# Этап 10: техника — добавление, правка, удаление

## Контекст

Технику сейчас нельзя ни добавить, ни изменить, ни удалить из приложения. Есть только демо-машины из
`SampleSeeder` и `VehicleLog.add` (его вызывают только тесты). Образец — этап 9
(`docs/plans/stage-9-edit-delete-records.md`, раздел «Шаблон: правка и удаление» в `docs/architecture.md`).
Его решения повторяются; отличия перечислены явно и обоснованы.

Доменная модель `Vehicle` (GarageCore): `id`, `kind: VehicleKind` (`car` / `motorcycle` / `bicycle`),
`make`, `model`, `year: Int`, `mileageKm` (`private(set)`, инвариант `≥ 0` в throwing init и
`updateMileage`). **Отдельного поля «название» нет**: в списке показывается `displayName = "\(make) \(model)"`.
Новое поле изменило бы контракт `VehicleDTO` (`docs/api.md`), сервер и схему SwiftData, поэтому в этот
этап оно не входит. Форма содержит: тип, марку, модель, год и пробег.

Синхронизация удаления техники уже есть на сервере (этап 6b, `Server/Sources/App/ChangeWriter.swift`).
Контракт (`docs/api.md`, «Удаления») гласит: «Удаление техники каскадно создаёт на сервере tombstones её
записей; клиент отправляет только удаление техники». Клиент пока технику не удаляет, поэтому основная работа
этапа — правильно встроить такое удаление в очередь и в применение изменений с сервера. Подробно это
разобрано в разделе «Каскадное удаление».

Работа делится на две части:

- **A** — Linux-пакеты: `Packages/GarageCore` (домен, порт, use case'ы), тесты `Packages/GarageSync` и
  `Server`. Можно делать в облачной сессии, отдельным PR.
- **B** — GarageStorage, ViewModel, вью, строки, ui-checker. Делается локально после мержа A.

## Решения

1. **Порт — один новый протокол `VehicleRepository` (`add`, `update`, `delete`).** На этапе 9 порт
   правки вынесли в отдельный протокол, чтобы PR A не сломал существующие адаптер и фейки, которые
   правятся только в B. Сейчас порта техники нет совсем, ломать нечего, так что одного протокола
   достаточно. Ошибки повторяют этап 9: правка отсутствующей машины даёт
   `RepositoryError.vehicleNotFound` (уже есть), удаление отсутствующей считается успехом
   (идемпотентно).
2. **Добавление и правка — use case'ы `AddVehicle` и `UpdateVehicle`.** Правило есть: черновик
   `VehicleDraft` проверяется (`makeVehicle`). В правке сохраняется `id`. Если ничего не изменилось,
   порт не вызывается и лишний upsert в синхронизацию не уходит.
3. **Удаление — без use case.** Правил на уровне домена нет, подтверждение — это UI, каскад делают
   хранилище и сервер. ViewModel вызывает `VehicleRepository.delete(id:)` напрямую.
4. **Правила формы живут в `VehicleDraft`, домен `Vehicle` не меняется.** Требования: непустые
   марка и модель после `trimmingCharacters(.whitespaces)`, год — целое число в диапазоне
   `1900...currentYear + 1`, пробег разбирается как в `ServiceRecordDraft.parseMileage`. Если добавить
   проверку года или пустой марки в `Vehicle.init`, изменятся валидация на сервере (она «ровно по
   GarageCore»), декодирование уже синхронизированных данных и контракт. Это отдельное решение, и в этот
   этап оно не входит. `currentYear` передаётся параметром, чтобы тесты были детерминированными.
5. **Пробег в форме — ручное значение `Vehicle.mileageKm`.** Действует правило «derived state»:
   `currentMileageKm(records:)` остаётся вычисляемым, форма его не записывает. В режиме правки под полем
   показывается подсказка «По записям: N км», если записи дают больше. Если поставить ручное значение
   ниже, чем по записям, итог не изменится, и это не ошибка.
6. **Удаление машины ставит в очередь только `delete(vehicle)`**, а pending-upsert'ы её записей
   убираются из очереди в том же сохранении. Подробности — в разделе «Каскадное удаление», пункты 1–2.
7. **Модель SwiftData не меняется** (`VehicleEntity.serviceRecords` уже `deleteRule: .cascade`), поэтому
   `GarageStore.schemaVersion` не растёт.
8. **Где удаляют:** свайп в списке (`VehicleListViewModel`) и кнопка на экране машины
   (`VehicleDetailViewModel.deleteVehicle`). Форма правки кнопку удаления не получает: на этапе 9 она
   была в форме записи, потому что у записи нет своего экрана, а у машины есть. Свайп — без
   `role: .destructive` (урок этапа 9: иначе List уберёт строку до подтверждения).

---

## Каскадное удаление

Как устроен каскад на сервере (`ChangeWriter.delete`). Удаление vehicle — одна транзакция. Строка
машины становится tombstone со своей версией. Затем выбираются **все живые строки** `kind = serviceRecord
AND vehicle_id = id AND deleted = false`, на момент коммита и независимо от того, какое устройство их
создало. Каждая получает tombstone со своей новой версией, `modifiedAt` удаления и тем же `changeID`.
Pull отдаёт их как обычные `delete`. Upsert записи поверх tombstone даёт `conflict/deleted`. Upsert
**новой** записи (строки нет) к удалённой машине даёт `rejected/vehicleNotFound`. Delete никогда не
отклоняется и не конфликтует: несуществующий id получает tombstone, повторное удаление возвращает версию
существующего tombstone.

### 1. Что ставить в очередь: только delete машины

Клиент ставит **только** `delete(.vehicle, id)`. Delete каждой записи не ставится.

- **Полнота.** Клиент знает только записи, которые есть у него локально. Запись, которую другое
  устройство добавило, а это ещё не скачало, клиент перечислить не может. Сервер в каскаде берёт **свою**
  таблицу на момент коммита, поэтому полноту даёт только он. Поштучные delete с клиента ничего к ней не
  добавляют.
- **Атомарность.** Каскад идёт в одной транзакции с tombstone машины. Не бывает состояния «машины нет,
  а часть записей жива», которое увидел бы pull другого устройства. Поштучные delete шли бы отдельными
  транзакциями, возможно в разных батчах (`maxPushBatch = 100`) и в разных sync.
- **Цена.** N лишних элементов push и N лишних версий, если delete записей оказались в очереди раньше
  машины. Если позже — N холостых `applied`.
- **Контракт** прямо требует этого: «клиент отправляет только удаление техники».

Delete машины ставится **всегда**, даже без `SyncVersionEntity` — тот же довод, что у `ServiceLog.delete`
на этапе 9. Push может быть в полёте, версии стираются при смене схемы и в «Забыть устройство». Если
машины на сервере нет, лишний delete стоит одного tombstone. Если pending-upsert машины ещё не
отправлен, он схлопывается в delete (`SyncQueue.enqueue` заменяет операцию, сохраняя `baseVersion` и
место в очереди).

Локально `context.delete(vehicleEntity)` удаляет записи и части каскадом SwiftData
(`VehicleEntity.serviceRecords`, `.cascade`).

**Тесты:**
- A, `Server/Tests/AppTests/ChangesTests.swift`: `cascadeCoversRecordsTheDeletingDeviceNeverSaw`.
  Клиент 1 пушит V. Клиент 2 пушит R1 и R2 к V. Клиент 1, ни разу не делавший pull, пушит только
  `delete(V)`. Pull содержит tombstones R1 и R2 с отдельными версиями. Последующий upsert R1 от клиента 2
  с его `baseVersion` даёт `conflict/deleted`.
- B, `VehicleLogTests.swift`: `deleteQueuesOnlyVehicleDelete`. У машины 3 записи, все синхронизированы
  (есть `SyncVersionEntity`). После `VehicleLog.delete` в очереди ровно один pending —
  `delete(.vehicle, V)` с `baseVersion` из версии. Записей и частей в базе нет.
- B, `VehicleLogTests.swift`: `deleteWithoutVersionStillQueuesDelete` (нет `SyncVersionEntity`) и
  `deleteOfUnsentVehicleCollapsesIntoDelete` (pending-upsert создания → один delete на той же
  `sequence`).
- B, `SyncEndToEndTests.swift`: `vehicleDeleteCascadesToAnotherDevice`. Устройство A добавило V с двумя
  записями и синхронизировалось. Устройство B синхронизировалось. A удалило V и синхронизировалось. На
  сервере (`FakeSyncServer`) одна push-операция; у B после sync нет ни V, ни записей.

### 2. Что делать с уже стоящими в очереди изменениями записей этой машины

В одном сохранении с удалением машины:

- **pending-upsert записей машины удаляются из очереди.** Если их оставить, push сломается двумя
  способами. Новая запись (сервер её не знает), отправленная после `delete(V)`, получит
  `rejected/vehicleNotFound`: попадёт в `report.rejected`, а движок «удалит» уже удалённую запись.
  Известная серверу запись получит `conflict/deleted`. Кроме того, `uploadReceipts` попробует загрузить
  чек записи, которой уже нет: `receiptData(sha256:)` вернёт `nil`, и upsert со ссылкой на blob, которого
  нет на сервере, получит `rejected/receiptNotFound`. Терять upsert'ы не страшно: все записи машины на
  сервере каскад удалит в любом случае (п. 1).
- **pending-delete записей остаются.** Delete никогда не даёт `vehicleNotFound`. Если он стоит в очереди
  раньше `delete(V)` (так и есть: `sequence` меньше), он ставит tombstone, а каскад эту запись
  пропускает (`deleted = false`). Найти такие delete по машине нельзя: у локальной сущности их больше
  нет, а в `delete(.serviceRecord, id)` нет `vehicleID`. Добавлять туда `vehicleID` ради удаления
  безвредных элементов очереди не стоит.

Записи с pending-upsert находятся по связи `vehicleEntity.serviceRecords` **до** `context.delete`:
pending-upsert без локальной сущности невозможен, потому что локальное удаление записи схлопывает его в
delete. Новый хелпер — `SyncQueue.dropPendingUpserts(ofRecordsOf: VehicleEntity, in:)`.

**Тот же хелпер нужен в `SwiftDataSyncStore.apply` для `.delete(.vehicle)`**, то есть при удалении
машины с сервера: pull tombstone'а, `conflict/deleted` на upsert машины. Без него запись, добавленная
локально к машине, которую удалили на другом устройстве, удаляется каскадом SwiftData, а её pending-upsert
остаётся в очереди и на следующем sync получает `vehicleNotFound`. Это меняет контракт `SyncStore.apply`.
Doc-комментарий протокола дополняется: «удаление машины удаляет её записи и pending-изменения их
upsert'ов». `InMemorySyncStore` в тестах GarageSync приводится к тому же поведению. Код `SyncEngine`
не меняется.

In-flight. Батч уже прочитан и отправлен, в нём upsert R. Пользователь удаляет V, и R уходит из очереди.
Ответ `applied` для R ничего не найдёт по `changeID`, `markApplied` тихо выйдет. Следующий sync отправит
`delete(V)`, и каскад удалит R на сервере. Ответ `conflict` для R применится через `apply`, но машины
локально нет: `SyncStoreError(missingVehicle)` попадёт в `skipped`, `discard` выполнится без эффекта.
В обоих случаях падения нет.

**Тесты:**
- A, `Server/.../ChangesTests.swift`: `queueOrderAroundVehicleDelete`. В одном батче
  `[upsert R(new), delete V]` оба `applied`, R в pull приходит tombstone'ом. В батче
  `[delete V, upsert R(new)]` R получает `rejected/vehicleNotFound` — тест фиксирует, почему upsert'ы
  нужно убирать. В батче `[delete R, delete V]` оба `applied`, у R одна версия, каскад её не трогает —
  поэтому delete оставлять безопасно.
- A, `GarageSyncTests/SyncEngineTests.swift`: `vehicleDeleteWithKeptRecordDeletesPushesCleanly`. В
  очереди `[delete R, delete V]`, сервер (`FakeHTTPTransport`) отвечает `applied` на оба. Pull приносит
  tombstones. В `report.rejected` пусто, очередь пуста, sync не бросает.
- A, `SyncEngineTests.swift`: `remoteVehicleDeleteDropsPendingRecordUpserts` (контракт `apply` на
  `InMemorySyncStore`). V и R3 синхронизированы, очередь пуста. Во время pull (после push) добавлена
  новая R к V и удалена R3. Pull приносит tombstone V → R удалена, pending R нет, в очереди только
  `delete R3`, следующий push несёт только его. Отклонение от исходного сценария («R в очереди до sync»):
  движок всегда делает push перед pull, и push сам снял бы upsert R (`markApplied` или `rejected` →
  `apply(.delete(R))`), так что tombstone нечего было бы снимать.
- A, `GarageSyncTests/ReceiptTests.swift`: `vehicleTombstoneDropsRecordUpsertHeldByReceiptFailure`.
  Upsert R с чеком стоит в очереди до sync, загрузка чека отклонена (`payloadTooLarge`), push его
  придерживает. Pull приносит tombstone V → очередь пуста, R и V удалены. Единственный случай, когда
  upsert, стоявший до sync, доживает до tombstone; тест падает без снятия upsert'а в каскаде `apply`.
- B, `VehicleLogTests.swift`: `deleteDropsPendingRecordUpsertsKeepsDeletes`. У V запись R1 с
  pending-upsert (правка) и R2 с pending-upsert (создание). R3 удалена ранее (pending-delete). После
  `VehicleLog.delete(V)` в очереди `[delete R3, delete V]` в порядке `sequence`.
- B, `SwiftDataSyncStoreTests.swift`: `applyingVehicleTombstoneDropsRecordUpserts` — то же самое через
  `apply(RemoteChange(.delete(V)))`.
- B, `SyncEndToEndTests.swift`: `deletingVehicleWithUnsyncedRecordPushesWithoutRejections`. V
  синхронизирована. Добавлена новая R с чеком, без sync удалена V. Sync: `report.rejected` пуст
  (`SyncSummary` без ошибок), чек R на сервер не загружался (счётчик `PUT /v1/receipts` в
  `FakeSyncServer` равен 0), на сервере нет живой R.
- B, `SyncEndToEndTests.swift`: `vehicleDeletedWhilePushIsInFlight` — по образцу
  `recordDeletedWhilePushIsInFlightIsNotResurrected`. Push с upsert R задерживается гейтом. Удаляется V.
  Ответ приходит, следующий sync отправляет `delete(V)`. На сервере R — tombstone, локально ничего не
  воскресло.

### 3. Гонка устройств: B добавил запись к машине, которую A уже удалил

A удалил V и синхронизировался: на сервере tombstones V и её записей. B, не зная об этом, добавил новую
запись R к V и запускает sync. Push идёт первым (`SyncEngine.run`: push → pull):

1. `upsert R` (`baseVersion = nil`) → на сервере строки R нет, у V tombstone → `rejected/vehicleNotFound`.
2. `SyncEngine.resolve`: запись, upsert, машина не была отклонена в этом прогоне →
   `store.apply(RemoteChange(version: nil, .delete(R)))`. R удаляется локально (вместе с частями и
   чеком), pending R уходит, версия не запоминается. Ошибка попадает в `report.rejected`, sync не падает.
3. Pull приносит tombstone V и каскадные tombstones её записей. `apply(.delete(V))` удаляет V локально,
   остальные записи уходят каскадом, pending-upsert'ы записей V удаляет хелпер из п. 2.

**Итог на B:** нет ни V, ни R. Локальная запись **потеряна** — так работает правило «удаление
побеждает» (`docs/api.md`, «Конфликты»). Восстановить её некуда: машины нет. Чек R, если был, уже
загружен на сервер на шаге `uploadReceipts` и остался там без ссылок (п. 5).

Варианты:
- B **правил** известную серверу запись R → `conflict/deleted` с tombstone в `current` → `serverWins` →
  `apply(.delete(R), version)`. Tombstone запомнен, старый upsert R его не воскресит.
- B **правил саму V** → `conflict/deleted` → `apply(.delete(V))` → каскад SwiftData и хелпер п. 2. Если
  в том же батче после V шли upsert'ы новых записей V, они уже на сервере и получают
  `vehicleNotFound` (п. 1 выше). Локально их уже нет — no-op.
- Push R ушёл, пока A ещё не синхронизировался: R создана на сервере под живой V. Затем `delete(V)` от A
  удаляет её каскадом (п. 1, полнота), B получает tombstone R при pull.

Сообщение пользователю B в этом этапе не показывается. `SyncSummary` сейчас не содержит `rejected`, и
расширять его ради одного случая значит менять `SyncService`. Это записано в «Рисках».

**Тесты:**
- A, `Server/.../ChangesTests.swift`: `secondDeviceEditsAfterVehicleDelete`. Клиенты 1 и 2 видят V и R1.
  Клиент 1 пушит `delete(V)`. Клиент 2 пушит `upsert R2(new)` → `rejected/vehicleNotFound`;
  `upsert R1(base)` → `conflict/deleted`, у `current` tombstone; `upsert V(base)` → `conflict/deleted`.
- A, `SyncEngineTests.swift`: `newRecordForRemotelyDeletedVehicleIsDroppedLocally`. Сценарий на
  `InMemorySyncStore` + `FakeHTTPTransport`: push отвечает `rejected/vehicleNotFound`, pull отдаёт
  `delete V` и `delete R1`. Проверки: R2 и V удалены, у R1 запомнена версия tombstone, очередь пуста, в
  `report.rejected` один элемент `vehicleNotFound`, `run` не бросает.
- A, `SyncEngineTests.swift`: `editOfRemotelyDeletedVehicleDeletesItLocally` — `conflict/deleted` на
  upsert V, затем `rejected/vehicleNotFound` на upsert новой записи из того же батча. V и запись удалены
  локально, очередь пуста.
- B, `SyncEndToEndTests.swift`: `recordAddedToVehicleDeletedOnAnotherDevice`. Два устройства на одном
  `FakeSyncServer` (с каскадом, см. B1). Сценарий полностью, итог: у B нет V и R, `pendingChangeCount == 0`,
  повторный sync ничего не пушит.

### 4. Демо-машины с фиксированными UUID

`SampleSeeder.seedIfNeeded` ставит 4 машины с `Vehicle.SampleID` **один раз на установку**: флаг
`GarageStorage.didSeedSamples` в `UserDefaults` выставляется после успешного сохранения. Поэтому:

- **Та же установка.** После удаления демо-машины сид не срабатывает: флаг уже стоит. Сид не вызывают ни
  `SyncSupport.resetIfSchemaChanged` (bump `schemaVersion`), ни `resetSyncState` («Забыть устройство»).
  `bootstrapIfNeeded` ставит в очередь только то, что есть локально, а удалённой машины нет.
- **Новая установка или новое устройство с тем же сервером.** Сид создаёт 4 машины с теми же UUID,
  bootstrap ставит `upsert` с `baseVersion = nil`. На сервере у удалённой демо-машины tombstone, push
  получает `conflict/deleted`. Удаление побеждает: машина удаляется локально и не воскресает на сервере
  (контракт: «upsert с `baseVersion == nil` на id с tombstone → `conflict/deleted`»). Фиксированные UUID
  здесь помогают: со случайными id удалённые демо-машины возвращались бы на каждом новом устройстве.
- **Без сервера** (устройство не зарегистрировано). После переустановки демо-машины вернутся: это новая
  локальная база, удаления помнить негде. Поведение ожидаемое.
- Пользователь на новом устройстве до первого sync успел добавить запись к демо-машине, удалённой
  на другом устройстве. Запись потеряется так же, как в п. 3. Это записано в «Рисках».

**Тесты:**
- A, `Server/.../ChangesTests.swift`: `sampleVehicleCannotBeRecreatedAfterDelete`. Upsert
  `Vehicle.samples[0]` → delete → upsert того же `id` с `baseVersion = nil` → `conflict/deleted`.
  Сервер зависит от GarageCore, `Vehicle.samples` доступен.
- A, `SyncEngineTests.swift`: `seededVehicleOverTombstoneIsDeletedLocally`. Pending-upsert создания
  `Vehicle.samples[0]` (без версии), сервер отвечает `conflict/deleted` с tombstone → машина удалена
  локально, версия tombstone запомнена, очередь пуста.
- B, `SampleSeederTests.swift`: `seedingDoesNotRecreateDeletedSampleVehicle`. Сид, затем
  `VehicleLog.delete(landCruiser)`, затем `seedIfNeeded`, `SyncSupport.prepare` и `resetSyncState` → 3
  машины, landCruiser нет, в очереди нет его upsert.
- B, `SyncEndToEndTests.swift`: `deletedSampleVehicleStaysDeletedOnNewDevice`. Устройство A (свои
  `UserDefaults`) сидит, синхронизируется, удаляет landCruiser, синхронизируется. Устройство B (новые
  `UserDefaults`, новый контейнер) сидит 4 машины → sync → 3 машины, landCruiser нет, на сервере его
  tombstone не перезаписан (версия та же).

### 5. Файлы чеков удалённых записей

- **Локально** чек — `ServiceRecordEntity.receiptImage` с `@Attribute(.externalStorage)`. Он удаляется
  вместе с сущностью: `context.delete(vehicle)` → каскад на записи → SwiftData/Core Data убирает внешний
  файл при сохранении. Удалённая с сервера машина (`apply(.delete(V))`) и каскадные tombstones записей
  идут тем же путём. Своего кода удаления файлов нет и не нужно. Важно, что **нигде нет второй копии
  байтов**: `ReceiptBlobStore` читает байты из сущностей (`receiptData(sha256:)`).
- **Загрузка на сервер** не происходит: pending-upsert'ы записей сняты (п. 2), а `uploadReceipts`
  смотрит только на очередь.
- **Скачивание.** `missingReceipts()` строится из живых сущностей с `receiptNeedsDownload`, поэтому
  удалённые записи из него пропадают. Если скачивание было в полёте, `storeReceipt` не найдёт сущность
  с этим `sha256 && receiptNeedsDownload` и ничего не сохранит: байты отбрасываются.
- **Один и тот же чек у двух записей** (одинаковый sha256). Каждая сущность хранит свою копию, поэтому
  удаление одной не трогает другую.
- **На сервере** blob'ы адресуются по содержимому и могут принадлежать нескольким записям, в том числе
  записям других машин. Каскад их не удаляет. Сборка мусора для blob'ов без ссылок вынесена из скоупа
  (`docs/api.md`, «Вне скоупа»), и этот этап её не добавляет. Осиротевшие blob'ы — известная цена,
  см. «Риски».

**Тесты:**
- A, `Server/.../AuthAndReceiptsTests.swift`: `receiptBlobOutlivesCascadedRecord`. PUT blob, upsert V и
  R со ссылкой, `delete(V)` → `GET /v1/receipts/<sha>` по-прежнему `200` (фиксирует «нет GC»).
- B, `VehicleLogTests.swift`: `deleteRemovesReceiptBytes`. Две записи V с чеками (у одной sha256 совпадает с
  записью другой машины W). После `VehicleLog.delete(V)`: `SwiftDataSyncStore.receiptData(sha256:)`
  для чека, который был только у V, равен `nil`; для общего — байты записи W. Удаление чеков
  проверяется только через `receiptData(sha256:)`; файлы внешнего хранилища SwiftData тесты не трогают.
- B, `SyncEndToEndTests.swift`: `pendingReceiptDownloadIsDroppedWithVehicle`. Устройство B получило R с
  чеком (`receiptNeedsDownload`), скачивание в `FakeSyncServer` заблокировано гейтом. Pull tombstone'а V
  → `missingReceipts()` пуст. Гейт открыт → `storeReceipt` ничего не пишет, ошибки нет.

---

## Часть A — Linux-пакеты (облачная сессия, отдельный PR)

Затрагивает только `Packages/GarageCore/**`, тесты `Packages/GarageSync/Tests/**` с doc-комментарием
`SyncStore.apply`, `Server/Tests/**` и `docs/`. Продакшен-код GarageSync и сервера не меняется. В
GarageCore только `import Foundation`. Проверка: `swift test` для GarageCore, GarageSync и Server,
`scripts/check.sh --only architecture`, `--only linux`. В CI — job `linux`.

### A1. Черновик — `VehicleDraft.swift`

```swift
/// Состояние формы машины: сырой ввод, проверка — в `makeVehicle`.
public struct VehicleDraft: Hashable, Sendable {
    public var kind: VehicleKind
    public var make: String
    public var model: String
    public var yearText: String
    public var mileageText: String

    public init(kind: VehicleKind = .car, make: String = "", model: String = "", yearText: String = "", mileageText: String = "")
    /// Обратное отображение для формы правки: год и пробег — цифры без разделителей.
    public init(vehicle: Vehicle)

    public enum Field: Hashable, Sendable { case make, model, year, mileage }
    public enum FieldError: Error, Hashable, Sendable {
        case required, notANumber, yearOutOfRange(ClosedRange<Int>), invalid(ValidationError)
    }
    public struct Errors: Error, Equatable, Sendable { public var fields: [Field: FieldError] }

    /// Марка и модель обрезаются по пробелам. Год — `1900...currentYear + 1`.
    public func makeVehicle(id: Vehicle.ID = UUID(), currentYear: Int) throws(Errors) -> Vehicle
}
```

- Пробег разбирается через `ServiceRecordDraft.parseMileage`: пустое поле → `required`, единые
  правила `negativeMileage` и `mileageTooLarge`.
- Все ошибки собираются сразу, как в `ServiceRecordDraft.makeRecord`.

### A2. Порт — `Repositories/Repositories.swift`

```swift
/// Хранилище техники. Каскад на записи и очередь синхронизации — забота адаптера.
public protocol VehicleRepository: Sendable {
    func add(_ vehicle: Vehicle) async throws
    /// Заменяет поля машины с тем же `id`. Машины нет → `RepositoryError.vehicleNotFound`.
    func update(_ vehicle: Vehicle) async throws
    /// Удаляет машину вместе с её записями, частями и чеками. Машины нет — не ошибка.
    func delete(id: Vehicle.ID) async throws
}
```

### A3. Use case'ы — `UseCases/AddVehicle.swift`, `UseCases/UpdateVehicle.swift`

```swift
public struct AddVehicle: Sendable {
    public init(vehicles: any VehicleRepository)
    /// Ошибки черновика (`VehicleDraft.Errors`) и репозитория пробрасываются как есть.
    public func execute(draft: VehicleDraft, currentYear: Int) async throws
}

public struct UpdateVehicle: Sendable {
    public init(vehicles: any VehicleRepository)
    /// Сохраняет `id` исходной машины. Ничего не изменилось → репозиторий не вызывается.
    public func execute(draft: VehicleDraft, original: Vehicle, currentYear: Int) async throws
}
```

### A4. Тесты GarageCore

- `VehicleDraftTests.swift`:
  - round-trip `VehicleDraft(vehicle: v).makeVehicle(id: v.id, currentYear: 2026) == v` для всех
    `Vehicle.samples`;
  - пустые и пробельные марка/модель → `required`;
  - год `"abc"` → `notANumber`, `1899` и `currentYear + 2` → `yearOutOfRange`, граница
    `currentYear + 1` проходит;
  - пробел вокруг марки обрезается;
  - отрицательный пробег → `invalid(.negativeMileage)`, пустой → `required`;
  - несколько ошибок сразу;
  - без `id` каждый вызов даёт новый id.
- `UseCases/UseCaseTests.swift`, новые `// MARK: AddVehicle` и `// MARK: UpdateVehicle`:
  - невалидный черновик не доходит до репозитория;
  - успешный путь;
  - `id` сохраняется;
  - без изменений вызова нет;
  - `vehicleNotFound` пробрасывается.
- `UseCases/Fakes.swift`: `FakeVehicleRepository` (`NSLock`, `@unchecked Sendable`, как
  `FakeRecordRepository`): `added`, `updated`, `deleted`, `var error`.

### A5. Тесты GarageSync и контракт `SyncStore.apply`

- `SyncStore.swift`: doc-комментарий `apply` дополнить строкой «удаление машины удаляет её записи и
  pending-upsert'ы этих записей».
- `TestSupport.swift`: `InMemorySyncStore.apply(.delete(.vehicle))` удаляет записи машины и их
  pending-upsert'ы; pending-delete записей остаются.
- Новые тесты в `SyncEngineTests.swift` (перечислены в пунктах 2–4 «Каскадного удаления»):
  `vehicleDeleteWithKeptRecordDeletesPushesCleanly`, `remoteVehicleDeleteDropsPendingRecordUpserts`,
  `newRecordForRemotelyDeletedVehicleIsDroppedLocally`, `editOfRemotelyDeletedVehicleDeletesItLocally`,
  `seededVehicleOverTombstoneIsDeletedLocally`.
- Новый тест в `ReceiptTests.swift`: `vehicleTombstoneDropsRecordUpsertHeldByReceiptFailure` (пункт 2).
- Если какой-то тест покажет, что `SyncEngine` ведёт себя не так, как описано в разделе «Каскадное
  удаление», код движка в A не правится. Расхождение записывается в отчёт PR, план обновляется, решение
  принимается до B.

### A6. Тесты сервера (код сервера не меняется)

`Server/Tests/AppTests/ChangesTests.swift`: `cascadeCoversRecordsTheDeletingDeviceNeverSaw`,
`queueOrderAroundVehicleDelete`, `secondDeviceEditsAfterVehicleDelete`,
`sampleVehicleCannotBeRecreatedAfterDelete`. `AuthAndReceiptsTests.swift`:
`receiptBlobOutlivesCascadedRecord`. Два «устройства» — два токена в одном `withTestApp`. Если хелпер
даёт только один, добавить в `TestSupport.swift` регистрацию второго.

### A7. Документация

- `docs/architecture.md`: в разделе «Use case или порт напрямую» добавить `AddVehicle` / `UpdateVehicle`
  и удаление машины через порт. Новый подраздел «Удаление техники»: только `delete(vehicle)`, снятие
  pending-upsert'ов записей и ссылка на этот план.

Готово, когда `swift test` GarageCore, GarageSync и Server зелёные, `check.sh --only architecture` и
`--only linux` чистые, CI `linux` зелёный.

---

## Часть B — хранилище, приложение, UI (локально, после мержа A)

### B1. GarageStorage

- `SyncQueue.swift`: `static func dropPendingUpserts(ofRecordsOf vehicle: VehicleEntity, in:)`. Для
  каждой `vehicle.serviceRecords` — `SyncState.pendingEntity(for: .serviceRecord(id))`; если операция
  этого pending — upsert, `context.delete(pending)`. Delete остаются. Работает в контексте вызывающего,
  ничего не сохраняет.
- `ServiceLog.swift`, `VehicleLog` — по образцу `ServiceLog`: свежий `ModelContext`,
  `autosaveEnabled = false`, одно сохранение, перегрузка с инъекцией `save`.
  - `add` — уже есть; добавить перегрузку с `save`.
  - `update(_ vehicle:, in:)`: сущности нет → `ServiceLogError.vehicleNotFound`;
    `entity.update(from:)`; `SyncQueue.enqueueUpsert(.vehicle(vehicle))`; `save`.
  - `delete(id:in:)`: сущности нет → вернуться без ошибки. Иначе
    `SyncQueue.enqueueDelete(.vehicle(id))` (всегда), затем `dropPendingUpserts(ofRecordsOf:)`, затем
    `context.delete(entity)` (записи, части и чеки — каскадом), затем `save`.
- `SwiftDataSyncStore.apply`, ветка `.delete(.vehicle)`: перед `modelContext.delete(entity)` вызвать
  `SyncQueue.dropPendingUpserts(ofRecordsOf: entity, in: modelContext)`.
- `Adapters/SwiftDataVehicleRepository.swift`: `VehicleRepository` поверх `VehicleLog`;
  `ServiceLogError.vehicleNotFound` → `RepositoryError.vehicleNotFound`.
- `ServiceRecordFormViewModel`: при добавлении записи к машине, удалённой во время открытой формы, сейчас
  показывается общий `saveFailed`. `RepositoryError.vehicleNotFound` → `vehicleGone` (алерт, затем
  закрыть форму), по образцу `recordGone`. Правка записи удалённой машины уже даёт `recordNotFound`.
- Тесты:
  - `FakeSyncServer.swift`: каскад на `delete(.vehicle)` по образцу `ChangeWriter.delete`. Записи с
    этим `vehicleID` получают tombstones со своими версиями, тем же `modifiedAt` и `changeID`. Для этого
    у живых записей хранить `vehicleID`. Счётчики запросов `PUT`/`GET /v1/receipts` и гейт на
    скачивание, если их ещё нет.
  - Новый `VehicleLogTests.swift`:
    - add/update: поля и upsert в очереди, `baseVersion` из версии;
    - две правки → один pending;
    - правка отсутствующей → `vehicleNotFound`;
    - сбой `save` ничего не пишет;
    - удаление отсутствующей — без ошибки и без pending;
    - тесты пунктов 1, 2, 5: `deleteQueuesOnlyVehicleDelete`, `deleteWithoutVersionStillQueuesDelete`,
      `deleteOfUnsentVehicleCollapsesIntoDelete`, `deleteDropsPendingRecordUpsertsKeepsDeletes`,
      `deleteRemovesReceiptBytes`.
  - `SwiftDataSyncStoreTests.swift`: `applyingVehicleTombstoneDropsRecordUpserts`.
  - `SampleSeederTests.swift`: `seedingDoesNotRecreateDeletedSampleVehicle`.
  - `SyncEndToEndTests.swift`: `vehicleDeleteCascadesToAnotherDevice`,
    `deletingVehicleWithUnsyncedRecordPushesWithoutRejections`, `vehicleDeletedWhilePushIsInFlight`,
    `recordAddedToVehicleDeletedOnAnotherDevice`, `deletedSampleVehicleStaysDeletedOnNewDevice`,
    `pendingReceiptDownloadIsDroppedWithVehicle`.
  - `AdapterTests.swift`: `SwiftDataVehicleRepository` — add/update/delete и маппинг `vehicleNotFound`.

### B2. ViewModel

- Новый `Features/VehicleForm/VehicleFormViewModel.swift`:
  - `enum Mode { case add, edit(original: Vehicle) }`.
  - Зависимости: `AddVehicle`, `UpdateVehicle`, `currentYear: () -> Int` (замыканием из composition
    root).
  - `draft`, `errors: [VehicleDraft.Field: VehicleDraft.FieldError]`, `isSaving`.
  - В режиме `edit` форма правки показывает ошибки полей сразу при открытии: черновик исходной машины
    проверяется в `init`, и `errors` заполняется (машина из синхронизации может не пройти проверку
    черновика, а `UpdateVehicle` не сохранит её, пока поля не исправлены).
  - `save() async -> Bool`: `VehicleDraft.Errors` → `errors`; `vehicleNotFound` в режиме `edit` →
    `vehicleGone`; прочее → `saveFailed`. Повторный вызов во время работы игнорируется.
  - `recordsMileageKm: Int?` — для подсказки «По записям» (решение 5); передаёт вызывающий.
- `VehicleDetailViewModel` (уже есть, удаляет записи): добавить
  - `isConfirmingVehicleDeletion`;
  - `deleteVehicle(id:) async -> Bool` через `VehicleRepository.delete`;
  - `vehicleDeleteFailed`.

  Флаг `isDeleting` общий с удалением записи. Пока идёт одно удаление, второе игнорируется.
- Новый `Features/VehicleList/VehicleListViewModel.swift`: `pendingDeletion: Vehicle.ID?`,
  `delete(id:) async`, `deleteFailed`, `isDeleting` — зеркало `VehicleDetailViewModel` для записей.
- `GarageTests/Fakes.swift`: `FakeVehicleRepository` с `Gate`.
- Тесты:
  - `VehicleFormViewModelTests`: черновик правки заполнен; невалидная исходная машина → ошибки в
    `errors` сразу после открытия; ошибки в `errors`; add и edit вызывают
    нужный use case; без изменений порт не вызван; `vehicleNotFound` → `vehicleGone`; сбой →
    `saveFailed`; повторный `save` при закрытом `Gate` даёт один вызов.
  - `VehicleListViewModelTests`: подтверждение → delete; сбой → `deleteFailed`; отмена → нет вызова;
    повторный delete при закрытом `Gate` — один вызов.
  - `VehicleDetailViewModelTests`: `deleteVehicle` успех → `true`; сбой → `vehicleDeleteFailed`;
    удаление записи во время удаления машины игнорируется.
  - `ServiceRecordFormViewModelTests`: `vehicleNotFound` при добавлении → `vehicleGone`.

### B3. Вью

- `VehicleListView`:
  - тулбар «Добавить машину» (`plus`) → `.sheet` с `VehicleFormView` в режиме `add`;
  - `.swipeActions(edge: .trailing, allowsFullSwipe: false)` «Удалить» с `.tint(.red)`, **без**
    `role: .destructive` → `viewModel.pendingDeletion`;
  - `.confirmationDialog` с числом записей (`item.recordCount`, plural) → `viewModel.delete(id:)`;
    ошибка — алертом.
- `VehicleDetailView`:
  - тулбар-меню (`ellipsis.circle`): «Изменить» → `.sheet` с `VehicleFormView(edit)`, «Удалить
    машину» (`role: .destructive` — это меню, не строка List) → `confirmationDialog` →
    `deleteVehicle` → `dismiss()` (pop из `NavigationStack`);
  - кнопка «Добавить запись» остаётся.

  Если машину удалили с другого устройства, экран уже показывает «Vehicle Not Found». Это не меняется.
- Новый `Features/VehicleForm/VehicleFormView.swift`:
  - `Form`: `Picker` типа (`VehicleKind` → локализованное имя в `Garage/Shared/`);
  - `TextField` марки и модели;
  - год и пробег с `.keyboardType(.numberPad)`;
  - ошибки под полями, как в `ServiceRecordFormView`; в режиме правки они видны сразу при открытии;
  - подсказка «По записям: N км»;
  - заголовок «Новая машина» / «Правка машины»;
  - алерты `saveFailed` и `vehicleGone`.

  Марку и модель пользователь вводит сам, поэтому в диалогах они идут через `Text(verbatim:)` /
  интерполяцию `String`.

### B4. Composition root

- `AppDependencies`: один `SwiftDataVehicleRepository`, `AddVehicle`, `UpdateVehicle`,
  `currentYear: { Calendar.current.component(.year, from: Date()) }`.
- Фабрики:
  - `makeVehicleFormViewModel()`;
  - `makeVehicleFormViewModel(editing: Vehicle, recordsMileageKm: Int?)`;
  - `makeVehicleListViewModel()`;
  - `makeVehicleDetailViewModel()` — расширить зависимостью `VehicleRepository`.

### B5. Строки (`Garage/Localizable.xcstrings`, сразу `ru`, `state: translated`)

Уже есть и переиспользуются: Delete, Cancel, Save, OK, Couldn't Delete, Couldn't Save, Required, Enter a
valid number, Mileage, km, Vehicle Not Found, This can't be undone.

| en | ru |
|---|---|
| Add Vehicle | Добавить машину |
| New Vehicle | Новая машина |
| Edit Vehicle | Правка машины |
| Edit | Изменить |
| Delete Vehicle | Удалить машину |
| Delete this vehicle? | Удалить эту машину? |
| Its %lld service records will be deleted too. | plural: one «Вместе с ней будет удалена %lld запись.», few «…удалены %lld записи.», many/other «…удалены %lld записей.» (en: one/other) |
| The vehicle could not be deleted. Please try again. | Не удалось удалить машину. Попробуйте ещё раз. |
| Vehicle Deleted | Машина удалена |
| This vehicle was deleted on another device. | Эта машина была удалена на другом устройстве. |
| Kind | Тип |
| Car | Автомобиль |
| Motorcycle | Мотоцикл |
| Bicycle | Велосипед |
| Make | Марка |
| Model | Модель |
| Year | Год |
| Enter a year from %lld to %lld | Введите год от %lld до %lld |
| By records: %@ | По записям: %@ |

Если машина без записей, вторая строка подтверждения не показывается.

### B6. Проверка

- `scripts/check.sh` целиком: architecture, linux, ios, strings.
- ui-checker, на `en` и `ru` (`-AppleLanguages "(ru)"`):
  1. «+» в списке → форма. Пустое сохранение показывает ошибки под полями. Заполнить → «Сохранить» →
     машина в списке.
  2. Экран машины → «…» → «Изменить» → форма заполнена. Сменить год → сохранить → заголовок и список
     обновились.
  3. Свайп в списке → «Удалить» → диалог с числом записей (ru: проверить «3 записи» / «5 записей») →
     «Отмена»: строка на месте. Повтор с подтверждением: строки нет.
  4. Экран машины → «…» → «Удалить машину» → подтверждение: экран закрыт, машины в списке нет.
     Сразу после подтверждения ui-checker делает снимок и проверяет, что до закрытия экран не
     показывает «Vehicle Not Found» (`@Query` может обновиться раньше `dismiss()`). Если показывает —
     `VehicleDetailView` держит последнее содержимое машины, пока `viewModel.isDeleting`, и сценарий
     повторяется.
  5. Сквозной сценарий с локальным сервером (CLAUDE.md, «Local server»), по желанию: удалить демо-машину
     → sync → переустановить приложение → зарегистрировать → sync → машины нет (п. 4).
- swift-reviewer на diff.
- `docs/architecture.md`: в разделе «Пример» и «Шаблон» упомянуть `VehicleLog.update` / `delete`,
  `dropPendingUpserts`, `VehicleFormViewModel`, `VehicleListViewModel`.

## Сводка: пункт → тесты

| Пункт | A (Linux) | B (Storage / e2e) |
|---|---|---|
| 1. Только delete машины | `cascadeCoversRecordsTheDeletingDeviceNeverSaw` | `deleteQueuesOnlyVehicleDelete`, `deleteWithoutVersionStillQueuesDelete`, `deleteOfUnsentVehicleCollapsesIntoDelete`, `vehicleDeleteCascadesToAnotherDevice` |
| 2. Очередь записей | `queueOrderAroundVehicleDelete`, `vehicleDeleteWithKeptRecordDeletesPushesCleanly`, `remoteVehicleDeleteDropsPendingRecordUpserts`, `vehicleTombstoneDropsRecordUpsertHeldByReceiptFailure` | `deleteDropsPendingRecordUpsertsKeepsDeletes`, `applyingVehicleTombstoneDropsRecordUpserts`, `deletingVehicleWithUnsyncedRecordPushesWithoutRejections`, `vehicleDeletedWhilePushIsInFlight` |
| 3. Гонка устройств | `secondDeviceEditsAfterVehicleDelete`, `newRecordForRemotelyDeletedVehicleIsDroppedLocally`, `editOfRemotelyDeletedVehicleDeletesItLocally` | `recordAddedToVehicleDeletedOnAnotherDevice` |
| 4. Демо-машины | `sampleVehicleCannotBeRecreatedAfterDelete`, `seededVehicleOverTombstoneIsDeletedLocally` | `seedingDoesNotRecreateDeletedSampleVehicle`, `deletedSampleVehicleStaysDeletedOnNewDevice` |
| 5. Чеки | `receiptBlobOutlivesCascadedRecord` | `deleteRemovesReceiptBytes`, `pendingReceiptDownloadIsDroppedWithVehicle` |

## Риски

- **Потеря записи при гонке (п. 3, п. 4).** Если машину удалили на другом устройстве, запись, добавленная
  к ней, исчезает без сообщения. Так работает правило «удаление побеждает». Сообщение пользователю
  потребует `rejected` в `SyncSummary`; это кандидат на следующий этап.
- **Осиротевшие чеки на сервере (п. 5).** После каскада blob'ы остаются. GC вне скоупа `docs/api.md`.
  Для одного пользователя с лимитом 5 МиБ на чек это приемлемо, пока нет компактации.
- **`rejected/internal` на `delete(V)`.** Движок делает `discard`, а локально машины и записей уже нет:
  сервер и устройство расходятся. Этот риск уже есть у удаления записей (этап 9). Здесь он крупнее, потому
  что pending-upsert'ы записей сняты. Повторять `internal` или нет — решение для `SyncEngine`, в этом
  этапе не меняется. Записать в отчёт.
- **Лишняя правка в отчёте sync.** `report.stillPending` считается до pull (`SyncEngine.swift:120`), поэтому upsert записи, придержанный push'ем и снятый tombstone'ом машины, всё равно попадает в отчёт; было и до этапа, здесь случается чаще — не меняется.
- **Дублирование расчёта пробега по записям.** `VehicleDetailView` считает «пробег по записям» для подсказки
  формы как `records.map(\.mileageKm).max()`, это повторяет логику `Vehicle.currentMileageKm(records:)`.
  Вынести в GarageCore (например `Vehicle.recordedMileageKm(records:)`) — отдельная задача.
- **Устаревшая форма правки.** Форма открыта, а машину правят на другом устройстве. Как на этапе 9:
  LWW по сущности целиком, снимок формы перезапишет чужие поля.
- **`FakeSyncServer` и `ChangeWriter`.** В B1 фейк приведён к серверу там, где его трогает удаление:
  - каскад `delete(.vehicle)`: tombstones живых записей с `vehicleID` машины, по порядку версий, каждая со
    своей новой версией, тем же `modifiedAt` и `changeID`;
  - delete не проверяет `baseVersion` и никогда не конфликтует (раньше по tombstone отвечал
    `conflict/deleted`); строки нет — tombstone без владельца; уже tombstone — его версия, без каскада;
  - повтор элемента push с тем же `changeID` даёт `applied` с версией строки.

  Осталось расхождение: upsert с `baseVersion` по неизвестному id фейк отклоняет как `validationFailed`,
  а по контракту это создание. Тесты этапа на этот путь не опираются, поэтому фейк здесь не правится.
  Фейк также не валидирует содержимое DTO (`DTOValidation` на сервере).
