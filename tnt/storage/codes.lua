--- Род отказа по коду сервера, по тексту, по коду ответа HTTP и по признаку
--- `sent` отказа сети HTTP.
---
--- Роки отказывают исключением-строкой, а род нужен словом из девяти
--- (`tnt.storage.failure`). Здесь собраны правила, общие для всех
--- драйверов: один перечень кодов вместо своего у каждого драйвера — свои
--- однажды разойдутся.
---
--- Улика первая — код сервера: SQLSTATE у PostgreSQL (строка из пяти знаков),
--- errno у MySQL (число) и первое слово отказа у Redis (`WRONGTYPE`,
--- `LOADING`: прописными, до пробела; общее `ERR` кодом не считается —
--- оно не говорит ничего). SQLSTATE и errno отдают сборки роков, которые
--- сохраняют код отказа, и код, если он есть, решает один:
--- незнакомый код — это `rejected` у оператора и `unreachable` у входа,
--- даже если текст похож на что-то иное. Текст — улика вторая, для отказов
--- без кода: libpq не даёт кода на отказ сети, а рок, который кода
--- не сохраняет, не даёт его вовсе. Текст сверяется до `tnt-log.scrub`:
--- у MySQL `scrub` принимает «(using password: YES)» за тайну и портит
--- ровно то, по чему видно смысл.
---
--- У MongoDB код — тоже число, но значат числа не то, что errno MySQL
--- (13 у MongoDB — «нет прав»), поэтому таблица у него своя и спрашивается
--- отдельно: `mongo` у отказа оператора, `mongo_login` у входа.
---
--- Чего здесь нет: проверки живости соединения. Она местная и своя у каждого
--- рока (`active()` у `pg`, `quote('')` у `mysql`), идёт первой, и бросила —
--- значит `broken` без всякого кода. Коды обрыва ниже — вторая линия,
--- когда рок успел сказать, что соединение закрыто, а живость ещё не видит.

local Module = {}

local DENIED = 'denied'
local UNREACHABLE = 'unreachable'
local BUSY = 'busy'
local TIMEOUT = 'timeout'
local BROKEN = 'broken'
local REJECTED = 'rejected'
local CONFLICT = 'conflict'

--- Коды, с которыми сервер отказывает во входе: время их не лечит.
---
--- Прочие отказы входа — `unreachable`: сервер не поднялся (57P03),
--- соединений больше предела (53300, 1040), сеть (класс 08, 2002, 2003).
local LOGIN_DENIED = {
    -- PostgreSQL: учётные данные, пароль, нет базы, нет права CONNECT.
    ['28000'] = true,
    ['28P01'] = true,
    ['3D000'] = true,
    ['42501'] = true,
    -- MySQL: нет доступа к базе, неверный пароль, нет базы.
    [1044] = true,
    [1045] = true,
    [1049] = true,
    -- Узел заперт после ошибок входа: отпирает только flush-hosts.
    [1129] = true,
    -- Узлу входить нельзя.
    [1130] = true,
    -- Способ проверки пароля клиенту неизвестен.
    [1251] = true,
    -- Вход без пароля запрещён.
    [1698] = true,
    -- Пароль просрочен.
    [1862] = true,
    -- Модуль проверки пароля не загрузился: способа входа, которого
    -- просит сервер, у коннектора нет — у рока без починки это
    -- caching_sha2_password.
    [2059] = true,
    -- Учётная запись заперта.
    [3118] = true,
    -- Redis: неверные имя или пароль, вход обязателен, нет права
    -- на команду входа, узел заперт защищённым режимом без пароля.
    WRONGPASS = true,
    NOAUTH = true,
    NOPERM = true,
    DENIED = true,
}

--- Коды отказа оператора, у которых свой род; прочие — `rejected`.
local STATEMENT = {
    -- PostgreSQL: конфликт сериализации, взаимоблокировка, блокировка
    -- не взята (NOWAIT, lock_timeout).
    ['40001'] = CONFLICT,
    ['40P01'] = CONFLICT,
    ['55P03'] = CONFLICT,
    -- Оператор отменён: statement_timeout и отмена руками.
    ['57014'] = TIMEOUT,
    -- Сервер закрыл сеанс: остановка, падение, запуск, база удалена,
    -- простой сеанса, простой и срок транзакции.
    ['57P01'] = BROKEN,
    ['57P02'] = BROKEN,
    ['57P03'] = BROKEN,
    ['57P04'] = BROKEN,
    ['57P05'] = BROKEN,
    ['25P03'] = BROKEN,
    ['25P04'] = BROKEN,
    -- MySQL: ожидание блокировки, взаимоблокировка, блокировка не взята
    -- (NOWAIT).
    [1205] = CONFLICT,
    [1213] = CONFLICT,
    [3572] = CONFLICT,
    -- Срок max_execution_time.
    [3024] = TIMEOUT,
    -- Сервер останавливается, сеанс убит, сервер ушёл, связь потеряна,
    -- сеанс закрыт за простой.
    [1053] = BROKEN,
    [1927] = BROKEN,
    [2006] = BROKEN,
    [2013] = BROKEN,
    [2055] = BROKEN,
    [4031] = BROKEN,
    -- Redis: вход не пройден либо нет права на команду — команду сервер
    -- не выполнял, и время этого не лечит.
    NOAUTH = DENIED,
    WRONGPASS = DENIED,
    NOPERM = DENIED,
    DENIED = DENIED,
    -- Команду сервер не выполнял и выполнит позже: идёт сценарий, данные
    -- грузятся с диска, связи с ведущим нет, узел стал репликой после
    -- смены ведущего, кластер перестраивается, реплик для записи мало.
    BUSY = BUSY,
    LOADING = BUSY,
    MASTERDOWN = BUSY,
    READONLY = BUSY,
    TRYAGAIN = BUSY,
    CLUSTERDOWN = BUSY,
    NOREPLICAS = BUSY,
}

--- Коды MongoDB, у которых свой род; прочие — `rejected`.
---
--- Таблица своя, а не общая с errno MySQL: коды у обоих — числа, и одно
--- число у двух серверов значит разное. Имя кода (`codeName`) приходит не
--- всегда — у отказа записи внутри ответа его нет, — поэтому род решает
--- число.
local MONGO = {
    -- Конфликт записи в транзакции, блокировка не взята, транзакция уже
    -- снята сервером.
    [112] = CONFLICT,
    [24] = CONFLICT,
    [251] = CONFLICT,
    -- Срок maxTimeMS, срок операции на сервере, срок подтверждения записи
    -- репликами (wtimeout): записано на ведущем, но не дождались реплик.
    [50] = TIMEOUT,
    [262] = TIMEOUT,
    [64] = TIMEOUT,
    -- Нет прав на команду: команду сервер не выполнял.
    [13] = DENIED,
    -- Узел не ведущий: запись не принята и не выполнялась.
    [10107] = BUSY,
    [13435] = BUSY,
    [13436] = BUSY,
    -- Сервер останавливается, ведущий сложил полномочия, операция прервана
    -- остановкой либо сменой ведущего, сеть между узлами: операция могла
    -- дойти, и повтор решает согласие вызывающего.
    [91] = BROKEN,
    [189] = BROKEN,
    [11600] = BROKEN,
    [11602] = BROKEN,
    [6] = BROKEN,
    [7] = BROKEN,
    [89] = BROKEN,
    [9001] = BROKEN,
}

--- Коды MongoDB, с которыми сервер отказывает во входе: нет учётной
--- записи, нет прав, вход не прошёл, способа входа у сервера нет.
local MONGO_DENIED = { [11] = true, [13] = true, [18] = true, [334] = true }

--- Метка MongoDB: транзакцию сервер снял целиком, и повторять можно только
--- её всю.
local TRANSIENT = 'TransientTransactionError'

--- Класс SQLSTATE «ошибка соединения» целиком: 08000, 08003, 08006…
local CONNECTION_CLASS = '^08'

--- Слова отказа входа, после которых повторять бесполезно.
---
--- Слова Redis нужны и при коде: отказ входа, пришедший из пула строкой
--- по сроку, кода уже не несёт, а общее `ERR` кодом не считается.
local LOGIN_HINTS = {
    'password authentication failed',
    'does not exist',
    'no pg_hba.conf entry',
    'Access denied',
    -- Redis 6 и новее: неверные имя или пароль; старше 6 — неверный пароль.
    'invalid username-password pair',
    'invalid password',
    -- Пароль задан, а у сервера его нет: 6 и новее, затем старше 6.
    'without any password configured',
    'no password is set',
    -- Вход обязателен, а пароль не задан; нет права на команду входа.
    'Authentication required',
    'has no permissions',
    -- Сервер без пароля в защищённом режиме пускает только с себя.
    'running in protected mode',
    -- Номера базы из настроек у сервера нет.
    'DB index is out of range',
}

--- Слова отказа оператора без кода и род по ним: первые совпавшие решают.
local STATEMENT_HINTS = {
    { words = 'could not serialize access', kind = CONFLICT },
    { words = 'deadlock detected', kind = CONFLICT },
    { words = 'canceling statement due to lock timeout', kind = CONFLICT },
    { words = 'Deadlock found when trying to get lock', kind = CONFLICT },
    { words = 'Lock wait timeout exceeded', kind = CONFLICT },
    { words = 'canceling statement due to statement timeout', kind = TIMEOUT },
    { words = 'maximum statement execution time exceeded', kind = TIMEOUT },
    { words = 'server closed the connection unexpectedly', kind = BROKEN },
    { words = 'terminating connection', kind = BROKEN },
    { words = 'Lost connection to MySQL server', kind = BROKEN },
    { words = 'MySQL server has gone away', kind = BROKEN },
}

--- Слова libcurl об истёкшем сроке: и входа, и ответа.
---
--- Признак `sent` говорит, ушёл ли запрос, но не почему нет ответа,
--- а срок у хранилища — свой род, поэтому эти слова читаются здесь.
local EXPIRED = 'Timeout was reached'

--- Коды ответа HTTP, у которых свой род; прочие 4xx — `rejected`, 5xx —
--- `broken`.
local STATUS = {
    [401] = DENIED,
    [403] = DENIED,
    [409] = CONFLICT,
    [412] = CONFLICT,
    [429] = BUSY,
    [503] = BUSY,
}

--- Первые с начала коды ответа, которыми сервер признаётся в своей беде.
local SERVER_ERROR = 500

--- Есть ли в тексте слова — как они есть, без разбора образца.
---
--- Один поиск на весь модуль: слова отказов пишут люди, и точка в «no
--- pg_hba.conf entry» — это точка, а не «любой знак».
---@param text string
---@param words string
---@return boolean
local function says(text, words)
    return text:find(words, nil, true) ~= nil
end

--- Есть ли в тексте хоть одно из слов.
---@param text string
---@param list string[]
---@return true|nil
local function mentions(text, list)
    for _, words in ipairs(list) do
        if says(text, words) then
            return true
        end
    end

    return nil
end

--- Род отказа входа.
---@param code string|integer|nil SQLSTATE, errno либо первое слово отказа Redis
---@param text string Текст отказа до `scrub`
---@return string kind Род: denied либо unreachable
function Module.login(code, text)
    if code ~= nil then
        return LOGIN_DENIED[code] and DENIED or UNREACHABLE
    end

    return mentions(text, LOGIN_HINTS) and DENIED or UNREACHABLE
end

--- Род отказа оператора при живом соединении.
---@param code string|integer|nil SQLSTATE, errno либо первое слово отказа Redis
---@param text string Текст отказа до `scrub`
---@return string kind Род: conflict, timeout, broken, denied, busy либо rejected
function Module.statement(code, text)
    if type(code) == 'string' and code:find(CONNECTION_CLASS) then
        return BROKEN
    end

    if code ~= nil then
        return STATEMENT[code] or REJECTED
    end

    for _, hint in ipairs(STATEMENT_HINTS) do
        if says(text, hint.words) then
            return hint.kind
        end
    end

    return REJECTED
end

--- Род по коду ответа HTTP.
---@param status integer
---@return string kind Род: denied, conflict, busy, broken либо rejected
function Module.status(status)
    if STATUS[status] ~= nil then
        return STATUS[status]
    end

    return status >= SERVER_ERROR and BROKEN or REJECTED
end

--- Род отказа MongoDB по коду и меткам ответа.
---
--- Метка `TransientTransactionError` главнее кода: с ней сервер снял
--- транзакцию целиком, и это конфликт, какой бы код ни стоял рядом.
---@param code integer|nil Код отказа (`code`)
---@param labels string[]|nil Метки отказа (`errorLabels`)
---@return string kind Род: conflict, timeout, denied, busy, broken либо rejected
function Module.mongo(code, labels)
    for _, label in ipairs(labels or {}) do
        if label == TRANSIENT then
            return CONFLICT
        end
    end

    return MONGO[code] or REJECTED
end

--- Род отказа входа MongoDB по коду.
---@param code integer|nil
---@return string kind Род: denied либо unreachable
function Module.mongo_login(code)
    return MONGO_DENIED[code] and DENIED or UNREACHABLE
end

--- Род отказа сети HTTP по признаку `sent` и словам срока.
---
--- Отказ сети у `tnt-http` один — `unreachable`, — а он бывает и до
--- отправки, и после: обрыв посреди ответа выглядит так же. Ушёл ли
--- запрос, решает сам `tnt-http` признаком `sent`: слова libcurl знает
--- одно место, рядом с самим libcurl. Свой их список здесь однажды
--- разошёлся бы с тамошним на новом выпуске libcurl, и драйверы поверх
--- HTTP судили бы об одном и том же отказе иначе, чем `tnt-etcd-client`.
---
--- `unreachable` — только `sent = false`, как бы libcurl ни назвал отказ:
--- запрос, который не ушёл, повторять можно всегда. Прочее могло уйти:
--- срок — `timeout`, остальное, и бросок libcurl тоже, — `broken`,
--- и повтор решает согласие вызывающего. Пустой признак — «могло уйти»:
--- ошибка в эту сторону стоит лишнего отказа, а в другую — двойной записи.
---@param text string Текст отказа `tnt-http`
---@param sent boolean|nil Мог ли запрос дойти до сервера — признак `tnt-http`
---@return string kind Род: unreachable, timeout либо broken
function Module.network(text, sent)
    if sent == false then
        return UNREACHABLE
    end

    return says(text, EXPIRED) and TIMEOUT or BROKEN
end

return Module
