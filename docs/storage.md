# Общее для драйверов хранилищ

`tnt-storage` — то общее, из чего собираются драйверы хранилищ: отказ
одного вида с родом и приговором повтору, срок вызова, кодирование
значений для сервера и драйвер SQL над роками `pg` и `mysql`.

```lua
local storage = require('tnt.storage')

local err = storage.failure.statement('ERROR:  could not serialize access', '40001')   -- err.kind == 'conflict'
local limits = storage.within.settings(nil, 30)                                      -- срок 5 с, потолок 30 с
local value, cast = storage.value.wire('postgres', 9007199254740993LL)               -- '9007199254740993', 'int8'
```

Зависимости: `tnt-must` (проверки аргументов), `tnt-clock` (часы срока),
`tnt-context` (контекст вызывающего в работнике), `tnt-log` (очистка
текста отказа и журнал драйвера) и `tnt-external` (подмена часов, рока
и транзакции box в проверках). Драйверу SQL над роком нужны ещё
`tnt-pool` и `tnt-retry`, но их приносит фасад аргументом — пакет от них
не зависит. Остальное встроено в Tarantool: `fiber`, `json`, `decimal`,
`uuid`, `datetime`, `varbinary`.

## Зачем пакет

Драйвер хранилища — клиент к базе или службе, которым пользуется
прикладной код. Драйверов много — PostgreSQL, MySQL, Redis, MongoDB,
поисковые и файловые службы поверх HTTP, — а тот, кто стоит над ними
(кэш, поиск, модель, очередь), хочет от всех одного: понять, что
случилось, и решить, повторять ли. Если каждый драйвер решает это сам,
видов отказа заводится столько же, сколько драйверов, и расходятся они
в мелочах, которые всплывают под нагрузкой:

- **отказ строкой** — «сеть пропала» и «нарушено ограничение» различаются
  только текстом, а текст у каждого сервера свой;
- **повтор после отправки** — обрыв до отправки от обрыва после по тексту
  не отличить, а повтор оператора, который сервер уже выполнил, списывает
  деньги дважды;
- **пароль в тексте отказа** — строка соединения уходит в журнал вместе
  с отказом;
- **вызов без срока** — у роков `pg` и `mysql` срока нет ни на вход,
  ни на запрос, и вызов к молчащему серверу не вернётся никогда;
- **порча значений** — рок `pg` пишет строку `'0012'` числом 12, число
  длиннее 14 значащих цифр — с потерей хвоста, `int64` и таблицу
  в текстовый столбец — NULL; рок `mysql` пишет NULL вместо `decimal`
  и `uuid`.

Пакет делает четыре вещи:

1. **Отказ** (`tnt.storage.failure`) — таблица `TntStorageFailure` с родом
   из девяти, признаками `sent` и `retriable` для повторов и текстом, из
   которого убраны пароли. Род выбирается по SQLSTATE, errno, первому
   слову отказа Redis, коду MongoDB и коду ответа HTTP, а без кода —
   по словам отказа, в одном месте на все драйверы.
2. **Срок** (`tnt.storage.within`) — умолчание 5 с, потолок `max_timeout`,
   один миг на вызов и ожидание рока в отдельном файбере с отменой.
3. **Значения** (`tnt.storage.value` и его часть `exact` — граница
   точности числа и его точная запись) — что передать року, чтобы сервер
   получил ровно то, что дали, и какое приведение поставить у PostgreSQL.
4. **Драйвер SQL над роком** (`tnt.storage.driver` и его части `link`,
   `statement`, `transaction`) — пул с живостью и сбросом без сети, вызов
   в срок с повторами, решение «вернуть, откатить, выбросить» и транзакция
   на одном соединении. Фасад над роком приносит только свои настройки
   и знание рока.

Чего здесь нет. **Пула и повторов как таковых** — это `tnt-pool`
и `tnt-retry`; драйвер SQL над роком заводит их сам из пакетов, которые
ему дали аргументом, и тем, кому нужны только отказ, срок и значения,
их ставить незачем. **Сборки запросов** — текст и параметры даёт
вызывающий. Настроек и состояния у пакета нет.

## Как пользоваться

### Вызов из трёх частей

Так выглядит вызов драйвера, собранный из отказа, срока и значений. Рок
здесь — двойник с `fiber.sleep`: пример идёт без базы.

```lua
local fiber = require('fiber')
local storage = require('tnt.storage')

local failure, value, within = storage.failure, storage.value, storage.within

-- в new драйвера: сроки из его настроек
local limits = within.settings(nil, 30)
--> { timeout = 5, max_timeout = 30 }

-- рок-двойник: отвечает через `pause` секунд
local function execute(pause, ...)
    fiber.sleep(pause)
    return { { { n = select('#', ...) } } }
end

-- вызов: срок, миг, параметры, ожидание, род отказа
local function query(pause, params, opts)
    local timeout = within.timeout(opts.timeout, limits, 2)
    local deadline = within.deadline(timeout)
    local encoded, refused = value.params('postgres', params, 2)

    if encoded == nil then
        return nil, refused
    end

    local status, datas = within.call(deadline, function()
        return execute(pause, unpack(encoded, 1, encoded.n))
    end)

    if status == within.EXPIRED then
        return nil, failure.new(failure.TIMEOUT, ('ответа нет за %s с'):format(timeout), {
            idempotent = opts.idempotent,
        })
    end

    if status == within.RAISED then
        return nil, failure.statement(datas, nil, { idempotent = opts.idempotent })
    end

    return datas[1]
end

query(0, { n = 3, 1, nil, 9007199254740993LL }, {})
--> { { n = 3 } }
query(1, { n = 0 }, { timeout = 0.1, idempotent = true })
--> nil, ответа нет за 0.1 с    (kind = timeout, sent = true, retriable = true)
query(0, { n = 1, 'a\0b' }, {})
--> nil, строка с нулевым байтом: pg обрезал бы её молча    (kind = rejected, sent = false)
query(0, nil, { timeout = 90 })
--> исключение: timeout 90 с длиннее потолка max_timeout 30 с
```

Уровень `2` в `within.timeout` и `value.params` — вина на строке того,
кто позвал `query`: опечатка в сроке — его, а не драйвера.

Соединения из пула здесь нет, и `within.call` зовётся без `pcall`.
Драйвер, который держит соединение, ловит бросок `call` сам: иначе
отмена вызывающего оставит соединение занятым до конца жизни узла —
«Ожидание рока: `within.call`».

### Отказ

Отказ — пара `nil, err`, где `err` — таблица `TntStorageFailure`,
читаемая и как строка: `tostring(err)`, `'причина: ' .. err`
и `json.encode` дают текст, как у отказа `tnt-http`, — и отказ можно
отдать туда, где прежде ждали строку. Исключение — только ошибка
программиста.

| Поле | Что |
|---|---|
| `kind` | род, таблица ниже |
| `message` | текст для вызывающего, прошедший `tnt-log.scrub` |
| `reason` | первая строка — для журнала: в `DETAIL` PostgreSQL кладёт значения строки |
| `retriable` | повторил бы драйвер сам: `tnt-retry` смотрит это поле первым |
| `sent` | мог ли оператор дойти до сервера |
| `server_code` | SQLSTATE, errno, первое слово отказа Redis, код MongoDB либо код ответа HTTP; не `code` — `tnt-retry` его нарочно не читает, а каталоги отказов приложения понимают под ним свой код |

| Род | Когда | `sent` | `retriable` |
|---|---|---|---|
| `unreachable` | соединение не открылось: сеть, вход не уложился в срок | нет | да |
| `denied` | сервер отказал во входе: пароль, нет базы, нет прав | нет | нет |
| `busy` | за срок не досталось соединения из пула | нет | да |
| `timeout` | ответа нет за срок вызова либо сработал срок сервера | да | с `idempotent = true` |
| `broken` | соединение оборвалось посреди работы | да | с `idempotent = true` |
| `rejected` | сервер отказал оператору; значение не отправлено | да | нет |
| `conflict` | сериализация, взаимоблокировка, блокировка не взята | да | нет — повторяют всю транзакцию |
| `closed` | драйвер закрыт | нет | нет |
| `overflow` | строк больше `max_rows` | да | нет |

`sent` и `retriable` — умолчания рода; драйвер задаёт их сам, когда знает
больше: срок, вышедший до отправки, — `timeout` с `sent = false`, и тогда
повтора нет и с согласием вызывающего. Согласие — `idempotent = true`:
сервер мог выполнить оператор, и обрыв до отправки от обрыва после
по тексту не отличить.

```lua
local err = failure.new('timeout', 'ответа нет за 0.3 с', { idempotent = true })
--> err.kind = timeout, err.sent = true, err.retriable = true
'причина: ' .. err
--> причина: ответа нет за 0.3 с

failure.new('timeout', 'срок вышел до отправки', { sent = false, idempotent = true }).retriable
--> false

failure.new('unreachable', 'вход в postgres://app:hunter2@db/app не удался').message
--> вход в postgres://app:[скрыто]@db/app не удался

failure.is(err)                    --> true
failure.is({ kind = 'timeout' })   --> false

failure.new('lost', 'x')
--> исключение: род отказа lost незнаком: есть unreachable, denied, busy, timeout, broken, rejected, conflict, closed, overflow
```

`failure.new(kind, message, opts, level)` — настройки `sent`, `retriable`,
`idempotent`, `server_code` и `reason`; незнакомый ключ — исключение.
`reason` задают, когда текст несёт то, чего в журнал не пишут.

#### Род по коду сервера и по словам

Роки отказывают исключением-строкой. Род из него собирают три функции;
текст рока они сначала освобождают от приписки места
(`…/pg/init.lua:129: `) — это делает и `failure.text(err)`.

- `failure.login(err, code)` — отказ входа: `denied` либо `unreachable`,
  `sent = false`.
- `failure.statement(err, code, { idempotent })` — отказ оператора при живом
  соединении: `conflict`, `timeout`, `broken` либо `rejected`, `sent = true`;
  у Redis ещё `denied` и `busy` — без отправки: команды сервер не выполнял.
  Живость драйвер проверяет раньше и сам (`active()` у `pg`, `quote('')`
  у `mysql`): бросила — это `broken` без всякого кода.
- `failure.status(status, message, { idempotent })` и `failure.http(err,
  { idempotent })` — для драйверов поверх HTTP, ниже.

Код сервера, если он есть, решает один: SQLSTATE у PostgreSQL, errno
у MySQL, первое слово отказа у Redis (`WRONGTYPE`, `LOADING`; общее `ERR`
кодом не считается). Код отдаёт не всякий рок: выпуски `pg` 2.0.2
и `mysql` с rocks.tarantool.org бросают строку без кода, и код есть
только у сборок, которые его сохраняют. Незнакомый код — `rejected`
у оператора и `unreachable` у входа. Без кода род решают слова отказа,
и сверяются они до `scrub`: у MySQL `scrub` принимает «(using password:
YES)» за тайну.

| Род | SQLSTATE | errno | Redis | Слова без кода |
|---|---|---|---|---|
| вход `denied` | `28000`, `28P01`, `3D000`, `42501` | `1044`, `1045`, `1049`, `1129`, `1130`, `1251`, `1698`, `1862`, `2059`, `3118` | `WRONGPASS`, `NOAUTH`, `NOPERM`, `DENIED` | `password authentication failed`, `does not exist`, `no pg_hba.conf entry`, `Access denied`; у Redis — `invalid username-password pair`, `invalid password`, `without any password configured`, `no password is set`, `Authentication required`, `has no permissions`, `running in protected mode`, `DB index is out of range` |
| `conflict` | `40001`, `40P01`, `55P03` | `1205`, `1213`, `3572` | — | `could not serialize access`, `deadlock detected`, `canceling statement due to lock timeout`, `Deadlock found when trying to get lock`, `Lock wait timeout exceeded` |
| `timeout` | `57014` | `3024` | — | `canceling statement due to statement timeout`, `maximum statement execution time exceeded` |
| `broken` | класс `08`, `57P01`–`57P05`, `25P03`, `25P04` | `1053`, `1927`, `2006`, `2013`, `2055`, `4031` | — | `server closed the connection unexpectedly`, `terminating connection`, `Lost connection to MySQL server`, `MySQL server has gone away` |
| `denied` оператора | — | — | `NOAUTH`, `WRONGPASS`, `NOPERM`, `DENIED` | — |
| `busy` оператора | — | — | `BUSY`, `LOADING`, `MASTERDOWN`, `READONLY`, `TRYAGAIN`, `CLUSTERDOWN`, `NOREPLICAS` | — |

У Redis оператор бывает `denied` и `busy`: сервер отказал, не выполнив
команды, — нет прав либо он занят (сценарий, загрузка с диска, смена
ведущего). `busy` повторяется всегда: команда не выполнялась. Слова Redis
у входа нужны и при коде: отказ входа, пришедший из пула строкой по сроку,
кода уже не несёт.

```lua
failure.statement('/usr/share/tarantool/pg/init.lua:129: ERROR:  could not serialize access', '40001')
--> kind = conflict, retriable = false, server_code = 40001, message = ERROR:  could not serialize access

failure.statement('Query execution was interrupted', 3024, { idempotent = true })
--> kind = timeout, retriable = true

failure.statement('BUSY Redis is busy running a script', 'BUSY')
--> kind = busy, sent = false, retriable = true

failure.login('FATAL:  password authentication failed for user "app"')
--> kind = denied, sent = false, retriable = false

failure.login('connection to server at "10.0.0.5", port 5432 failed: Connection refused')
--> kind = unreachable, retriable = true
```

Сами правила открыты и в `tnt.storage.codes`: `codes.login(code, text)`,
`codes.statement(code, text)` и `codes.status(status)` отдают род словом
— драйверу, который собирает отказ сам.

#### Коды MongoDB

У MongoDB код — число, как errno у MySQL, но значат числа разное: 13 у
MongoDB — «нет прав», а 1045 — ничего. Поэтому таблица у MongoDB своя,
а не общая с errno, и спрашивают её отдельно: `codes.mongo(code, labels)`
у отказа оператора и `codes.mongo_login(code)` у входа. Имени кода
(`codeName`) у отказа записи внутри ответа нет, поэтому род решает число.

| Род | Коды MongoDB |
|---|---|
| вход `denied` | `11` UserNotFound, `13` Unauthorized, `18` AuthenticationFailed, `334` MechanismUnavailable; прочие — `unreachable` |
| `conflict` | `112` WriteConflict, `24` LockTimeout, `251` NoSuchTransaction; метка `TransientTransactionError` при любом коде |
| `timeout` | `50` MaxTimeMSExpired, `262` ExceededTimeLimit, `64` WriteConcernFailed |
| `denied` оператора | `13` Unauthorized |
| `busy` оператора | `10107` NotWritablePrimary, `13435` NotPrimaryNoSecondaryOk, `13436` NotPrimaryOrSecondary |
| `broken` | `91`, `189`, `11600`, `11602` — остановка и смена ведущего посреди операции; `6`, `7`, `89`, `9001` — сеть между узлами |
| `rejected` | прочие: `11000` DuplicateKey, `2` BadValue, `26` NamespaceNotFound… |

Метка `TransientTransactionError` главнее кода: с ней сервер снял
транзакцию целиком, и повторять можно только её всю. `busy` у MongoDB —
узел не ведущий: запись не принята и не выполнялась, повтор безопасен.
Отказ собирает драйвер: `failure.new(codes.mongo(code, labels), text, {
server_code = code, … })`.

```lua
local codes = require('tnt.storage.codes')

codes.mongo(11000)                                  --> 'rejected'
codes.mongo(11000, { 'TransientTransactionError' }) --> 'conflict'
codes.mongo(10107)                                  --> 'busy'
codes.mongo_login(18)                               --> 'denied'
codes.mongo_login(59)                               --> 'unreachable'
```

#### Отказ HTTP

Драйверу поверх HTTP — две функции. `failure.status(status, message,
{ idempotent })` — ответ пришёл, но это отказ: 401 и 403 — `denied`,
409 и 412 — `conflict`, 429 и 503 — `busy`, прочие 4xx и всё ниже 400 —
`rejected`, 5xx — `broken`. `failure.http(err, { idempotent })` переводит
отказ `tnt-http` целиком. Отказ сети `unreachable` у `tnt-http` один
и до отправки, и после, поэтому род берётся по его признаку `sent`.
`sent = false` — запрос точно не ушёл: имя узла или прокси
не разрешилось, соединение не открылось, рукопожатие TLS не прошло, —
и это `unreachable`, как бы libcurl ни назвал отказ. Иначе срок
(«Timeout was reached») — `timeout`, прочее — `broken`. Слов «не ушло»
у `tnt-storage` нет: их знает `tnt-http` рядом с самим libcurl, а тексты
libcurl меняются от выпуска к выпуску («Couldn't connect to server»
с 8.9 стал «Could not connect to server»). Второй их список однажды
разошёлся бы с первым, и драйверы поверх HTTP судили бы об одном отказе
иначе, чем `tnt-etcd-client`. Отказ без признака `sent` — «могло уйти»:
ошибка в эту сторону стоит лишнего отказа, а в другую — двойной записи.
`idle` — `timeout`, `invalid` — `rejected` без отправки, `refused` —
`rejected` после неё, незнакомый род — `broken`. В `reason` идёт причина
`tnt-http` без адреса: в адресе ездят ключи доступа.

```lua
failure.status(409, 'PUT /i/_doc/1: версия устарела')
--> kind = conflict, sent = true, retriable = false, server_code = 409

failure.http({ kind = 'status', status = 503, message = 'GET http://os:9200/i/_search: сервер ответил 503', reason = 'сервер ответил 503' })
--> kind = busy, sent = false, retriable = true, server_code = 503, reason = сервер ответил 503

failure.http({ kind = 'unreachable', sent = true, message = 'PUT http://s3/b/k: сервер не ответил: Timeout was reached (код 408)' })
--> kind = timeout, sent = true, retriable = false

failure.http({ kind = 'unreachable', sent = false, message = 'PUT http://s3/b/k: сервер не ответил: Could not connect to server (код 595)' })
--> kind = unreachable, sent = false, retriable = true

failure.http({ kind = 'unreachable', sent = true, message = 'PUT http://s3/b/k: libcurl отказал: curl: Failure when receiving data from the peer: Connection reset by peer' })
--> kind = broken, sent = true, retriable = false

failure.http({ kind = 'unreachable', message = 'PUT http://s3/b/k: сервер не ответил: Could not connect to server (код 595)' })
--> kind = broken, sent = true, retriable = false
```

### Срок

```lua
local limits = within.settings(opts.timeout, opts.max_timeout)   -- в new драйвера
local timeout = within.timeout(call_opts.timeout, limits)         -- в вызове
local deadline = within.deadline(timeout)                         -- миг, один на вызов
local left = within.left(deadline)                                -- перед каждым ожиданием
```

- **Без срока звать нельзя.** Срок вызова — его `timeout`, иначе срок
  драйвера, по умолчанию `DEFAULT_TIMEOUT = 5` с. Ноль, отрицательное,
  NaN, бесконечность и не число — исключение: ожидание без срока не ждёт
  никого.
- **Потолок** `max_timeout`, по умолчанию `DEFAULT_MAX_TIMEOUT = 60` с:
  срок длиннее — исключение. Отменённый запрос дорабатывает на сервере,
  и потолок длиннее минуты держал бы брошенную работу дольше, чем ждёт
  её любой запрос к узлу; у PostgreSQL потолком служит `statement_timeout`
  соединения, который фасад ставит равным `max_timeout`. Срок драйвера
  длиннее его потолка — тоже исключение, уже в `settings`: иначе драйвер
  с потолком в 3 с отказывал бы на каждом вызове без срока.
- **Миг — настоящими часами на входе** вызова, `monotonic() + timeout`;
  **остаток — от времени планировщика** перед каждым ожиданием: пула,
  входа, ответа, `ROLLBACK`, паузы повтора. Работа без уступки перед
  вызовом срок не съедает, а ожидание кончается ровно в миг.

```lua
within.settings()                 --> { timeout = 5, max_timeout = 60 }
within.settings(nil, 3)           --> исключение: timeout 5 с длиннее потолка max_timeout 3 с
within.timeout(nil, limits)       --> 5
within.timeout(0.3, limits)       --> 0.3
within.timeout(0, limits)         --> исключение: timeout — число секунд больше нуля и меньше бесконечности, а не 0
```

Уровень вины у `settings` и `timeout` — последний аргумент, как у `error`,
в кадрах того, кто их зовёт: `1` — его строка (по умолчанию), `2` — его
вызывающий.

#### Ожидание рока: `within.call`

`within.call(deadline, fn, late)` зовёт `fn` в отдельном файбере
(`tnt.storage.within` в `fiber.info()`) под контекстом вызывающего
(`tnt-context`: запись из тела не теряет `request_id`) и ждёт итога
до мига. Первое значение — исход словом:

| Исход | Что дальше | Что с соединением у драйвера |
|---|---|---|
| `returned` | значения тела, все, с `nil` посреди | вернуть в пул |
| `raised` | брошенное телом: рок отказывает исключением | по живости и коду |
| `expired` | ничего: работник отменён, итог уйдёт в `late` | выбросить: в сокете недочитанный ответ |
| `skipped` | ничего: срок вышел раньше, тело не звалось | вернуть в пул: рок не звался |
| бросок, не исход | исключение отмены: отменили вызывающего; работник отменён, итог уйдёт в `late` | как у `expired`, затем поднять отмену — ниже |

`late(ok, ...)` получает то, что отдал бы `pcall(fn)`, в файбере
работника, когда итог пришёл после отмены: соединение, открытое
опоздавшим входом, закрывается там, где оно появилось.

```lua
within.call(within.deadline(1), function() return 1, nil, 3 end)
--> returned, 1, nil, 3

within.call(within.deadline(1), function() error('рок упал', 0) end)
--> raised, рок упал

within.call(within.deadline(0.05), function() fiber.sleep(10) end, function(ok, err)
    print('опоздал:', ok, err)
end)
--> expired
--> опоздал: false fiber is cancelled

within.call(within.deadline(0) - 1, function() print('не звалось') end)
--> skipped
```

**Отмена вызывающего — бросок, а не исход.** Вызывающего, которого самого
отменили в ожидании, `call` не прячет: работник отменяется так же, как
по сроку, а исключение отмены идёт дальше, мимо драйвера. Драйвер,
который взял соединение из пула и зовёт `call` без `pcall`, на отмене
не вернёт его и не выбросит: соединение останется занятым до конца жизни
узла — пул о таком только пишет в журнал, — и после стольких отмен,
сколько в пуле мест, пул не отдаст ни одного соединения. Поэтому бросок
драйвер ловит сам:

1. `pcall(within.call, …)`; бросок — исход `expired`: работник отменён,
   в сокете недочитанный ответ;
2. соединение выбросить без ожидания: в отменённом файбере каждое
   ожидание — сон, уступка, чтение канала — бросает отмену снова.
   Закрытие рока, которое ждёт замка соединения, остаётся выходу
   работника, как у драйвера SQL над роком (ниже);
3. отмену поднять после, `fiber.testcancel()`: отменили вызывающего,
   а не вызов, и пара выдала бы отмену за отказ хранилища.

```lua
-- пул-двойник: соединение занято, пока драйвер его не вернёт либо не выбросит
local pool = { busy = 0, drops = 0 }

local function run(deadline, fn)
    pool.busy = pool.busy + 1

    local called, status, value = pcall(within.call, deadline, fn)

    if not called then
        status = within.EXPIRED       -- отменили вызывающего: как по сроку
    end

    pool.busy = pool.busy - 1

    if status == within.EXPIRED then
        pool.drops = pool.drops + 1   -- выбросить: в сокете недочитанный ответ
    end

    fiber.testcancel()                -- отмена — дальше, соединение уже выброшено

    return status, value
end

local caller = fiber.new(run, within.deadline(5), function() fiber.sleep(10) end)
caller:set_joinable(true)
fiber.sleep(0.01)
caller:cancel()

caller:join()
--> false, fiber is cancelled
pool
--> { busy = 0, drops = 1 }    (без pcall — { busy = 1, drops = 0 })
```

### Значения

`value.wire(dialect, v)` → `значение, приведение`. Значение — то, что рок
передаст без порчи; приведение — тип для PostgreSQL, который построитель
запросов ставит в текст как `$n::тип`: без него сервер отказывает громко
(«expression is of type text»), а не молча. Диалект — имя (`'postgres'`,
`'mysql'`, `'tarantool'`, `'redis'`, `'mongo'`) либо таблица диалекта
драйвера с полем `name`.

| Значение | `postgres` | `mysql` | `tarantool` | `redis` |
|---|---|---|---|---|
| `nil`, `box.NULL` | `box.NULL` | `box.NULL` | `box.NULL` | исключение |
| логика | как есть | как есть | как есть | исключение |
| строка | как есть | как есть | как есть | как есть |
| целое до 14 значащих цифр | как есть, `int8` | как есть | как есть | цифры |
| целое длиннее, до ±2⁵³ | цифры, `int8` | как есть | как есть | цифры |
| дробное до 14 значащих цифр | как есть | как есть | как есть | точный текст |
| дробное длиннее | точный текст, `numeric` | как есть | как есть | точный текст |
| число за ±2⁵³, NaN, бесконечность | исключение | исключение | исключение | исключение |
| `int64`, `uint64` | текст, `int8`; выше 2⁶³−1 — `numeric` | текст | как есть | текст |
| `decimal` | текст, `numeric` | текст | как есть | текст |
| `uuid` | текст, `uuid` | текст | как есть | текст |
| `datetime` | ISO 8601 со сдвигом числом, `timestamptz` | `%Y-%m-%d %H:%M:%S.%6f` в UTC | как есть | ISO 8601 со сдвигом числом |
| `storage.json(v)` | текст JSON, `jsonb` | текст JSON | текст JSON | текст JSON |
| `storage.binary(s)`, `varbinary` | `\x…`, `bytea` | байты | `varbinary` | байты |
| строка с нулевым байтом | отказ `rejected`, `sent = false` | как есть | как есть | как есть |
| таблица без обёртки, функция, иной cdata | исключение | исключение | исключение | исключение |

У `redis` значение — всегда строка байтов: команда Redis — список строк.
Целое уходит цифрами без степени — `INCRBY k 1e+15` Redis отвергает
(проверено на 7.4), а `tostring(1e15)` в Tarantool даёт именно `1e+15`;
дробное — самой короткой точной записью. Пустого и логики у Redis нет,
и угадывать за вызывающего, `''` это или `'0'`, модуль не берётся.

У `mongo` второе значение — не приведение, а тип BSON, которым значение
уйдёт: документ BSON несёт тип при каждом значении, и выбирать его по месту,
как делал бы каждый драйвер сам, значит однажды выбрать по-разному.
Документ и массив собирает драйвер, а не модуль: таблица без обёртки
у `mongo` — исключение, как у прочих.

| Значение | `mongo` |
|---|---|
| `nil`, `box.NULL` | `box.NULL`, `null` |
| логика, строка | как есть, `bool`, `string` |
| целое до ±2³¹ | как есть, `int32` |
| целое до ±2⁵³ | как есть, `int64` |
| дробное | как есть, `double` |
| число за ±2⁵³, NaN, бесконечность | исключение |
| `int64`, `uint64` до 2⁶³−1 | `int64`, `int64` |
| `uint64` выше 2⁶³−1 | исключение: беззнакового целого в BSON нет |
| `decimal`, `uuid` | как есть, `decimal128`, `uuid` |
| `datetime` | миллисекунды `int64`, `date`; остаток — вниз |
| `storage.json(v)` | текст JSON, `string` |
| `storage.binary(s)`, `varbinary` | байты, `binary` |
| таблица без обёртки, функция, иной cdata | исключение |

Время у `mongo` — миллисекунды от начала эпохи: у типа `date` точность
такая, и остаток отбрасывается вниз и до эпохи (`epoch` у даты — целые
секунды, `nsec` не бывает отрицательным).

Четыре правила таблицы, которые легко написать неверно:

- **NULL — всегда `box.NULL`.** `box.execute` теряет всё после дыры
  в массиве параметров: `{ 1, nil, 3 }` доезжает как `1, NULL, NULL`
  (проверено на 3.8). Оба рока принимают `box.NULL` за NULL.
- **Целое у `postgres` — с `int8`.** Рок шлёт всякое число типом
  `numeric`, и сравнение целого столбца с `numeric` идёт мимо индекса:
  `where id = $1` просматривает всю таблицу, а `where id = $1::int8`
  идёт по индексу — у столбцов `int2`, `int4` и `int8` (сверено планом
  запроса на PostgreSQL 16). Тип столбца модулю неизвестен, и `int8`
  выбран потому, что с ним сравниваются все три. Само число остаётся
  числом: драйвер отдаёт року значение без приведения, и в тексте,
  написанном руками без `$1::int8`, оно сравнится как прежде — `numeric`.
  Строка на его месте у рока, который шлёт строки текстом, отказала бы
  «operator does not exist: integer = text».
- **Число длиннее 14 значащих цифр у `postgres` — точным текстом.** Рок
  превращает число в текст `%.14g` — так же, как `tostring` в Tarantool:
  `tostring(123456789012345)` даёт `1.2345678901235e+14`. Портится всё,
  что длиннее 14 цифр, а не только числа за 2⁵³. Целое пишется цифрами
  без степени (`1234567890123450`, а не `1.23456789012345e+15`: такой
  записи `int8` не читает), дробное — самой короткой записью, которая
  читается обратно тем же числом, с `numeric` (`0.1 + 0.2` →
  `0.30000000000000004`, `123456789012345.6` → `123456789012345.6`).
- **Время у `postgres` — со сдвигом числом**, а не `tostring`: у даты
  с поясом `tostring` отдаёт `2026-09-13T12:34:56 Europe/Moscow`, а имя пояса
  на сервере может значить другое.

```lua
value.wire('postgres', 9007199254740993LL)      --> '9007199254740993', 'int8'
value.wire('mysql', 9007199254740993LL)         --> '9007199254740993'
value.wire('postgres', 123456789012345)         --> '123456789012345', 'int8'
value.wire('postgres', 42)                      --> 42, 'int8'
value.wire('postgres', 1.5)                     --> 1.5
value.wire('postgres', 0.1 + 0.2)               --> '0.30000000000000004', 'numeric'
value.wire('postgres', decimal.new('1.10'))     --> '1.10', 'numeric'
value.wire('postgres', storage.json({ a = 1 })) --> '{"a":1}', 'jsonb'
value.wire('postgres', storage.binary('\0\255'))--> '\x00ff', 'bytea'
value.wire('mysql', datetime.new({ year = 2026, month = 9, day = 13, hour = 12, min = 34, sec = 56, tzoffset = 180 }))
--> '2026-09-13 09:34:56.000000'
value.wire('redis', 1e15)                       --> '1000000000000000'
value.wire('redis', 0.1 + 0.2)                  --> '0.30000000000000004'
value.wire('redis', 9007199254740993LL)         --> '9007199254740993'
value.wire('redis', true)
--> исключение: логику в Redis не передать: у него только строки — передайте строку явно
value.wire('mongo', 7)                          --> 7, 'int32'
value.wire('mongo', 2 ^ 31)                     --> 2147483648, 'int64'
value.wire('mongo', decimal.new('1.10'))        --> 1.10, 'decimal128'
value.wire('mongo', datetime.new({ timestamp = -1.5 }))
--> -1500LL, 'date'
value.wire('mongo', 9223372036854775808ULL)
--> исключение: uint64 9223372036854775808ULL не уходит в BSON: он больше 2^63−1
value.wire('postgres', 'a\0b')                  --> nil, nil, строка с нулевым байтом: pg обрезал бы её молча
value.wire('mysql', { 1 })
--> исключение: значение table нельзя передать параметром: таблицу оберните json, байты — binary
value.wire('mysql', 2 ^ 60)
--> исключение: число 1.1529215046068e+18 за пределом ±2^53: целые там неточны — передайте int64 либо decimal
```

`storage.json(v)` кодирует сразу, в миг вызова, своим кодировщиком
(`json.new()`: чужой `json.cfg` не меняет того, что уходит в базу).
Таблица, поправленная после, в базу не попадёт; значение, которого JSON
не выражает, бросает на строке вызывающего. Пустая таблица — массив либо
объект по `__serialize`, как у `json.encode`: `storage.json({})` — `[]`.

NaN и бесконечность где угодно в глубине значения — исключение, то же
правило, что у параметров. Кодировщик по умолчанию написал бы их словами
`nan` и `inf`, а это не JSON: `jsonb` PostgreSQL и службы поверх HTTP
отвергли бы значение уже на сервере — лишним обращением к сети
и словами сервера вместо строки того, кто передал число. Значение, где
кроме нечисла есть и функция, отказ называет функцией: её JSON
не выражает ни при каких настройках.

```lua
storage.json({ a = { 1.5, 9007199254740993LL } }).text  --> '{"a":[1.5,9007199254740993]}'
storage.json({ a = { b = 0 / 0 } })
--> исключение: значение не кодируется в JSON: NaN и бесконечность не выражаются
storage.json({ math.huge, print })
--> исключение: значение не кодируется в JSON: unsupported Lua type 'function'
```

#### Параметры вызова

`value.params(dialect, params)` — проверка и кодирование всех параметров
вызова: `params` — массив с полем `n`, чтобы `nil` посреди не терялся.
Без `n`, с ключом вне `1..n`, не таблица — исключение: рок принял бы
таблицу одним значением и молча записал NULL. Отказ данных у любого
значения — пара `nil, err`. Диалект проверяется и при пустых параметрах.

```lua
value.params('postgres', { n = 3, 1, nil, 9007199254740993LL })
--> { n = 3, 1, box.NULL, '9007199254740993' }
value.params('mysql', { 1, 2 })
--> исключение: params.n — целое число, а не nil
```

#### Двоичное из ответа

`storage.decode_binary(dialect, raw)`: PostgreSQL отдаёт `bytea` текстом
`\x…`, MySQL — байтами, Tarantool — `varbinary`. NULL (нет ключа)
остаётся `nil`. Текст не в виде `\x…` у PostgreSQL — исключение: это
не `bytea` либо сервер отдаёт `bytea_output = 'escape'`.

```lua
storage.decode_binary('postgres', '\\x00ff')  --> '\0\255'
storage.decode_binary('postgres', nil)        --> nil
storage.decode_binary('mysql', '\0\255')      --> '\0\255'
```

Выборку пакет не приводит к типам: рок не отдаёт типов столбцов, и угадывать
тип по значению — портить строки, похожие на числа. Столбец, которому нужна
точность, берут в запросе текстом (`id::text`, `cast(amount as char)`)
и разбирают сами.

### Драйвер SQL над роком

Роки `pg` и `mysql` устроены одинаково там, где драйверу это важно: срока
нет ни на вход, ни на запрос, отказ — бросок, соединение однопоточное
и держит свой замок. Поэтому пул, срок, повторы, транзакции и решение
о соединении написаны один раз, здесь, а фасад над роком приносит только
своё: настройки и **знание рока** — таблицу `TntStorageRock`.

| Поле `TntStorageRock` | Что | `pg` | `mysql` |
|---|---|---|---|
| `label`, `where` | начало текста отказа: имя и узел без учётных данных | `postgres`, `h:5432/app` | `mysql`, `h:3306/app` |
| `connect()` | открыть соединение; отказ — бросок | строкой соединения | аргументами |
| `shut(conn)` | закрыть, чем бы ни кончилось | `link.shut` | `link.shut` |
| `state(conn)` | жив ли без сети; открыта ли транзакция, если рок знает | `active()` | `quote('')`, о транзакции — ничего |
| `execute(conn, sql, params)` | оператор; отдаёт наборы записей первым значением | `link.execute` | `link.execute` |
| `code(err)` | код сервера из броска либо `nil` | SQLSTATE | errno |
| `text(err)` | текст отказа до `scrub` | `failure.text` | и слово вместо «(using password: …)» |
| `count(...)` | ответ оператора без выборки из того, что отдал рок | `{ affected }` | `{ affected, last_id }` |

`link.shut(conn)` зовёт `close()` рока, а на оборванном соединении, где тот
бросает и сокета не закрывает, — `close()` объекта драйвера под ним
(`conn.conn`). `link.execute(conn, sql, params)` передаёт параметры
аргументами после текста, с `nil` посреди.

Фасад целиком — описание, из которого `driver.facade` делает `new`. Рок
в примере — двойник в памяти `memo`, чтобы пример шёл без базы; знание
настоящего рока устроено так же.

```lua
local driver = require('tnt.storage.driver')
local failure = require('tnt.storage.failure')
local link = require('tnt.storage.link')

-- Знание рока: как его загрузить и как с ним говорить.
local rock = {
    -- Не хвостовым вызовом ни здесь, ни в `check`: хвостовой снимает кадр,
    -- и вина уходит на строку выше того, кто завёл драйвер.
    load = function(level)
        local memo = link.require('memo', 'поставьте рок memo', level + 1)

        return memo
    end,
    new = function(settings, memo)
        return {
            label = 'memo',
            where = settings.where,
            connect = function()
                return memo.connect({ user = settings.user, password = settings.password, db = settings.db })
            end,
            shut = link.shut,
            state = function(conn)
                local ok, open = pcall(conn.active, conn)

                if not ok then
                    return false
                end

                return true, open
            end,
            execute = link.execute,
            code = function()
                return nil
            end,
            text = failure.text,
            count = function(_, affected)
                return { affected = affected }
            end,
        }
    end,
}

local new = driver.facade({
    dialect = { name = 'postgres' },
    -- Уровень 3: вина на строке того, кто позвал `new` фасада.
    check = function(opts)
        local checked = driver.settings(opts, 'настройки memo', { name = 'memo', port = 5432 }, 3)

        return checked
    end,
    rock = rock,
    log = require('tnt.log').new('app.memo'),
    pool = require('tnt.pool'),
    retry = require('tnt.retry'),
})

local db = new({ user = 'app', password = 'secret', db = 'app' })

db:query('select id, login from users where id = $1', { n = 1, 1 })
--> { { id = 1, login = 'ann' } }
db:execute('insert into users (login) values ($1)', { n = 1, 'bob' })
--> { affected = 1 }
db:query('select id from users where id = $1', { n = 1, 2 ^ 60 })
--> исключение: число 1.1529215046068e+18 за пределом ±2^53: целые там неточны — передайте int64 либо decimal
db:query('delete from users')
--> nil, ERROR:  syntax error at or near "delete"    (kind = rejected)

local ok, err = db:transaction(function(tx)
    tx:execute('insert into users (login) values ($1)', { n = 1, 'eve' })
    return nil, 'передумали'
end)
--> nil, передумали    (соединение получило BEGIN, insert и ROLLBACK)

new({ user = 'app', password = 'wrong', db = 'app' }):query('select id, login from users where id = $1', { n = 1, 1 })
--> nil, memo 127.0.0.1:5432/app: вход не удался: FATAL:  password authentication failed for user "app"    (kind = denied)

db:close()                               --> true
db:query('select 1')                     --> nil, memo: драйвер закрыт    (kind = closed)
```

Двойник, на котором идёт пример: `connect` проверяет пароль, соединение
знает два оператора и помнит, открыта ли транзакция.

```lua
package.loaded['memo'] = {
    connect = function(opts)
        if opts.password ~= 'secret' then
            error(('FATAL:  password authentication failed for user "%s"'):format(opts.user), 0)
        end

        local conn = { open = false, conn = { close = function() end } }

        function conn.execute(self, sql, ...)
            if sql == 'BEGIN' or sql == 'COMMIT' or sql == 'ROLLBACK' then
                self.open = sql == 'BEGIN'

                return { {} }, 0
            end

            if sql:find('^select') then
                return { { { id = ..., login = 'ann' } } }, 0
            end

            if sql:find('^insert') then
                return { {} }, 1
            end

            error(('ERROR:  syntax error at or near "%s"'):format(sql:match('^%S+')), 0)
        end

        function conn.active(self)
            return self.open
        end

        function conn.close() end

        return conn
    end,
}
```

`new` проверяет настройки, грузит рок по имени (без рока — исключение
на строке заведшего), заводит повторы (`scope` — имя драйвера) и пул
с крюками `link.open`, `link.close`, `link.alive`, `link.reset` и отдаёт
драйвер. Соединений `new` не открывает: первое откроет первый вызов.
Диалект у каждого драйвера — своя копия: общая таблица, поправленная
через один драйвер, поменяла бы сборку запросов всем.

#### Настройки: `driver.settings`

`driver.settings(opts, title, { name, port }, level)` — общая проверка
настроек фасада: набор ключей `driver.OPTIONS`, порт, предел строк, сроки
через `within.settings`. Отдаёт их с умолчаниями и `where` — узлом, портом
и базой для текста отказа, без учётных данных. Проверяется всё и сразу,
при заведении: драйвер заводят при подъёме узла, а первый запрос шлют через
час под нагрузкой. Незнакомый ключ — исключение: опечатка в имени
(`pasword`) иначе молча оставила бы драйвер без пароля. Свой ключ фасад
добавляет к копии `driver.OPTIONS`, проверяет настройки по ней сам
и отдаёт `driver.settings` остальное: так отказ о незнакомом ключе
называет и его — у `tnt-mysql` это `server_public_key`.

| Ключ | Что | По умолчанию |
|---|---|---|
| `host` | узел | `127.0.0.1` (`driver.DEFAULT_HOST`) |
| `port` | порт, 1…65535 | порт службы от фасада |
| `user`, `db` | учётная запись и база — обязательны: иначе коннектор взял бы имя пользователя машины | — |
| `password` | пароль; наружу не отдаётся | нет |
| `tls` | `true` либо таблица; что значит, решает фасад | нет |
| `timeout`, `max_timeout` | срок вызова и его потолок, секунд | 5 и 60 |
| `max_rows` | предел строк выборки | 10000 (`driver.DEFAULT_MAX_ROWS`) |
| `pool` | `size`, `wait_timeout`, `idle_timeout`, `max_lifetime`, `open_cooldown`, `leak_timeout`, `sweep_interval` — для `tnt-pool` как есть | его умолчания |
| `retry` | `attempts`, `base`, `factor`, `max`, `jitter` — для `tnt-retry` как есть | его умолчания |
| `name` | имя драйвера: в журнале, в имени пула и ведре повторов | имя от фасада |

Роки читают ответ целиком, построчной выдачи у них нет: выборка в миллион
строк заняла бы память узла, в которой живут его данные. Предел в десять
тысяч больше любой страницы; большие выборки идут постранично по ключу.

```lua
new({ user = 'app', db = 'app', pasword = 'secret' })
--> исключение: настройки memo: ключа «pasword» нет, есть db, host, max_rows, max_timeout, name, password, pool, port, retry, timeout, tls, user
new({ user = 'app', db = 'app', timeout = 90 })
--> исключение: timeout 90 с длиннее потолка max_timeout 60 с
```

#### Вызовы драйвера

| Вызов | Что делает |
|---|---|
| `db:query(sql, params, opts)` | выборка: записи первого набора по именам столбцов, NULL — отсутствующий ключ |
| `db:execute(sql, params, opts)` | оператор без выборки: ответ в форме `count` знания рока |
| `db:transaction(fn, opts)` | транзакция на одном соединении, ниже |
| `db:close()` | закрывает: свободные соединения — сразу, занятые — когда их вернут; повторно — `false` и отказ `closed` |
| `db:stats()` | показатели пула: соединения, ожидания, выбросы; учётных данных в них нет |

Поля драйвера: `name`, `features = { transaction = true }`, `dialect`,
`where`, `limits`, `max_rows`, `wait_timeout`.

`params` — массив с полем `n`, как у `value.params`; настройки вызова —
`timeout`, `idempotent` и у выборки `max_rows`. Отказ сборки запроса —
пара `nil, err` с `TntStorageFailure` вместо `sql, params` — проходит
насквозь: так `db:query(build())` не бросает, если сборщик отказал,
а отдаёт его отказ.

Вызов — один миг срока на всё: взятие соединения, вход, ответ и паузы
повторов. Повторы — `tnt-retry` по полю `retriable` отказа: `unreachable`
и `busy` — всегда, `timeout` и `broken` — только с `idempotent = true`.
Срок, вышедший до очередной попытки, отдаёт отказ последней попытки без
повтора, а без попыток — `timeout` без отправки.

Соединение после оператора решает место отказа:

- `give` — рок ответил, соединение цело и чисто, либо срок вышел
  до вызова рока и сокет не тронут;
- `rollback` — сервер отказал, соединение цело, а транзакция на нём
  осталась открытой: её откатывает драйвер сам, в остаток срока, — крюк
  `reset` пула без сети и откатить не может;
- `drop` — работник отменён по сроку (в сокете недочитанный ответ) либо
  соединение оборвалось. Выброс пишется в журнал.

Соединение, выброшенное, пока работник внутри рока, закрывает выход
работника, а не тот, кто выбросил: закрытие рока ждёт замка соединения.
Отменённого вызывающего пара не останавливает: соединение к этому мигу
выброшено, а отмена уходит дальше тем же исключением.

#### Транзакция: `transaction`

`db:transaction(fn, { timeout, retry })` — `BEGIN`, тело, `COMMIT` либо
`ROLLBACK` на одном соединении:

- тело ничего не вернуло — фиксация и `true`, как у `box.atomic`; первое
  значение `nil` или `false` — откат и пара `nil, err`, где `err` тела
  отдаётся как есть; иное — фиксация и это значение;
- **первый отказ оператора помечает транзакцию**: следующие операторы `tx`
  сразу отдают тот же отказ, фиксации не будет. У PostgreSQL так ведёт
  себя сервер — и `COMMIT` после ошибки молча откатывает; у MySQL
  транзакция после ошибки цела, но правило одно на оба рока;
- исключение в теле — соединение выбрасывается (закрытие сокета откатывает
  транзакцию на сервере), исключение идёт дальше: это ошибка программиста;
- соединение, помеченное к выбросу оператором тела (отменённое ожидание),
  выбрасывается без `ROLLBACK`: в сокете недочитанный ответ;
- взятие соединения и `BEGIN` повторяются — тело ещё не выполнялось;
  операторы тела — никогда, и срока своего у них нет: срок один
  на транзакцию, настройки оператора — только `max_rows`;
- `retry = true` повторяет всю транзакцию с телом, если она кончилась
  конфликтом (`conflict`), — сервер откатил её целиком. Тело при этом
  обязано быть безопасным для повтора: всё, что оно делает мимо `tx`,
  случится дважды;
- `tx` годен только внутри тела; вложенная транзакция и транзакция внутри
  транзакции box — исключение.

Открыта ли транзакция, драйвер отмечает на соединении сам (`open`): рок
`mysql` этого не говорит, а крюк `reset` пула без отметки был бы слеп.
Рок, который знает (`pg`), отметку поправляет.

```lua
db:transaction(function(tx)
    tx:execute('insert into users (login) values ($1)', { n = 1, 'eve' })
    tx:execute('insert into users (login) values ($1)', { n = 1, 'max' })
end)
--> true

db:transaction(function(tx)
    tx:execute('insert', nil, { timeout = 1 })
end)
--> исключение: у оператора транзакции нет своего срока и повтора: их задаёт transaction
```

#### Журнал

Драйвер пишет журналом фасада, которым его завели:

| Уровень | Текст | Поля |
|---|---|---|
| `warn` | `соединение выброшено` | `driver`, `kind`, `reason` — первая строка отказа, без значений строки |
| `warn` | `соединение вернулось с открытой транзакцией` | `driver` |

Выброс — это новый вход на следующем вызове, и частые выбросы видны
только так. Соединение с открытой транзакцией при возврате — след ошибки
фасада либо `BEGIN`, посланного текстом: такое соединение выбрасывается,
а не откатывается, иначе следующий взявший зафиксировал бы чужую работу.

### Подмена в проверках: `_set_source`

Три модуля берут внешнее через `tnt-external`, и проверка подменяет его
на время, а затем возвращает настоящее `_set_source(nil)`:

| Модуль | Средства | Зачем подменять |
|---|---|---|
| `tnt.storage.within` | `monotonic`, `scheduler_now` | остаток срока ровно ноль и меньше нуля без сна |
| `tnt.storage.link` | `require` | рок-двойник вместо настоящего по имени |
| `tnt.storage.transaction` | `in_box_txn` | транзакция box без узла: до `box.cfg` обращение к `box.is_in_txn` роняет процесс |

```lua
link._set_source({
    require = function()
        return package.loaded['memo']
    end,
})
-- … драйвер к двойнику …
link._set_source(nil)
```

## Чем пришлось поступиться

- **Число за ±2⁵³ — исключение, даже дробное по замыслу.** В Lua не видно,
  целое ли `6.02e23`, а целые там уже неточны: `2^60 + 1` — это `2^60`.
  Точное большое число передают `int64` либо `decimal`.
- **Строка, похожая на число, у `pg` 2.0.2 уходит числом** (`'0012'` → `12`)
  — модулем не лечится: приведение `$n::text` не спасает. Лечит только рок,
  который привязывает строки текстом.
- **Число длиннее 14 цифр у `postgres` — текстом с приведением**
  (`int8` у целого, `numeric` у дробного): текст, написанный руками без
  `$n::int8` или `$n::numeric`, с таким числом на роке 2.0.2 проходит
  (рок шлёт строку-число числом), а на роке, который шлёт строки текстом,
  отказывает громко.
- **Целое у `postgres` — `int8`, а не тип столбца.** Индекс сравнение
  берёт, но в выражении целое ведёт себя как целый литерал SQL: деление
  двух целых — целое (`$1::int8 / $2::int8` с 7 и 2 — `3`), а функция
  с аргументом `integer` его не примет — «function repeat(unknown,
  bigint) does not exist». Нужный тип пишет текст поверх знака:
  `$1::int8::int`, `$1::int8::numeric`.
- **Числа внутри JSON — с точностью `json.encode`**: 14 значащих цифр у
  дробных (`0.1 + 0.2` → `0.3`). Целые и `int64` — точно. Точное дробное
  внутри JSON — `decimal`, он уходит строкой.
- **Время — до микросекунд**: наносекунды отбрасываются, у MySQL — ещё
  и пояс, пишется миг в UTC.
- **Род у отказа без кода — по английским словам.** Сервер с `lc_messages`
  не на английском превратит `conflict` и `timeout` в `rejected`; с кодом
  сервера род от языка не зависит.
- **`57014` — всегда `timeout`**, хотя так же отменяет оператор и
  `pg_cancel_backend` руками.
- **Отказ сети HTTP с незнакомыми словами — `broken`**, а не `unreachable`:
  `tnt-http` не говорит, ушёл ли запрос, и без согласия вызывающего такой
  отказ не повторяется. Незнакомый род отказа `tnt-http` — тоже `broken`.
- **Файбер и канал на каждый вызов рока.** Иначе срока нет вовсе; цена —
  порождение файбера на вызов. Рок, который отмену не слышит, дорабатывает
  в работнике, и его итог уходит в `late`.
- **Предел строк сверяется после чтения**: рок читает ответ целиком,
  и память уже потрачена; предел защищает того, кто работает с ответом
  дальше.
- **Соединение, умершее в простое, живость без сети не видит**: его узнаёт
  первый запрос родом `broken`, и повтор такого запроса — только
  с `idempotent = true`.

## Проверки

Проверки лежат в `test/` и идут на luatest: `.rocks/bin/luatest test/`.
Модули пакета берутся из исходников, зависимости — установленными.

Пакет — чистый Lua, и проверяется без базы и без докера: 146 проверок
за пару секунд. Отказ, срок и значения — 67 проверок. Драйвер SQL над
роком — ещё 79 на двойнике знания рока (`test/driver_helper.lua`
и `test/fake_rock.lua`): вход в срок и опоздавший вход, закрытие выходом
работника, живость и сброс без сети, отметка транзакции у рока, который
её не видит, род отказа, форма ответа, повторы по роду, откат и выброс,
отмена вызывающего, транзакция во всех исходах; `transaction_node_test.lua`
— на временном узле: транзакция box видна драйверу. Перечни кодов, слов
и значений в проверках свои, а не взятые из модуля: проверка, читающая
таблицу модуля, согласилась бы с любой её опечаткой. Ожидание работника
идёт настоящими файберами и временем в сотые доли секунды — отмена
и опоздавший итог держатся на ядре; двойник часов — для остатка ровно
ноль и меньше нуля. Каждый бросок сверяется с текстом и со строкой
вызывающего, в том числе с уровнем `2`.

Покрытие строк — 100 % (985 строк), убитых мутантов — 100 %: 1030
мутантов в девяти модулях — `codes.lua` 228, `failure.lua` 83, `exact.lua`
40, `value.lua` 277, `within.lua` 86, `link.lua` 54, `statement.lua` 34,
`transaction.lua` 125, `driver.lua` 103; правил исключения нет. В фасаде
`storage.lua` мутировать нечего: подключения частей и обёртки под своими
именами.
