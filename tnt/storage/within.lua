--- Срок вызова хранилища: откуда он берётся, где кончается и как доводится
--- до рока, у которого срока нет вовсе.
---
--- Роки `pg` и `mysql` не знают срока ни на вход, ни на запрос: вызов
--- к молчащему серверу не вернётся никогда. Правило одно на все драйверы:
---
--- 1. Без срока звать нельзя. Срок вызова — `timeout` из его настроек, иначе
---    срок драйвера, по умолчанию 5 с. Ноль, отрицательное, NaN
---    и бесконечность — исключение: ожидание без срока не ждёт никого.
--- 2. Срок не длиннее потолка `max_timeout` драйвера: отменённый
---    запрос дорабатывает на сервере, и у PostgreSQL потолком служит
---    `statement_timeout` соединения, равный `max_timeout`. Вызов со сроком
---    длиннее потолка — исключение.
--- 3. Миг срока отмечается один раз, на входе вызова, настоящими часами:
---    `deadline = monotonic() + timeout`. Перед каждым ожиданием — пула,
---    входа, ответа, паузы повтора — остаток считается заново от времени
---    планировщика: `deadline - scheduler_now()`. Работа без уступки
---    перед вызовом срок не съедает, а ожидание кончается ровно в миг.
--- 4. Ответ ждётся в отдельном файбере: работник зовёт рок, вызывающий ждёт
---    итога с остатком срока. Не дождался — отменяет работника, и драйвер
---    выбрасывает соединение: в сокете остался недочитанный ответ.
--- 5. Отменённого в ожидании вызывающего `call` не прячет: работник
---    отменяется, как по сроку, а отмена бросается дальше, мимо драйвера.
---    Драйвер, который зовёт `call` без `pcall`, соединение из пула
---    не вернёт и не выбросит — оно останется занятым до конца жизни
---    узла. Поэтому бросок драйвер ловит сам и считает исходом `expired`:
---    выбрасывает соединение без ожидания — в отменённом файбере каждое
---    ожидание бросает отмену снова, — а отмену поднимает после,
---    `fiber.testcancel()`: отменили вызывающего, а не вызов.
---
---     local within = require('tnt.storage.within')
---
---     local limits = within.settings(opts.timeout, opts.max_timeout)  -- в new драйвера
---     local timeout = within.timeout(call_opts.timeout, limits)        -- в вызове
---     local deadline = within.deadline(timeout)
---
---     local called, status, rows = pcall(within.call, deadline, function()
---         return conn:execute(sql, unpack(params, 1, params.n))
---     end)
---
---     if not called then
---         status = within.EXPIRED  -- отменили вызывающего: соединение — как по сроку
---     end
---
---     -- … вернуть соединение либо выбросить по исходу …
---
---     fiber.testcancel()           -- отмена — дальше, соединение уже выброшено
---
--- Исход `call` — слово: `returned` (тело вернуло, дальше — его значения),
--- `raised` (тело бросило, дальше — брошенное), `expired` (срок вышел
--- в ожидании, работник отменён), `skipped` (срок вышел раньше, тело не
--- звалось — соединение чисто). Итог, пришедший после отмены, уходит
--- в `late` в файбере работника: соединение, открытое опоздавшим входом,
--- закрывается там, где оно появилось.

local fiber = require('fiber')

local clock = require('tnt.clock')
local context = require('tnt.context')
local must = require('tnt.must')
local external = require('tnt.external')

local Module = {}

--- Срок вызова по умолчанию, секунд.
---
--- Пять: запрос к базе, не ответивший за пять секунд, упёрся не в работу,
--- а в перегруз или блокировку, и честный отказ полезнее очереди ждущих.
--- Столько же ждёт соединения `tnt-pool`.
Module.DEFAULT_TIMEOUT = 5

--- Потолок срока вызова по умолчанию, секунд.
---
--- Минута: отменённый запрос дорабатывает на сервере до потолка, и потолок
--- длиннее минуты держал бы брошенную работу дольше, чем ждёт её любой
--- запрос к узлу. Отчёту и миграции, которым нужно дольше, потолок
--- поднимают настройкой драйвера.
Module.DEFAULT_MAX_TIMEOUT = 60

--- Тело вернуло; за словом — его значения.
Module.RETURNED = 'returned'

--- Тело бросило; за словом — брошенное.
Module.RAISED = 'raised'

--- Срок вышел в ожидании: работник отменён, итог уйдёт в `late`.
Module.EXPIRED = 'expired'

--- Срок вышел до начала: тело не звалось.
Module.SKIPPED = 'skipped'

--- Имя файбера работника: его видно в `fiber.info()`.
Module.WORKER = 'tnt.storage.within'

--- Действующие часы.
local source = external.install(Module, {
    monotonic = clock.monotonic,
    scheduler_now = clock.scheduler_now,
})

--- Значения со счётом: `nil` посреди и в конце не теряются.
---@param ... any
---@return table
local function pack(...)
    return { n = select('#', ...), ... }
end

---@class TntStorageLimits Сроки драйвера
---@field timeout number Срок вызова по умолчанию, секунд
---@field max_timeout number Потолок срока вызова, секунд

--- Проверенный срок: число секунд больше нуля и меньше бесконечности.
---@param value any
---@param name string Как назвать настройку в отказе
---@param level integer Уровень вины для `error` из кадра того, кто зовёт
---@return number
local function span_of(value, name, level)
    if type(value) ~= 'number' or not (value > 0 and value < math.huge) then
        error(
            ('%s — число секунд больше нуля и меньше бесконечности, а не %s'):format(
                name,
                tostring(value)
            ),
            level + 1
        )
    end

    return value
end

--- Сроки драйвера из его настроек.
---
--- Срок по умолчанию длиннее потолка — исключение: драйвер, которому
--- потолок задали меньше пяти секунд, а срок не задали, иначе отказывал бы
--- на каждом вызове без срока.
---@param timeout number|nil Срок вызова по умолчанию; nil — `DEFAULT_TIMEOUT`
---@param max_timeout number|nil Потолок; nil — `DEFAULT_MAX_TIMEOUT`
---@param level integer|nil Уровень вины, как у `error`, в кадрах того, кто зовёт эту функцию:
--- 1 — его строка (по умолчанию), 2 — его вызывающий
---@return TntStorageLimits
function Module.settings(timeout, max_timeout, level)
    local depth = (level or 1) + 1
    local ceiling = span_of(max_timeout or Module.DEFAULT_MAX_TIMEOUT, 'max_timeout', depth)
    local span = span_of(timeout or Module.DEFAULT_TIMEOUT, 'timeout', depth)

    if span > ceiling then
        error(('timeout %s с длиннее потолка max_timeout %s с'):format(span, ceiling), depth)
    end

    return { timeout = span, max_timeout = ceiling }
end

--- Срок одного вызова.
---@param given number|nil Срок из настроек вызова; nil — срок драйвера
---@param limits TntStorageLimits Сроки драйвера из `settings`
---@param level integer|nil Уровень вины, как у `settings`
---@return number
function Module.timeout(given, limits, level)
    local depth = (level or 1) + 1

    if given == nil then
        return limits.timeout
    end

    local span = span_of(given, 'timeout', depth)

    if span > limits.max_timeout then
        error(('timeout %s с длиннее потолка max_timeout %s с'):format(span, limits.max_timeout), depth)
    end

    return span
end

--- Миг срока: настоящие часы в миг вызова плюс срок.
---
--- Отметка цикла событий тут не годится: она отстаёт на всю работу без
--- уступки перед вызовом, и срок, отсчитанный от неё, кончался бы раньше.
---@param timeout number
---@return number
function Module.deadline(timeout)
    return source().monotonic() + timeout
end

--- Остаток до мига — для ожидания, которое начинается сейчас.
---
--- От времени планировщика: от него же ожидание отсчитает свой срок и
--- кончится ровно в миг, была ли перед ним работа без уступки или нет.
---@param deadline number
---@return number Секунд; ноль и меньше — срок вышел
function Module.left(deadline)
    return deadline - source().scheduler_now()
end

--- Зовёт тело в работнике и ждёт итога до мига.
---
--- Тело зовётся под контекстом вызывающего (`tnt-context`): хранилище
--- файбера в работнике пусто, и запись из тела потеряла бы `request_id`.
--- Брошенное телом ловится и отдаётся словом `raised`: рок отказывает
--- исключением, а драйвер — парой.
---
--- Вызывающего, которого отменили в ожидании, `call` не прячет: работник
--- отменяется, как по сроку, а исключение отмены идёт дальше. Драйвер
--- с соединением из пула ловит его сам (п. 5 шапки модуля): иначе
--- соединение останется занятым.
---@param deadline number Миг срока из `deadline`
---@param fn fun(): any Тело: вызов рока
---@param late fun(ok: boolean, ...: any)|nil Куда деть итог, пришедший после отмены: то же, что отдал бы `pcall(fn)`
---@return string status returned, raised, expired либо skipped
---@return any ... Значения тела либо брошенное
function Module.call(deadline, fn, late)
    local caller = must.at(2)

    caller.number(deadline, 'миг срока')
    caller.callable(fn, 'тело')
    caller.optional.callable(late, 'приёмник опоздавшего итога')

    local left = Module.left(deadline)

    if left <= 0 then
        return Module.SKIPPED
    end

    -- Канал без буфера: работник кладёт итог, только пока вызывающий ждёт.
    -- Вызывающий, перестав ждать, отмечает `expired` без единой уступки,
    -- а ждущему, чей срок уже вышел, но который ещё не проснулся, итог
    -- передаётся прямо в руки (проверено на 3.8) — класть некуда не бывает.
    local done = fiber.channel()
    -- Отмечено вызывающим, когда он перестал ждать: работник по этой отметке
    -- решает, кому отдать итог.
    ---@type { expired: boolean }
    local state = { expired = false }
    local worker = fiber.new(context.bind(function()
        local result = pack(pcall(fn))

        if state.expired then
            if late ~= nil then
                late(unpack(result, 1, result.n))
            end

            return
        end

        done:put(result)
    end))

    worker:name(Module.WORKER)

    local waited, result = pcall(done.get, done, left)

    if not waited or result == nil then
        state.expired = true
        -- Под pcall: из отменённого вызывающего `cancel` чужого файбера
        -- бросает отмену сразу, уже отменив работника, — а бросок здесь
        -- один, ниже, тем же значением, что поймано.
        pcall(worker.cancel, worker)

        -- Отмена вызывающего приходит объектом `box.error`, и место к нему
        -- не приписывается: бросается то же, что поймано.
        if not waited then
            error(result)
        end

        return Module.EXPIRED
    end

    if result[1] then
        return Module.RETURNED, unpack(result, 2, result.n)
    end

    return Module.RAISED, result[2]
end

return Module
