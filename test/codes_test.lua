--- Проверки выбора рода: SQLSTATE, errno, первое слово отказа Redis, слова
--- отказа, коды HTTP, признак `sent` и срок у отказа сети HTTP.
---
--- Перечни здесь свои, а не взятые из модуля: проверка, читающая таблицу
--- модуля, согласилась бы с любой её опечаткой.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local codes = helper.codes

local g = t.group('tnt.storage.codes')

--- Сверяет род у каждой пары «аргумент — род».
---@param classify fun(value: any): string
---@param cases table[] Пары: аргумент и ожидаемый род
local function assert_kinds(classify, cases)
    for _, case in ipairs(cases) do
        t.assert_equals(classify(case[1]), case[2], tostring(case[1]))
    end
end

g.test_a_login_code_decides_between_denied_and_unreachable = function()
    assert_kinds(function(code)
        -- Слова отказа нарочно другого рода: код решает один.
        return codes.login(code, 'password authentication failed')
    end, {
        { '28000', 'denied' },
        { '28P01', 'denied' },
        { '3D000', 'denied' },
        { '42501', 'denied' },
        { 1044, 'denied' },
        { 1045, 'denied' },
        { 1049, 'denied' },
        { 1129, 'denied' },
        { 1130, 'denied' },
        { 1251, 'denied' },
        { 1698, 'denied' },
        { 1862, 'denied' },
        { 2059, 'denied' },
        { 3118, 'denied' },
        { '08006', 'unreachable' },
        { '57P03', 'unreachable' },
        { '53300', 'unreachable' },
        { 1040, 'unreachable' },
        { 2002, 'unreachable' },
        { 2003, 'unreachable' },
        { 'WRONGPASS', 'denied' },
        { 'NOAUTH', 'denied' },
        { 'NOPERM', 'denied' },
        { 'DENIED', 'denied' },
        { 'LOADING', 'unreachable' },
        { 'BUSY', 'unreachable' },
        { 'MASTERDOWN', 'unreachable' },
    })
end

g.test_a_login_without_a_code_is_judged_by_its_words = function()
    assert_kinds(function(text)
        return codes.login(nil, text)
    end, {
        { 'FATAL:  password authentication failed for user "probe"', 'denied' },
        { 'FATAL:  database "no_such_db" does not exist', 'denied' },
        { 'FATAL:  no pg_hba.conf entry for host "10.0.0.1"', 'denied' },
        { "Access denied for user 'probe'@'172.17.0.1' (using password: YES)", 'denied' },
        { 'connection to server at "127.0.0.1", port 55433 failed: Connection refused', 'unreachable' },
        { 'вход не завершился за срок', 'unreachable' },
        -- Точка в словах — точка, а не «любой знак».
        { 'FATAL:  no pg_hbaXconf entry for host', 'unreachable' },
        { 'WRONGPASS invalid username-password pair or user is disabled.', 'denied' },
        { 'ERR invalid password', 'denied' },
        {
            'ERR AUTH <password> called without any password configured for the default user. '
                .. 'Are you sure your configuration is correct?',
            'denied',
        },
        { 'ERR Client sent AUTH, but no password is set', 'denied' },
        { 'NOAUTH Authentication required.', 'denied' },
        { "NOPERM User app has no permissions to run the 'select' command", 'denied' },
        { 'DENIED Redis is running in protected mode because protected mode is enabled', 'denied' },
        { 'ERR DB index is out of range', 'denied' },
        { 'ERR max number of clients reached', 'unreachable' },
        { 'LOADING Redis is loading the dataset in memory', 'unreachable' },
    })
end

g.test_a_statement_code_decides_its_kind = function()
    assert_kinds(function(code)
        -- Слова отказа нарочно другого рода: код решает один.
        return codes.statement(code, 'deadlock detected')
    end, {
        { '40001', 'conflict' },
        { '40P01', 'conflict' },
        { '55P03', 'conflict' },
        { '57014', 'timeout' },
        { '57P01', 'broken' },
        { '57P02', 'broken' },
        { '57P03', 'broken' },
        { '57P04', 'broken' },
        { '57P05', 'broken' },
        { '25P03', 'broken' },
        { '25P04', 'broken' },
        { '08000', 'broken' },
        { '08003', 'broken' },
        { '08006', 'broken' },
        { '08P01', 'broken' },
        { '23505', 'rejected' },
        { '42601', 'rejected' },
        { '22012', 'rejected' },
        { '25P02', 'rejected' },
        { '40002', 'rejected' },
        { 'X0800', 'rejected' },
        { '0A000', 'rejected' },
        { 1205, 'conflict' },
        { 1213, 'conflict' },
        { 3572, 'conflict' },
        { 3024, 'timeout' },
        { 1053, 'broken' },
        { 1927, 'broken' },
        { 2006, 'broken' },
        { 2013, 'broken' },
        { 2055, 'broken' },
        { 4031, 'broken' },
        { 1062, 'rejected' },
        { 1064, 'rejected' },
        { 1317, 'rejected' },
        { 8, 'rejected' },
        { 'NOAUTH', 'denied' },
        { 'WRONGPASS', 'denied' },
        { 'NOPERM', 'denied' },
        { 'DENIED', 'denied' },
        { 'BUSY', 'busy' },
        { 'LOADING', 'busy' },
        { 'MASTERDOWN', 'busy' },
        { 'READONLY', 'busy' },
        { 'TRYAGAIN', 'busy' },
        { 'CLUSTERDOWN', 'busy' },
        { 'NOREPLICAS', 'busy' },
        { 'WRONGTYPE', 'rejected' },
        { 'NOSCRIPT', 'rejected' },
        { 'MOVED', 'rejected' },
        { 'OOM', 'rejected' },
        { 'MISCONF', 'rejected' },
        { 'EXECABORT', 'rejected' },
    })
end

g.test_a_statement_without_a_code_is_judged_by_its_words = function()
    assert_kinds(function(text)
        return codes.statement(nil, text)
    end, {
        { 'ERROR:  could not serialize access due to read/write dependencies among transactions', 'conflict' },
        { 'ERROR:  deadlock detected', 'conflict' },
        { 'ERROR:  canceling statement due to lock timeout', 'conflict' },
        { 'Deadlock found when trying to get lock; try restarting transaction', 'conflict' },
        { 'Lock wait timeout exceeded; try restarting transaction', 'conflict' },
        { 'ERROR:  canceling statement due to statement timeout', 'timeout' },
        { 'Query execution was interrupted, maximum statement execution time exceeded', 'timeout' },
        { 'server closed the connection unexpectedly', 'broken' },
        { 'FATAL:  terminating connection due to administrator command', 'broken' },
        { 'Lost connection to MySQL server during query', 'broken' },
        { 'MySQL server has gone away', 'broken' },
        { 'ERROR:  syntax error at or near "selec"', 'rejected' },
        { 'ERROR:  canceling statement due to user request', 'rejected' },
        { '', 'rejected' },
    })
end

g.test_a_status_of_http_decides_its_kind = function()
    assert_kinds(codes.status, {
        { 401, 'denied' },
        { 403, 'denied' },
        { 409, 'conflict' },
        { 412, 'conflict' },
        { 429, 'busy' },
        { 503, 'busy' },
        { 400, 'rejected' },
        { 402, 'rejected' },
        { 404, 'rejected' },
        { 499, 'rejected' },
        { 500, 'broken' },
        { 502, 'broken' },
        { 504, 'broken' },
        { 599, 'broken' },
        { 302, 'rejected' },
    })
end

g.test_a_network_failure_of_http_is_judged_by_the_sent_mark = function()
    -- Тексты — как их отдаёт `http.client` Tarantool 3.8 на libcurl 8.11
    -- статической сборки для Linux: код 595 у имени и соединения, 444
    -- у пустого ответа, прочее — бросок `curl: …` с errno в конце. Ушёл ли
    -- запрос, решает признак `sent` `tnt-http`, а не слова.
    local timeout = 'GET http://os/: сервер не ответил: Timeout was reached (код 408)'
    local refused = 'PUT http://os/: сервер не ответил: Could not connect to server (код 595)'
    local reset = 'PUT http://os/: libcurl отказал: curl: Failure when receiving data from the peer: '
        .. 'Connection reset by peer'

    -- Тройки: текст, признак `sent`, род.
    local cases = {
        -- Не ушло — `unreachable`, как бы libcurl ни назвал отказ: и срок,
        -- и бросок.
        { refused, false, 'unreachable' },
        { timeout, false, 'unreachable' },
        { reset, false, 'unreachable' },
        -- Могло уйти: срок — `timeout`, признак `true` либо пустой.
        { timeout, true, 'timeout' },
        { timeout, nil, 'timeout' },
        -- Слова отказа до отправки без признака ничего не решают: список их
        -- ведёт `tnt-http`, своего здесь нет.
        { refused, true, 'broken' },
        { refused, nil, 'broken' },
        { "GET http://os/: сервер не ответил: Couldn't resolve host name (код 595)", nil, 'broken' },
        { 'PUT https://os/: libcurl отказал: curl: SSL connect error: Invalid argument', nil, 'broken' },
        -- Сервер запрос прочитал: пустой ответ, сброс, оборванное тело,
        -- негодное сжатие.
        {
            'PUT http://os/: сервер не ответил: Server returned nothing (no headers, no data) (код 444)',
            true,
            'broken',
        },
        { reset, true, 'broken' },
        { 'PUT http://os/: libcurl отказал: curl: Transferred a partial file: Invalid argument', nil, 'broken' },
        {
            'PUT http://os/: сервер не ответил: Unrecognized or bad HTTP Content or Transfer-Encoding (код 595)',
            nil,
            'broken',
        },
        -- Признак не той породы — не `false`, и запрос мог уйти.
        { refused, 'false', 'broken' },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(codes.network(case[1], case[2]), case[3], ('%s; sent = %s'):format(case[1], tostring(case[2])))
    end
end

g.test_a_mongo_code_decides_its_kind = function()
    assert_kinds(function(code)
        return codes.mongo(code)
    end, {
        { 112, 'conflict' },
        { 24, 'conflict' },
        { 251, 'conflict' },
        { 50, 'timeout' },
        { 262, 'timeout' },
        { 64, 'timeout' },
        { 13, 'denied' },
        { 10107, 'busy' },
        { 13435, 'busy' },
        { 13436, 'busy' },
        { 91, 'broken' },
        { 189, 'broken' },
        { 11600, 'broken' },
        { 11602, 'broken' },
        { 6, 'broken' },
        { 7, 'broken' },
        { 89, 'broken' },
        { 9001, 'broken' },
        -- Дубликат ключа, негодное значение, нет коллекции — отказ данных.
        { 11000, 'rejected' },
        { 2, 'rejected' },
        { 26, 'rejected' },
        -- Числа errno MySQL у MongoDB значат иное: таблицы не смешиваются.
        { 1213, 'rejected' },
        { 1045, 'rejected' },
        { 18, 'rejected' },
    })
    t.assert_equals(codes.mongo(nil), 'rejected')
    t.assert_equals(codes.mongo(nil, {}), 'rejected')
end

g.test_a_transient_label_is_a_conflict_whatever_the_code = function()
    t.assert_equals(codes.mongo(11000, { 'RetryableWriteError', 'TransientTransactionError' }), 'conflict')
    t.assert_equals(codes.mongo(10107, { 'RetryableWriteError' }), 'busy')
    t.assert_equals(codes.mongo(nil, { 'TransientTransactionError' }), 'conflict')
end

g.test_a_mongo_login_code_decides_between_denied_and_unreachable = function()
    assert_kinds(codes.mongo_login, {
        { 11, 'denied' },
        { 13, 'denied' },
        { 18, 'denied' },
        { 334, 'denied' },
        { 59, 'unreachable' },
        { 1045, 'unreachable' },
        { '28P01', 'unreachable' },
    })
    t.assert_equals(codes.mongo_login(nil), 'unreachable')
end
