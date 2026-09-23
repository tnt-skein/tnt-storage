--- Проверка на временном узле с настоящим `box`: транзакция box видна
--- драйверу.
---
--- В процессе проверок `box` не настроен, и транзакций там не бывает, а само
--- обращение к `box.is_in_txn` до `box.cfg` роняет процесс. Что умолчание
--- внешней зависимости видит транзакцию, показывает только узел.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.storage.transaction.node')

g.before_all(function()
    g.server = helper.start_node()
end)

g.after_all(function()
    helper.stop_node(g.server)
end)

g.test_a_box_transaction_is_seen = function()
    local seen = g.server:exec(function()
        local transaction = require('tnt.storage.transaction')
        local outside = transaction.in_box_txn()

        box.begin()

        local inside = transaction.in_box_txn()

        box.rollback()

        return { outside = outside, inside = inside }
    end)

    t.assert_equals(seen, { outside = false, inside = true })
end

g.test_no_box_transaction_before_box_cfg = function()
    -- Проверки идут без box.cfg: обращение к box.is_in_txn уронило бы процесс.
    t.assert_equals(helper.transaction.in_box_txn(), false)
end
