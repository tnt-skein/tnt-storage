# tnt-storage

Общее для драйверов хранилищ в Tarantool: отказ одного вида с родом
и приговором повтору, срок вызова, кодирование значений для сервера
и драйвер SQL над роками `pg` и `mysql`. Драйвер поверх него отказывает,
ждёт и передаёт значения так же, как все остальные.

```lua
local storage = require('tnt.storage')

-- отказ: род, приговор повтору, текст без паролей
local err = storage.failure.statement('ERROR:  could not serialize access', '40001')
-- err.kind == 'conflict', err.retriable == false, tostring(err) — текст

-- срок: умолчание 5 с, потолок max_timeout, один миг на вызов
local limits = storage.within.settings(nil, 30)
local deadline = storage.within.deadline(storage.within.timeout(nil, limits))

-- значение: что передать року и какое приведение поставить у PostgreSQL
local value, cast = storage.value.wire('postgres', 9007199254740993LL)   -- '9007199254740993', 'int8'
```

Зависимости: `tnt-must` (проверки аргументов), `tnt-clock` (часы срока),
`tnt-context` (контекст вызывающего в работнике), `tnt-log` (очистка
текста отказа и журнал драйвера) и `tnt-external` (подмена часов, рока
и транзакции box в проверках). Драйверу SQL над роком фасад приносит
`tnt-pool` и `tnt-retry` аргументом.

## Зачем

Драйверов хранилищ много — PostgreSQL, MySQL, Redis, MongoDB, службы
поверх HTTP, — а тот, кто стоит над ними, хочет от всех одного: понять,
что случилось, и решить, повторять ли. Написанное в каждом драйвере
по-своему, это расходится: отказ строкой, повтор оператора, который
сервер уже выполнил, пароль в тексте отказа, вызов без срока к молчащему
серверу, `int64` и `decimal`, молча записанные NULL. Пакет делает четыре
вещи:

- **Отказ** — таблица `TntStorageFailure` с родом из девяти (`unreachable`,
  `denied`, `busy`, `timeout`, `broken`, `rejected`, `conflict`, `closed`,
  `overflow`), признаками `sent` и `retriable` и текстом без паролей;
  читается и как строка. Род — по SQLSTATE, errno, слову отказа Redis,
  коду MongoDB и коду ответа HTTP, а без кода — по словам отказа.
- **Срок** — умолчание 5 с, потолок `max_timeout`, один миг на вызов
  и ожидание рока в отдельном файбере с отменой: у роков `pg` и `mysql`
  срока нет ни на вход, ни на запрос.
- **Значения** — `int64`, `decimal`, `uuid`, `datetime`, JSON и байты
  по диалекту `postgres`, `mysql`, `tarantool`, `redis` либо `mongo`,
  с приведением для PostgreSQL и типом BSON для MongoDB.
- **Драйвер SQL над роком** — пул с живостью и сбросом без сети, вызов
  в срок с повторами по приговору отказа, решение «вернуть, откатить,
  выбросить» и транзакция на одном соединении. Фасад над роком приносит
  только настройки и знание своего рока.

## Установка

```sh
tt rocks install tnt-storage --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-storage.git
cd tnt-storage && tt rocks make
```

## Как пользоваться

| Вызов | Что делает |
|---|---|
| `failure.new(kind, message, opts)` | собирает отказ; незнакомый род — исключение |
| `failure.login(err, code)`, `failure.statement(err, code, opts)` | отказ входа и оператора по коду сервера либо словам |
| `failure.status(status, message, opts)`, `failure.http(err, opts)` | отказ по коду ответа HTTP и отказ `tnt-http` |
| `failure.is(v)`, `failure.text(err)` | отказ ли это; текст броска рока без приписки места |
| `within.settings(timeout, max_timeout)`, `within.timeout(given, limits)` | сроки драйвера и срок одного вызова |
| `within.deadline(timeout)`, `within.left(deadline)` | миг срока и остаток перед ожиданием |
| `within.call(deadline, fn, late)` | тело в работнике до мига: `returned`, `raised`, `expired`, `skipped` |
| `value.wire(dialect, v)`, `value.params(dialect, params)` | значение и приведение; все параметры вызова с полем `n` |
| `storage.json(v)`, `storage.binary(s)`, `storage.decode_binary(dialect, raw)` | обёртки JSON и байтов; байты из ответа |
| `driver.facade(parts)`, `driver.settings(opts, title, defaults, level)` | `new` фасада над роком; общая проверка его настроек |

Драйвер SQL над роком отдаёт `query`, `execute`, `transaction`, `close`
и `stats`:

```lua
local rows, err = db:query('select id, login from users where id = $1::int8', { n = 1, 7 })
local ok, err = db:transaction(function(tx)
    tx:execute('insert into users (login) values ($1)', { n = 1, 'eve' })
end)
```

Отказ — пара `nil, err`; исключение — ошибка программиста: негодный срок,
незнакомый ключ настроек, значение, которое передать нельзя.

## Проверки

```sh
make deps          # luatest, luacheck, luacov с cluacov, зависимости пакета и tnt-pool с tnt-retry в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
```

Покрытие строк — 100 %, убитых мутантов — 100 % (146 проверок,
1030 мутантов в девяти модулях). Пакет проверяется без базы:
драйвер SQL над роком — на двойнике знания рока, ожидание работника —
настоящими файберами, транзакция box — на временном узле.

## Документ

Полное описание с таблицами кодов и значений, примером фасада
и обоснованием решений: [docs/storage.md](docs/storage.md).

## Лицензия

MIT.
