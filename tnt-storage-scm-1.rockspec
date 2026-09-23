rockspec_format = '3.0'

package = 'tnt-storage'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-storage.git',
    branch = 'main',
}

description = {
    summary = 'Общее для драйверов хранилищ: отказ с родом, срок вызова, кодирование значений, драйвер SQL над роком',
    detailed = [[
        Драйверы разных хранилищ — PostgreSQL, MySQL, Redis, MongoDB,
        служб поверх HTTP — отказывают, ждут и передают значения по-разному,
        и тот, кто стоит над ними, разбирал бы столько видов отказа,
        сколько драйверов. Пакет даёт им одно общее.

        Отказ — таблица с родом из девяти (unreachable, denied, busy,
        timeout, broken, rejected, conflict, closed, overflow), признаками
        sent и retriable для повторов и текстом, из которого убраны пароли;
        читается и как строка. Род выбирается по SQLSTATE, errno, первому
        слову отказа Redis, коду MongoDB, коду ответа HTTP, а без кода —
        по словам отказа.

        Срок — умолчание 5 с, потолок max_timeout, один миг на вызов
        и ожидание рока в отдельном файбере с отменой: у роков pg и mysql
        срока нет ни на вход, ни на запрос. Значения — что передать року,
        чтобы сервер получил ровно то, что дали: int64, decimal, uuid,
        datetime, JSON и байты по диалекту postgres, mysql, tarantool,
        redis либо mongo.

        Драйвер SQL над роком — пул с живостью и сбросом без сети,
        ожидание рока в работнике, повторы по приговору отказа и транзакция
        на одном соединении; фасад над роком приносит только настройки
        и знание своего рока. Пакеты tnt-pool и tnt-retry драйвер получает
        аргументом, и тем, кому нужны только отказ, срок и значения,
        они не нужны.

        Зависит от tnt-must (проверки аргументов), tnt-clock (часы срока),
        tnt-context (контекст в работнике), tnt-log (очистка текста отказа
        и журнал драйвера) и tnt-external (подмена часов, рока и транзакции
        box в проверках). Покрытие строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-storage',
    issues_url = 'https://github.com/tnt-skein/tnt-storage/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'storage', 'database', 'sql', 'driver', 'timeout', 'errors' },
}

dependencies = {
    'lua >= 5.1',
    -- Проверки аргументов и настроек на строке вызывающего.
    'tnt-must',
    -- Монотонные часы и время планировщика для срока вызова.
    'tnt-clock',
    -- Контекст вызывающего в файбере работника.
    'tnt-context',
    -- Очистка текста отказа от паролей и записи драйвера о выброшенных соединениях.
    'tnt-log',
    -- Подмена часов, загрузки рока и транзакции box в проверках.
    'tnt-external',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.storage'] = 'tnt/storage.lua',
        ['tnt.storage.codes'] = 'tnt/storage/codes.lua',
        ['tnt.storage.driver'] = 'tnt/storage/driver.lua',
        ['tnt.storage.exact'] = 'tnt/storage/exact.lua',
        ['tnt.storage.failure'] = 'tnt/storage/failure.lua',
        ['tnt.storage.link'] = 'tnt/storage/link.lua',
        ['tnt.storage.statement'] = 'tnt/storage/statement.lua',
        ['tnt.storage.transaction'] = 'tnt/storage/transaction.lua',
        ['tnt.storage.value'] = 'tnt/storage/value.lua',
        ['tnt.storage.within'] = 'tnt/storage/within.lua',
    },
}
