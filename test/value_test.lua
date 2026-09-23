--- Проверки кодирования: таблица значений на четыре диалекта, отказ данных,
--- исключения, обёртки, двоичное из ответа, параметры с `n`.

local datetime = require('datetime')
local decimal = require('decimal')
local t = require('luatest')
local uuid = require('uuid')
local varbinary = require('varbinary')

local helper = dofile('test/helper.lua')

local value = helper.value

local g = t.group('tnt.storage.value')

--- Значение и приведение одним списком: сверять их надо вместе.
---@param dialect any
---@param given any
---@return table
local function wired(dialect, given)
    local result, cast, err = value.wire(dialect, given)

    return { result, cast, err }
end

--- Дата с числовым сдвигом: 2026-09-13 12:34:56.789 по Москве.
local MOMENT =
    datetime.new({ year = 2026, month = 9, day = 13, hour = 12, min = 34, sec = 56, nsec = 789000000, tzoffset = 180 })

--- Обёртка JSON того же модуля.
---@param given any
---@return table
local function storage_json(given)
    return value.json(given)
end

--- Опознаватель для проверок.
local ID = '6f5d9c77-6a4e-4a8b-9d7e-3a2f1c0b9e8d'

g.test_the_dialects_are_named_by_constants = function()
    t.assert_equals(
        { value.POSTGRES, value.MYSQL, value.TARANTOOL, value.REDIS, value.MONGO },
        { 'postgres', 'mysql', 'tarantool', 'redis', 'mongo' }
    )
end

g.test_a_dialect_is_a_name_or_a_table_of_the_driver = function()
    t.assert_equals(wired({ name = 'postgres', placeholder = '$' }, 9007199254740993LL), { '9007199254740993', 'int8' })
    t.assert_equals(wired({ name = 'mysql' }, 9007199254740993LL), { '9007199254740993' })
end

g.test_null_is_always_box_null = function()
    -- box.execute теряет всё после дыры в массиве параметров.
    for _, dialect in ipairs({ 'postgres', 'mysql', 'tarantool' }) do
        for _, given in ipairs({ box.NULL }) do
            local result, cast = value.wire(dialect, given)

            t.assert(rawequal(result, box.NULL), dialect)
            t.assert_equals(cast, nil, dialect)
        end

        t.assert(rawequal((value.wire(dialect, nil)), box.NULL), dialect)
    end
end

g.test_booleans_and_strings_go_as_they_are = function()
    for _, dialect in ipairs({ 'postgres', 'mysql', 'tarantool' }) do
        t.assert_equals(wired(dialect, true), { true }, dialect)
        t.assert_equals(wired(dialect, false), { false }, dialect)
        t.assert_equals(wired(dialect, 'строка'), { 'строка' }, dialect)
        t.assert_equals(wired(dialect, '0012'), { '0012' }, dialect)
        t.assert_equals(wired(dialect, ''), { '' }, dialect)
    end
end

g.test_a_zero_byte_in_a_string_is_a_refusal_only_for_postgres = function()
    local result, cast, err = value.wire('postgres', 'a\0b')

    t.assert_equals({ result, cast }, { nil, nil })
    t.assert_equals({ err.kind, err.sent, err.retriable, err.message }, {
        'rejected',
        false,
        false,
        'строка с нулевым байтом: pg обрезал бы её молча',
    })
    t.assert(helper.failure.is(err))
    t.assert_equals(wired('mysql', 'a\0b'), { 'a\0b' })
    t.assert_equals(wired('tarantool', 'a\0b'), { 'a\0b' })
end

g.test_numbers_that_the_rock_keeps_go_as_they_are = function()
    local integers = { 0, 42, -7, 12345678901234, -12345678901234, 1e15 }
    local fractions = { 1.5, -0.25, 0.1, 1e-300 }

    for _, dialect in ipairs({ 'mysql', 'tarantool' }) do
        for _, numbers in ipairs({ integers, fractions }) do
            for _, number in ipairs(numbers) do
                t.assert_equals(wired(dialect, number), { number }, dialect .. ' ' .. tostring(number))
            end
        end
    end

    -- Целое у PostgreSQL — с int8: `numeric` рока сравнивался бы с целым
    -- столбцом мимо индекса.
    for _, number in ipairs(integers) do
        t.assert_equals(wired('postgres', number), { number, 'int8' }, tostring(number))
    end

    for _, number in ipairs(fractions) do
        t.assert_equals(wired('postgres', number), { number }, tostring(number))
    end
end

g.test_postgres_gets_numbers_longer_than_fourteen_digits_as_exact_text = function()
    -- Рок pg пишет число текстом %.14g: хвост пропал бы молча.
    local expected = {
        { 123456789012345, '123456789012345', 'int8' },
        { 1234567890123456, '1234567890123456', 'int8' },
        -- Пятнадцать значащих цифр за 10^15: самая короткая точная запись
        -- была бы 1.23456789012345e+15, а её int8 не читает.
        { 1234567890123450, '1234567890123450', 'int8' },
        { 2 ^ 53, '9007199254740992', 'int8' },
        { -(2 ^ 53), '-9007199254740992', 'int8' },
        { 0.1 + 0.2, '0.30000000000000004', 'numeric' },
        { 123456789012345.6, '123456789012345.6', 'numeric' },
        -- Пятнадцати знаков хватает, а шестнадцать дали бы другую запись:
        -- 8.000002469135779.
        { 8.00000246913578, '8.00000246913578', 'numeric' },
    }

    for _, case in ipairs(expected) do
        t.assert_equals(wired('postgres', case[1]), { case[2], case[3] }, case[2])
        t.assert_equals(tonumber(case[2]), case[1], case[2])
        t.assert_equals(wired('mysql', case[1]), { case[1] }, case[2])
        t.assert_equals(wired('tarantool', case[1]), { case[1] }, case[2])
    end
end

g.test_integers_and_exact_values_go_as_text_with_a_cast_for_postgres = function()
    local id = uuid.fromstr(ID)
    local price = decimal.new('1.10')
    local cases = {
        { 9007199254740993LL, { '9007199254740993', 'int8' }, { '9007199254740993' } },
        { -9223372036854775807LL - 1, { '-9223372036854775808', 'int8' }, { '-9223372036854775808' } },
        { 5ULL, { '5', 'int8' }, { '5' } },
        { 9223372036854775807ULL, { '9223372036854775807', 'int8' }, { '9223372036854775807' } },
        { 9223372036854775808ULL, { '9223372036854775808', 'numeric' }, { '9223372036854775808' } },
        { 18446744073709551615ULL, { '18446744073709551615', 'numeric' }, { '18446744073709551615' } },
        { price, { '1.10', 'numeric' }, { '1.10' } },
        { decimal.new('1e30'), { '1E+30', 'numeric' }, { '1E+30' } },
        { id, { ID, 'uuid' }, { ID } },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(wired('postgres', case[1]), case[2], tostring(case[1]))
        t.assert_equals(wired('mysql', case[1]), case[3], tostring(case[1]))

        local native, cast = value.wire('tarantool', case[1])

        t.assert(rawequal(native, case[1]), tostring(case[1]))
        t.assert_equals(cast, nil, tostring(case[1]))
    end
end

g.test_a_moment_has_an_offset_for_postgres_and_is_utc_for_mysql = function()
    t.assert_equals(wired('postgres', MOMENT), { '2026-09-13T12:34:56.789000+0300', 'timestamptz' })
    t.assert_equals(wired('mysql', MOMENT), { '2026-09-13 09:34:56.789000' })

    local named =
        datetime.new({ year = 2026, month = 9, day = 13, hour = 12, min = 34, sec = 56, tz = 'Europe/Moscow' })

    -- Имя пояса у сервера может значить другое: уходит сдвиг числом.
    t.assert_equals(wired('postgres', named), { '2026-09-13T12:34:56.000000+0300', 'timestamptz' })
    t.assert_equals(wired('mysql', named), { '2026-09-13 09:34:56.000000' })

    local native, cast = value.wire('tarantool', MOMENT)

    t.assert(rawequal(native, MOMENT))
    t.assert_equals(cast, nil)
end

g.test_json_is_encoded_at_once_and_goes_as_text = function()
    local document = { a = 1 }
    local wrapped = value.json(document)

    document.a = 2

    t.assert_equals(wired('postgres', wrapped), { '{"a":1}', 'jsonb' })
    t.assert_equals(wired('mysql', wrapped), { '{"a":1}' })
    t.assert_equals(wired('tarantool', wrapped), { '{"a":1}' })
    t.assert_equals(wired('mysql', value.json({})), { '[]' })
    t.assert_equals(wired('mysql', value.json(setmetatable({}, { __serialize = 'map' }))), { '{}' })
    t.assert_equals(wired('mysql', value.json('x')), { '"x"' })
    t.assert_equals(wired('mysql', value.json(9007199254740993LL)), { '9007199254740993' })
    -- Конечное число у края double кодируется как прежде: отсекаются
    -- только нечисла.
    t.assert_equals(wired('mysql', value.json({ 1e308, -1e308, 0 })), { '[1e+308,-1e+308,0]' })
end

g.test_json_refuses_nan_and_infinity_at_the_callers_line = function()
    local refused =
        'значение не кодируется в JSON: NaN и бесконечность не выражаются'

    helper.assert_blamed({
        {
            function()
                helper.storage.json({ a = 0 / 0 })
            end,
            refused,
        },
        {
            function()
                helper.storage.json({ a = 1 / 0 })
            end,
            refused,
        },
        {
            function()
                value.json({ a = -math.huge })
            end,
            refused,
        },
        {
            function()
                value.json({ a = { b = 0 / 0 } })
            end,
            refused,
        },
        {
            function()
                value.json({ 1, 2, math.huge })
            end,
            refused,
        },
        {
            function()
                value.json(0 / 0)
            end,
            refused,
        },
        {
            -- Нечисло стоит раньше функции: отказ всё равно называет
            -- функцию — её в JSON не выразить при любых настройках.
            function()
                value.json({ 0 / 0, print })
            end,
            "значение не кодируется в JSON: unsupported Lua type 'function'",
        },
    })
end

g.test_bytes_go_as_bytea_blob_or_varbinary = function()
    for _, given in ipairs({ value.binary('\0\255'), varbinary.new('\0\255') }) do
        t.assert_equals(wired('postgres', given), { '\\x00ff', 'bytea' })
        t.assert_equals(wired('mysql', given), { '\0\255' })

        local native, cast = value.wire('tarantool', given)

        t.assert(varbinary.is(native))
        t.assert_equals({ tostring(native), cast }, { '\0\255', nil })
    end

    t.assert_equals(wired('postgres', value.binary('')), { '\\x', 'bytea' })
end

g.test_what_cannot_be_sent_is_raised_at_the_callers_line = function()
    -- Не хвостовым вызовом: у хвостового кадра нет, и уровню 2 некуда указать.
    local function driver_wire(given)
        local result = value.wire('postgres', given, 2)

        return result
    end

    helper.assert_blamed({
        {
            function()
                value.wire('postgres', { 1 })
            end,
            'значение table нельзя передать параметром: таблицу оберните json, байты — binary',
        },
        {
            function()
                value.wire('mysql', setmetatable({}, {}))
            end,
            'значение table нельзя передать параметром: таблицу оберните json, байты — binary',
        },
        {
            function()
                value.wire('tarantool', print)
            end,
            'значение function нельзя передать параметром: таблицу оберните json, байты — binary',
        },
        {
            function()
                value.wire('postgres', datetime.interval.new({ day = 1 }))
            end,
            'значение ctype<struct interval> нельзя передать параметром: таблицу оберните json, байты — binary',
        },
        {
            function()
                value.wire('tarantool', box.tuple.new({ 1 }))
            end,
            'значение ctype<struct tuple &> нельзя передать параметром: таблицу оберните json, байты — binary',
        },
        {
            function()
                value.wire('mysql', 2 ^ 53 + 2)
            end,
            'число 9.007199254741e+15 за пределом ±2^53: целые там неточны — передайте int64 либо decimal',
        },
        {
            function()
                value.wire('tarantool', -(2 ^ 53) - 2)
            end,
            'число -9.007199254741e+15 за пределом ±2^53: целые там неточны — передайте int64 либо decimal',
        },
        {
            function()
                value.wire('postgres', 0 / 0)
            end,
            'число — NaN или бесконечность: серверу его не передать',
        },
        {
            function()
                value.wire('mysql', math.huge)
            end,
            'число — NaN или бесконечность: серверу его не передать',
        },
        {
            function()
                value.wire('tarantool', -math.huge)
            end,
            'число — NaN или бесконечность: серверу его не передать',
        },
        {
            function()
                value.wire('oracle', 1)
            end,
            'диалект oracle незнаком: есть postgres, mysql, tarantool, redis, mongo',
        },
        {
            function()
                value.wire({ name = 'sqlite' }, 1)
            end,
            'диалект sqlite незнаком: есть postgres, mysql, tarantool, redis, mongo',
        },
        {
            function()
                value.wire(helper.wrong(nil), 1)
            end,
            'диалект nil незнаком: есть postgres, mysql, tarantool, redis, mongo',
        },
        {
            function()
                driver_wire({ 1 })
            end,
            'значение table нельзя передать параметром: таблицу оберните json, байты — binary',
        },
        {
            function()
                driver_wire(0 / 0)
            end,
            'число — NaN или бесконечность: серверу его не передать',
        },
        {
            function()
                driver_wire(2 ^ 60)
            end,
            'число 1.1529215046068e+18 за пределом ±2^53: целые там неточны — передайте int64 либо decimal',
        },
        {
            function()
                driver_wire(datetime.interval.new({ day = 1 }))
            end,
            'значение ctype<struct interval> нельзя передать параметром: таблицу оберните json, байты — binary',
        },
        {
            function()
                value.json(print)
            end,
            "значение не кодируется в JSON: unsupported Lua type 'function'",
        },
        {
            function()
                value.binary(helper.wrong(42))
            end,
            'байты — строка, а не число',
        },
    })

    t.assert_equals(pcall(value.wire, { name = 'postgres' }, box.NULL), true)
end

g.test_redis_gets_every_value_as_a_string = function()
    local cases = {
        { 'строка', 'строка' },
        { 'a\0b', 'a\0b' },
        { '', '' },
        { 0, '0' },
        { -0.0, '0' },
        { 42, '42' },
        { -7, '-7' },
        -- Степени Redis в целом не принимает: `INCRBY k 1e+15` — отказ.
        { 1e15, '1000000000000000' },
        { 2 ^ 53, '9007199254740992' },
        { -(2 ^ 53), '-9007199254740992' },
        { 1.5, '1.5' },
        { 0.1, '0.1' },
        { 0.1 + 0.2, '0.30000000000000004' },
        { 123456789012345.6, '123456789012345.6' },
        { 1e-7, '1e-07' },
        { 9007199254740993LL, '9007199254740993' },
        { -9223372036854775807LL - 1, '-9223372036854775808' },
        { 18446744073709551615ULL, '18446744073709551615' },
        { decimal.new('1.10'), '1.10' },
        { uuid.fromstr(ID), ID },
        { MOMENT, '2026-09-13T12:34:56.789000+0300' },
        { value.json({ a = 1 }), '{"a":1}' },
        { value.binary('\0\255'), '\0\255' },
        { varbinary.new('\0\255'), '\0\255' },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(wired('redis', case[1]), { case[2] }, case[2])
    end

    t.assert_equals(wired({ name = 'redis' }, 7), { '7' })
end

g.test_mongo_names_the_bson_type_of_every_value = function()
    local ffi = require('ffi')
    local id = uuid.fromstr(ID)
    local price = decimal.new('1.10')

    local cases = {
        { true, true, 'bool' },
        { false, false, 'bool' },
        { 'Анна', 'Анна', 'string' },
        { 7, 7, 'int32' },
        { -2 ^ 31, -2 ^ 31, 'int32' },
        { 2 ^ 31 - 1, 2 ^ 31 - 1, 'int32' },
        { 2 ^ 31, 2 ^ 31, 'int64' },
        { -2 ^ 31 - 1, -2 ^ 31 - 1, 'int64' },
        { 2 ^ 53, 2 ^ 53, 'int64' },
        { 1.5, 1.5, 'double' },
        { -0.25, -0.25, 'double' },
        { storage_json({ a = 1 }), '{"a":1}', 'string' },
        { value.binary('\0\1'), '\0\1', 'binary' },
        { varbinary.new('\255'), '\255', 'binary' },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(wired('mongo', case[1]), { case[2], case[3] }, tostring(case[1]))
    end

    -- `varbinary` равен строке тех же байтов, и сверка значения его
    -- не отличит: что уходят именно байты строкой, видно по типу.
    t.assert_equals(type((value.wire('mongo', varbinary.new('\255')))), 'string')

    local wide, kind = value.wire('mongo', 9007199254740993ULL)

    t.assert_equals({ tostring(wide), kind }, { '9007199254740993LL', 'int64' })
    t.assert(ffi.istype('int64_t', wide))

    wide, kind = value.wire('mongo', -5LL)
    t.assert_equals({ tostring(wide), kind }, { '-5LL', 'int64' })

    wide, kind = value.wire('mongo', 9223372036854775807ULL)
    t.assert_equals({ tostring(wide), kind }, { '9223372036854775807LL', 'int64' })

    t.assert_equals({ value.wire('mongo', price) }, { price, 'decimal128' })
    t.assert_equals({ value.wire('mongo', id) }, { id, 'uuid' })

    local null, null_kind = value.wire('mongo', nil)

    t.assert(rawequal(null, box.NULL))
    t.assert_equals(null_kind, 'null')

    null, null_kind = value.wire('mongo', box.NULL)
    t.assert(rawequal(null, box.NULL))
    t.assert_equals(null_kind, 'null')
end

g.test_mongo_time_is_milliseconds_rounded_down = function()
    local moment, kind = value.wire('mongo', MOMENT)

    t.assert_equals({ tostring(moment), kind }, { '1789292096789LL', 'date' })

    local before = value.wire('mongo', datetime.new({ timestamp = -1, nsec = 999999999 }))

    t.assert_equals(tostring(before), '-1LL')
    t.assert_equals(tostring(value.wire('mongo', datetime.new({ timestamp = -2, nsec = 500000 }))), '-2000LL')
end

g.test_what_bson_cannot_hold_is_raised_at_the_callers_line = function()
    helper.assert_blamed({
        {
            function()
                value.wire('mongo', 9223372036854775808ULL)
            end,
            'uint64 9223372036854775808ULL не уходит в BSON: он больше 2^63−1',
        },
        {
            function()
                value.wire('mongo', 0 / 0)
            end,
            'число — NaN или бесконечность: серверу его не передать',
        },
        {
            function()
                value.wire('mongo', 2 ^ 53 + 2)
            end,
            'число 9.007199254741e+15 за пределом ±2^53: целые там неточны — передайте int64 либо decimal',
        },
        {
            function()
                value.wire('mongo', print)
            end,
            'значение function не уходит в BSON: документ — таблица, байты — binary',
        },
        {
            function()
                value.wire('mongo', { 1 })
            end,
            'значение table не уходит в BSON: документ — таблица, байты — binary',
        },
        {
            function()
                value.wire('mongo', setmetatable({}, { __index = {} }))
            end,
            'значение table не уходит в BSON: документ — таблица, байты — binary',
        },
        {
            function()
                value.wire('mongo', box.tuple.new({ 1 }))
            end,
            'значение cdata не уходит в BSON: документ — таблица, байты — binary',
        },
    })
end

g.test_redis_has_no_null_and_no_booleans = function()
    local function driver_wire(given)
        local result = value.wire('redis', given, 2)

        return result
    end

    local null =
        'пустое значение в Redis не передать: у него только строки — передайте строку явно'
    local boolean =
        'логику в Redis не передать: у него только строки — передайте строку явно'

    helper.assert_blamed({
        {
            function()
                value.wire('redis', nil)
            end,
            null,
        },
        {
            function()
                value.wire('redis', box.NULL)
            end,
            null,
        },
        {
            function()
                value.wire('redis', false)
            end,
            boolean,
        },
        {
            function()
                driver_wire(true)
            end,
            boolean,
        },
        {
            function()
                driver_wire(nil)
            end,
            null,
        },
        {
            function()
                value.wire('redis', 2 ^ 53 + 2)
            end,
            'число 9.007199254741e+15 за пределом ±2^53: целые там неточны — передайте int64 либо decimal',
        },
        {
            function()
                value.wire('redis', { 1 })
            end,
            'значение table нельзя передать параметром: таблицу оберните json, байты — binary',
        },
    })
end

g.test_bytes_are_read_back_by_dialect = function()
    t.assert_equals(value.decode_binary('postgres', '\\x00ff'), '\0\255')
    t.assert_equals(value.decode_binary('postgres', '\\xDEADbeef'), '\222\173\190\239')
    t.assert_equals(value.decode_binary({ name = 'postgres' }, '\\x'), '')
    t.assert_equals(value.decode_binary('postgres', nil), nil)
    t.assert_equals(value.decode_binary('mysql', '\0\255'), '\0\255')
    t.assert_equals(value.decode_binary('mysql', nil), nil)
    t.assert_equals(value.decode_binary('tarantool', varbinary.new('\0\255')), '\0\255')
    t.assert_equals(value.decode_binary('postgres', varbinary.new('\0\255')), '\0\255')
    t.assert_equals(value.decode_binary('tarantool', 'ab'), 'ab')
end

g.test_bytes_not_in_hex_are_raised_at_the_callers_line = function()
    local hint =
        "bytea не в виде \\x…: столбец не bytea либо сервер отдаёт bytea_output = 'escape'"

    helper.assert_blamed({
        {
            function()
                value.decode_binary('postgres', '\\x0')
            end,
            hint,
        },
        {
            function()
                value.decode_binary('postgres', '\\x00f')
            end,
            hint,
        },
        {
            function()
                value.decode_binary('postgres', '\\xzz')
            end,
            hint,
        },
        {
            function()
                value.decode_binary('postgres', '\\000\\377')
            end,
            hint,
        },
        {
            function()
                value.decode_binary('postgres', 'x\\x00')
            end,
            hint,
        },
        {
            function()
                value.decode_binary('mysql', helper.wrong(42))
            end,
            'значение столбца — строка, а не число',
        },
        {
            function()
                value.decode_binary('oracle', '\\x00')
            end,
            'диалект oracle незнаком: есть postgres, mysql, tarantool, redis, mongo',
        },
    })
end

g.test_params_keep_the_count_and_null_in_the_middle = function()
    t.assert_equals(value.params('mysql', nil), { n = 0 })
    t.assert_equals(value.params('mysql', { n = 0 }), { n = 0 })

    local encoded = value.params('postgres', { n = 4, 10, nil, 9007199254740993LL })

    t.assert_equals(encoded.n, 4)
    t.assert_equals({ encoded[1], encoded[3], encoded[4] }, { 10, '9007199254740993', box.NULL })
    t.assert(rawequal(encoded[2], box.NULL))
    t.assert(rawequal(encoded[4], box.NULL))
    -- Сверка типом: `box.NULL == nil`, и лишний ключ со значением
    -- `box.NULL` сравнением не видно.
    t.assert_equals({ type(encoded[0]), type(encoded[5]) }, { 'nil', 'nil' })

    local native = value.params('tarantool', { n = 3, 1, nil, 3 })

    t.assert_equals({ native.n, native[1], native[3] }, { 3, 1, 3 })
    t.assert(rawequal(native[2], box.NULL))
end

g.test_params_with_a_refused_value_are_a_pair = function()
    local encoded, err = value.params('postgres', { n = 2, 'ok', 'a\0b' })

    t.assert_equals(encoded, nil)
    t.assert_equals({ err.kind, err.sent }, { 'rejected', false })
end

g.test_params_that_are_not_an_array_with_n_are_raised_at_the_callers_line = function()
    local function driver_params(params)
        local encoded = value.params('mysql', params, 2)

        return encoded
    end

    helper.assert_blamed({
        {
            function()
                value.params('mysql', { 1, 2 })
            end,
            'params.n — целое число, а не nil',
        },
        {
            function()
                value.params('mysql', { n = 1.5 })
            end,
            'params.n — целое число, а не 1.5',
        },
        {
            function()
                value.params('mysql', { n = -1 })
            end,
            'params.n — число не меньше 0, а не -1',
        },
        {
            function()
                value.params('mysql', helper.wrong('select 1'))
            end,
            'params — таблица, а не строка',
        },
        {
            function()
                value.params('mysql', { n = 1, [0] = 'x' })
            end,
            'params: ключ 0 вне 1..n',
        },
        {
            function()
                value.params('mysql', { n = 1, 'a', 'b' })
            end,
            'params: ключ 2 вне 1..n',
        },
        {
            function()
                value.params('mysql', { n = 2, [1.5] = 'x' })
            end,
            'params: ключ 1.5 вне 1..n',
        },
        {
            function()
                value.params('mysql', { n = 1, name = 'x' })
            end,
            'params: ключ name вне 1..n',
        },
        {
            function()
                value.params('mysql', { n = 1, { 1 } })
            end,
            'значение table нельзя передать параметром: таблицу оберните json, байты — binary',
        },
        {
            function()
                value.params('oracle', { n = 0 })
            end,
            'диалект oracle незнаком: есть postgres, mysql, tarantool, redis, mongo',
        },
        {
            function()
                driver_params({ n = 1, 'a', 'b' })
            end,
            'params: ключ 2 вне 1..n',
        },
        {
            function()
                driver_params({ n = 1, { 1 } })
            end,
            'значение table нельзя передать параметром: таблицу оберните json, байты — binary',
        },
        {
            function()
                driver_params({ 1 })
            end,
            'params.n — целое число, а не nil',
        },
    })
end
