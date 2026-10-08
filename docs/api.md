# API синхронизации Garage, v1

Контракт между приложением и будущим сервером (Vapor). Реализация DTO — `Packages/GarageAPI`. Блоки ` ```json golden=<name> ` ниже — «золотые» примеры: тесты `GarageAPITests` читают их из этого файла и проверяют, что DTO декодируют и кодируют их без расхождений. **Примеры правятся только здесь.**

## Модель синхронизации

- **Сущности:** `vehicle` и `serviceRecord`. Запчасти встроены в запись массивом `parts` (собственной синхронизации у них нет, запись заменяется целиком). Upsert всегда несёт полное состояние, а не патч.
- **Версии:** у пользователя один монотонный счётчик `Int64`. При каждой записи сущность получает `version` = следующее значение. Удаление — tombstone со своей версией. Отдельного журнала нет: pull = `WHERE version > cursor ORDER BY version`, по одной (последней) строке на сущность.
- **Операция:** `{"op":"upsert","entity":"vehicle","data":{…}}` или `{"op":"delete","entity":"serviceRecord","id":"…"}`. `ServerChange` = `version` + `modifiedAt` + поля операции.

## Эндпоинты

Все, кроме `POST /v1/devices`, требуют `Authorization: Bearer <token>`; это относится и к `GET`/`PUT /v1/receipts/{sha256}`. Только HTTPS (TLS на reverse proxy). Сервер рассчитан на один экземпляр процесса: блокировка счётчика версий и порядок коммитов (см. ниже) не рассчитаны на несколько экземпляров.

### `GET /v1/changes?after=<cursor>&limit=<1…500, по умолчанию 200>`

Ответ `200` — `{changes, cursor, hasMore}`. `cursor` — непрозрачная строка; без `after` — полная выгрузка, включая tombstones. Пустой ответ (`changes: []`) возвращает `cursor` = `after` из запроса (или `"0"`, если `after` не передан).

```json golden=pull-response
{
  "changes": [
    {
      "data": {
        "id": "11111111-1111-4111-8111-111111111111",
        "kind": "car",
        "make": "Toyota",
        "mileageKm": 87400,
        "model": "Land Cruiser",
        "year": 2019
      },
      "entity": "vehicle",
      "modifiedAt": "2026-10-07T09:30:00.000Z",
      "op": "upsert",
      "version": 41
    },
    {
      "data": {
        "date": "2026-10-01T00:00:00.000Z",
        "id": "22222222-2222-4222-8222-222222222222",
        "laborCostKopecks": 350000,
        "mileageKm": 87000,
        "notes": "Заменено масло",
        "parts": [],
        "serviceType": "oilChange",
        "vehicleID": "11111111-1111-4111-8111-111111111111"
      },
      "entity": "serviceRecord",
      "modifiedAt": "2026-10-07T09:31:00.000Z",
      "op": "upsert",
      "version": 42
    },
    {
      "entity": "serviceRecord",
      "id": "33333333-3333-4333-8333-333333333333",
      "modifiedAt": "2026-10-07T09:32:00.000Z",
      "op": "delete",
      "version": 43
    }
  ],
  "cursor": "43",
  "hasMore": false
}
```

### `POST /v1/changes`

Тело `{changes:[PushChange]}` (≤ 100). Ответ `200 {results:[PushResult]}`: один результат на элемент, в том же порядке. Элементы обрабатываются по порядку, каждый в своей транзакции; ошибка одного не блокирует остальные. Порядок важен: техника раньше её записей.

- `changeID` (UUID) — идемпотентность: сервер хранит `lastChangeID` в строке сущности, повтор уже применённого изменения → `applied` с той же версией, а не ложный конфликт.
- Идемпотентность держится на `lastChangeID` строки, поэтому после правки той же сущности с другого устройства повтор потерявшегося ответа может вернуть конфликт. Клиент считает изменение применённым, если `current` совпадает с его собственным содержимым (для создания — `alreadyExists` с тем же `data`).
- Сервер обязан выделять версии и коммитить их последовательно в рамках пользователя (блокировка строки счётчика до коммита), иначе pull может пропустить версию, закоммиченную позже большей.
- Батч > 100 элементов, невалидный `after` или `limit` вне 1…500 → `400 malformedRequest`. Сервер валидирует содержимое DTO ровно правилами домена `GarageCore` (не строже и не мягче) и при ошибке отвечает `rejected/validationFailed`.
- `baseVersion` — версия, на которой основана правка; `null`/отсутствует для создания. Upsert с `baseVersion` по id, которого нет на сервере (и для которого нет tombstone), — создание, не конфликт.
- `modifiedAt` — время правки на устройстве; сервер его только хранит и отдаёт.

```json golden=push-request
{
  "changes": [
    {
      "changeID": "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
      "data": {
        "id": "11111111-1111-4111-8111-111111111111",
        "kind": "car",
        "make": "Toyota",
        "mileageKm": 87400,
        "model": "Land Cruiser",
        "year": 2019
      },
      "entity": "vehicle",
      "modifiedAt": "2026-10-07T09:30:00.000Z",
      "op": "upsert"
    },
    {
      "baseVersion": 42,
      "changeID": "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
      "data": {
        "date": "2026-10-01T00:00:00.000Z",
        "id": "22222222-2222-4222-8222-222222222222",
        "laborCostKopecks": 400000,
        "mileageKm": 87000,
        "notes": "Заменено масло и фильтр",
        "parts": [],
        "serviceType": "oilChange",
        "vehicleID": "11111111-1111-4111-8111-111111111111"
      },
      "entity": "serviceRecord",
      "modifiedAt": "2026-10-07T10:00:00.000Z",
      "op": "upsert"
    },
    {
      "baseVersion": 7,
      "changeID": "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
      "entity": "serviceRecord",
      "id": "33333333-3333-4333-8333-333333333333",
      "modifiedAt": "2026-10-07T10:01:00.000Z",
      "op": "delete"
    },
    {
      "changeID": "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD",
      "data": {
        "date": "2026-10-02T00:00:00.000Z",
        "id": "77777777-7777-4777-8777-777777777777",
        "laborCostKopecks": 120000,
        "mileageKm": 5200,
        "notes": "Замена цепи",
        "parts": [],
        "serviceType": "chain",
        "vehicleID": "99999999-9999-4999-8999-999999999999"
      },
      "entity": "serviceRecord",
      "modifiedAt": "2026-10-07T10:02:00.000Z",
      "op": "upsert"
    }
  ]
}
```

`PushResult.status`:

- `applied` (+`version`);
- `conflict` (+`reason`, +`current` — актуальный `ServerChange`); `reason`: `versionMismatch`, `deleted`, `alreadyExists`. Клиент читает неизвестный `reason` как `ConflictReason.unknown` и разрешает конфликт по `current`, как обычно (LWW; для `deleted` — удаление побеждает), поэтому новые причины — аддитивное изменение;
- `rejected` (+`error`); коды: `validationFailed`, `vehicleNotFound`, `receiptNotFound`.

Конфликт элемента — не HTTP-ошибка, а `200` с результатом по каждому элементу.

```json golden=push-response
{
  "results": [
    {
      "changeID": "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
      "status": "applied",
      "version": 44
    },
    {
      "changeID": "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
      "current": {
        "data": {
          "date": "2026-10-01T00:00:00.000Z",
          "id": "22222222-2222-4222-8222-222222222222",
          "laborCostKopecks": 350000,
          "mileageKm": 87000,
          "notes": "Заменено масло",
          "parts": [],
          "serviceType": "oilChange",
          "vehicleID": "11111111-1111-4111-8111-111111111111"
        },
        "entity": "serviceRecord",
        "modifiedAt": "2026-10-07T09:45:00.000Z",
        "op": "upsert",
        "version": 45
      },
      "reason": "versionMismatch",
      "status": "conflict"
    },
    {
      "changeID": "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
      "status": "applied",
      "version": 46
    },
    {
      "changeID": "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD",
      "error": {
        "code": "vehicleNotFound",
        "message": "Vehicle 99999999-9999-4999-8999-999999999999 does not exist"
      },
      "status": "rejected"
    }
  ]
}
```

## Конфликты

Сервер определяет конфликт по `baseVersion` и **никогда не перезаписывает молча**; решает клиент. Часы устройств могут расходиться, поэтому по `modifiedAt` сервер ничего не решает.

Политика клиента — LWW по записи целиком: побеждает больший `modifiedAt`, при равенстве — серверная версия. Победивший клиент повторяет push с `baseVersion = current.version`. Исключение — `conflict/deleted`: удаление всегда побеждает, клиент отбрасывает свою правку и удаляет запись локально (воскрешения нет; upsert с `baseVersion == nil` на id с tombstone → `conflict/deleted`). Удаление со устаревшим `baseVersion` применяется (`applied`) — это явное намерение; удаление несуществующего id тоже `applied` (сервер записывает tombstone с новой версией). Повторное удаление уже удалённой сущности — `applied` с версией существующего tombstone, новая версия не выделяется. Слияние по полям не используется: клиенту пришлось бы хранить базовые копии, а для одного пользователя конфликт — редкость.

**Алгоритм клиента:** push очереди → pull до `hasMore == false` → сохранить cursor. Свои изменения, вернувшиеся в pull, клиент узнаёт по совпадающей версии.

## Удаления

- Tombstones хранятся бессрочно. `410 cursorExpired` зарезервирован на случай будущей компактации: клиент тогда выполняет полную синхронизацию.
- Удаление побеждает правку (`conflict/deleted`). Повторное удаление идемпотентно: `applied` с версией tombstone, без новой версии.
- Удаление техники каскадно создаёт на сервере tombstones её записей; клиент отправляет только удаление техники. Tombstone от каскада побеждает последующий upsert этой записи: `conflict/deleted`.
- Запись с неизвестной или удалённой техникой → `rejected/vehicleNotFound`, клиент удаляет её локально.

## Сущности

```json golden=vehicle
{
  "id": "11111111-1111-4111-8111-111111111111",
  "kind": "motorcycle",
  "make": "Honda",
  "mileageKm": 18250,
  "model": "CB500X",
  "year": 2021
}
```

`kind` — `car|motorcycle|bicycle`. Деньги — целые копейки. `serviceType` — строка формата `ServiceType.storageString` (`"other:<текст>"` для произвольного).

Запись с запчастями и чеком:

```json golden=service-record
{
  "date": "2026-10-01T00:00:00.000Z",
  "id": "22222222-2222-4222-8222-222222222222",
  "laborCostKopecks": 350000,
  "mileageKm": 87000,
  "notes": "Заменены колодки",
  "parts": [
    {
      "id": "44444444-4444-4444-8444-444444444444",
      "name": "Колодки передние",
      "partNumber": "04465-60320",
      "unitPriceKopecks": 520000,
      "quantity": 1
    },
    {
      "id": "55555555-5555-4555-8555-555555555555",
      "name": "Болт",
      "unitPriceKopecks": 15000,
      "quantity": 4
    }
  ],
  "receipt": {
    "byteCount": 183204,
    "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  },
  "serviceType": "brakes",
  "vehicleID": "11111111-1111-4111-8111-111111111111"
}
```

`nil` не пишется (ключ отсутствует); при чтении `null` и отсутствие ключа равнозначны.

## Фото чека

Отдельно от JSON, без base64, с адресацией по содержимому:

- `PUT /v1/receipts/{sha256}` — тело сырой `image/jpeg`, ≤ 5 МиБ. `201` новое, `200` уже есть; `422 hashMismatch`; `413 payloadTooLarge`; `415 unsupportedMediaType`.
- `GET /v1/receipts/{sha256}` — `ETag` = хеш, кешируется навсегда.
- В записи — `receipt: {"sha256","byteCount"}` или поле отсутствует. Смена или удаление фото — обычная правка записи, поэтому действует та же логика конфликтов.
- Порядок: сначала blob, потом запись. Ссылка на отсутствующий blob → `rejected/receiptNotFound`. Повтор PUT безопасен.

## Аутентификация

`POST /v1/devices` без токена: `{setupSecret, deviceName}` → `201 {deviceID, token}`. Токен — 32 случайных байта в base64url; сервер хранит только его SHA-256, секрет задаётся через env. Клиент хранит токен в Keychain. Устройство отзывается удалением строки на сервере (эндпоинта нет).

```json golden=register-device-request
{
  "deviceName": "iPhone Андрея",
  "setupSecret": "correct-horse-battery-staple"
}
```

```json golden=register-device-response
{
  "deviceID": "66666666-6666-4666-8666-666666666666",
  "token": "q83vEjRZk1T7mP0cX2wYb9LdAaNfU5hGsKiOtVeJr4I"
}
```

## Ошибки

Тело: `{"error":{"code","message","details"?}}`.

| HTTP | code |
|---|---|
| 400 | `malformedRequest` |
| 401 | `unauthorized`, `invalidSetupSecret` |
| 404 | `notFound` |
| 410 | `cursorExpired` (резерв) |
| 413 | `payloadTooLarge` |
| 415 | `unsupportedMediaType` |
| 422 | `hashMismatch` |
| 426 | `upgradeRequired` |
| 500 | `internal` |

```json golden=error-response
{
  "error": {
    "code": "malformedRequest",
    "details": {
      "field": "limit"
    },
    "message": "limit must be between 1 and 500"
  }
}
```

## JSON-соглашения

- Ключи в camelCase (`vehicleID`), без key strategy.
- Даты — ISO 8601 UTC с миллисекундами (`2026-10-07T09:30:00.000Z`); декодер принимает и вариант без дробной части.
- Время (`modifiedAt`, `date`) клиент округляет до миллисекунд при записи правки: так значение не меняется после обмена с сервером. Кодировщик `APICoding` тоже округляет до ближайшей миллисекунды (не отбрасывает остаток). Смещения кроме `Z` не используются.
- `sha256` — 64 символа hex в нижнем регистре (в пути, `ETag` и `receipt`).
- UUID — каноническая строка в верхнем регистре (так пишет `JSONEncoder`); читатели принимают любой регистр.
- Вывод детерминирован (`.sortedKeys`).
- Общая настройка — `APICoding.makeEncoder()` / `makeDecoder()`.

## Версионирование

- Префикс `/v1` в URL.
- Что допустимо в v1 и как клиент читает незнакомое — в разделе «Правила эволюции контракта» ниже.
- Ломающие изменения (переименование или смена типа поля, новое обязательное поле, смена смысла значения) → `/v2`; сервер какое-то время обслуживает обе версии, снятую отвечает `426 upgradeRequired`.
- **`serviceType` — терпимый читатель:** DTO передаёт строку; при маппинге в домен клиент читает неизвестное значение как `.other(<строка>)` и хранит исходную строку; при push отправляет её без изменений (не `"other:<строка>"`).

## Правила эволюции контракта

1. **В v1 — только добавляющие изменения:** новые необязательные поля, новые значения перечислений (`entity`, `op`, `status` push, `kind` машины, `serviceType`, `period`), новые виды сущностей, новые коды ошибок и причины конфликтов, новые эндпоинты. Переименование, смена типа, новое обязательное поле, смена смысла значения — `/v2`.
2. **Клиент — терпимый читатель.** Незнакомое не валит ответ целиком:

   | Что незнакомо | Что делает клиент |
   |---|---|
   | `entity` или `op` в элементе `changes` ответа pull | элемент пропускается, имя (`entity:<вид>` / `op:<значение>`) — в `PullResponse.skipped` и в лог; курсор идёт дальше |
   | `status` в результате push, а также `conflict`, чей `current` имеет незнакомые `entity`/`op` | `PushOutcome.unrecognized`: изменение **остаётся в очереди** (правка пользователя не теряется, повтор идемпотентен по `changeID`), исход попадает в отчёт и лог при каждом прогоне; остальные результаты батча обрабатываются |
   | `reason` конфликта | `ConflictReason.unknown`, конфликт разрешается по `current` (LWW) |
   | `code` ошибки (тело ошибки HTTP, `rejected`) | `APIErrorCode.unknown`; `rejected` с таким кодом — общая ветка: изменение снимается с очереди, локальные данные остаются |
   | `serviceType` записи | `.other(<строка>)`, исходная строка уходит обратно без изменений |
   | `kind` машины | сырое значение сохраняется и уходит обратно без изменений, пока вид не выбран явно; в домене показывается как автомобиль |
   | `period` правила | сырое значение сохраняется; если не остаётся ни одного известного интервала, правило пропускается |
   | неизвестный ключ в любом объекте | игнорируется |

   Не «эволюция», а нарушение формата, и должно падать громко: даты не в ISO 8601, невалидный UUID, отсутствие обязательного ключа у **известного** вида, известный вид с битым `data`.
3. **Выкатка: сервер раньше клиентов.** Сервер строг к тому, что принимает: незнакомые `entity`/`op` во входящем `POST /v1/changes` — `400 malformedRequest`, невалидное содержимое — `rejected/validationFailed`.
4. **Когда расти `GarageStore.schemaVersion`:** клиент начал понимать то, что раньше пропускал или хранил сырым (новый вид сущности, новое значение перечисления, новое поле, которое теперь хранится локально), и при любом изменении локальной модели. Рост сбрасывает курсор и запомненные версии, поэтому следующая синхронизация скачивает всё и получает пропущенное. Очередь неотправленных изменений при этом сохраняется.
5. **Тест-растяжка:** снимок известных клиенту видов сущностей привязан к `schemaVersion`; новый вид без роста версии роняет тест с подсказкой, что делать.

Для пропуска круговой проход (декодировать → закодировать) невозможен, поэтому у таких примеров тесты только декодируют и сравнивают с ожидаемым значением из теста; JSON берётся отсюда.

Pull с незнакомым видом сущности — `PullResponse.skipped == ["entity:futureEntity"]`, остальные изменения на месте:

```json golden=pull-response-unknown-entity
{
  "changes": [
    {
      "data": {
        "id": "11111111-1111-4111-8111-111111111111",
        "kind": "car",
        "make": "Toyota",
        "mileageKm": 87400,
        "model": "Land Cruiser",
        "year": 2019
      },
      "entity": "vehicle",
      "modifiedAt": "2026-10-07T09:30:00.000Z",
      "op": "upsert",
      "version": 41
    },
    {
      "data": {
        "note": "содержимое незнакомого вида не разбирается"
      },
      "entity": "futureEntity",
      "modifiedAt": "2026-10-07T09:31:00.000Z",
      "op": "upsert",
      "version": 42
    },
    {
      "entity": "serviceRecord",
      "id": "33333333-3333-4333-8333-333333333333",
      "modifiedAt": "2026-10-07T09:32:00.000Z",
      "op": "delete",
      "version": 43
    }
  ],
  "cursor": "43",
  "hasMore": false
}
```

Pull с незнакомой операцией — `PullResponse.skipped == ["op:patch"]`:

```json golden=pull-response-unknown-op
{
  "changes": [
    {
      "data": {
        "id": "11111111-1111-4111-8111-111111111111",
        "kind": "car",
        "make": "Toyota",
        "mileageKm": 87400,
        "model": "Land Cruiser",
        "year": 2019
      },
      "entity": "vehicle",
      "modifiedAt": "2026-10-07T09:30:00.000Z",
      "op": "upsert",
      "version": 41
    },
    {
      "entity": "vehicle",
      "modifiedAt": "2026-10-07T09:31:00.000Z",
      "op": "patch",
      "version": 42
    },
    {
      "entity": "serviceRecord",
      "id": "33333333-3333-4333-8333-333333333333",
      "modifiedAt": "2026-10-07T09:32:00.000Z",
      "op": "delete",
      "version": 43
    }
  ],
  "cursor": "43",
  "hasMore": false
}
```

Push с незнакомым `status` (второй элемент) и `conflict`, чей `current` имеет незнакомый вид (третий): оба — `PushOutcome.unrecognized`, изменения остаются в очереди, первый и четвёртый результаты обрабатываются как обычно:

```json golden=push-response-unknown-status
{
  "results": [
    {
      "changeID": "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
      "status": "applied",
      "version": 44
    },
    {
      "changeID": "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
      "status": "postponed"
    },
    {
      "changeID": "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
      "current": {
        "data": {
          "note": "содержимое незнакомого вида не разбирается"
        },
        "entity": "futureEntity",
        "modifiedAt": "2026-10-07T09:45:00.000Z",
        "op": "upsert",
        "version": 45
      },
      "reason": "versionMismatch",
      "status": "conflict"
    },
    {
      "changeID": "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD",
      "status": "applied",
      "version": 46
    }
  ]
}
```

Конфликт с незнакомой причиной — `ConflictReason.unknown("locked")`, разрешается по `current`:

```json golden=push-response-unknown-conflict-reason
{
  "results": [
    {
      "changeID": "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
      "current": {
        "data": {
          "date": "2026-10-01T00:00:00.000Z",
          "id": "22222222-2222-4222-8222-222222222222",
          "laborCostKopecks": 350000,
          "mileageKm": 87000,
          "notes": "Заменено масло",
          "parts": [],
          "serviceType": "oilChange",
          "vehicleID": "11111111-1111-4111-8111-111111111111"
        },
        "entity": "serviceRecord",
        "modifiedAt": "2026-10-07T09:45:00.000Z",
        "op": "upsert",
        "version": 45
      },
      "reason": "locked",
      "status": "conflict"
    }
  ]
}
```

Отказ с незнакомым кодом — `APIErrorCode.unknown("teapot")`, общая ветка `rejected`:

```json golden=push-response-unknown-error-code
{
  "results": [
    {
      "changeID": "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD",
      "error": {
        "code": "teapot",
        "message": "I am a teapot"
      },
      "status": "rejected"
    }
  ]
}
```

Запись с незнакомым типом работ — в домене `.other("coolant")`, при push строка уходит без изменений:

```json golden=service-record-unknown-service-type
{
  "date": "2026-10-01T00:00:00.000Z",
  "id": "22222222-2222-4222-8222-222222222222",
  "laborCostKopecks": 0,
  "mileageKm": 87000,
  "notes": "",
  "parts": [],
  "serviceType": "coolant",
  "vehicleID": "11111111-1111-4111-8111-111111111111"
}
```

Машина с незнакомым видом — DTO несёт строку как есть; сырое значение в домене и в форме правки — решение этапа 12 (T7), реализация в части B:

```json golden=vehicle-unknown-kind
{
  "id": "11111111-1111-4111-8111-111111111111",
  "kind": "tractor",
  "make": "Fendt",
  "mileageKm": 1200,
  "model": "Vario",
  "year": 2020
}
```

## Открытые вопросы

- Сборка мусора для blob-ов чеков без ссылок.
- Компактация tombstones (и тогда — поведение `cursorExpired`).
- Многопользовательский режим.
- Upsert передаёт полное состояние, поэтому старый клиент стирает новые необязательные поля, о которых не знает. Для v1 допустимо (один пользователь); решение — сохранять неизвестные поля или вводить патчи в v2.
