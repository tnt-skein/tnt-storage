--- Отказ хранилища: таблица с родом и приговором, которая читается и как
--- строка.
---
--- Драйверы хранилищ отказывают одним видом: иначе у каждого драйвера
--- заведётся свой способ сказать «сеть пропала» и «сервер отказал»,
--- и потребитель — кэш, поиск, модель — будет разбирать столько видов
--- отказа, сколько драйверов, вместо одного.
---
--- Главное поле — род (`kind`), и родов ровно девять:
---
--- * `unreachable` — соединение не открылось: сеть, вход не уложился в срок;
--- * `denied` — сервер отказал во входе: пароль, нет базы, нет прав;
--- * `busy` — за срок не досталось соединения из пула;
--- * `timeout` — ответа нет за срок вызова либо сработал срок сервера;
--- * `broken` — соединение оборвалось посреди работы;
--- * `rejected` — сервер отказал оператору: синтаксис, ограничение, данные;
---   либо значение, которое драйвер не отправил вовсе;
--- * `conflict` — конфликт сериализации, взаимоблокировка, ожидание
---   блокировки: повторять можно только всю транзакцию;
--- * `closed` — драйвер закрыт;
--- * `overflow` — строк больше предела выборки.
---
--- Рядом с родом два признака, которые нужны повторам. `sent` — мог ли
--- оператор дойти до сервера: обрыв до отправки от обрыва после по тексту
--- не отличить, а драйвер знает это по месту, где отказ случился.
--- `retriable` — повторил бы драйвер сам: `tnt-retry` смотрит это поле
--- первым. Приговор по умолчанию выносит род: до отправки (`unreachable`,
--- `busy`) — да; после отправки (`timeout`, `broken`) — только с согласия
--- вызывающего, `idempotent = true`, потому что сервер мог оператор
--- выполнить; остальное время не лечит.
---
--- Текст (`message`) проходит `tnt-log.scrub`: адрес с паролем и пара
--- `password=…` прячутся, и отказ можно отдать наверх и записать в журнал
--- как есть. `reason` — первая строка текста: в `DETAIL` PostgreSQL кладёт
--- значения строки («Key (id)=(1) already exists»), и в журнал идёт
--- только первая.
---
--- Код сервера — поле `server_code`, а не `code`: `tnt-retry` поле `code`
--- не читает нарочно, а каталоги отказов приложения понимают под ним свой
--- код.
---
--- Как род выбирается по SQLSTATE, errno, тексту и коду HTTP, — в соседнем
--- `tnt.storage.codes`; здесь — только сборка отказа.

local codes = require('tnt.storage.codes')
local log = require('tnt.log')
local must = require('tnt.must')

local Module = {}

--- Соединение не открылось.
Module.UNREACHABLE = 'unreachable'

--- Сервер отказал во входе.
Module.DENIED = 'denied'

--- Соединения из пула за срок не досталось.
Module.BUSY = 'busy'

--- Ответа нет за срок.
Module.TIMEOUT = 'timeout'

--- Соединение оборвалось посреди работы.
Module.BROKEN = 'broken'

--- Сервер отказал оператору либо значение не отправлено.
Module.REJECTED = 'rejected'

--- Конфликт транзакций: повторять можно только всю транзакцию.
Module.CONFLICT = 'conflict'

--- Драйвер закрыт.
Module.CLOSED = 'closed'

--- Строк больше предела выборки.
Module.OVERFLOW = 'overflow'

--- Повторять всегда: сервер оператора не видел.
local ALWAYS = 'always'

--- Повторять, только если вызывающий назвал оператор идемпотентным.
local IDEMPOTENT = 'idempotent'

--- Не повторять: время не лечит.
local NEVER = 'never'

--- Умолчания рода: дошёл ли оператор до сервера и когда его повторять.
---
--- `timeout` здесь — срок, вышедший после
--- отправки; срок, вышедший до неё, драйвер отдаёт с `sent = false`,
--- и тогда повтора нет: повторять уже некогда.
---@type table<string, { sent: boolean, retry: string }>
local RULES = {
    [Module.UNREACHABLE] = { sent = false, retry = ALWAYS },
    [Module.DENIED] = { sent = false, retry = NEVER },
    [Module.BUSY] = { sent = false, retry = ALWAYS },
    [Module.TIMEOUT] = { sent = true, retry = IDEMPOTENT },
    [Module.BROKEN] = { sent = true, retry = IDEMPOTENT },
    [Module.REJECTED] = { sent = true, retry = NEVER },
    [Module.CONFLICT] = { sent = true, retry = NEVER },
    [Module.CLOSED] = { sent = false, retry = NEVER },
    [Module.OVERFLOW] = { sent = true, retry = NEVER },
}

--- Роды по порядку — для отказа о незнакомом роде.
local ORDER = {
    Module.UNREACHABLE,
    Module.DENIED,
    Module.BUSY,
    Module.TIMEOUT,
    Module.BROKEN,
    Module.REJECTED,
    Module.CONFLICT,
    Module.CLOSED,
    Module.OVERFLOW,
}

--- Роды отказов `tnt-http`, которые переводятся без разбора текста.
---
--- `invalid` — запрос не собран и не ушёл; `refused` — ответ был, но клиент
--- его не отдал; `idle` — поток молчал дольше срока чтения куска.
local HTTP = {
    invalid = { kind = Module.REJECTED, sent = false },
    refused = { kind = Module.REJECTED, sent = true },
    idle = { kind = Module.TIMEOUT, sent = true },
}

--- Род отказа `tnt-http`, у которого есть код ответа.
local HTTP_STATUS = 'status'

--- Род отказа `tnt-http` без ответа: сеть либо срок.
local HTTP_UNREACHABLE = 'unreachable'

--- Отказ `tnt-http` незнакомого рода: после отправки, как обрыв.
local HTTP_UNKNOWN = { kind = Module.BROKEN }

--- Настройки вызова, которые влияют на приговор повтору.
local CALL = { idempotent = '?boolean' }

--- Настройки отказа: незнакомый ключ — ошибка программиста.
local OPTIONS = {
    sent = '?boolean',
    retriable = '?boolean',
    idempotent = '?boolean',
    server_code = '?string|integer',
    reason = '?string',
}

---@class TntStorageFailure Отказ хранилища: род, приговор и текст
---@field kind string Род: unreachable, denied, busy, timeout, broken, rejected, conflict, closed либо overflow
---@field message string Текст для вызывающего, без тайн — его и отдаёт `tostring`
---@field reason string Первая строка — для журнала
---@field retriable boolean Повторил бы драйвер сам
---@field sent boolean Мог ли оператор дойти до сервера
---@field server_code string|integer|nil Код сервера: SQLSTATE, errno, код ответа HTTP

---@class TntStorageFailureOptions
---@field sent boolean|nil Мог ли оператор дойти до сервера; по умолчанию — по роду
---@field retriable boolean|nil Приговор повтору, если его выносит драйвер сам
---@field idempotent boolean|nil Согласен ли вызывающий на повтор после отправки
---@field server_code string|integer|nil Код сервера
---@field reason string|nil Причина для журнала, если текст несёт то, чего в журнал не пишут

--- Поведение всех отказов: строкой, в JSON и в склейке с любой стороны
--- они — свой текст, и отказ можно отдать туда, где прежде ждали строку.
local Failure = {
    __tostring = function(failure)
        return failure.message
    end,
    __concat = function(left, right)
        return tostring(left) .. tostring(right)
    end,
}

Failure.__serialize = Failure.__tostring

--- Первая строка текста.
---@param text string
---@return string
local function first_line(text)
    -- Образец совпадает всегда, хотя бы пустой строкой.
    return text:match('^[^\n]*') --[[@as string]]
end

--- Приговор повтору по роду, месту и согласию вызывающего.
---@param rule { sent: boolean, retry: string }
---@param sent boolean
---@param idempotent boolean|nil
---@return boolean
local function verdict(rule, sent, idempotent)
    if rule.retry == ALWAYS then
        return true
    end

    return rule.retry == IDEMPOTENT and sent and idempotent == true
end

--- Собирает отказ.
---
--- Незнакомый род — исключение: отказ рода, которого нет в договоре,
--- потребитель не разберёт, и ошибся тут тот, кто писал драйвер.
---@param kind string Род отказа
---@param message string Текст как есть: тайны прячутся здесь
---@param opts TntStorageFailureOptions|nil
---@param level integer|nil Уровень вины, как у `error`, в кадрах того, кто зовёт эту функцию:
--- 1 — его строка (по умолчанию), 2 — его вызывающий
---@return TntStorageFailure
function Module.new(kind, message, opts, level)
    local caller = must.at((level or 1) + 1)
    local rule = RULES[kind]

    if rule == nil then
        error(
            ('род отказа %s незнаком: есть %s'):format(tostring(kind), table.concat(ORDER, ', ')),
            (level or 1) + 1
        )
    end

    caller.string(message, 'текст отказа')
    caller.optional.options(opts, 'настройки отказа', OPTIONS)

    local given = opts or {}
    local sent = given.sent

    if sent == nil then
        sent = rule.sent
    end

    local retriable = given.retriable

    if retriable == nil then
        retriable = verdict(rule, sent, given.idempotent)
    end

    local text = log.scrub(message)
    local reason = text

    if given.reason ~= nil then
        reason = log.scrub(given.reason)
    end

    return setmetatable({
        kind = kind,
        message = text,
        reason = first_line(reason),
        retriable = retriable,
        sent = sent,
        server_code = given.server_code,
    }, Failure)
end

--- Отказ ли это хранилища, а не чужая таблица.
---@param value any
---@return boolean
function Module.is(value)
    return getmetatable(value) == Failure
end

--- Текст исключения рока без приписки места.
---
--- `error()` рока приписывает к тексту место — «…/pg/init.lua:129: », —
--- и вызывающему оно ничего не говорит, а текст длиннее. Место срезается,
--- только если оно в начале и без пробелов в пути: «ошибка в app.lua:5: »
--- посреди текста — это текст.
---@param err any Что бросил рок: строка, `box.error`, иное
---@return string
function Module.text(err)
    return (tostring(err):gsub('^%S-%.lua:%d+: ', ''))
end

--- Отказ входа: `denied` либо `unreachable`, до отправки.
---
--- Род решает код сервера, а без кода — слова отказа.
---@param err any Что бросил рок или отдал вход
---@param code string|integer|nil SQLSTATE либо errno, если рок его дал
---@return TntStorageFailure
function Module.login(err, code)
    local text = Module.text(err)

    return (Module.new(codes.login(code, text), text, { server_code = code }, 2))
end

--- Отказ оператора при живом соединении: `conflict`, `timeout`, `broken`
--- либо `rejected`, после отправки.
---
--- Живость драйвер проверяет сам и раньше: бросила — это `broken` без
--- всякого кода, и сюда такой отказ не идёт.
---@param err any Что бросил рок
---@param code string|integer|nil SQLSTATE либо errno, если рок его дал
---@param opts { idempotent: boolean|nil }|nil Согласен ли вызывающий на повтор после отправки
---@return TntStorageFailure
function Module.statement(err, code, opts)
    must.at(2).optional.options(opts, 'настройки вызова', CALL)

    local text = Module.text(err)

    return (
        Module.new(codes.statement(code, text), text, {
            server_code = code,
            idempotent = (opts or {}).idempotent,
        }, 2)
    )
end

--- Отказ по коду ответа HTTP: ответ пришёл, но это отказ.
---
--- 401 и 403 — `denied`, 409 и 412 — `conflict`, 429 и 503 — `busy`,
--- прочие 4xx — `rejected`, 5xx — `broken`.
---@param status integer Код ответа
---@param message string Текст для вызывающего: что за запрос и что ответили
---@param opts { idempotent: boolean|nil }|nil Согласен ли вызывающий на повтор после отправки
---@return TntStorageFailure
function Module.status(status, message, opts)
    local caller = must.at(2)

    caller.integer(status, 'код ответа')
    caller.optional.options(opts, 'настройки вызова', CALL)

    return (
        Module.new(codes.status(status), message, {
            server_code = status,
            idempotent = (opts or {}).idempotent,
        }, 2)
    )
end

--- Отказ `tnt-http` родом хранилища — для драйверов поверх HTTP.
---
--- Код ответа переводится, как у `status`; отказ сети — по признаку
--- `sent`, который ставит `tnt-http` (`codes.network`): точно не ушедший
--- запрос (`sent = false`) — `unreachable`, срок — `timeout`, прочее —
--- `broken`; отказ без признака мог уйти. `idle` — `timeout`, `invalid`
--- и `refused` — `rejected`. В журнальную причину идёт причина `tnt-http`
--- без адреса: в адресе ездят ключи доступа.
---@param err TntHttpFailure|table Отказ `tnt-http`
---@param opts { idempotent: boolean|nil }|nil Согласен ли вызывающий на повтор после отправки
---@return TntStorageFailure
function Module.http(err, opts)
    local caller = must.at(2)

    caller.table(err, 'отказ tnt-http')
    caller.optional.options(opts, 'настройки вызова', CALL)

    local message = tostring(err.message)
    local rule = HTTP[err.kind] or HTTP_UNKNOWN

    if err.kind == HTTP_STATUS then
        rule = { kind = codes.status(err.status) }
    elseif err.kind == HTTP_UNREACHABLE then
        rule = { kind = codes.network(message, err.sent) }
    end

    return (
        Module.new(rule.kind, message, {
            sent = rule.sent,
            idempotent = (opts or {}).idempotent,
            server_code = err.status,
            reason = err.reason,
        }, 2)
    )
end

return Module
