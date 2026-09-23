--- Проверки срока: умолчание и потолок, миг и остаток, ожидание работника
--- с отменой и опоздавшим итогом.

local fiber = require('fiber')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local within = helper.within

local g = t.group('tnt.storage.within')

g.after_each(helper.restore)

--- Часы проверки, которые внешняя зависимость отдаёт пакету.
---@param opts table|nil
---@return TntTestingClock
local function fake_clock(opts)
    local clock = helper.clock(opts)

    within._set_source({ monotonic = clock.monotonic, scheduler_now = clock.scheduler_now })

    return clock
end

--- Все значения, что вернул вызов, с их числом.
---@param ... any
---@return table
local function all(...)
    return { n = select('#', ...), ... }
end

--- Ждёт, пока условие не станет истинным, не дольше секунды.
---@param condition fun(): boolean
local function wait_for(condition)
    local started = fiber.clock()

    while not condition() and fiber.clock() - started < 1 do
        fiber.sleep(0.005)
    end

    t.assert(condition(), 'условие не наступило за секунду')
end

g.test_the_defaults_and_the_outcomes_are_named = function()
    t.assert_equals({ within.DEFAULT_TIMEOUT, within.DEFAULT_MAX_TIMEOUT }, { 5, 60 })
    t.assert_equals(
        { within.RETURNED, within.RAISED, within.EXPIRED, within.SKIPPED, within.WORKER },
        { 'returned', 'raised', 'expired', 'skipped', 'tnt.storage.within' }
    )
end

g.test_the_limits_of_a_driver_have_defaults = function()
    t.assert_equals(within.settings(), { timeout = 5, max_timeout = 60 })
    t.assert_equals(within.settings(0.5, 2), { timeout = 0.5, max_timeout = 2 })
    t.assert_equals(within.settings(nil, 7), { timeout = 5, max_timeout = 7 })
    t.assert_equals(within.settings(30), { timeout = 30, max_timeout = 60 })
    t.assert_equals(within.settings(3, 3), { timeout = 3, max_timeout = 3 })
end

g.test_the_timeout_of_a_call_is_its_own_or_the_drivers = function()
    local limits = within.settings(2, 10)

    t.assert_equals(within.timeout(nil, limits), 2)
    t.assert_equals(within.timeout(0.3, limits), 0.3)
    t.assert_equals(within.timeout(10, limits), 10)
    t.assert_equals(within.timeout(0.001, limits), 0.001)
end

g.test_a_timeout_that_is_not_a_span_is_raised_at_the_callers_line = function()
    local limits = within.settings(2, 10)

    -- Не хвостовым вызовом: у хвостового кадра нет, и уровню 2 некуда указать.
    local function driver_settings(timeout, max_timeout)
        local made = within.settings(timeout, max_timeout, 2)

        return made
    end

    local function driver_timeout(given)
        local span = within.timeout(given, limits, 2)

        return span
    end

    local function span(name, shown)
        return ('%s — число секунд больше нуля и меньше бесконечности, а не %s'):format(
            name,
            shown
        )
    end

    helper.assert_blamed({
        {
            function()
                within.settings(0)
            end,
            span('timeout', '0'),
        },
        {
            function()
                within.settings(-0.5)
            end,
            span('timeout', '-0.5'),
        },
        {
            function()
                within.settings(0 / 0)
            end,
            span('timeout', tostring(0 / 0)),
        },
        {
            function()
                within.settings(math.huge)
            end,
            span('timeout', 'inf'),
        },
        {
            function()
                within.settings(-math.huge)
            end,
            span('timeout', '-inf'),
        },
        {
            function()
                within.settings(helper.wrong('5'))
            end,
            span('timeout', '5'),
        },
        {
            function()
                within.settings(1, 0)
            end,
            span('max_timeout', '0'),
        },
        {
            function()
                within.settings(nil, 3)
            end,
            'timeout 5 с длиннее потолка max_timeout 3 с',
        },
        {
            function()
                within.settings(4, 3.5)
            end,
            'timeout 4 с длиннее потолка max_timeout 3.5 с',
        },
        {
            function()
                driver_settings(0)
            end,
            span('timeout', '0'),
        },
        {
            function()
                driver_settings(4, 3)
            end,
            'timeout 4 с длиннее потолка max_timeout 3 с',
        },
        {
            function()
                within.timeout(0, limits)
            end,
            span('timeout', '0'),
        },
        {
            function()
                within.timeout(10.5, limits)
            end,
            'timeout 10.5 с длиннее потолка max_timeout 10 с',
        },
        {
            function()
                driver_timeout(-1)
            end,
            span('timeout', '-1'),
        },
        {
            function()
                driver_timeout(11)
            end,
            'timeout 11 с длиннее потолка max_timeout 10 с',
        },
    })
end

g.test_the_deadline_is_real_time_and_the_rest_is_scheduler_time = function()
    -- Отметка цикла отстаёт на работу без уступки: остаток от неё длиннее.
    local clock = fake_clock({ at = 1000, lag = 0.2 })

    t.assert_equals(within.deadline(5), 1005)
    t.assert_almost_equals(within.left(1005), 5.2, 1e-9)
    clock.advance(6)
    t.assert_almost_equals(within.left(1005), -0.8, 1e-9)
end

g.test_a_body_that_returns_gives_all_its_values = function()
    local deadline = within.deadline(1)

    t.assert_equals(
        all(within.call(deadline, function()
            return 1, nil, 3, nil
        end)),
        { n = 5, 'returned', 1, nil, 3, nil }
    )
    t.assert_equals(all(within.call(deadline, function() end)), { n = 1, 'returned' })
    t.assert_equals(
        all(within.call(deadline, function()
            return false
        end)),
        { n = 2, 'returned', false }
    )
end

g.test_a_body_runs_in_its_own_named_fiber_under_the_callers_context = function()
    local caller = fiber.self():id()
    local status, worker, name, request = helper.context.run({ request_id = 'req-1' }, function()
        return within.call(within.deadline(1), function()
            return fiber.self():id(), fiber.self():name(), helper.context.get('request_id')
        end)
    end)

    t.assert_equals({ status, name, request }, { 'returned', 'tnt.storage.within', 'req-1' })
    t.assert_not_equals(worker, caller)
end

g.test_a_body_that_raises_gives_what_it_raised = function()
    local deadline = within.deadline(1)
    local thrown = { kind = 'таблица' }

    t.assert_equals(
        all(within.call(deadline, function()
            error('рок упал', 0)
        end)),
        { n = 2, 'raised', 'рок упал' }
    )

    local status, err = within.call(deadline, function()
        error(thrown)
    end)

    t.assert_equals(status, 'raised')
    t.assert(rawequal(err, thrown))
end

g.test_a_body_past_the_deadline_is_cancelled_and_its_late_result_goes_aside = function()
    local late = {}
    ---@type any
    local worker
    local started = fiber.clock()
    local status = within.call(within.deadline(0.05), function()
        worker = fiber.self()
        fiber.sleep(10)
    end, function(...)
        late = all(...)
    end)
    local took = fiber.clock() - started

    t.assert_equals(status, 'expired')
    t.assert(took >= 0.04 and took < 0.5, took)
    wait_for(function()
        return late.n ~= nil
    end)
    t.assert_equals({ late.n, late[1], tostring(late[2]) }, { 2, false, 'fiber is cancelled' })
    t.assert_equals(worker:status(), 'dead')
end

g.test_a_late_success_goes_to_late_and_not_to_the_caller = function()
    -- Рок, который отмену не слышит: вход закончился уже после срока.
    local late = {}
    local status = within.call(within.deadline(0.02), function()
        pcall(fiber.sleep, 0.1)

        return 'соединение', nil
    end, function(...)
        late = all(...)
    end)

    t.assert_equals(status, 'expired')
    wait_for(function()
        return late.n ~= nil
    end)
    t.assert_equals(late, { n = 3, true, 'соединение', nil })
end

g.test_a_late_result_without_a_receiver_is_dropped = function()
    local finished = false
    local status = within.call(within.deadline(0.02), function()
        pcall(fiber.sleep, 0.05)
        finished = true

        return 'никому'
    end)

    t.assert_equals(status, 'expired')
    wait_for(function()
        return finished
    end)
end

g.test_a_body_is_skipped_when_the_deadline_has_passed = function()
    local called = 0
    local body = function()
        called = called + 1
    end

    fake_clock({ at = 100 })
    t.assert_equals(all(within.call(100, body)), { n = 1, 'skipped' })
    t.assert_equals(all(within.call(99, body)), { n = 1, 'skipped' })
    t.assert_equals(called, 0)
end

g.test_a_short_rest_still_calls_the_body = function()
    t.assert_equals(
        all(within.call(within.deadline(0.5), function()
            return 'успел'
        end)),
        { n = 2, 'returned', 'успел' }
    )
end

g.test_a_cancelled_caller_cancels_the_worker_and_raises_on = function()
    local late = {}
    local caught = {}
    local caller = fiber.new(function()
        caught = all(pcall(within.call, within.deadline(5), function()
            fiber.sleep(10)
        end, function(...)
            late = all(...)
        end))
    end)

    caller:set_joinable(true)
    fiber.yield()
    caller:cancel()
    caller:join()

    t.assert_equals({ caught[1], tostring(caught[2]) }, { false, 'fiber is cancelled' })
    wait_for(function()
        return late.n ~= nil
    end)
    t.assert_equals({ late[1], tostring(late[2]) }, { false, 'fiber is cancelled' })
end

g.test_wrong_arguments_are_raised_at_the_callers_line = function()
    helper.assert_blamed({
        {
            function()
                within.call(helper.wrong(nil), function() end)
            end,
            'миг срока — число, а не nil',
        },
        {
            function()
                within.call(1, helper.wrong('select 1'))
            end,
            'тело — функция или вызываемая таблица, а не строка',
        },
        {
            function()
                within.call(1, function() end, helper.wrong(true))
            end,
            'приёмник опоздавшего итога — функция или вызываемая таблица, а не логическое значение',
        },
    })
end
