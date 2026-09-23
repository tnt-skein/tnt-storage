--- Соединение пула над роком SQL: открыть в срок, проверить без сети,
--- выполнить в работнике, закрыть.
---
--- Роки `pg` и `mysql` устроены одинаково там, где драйверу это важно:
--- срока нет ни на вход, ни на запрос, отказ — бросок, соединение
--- однопоточное и держит свой замок. Поэтому всё, что с этим делает
--- драйвер, живёт здесь одно на оба рока, а драйвер отдаёт только знание
--- своего рока — таблицу `TntStorageRock`: как войти, как закрыть, жив ли,
--- как позвать, какой код у отказа.
---
--- И вход, и оператор идут в работнике `within.call`: вызывающий ждёт итога
--- до мига срока, а не дождавшись — отменяет работника. Вход, завершившийся
--- после срока, закрывается в работнике, там, где появился.
---
--- Живость без сети: рок проверяет соединение местно и бросает ровно
--- тогда, когда сам пометил его негодным. Соединение, умершее в простое,
--- так не видно — его узнаёт первый запрос родом `broken`.
---
--- Соединение, выброшенное, пока работник внутри рока, закрывает выход
--- работника, а не тот, кто выбросил: закрытие рока ждёт замка
--- соединения, и выбросивший ждал бы вместе с ним. Место в пуле `drop`
--- освобождает сразу.
---
--- Рок берётся по имени, как внешняя зависимость (`require`): без рока пакет загружается
--- и проверяется двойником, а драйвер на узле без рока бросает при
--- заведении — лучше узнать это сразу, чем отказом `unreachable` на каждом
--- вызове.

local failure = require('tnt.storage.failure')
local external = require('tnt.external')
local within = require('tnt.storage.within')

local Module = {}

--- Внешнее средство: загрузка рока по имени.
local source = external.install(Module, {
    require = function(name)
        local ok, rock = pcall(require, name)

        if not ok then
            return nil, tostring(rock)
        end

        return rock
    end,
})

---@class TntStorageRock Что драйвер знает о своём роке
---@field label string Имя в начале текста отказа: postgres, mysql
---@field where string Узел, порт и база — для текста отказа, без учётных данных
---@field connect fun(): any Открыть соединение рока; отказ — бросок
---@field shut fun(conn: any) Закрыть соединение рока, чем бы оно ни кончилось
---@field state fun(conn: any): boolean, boolean|nil Годно ли без сети; открыта ли транзакция, если рок это знает
---@field execute fun(conn: any, sql: string, params: table): any, any, any, any Оператор; отказ — бросок
---@field code fun(err: any): string|integer|nil Код сервера из броска рока: SQLSTATE, errno
---@field text fun(err: any): string Текст броска рока для отказа, до `scrub`
---@field count fun(...: any): table Ответ оператора без выборки из того, что отдал рок

---@class TntStorageLink Соединение пула
---@field rock TntStorageRock Знание рока
---@field conn any Соединение рока
---@field working boolean Работник сейчас внутри рока
---@field doomed boolean Выброшено, пока работник внутри: закроет его выход
---@field open boolean Транзакция, которую открыл фасад, ещё не закрыта

--- Значения со счётом: `nil` посреди и в конце не теряются.
---@param ... any
---@return table
local function pack(...)
    return { n = select('#', ...), ... }
end

--- Рок по имени либо исключение: без рока драйвер не откроет ни одного
--- соединения.
---@param name string Имя модуля рока: pg, mysql
---@param hint string Что делать: как поставить рок
---@param level integer Уровень вины, как у `error`, в кадрах того, кто зовёт
---@return table rock
function Module.require(name, hint, level)
    local rock, missing = source().require(name)

    if rock == nil then
        error(
            ('рок %s не установлен (%s): %s'):format(name, tostring(missing):match('^[^\n]*'), hint),
            level + 1
        )
    end

    return rock
end

--- Закрывает соединение рока, чем бы оно ни кончилось.
---
--- У обоих роков соединение закрывает `close()`, а на оборванном он бросает
--- и сокета не закрывает; тогда — объект драйвера рока (`conn.conn`),
--- иначе сокет ждал бы сборки мусора.
---@param conn { close: fun(self: any), conn: { close: fun(self: any) } } Соединение рока
function Module.shut(conn)
    if not pcall(conn.close, conn) then
        pcall(conn.conn.close, conn.conn)
    end
end

--- Оператор рока: параметры аргументами после текста, `nil` посреди
--- не теряется.
---@param conn { execute: fun(self: any, sql: string, ...: any): ... } Соединение рока
---@param sql string
---@param params table Параметры с полем `n`
---@return any ... Что отдал рок
function Module.execute(conn, sql, params)
    return conn:execute(sql, unpack(params, 1, params.n))
end

--- Открывает соединение в срок, который дал пул.
---
--- Отказ — `TntStorageFailure`: `denied` пул отдаёт взявшему сразу
--- (`retriable = false`), `unreachable` повторяет внутри срока.
---@param rock TntStorageRock
---@param left number Остаток срока `take`, секунд; больше нуля
---@return TntStorageLink|nil link
---@return TntStorageFailure|nil err
function Module.open(rock, left)
    local status, conn = within.call(within.deadline(left), rock.connect, function(ok, late)
        if ok then
            rock.shut(late)
        end
    end)

    if status == within.RETURNED then
        return { rock = rock, conn = conn, working = false, doomed = false, open = false }
    end

    if status == within.RAISED then
        local text = ('%s %s: вход не удался: %s'):format(rock.label, rock.where, rock.text(conn))

        return nil, failure.login(text, rock.code(conn))
    end

    return nil,
        failure.new(
            failure.UNREACHABLE,
            ('%s %s: вход не завершился за %s с'):format(rock.label, rock.where, left)
        )
end

--- Закрывает соединение, которое пул выбросил или закрывает.
---@param link TntStorageLink
function Module.close(link)
    if link.working then
        link.doomed = true

        return
    end

    link.rock.shut(link.conn)
end

--- Годно ли соединение и открыта ли на нём транзакция — без сети.
---
--- Открыта ли транзакция, говорит рок, если знает (`pg`); не знает
--- (`mysql`) — отметка фасада, который сам шлёт `BEGIN` и `COMMIT`.
--- Ответ рока заодно поправляет отметку: транзакция, закрытая отказом
--- `COMMIT`, иначе числилась бы открытой.
---@param link TntStorageLink
---@return boolean alive Рок не пометил соединение негодным
---@return boolean|nil open Транзакция открыта
function Module.state(link)
    local alive, open = link.rock.state(link.conn)

    if not alive then
        return false
    end

    if open ~= nil then
        link.open = open
    end

    return true, link.open
end

--- Живо ли свободное соединение: крюк `alive` пула.
---@param link TntStorageLink
---@return boolean
function Module.alive(link)
    return (Module.state(link))
end

--- Крюк `reset` пула: без сети, у крюка нет срока вызова.
---
--- Открытая транзакция при возврате — след ошибки фасада либо `BEGIN`,
--- посланного текстом: откатывает фасад сам и до возврата. Такое
--- соединение выбрасывается, а не откатывается: следующий взявший иначе
--- зафиксировал бы чужую работу.
---@param link TntStorageLink
---@param name string Имя драйвера для журнала
---@param log table Журнал драйвера
---@return boolean clean Можно ли вернуть в свободные
function Module.reset(link, name, log)
    local alive, open = Module.state(link)

    if open then
        log.warn(
            'соединение вернулось с открытой транзакцией',
            { driver = name }
        )
    end

    return alive and not open
end

--- Выполняет оператор в работнике и ждёт итога до мига срока.
---
--- Исход — слово `within.call`, за ним — значения рока: `returned`, что
--- отдал рок; `raised`, брошенное; `expired` — работник отменён, в сокете
--- недочитанный ответ; `skipped` — рок не звался.
---
--- Вызывающего, которого отменили в ожидании, `within.call` не прячет
--- и бросает отмену дальше. Здесь она — `expired`: работник отменён так же,
--- как по сроку, и соединение надо выбросить, а брошенная мимо драйвера
--- отмена оставила бы его занятым в пуле навсегда. Отмену поднимает
--- драйвер сам, когда соединение уже выброшено.
---@param link TntStorageLink
---@param deadline number Миг срока
---@param sql string
---@param params table Параметры с полем `n`
---@return string status
---@return any ... Итог рока
function Module.run(link, deadline, sql, params)
    -- Работник отдаёт итог рока целиком, как его поймал `pcall`: брошенное
    -- уходит значением, а не повторным броском, и место к нему
    -- не приписывается.
    local called, status, done = pcall(within.call, deadline, function()
        link.working = true

        local result = pack(pcall(link.rock.execute, link.conn, sql, params))

        link.working = false

        if link.doomed then
            link.rock.shut(link.conn)
        end

        return result
    end)

    if not called then
        return within.EXPIRED
    end

    if status ~= within.RETURNED then
        return status
    end

    -- Итог работника — таблица `pack(pcall(…))`; аннотация `within.call`
    -- о значениях тела ничего не знает.
    local result = done --[[@as table]]

    if not result[1] then
        return within.RAISED, result[2]
    end

    return within.RETURNED, unpack(result, 2, result.n)
end

return Module
