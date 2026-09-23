--- Средства проверок драйвера SQL над роком (`tnt.storage.driver`).
---
--- Двойник здесь — знание рока (`TntStorageRock`) над соединениями-
--- двойниками: драйвер разговаривает с роком только через него, и всё, что
--- он решает, — по тому, что рок вернул, бросил и ответил о живости.
--- Двойник повторяет поведение роков `pg` и `mysql`: оператор отдаёт
--- наборы записей, `true` и число строк, отказывает броском, живость
--- бросает на негодном соединении; `BEGIN`, `COMMIT` и `ROLLBACK` меняют
--- транзакцию сами. Рок, который открытую транзакцию не видит (`mysql`), —
--- тот же двойник с `knows_open = false`.
---
--- Ожидание — настоящий `fiber.sleep`: отмена работника и срок держатся
--- на ядре. Как это сходится с настоящими роками, проверяют фасады над
--- ними своими двойниками и живыми проверками.

local fake_rock = dofile('test/fake_rock.lua')
local storage = dofile('test/helper.lua')

local helper = {}

--- Драйвер из исходников вместе с пулом и повторами, которые он получает
--- аргументом.
helper.driver = storage.load_driver()

--- Части пакета и соседи из той же загрузки, что и драйвер.
helper.link = storage.module('tnt.storage.link')
helper.statement = storage.module('tnt.storage.statement')
helper.transaction = storage.module('tnt.storage.transaction')
helper.within = storage.module('tnt.storage.within')
helper.failure = storage.module('tnt.storage.failure')
helper.value = storage.module('tnt.storage.value')
helper.pool = storage.module('tnt.pool')
helper.retry = storage.module('tnt.retry')

--- Журнал драйвера: записи идут под именем фасада.
helper.log = storage.module('tnt.log').new('tnt.fake')

--- Ловушка журнала на время проверки.
helper.capture_log = storage.capture_log

--- Сверка места броска и значение мимо проверки типов.
helper.assert_blamed = storage.assert_blamed
helper.wrong = storage.wrong

--- Как настройки называются в отказе.
helper.TITLE = 'настройки fake'

--- Отказ сервера с кодом, как его бросает рок, который код отдаёт:
--- `box.error` с полем кода.
---@param reason string
---@param code string|integer|nil
---@return any
function helper.server_error(reason, code)
    -- `box.error.new` в аннотациях ядра может быть пуст; в Tarantool он есть всегда.
    ---@diagnostic disable-next-line: need-check-nil
    return box.error.new({ type = 'FakeError', reason = reason, server_code = code })
end

---@class TntStorageFake: TntStorageFakeLog Двойник рока
---@field rock TntStorageRock Знание рока для драйвера
---@field conns TntStorageFakeConn[] Открытые соединения

--- Двойник рока.
---
--- `respond(sql, args, conn)` отвечает на оператор таблицей
--- `TntStorageFakeAnswer`; пустой ответ — пустая выборка. `login(number)`
--- решает вход: пусто — вход удался, `{ raise = …, delay = … }` — отказ
--- либо ожидание.
---@param respond (fun(sql: string, args: table, conn: TntStorageFakeConn): TntStorageFakeAnswer|nil)|nil
---@param login (fun(number: integer): table|nil)|nil
---@param knows_open boolean|nil Говорит ли рок, открыта ли транзакция; по умолчанию да
---@return TntStorageFake
function helper.rock(respond, login, knows_open)
    ---@type TntStorageFake
    local fake = { conns = {}, sent = {}, logins = 0 } ---@diagnostic disable-line: missing-fields

    fake.rock = {
        label = 'fake',
        where = 'h:1/app',
        connect = function()
            local conn = fake_rock.login(fake, login)

            table.insert(fake.conns, conn)

            return conn
        end,
        shut = function(conn)
            conn.closed = true
        end,
        state = function(conn)
            if conn.closed or not conn.alive then
                return false
            end

            if knows_open == false then
                return true
            end

            return true, conn.open
        end,
        execute = function(conn, sql, params)
            local answer = fake_rock.execute(fake, respond, conn, sql, params)

            return { answer.rows }, true, answer.affected
        end,
        code = function(err)
            -- `box.error.is` в аннотациях ядра не описан.
            ---@diagnostic disable-next-line: undefined-field
            if box.error.is(err) then
                return err.server_code
            end

            return nil
        end,
        text = helper.failure.text,
        count = function(_, _, affected)
            return { affected = affected }
        end,
    }

    return fake
end

--- Говорит драйверу, идёт ли транзакция box.
---@param inside boolean
function helper.in_box_txn(inside)
    helper.transaction._set_source({
        in_box_txn = function()
            return inside
        end,
    })
end

--- Операторы, которые дошли до рока.
helper.statements = fake_rock.statements

--- Настройки входа двойника: учётная запись и база обязательны.
helper.LOGIN = { user = 'app', db = 'app' }

--- Обвязка: `install`, `restore`, `client(fake, opts)` и `suite(g)`,
--- где способ завести драйвер берёт ещё `knows_open` двойника.
fake_rock.harness(helper, function(given, fake)
    local settings = helper.driver.settings(given, helper.TITLE, { name = 'fake', port = 1 }, 1)
    local client = helper.driver.new(settings, {
        rock = fake.rock,
        dialect = { name = 'postgres' },
        log = helper.log,
        pool = helper.pool,
        retry = helper.retry,
    }, 1)

    return client
end)

--- Отмена вызывающего посреди ожидания.
helper.cancelled = fake_rock.cancelled

return helper
