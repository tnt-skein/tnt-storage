--- Проверки одного оператора: форма ответа и предел строк, род отказа
--- по живости, коду и словам, решение «вернуть, откатить, выбросить».

local t = require('luatest')

local helper = dofile('test/driver_helper.lua')

local link = helper.link
local statement = helper.statement
local within = helper.within

local g = t.group('tnt.storage.statement')

--- Вызов по умолчанию: выборка, предел в две строки.
---@param extra table|nil
---@return TntStorageCall
local function call(extra)
    local given = { timeout = 0.05, max_rows = 2, shape = statement.ROWS }

    for key, value in pairs(extra or {}) do
        given[key] = value
    end

    return given
end

--- Соединение двойника с ответом `respond`.
---@param respond function|nil
---@param knows_open boolean|nil
---@return TntStorageLink conn
---@return TntStorageFake fake
local function connected(respond, knows_open)
    local fake = helper.rock(respond, nil, knows_open)
    local conn = link.open(fake.rock, 1)

    ---@cast conn TntStorageLink
    return conn, fake
end

--- Итог оператора целиком.
---@param conn TntStorageLink
---@param extra table|nil Вызов поверх умолчаний
---@param deadline number|nil
---@return table
local function run(conn, extra, deadline)
    return helper.pack(statement.run(conn, 'select', { n = 0 }, deadline or within.deadline(1), call(extra)))
end

--- Род и приговор отказа.
---@param err TntStorageFailure
---@return table
local function verdict(err)
    return {
        kind = err.kind,
        sent = err.sent,
        retriable = err.retriable,
        server_code = err.server_code,
        message = err.message,
    }
end

g.test_names = function()
    t.assert_equals(
        { statement.GIVE, statement.ROLLBACK, statement.DROP, statement.ROWS, statement.COUNT },
        { 'give', 'rollback', 'drop', 'rows', 'count' }
    )
end

g.test_rows_up_to_the_limit = function()
    local conn = connected(function()
        return { rows = { { a = 1 }, { a = 2 } } }
    end)

    t.assert_equals(run(conn), { n = 3, { { a = 1 }, { a = 2 } }, nil, 'give' })
end

g.test_rows_over_the_limit_are_an_overflow = function()
    local conn = connected(function()
        return { rows = { { a = 1 }, { a = 2 }, { a = 3 } } }
    end)
    local result = run(conn)

    t.assert_equals(result[1], nil)
    t.assert_equals(result[3], 'give')
    t.assert_equals(verdict(result[2]), {
        kind = 'overflow',
        sent = true,
        retriable = false,
        message = 'строк 3 больше max_rows 2',
    })
end

g.test_no_result_set_is_no_rows = function()
    local conn = connected()

    t.assert_equals(run(conn), { n = 3, {}, nil, 'give' })
end

g.test_count_is_shaped_by_the_rock = function()
    local conn = connected(function(sql)
        if sql == 'select' then
            return { affected = 3 }
        end
    end)

    t.assert_equals(run(conn, { shape = statement.COUNT }), { n = 3, { affected = 3 }, nil, 'give' })
end

g.test_a_broken_conn_is_dropped_whatever_it_raised = function()
    local conn = connected(function()
        return { raise = 'server closed the connection unexpectedly', broken = true }
    end)
    local result = run(conn, { idempotent = true })

    t.assert_equals(result[3], 'drop')
    t.assert_equals(verdict(result[2]), {
        kind = 'broken',
        sent = true,
        retriable = true,
        message = 'fake h:1/app: соединение оборвалось: server closed the connection unexpectedly',
    })
end

g.test_a_refusal_keeps_the_conn = function()
    local conn = connected(function()
        return { raise = helper.server_error('ERROR:  syntax error', '42601') }
    end)
    local result = run(conn, { idempotent = true })

    t.assert_equals(result[3], 'give')
    t.assert_equals(verdict(result[2]), {
        kind = 'rejected',
        sent = true,
        retriable = false,
        server_code = '42601',
        message = 'ERROR:  syntax error',
    })
end

g.test_a_refusal_in_an_open_transaction_is_rolled_back = function()
    local conn = connected(function()
        return {
            raise = helper.server_error('ERROR:  deadlock detected', '40P01'),
            open = true,
        }
    end)
    local result = run(conn)

    t.assert_equals(result[3], 'rollback')
    t.assert_equals(result[2].kind, 'conflict')
end

g.test_a_rock_blind_to_transactions_rolls_back_by_the_mark = function()
    local conn = connected(function()
        return { raise = helper.server_error('Deadlock found when trying to get lock', 1213) }
    end, false)

    t.assert_equals(run(conn)[3], 'give')

    conn.open = true

    local result = run(conn)

    t.assert_equals(result[3], 'rollback')
    t.assert_equals(result[2].kind, 'conflict')
    t.assert_equals(result[2].server_code, 1213)
end

g.test_words_decide_without_a_code = function()
    local conn = connected(function()
        return { raise = '/x/fake/init.lua:57: ERROR:  canceling statement due to statement timeout' }
    end)
    local result = run(conn, { idempotent = true })

    t.assert_equals(result[3], 'give')
    t.assert_equals(verdict(result[2]), {
        kind = 'timeout',
        sent = true,
        retriable = true,
        message = 'ERROR:  canceling statement due to statement timeout',
    })
end

g.test_a_session_the_server_closes_is_dropped = function()
    local conn = connected(function()
        return {
            raise = helper.server_error('FATAL:  terminating connection due to administrator command', '57P01'),
            open = true,
        }
    end)
    local result = run(conn)

    t.assert_equals(result[3], 'drop')
    t.assert_equals(result[2].kind, 'broken')
end

g.test_a_deadline_before_the_rock_keeps_the_conn = function()
    local conn, fake = connected()
    local result = run(conn, { idempotent = true }, within.deadline(0) - 1)

    t.assert_equals(result[3], 'give')
    t.assert_equals(verdict(result[2]), {
        kind = 'timeout',
        sent = false,
        retriable = false,
        message = 'срок вызова вышел до отправки оператора',
    })
    t.assert_equals(#fake.sent, 0)
end

g.test_no_answer_drops_the_conn = function()
    local conn = connected(function()
        return { delay = 1 }
    end)
    local result = run(conn, { idempotent = true }, within.deadline(0.02))

    t.assert_equals(result[3], 'drop')
    t.assert_equals(verdict(result[2]), {
        kind = 'timeout',
        sent = true,
        retriable = true,
        message = 'fake h:1/app: ответа нет за 0.05 с',
    })
end
