--- Проверки драйвера над роком: общие настройки, выборка и число строк,
--- отказ парой с родом, повторы по приговору, откат и выброс соединения,
--- один срок на вызов, закрытие и отмена — на двойнике рока.

local clock = require('clock')
local fiber = require('fiber')
local json = require('json')
local t = require('luatest')

local helper = dofile('test/driver_helper.lua')

local driver = helper.driver

local g = t.group('tnt.storage.driver')

local connect = helper.suite(g)

--- Род и приговор отказа.
---@param err TntStorageFailure
---@return table
local function verdict(err)
    return { kind = err.kind, retriable = err.retriable, sent = err.sent }
end

g.test_new_opens_nothing = function()
    local client, fake = connect(nil, { name = 'orders', max_rows = 7 })

    t.assert_equals(client.name, 'orders')
    t.assert_equals(client.features, { transaction = true })
    t.assert_equals(client.dialect, { name = 'postgres' })
    t.assert_equals(client.where, 'h:1/app')
    t.assert_is(client.rock, fake.rock)
    t.assert_is(client.log, helper.log)
    t.assert_equals(client.limits, { timeout = 5, max_timeout = 60 })
    t.assert_equals(client.max_rows, 7)
    t.assert_equals(client.wait_timeout, 5)
    t.assert_equals(client.closed, false)
    t.assert_equals(client:stats().name, 'orders')
    t.assert_equals(fake.logins, 0)
end

--- Имя и порт двойника по умолчанию.
local DEFAULTS = { name = 'fake', port = 1 }

g.test_settings = function()
    t.assert_equals(driver.DEFAULT_MAX_ROWS, 10000)
    t.assert_equals(driver.DEFAULT_HOST, '127.0.0.1')
    t.assert_equals(driver.settings({ user = 'app', db = 'shop' }, helper.TITLE, DEFAULTS, 1), {
        name = 'fake',
        host = '127.0.0.1',
        port = 1,
        user = 'app',
        db = 'shop',
        where = '127.0.0.1:1/shop',
        limits = { timeout = 5, max_timeout = 60 },
        max_rows = 10000,
        pool = {},
        retry = {},
    })
    t.assert_equals(
        driver.settings({
            host = 'db.local',
            port = 65535,
            user = 'app',
            password = 'secret',
            db = 'app db',
            tls = { mode = 'require' },
            name = 'orders',
            timeout = 0.2,
            max_timeout = 0.3,
            max_rows = 5,
            pool = { size = 2 },
            retry = { attempts = 4 },
        }, helper.TITLE, DEFAULTS, 1),
        {
            name = 'orders',
            host = 'db.local',
            port = 65535,
            user = 'app',
            password = 'secret',
            db = 'app db',
            where = 'db.local:65535/app db',
            limits = { timeout = 0.2, max_timeout = 0.3 },
            max_rows = 5,
            pool = { size = 2 },
            retry = { attempts = 4 },
        }
    )
end

g.test_facade_checks_loads_and_builds = function()
    local fake = helper.rock()
    local seen = {}
    local new = driver.facade({
        dialect = { name = 'postgres', quote = '"' },
        check = function(opts)
            seen.opts = opts

            local checked = driver.settings(opts, helper.TITLE, DEFAULTS, 3)

            return checked
        end,
        rock = {
            load = function(level)
                seen.level = level

                return 'рок'
            end,
            new = function(settings, loaded)
                seen.settings, seen.loaded = settings, loaded

                return fake.rock
            end,
        },
        log = helper.log,
        pool = helper.pool,
        retry = helper.retry,
    })
    local client = new({ user = 'app', db = 'app', name = 'orders' })
    local other = new({ user = 'app', db = 'app' })

    t.assert_equals(seen.opts, { user = 'app', db = 'app' })
    t.assert_equals(seen.level, 2)
    t.assert_equals(seen.loaded, 'рок')
    t.assert_equals(seen.settings.name, 'fake')
    t.assert_is(client.rock, fake.rock)
    t.assert_equals(client.name, 'orders')
    t.assert_equals(client.dialect, { name = 'postgres', quote = '"' })
    -- Своя копия правил у каждого драйвера.
    t.assert(client.dialect ~= other.dialect)
    client:close()
    other:close()

    helper.assert_blamed({
        {
            function()
                new({ user = 'app' })
            end,
            'настройки fake.db — непустая строка, а не nil',
        },
        {
            function()
                new({ user = 'app', db = 'app', retry = { attempts = 0 } })
            end,
            'настройки повторов: настройка attempts — целое число от 1, а пришло: 0',
        },
    })
end

g.test_wrong_settings_blame_the_caller = function()
    local parts = {
        rock = helper.rock().rock,
        dialect = { name = 'postgres' },
        log = helper.log,
        pool = helper.pool,
        retry = helper.retry,
    }

    local login = helper.with

    helper.assert_blamed({
        {
            function()
                driver.settings(helper.wrong(nil), helper.TITLE, DEFAULTS, 1)
            end,
            'настройки fake — таблица, а не nil',
        },
        {
            function()
                driver.settings({ db = 'app' }, helper.TITLE, DEFAULTS, 1)
            end,
            'настройки fake.user — непустая строка, а не nil',
        },
        {
            function()
                driver.settings(login({ pasword = 'x' }), helper.TITLE, DEFAULTS, 1)
            end,
            'настройки fake: ключа «pasword» нет, есть db, host, max_rows, max_timeout, name, '
                .. 'password, pool, port, retry, timeout, tls, user',
        },
        {
            function()
                driver.settings(login({ port = 0 }), helper.TITLE, DEFAULTS, 1)
            end,
            'настройки fake.port — число от 1 до 65535, а не 0',
        },
        {
            function()
                driver.settings(login({ port = 65536 }), helper.TITLE, DEFAULTS, 1)
            end,
            'настройки fake.port — число от 1 до 65535, а не 65536',
        },
        {
            function()
                driver.settings(login({ max_rows = 0 }), helper.TITLE, DEFAULTS, 1)
            end,
            'настройки fake.max_rows — число больше 0, а не 0',
        },
        {
            function()
                driver.settings(login({ timeout = 10, max_timeout = 3 }), helper.TITLE, DEFAULTS, 1)
            end,
            'timeout 10 с длиннее потолка max_timeout 3 с',
        },
        {
            function()
                driver.new(driver.settings(login({ retry = { attempts = 0 } }), helper.TITLE, DEFAULTS, 1), parts, 1)
            end,
            'настройки повторов: настройка attempts — целое число от 1, а пришло: 0',
        },
    })
end

g.test_query_and_execute = function()
    local client, fake = connect(function(text, args)
        if text:find('^select') then
            return { rows = { { a = args[1], c = args[3] } }, affected = 1 }
        end

        return { affected = 2 }
    end)

    t.assert_equals({ client:query('select $1, $2, $3', { n = 3, 1, nil, 3 }) }, { { { a = 1, c = 3 } } })
    t.assert_equals({ client:execute('update t set a = 1') }, { { affected = 2 } })
    t.assert_equals({ client:query('select 1') }, { { {} } })
    t.assert_equals(fake.sent[1].args, { n = 3, 1, box.NULL, 3 })
    t.assert_equals(fake.sent[3].args, { n = 0 })
    t.assert_equals(fake.logins, 1)
    t.assert_equals(client:stats().gives, 3)
end

g.test_a_refusal_of_the_builder_goes_as_is = function()
    local client, fake = connect()
    local _, _, refusal = helper.value.wire('postgres', 'a\0b')

    -- Отказ сборки проходит насквозь той же парой, ничего не отправив.
    local rows, err = client:query(nil, refusal)

    t.assert_equals(rows, nil)
    t.assert_is(err, refusal)
    t.assert_equals({ client:execute(nil, refusal) }, { nil, refusal })
    t.assert_equals(#fake.sent, 0)
end

g.test_values_are_encoded_like_tnt_sql_does = function()
    local client, fake = connect()

    t.assert_equals({ client:query('select $1::int8', { n = 1, 42LL }) }, { {} })
    t.assert_equals(fake.sent[1].args, { n = 1, '42' })

    local rows, err = client:query('select $1', { n = 1, 'a\0b' })

    t.assert_equals(rows, nil)
    t.assert_equals(verdict(err), { kind = 'rejected', retriable = false, sent = false })
    t.assert_equals(#fake.sent, 1)
end

g.test_rows_over_the_limit = function()
    local client = connect(function()
        return { rows = { { a = 1 }, { a = 2 } } }
    end, { max_rows = 1 })
    local _, err = client:query('select a from t')

    t.assert_equals(verdict(err), { kind = 'overflow', retriable = false, sent = true })
    t.assert_equals({ client:query('select a from t', nil, { max_rows = 2 }) }, { { { a = 1 }, { a = 2 } } })
end

g.test_a_refusal_is_not_repeated = function()
    local client, fake = connect(function()
        return { raise = helper.server_error('ERROR:  syntax error', '42601') }
    end)
    local _, err = client:query('selec 1', nil, { idempotent = true })

    t.assert_equals(verdict(err), { kind = 'rejected', retriable = false, sent = true })
    t.assert_equals(err.server_code, '42601')
    t.assert_equals(#fake.sent, 1)
    t.assert_equals(client:stats().drops, 0)
end

g.test_a_break_after_sending_is_repeated_only_when_idempotent = function()
    local breaking = true
    local client, fake = connect(function()
        if breaking then
            breaking = false

            return { raise = 'server closed the connection unexpectedly', broken = true }
        end

        return { rows = { { one = 1 } } }
    end)
    local _, err = client:query('select 1')

    t.assert_equals(verdict(err), { kind = 'broken', retriable = false, sent = true })
    t.assert_equals(#fake.sent, 1)
    t.assert_equals(client:stats().drops, 1)

    breaking = true
    t.assert_equals({ client:query('select 1', nil, { idempotent = true }) }, { { { one = 1 } } })
    t.assert_equals(#fake.sent, 3)
    t.assert_equals(client:stats().drops, 2)
    t.assert_equals(fake.logins, 3)
end

g.test_an_unanswered_statement_drops_the_conn_and_logs_no_values = function()
    g.journal = helper.capture_log()

    local client = connect(function(text)
        if text:find('secret') then
            return { delay = 1 }
        end
    end)
    local started = clock.monotonic()
    local result, err = client:query("select 'secret'", { n = 1, 'hidden-value' }, { timeout = 0.05 })
    local spent = clock.monotonic() - started

    t.assert_equals(result, nil)
    t.assert_equals(verdict(err), { kind = 'timeout', retriable = false, sent = true })
    t.assert_equals(err.message, 'fake h:1/app: ответа нет за 0.05 с')
    t.assert(spent >= 0.04 and spent < 0.3, spent)
    t.assert_equals(client:stats().drops, 1)

    local record = g.journal.find('WARN [tnt.fake] соединение выброшено')

    t.assert_equals(record.record.fields, { driver = 'fake', kind = 'timeout', reason = err.message })
    t.assert_not(g.journal.logged('secret'))
    t.assert_not(g.journal.logged('hidden-value'))
end

g.test_a_refusal_in_an_open_transaction_is_rolled_back_before_return = function()
    local client, fake = connect(function(text)
        if text == 'insert' then
            return { raise = 'ERROR:  duplicate key value', open = true }
        end
    end)
    local _, err = client:execute('insert')

    t.assert_equals(err.kind, 'rejected')
    t.assert_equals(helper.statements(fake), { 'insert', 'ROLLBACK' })
    t.assert_equals(fake.conns[1].open, false)
    t.assert_equals(client:stats().drops, 0)
    t.assert_equals(client:stats().idle, 1)
end

g.test_a_transaction_left_open_by_hand_is_not_given_to_the_next = function()
    g.journal = helper.capture_log()

    local client, fake = connect()

    t.assert_equals({ client:execute('BEGIN') }, { { affected = nil } })
    t.assert_equals(fake.conns[1].closed, true)
    t.assert_equals(client:stats().discarded, 1)
    t.assert_not_equals(
        g.journal.find(
            'WARN [tnt.fake] соединение вернулось с открытой транзакцией'
        ),
        nil
    )
end

g.test_a_failed_rollback_drops_the_conn = function()
    g.journal = helper.capture_log()

    local client = connect(function(text)
        if text == 'insert' then
            return { raise = 'ERROR:  duplicate key value', open = true }
        end

        if text == 'ROLLBACK' then
            return { raise = 'server closed the connection unexpectedly', broken = true }
        end
    end)
    local _, err = client:execute('insert')

    t.assert_equals(err.kind, 'rejected')
    t.assert_equals(client:stats().drops, 1)

    local record = g.journal.find('WARN [tnt.fake] соединение выброшено')

    t.assert_equals(record.record.fields.kind, 'broken')
end

g.test_a_denied_login_is_returned_at_once = function()
    local client, fake = connect(nil, { timeout = 1 }, function()
        return { raise = 'FATAL:  password authentication failed for user "app"' }
    end)
    local started = clock.monotonic()
    local _, err = client:query('select 1')

    t.assert_equals(verdict(err), { kind = 'denied', retriable = false, sent = false })
    t.assert(clock.monotonic() - started < 0.5)
    t.assert_equals(fake.logins, 1)
end

g.test_an_unreachable_server_is_told_by_the_last_open_error = function()
    local client = connect(nil, { timeout = 0.2, pool = { wait_timeout = 0.05 } }, function()
        return { raise = 'connection to server at "127.0.0.1", port 5432 failed: Connection refused' }
    end)
    local _, err = client:query('select 1')

    t.assert_equals(verdict(err), { kind = 'unreachable', retriable = true, sent = false })
    t.assert_str_contains(err.message, 'Connection refused')
end

g.test_a_busy_pool_waits_no_longer_than_wait_timeout = function()
    local client = connect(nil, { timeout = 1, pool = { size = 1, wait_timeout = 0.05 } })
    local holder = fiber.new(function()
        client:transaction(function()
            fiber.sleep(2)
        end, { timeout = 3 })
    end)

    holder:set_joinable(true)
    fiber.sleep(0.01)

    local started = clock.monotonic()
    local _, err = client:query('select 1')
    local spent = clock.monotonic() - started

    t.assert_equals(verdict(err), { kind = 'busy', retriable = true, sent = false })
    t.assert_equals(
        err.message,
        'fake h:1/app: соединение не получено за 0.05 с: все 1 заняты'
    )
    t.assert(spent < 0.5, spent)
    holder:cancel()
end

g.test_a_busy_pool_stays_busy_after_an_old_open_failure = function()
    local client = connect(nil, { timeout = 1, pool = { size = 1, wait_timeout = 0.05 } }, function(number)
        if number == 1 then
            return { raise = 'connection to server at "127.0.0.1", port 5432 failed: Connection refused' }
        end
    end)
    local holder = fiber.new(function()
        client:transaction(function()
            fiber.sleep(2)
        end, { timeout = 3 })
    end)

    holder:set_joinable(true)

    -- Ждём, пока держатель займёт место, а не спим заданное время. Срок его
    -- первого взятия кончается в тот же миг, что и такой сон, и под
    -- нагрузкой прогона побудка после паузы опаздывает: взятие держателя
    -- выходит по сроку, а место достаётся самой проверке.
    t.helpers.retrying({ timeout = 2 }, function()
        t.assert_equals(client:stats().busy, 1)
    end)

    -- Отказ открытия пул помнит и после удачного входа, но место занято:
    -- соединения не дали, потому что все заняты, а не потому что не открыть.
    t.assert_not_equals(client:stats().last_open_error, nil)

    local _, err = client:query('select 1')

    t.assert_equals(verdict(err), { kind = 'busy', retriable = true, sent = false })
    holder:cancel()
end

g.test_the_deadline_gone_before_an_attempt = function()
    local now = 0

    helper.within._set_source({
        monotonic = function()
            return 0
        end,
        scheduler_now = function()
            return now
        end,
    })

    -- Остаток следующей попытки — ровно ноль: срок вышел и на самой границе.
    local client, fake = connect(function()
        now = 5

        return { raise = 'server closed the connection unexpectedly', broken = true }
    end)
    local _, err = client:query('select 1', nil, { idempotent = true })

    t.assert_equals(verdict(err), { kind = 'broken', retriable = false, sent = true })
    t.assert_equals(
        err.message,
        'fake h:1/app: соединение оборвалось: server closed the connection unexpectedly'
    )
    t.assert_equals(#fake.sent, 1)

    -- Остаток меньше нуля — тоже срок, и попытки не было вовсе.
    now = 6

    local _, late = client:query('select 1')

    t.assert_equals(verdict(late), { kind = 'timeout', retriable = false, sent = false })
    t.assert_equals(late.message, 'срок вызова вышел до отправки оператора')
    t.assert_equals(#fake.sent, 1)
end

g.test_close = function()
    local client, fake = connect()

    t.assert_equals({ client:query('select 1') }, { {} })
    t.assert_equals({ client:close() }, { true })
    t.assert_equals(fake.conns[1].closed, true)

    local closed, again = client:close()

    t.assert_equals(closed, false)
    t.assert_equals(again.kind, 'closed')
    t.assert_equals(again.message, 'fake: драйвер уже закрыт')

    local _, err = client:query('select 1')

    t.assert_equals(verdict(err), { kind = 'closed', retriable = false, sent = false })
    t.assert_equals(err.message, 'fake: драйвер закрыт')
end

g.test_close_while_waiting_for_a_conn = function()
    local client = connect(nil, { timeout = 2, pool = { size = 1 } })
    local holder = fiber.new(function()
        client:transaction(function()
            fiber.sleep(0.1)
        end)
    end)

    holder:set_joinable(true)
    fiber.sleep(0.01)

    ---@type any
    local seen = {}
    local waiter = fiber.new(function()
        seen.rows, seen.err = client:query('select 1')
    end)

    waiter:set_joinable(true)
    fiber.sleep(0.01)
    client:close()
    waiter:join()

    local err = seen.err

    t.assert_equals(err.kind, 'closed')
    t.assert_equals(err.message, 'fake: драйвер закрыт')
    holder:join()
end

g.test_a_cancelled_caller_is_not_hidden_in_a_pair = function()
    local client = connect(function()
        return { delay = 1 }
    end)
    local ok, err = helper.cancelled(function()
        return client:query('select 1')
    end)

    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'fiber is cancelled')
    t.assert_equals(client:stats().drops, 1)
    t.assert_equals(client:stats().busy, 0)
end

g.test_stats_carry_no_credentials = function()
    local client = connect()

    client:query('select 1')
    t.assert_not(json.encode(client:stats()):find('secret', 1, true))
    t.assert_equals(client:stats().name, 'fake')
end

g.test_wrong_calls_blame_the_caller = function()
    local client = connect()
    local wrong = helper.wrong

    helper.assert_blamed({
        {
            function()
                client:query(wrong(42))
            end,
            'sql — строка, а не число',
        },
        {
            function()
                client:execute(wrong(nil))
            end,
            'sql — строка, а не nil',
        },
        {
            function()
                client:execute('select 1', nil, { tiemout = 1 })
            end,
            'настройки вызова: ключа «tiemout» нет, есть idempotent, max_rows, timeout',
        },
        {
            function()
                client:query('select 1', nil, { timeout = 0 })
            end,
            'timeout — число секунд больше нуля и меньше бесконечности, а не 0',
        },
        {
            function()
                client:query('select 1', nil, { timeout = 61 })
            end,
            'timeout 61 с длиннее потолка max_timeout 60 с',
        },
        {
            function()
                client:query('select 1', nil, { max_rows = 0 })
            end,
            'max_rows — число больше 0, а не 0',
        },
        {
            function()
                client:query('select $1', { 1 })
            end,
            'params.n — целое число, а не nil',
        },
        {
            function()
                client:query('select $1', { n = 1, {} })
            end,
            'значение table нельзя передать параметром: таблицу оберните json, байты — binary',
        },
    })
end
