--- Общее для драйверов хранилищ: отказ, срок и кодирование значений.
---
---     local storage = require('tnt.storage')
---
---     -- отказ: род, приговор повтору, текст без тайн
---     local err = storage.failure.statement(raised, '40001', { idempotent = true })
---     -- err.kind == 'conflict', err.retriable == false, err.sent == true
---
---     -- срок: умолчание 5 с, потолок max_timeout, один миг на вызов
---     local limits = storage.within.settings(opts.timeout, opts.max_timeout)
---     local deadline = storage.within.deadline(storage.within.timeout(call.timeout, limits))
---
---     -- значение: что передать року и какое приведение поставить у pg
---     local value, cast = storage.value.wire('postgres', 9007199254740993LL)
---     -- '9007199254740993', 'int8'
---     local doc = storage.json({ a = 1 })   -- jsonb у pg, текст у mysql
---     local blob = storage.binary('\0\255') -- bytea у pg, BLOB у mysql
---
--- Драйверы разных хранилищ берут отсюда одно и то же, а не пишут каждый
--- своё: отказ одного вида, один срок и одно правило кодирования значений.
--- Драйвер SQL над роком (`tnt.storage.driver`: пул, повторы, транзакции
--- для `pg` и `mysql`) — отдельный модуль, в этот фасад он не входит:
--- тем, кому нужны только отказ, срок и значения, пул и повторы ни к чему,
--- а их пакеты драйвер получает аргументом.
---
--- Настроек и состояния у пакета нет. Подробно — `docs/storage.md`.

local failure = require('tnt.storage.failure')
local value = require('tnt.storage.value')
local within = require('tnt.storage.within')

local Module = {}

--- Отказ хранилища: роды, сборка, перевод из кода сервера и из `tnt-http`.
Module.failure = failure

--- Кодирование значений параметров по диалекту.
Module.value = value

--- Срок вызова и ожидание рока в работнике.
Module.within = within

--- Значение, которое уйдёт текстом JSON.
Module.json = value.json

--- Байты, которые уйдут двоичным значением.
Module.binary = value.binary

--- Байты из ответа.
Module.decode_binary = value.decode_binary

return Module
