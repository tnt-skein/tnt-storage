--- Транзакция на одном соединении: `BEGIN`, тело, `COMMIT` либо `ROLLBACK`.
---
--- Правила одни на все драйверы SQL над роком:
---
--- * тело ничего не вернуло — фиксация и `true`, как у `box.atomic`;
---   первое значение `nil` или `false` — откат и пара `nil, err`, где `err`
---   тела отдаётся как есть; иное — фиксация и это значение;
--- * **первый отказ оператора помечает транзакцию**: следующие операторы
---   `tx` сразу отдают тот же отказ, фиксации не будет. У PostgreSQL так
---   ведёт себя сервер — и `COMMIT` после ошибки молча откатывает;
---   у MySQL транзакция после ошибки цела, но договор один на оба рока;
--- * исключение в теле — соединение выбрасывается (закрытие сокета
---   откатывает транзакцию на сервере), исключение идёт дальше: это ошибка
---   программиста, и прятать её в пару — прятать поломку;
--- * соединение, помеченное к выбросу оператором тела (отменённое
---   ожидание), выбрасывается без `ROLLBACK`: в сокете недочитанный ответ;
--- * взятие соединения и `BEGIN` повторяются — тело ещё не выполнялось;
---   операторы тела — никогда, и срока своего у них нет: срок один
---   на транзакцию;
--- * `retry = true` повторяет всю транзакцию с телом, если она кончилась
---   конфликтом (`conflict`: сериализация, взаимоблокировка), — сервер
---   откатил её целиком. Тело при этом обязано быть безопасным для
---   повтора: всё, что оно делает мимо `tx`, случится дважды;
--- * `tx` годен только внутри тела; вложенная транзакция и транзакция
---   внутри транзакции box — исключение.
---
--- Открыта ли транзакция, фасад отмечает на соединении сам (`open`):
--- `mysql` этого не говорит, а крюк `reset` пула и решение
--- «откатить перед возвратом» без отметки у него были бы слепы.

local fiber = require('fiber')

local fail = require('tnt.must.fail')
local failure = require('tnt.storage.failure')
local must = require('tnt.must')
local external = require('tnt.external')
local statement = require('tnt.storage.statement')
local value = require('tnt.storage.value')
local within = require('tnt.storage.within')

local Module = {}

--- Внешнее средство: транзакция box.
local source = external.install(Module, {
    -- До `box.cfg` транзакции не бывает, а само обращение
    -- к `box.is_in_txn` бросает, и перехватить его нельзя.
    in_box_txn = function()
        return type(box.cfg) ~= 'function' and box.is_in_txn()
    end,
})

--- Настройки транзакции.
local OPTIONS = { timeout = '?number', retry = '?boolean' }

--- Настройки оператора внутри транзакции: только предел строк.
local STEP = { max_rows = '?integer' }

--- Параметры служебных операторов.
local NONE = { n = 0 }

--- Бросок `tx`, унесённого за пределы тела.
local FINISHED =
    'tx годен только внутри тела транзакции, а она уже закончена'

--- Бросок срока и повтора у оператора транзакции.
local OWN_DEADLINE =
    'у оператора транзакции нет своего срока и повтора: их задаёт transaction'

--- Бросок транзакции внутри транзакции box.
local INSIDE_BOX = 'transaction внутри транзакции box: ожидание сети оборвёт её'

--- Бросок вложенной транзакции.
local NESTED =
    'transaction внутри transaction: вторая взяла бы второе соединение и ждала бы первого'

---@class TntStorageTx Операторы одной транзакции
---@field client TntStorageDriver
---@field conn TntStorageLink Соединение транзакции
---@field deadline number Миг срока транзакции
---@field timeout number Срок транзакции, секунд
---@field failed TntStorageFailure|nil Первый отказ оператора: фиксации не будет
---@field doomed boolean Соединение не вернуть: в сокете недочитанный ответ
---@field finished boolean Тело вышло: `tx` больше не годен
local Tx = {}
Tx.__index = Tx

--- Значения со счётом: `nil` посреди и в конце не теряются.
---@param ... any
---@return table
local function pack(...)
    return { n = select('#', ...), ... }
end

--- Идёт ли транзакция box в этом файбере.
---@return boolean
function Module.in_box_txn()
    return source().in_box_txn() == true
end

--- Отказ оператора транзакции: не повторяется никогда — повтор оператора
--- помеченную транзакцию не лечит.
---@param err TntStorageFailure
---@return TntStorageFailure
local function final(err)
    return failure.new(err.kind, err.message, {
        sent = err.sent,
        retriable = false,
        server_code = err.server_code,
        reason = err.reason,
    })
end

--- Оператор внутри транзакции.
---@param sql string
---@param params table|nil
---@param opts table|nil
---@param shape string rows либо count
---@return table|nil value
---@return TntStorageFailure|nil err
function Tx:_run(sql, params, opts, shape)
    if self.finished then
        error(FINISHED, 3)
    end

    if sql == nil and failure.is(params) then
        ---@cast params TntStorageFailure
        self.failed = self.failed or final(params)

        return nil, self.failed
    end

    local caller = must.at(3)

    caller.string(sql, 'sql')

    if type(opts) == 'table' and (opts.timeout ~= nil or opts.idempotent ~= nil) then
        error(OWN_DEADLINE, 3)
    end

    caller.optional.options(opts, 'настройки оператора транзакции', STEP)

    local given = opts or {}

    caller.optional.positive(given.max_rows, 'max_rows')

    local encoded, refused = value.params(self.client.dialect, params or NONE, 3)

    if self.failed ~= nil then
        return nil, self.failed
    end

    if encoded == nil then
        ---@cast refused TntStorageFailure
        self.failed = final(refused)

        return nil, self.failed
    end

    ---@type TntStorageCall
    local call = { timeout = self.timeout, max_rows = given.max_rows or self.client.max_rows, shape = shape }
    local done, err, action = statement.run(self.conn, sql, encoded, self.deadline, call)

    if action == statement.DROP then
        self.doomed = true
    end

    if err ~= nil then
        self.failed = final(err)

        return nil, self.failed
    end

    return done
end

--- Выборка внутри транзакции.
---@param sql string
---@param params table|nil
---@param opts { max_rows: integer|nil }|nil
---@return table[]|nil rows
---@return TntStorageFailure|nil err
function Tx:query(sql, params, opts)
    local rows, err = self:_run(sql, params, opts, statement.ROWS)

    return rows, err
end

--- Оператор без выборки внутри транзакции.
---@param sql string
---@param params table|nil
---@param opts table|nil
---@return table|nil result
---@return TntStorageFailure|nil err
function Tx:execute(sql, params, opts)
    local result, err = self:_run(sql, params, opts, statement.COUNT)

    return result, err
end

--- Берёт соединение и открывает транзакцию; то и другое повторяется
--- по приговору отказа: тело ещё не выполнялось, а `BEGIN` ничего
--- не меняет.
---@param client TntStorageDriver
---@param deadline number
---@param timeout number
---@return TntStorageLink|nil conn
---@return TntStorageFailure|nil err
local function begin(client, deadline, timeout)
    ---@type TntStorageCall
    local call = { timeout = timeout, idempotent = true, shape = statement.COUNT }
    local last = nil

    return client.retry:run(function()
        local conn, refused = client:_take(deadline, last)

        if conn == nil then
            last = refused

            return nil, refused
        end

        local _, failed, action = statement.run(conn, 'BEGIN', NONE, deadline, call)

        if failed ~= nil then
            client:_release(conn, action, failed, deadline, call)
            last = failed

            return nil, failed
        end

        conn.open = true

        return conn
    end, { deadline = timeout })
end

--- Конец транзакции: фиксация, если тело согласно и отказов не было,
--- иначе откат.
---@param tx TntStorageTx
---@param verdict any Первое значение тела
---@param reason any Второе значение тела
---@return any value
---@return any err
local function finish(tx, verdict, reason)
    local client, conn, deadline = tx.client, tx.conn, tx.deadline
    ---@type TntStorageCall
    local call = { timeout = tx.timeout, shape = statement.COUNT }

    if tx.failed == nil and verdict ~= nil and verdict ~= false then
        local _, refused, action = statement.run(conn, 'COMMIT', NONE, deadline, call)

        if refused == nil then
            conn.open = false
        end

        client:_release(conn, action, refused, deadline, call)

        if refused ~= nil then
            return nil, refused
        end

        return verdict
    end

    local refusal = tx.failed
        or reason
        or failure.new(failure.REJECTED, 'тело отменило транзакцию')

    if tx.doomed then
        ---@cast refusal TntStorageFailure
        client:_discard(conn, refusal.kind, refusal.reason)
    else
        client:_release(conn, statement.ROLLBACK, nil, deadline, call)
    end

    return nil, refusal
end

--- Одна транзакция целиком.
---@param client TntStorageDriver
---@param fn fun(tx: TntStorageTx): any, any
---@param deadline number
---@param timeout number
---@return any value
---@return any err
local function once(client, fn, deadline, timeout)
    local conn, err = begin(client, deadline, timeout)

    if conn == nil then
        return nil, err
    end

    ---@type TntStorageTx
    local tx = setmetatable({
        client = client,
        conn = conn,
        deadline = deadline,
        timeout = timeout,
        doomed = false,
        finished = false,
    }, Tx)
    local id = fiber.id()

    client.inside[id] = true

    local results = pack(pcall(fn, tx))

    client.inside[id] = nil
    tx.finished = true

    if not results[1] then
        client:_discard(conn, nil, 'исключение в теле транзакции')
        fail.raise(results[2])
    end

    local verdict = results[2]

    if results.n == 1 then
        verdict = true
    end

    return finish(tx, verdict, results[3])
end

--- Повторять ли всю транзакцию: только конфликт — его сервер откатил
--- целиком.
---@param err any
---@return boolean
local function conflicted(err)
    return failure.is(err) and err.kind == failure.CONFLICT
end

--- Транзакция: проверка аргументов, один срок, повтор по `retry`.
---@param client TntStorageDriver
---@param fn fun(tx: TntStorageTx): any, any
---@param opts { timeout: number|nil, retry: boolean|nil }|nil
---@return any value
---@return any err
function Module.run(client, fn, opts)
    local caller = must.at(3)

    caller.callable(fn, 'тело транзакции')
    caller.optional.options(opts, 'настройки транзакции', OPTIONS)

    local given = opts or {}
    local timeout = within.timeout(given.timeout, client.limits, 3)

    if Module.in_box_txn() then
        error(INSIDE_BOX, 3)
    end

    if client.inside[fiber.id()] then
        error(NESTED, 3)
    end

    local deadline = within.deadline(timeout)

    if not given.retry then
        return once(client, fn, deadline, timeout)
    end

    -- `tnt-retry` ловит исключения действия и считает их отказом, а
    -- исключение тела обязано идти дальше: оно несётся мимо повторов.
    -- Брошенное отдаётся повторам как итог: конфликтом оно не бывает,
    -- и повтора за ним нет.
    ---@type table|nil
    local raised = nil
    local done, err = client.retry:run(function()
        local results = pack(pcall(once, client, fn, deadline, timeout))

        if not results[1] then
            raised = results
        end

        return results[2], results[3]
    end, { deadline = timeout, retriable = conflicted })

    if raised ~= nil then
        fail.raise(raised[2])
    end

    return done, err
end

return Module
