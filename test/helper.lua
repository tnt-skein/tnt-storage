--- Общие средства проверок общего для драйверов хранилищ.
---
--- Пакет — чистый Lua без сети: отказ, коды, значения и срок проверяются
--- без базы, своими перечнями кодов, слов и значений. Ожидание работника
--- идёт настоящими файберами и настоящим временем в десятые доли секунды:
--- отмена и опоздавший итог держатся на ядре, и двойник тут доказал бы
--- только, что мы правильно разговариваем сами с собой. Двойник часов — для
--- арифметики срока: остаток ровно ноль и меньше нуля.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must`, `tnt.clock`, `tnt.context`, `tnt.log`,
--- `tnt.external` — берутся из `.rocks` обычным `require`: проверяется
--- этот пакет, а не они. Пул и повторы, которые драйвер SQL над роком
--- получает аргументом, — `tnt.pool` и `tnt.retry` — стоят там же
--- (`make deps`), хотя пакет от них не зависит.
---
--- Оснастка в `test/testing/` — загрузчик исходников, часы, которые
--- двигает проверка, ловушка журнала, запись файлов и временный узел —
--- грузится так же, файлами, и один раз на процесс: второй экземпляр
--- загрузчика не знал бы, что вытеснил первый, и не вернул бы вытесненное
--- на место.
---
--- Проверки берут всё через этот помощник и через `driver_helper.lua`
--- поверх него, а не из оснастки напрямую: помощник — единственное, чем
--- файл проверок отличается от того же файла в наборе, где пакет живёт
--- рядом со своими зависимостями.

local fio = require('fio')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей: узел берёт файлы и загрузчик,
--- ловушка журнала — загрузчик.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.clock', path = 'test/testing/clock.lua' },
    { name = 'tnt.testing.files', path = 'test/testing/files.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
    { name = 'tnt.testing.node', path = 'test/testing/node.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    module = package.loaded['tnt.testing.sources'].module,
    clock = package.loaded['tnt.testing.clock'].new,
    capture_log = package.loaded['tnt.testing.journal'].capture,
    start_node = package.loaded['tnt.testing.node'].start,
    stop_node = package.loaded['tnt.testing.node'].stop,
}

local helper = {
    --- Модули пакета в порядке зависимостей.
    MODULES = {
        { name = 'tnt.storage.codes', path = 'tnt/storage/codes.lua' },
        { name = 'tnt.storage.failure', path = 'tnt/storage/failure.lua' },
        { name = 'tnt.storage.exact', path = 'tnt/storage/exact.lua' },
        { name = 'tnt.storage.value', path = 'tnt/storage/value.lua' },
        { name = 'tnt.storage.within', path = 'tnt/storage/within.lua' },
        { name = 'tnt.storage.link', path = 'tnt/storage/link.lua' },
        { name = 'tnt.storage.statement', path = 'tnt/storage/statement.lua' },
        { name = 'tnt.storage.transaction', path = 'tnt/storage/transaction.lua' },
        { name = 'tnt.storage.driver', path = 'tnt/storage/driver.lua' },
        { name = 'tnt.storage', path = 'tnt/storage.lua' },
    },
}

--- Фасад пакета из исходников.
---
--- Грузится один раз на процесс: состояния у пакета нет, кроме внешней зависимости часов,
--- а внешние зависимости проверки возвращают сами (`restore`).
helper.storage = testing.load_sources(helper.MODULES, 'tnt.storage')

--- Части пакета и соседи из той же загрузки, что и фасад.
helper.codes = testing.module('tnt.storage.codes')
helper.failure = testing.module('tnt.storage.failure')
helper.value = testing.module('tnt.storage.value')
helper.within = testing.module('tnt.storage.within')
helper.transaction = testing.module('tnt.storage.transaction')
helper.context = testing.module('tnt.context')

--- Модуль последней загрузки по имени: помощник драйвера и обвязка
--- фасадов берут части уже после того, как исходники загружены.
helper.module = testing.module

--- Значение мимо проверки типов: негодный аргумент нарочно.
---@param value any
---@return any
function helper.wrong(value)
    return value
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

--- Часы, которые двигает проверка.
helper.clock = testing.clock

--- Ловушка журнала на время проверки: выброс соединения виден только
--- записью.
helper.capture_log = testing.capture_log

--- Драйвер SQL над роком из исходников — вместе с пулом и повторами,
--- которые он получает аргументом.
---
--- Пул и повторы — установленные, из `.rocks`: драйвер их не берёт сам,
--- а проверкам они нужны, чтобы завести драйвер так, как его заводит фасад.
---@return table driver Модуль `tnt.storage.driver`
function helper.load_driver()
    local driver = testing.load_sources(helper.MODULES, 'tnt.storage.driver')

    require('tnt.pool')
    require('tnt.retry')

    return driver
end

--- Возвращает пакету настоящие часы.
function helper.restore()
    helper.within._set_source(nil)
end

--- Временный узел с исходниками пакета: транзакция box бывает только
--- на нём, в процессе проверок `box` не настроен. Остановить узел
--- проверка обязана сама.
---@return table server
function helper.start_node()
    local server = testing.start_node({ modules = helper.MODULES })

    return server
end

--- Останавливает узел и убирает его каталог.
helper.stop_node = testing.stop_node

return helper
