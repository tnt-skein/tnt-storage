--- Кодирование значений параметров: что передать року, чтобы сервер
--- получил ровно то, что дал вызывающий.
---
--- Каждый рок портит своё: `pg` пишет строку `'0012'` числом `12`, число
--- длиннее четырнадцати значащих цифр — с потерей хвоста, `int64`
--- и таблицу в текстовый столбец — NULL; `mysql` пишет NULL вместо
--- `decimal` и `uuid`. Правило «чем передавать `int64`» поэтому живёт
--- в одном месте на все драйверы и построители запросов: разнесённое
--- по ним, оно разойдётся.
---
--- Главное — `wire(dialect, value)` → `значение, приведение`. Значение —
--- то, что рок передаст без порчи; приведение — тип для PostgreSQL
--- (`int8`, `numeric`, `uuid`, `timestamptz`, `jsonb`, `bytea`), который
--- построитель запросов ставит в текст как `$n::тип`. Без приведения сервер
--- отказывает громко («expression is of type text»), а не молча.
---
--- Целое число у PostgreSQL тоже уходит с приведением — `int8`. Рок шлёт
--- всякое число типом `numeric`, и сравнение целого столбца с `numeric`
--- идёт мимо индекса: поиск по ключу становится просмотром всей таблицы.
--- Тип столбца модулю неизвестен, а `int8` сравнивается с `int2`, `int4`
--- и `int8` операторами того же семейства, что у индекса целых.
---
--- | Значение | `postgres` | `mysql` | `tarantool` | `redis` |
--- |---|---|---|---|---|
--- | `nil`, `box.NULL` | `box.NULL` | `box.NULL` | `box.NULL` | исключение |
--- | логика | как есть | как есть | как есть | исключение |
--- | строка | как есть | как есть | как есть | как есть |
--- | целое до 14 значащих цифр | как есть, `int8` | как есть | как есть | цифры |
--- | целое длиннее, до ±2⁵³ | цифры, `int8` | как есть | как есть | цифры |
--- | дробное до 14 значащих цифр | как есть | как есть | как есть | точный текст |
--- | дробное длиннее | точный текст, `numeric` | как есть | как есть | точный текст |
--- | число за ±2⁵³, NaN, бесконечность | исключение | исключение | исключение | исключение |
--- | `int64`, `uint64` | текст, `int8` (`numeric` выше 2⁶³−1) | текст | как есть | текст |
--- | `decimal` | текст, `numeric` | текст | как есть | текст |
--- | `uuid` | текст, `uuid` | текст | как есть | текст |
--- | `datetime` | ISO 8601 со сдвигом, `timestamptz` | UTC без пояса | как есть | ISO 8601 со сдвигом |
--- | `json(v)` | текст JSON, `jsonb` | текст JSON | текст JSON | текст JSON |
--- | `binary(s)`, `varbinary` | `\x…`, `bytea` | байты | `varbinary` | байты |
---
--- У `mongo` второе значение — не приведение, а тип BSON, которым значение
--- уйдёт: документ BSON несёт тип при каждом значении, и выбирать его
--- по месту, как делал бы каждый драйвер сам, значит однажды выбрать
--- по-разному.
---
--- | Значение | `mongo` |
--- |---|---|
--- | `nil`, `box.NULL` | `box.NULL`, `null` |
--- | логика, строка | как есть, `bool`, `string` |
--- | целое до ±2³¹, до ±2⁵³ | как есть, `int32`, `int64` |
--- | дробное | как есть, `double` |
--- | целое больше 2⁵³, NaN, бесконечность | исключение |
--- | `int64`, `uint64` до 2⁶³−1 | `int64`; `uint64` выше — исключение |
--- | `decimal`, `uuid` | как есть, `decimal128`, `uuid` |
--- | `datetime` | миллисекунды `int64`, `date` |
--- | `json(v)` | текст JSON, `string` |
--- | `binary(s)`, `varbinary` | байты, `binary` |
---
--- Время у `mongo` — миллисекунды от начала эпохи: у типа `date` точность
--- миллисекунда, и остаток отбрасывается вниз, как отбрасывает его сервер
--- у времени, пришедшего от любого клиента. Таблица без обёртки — документ
--- BSON, и собирает его драйвер, а не модуль.
---
--- У `redis` значение — всегда строка байтов: команда Redis — это список
--- строк. Целое уходит цифрами без степени (`1e15` — `1000000000000000`:
--- `INCRBY` запись `1e+15` отвергает, проверено на 7.4), дробное — самой
--- короткой точной записью. Пустоты и логики у Redis нет вовсе, и угадывать
--- за вызывающего, `''` это или `'0'`, `'false'` или `'0'`, модуль не берётся.
---
--- Строка с нулевым байтом у `postgres` — отказ данных третьим значением
--- (`nil, nil, err` рода `rejected`, `sent = false`): рок обрезал бы её
--- молча. Всё прочее — таблица без обёртки, функция, иной cdata —
--- исключение: передать это нельзя, и ошибся тот, кто передаёт.
--- То же у NaN и бесконечности где угодно внутри `json(v)`: JSON их
--- не выражает, и отказ сервера пришёл бы лишним обращением к сети.
---
--- NULL всегда `box.NULL`, а не `nil`: `box.execute` теряет всё после дыры
--- в массиве параметров (`{ 1, nil, 3 }` доезжает как `1, NULL, NULL`,
--- проверено на 3.8), а оба рока принимают `box.NULL` за NULL.
---
--- Выборка значений не приводит: рок не отдаёт типов столбцов, и угадывать
--- тип по значению значит портить строки, похожие на числа. Двоичное из
--- ответа достаёт `decode_binary`.

local datetime = require('datetime')
local decimal = require('decimal')
local ffi = require('ffi')
local json = require('json')
local must = require('tnt.must')
local uuid = require('uuid')
local varbinary = require('varbinary')

local exact = require('tnt.storage.exact')
local failure = require('tnt.storage.failure')

local Module = {}

--- PostgreSQL: знак параметра `$n`, приведение в тексте запроса.
Module.POSTGRES = 'postgres'

--- MySQL: знак параметра `?`.
Module.MYSQL = 'mysql'

--- SQL самого Tarantool (`box.execute`) и спейсы: родные типы msgpack.
Module.TARANTOOL = 'tarantool'

--- Redis: всякое значение — строка байтов.
Module.REDIS = 'redis'

--- MongoDB: значение уходит типом BSON; второе значение — имя типа.
Module.MONGO = 'mongo'

--- Диалекты, которые модуль знает: для отказа и для сверки.
local KNOWN = 'postgres, mysql, tarantool, redis, mongo'

---@type table<any, boolean>
local DIALECTS = {
    [Module.POSTGRES] = true,
    [Module.MYSQL] = true,
    [Module.TARANTOOL] = true,
    [Module.REDIS] = true,
    [Module.MONGO] = true,
}

--- Больше этого `uint64` в `int8` PostgreSQL не помещается: 2⁶³ − 1.
--- Тот же предел у `int64` BSON: беззнакового целого в нём нет.
local INT8_MAX = 9223372036854775807ULL

--- Граница `int32` BSON: целое за ±2³¹ уходит `int64`.
local INT32 = 2 ^ 31

--- Время для PostgreSQL и Redis: ISO 8601 со сдвигом числом, а не именем
--- пояса. `tostring` у даты с поясом отдаёт «… Europe/Moscow», и имя пояса
--- у сервера и у того, кто прочтёт строку из Redis, может значить другое.
local ISO_TIME = '%Y-%m-%dT%H:%M:%S.%6f%z'

--- Время для MySQL: `DATETIME` пояса не хранит, поэтому пишется миг в UTC.
local MYSQL_TIME = '%Y-%m-%d %H:%M:%S.%6f'

--- Нулевой байт образцом: `%z` — его класс в образцах Lua 5.1.
local ZERO_BYTE = '%z'

--- Отказ о `bytea` не в шестнадцатеричном виде.
local NOT_HEX =
    "bytea не в виде \\x…: столбец не bytea либо сервер отдаёт bytea_output = 'escape'"

--- JSON своим кодировщиком: чужой `json.cfg` не должен менять то, что
--- уходит в базу.
---
--- NaN и бесконечность он не пишет: по умолчанию они ушли бы словами
--- `nan` и `inf`, а это не JSON — `jsonb` и службы поверх HTTP отвергли бы
--- значение уже на сервере, лишним обращением к сети и своими словами,
--- а не на строке того, кто передал негодное число. Правило то же, что
--- у параметров (`exact.check`).
local encoder = json.new()

encoder.cfg({ encode_invalid_numbers = false })

--- Опции второго прохода, который нечисла пишет: удался он — значит,
--- кодированию мешали только они.
local INVALID_NUMBERS = { encode_invalid_numbers = true }

--- Отказ о нечисле внутри значения JSON.
local NOT_A_NUMBER =
    'значение не кодируется в JSON: NaN и бесконечность не выражаются'

--- Обёртка JSON: значение, закодированное в миг вызова `json`.
local Json = {}

--- Обёртка двоичного: байты, которые рок иначе принял бы за текст.
local Binary = {}

--- Имя диалекта: строка либо таблица диалекта с полем `name`.
---@param dialect any
---@param level integer Уровень вины для `error` из кадра того, кто зовёт
---@return string
local function name_of(dialect, level)
    local name = dialect

    if type(dialect) == 'table' then
        name = dialect.name
    end

    if not DIALECTS[name] then
        error(('диалект %s незнаком: есть %s'):format(tostring(name), KNOWN), level + 1)
    end

    return name
end

--- Число: без потерь либо исключение (`tnt.storage.exact`).
---@param dialect string
---@param number number
---@param level integer
---@return number|string value
---@return string|nil cast
local function wire_number(dialect, number, level)
    exact.check(number, level + 1)

    -- У Redis всякое число — текст: `%.14g` отдал бы `1e+15`, а такой
    -- записи `INCRBY` не принимает.
    if dialect == Module.REDIS then
        return exact.digits(number)
    end

    if dialect ~= Module.POSTGRES then
        return number
    end

    -- Целое — с `int8`: без приведения рок шлёт его `numeric`, и сравнение
    -- с целым столбцом идёт мимо индекса. Само число остаётся числом, а не
    -- текстом: драйвер отдаёт року значение без приведения, и в тексте,
    -- написанном руками без `$n::int8`, число сравнится как `numeric` —
    -- медленно, но верно, а текст отказал бы «operator does not exist:
    -- integer = text».
    local cast = math.floor(number) == number and 'int8' or nil

    -- Рок пишет число текстом `%.14g`, и всё, что длиннее, уходит точным
    -- текстом; дробному нужен тогда `numeric` — у текста типа нет.
    if tonumber(tostring(number)) ~= number then
        return exact.digits(number), cast or 'numeric'
    end

    return number, cast
end

--- Целое `int64`/`uint64` текстом без приписки `LL`/`ULL`.
---@param dialect string
---@param number ffi.cdata*
---@return any value
---@return string|nil cast
local function wire_integer(dialect, number)
    if dialect == Module.TARANTOOL then
        return number
    end

    local text = (tostring(number):gsub('U?LL$', ''))

    if dialect ~= Module.POSTGRES then
        return text
    end

    if ffi.istype('uint64_t', number) and number > INT8_MAX then
        return text, 'numeric'
    end

    return text, 'int8'
end

--- Дата и время по диалекту.
---@param dialect string
---@param moment any datetime
---@return any value
---@return string|nil cast
local function wire_datetime(dialect, moment)
    if dialect == Module.TARANTOOL then
        return moment
    end

    if dialect == Module.MYSQL then
        return datetime.new({ timestamp = moment.epoch, nsec = moment.nsec }):format(MYSQL_TIME)
    end

    local text = moment:format(ISO_TIME)

    if dialect == Module.POSTGRES then
        return text, 'timestamptz'
    end

    return text
end

--- Байты по диалекту.
---@param dialect string
---@param bytes string
---@return any value
---@return string|nil cast
local function wire_binary(dialect, bytes)
    if dialect == Module.TARANTOOL then
        return varbinary.new(bytes)
    end

    if dialect == Module.POSTGRES then
        return '\\x' .. bytes:hex(), 'bytea'
    end

    return bytes
end

--- Значение cdata: целое, точное, опознаватель, время, байты.
---@param dialect string
---@param value any
---@param level integer
---@return any value
---@return string|nil cast
local function wire_cdata(dialect, value, level)
    if ffi.istype('int64_t', value) or ffi.istype('uint64_t', value) then
        return wire_integer(dialect, value)
    end

    if datetime.is_datetime(value) then
        return wire_datetime(dialect, value)
    end

    if varbinary.is(value) then
        return wire_binary(dialect, tostring(value))
    end

    local cast

    if decimal.is_decimal(value) then
        cast = 'numeric'
    elseif uuid.is_uuid(value) then
        cast = 'uuid'
    else
        error(
            ('значение %s нельзя передать параметром: таблицу оберните json, байты — binary'):format(
                tostring(ffi.typeof(value))
            ),
            level + 1
        )
    end

    if dialect == Module.TARANTOOL then
        return value
    end

    if dialect == Module.POSTGRES then
        return tostring(value), cast
    end

    return tostring(value)
end

--- Типы BSON значений, которые уходят как есть, и cdata — с тем, во что
--- его превратить.
local PLAIN_BSON = { boolean = 'bool', string = 'string' }
local CDATA_BSON =
    { { varbinary.is, 'binary', tostring }, { decimal.is_decimal, 'decimal128' }, { uuid.is_uuid, 'uuid' } }

--- Отказ о значении, которого BSON не выразит.
local NOT_BSON =
    'значение %s не уходит в BSON: документ — таблица, байты — binary'

--- Значение для MongoDB и тип BSON, которым оно уйдёт.
---
--- Числа сверяются тем же правилом, что у прочих диалектов: NaN,
--- бесконечность и целое за ±2⁵³ — исключение. `uint64` выше 2⁶³−1 —
--- тоже: беззнакового целого в BSON нет, и `int64` прочёл бы его
--- отрицательным. Время — миллисекунды `int64`: `epoch` у даты — целые
--- секунды, а `nsec` не бывает отрицательным, и остаток отбрасывается вниз
--- и до эпохи.
---@param value any
---@param level integer
---@return any value
---@return string bson Тип BSON
local function wire_mongo(value, level)
    if value == nil then
        return box.NULL, 'null'
    end

    if PLAIN_BSON[type(value)] ~= nil then
        return value, PLAIN_BSON[type(value)]
    end

    if type(value) == 'number' then
        exact.check(value, level + 1)

        if value % 1 ~= 0 then
            return value, 'double'
        end

        return value, (value < -INT32 or value >= INT32) and 'int64' or 'int32'
    end

    if ffi.istype('uint64_t', value) and value > INT8_MAX then
        error(('uint64 %s не уходит в BSON: он больше 2^63−1'):format(tostring(value)), level + 1)
    end

    if ffi.istype('int64_t', value) or ffi.istype('uint64_t', value) then
        return ffi.cast('int64_t', value), 'int64'
    end

    if datetime.is_datetime(value) then
        return ffi.cast('int64_t', value.epoch) * 1000 + math.floor(value.nsec / 1e6), 'date'
    end

    for _, rule in ipairs(CDATA_BSON) do
        if rule[1](value) then
            return rule[3] and rule[3](value) or value, rule[2]
        end
    end

    local marker = getmetatable(value)

    if marker == Json or marker == Binary then
        return value.text or value.bytes, marker == Json and 'string' or 'binary'
    end

    error(NOT_BSON:format(type(value)), level + 1)
end

--- Значение параметра, которое рок передаст без порчи, и приведение для
--- PostgreSQL.
---
--- Отказ данных — третьим значением: строка с нулевым байтом у `postgres`.
--- Значение, которое передать нельзя вовсе, — исключение.
---@param dialect string|{ name: string } Диалект: имя либо таблица диалекта драйвера
---@param value any
---@param level integer|nil Уровень вины, как у `error`, в кадрах того, кто зовёт эту функцию:
--- 1 — его строка (по умолчанию), 2 — его вызывающий
---@return any value Что передать року
---@return string|nil cast Приведение для PostgreSQL; у `mongo` — тип BSON; у прочих — nil
---@return TntStorageFailure|nil err Отказ данных
function Module.wire(dialect, value, level)
    local depth = (level or 1) + 1
    local name = name_of(dialect, depth)

    -- Хвостовой вызов снимает кадр этой функции: уровень вины у броска
    -- из `wire_mongo` поэтому на единицу меньше.
    if name == Module.MONGO then
        return wire_mongo(value, depth - 1)
    end

    local kind = type(value)

    -- `value == nil` верно и для `box.NULL`: сравнение cdata с пустым
    -- указателем в LuaJIT даёт равенство с `nil`.
    if name == Module.REDIS and (value == nil or kind == 'boolean') then
        error(
            ('%s в Redis не передать: у него только строки — передайте строку явно'):format(
                value == nil and 'пустое значение' or 'логику'
            ),
            depth
        )
    end

    if value == nil then
        return box.NULL
    end

    if kind == 'boolean' then
        return value
    end

    -- Не хвостовым вызовом: без кадра этой функции уровень вины в бросках
    -- ниже ушёл бы на строку дальше вызывающего.
    local wired, cast

    if kind == 'number' then
        wired, cast = wire_number(name, value, depth)

        return wired, cast
    end

    if kind == 'string' then
        if name == Module.POSTGRES and value:find(ZERO_BYTE) then
            return nil,
                nil,
                failure.new(
                    failure.REJECTED,
                    'строка с нулевым байтом: pg обрезал бы её молча',
                    {
                        sent = false,
                    }
                )
        end

        return value
    end

    if kind == 'cdata' then
        wired, cast = wire_cdata(name, value, depth)

        return wired, cast
    end

    local marker = getmetatable(value)

    if kind == 'table' and marker == Json then
        return value.text, name == Module.POSTGRES and 'jsonb' or nil
    end

    if kind == 'table' and marker == Binary then
        return wire_binary(name, value.bytes)
    end

    error(
        ('значение %s нельзя передать параметром: таблицу оберните json, байты — binary'):format(
            kind
        ),
        depth
    )
end

--- Значение, которое уйдёт текстом JSON.
---
--- Кодируется сразу, в миг вызова: таблица, поправленная после, в базу
--- не попадёт, а значение, которое JSON не выражает (функция, NaN,
--- бесконечность — где угодно в глубине), бросает здесь, на строке
--- вызывающего. Пустая таблица — массив либо объект по `__serialize`,
--- как у `json.encode`: пустоту модуль не угадывает.
---@param value any
---@return table
function Module.json(value)
    local ok, text = pcall(encoder.encode, value)

    if ok then
        return setmetatable({ text = text }, Json)
    end

    -- Причину называет второй проход, а не сверка с текстом отказа ядра:
    -- тот не наш и может смениться, а итог прохода, которому нечисла
    -- разрешены, от слов не зависит. Значение с функцией не кодируется
    -- и так, и отказ берётся из второго прохода: первый мог споткнуться
    -- о нечисло раньше, чем дошёл до функции.
    local lenient, reason = pcall(encoder.encode, value, INVALID_NUMBERS)

    if lenient then
        error(NOT_A_NUMBER, 2)
    end

    error(('значение не кодируется в JSON: %s'):format(tostring(reason)), 2)
end

--- Байты, которые уйдут двоичным значением: `bytea` у PostgreSQL, `BLOB`
--- у MySQL, `varbinary` у Tarantool.
---@param bytes string
---@return table
function Module.binary(bytes)
    must.at(2).string(bytes, 'байты')

    return setmetatable({ bytes = bytes }, Binary)
end

--- Байты из ответа.
---
--- PostgreSQL отдаёт `bytea` текстом `\x…`, MySQL — байтами, Tarantool —
--- `varbinary`. NULL (нет ключа) остаётся `nil`. Текст не в виде `\x…`
--- у PostgreSQL — исключение: это столбец не `bytea` либо сервер отдаёт
--- `bytea_output = 'escape'`, и угадывать тут нечего.
---@param dialect string|{ name: string }
---@param raw any Значение столбца
---@return string|nil
function Module.decode_binary(dialect, raw)
    local name = name_of(dialect, 2)

    if raw == nil then
        return nil
    end

    if varbinary.is(raw) then
        return tostring(raw)
    end

    must.at(2).string(raw, 'значение столбца')

    if name ~= Module.POSTGRES then
        return raw
    end

    local hex = raw:match('^\\x(%x*)$')

    if hex == nil or #hex % 2 == 1 then
        error(NOT_HEX, 2)
    end

    return (hex:fromhex())
end

--- Проверенные и закодированные параметры вызова.
---
--- Параметры — массив с полем `n`: без `n` нельзя передать `nil`
--- посреди значений. Таблица без `n`, ключ вне `1..n` — исключение: рок
--- принял бы таблицу одним значением и молча записал NULL. Отказ
--- данных у любого значения — пара `nil, err`.
---@param dialect string|{ name: string }
---@param params table|nil Параметры; `nil` — ни одного
---@param level integer|nil Уровень вины, как у `wire`
---@return table|nil encoded Значения с тем же `n`
---@return TntStorageFailure|nil err
function Module.params(dialect, params, level)
    local depth = (level or 1) + 1
    local name = name_of(dialect, depth)
    local given = params or { n = 0 }
    local caller = must.at(depth)

    caller.table(given, 'params')
    caller.integer(given.n, 'params.n')
    caller.non_negative(given.n, 'params.n')

    for key in pairs(given) do
        if key ~= 'n' and not (type(key) == 'number' and key % 1 == 0 and key >= 1 and key <= given.n) then
            error(('params: ключ %s вне 1..n'):format(tostring(key)), depth)
        end
    end

    local encoded = { n = given.n }

    for index = 1, given.n do
        local value, _, refusal = Module.wire(name, given[index], depth)

        if refusal ~= nil then
            return nil, refusal
        end

        encoded[index] = value
    end

    return encoded
end

return Module
