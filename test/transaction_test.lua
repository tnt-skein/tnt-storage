--- Проверки транзакции: итог тела — фиксация, откат либо исключение
--- дальше; первый отказ оператора помечает транзакцию; соединение
--- с недочитанным ответом выбрасывается без отката; повтор всей транзакции
--- по конфликту; ошибки программиста — исключения на строке вызывающего.

local fiber = require('fiber')
local t = require('luatest')

local helper = dofile('test/driver_helper.lua')

local failure = helper.failure

local g = t.group('tnt.storage.transaction')

local connect = helper.suite(g)

--- Отказ сервера с кодом, как его бросает рок, который код отдаёт.
local server_error = helper.server_error

g.test_a_body_without_return_commits = function()
    local client, fake = connect()
    local done, err = client:transaction(function(tx)
        tx:execute('insert', { n = 1, 1 })
    end)

    t.assert_equals({ done, err }, { true, nil })
    t.assert_equals(helper.statements(fake), { 'BEGIN', 'insert', 'COMMIT' })
    t.assert_equals(client:stats().idle, 1)
    t.assert_equals(fake.conns[1].open, false)
end

g.test_a_value_is_committed_and_returned = function()
    local client, fake = connect(function(text)
        if text == 'select' then
            return { rows = { { id = 7 } }, affected = 1 }
        end
    end)
    local done = client:transaction(function(tx)
        local rows = tx:query('select')
        local counted = tx:execute('select')

        return { rows = rows, counted = counted }
    end)

    t.assert_equals(done, { rows = { { id = 7 } }, counted = { affected = 1 } })
    t.assert_equals(helper.statements(fake), { 'BEGIN', 'select', 'select', 'COMMIT' })

    -- Служебным операторам и оператору без параметров рок не получает
    -- ни одного аргумента.
    for _, entry in ipairs(fake.sent) do
        t.assert_equals(entry.args, { n = 0 })
    end
end

g.test_a_refusal_of_the_body_rolls_back = function()
    local client, fake = connect()

    t.assert_equals(
        { client:transaction(function()
            return nil, 'передумали'
        end) },
        { nil, 'передумали' }
    )
    t.assert_equals(helper.statements(fake), { 'BEGIN', 'ROLLBACK' })
    t.assert_equals(client:stats().idle, 1)

    local _, err = client:transaction(function()
        return false
    end)

    t.assert_equals(err.kind, 'rejected')
    t.assert_equals(err.message, 'тело отменило транзакцию')

    local _, silent = client:transaction(function()
        return nil
    end)

    t.assert_equals(silent.message, 'тело отменило транзакцию')
    t.assert_equals(helper.statements(fake), { 'BEGIN', 'ROLLBACK', 'BEGIN', 'ROLLBACK', 'BEGIN', 'ROLLBACK' })
end

g.test_an_exception_drops_the_conn_and_goes_further = function()
    g.journal = helper.capture_log()

    local client, fake = connect()
    local ok, err = pcall(client.transaction, client, function(tx)
        tx:execute('insert')
        error('тело упало', 0)
    end)

    t.assert_equals({ ok, err }, { false, 'тело упало' })
    t.assert_equals(helper.statements(fake), { 'BEGIN', 'insert' })
    t.assert_equals(client:stats().drops, 1)

    local record = g.journal.find('WARN [tnt.fake] соединение выброшено')

    t.assert_equals(
        record.record.fields,
        { driver = 'fake', reason = 'исключение в теле транзакции' }
    )

    -- Файбер снова вправе открыть транзакцию: вложенной она не считается.
    t.assert_equals(client:transaction(function() end), true)
end

g.test_the_first_refusal_marks_the_transaction = function()
    local client, fake = connect(function(text)
        if text == 'bad' then
            return { raise = server_error('ERROR:  division by zero', '22012'), open = true }
        end
    end)
    local first, second = {}, {}
    local done, err = client:transaction(function(tx)
        first = { tx:execute('bad') }
        second = { tx:query('good') }

        return true
    end)

    t.assert_equals(done, nil)
    t.assert_equals(err.kind, 'rejected')
    t.assert_equals(err.server_code, '22012')
    t.assert_equals(err.retriable, false)
    t.assert_is(first[2], err)
    t.assert_equals(first[1], nil)
    t.assert_is(second[2], err)
    t.assert_equals(helper.statements(fake), { 'BEGIN', 'bad', 'ROLLBACK' })
    t.assert_equals(client:stats().idle, 1)
end

g.test_a_refused_value_marks_the_transaction_unsent = function()
    local client, fake = connect()
    local built, again = {}, {}
    local _, err = client:transaction(function(tx)
        built = { tx:query('select $1', { n = 1, 'a\0b' }) }
        again = { tx:query('select 1') }
    end)

    t.assert_equals(err.kind, 'rejected')
    t.assert_equals(err.sent, false)
    t.assert_is(built[2], err)
    t.assert_is(again[2], err)
    t.assert_equals(helper.statements(fake), { 'BEGIN', 'ROLLBACK' })
end

g.test_a_refusal_from_the_builder_marks_the_transaction = function()
    local client = connect()
    local _, _, refusal = helper.value.wire('postgres', 'a\0b')
    local first = {}
    local _, err = client:transaction(function(tx)
        first = { tx:execute(nil, refusal) }

        return true
    end)

    t.assert_equals(err.message, refusal.message)
    t.assert_equals(err.retriable, false)
    t.assert_equals(first[1], nil)
    t.assert_is(first[2], err)
end

g.test_an_unanswered_statement_drops_without_rollback = function()
    local client, fake = connect(function(text)
        if text == 'slow' then
            return { delay = 1 }
        end
    end)
    local done, err = client:transaction(function(tx)
        tx:execute('slow')

        return true
    end, { timeout = 0.05 })

    t.assert_equals(done, nil)
    t.assert_equals(err.kind, 'timeout')
    t.assert_equals(err.sent, true)
    t.assert_equals(helper.statements(fake), { 'BEGIN', 'slow' })
    t.assert_equals(client:stats().drops, 1)
end

g.test_a_statement_past_the_deadline_is_not_sent = function()
    local client, fake = connect()
    local _, err = client:transaction(function(tx)
        fiber.sleep(0.06)
        tx:execute('late')
    end, { timeout = 0.05 })

    t.assert_equals(err.kind, 'timeout')
    t.assert_equals(err.sent, false)
    t.assert_equals(helper.statements(fake), { 'BEGIN' })
    -- Откатить уже некогда: соединение с открытой транзакцией выброшено.
    t.assert_equals(client:stats().drops, 1)
end

g.test_a_refused_commit_is_a_pair = function()
    local client, fake = connect(function(text)
        if text == 'COMMIT' then
            return { raise = server_error('ERROR:  could not serialize access', '40001'), open = false }
        end
    end)
    local done, err = client:transaction(function(tx)
        tx:execute('update')
    end)

    t.assert_equals(done, nil)
    t.assert_equals(err.kind, 'conflict')
    t.assert_equals(helper.statements(fake), { 'BEGIN', 'update', 'COMMIT' })
    t.assert_equals(client:stats().idle, 1)
end

g.test_a_conflict_repeats_the_whole_transaction_on_request = function()
    local commits = 0
    local client, fake = connect(function(text)
        if text == 'COMMIT' then
            commits = commits + 1

            if commits == 1 then
                return { raise = server_error('ERROR:  could not serialize access', '40001'), open = false }
            end
        end
    end)
    local calls = 0
    local done = client:transaction(function(tx)
        calls = calls + 1
        tx:execute('update')

        return calls
    end, { retry = true })

    t.assert_equals(done, 2)
    t.assert_equals(helper.statements(fake), { 'BEGIN', 'update', 'COMMIT', 'BEGIN', 'update', 'COMMIT' })

    -- Без согласия конфликт отдаётся парой после одной попытки.
    commits = 0
    calls = 0

    local _, err = client:transaction(function(tx)
        calls = calls + 1
        tx:execute('update')
    end)

    t.assert_equals(err.kind, 'conflict')
    t.assert_equals(calls, 1)
end

g.test_retry_repeats_only_conflicts = function()
    local client = connect()
    local calls = 0
    local _, err = client:transaction(function()
        calls = calls + 1

        return nil, 'передумали'
    end, { retry = true })

    t.assert_equals(err, 'передумали')
    t.assert_equals(calls, 1)
end

g.test_retry_repeats_no_other_storage_refusal = function()
    local client = connect(function(text)
        if text == 'update' then
            return { raise = server_error('ERROR:  division by zero', '22012'), open = true }
        end
    end)
    local calls = 0
    local _, err = client:transaction(function(tx)
        calls = calls + 1

        return tx:execute('update')
    end, { retry = true })

    t.assert_equals(err.kind, 'rejected')
    t.assert_equals(calls, 1)
end

g.test_retry_throws_the_text_of_the_body_as_is = function()
    local client = connect()
    local ok, err = pcall(client.transaction, client, function()
        error('тело упало', 0)
    end, { retry = true })

    t.assert_equals({ ok, err }, { false, 'тело упало' })
end

g.test_retry_does_not_hide_an_exception = function()
    local client = connect()
    local calls = 0
    local ok, err = pcall(client.transaction, client, function()
        calls = calls + 1
        error({ code = 'упало' })
    end, { retry = true })

    t.assert_equals(ok, false)
    t.assert_equals(err, { code = 'упало' })
    t.assert_equals(calls, 1)
    t.assert_equals(client:stats().drops, 1)
end

g.test_begin_is_repeated_after_a_break = function()
    local begins = 0
    local client, fake = connect(function(text)
        if text == 'BEGIN' then
            begins = begins + 1

            if begins == 1 then
                return { raise = 'server closed the connection unexpectedly', broken = true }
            end
        end
    end)

    t.assert_equals(client:transaction(function() end), true)
    t.assert_equals(helper.statements(fake), { 'BEGIN', 'BEGIN', 'COMMIT' })
    t.assert_equals(client:stats().drops, 1)
end

g.test_a_refused_begin_is_returned_as_is = function()
    local client, fake = connect(function(text)
        if text == 'BEGIN' then
            return { raise = server_error('ERROR:  permission denied', '42501'), open = false }
        end
    end)
    local called = false
    local _, err = client:transaction(function()
        called = true
    end)

    t.assert_equals(err.kind, 'rejected')
    t.assert_equals(err.server_code, '42501')
    t.assert_equals(called, false)
    t.assert_equals(helper.statements(fake), { 'BEGIN' })
    t.assert_equals(client:stats().idle, 1)
end

g.test_a_closed_driver_opens_no_transaction = function()
    local client = connect()

    client:close()

    local called = false
    local _, err = client:transaction(function()
        called = true
    end)

    t.assert_equals(err.kind, 'closed')
    t.assert_equals(called, false)
end

g.test_a_cancelled_caller_is_not_hidden_in_a_pair = function()
    local client = connect(function(text)
        if text == 'COMMIT' then
            return { delay = 1 }
        end
    end)
    local ok, err = helper.cancelled(function()
        return client:transaction(function() end)
    end)

    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'fiber is cancelled')
    t.assert_equals(client:stats().drops, 1)
    t.assert_equals(client:stats().busy, 0)
end

g.test_a_cancel_in_the_body_drops_without_rollback = function()
    local client, fake = connect(function(text)
        if text == 'slow' then
            return { delay = 1 }
        end
    end)
    local ok = helper.cancelled(function()
        return client:transaction(function(tx)
            tx:execute('slow')

            return true
        end)
    end)

    -- Отменённый ждёт с запасом срока, но в сокете недочитанный ответ:
    -- ROLLBACK не уходит и отдельным работником.
    fiber.sleep(0.02)
    t.assert_equals(ok, false)
    t.assert_equals(helper.statements(fake), { 'BEGIN', 'slow' })
    t.assert_equals(client:stats().drops, 1)
end

g.test_tx_is_good_only_inside_the_body = function()
    local client = connect()
    ---@type any
    local escaped = nil

    client:transaction(function(tx)
        escaped = tx
    end)

    helper.assert_blamed({
        {
            function()
                escaped:query('select 1')
            end,
            'tx годен только внутри тела транзакции, а она уже закончена',
        },
    })
end

g.test_wrong_calls_blame_the_caller = function()
    local client = connect()
    local wrong = helper.wrong
    local tx_cases = {}

    client:transaction(function(tx)
        tx_cases = {
            {
                function()
                    tx:query('select 1', nil, { timeout = 1 })
                end,
                'у оператора транзакции нет своего срока и повтора: их задаёт transaction',
            },
            {
                function()
                    tx:execute('select 1', nil, { idempotent = true })
                end,
                'у оператора транзакции нет своего срока и повтора: их задаёт transaction',
            },
            {
                function()
                    tx:query('select 1', nil, { max_rows = 0 })
                end,
                'max_rows — число больше 0, а не 0',
            },
            {
                function()
                    tx:query('select 1', nil, { rows = 1 })
                end,
                'настройки оператора транзакции: ключа «rows» нет, есть max_rows',
            },
            {
                function()
                    tx:query(wrong(1))
                end,
                'sql — строка, а не число',
            },
            {
                function()
                    tx:query(wrong(nil))
                end,
                'sql — строка, а не nil',
            },
            {
                function()
                    tx:query('select $1', { 1 })
                end,
                'params.n — целое число, а не nil',
            },
            {
                function()
                    tx:execute('select $1', { n = 1, {} })
                end,
                'значение table нельзя передать параметром: таблицу оберните json, байты — binary',
            },
            {
                function()
                    client:transaction(function() end)
                end,
                'transaction внутри transaction: вторая взяла бы второе соединение и ждала бы первого',
            },
        }
        helper.assert_blamed(tx_cases)
    end)

    t.assert_equals(#tx_cases, 9)

    helper.assert_blamed({
        {
            function()
                client:transaction(wrong('тело'))
            end,
            'тело транзакции — функция или вызываемая таблица, а не строка',
        },
        {
            function()
                client:transaction(function() end, { tries = 2 })
            end,
            'настройки транзакции: ключа «tries» нет, есть retry, timeout',
        },
        {
            function()
                client:transaction(function() end, { timeout = 0 })
            end,
            'timeout — число секунд больше нуля и меньше бесконечности, а не 0',
        },
    })

    helper.in_box_txn(true)
    helper.assert_blamed({
        {
            function()
                client:transaction(function() end)
            end,
            'transaction внутри транзакции box: ожидание сети оборвёт её',
        },
    })
end

g.test_rows_over_the_limit_inside = function()
    local client = connect(function(text)
        if text == 'select' then
            return { rows = { { a = 1 }, { a = 2 } } }
        end
    end, { max_rows = 1 })
    local rows
    local _, err = client:transaction(function(tx)
        rows = tx:query('select', nil, { max_rows = 2 })
        tx:query('select')
    end)

    t.assert_equals(rows, { { a = 1 }, { a = 2 } })
    t.assert_equals(err.kind, failure.OVERFLOW)
end

g.test_a_rock_blind_to_transactions_is_led_by_the_mark = function()
    local client, fake = connect(function(text)
        if text == 'COMMIT' then
            return { raise = server_error('Deadlock found when trying to get lock', 1213) }
        end
    end, nil, nil, false)
    local _, err = client:transaction(function(tx)
        tx:execute('update')
    end)

    -- Рок не говорит, открыта ли транзакция: после отказа COMMIT фасад
    -- откатывает по своей отметке, и соединение возвращается чистым.
    t.assert_equals(err.kind, 'conflict')
    t.assert_equals(helper.statements(fake), { 'BEGIN', 'update', 'COMMIT', 'ROLLBACK' })
    t.assert_equals(client:stats().idle, 1)
    t.assert_equals(client:stats().drops, 0)
end

g.test_the_mark_is_cleared_by_commit_and_rollback = function()
    local client, fake = connect(nil, nil, nil, false)

    t.assert_equals(client:transaction(function() end), true)
    t.assert_equals(
        client:transaction(function()
            return false
        end),
        nil
    )
    t.assert_equals(helper.statements(fake), { 'BEGIN', 'COMMIT', 'BEGIN', 'ROLLBACK' })
    t.assert_equals(client:stats().idle, 1)
    t.assert_equals(client:stats().discarded, 0)
end
