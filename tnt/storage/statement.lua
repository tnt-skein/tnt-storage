--- Один оператор на взятом соединении: итог рока — ответом либо отказом
--- с решением, что делать с соединением.
---
--- Решение принимается по месту отказа:
---
--- * `give` — рок ответил, соединение цело и чисто, либо срок вышел
---   до вызова рока и сокет не тронут;
--- * `rollback` — сервер отказал, соединение цело, а транзакция на нём
---   осталась открытой: её откатывает драйвер сам, в остаток срока, —
---   крюк `reset` пула без сети и откатить не может;
--- * `drop` — работник отменён по сроку (в сокете недочитанный ответ)
---   либо соединение оборвалось.
---
--- Род отказа, пришедшего броском рока: сначала местная живость — бросила,
--- значит `broken`, какой бы ни была ошибка. Жива — род решает код сервера
--- (SQLSTATE, errno), а без него слова отказа (`tnt.storage.codes`).

local failure = require('tnt.storage.failure')
local link = require('tnt.storage.link')
local within = require('tnt.storage.within')

local Module = {}

--- Вернуть соединение в пул.
Module.GIVE = 'give'

--- Откатить открытую транзакцию и вернуть.
Module.ROLLBACK = 'rollback'

--- Выбросить соединение.
Module.DROP = 'drop'

--- Ответ — записи первого набора.
Module.ROWS = 'rows'

--- Ответ — сколько строк затронуто: форму даёт знание рока (`count`).
Module.COUNT = 'count'

--- Значения со счётом: `nil` посреди и в конце не теряются.
---@param ... any
---@return table
local function pack(...)
    return { n = select('#', ...), ... }
end

---@class TntStorageCall Что знает о вызове каждый его оператор
---@field timeout number Срок вызова, секунд — для текста отказа
---@field idempotent boolean|nil Согласие на повтор после отправки
---@field max_rows integer|nil Предел строк выборки; служебным операторам не нужен
---@field shape string rows либо count

--- Отказ, который пришёл броском рока.
---@param conn TntStorageLink
---@param err any Что бросил рок
---@param call TntStorageCall
---@return TntStorageFailure
---@return string action
local function refusal(conn, err, call)
    local alive, open = link.state(conn)
    local rock = conn.rock

    if not alive then
        local text = ('%s %s: соединение оборвалось: %s'):format(
            rock.label,
            rock.where,
            rock.text(err)
        )

        return failure.new(failure.BROKEN, text, { idempotent = call.idempotent }), Module.DROP
    end

    local refused = failure.statement(rock.text(err), rock.code(err), { idempotent = call.idempotent })

    -- Сервер сказал, что закрывает сеанс, а рок ещё не заметил: такое
    -- соединение не вернуть.
    if refused.kind == failure.BROKEN then
        return refused, Module.DROP
    end

    return refused, open and Module.ROLLBACK or Module.GIVE
end

--- Ответ рока в форме вызова.
---
--- Выборка — записи первого набора: оператор на вызов один.
--- Предел строк сверяется после чтения: память уже потрачена, и защищает
--- он того, кто работает с ответом дальше.
---@param conn TntStorageLink
---@param call TntStorageCall
---@param ... any Что отдал рок: наборы записей, затем своё
---@return table|nil value
---@return TntStorageFailure|nil err
local function shaped(conn, call, ...)
    if call.shape == Module.COUNT then
        return conn.rock.count(...)
    end

    local datas = ...
    local rows = datas[1] or {}
    local limit = call.max_rows --[[@as integer]]

    if #rows > limit then
        return nil, failure.new(failure.OVERFLOW, ('строк %d больше max_rows %d'):format(#rows, limit))
    end

    return rows
end

--- Выполняет оператор.
---@param conn TntStorageLink
---@param sql string
---@param params table Закодированные параметры с полем `n`
---@param deadline number Миг срока
---@param call TntStorageCall
---@return table|nil value Записи либо ответ оператора без выборки
---@return TntStorageFailure|nil err
---@return string action give, rollback либо drop
function Module.run(conn, sql, params, deadline, call)
    local result = pack(link.run(conn, deadline, sql, params))
    local status = result[1]

    if status == within.RETURNED then
        local value, overflow = shaped(conn, call, unpack(result, 2, result.n))

        return value, overflow, Module.GIVE
    end

    if status == within.RAISED then
        return nil, refusal(conn, result[2], call)
    end

    if status == within.EXPIRED then
        local rock = conn.rock
        local text = ('%s %s: ответа нет за %s с'):format(rock.label, rock.where, call.timeout)

        return nil, failure.new(failure.TIMEOUT, text, { idempotent = call.idempotent }), Module.DROP
    end

    -- Осталось одно: срок вышел раньше, и рок не звался — сокет чист.
    return nil,
        failure.new(
            failure.TIMEOUT,
            'срок вызова вышел до отправки оператора',
            { sent = false }
        ),
        Module.GIVE
end

return Module
