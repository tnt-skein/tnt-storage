--- Проверки фасада: части пакета и обёртки значений под своими именами.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local storage = helper.storage

local g = t.group('tnt.storage')

g.test_the_parts_are_in_place = function()
    t.assert(rawequal(storage.failure, helper.failure))
    t.assert(rawequal(storage.value, helper.value))
    t.assert(rawequal(storage.within, helper.within))
end

g.test_the_wrappers_are_the_ones_of_value = function()
    t.assert(rawequal(storage.json, helper.value.json))
    t.assert(rawequal(storage.binary, helper.value.binary))
    t.assert(rawequal(storage.decode_binary, helper.value.decode_binary))
    t.assert_equals({ storage.value.wire('postgres', storage.json({ a = 1 })) }, { '{"a":1}', 'jsonb' })
end
