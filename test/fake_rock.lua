--- Поведение рока-двойника, общее для проверок драйвера SQL над роком
--- и фасадов над ним.
---
--- Роки `pg` и `mysql` отвечают на оператор одинаково там, где это важно
--- драйверу: записи либо бросок, соединение, которое рок пометил негодным,
--- отказывает всему, `BEGIN`, `COMMIT` и `ROLLBACK` меняют транзакцию.
--- Своё у каждого — форма ответа и отказа, её двойник фасада строит
--- из ответа отсюда.
---
--- Исходников фасадов файл не грузит: его берут помощники, которые грузят
--- их сами. Обвязка проверок фасада — поставить двойника, завести драйвер,
--- убрать за проверкой — тоже здесь: у фасадов она одна.

local fiber = require('fiber')

--- Помощник пакета: части драйвера по имени, сверка места броска.
local storage = dofile('test/helper.lua')

local Module = {}

---@class TntStorageFakeAnswer Что рок сделает с оператором
---@field rows table[]|nil Записи первого набора
---@field affected integer|nil Число затронутых строк
---@field last_id integer|nil Новый ключ AUTO_INCREMENT
---@field delay number|nil Сколько помолчать перед ответом
---@field raise any Что бросить вместо ответа
---@field broken boolean|nil Пометить соединение негодным
---@field open boolean|nil Транзакция открыта после оператора

---@class TntStorageFakeConn Соединение двойника
---@field number integer Номер входа
---@field alive boolean Годно ли: негодное отказывает всему
---@field open boolean Открыта ли транзакция
---@field closed boolean Закрыто ли

---@class TntStorageFakeLog Что видел двойник
---@field sent table[] Операторы по порядку: `{ sql, args, number }`
---@field logins integer Сколько было входов

--- Вход: решает `login(number)` — пусто, вход удался; `{ raise = …,
--- delay = … }` — отказ либо ожидание.
---@param seen TntStorageFakeLog
---@param login (fun(number: integer): table|nil)|nil
---@return TntStorageFakeConn
function Module.login(seen, login)
    seen.logins = seen.logins + 1

    local number = seen.logins
    local decision = login ~= nil and login(number) or {}

    if decision.delay ~= nil then
        fiber.sleep(decision.delay)
    end

    if decision.raise ~= nil then
        error(decision.raise, 0)
    end

    return { number = number, alive = true, open = false, closed = false }
end

--- Оператор: записать, ответить по `respond`, поменять транзакцию.
---@param seen TntStorageFakeLog
---@param respond (fun(sql: string, args: table, conn: TntStorageFakeConn): TntStorageFakeAnswer|nil)|nil
---@param conn TntStorageFakeConn
---@param sql string
---@param args table Параметры со счётом
---@return TntStorageFakeAnswer
function Module.execute(seen, respond, conn, sql, args)
    table.insert(seen.sent, { sql = sql, args = args, number = conn.number })

    if conn.closed or not conn.alive then
        error('Connection is not usable', 0)
    end

    local answer = respond ~= nil and respond(sql, args, conn) or {}

    if answer.delay ~= nil then
        fiber.sleep(answer.delay)
    end

    if answer.broken then
        conn.alive = false
    end

    if answer.open ~= nil then
        conn.open = answer.open
    elseif sql == 'BEGIN' then
        conn.open = true
    elseif sql == 'COMMIT' or sql == 'ROLLBACK' then
        conn.open = false
    end

    if answer.raise ~= nil then
        error(answer.raise, 0)
    end

    return answer
end

--- Соединение двойника с объектом драйвера рока: его `close` закрывает
--- и оборванное соединение, как у настоящих роков, у которых `close()`
--- на оборванном бросает.
---@param seen TntStorageFakeLog|table С полем `conns`
---@param login (fun(number: integer): table|nil)|nil
---@param class table Метатаблица соединения рока
---@return table conn
function Module.open(seen, login, class)
    local conn = setmetatable(Module.login(seen, login), class)

    conn.shut = false
    conn.conn = {
        close = function()
            conn.shut = true
        end,
    }
    table.insert(seen.conns, conn)

    return conn
end

--- `close()` соединения рока: на негодном бросает, как настоящий.
---@param conn TntStorageFakeConn
---@return boolean
function Module.close(conn)
    if conn.closed or not conn.alive then
        error('Connection is broken', 0)
    end

    conn.closed = true

    return true
end

--- Обвязка проверок фасада: `install`, `restore`, `client` и `suite`
--- в помощник пакета.
---
--- Драйвер к двойнику — без уборки пула и без пауз повторов: уборка
--- заводила бы файбер на каждый пул, а пауза между попытками — десятые
--- доли секунды на каждую проверку повторов. Пауза после отказа
--- открытия — сотые: без неё пул открывал бы без передышки до конца срока.
---@param helper table Помощник: `link`, `transaction`, `within`, `LOGIN`, `rock(respond, login)`
---@param new fun(opts: table, rock: any): any `new` фасада; двойника ему ставит подмена, а движку — аргумент
function Module.harness(helper, new)
    -- Движок и соседи из той же загрузки, что и фасад: помощник пакета
    -- зовёт обвязку сразу после загрузки исходников.
    helper.link = storage.module('tnt.storage.link')
    helper.transaction = storage.module('tnt.storage.transaction')
    helper.within = storage.module('tnt.storage.within')
    helper.failure = storage.module('tnt.storage.failure')

    -- Сверка места броска и значение мимо проверки типов.
    helper.assert_blamed = storage.assert_blamed
    helper.wrong = storage.wrong

    helper.pack = Module.pack

    --- Настройки входа, общие для проверок фасада.
    ---@type table
    helper.LOGIN = helper.LOGIN or { user = 'app', password = 'secret', db = 'app' }

    --- Настройки входа и поверх них данные.
    ---@param extra table|nil
    ---@return table
    function helper.with(extra)
        local given = table.copy(helper.LOGIN)

        for key, value in pairs(extra or {}) do
            given[key] = value
        end

        return given
    end

    --- Ставит двойника рока и говорит, что транзакции box нет.
    function helper.install(rock)
        helper.link._set_source({
            require = function()
                return rock
            end,
        })
        helper.transaction._set_source({
            in_box_txn = function()
                return false
            end,
        })
    end

    --- Возвращает пакету настоящие рок, часы и box.
    function helper.restore()
        helper.link._set_source(nil)
        helper.transaction._set_source(nil)
        helper.within._set_source(nil)
    end

    --- Драйвер к двойнику рока.
    ---@param rock any Двойник
    ---@param opts table|nil Настройки поверх
    ---@return any
    function helper.client(rock, opts)
        local given = table.deepcopy(opts or {})

        for key, value in pairs(helper.LOGIN) do
            if given[key] == nil then
                given[key] = value
            end
        end

        given.pool = given.pool or {}
        given.pool.sweep_interval = given.pool.sweep_interval or 0
        given.pool.open_cooldown = given.pool.open_cooldown or 0.01
        given.retry = given.retry or {}
        given.retry.base = given.retry.base or 0

        helper.install(rock)

        local client = new(given, rock)

        return client
    end

    --- Уборка проверкам настроек и `check` фасада на той же глубине, что
    --- у его `new`: бросок негодной настройки винит строку проверки,
    --- а не чужую строку выше неё.
    function helper.checking(g)
        g.before_each(function()
            helper.install(helper.rock())
        end)

        g.after_each(function()
            helper.restore()
        end)

        return function(opts)
            local checked = helper.settings.check(opts)

            return checked
        end
    end

    --- Уборка после каждой проверки набора и способ завести драйвер
    --- к двойнику на эту проверку. Драйвер отдаётся без типа: проверки
    --- читают поля отказа, не сверяя его с пустотой.
    function helper.suite(g)
        g.after_each(function()
            if g.client ~= nil then
                g.client:close()
                g.client = nil
            end

            helper.restore()

            if g.journal ~= nil then
                g.journal.release()
                g.journal = nil
            end
        end)

        return function(respond, opts, login, ...)
            local rock = helper.rock(respond, login, ...)

            g.client = helper.client(rock, opts)

            return g.client, rock
        end
    end
end

--- Значения со счётом.
---@param ... any
---@return table
function Module.pack(...)
    return { n = select('#', ...), ... }
end

--- Операторы, которые дошли до рока.
---@param seen TntStorageFakeLog
---@return string[]
function Module.statements(seen)
    local list = {}

    for _, entry in ipairs(seen.sent) do
        table.insert(list, entry.sql)
    end

    return list
end

--- Зовёт `fn` в файбере, отменяет его, пока тот ждёт, и отдаёт итог:
--- `false` и отмену, если её не спрятали в пару.
---@param fn fun(): any
---@return boolean ok
---@return any err
function Module.cancelled(fn)
    local caller = fiber.new(fn)

    caller:set_joinable(true)
    fiber.sleep(0.01)
    caller:cancel()

    return caller:join()
end

return Module
