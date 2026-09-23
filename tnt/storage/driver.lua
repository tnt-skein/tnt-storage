--- Драйвер SQL над роком: пул, срок, повторы, транзакции и отказ парой —
--- одно на фасады над роками `pg` и `mysql`.
---
---     -- фасад целиком: настройки, знание рока, диалект, журнал, пул, повторы
---     return {
---         new = driver.facade({
---             dialect = { name = value.MYSQL },
---             check = settings.check,         -- driver.settings и своё
---             rock = rock,                    -- load(level), new(settings, loaded)
---             log = require('tnt.log').new('app.mysql'),
---             pool = require('tnt.pool'),
---             retry = require('tnt.retry'),
---         }),
---     }
---
---     local rows, err = db:query('select id from users where id = ?', { n = 1, 7 })
---
--- Оба рока — готовые неблокирующие, и фасаду над каждым нужно одно и то
--- же: пул `tnt-pool`, заведённый драйвером, с живостью и сбросом без сети;
--- один миг срока на вызов; повторы `tnt-retry` по полю `retriable` отказа;
--- выборка записями и предел строк; транзакция на одном соединении; вход —
--- пара `sql, params`. Всё это здесь, а у фасада — его настройки и знание
--- рока (`TntStorageRock`): написанное дважды, оно разошлось бы.
---
--- Пул и повторы драйвер заводит из модулей, которые ему дали аргументом:
--- `tnt-storage` не зависит ни от `tnt-pool`, ни от `tnt-retry`, и их
--- не тянут те, кому нужны только отказ, срок и значения.

local fiber = require('fiber')

local failure = require('tnt.storage.failure')
local link = require('tnt.storage.link')
local must = require('tnt.must')
local statement = require('tnt.storage.statement')
local transaction = require('tnt.storage.transaction')
local value = require('tnt.storage.value')
local within = require('tnt.storage.within')

local Module = {}

--- Предел строк выборки по умолчанию.
---
--- Роки читают ответ целиком, построчной выдачи у них нет: выборка
--- в миллион строк заняла бы память узла, в которой живут его данные.
--- Десять тысяч — больше любой страницы; большие выборки идут
--- постранично по ключу.
Module.DEFAULT_MAX_ROWS = 10000

--- Настройки пула, которые драйвер передаёт `tnt-pool` как есть: размер —
--- целое, прочее — секунды.
local POOL = { size = '?integer' }

for _, key in ipairs({
    'wait_timeout',
    'idle_timeout',
    'max_lifetime',
    'open_cooldown',
    'leak_timeout',
    'sweep_interval',
}) do
    POOL[key] = '?number'
end

--- Настройки повторов, которые драйвер передаёт `tnt-retry` как есть.
---
--- Срока и суждения о повторе здесь нет: срок у каждого вызова свой,
--- а судит поле `retriable` отказа.
local RETRY = { attempts = '?integer', jitter = '?number|string' }

for _, key in ipairs({ 'base', 'factor', 'max' }) do
    RETRY[key] = '?number'
end

--- Настройки драйверов над роком — у PostgreSQL и MySQL их набор один:
--- узел, учётная запись, база, шифрование, сроки, предел строк, пул,
--- повторы и имя. Незнакомый ключ — отказ: опечатка в имени (`pasword`)
--- иначе молча оставила бы драйвер без пароля. Что значит `tls`, решает
--- фасад: у `pg` — ключи libpq, у `mysql` — TLS со сверкой по корню.
--- Свои ключи фасад добавляет к этому набору сам и проверяет их до общих.
Module.OPTIONS = {
    host = '?not_empty',
    port = '?integer',
    user = 'not_empty',
    password = '?string',
    db = 'not_empty',
    tls = '?boolean|table',
    timeout = '?number',
    max_timeout = '?number',
    max_rows = '?integer',
    pool = { '?options', POOL },
    retry = { '?options', RETRY },
    name = '?not_empty',
}

--- Узел по умолчанию: служба на той же машине.
Module.DEFAULT_HOST = '127.0.0.1'

--- Настройки вызова: срок, согласие на повтор после отправки, предел строк.
local CALL = { timeout = '?number', idempotent = '?boolean', max_rows = '?integer' }

--- Параметры, когда их не дали.
local NONE = { n = 0 }

---@class TntStorageDriverSettings Общие настройки драйвера, проверенные
---@field name string Имя драйвера: в журнале, в имени пула и ведре повторов
---@field host string Узел
---@field port integer Порт
---@field user string Учётная запись
---@field password string|nil Пароль; наружу не отдаётся
---@field db string База
---@field where string Узел, порт и база — для текста отказа, без учётных данных
---@field limits TntStorageLimits Сроки вызова
---@field max_rows integer Предел строк выборки
---@field pool table Настройки пула как даны
---@field retry table Настройки повторов как даны

---@class TntStorageDriverParts Из чего драйвер собран
---@field rock TntStorageRock Знание рока
---@field dialect table Диалект: таблица с полем `name`, её отдаёт `db.dialect`
---@field log table Журнал фасада: записи идут под его именем
---@field pool { new: fun(opts: table): TntPool } Пакет `tnt-pool`
---@field retry { new: fun(opts: table): TntRetry|nil, string|nil } Пакет `tnt-retry`

---@class TntStorageDriver
---@field name string Имя драйвера
---@field features { transaction: boolean } Что драйвер умеет по договору
---@field dialect table Диалект: таблица с полем `name` и правилами построителя запросов
---@field where string Узел, порт и база
---@field limits TntStorageLimits Сроки вызова
---@field max_rows integer Предел строк выборки
---@field wait_timeout number Сколько ждать соединения из пула
---@field rock TntStorageRock Знание рока
---@field log table Журнал фасада
---@field pool TntPool Соединения
---@field retry TntRetry Повторы
---@field closed boolean Закрыт ли драйвер
---@field inside table<integer, boolean> Файберы, чья транзакция идёт сейчас
local Client = {}
Client.__index = Client

--- Проверяет настройки и дополняет их умолчаниями.
---
--- Проверяется всё и сразу, при заведении, а не там, где до настройки
--- впервые дошло дело: драйвер заводят при подъёме узла, а первый запрос
--- шлют через час под нагрузкой. Негодная настройка — исключение на строке
--- того, кто завёл драйвер. `user` и `db` обязательны: без них коннектор
--- взял бы имя пользователя машины, и узел вошёл бы туда, о чём
--- в настройках ни слова. Сроки проверяет `within.settings`, границы
--- пула и повторов — сами `tnt-pool` и `tnt-retry`; `tls` — фасад.
---@param opts table Настройки фасада
---@param title string Как настройки называются в отказе: «настройки mysql»
---@param defaults { name: string, port: integer } Имя драйвера и порт службы по умолчанию
---@param level integer Уровень вины, как у `error`, в кадрах того, кто зовёт
---@return TntStorageDriverSettings
function Module.settings(opts, title, defaults, level)
    local owner = must.at(level + 1)

    owner.options(opts, title, Module.OPTIONS)

    local port = opts.port or defaults.port

    owner.between(port, title .. '.port', 1, 65535)
    owner.optional.positive(opts.max_rows, title .. '.max_rows')

    local host = opts.host or Module.DEFAULT_HOST

    return {
        name = opts.name or defaults.name,
        host = host,
        port = port,
        user = opts.user,
        password = opts.password,
        db = opts.db,
        where = ('%s:%d/%s'):format(host, port, opts.db),
        limits = within.settings(opts.timeout, opts.max_timeout, level + 1),
        max_rows = opts.max_rows or Module.DEFAULT_MAX_ROWS,
        pool = opts.pool or {},
        retry = opts.retry or {},
    }
end

--- Заводит драйвер. Соединений не открывает: первое откроет первый вызов.
---@param settings TntStorageDriverSettings Проверенные общие настройки
---@param parts TntStorageDriverParts
---@param level integer Уровень вины для негодных повторов: строка того, кто завёл драйвер
---@return TntStorageDriver
function Module.new(settings, parts, level)
    local rock, log = parts.rock, parts.log
    local retries = table.copy(settings.retry)

    -- Бюджет и размыкатель повторов — на драйвер. Повторы заводятся раньше
    -- пула: негодная настройка бросает, не оставив пула без хозяина.
    retries.scope = settings.name

    local retrier, wrong = parts.retry.new(retries)

    if retrier == nil then
        -- Отказ повторов сам начинается словами «настройки повторов»,
        -- и своя приставка назвала бы те же настройки дважды.
        error(wrong, level + 1)
    end

    -- Пулу — его настройки как даны и крюки: вход в срок, закрытие
    -- выходом работника, живость и сброс без сети.
    local limits = table.copy(settings.pool)

    limits.name = settings.name
    limits.open = function(left)
        return link.open(rock, left)
    end
    limits.close = link.close
    limits.alive = link.alive
    limits.reset = function(conn)
        return link.reset(conn, settings.name, log)
    end

    local connections = parts.pool.new(limits)

    return setmetatable({
        name = settings.name,
        features = { transaction = true },
        dialect = parts.dialect,
        where = rock.where,
        limits = settings.limits,
        max_rows = settings.max_rows,
        wait_timeout = connections.settings.wait_timeout,
        rock = rock,
        log = log,
        pool = connections,
        retry = retrier,
        closed = false,
        inside = {},
    }, Client)
end

---@class TntStorageRockModule Модуль знания рока у фасада
---@field load fun(level: integer): table Рок по имени либо исключение
---@field new fun(settings: table, loaded: table): TntStorageRock Знание рока для драйвера

---@class TntStorageFacade Из чего фасад заводит драйвер
---@field check fun(opts: table): TntStorageDriverSettings Проверка настроек фасада; вину ставит строке того, кто завёл
---@field rock TntStorageRockModule Знание рока
---@field dialect table Диалект: таблица с полем `name`; у каждого драйвера — своя копия
---@field log table Журнал фасада
---@field pool { new: fun(opts: table): TntPool } Пакет `tnt-pool`
---@field retry { new: fun(opts: table): TntRetry|nil, string|nil } Пакет `tnt-retry`

--- `new` фасада: проверить настройки, загрузить рок, завести драйвер.
---
--- Соединений `new` не открывает: первое откроет первый вызов. Диалект
--- у каждого драйвера — своя копия: общая таблица, поправленная через один
--- драйвер, поменяла бы сборку запросов всем.
---@param facade TntStorageFacade
---@return fun(opts: table): TntStorageDriver
function Module.facade(facade)
    return function(opts)
        local settings = facade.check(opts)
        local client = Module.new(settings, {
            rock = facade.rock.new(settings, facade.rock.load(2)),
            dialect = table.copy(facade.dialect),
            log = facade.log,
            pool = facade.pool,
            retry = facade.retry,
        }, 2)

        return client
    end
end

--- Отказ, когда срок вышел до очередной попытки.
---
--- Была попытка — отказ её, но без повтора: пауза `tnt-retry` меряет
--- свой срок от своего начала и могла в него уложиться, не уложившись
--- в миг вызова. Не было — `timeout` без отправки.
---@param last TntStorageFailure|nil
---@return TntStorageFailure
local function expired(last)
    if last ~= nil then
        return failure.new(last.kind, last.message, {
            sent = last.sent,
            retriable = false,
            server_code = last.server_code,
            reason = last.reason,
        })
    end

    return failure.new(
        failure.TIMEOUT,
        'срок вызова вышел до отправки оператора',
        { sent = false }
    )
end

--- Чем объяснить, что соединения не дали.
---@param why any Что отдал пул
---@return TntStorageFailure
function Client:_refusal(why)
    -- Окончательный отказ входа (`denied`) пул отдаёт тем, что вернула `open`.
    if failure.is(why) then
        return why
    end

    if self.closed then
        return failure.new(failure.CLOSED, ('%s: драйвер закрыт'):format(self.name))
    end

    -- Место в пуле есть, а соединения нет — не открылось: род по тексту
    -- отказа открытия. Иначе — все заняты.
    local stats = self.pool:stats()

    if stats.total < stats.size and stats.last_open_error ~= nil then
        return failure.login(why)
    end

    return failure.new(failure.BUSY, ('%s %s: %s'):format(self.rock.label, self.where, tostring(why)))
end

--- Берёт соединение в остаток срока.
---@param deadline number
---@param last TntStorageFailure|nil Отказ прошлой попытки
---@return TntStorageLink|nil conn
---@return TntStorageFailure|nil err
function Client:_take(deadline, last)
    local left = within.left(deadline)

    if self.closed or left <= 0 then
        return nil, self.closed and self:_refusal(nil) or expired(last)
    end

    local conn, why = self.pool:take(math.min(left, self.wait_timeout))

    if conn ~= nil then
        return conn
    end

    return nil, self:_refusal(why)
end

--- Выбрасывает соединение и говорит об этом в журнал: выброс —
--- это новый вход на следующем вызове, и частые выбросы видны только так.
---@param conn TntStorageLink
---@param kind string|nil Род отказа, из-за которого выброшено
---@param reason string Почему: первая строка отказа, без значений строки
function Client:_discard(conn, kind, reason)
    self.pool:drop(conn)
    self.log.warn('соединение выброшено', { driver = self.name, kind = kind, reason = reason })
end

--- Возвращает соединение по решению оператора: вернуть, откатить, выбросить.
---@param conn TntStorageLink
---@param action string give, rollback либо drop
---@param err TntStorageFailure|nil Отказ оператора
---@param deadline number
---@param call TntStorageCall
function Client:_release(conn, action, err, deadline, call)
    if action == statement.ROLLBACK then
        -- Откат — в остаток того же срока; не вышел — соединение не вернуть.
        local undo = { timeout = call.timeout, shape = statement.COUNT }
        local _, undone = statement.run(conn, 'ROLLBACK', NONE, deadline, undo)

        if undone ~= nil then
            action, err = statement.DROP, undone
        else
            action = statement.GIVE
            conn.open = false
        end
    end

    if action == statement.DROP then
        ---@cast err TntStorageFailure
        self:_discard(conn, err.kind, err.reason)

        return
    end

    self.pool:give(conn)
end

--- Одна попытка: взять соединение, выполнить, вернуть либо выбросить.
---@param sql string
---@param params table
---@param deadline number
---@param call TntStorageCall
---@param last TntStorageFailure|nil
---@return table|nil value
---@return TntStorageFailure|nil err
function Client:_attempt(sql, params, deadline, call, last)
    local conn, refused = self:_take(deadline, last)

    if conn == nil then
        return nil, refused
    end

    local done, err, action = statement.run(conn, sql, params, deadline, call)

    self:_release(conn, action, err, deadline, call)

    return done, err
end

--- Вызов целиком: проверка аргументов, один миг срока, попытки по приговору
--- отказа.
---@param sql string
---@param params table|nil
---@param opts table|nil
---@param shape string rows либо count
---@return table|nil value
---@return TntStorageFailure|nil err
function Client:_call(sql, params, opts, shape)
    -- Отказ сборки запроса — `nil, err` вместо `sql, params` — проходит
    -- насквозь: так `db:query(q:build(db.dialect))` не бросает на строке
    -- с нулевым байтом.
    if sql == nil and failure.is(params) then
        return nil, params
    end

    local caller = must.at(3)

    caller.string(sql, 'sql')
    caller.optional.options(opts, 'настройки вызова', CALL)

    local given = opts or {}
    local timeout = within.timeout(given.timeout, self.limits, 3)

    caller.optional.positive(given.max_rows, 'max_rows')

    local encoded, refused = value.params(self.dialect, params or NONE, 3)

    if encoded == nil then
        return nil, refused
    end

    ---@type TntStorageCall
    local call = {
        timeout = timeout,
        idempotent = given.idempotent,
        max_rows = given.max_rows or self.max_rows,
        shape = shape,
    }
    local deadline = within.deadline(timeout)
    local last = nil

    local done, err = self.retry:run(function()
        local result, refusal = self:_attempt(sql, encoded, deadline, call, last)

        last = refusal

        return result, refusal
    end, { deadline = timeout })

    -- Отменённого вызывающего пара не останавливает: отмена уходит
    -- дальше тем же исключением, соединение к этому мигу уже выброшено.
    fiber.testcancel()

    return done, err
end

--- Выборка: записи по именам столбцов, NULL — отсутствующий ключ.
---@param sql string
---@param params table|nil Значения с полем `n`: `{ n = 2, 'a', nil }`
---@param opts { timeout: number|nil, idempotent: boolean|nil, max_rows: integer|nil }|nil
---@return table[]|nil rows
---@return TntStorageFailure|nil err
function Client:query(sql, params, opts)
    local rows, err = self:_call(sql, params, opts, statement.ROWS)

    return rows, err
end

--- Оператор без выборки: сколько строк затронуто — в форме, которую
--- знает рок (`TntStorageRock.count`).
---@param sql string
---@param params table|nil
---@param opts { timeout: number|nil, idempotent: boolean|nil }|nil
---@return table|nil result
---@return TntStorageFailure|nil err
function Client:execute(sql, params, opts)
    local result, err = self:_call(sql, params, opts, statement.COUNT)

    return result, err
end

--- Транзакция на одном соединении (`tnt.storage.transaction`).
---@param fn fun(tx: TntStorageTx): any, any Тело: `nil, err` — откат
---@param opts { timeout: number|nil, retry: boolean|nil }|nil
---@return any value `true`, если тело ничего не вернуло, иначе его значение
---@return any err Отказ хранилища либо отказ тела как есть
function Client:transaction(fn, opts)
    local done, err = transaction.run(self, fn, opts)

    -- Отменённого вызывающего пара не останавливает, как и у `query`.
    fiber.testcancel()

    return done, err
end

--- Закрывает драйвер: свободные соединения — сразу, занятые — когда
--- их вернут.
---
--- Повторное закрытие — пара `closed`, а не исключение: закрытие при
--- остановке узла гонится с запросами, и «так бывает».
---@return boolean ok
---@return TntStorageFailure|nil err
function Client:close()
    if not self.closed then
        self.closed = true
        self.pool:close()

        return true
    end

    return false, failure.new(failure.CLOSED, ('%s: драйвер уже закрыт'):format(self.name))
end

--- Показатели пула: соединения, ожидания, выбросы. Учётных данных
--- в них нет — они живут только в замыкании входа.
---@return table
function Client:stats()
    local stats = self.pool:stats()

    return stats
end

return Module
