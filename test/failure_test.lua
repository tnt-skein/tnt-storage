--- Проверки отказа: роды, приговор повтору, текст без тайн, вид строкой.

local json = require('json')
local t = require('luatest')

---@type any
local box_error = box.error

local helper = dofile('test/helper.lua')

local failure = helper.failure

local g = t.group('tnt.storage.failure')

--- Отказ по названию рода — для проверок, где текст не важен.
---@param kind string
---@param opts table|nil
---@return TntStorageFailure
local function made(kind, opts)
    return failure.new(kind, 'текст', opts)
end

--- Род, `sent`, приговор без согласия и с согласием на повтор.
---@param err TntStorageFailure
---@return table
local function verdict_of(err)
    return { err.kind, err.sent, err.retriable }
end

g.test_the_nine_kinds_are_named_by_constants = function()
    t.assert_equals({
        failure.UNREACHABLE,
        failure.DENIED,
        failure.BUSY,
        failure.TIMEOUT,
        failure.BROKEN,
        failure.REJECTED,
        failure.CONFLICT,
        failure.CLOSED,
        failure.OVERFLOW,
    }, { 'unreachable', 'denied', 'busy', 'timeout', 'broken', 'rejected', 'conflict', 'closed', 'overflow' })
end

g.test_each_kind_has_its_place_and_verdict_by_the_contract = function()
    -- Род, дошёл ли оператор, повтор без согласия, повтор с согласием.
    local expected = {
        { 'unreachable', false, true, true },
        { 'denied', false, false, false },
        { 'busy', false, true, true },
        { 'timeout', true, false, true },
        { 'broken', true, false, true },
        { 'rejected', true, false, false },
        { 'conflict', true, false, false },
        { 'closed', false, false, false },
        { 'overflow', true, false, false },
    }

    for _, case in ipairs(expected) do
        local kind = case[1]

        t.assert_equals(verdict_of(made(kind)), { kind, case[2], case[3] }, kind)
        t.assert_equals(verdict_of(made(kind, { idempotent = true })), { kind, case[2], case[4] }, kind)
        t.assert_equals(made(kind, { idempotent = false }).retriable, case[3], kind)
    end
end

g.test_a_timeout_before_sending_is_not_repeated_even_with_consent = function()
    -- Срок, вышедший до отправки: повторять уже некогда.
    t.assert_equals(verdict_of(made('timeout', { sent = false, idempotent = true })), { 'timeout', false, false })
    t.assert_equals(verdict_of(made('broken', { sent = false, idempotent = true })), { 'broken', false, false })
end

g.test_the_place_and_the_verdict_can_be_given_by_the_driver = function()
    t.assert_equals(verdict_of(made('rejected', { sent = false })), { 'rejected', false, false })
    t.assert_equals(verdict_of(made('unreachable', { sent = true })), { 'unreachable', true, true })
    t.assert_equals(verdict_of(made('rejected', { retriable = true })), { 'rejected', true, true })
    t.assert_equals(verdict_of(made('busy', { retriable = false })), { 'busy', false, false })
    t.assert_equals(verdict_of(made('timeout', { retriable = true })), { 'timeout', true, true })
end

g.test_the_server_code_is_kept_as_given = function()
    t.assert_equals(made('conflict', { server_code = '40001' }).server_code, '40001')
    t.assert_equals(made('conflict', { server_code = 1213 }).server_code, 1213)
    t.assert_equals(made('conflict').server_code, nil)
end

g.test_the_message_is_scrubbed_of_secrets = function()
    local err = failure.new(
        'unreachable',
        'вход в postgres://probe:hunter2@db:5432/app не удался; password=hunter2'
    )

    t.assert_not_str_contains(err.message, 'hunter2')
    t.assert_not_str_contains(err.reason, 'hunter2')
    t.assert_not_str_contains(json.encode({ err = err }), 'hunter2')
    t.assert_str_contains(err.message, 'postgres://probe:')
end

g.test_the_reason_is_the_first_line_of_the_message = function()
    -- DETAIL у PostgreSQL несёт значения строки: в журнал идёт только первая.
    local text = 'ERROR:  duplicate key value violates unique constraint "t_pkey"\n'
        .. 'DETAIL:  Key (id)=(1) already exists.\n'
    local err = failure.new('rejected', text)

    t.assert_equals(err.message, text)
    t.assert_equals(err.reason, 'ERROR:  duplicate key value violates unique constraint "t_pkey"')
end

g.test_a_reason_given_apart_replaces_the_message_in_the_journal = function()
    local err = failure.new('unreachable', 'GET http://s3/b?X-Amz-Signature=abc: сервер не ответил', {
        reason = 'сервер не ответил: Could not connect to server\nвторая строка; password=hunter2',
    })

    t.assert_equals(err.message, 'GET http://s3/b?X-Amz-Signature=abc: сервер не ответил')
    t.assert_equals(err.reason, 'сервер не ответил: Could not connect to server')

    local scrubbed = failure.new('unreachable', 'текст', { reason = 'password=hunter2' })

    t.assert_not_str_contains(scrubbed.reason, 'hunter2')
end

g.test_an_empty_message_gives_an_empty_reason = function()
    t.assert_equals({ failure.new('closed', '').message, failure.new('closed', '').reason }, { '', '' })
end

g.test_a_failure_reads_as_its_text_everywhere = function()
    local err = failure.new('closed', 'драйвер закрыт')

    t.assert_equals(tostring(err), 'драйвер закрыт')
    t.assert_equals(json.encode({ err = err }), json.encode({ err = 'драйвер закрыт' }))
    t.assert_equals('причина: ' .. err, 'причина: драйвер закрыт')
    t.assert_equals(err .. '.', 'драйвер закрыт.')
    t.assert_equals(('%s'):format(err), 'драйвер закрыт')
end

g.test_a_failure_is_told_from_other_tables = function()
    t.assert_equals(failure.is(made('closed')), true)
    t.assert_equals(failure.is({ kind = 'closed', message = 'текст' }), false)
    t.assert_equals(failure.is('драйвер закрыт'), false)
    t.assert_equals(failure.is(nil), false)
end

g.test_a_programmer_error_is_raised_at_the_callers_line = function()
    -- Не хвостовым вызовом: у хвостового кадра нет, и уровню 2 некуда указать.
    local function driver_fail()
        return (failure.new('lost', 'x', nil, 2))
    end

    helper.assert_blamed({
        {
            function()
                failure.new('lost', 'x')
            end,
            'род отказа lost незнаком: есть unreachable, denied, busy, timeout, broken, rejected, '
                .. 'conflict, closed, overflow',
        },
        {
            function()
                failure.new(helper.wrong(nil), 'x')
            end,
            'род отказа nil незнаком: есть unreachable, denied, busy, timeout, broken, rejected, '
                .. 'conflict, closed, overflow',
        },
        {
            function()
                driver_fail()
            end,
            'род отказа lost незнаком: есть unreachable, denied, busy, timeout, broken, rejected, '
                .. 'conflict, closed, overflow',
        },
        {
            function()
                failure.new('closed', helper.wrong(42))
            end,
            'текст отказа — строка, а не число',
        },
        {
            function()
                failure.new('closed', 'x', { retry = true })
            end,
            'настройки отказа: ключа «retry» нет, есть idempotent, reason, retriable, sent, server_code',
        },
        {
            function()
                failure.new('closed', 'x', { server_code = 1.5 })
            end,
            'настройки отказа.server_code — строка или целое число, а не 1.5',
        },
    })
end

g.test_the_text_of_a_rock_loses_the_place_only_at_its_start = function()
    local expected = {
        { '/usr/share/tarantool/pg/init.lua:129: ERROR:  syntax error', 'ERROR:  syntax error' },
        { 'init.lua:5: Connection is not usable', 'Connection is not usable' },
        { 'a.lua:1: b.lua:2: c', 'b.lua:2: c' },
        { 'ошибка в app.lua:5: слово', 'ошибка в app.lua:5: слово' },
        { 'init.lua: без номера', 'init.lua: без номера' },
        { 'init.lua:: пустой номер', 'init.lua:: пустой номер' },
        { '.lua:5: без имени', 'без имени' },
        { 'init.lua:5:без пробела', 'init.lua:5:без пробела' },
        { 'просто текст', 'просто текст' },
    }

    for _, case in ipairs(expected) do
        t.assert_equals(failure.text(case[1]), case[2], case[1])
    end

    t.assert_equals(
        failure.text(box_error.new({ reason = 'fiber is cancelled', type = 'FiberIsCancelled' })),
        'fiber is cancelled'
    )
    t.assert_equals(failure.text(42), '42')
end

g.test_a_login_failure_is_denied_or_unreachable_before_sending = function()
    local denied =
        failure.login('/usr/share/tarantool/pg/init.lua:12: FATAL:  password authentication failed for user "probe"')
    local refused = failure.login('connection to server at "127.0.0.1", port 55433 failed: Connection refused', nil)
    local coded = failure.login('Access denied for user', 1045)
    local network = failure.login("Can't connect to MySQL server on '127.0.0.1' (36)", 2003)

    t.assert_equals(
        { denied.kind, denied.sent, denied.retriable, denied.server_code, denied.message },
        { 'denied', false, false, nil, 'FATAL:  password authentication failed for user "probe"' }
    )
    t.assert_equals({ refused.kind, refused.sent, refused.retriable }, { 'unreachable', false, true })
    t.assert_equals({ coded.kind, coded.server_code }, { 'denied', 1045 })
    t.assert_equals({ network.kind, network.retriable, network.server_code }, { 'unreachable', true, 2003 })
end

g.test_a_statement_failure_is_after_sending_and_repeats_only_with_consent = function()
    local conflict = failure.statement('ERROR:  could not serialize access', '40001', { idempotent = true })
    local timeout = failure.statement('init.lua:3: ERROR:  canceling statement due to statement timeout', '57014')
    local again = failure.statement('Query execution was interrupted', 3024, { idempotent = true })
    local syntax = failure.statement('You have an error in your SQL syntax', 1064)

    t.assert_equals(
        { conflict.kind, conflict.sent, conflict.retriable, conflict.server_code },
        { 'conflict', true, false, '40001' }
    )
    t.assert_equals(
        { timeout.kind, timeout.sent, timeout.retriable, timeout.message },
        { 'timeout', true, false, 'ERROR:  canceling statement due to statement timeout' }
    )
    t.assert_equals({ again.kind, again.retriable, again.server_code }, { 'timeout', true, 3024 })
    t.assert_equals({ syntax.kind, syntax.retriable, syntax.server_code }, { 'rejected', false, 1064 })
    t.assert_equals(failure.statement('ERROR:  deadlock detected').kind, 'conflict')
end

g.test_a_status_of_http_becomes_a_kind_of_storage = function()
    local forbidden = failure.status(403, 'PUT /b/k: сервер ответил 403 Forbidden')
    local busy = failure.status(503, 'GET /i/_search: сервер ответил 503')
    local broken = failure.status(500, 'POST /i/_doc: сервер ответил 500', { idempotent = true })
    local gone = failure.status(502, 'POST /i/_doc: сервер ответил 502')

    t.assert_equals(
        { forbidden.kind, forbidden.sent, forbidden.retriable, forbidden.server_code, forbidden.message },
        { 'denied', false, false, 403, 'PUT /b/k: сервер ответил 403 Forbidden' }
    )
    t.assert_equals({ busy.kind, busy.sent, busy.retriable }, { 'busy', false, true })
    t.assert_equals({ broken.kind, broken.sent, broken.retriable }, { 'broken', true, true })
    t.assert_equals({ gone.kind, gone.retriable }, { 'broken', false })
end

g.test_a_failure_of_the_http_client_becomes_a_kind_of_storage = function()
    local cases = {
        {
            {
                kind = 'status',
                status = 409,
                message = 'PUT http://s3/b: сервер ответил 409',
                reason = 'сервер ответил 409',
            },
            { 'conflict', true, false, 409, 'сервер ответил 409' },
        },
        {
            {
                kind = 'unreachable',
                message = 'GET http://os/: сервер не ответил: Timeout was reached (код 408)',
            },
            {
                'timeout',
                true,
                false,
                nil,
                'GET http://os/: сервер не ответил: Timeout was reached (код 408)',
            },
        },
        {
            -- Не ушло: так решил `tnt-http`, и слова тут ни при чём.
            {
                kind = 'unreachable',
                sent = false,
                message = 'GET http://os/: сервер не ответил: Could not connect to server (код 595)',
                reason = 'сервер не ответил: Could not connect to server (код 595)',
            },
            {
                'unreachable',
                false,
                true,
                nil,
                'сервер не ответил: Could not connect to server (код 595)',
            },
        },
        {
            -- Таблица без признака могла уйти, какие бы слова в ней ни стояли.
            {
                kind = 'unreachable',
                message = 'GET http://os/: сервер не ответил: Could not connect to server (код 595)',
            },
            {
                'broken',
                true,
                false,
                nil,
                'GET http://os/: сервер не ответил: Could not connect to server (код 595)',
            },
        },
        {
            {
                kind = 'unreachable',
                sent = true,
                message = 'PUT http://os/: сервер не ответил: Timeout was reached (код 408)',
            },
            {
                'timeout',
                true,
                false,
                nil,
                'PUT http://os/: сервер не ответил: Timeout was reached (код 408)',
            },
        },
        {
            {
                kind = 'unreachable',
                message = 'GET http://os/: сервер не ответил: Server returned nothing (no headers, no data) (код 444)',
            },
            {
                'broken',
                true,
                false,
                nil,
                'GET http://os/: сервер не ответил: Server returned nothing (no headers, no data) (код 444)',
            },
        },
        {
            -- Сервер прочитал запрос и сбросил соединение: libcurl бросает,
            -- и бросок — «могло уйти», как бы его ни назвал клиент.
            {
                kind = 'unreachable',
                sent = true,
                message = 'PUT http://os/: libcurl отказал: curl: Failure when receiving data from the peer',
                reason = 'libcurl отказал: curl: Failure when receiving data from the peer',
            },
            { 'broken', true, false, nil, 'libcurl отказал: curl: Failure when receiving data from the peer' },
        },
        {
            { kind = 'idle', message = 'GET http://os/: за 1 с кусок не собрался' },
            { 'timeout', true, false, nil, 'GET http://os/: за 1 с кусок не собрался' },
        },
        {
            { kind = 'invalid', message = 'адрес без схемы' },
            { 'rejected', false, false, nil, 'адрес без схемы' },
        },
        {
            { kind = 'refused', message = 'GET http://os/: ответ больше предела' },
            { 'rejected', true, false, nil, 'GET http://os/: ответ больше предела' },
        },
        {
            { kind = 'странный', message = 'что-то' },
            { 'broken', true, false, nil, 'что-то' },
        },
    }

    for _, case in ipairs(cases) do
        local err = failure.http(case[1])

        t.assert_equals({ err.kind, err.sent, err.retriable, err.server_code, err.reason }, case[2], case[1].message)
    end

    local consented = failure.http({ kind = 'status', status = 502, message = 'сервер ответил 502' }, {
        idempotent = true,
    })

    t.assert_equals(
        { consented.kind, consented.retriable, consented.message },
        { 'broken', true, 'сервер ответил 502' }
    )

    local reset = failure.http({
        kind = 'unreachable',
        message = 'PUT http://os/: libcurl отказал: curl: Transferred a partial file: Invalid argument',
    }, { idempotent = true })

    t.assert_equals({ reset.kind, reset.sent, reset.retriable }, { 'broken', true, true })
end

g.test_the_translators_blame_the_callers_line = function()
    helper.assert_blamed({
        {
            function()
                failure.statement('x', nil, { idempotnet = true })
            end,
            'настройки вызова: ключа «idempotnet» нет, есть idempotent',
        },
        {
            function()
                failure.login('x', helper.wrong(1.5))
            end,
            'настройки отказа.server_code — строка или целое число, а не 1.5',
        },
        {
            function()
                failure.statement('x', helper.wrong(true))
            end,
            'настройки отказа.server_code — строка или целое число, а не true',
        },
        {
            function()
                failure.status(helper.wrong('503'), 'x')
            end,
            'код ответа — целое число, а не строка',
        },
        {
            function()
                failure.status(503, helper.wrong(nil))
            end,
            'текст отказа — строка, а не nil',
        },
        {
            function()
                failure.status(503, 'x', { idempotnet = true })
            end,
            'настройки вызова: ключа «idempotnet» нет, есть idempotent',
        },
        {
            function()
                failure.http(helper.wrong('сеть пропала'))
            end,
            'отказ tnt-http — таблица, а не строка',
        },
        {
            function()
                failure.http({ kind = 'idle', message = 'x' }, { idempotnet = true })
            end,
            'настройки вызова: ключа «idempotnet» нет, есть idempotent',
        },
        {
            function()
                failure.http({ kind = 'idle', message = 'x', reason = helper.wrong(7) })
            end,
            'настройки отказа.reason — строка, а не число',
        },
    })
end
