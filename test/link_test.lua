--- Проверки соединения над роком: рок по имени, вход в срок, закрытие
--- выходом работника, живость и сброс без сети, отметка открытой
--- транзакции, оператор в работнике.

local fiber = require('fiber')
local t = require('luatest')

local helper = dofile('test/driver_helper.lua')

local link = helper.link
local within = helper.within

local g = t.group('tnt.storage.link')

g.after_each(function()
    helper.restore()

    if g.journal ~= nil then
        g.journal.release()
        g.journal = nil
    end
end)

--- Соединение двойника.
---@param respond function|nil
---@param knows_open boolean|nil
---@return TntStorageLink conn
---@return table fake Двойник: проверки читают его поля, не сверяя с пустотой
local function connected(respond, knows_open)
    local fake = helper.rock(respond, nil, knows_open)
    local conn = link.open(fake.rock, 1)

    ---@cast conn TntStorageLink
    return conn, fake
end

g.test_the_rock_is_required_by_name = function()
    local found = {}

    link._set_source({
        require = function(name)
            if name == 'fake' then
                return found
            end

            return nil, "module '" .. name .. "' not found:\n\tno field package.preload"
        end,
    })

    t.assert_is(link.require('fake', 'поставьте', 1), found)

    helper.assert_blamed({
        {
            function()
                link.require('lost', 'поставьте рок — make deps', 1)
            end,
            "рок lost не установлен (module 'lost' not found:): поставьте рок — make deps",
        },
    })
end

g.test_the_default_source_requires_the_module = function()
    t.assert_is(link.require('fiber', '', 1), fiber)

    -- В отказ идёт первая строка, даже пустая: список путей поиска длинный,
    -- а суть — в начале.
    package.preload['tnt_storage_link_missing'] = function()
        error('\nerror loading module', 0)
    end

    local ok, err = pcall(link.require, 'tnt_storage_link_missing', 'поставьте', -1)

    package.preload['tnt_storage_link_missing'] = nil
    t.assert_equals(ok, false)
    t.assert_equals(err, 'рок tnt_storage_link_missing не установлен (): поставьте')
end

g.test_shut_closes_even_a_broken_conn = function()
    local closed = {}
    local healthy = {
        close = function()
            closed.conn = true
        end,
        conn = {
            close = function()
                closed.driver = true
            end,
        },
    }

    link.shut(healthy)
    t.assert_equals(closed, { conn = true })

    -- На оборванном соединении `close()` рока бросает: закрывает
    -- объект драйвера.
    closed = {}
    healthy.close = function()
        error('Connection is broken', 0)
    end
    link.shut(healthy)
    t.assert_equals(closed, { driver = true })

    -- И объект драйвера бросить не должен уронить того, кто выбрасывает.
    healthy.conn.close = function()
        error('Driver fatal error', 0)
    end
    link.shut(healthy)
end

g.test_execute_passes_the_values_after_the_text = function()
    ---@type table
    local got = {}
    local conn = {
        execute = function(self, sql, ...)
            got = { self = self, sql = sql, args = helper.pack(...) }

            return { { { a = 1 } } }, true, 3
        end,
    }

    t.assert_equals(helper.pack(link.execute(conn, 'select ?, ?, ?', { n = 3, 1, nil, box.NULL })), {
        n = 3,
        { { { a = 1 } } },
        true,
        3,
    })
    t.assert_is(got.self, conn)
    t.assert_equals(got.sql, 'select ?, ?, ?')
    t.assert_equals(got.args, { n = 3, 1, nil, box.NULL })
    t.assert_equals(helper.pack(link.execute(conn, 'select 1', { n = 0 })).n, 3)
    t.assert_equals(got.args, { n = 0 })
end

g.test_open_hands_over_the_conn = function()
    local conn, fake = connected()

    t.assert_is(conn.rock, fake.rock)
    t.assert_is(conn.conn, fake.conns[1])
    t.assert_equals(conn.working, false)
    t.assert_equals(conn.doomed, false)
    t.assert_equals(conn.open, false)
end

g.test_a_refused_login_is_classified_by_code_and_words = function()
    local fake = helper.rock(nil, function(number)
        if number == 1 then
            return { raise = '/x/fake/init.lua:12: FATAL:  password authentication failed for user "app"' }
        end

        return { raise = helper.server_error('Unknown MySQL server host', 2005) }
    end)
    local conn, err = link.open(fake.rock, 1)

    t.assert_equals(conn, nil)
    t.assert_equals(err.kind, 'denied')
    t.assert_equals(err.retriable, false)
    t.assert_equals(
        err.message,
        'fake h:1/app: вход не удался: FATAL:  password authentication failed for user "app"'
    )

    local _, coded = link.open(fake.rock, 1)

    t.assert_equals(coded.kind, 'unreachable')
    t.assert_equals(coded.server_code, 2005)
end

g.test_a_login_past_its_deadline_is_closed_where_it_appeared = function()
    local fake = helper.rock(nil, function()
        return { delay = 0.05 }
    end)
    local conn, err = link.open(fake.rock, 0.01)

    t.assert_equals(conn, nil)
    t.assert_equals(err.kind, 'unreachable')
    t.assert_equals(err.message, 'fake h:1/app: вход не завершился за 0.01 с')

    -- Работник отменён посреди сна двойника: входа не будет вовсе.
    fiber.sleep(0.08)
    t.assert_equals(#fake.conns, 0)
end

g.test_a_late_login_that_ignored_the_cancel_is_closed = function()
    local fake = helper.rock(nil, function()
        -- Вход, который отмены не слышит: рок в C не уступает до конца.
        local started = fiber.clock()

        while fiber.clock() - started < 0.05 do
            pcall(fiber.sleep, 0.01)
        end

        return {}
    end)
    local conn = link.open(fake.rock, 0.01)

    t.assert_equals(conn, nil)
    fiber.sleep(0.1)
    t.assert_equals(#fake.conns, 1)
    t.assert_equals(fake.conns[1].closed, true)
end

g.test_close_waits_for_the_worker_inside_the_rock = function()
    local conn, fake = connected(function()
        return { delay = 0.05 }
    end)
    local status

    fiber.create(function()
        status = link.run(conn, within.deadline(1), 'select 1', { n = 0 })
    end)
    fiber.sleep(0.01)
    t.assert_equals(conn.working, true)

    link.close(conn)
    t.assert_equals(conn.doomed, true)
    t.assert_equals(fake.conns[1].closed, false)

    fiber.sleep(0.08)
    t.assert_equals(status, within.RETURNED)
    t.assert_equals(conn.working, false)
    t.assert_equals(fake.conns[1].closed, true)
end

g.test_close_of_an_idle_conn = function()
    local conn, fake = connected()

    link.close(conn)
    t.assert_equals(fake.conns[1].closed, true)
end

g.test_state_alive_and_reset_ask_no_network = function()
    g.journal = helper.capture_log()

    local conn, fake = connected()

    t.assert_equals({ link.state(conn) }, { true, false })
    t.assert_equals(link.alive(conn), true)
    t.assert_equals(link.reset(conn, 'orders', helper.log), true)
    t.assert_not(g.journal.logged('открытой транзакцией'))

    fake.conns[1].open = true
    t.assert_equals({ link.state(conn) }, { true, true })
    t.assert_equals(conn.open, true)
    t.assert_equals(link.reset(conn, 'orders', helper.log), false)

    local record = g.journal.find(
        'WARN [tnt.fake] соединение вернулось с открытой транзакцией'
    )

    t.assert_equals(record.record.fields, { driver = 'orders' })

    -- Рок сказал, что транзакция закрыта: отметка фасада поправлена.
    fake.conns[1].open = false
    t.assert_equals({ link.state(conn) }, { true, false })
    t.assert_equals(conn.open, false)

    fake.conns[1].alive = false
    t.assert_equals(helper.pack(link.state(conn)), { n = 1, false })
    t.assert_equals(link.alive(conn), false)
    t.assert_equals(link.reset(conn, 'orders', helper.log), false)
    t.assert_equals(#fake.sent, 0)
end

g.test_a_rock_blind_to_transactions_trusts_the_mark = function()
    local conn = connected(nil, false)

    t.assert_equals({ link.state(conn) }, { true, false })

    conn.open = true
    t.assert_equals({ link.state(conn) }, { true, true })
    t.assert_equals(link.reset(conn, 'orders', helper.log), false)

    conn.open = false
    t.assert_equals(link.reset(conn, 'orders', helper.log), true)
end

g.test_run_returns_what_the_rock_returned = function()
    local conn, fake = connected(function(_, args)
        return { rows = { { a = args[1], b = args[3] } }, affected = 1 }
    end)
    local result = helper.pack(link.run(conn, within.deadline(1), 'select $1, $2, $3', { n = 3, 1, nil, 3 }))

    t.assert_equals(result, { n = 4, within.RETURNED, { { { a = 1, b = 3 } } }, true, 1 })
    t.assert_equals(fake.sent[1].args, { n = 3, 1, nil, 3 })
    t.assert_equals(fake.sent[1].sql, 'select $1, $2, $3')
end

g.test_run_hands_over_what_the_rock_raised = function()
    local raised = helper.server_error('ERROR:  boom', '40001')
    local conn = connected(function()
        return { raise = raised }
    end)
    local status, err = link.run(conn, within.deadline(1), 'select 1', { n = 0 })

    t.assert_equals(status, within.RAISED)
    t.assert_is(err, raised)
    t.assert_equals(conn.working, false)
end

g.test_run_past_the_deadline = function()
    local conn, fake = connected(function()
        return { delay = 1 }
    end)

    t.assert_equals(link.run(conn, within.deadline(0.02), 'select 1', { n = 0 }), within.EXPIRED)
    t.assert_equals(link.run(conn, within.deadline(0) - 1, 'select 1', { n = 0 }), within.SKIPPED)
    t.assert_equals(#fake.sent, 1)
end
