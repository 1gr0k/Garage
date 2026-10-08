# Этап 12: заметки (аудит, пробы, проверки, итоги частей)

Основной план — [stage-12-reminders.md](stage-12-reminders.md): решения, части, сводка «пункт → тесты», риски.
Здесь — подробности, вынесенные из плана: то, что нужно при разборе конкретного места, а не при чтении плана.

Оглавление:

1. [Аудит эволюции контракта (T1–T10)](#аудит-эволюции-контракта-t1t10)
2. [Пробы шага 0](#пробы-шага-0)
3. [Итоги реализации части A (2026-10-08)](#итоги-реализации-части-a-2026-10-08)
4. [Итоги реализации части S (2026-10-08)](#итоги-реализации-части-s-2026-10-08)
5. [Итоги реализации частей B1 и B2 (2026-10-08)](#итоги-реализации-частей-b1-и-b2-2026-10-08)

---

## Аудит эволюции контракта (T1–T10)

Таблица из решения 9a основного плана. Аудит GarageAPI и разбора ответов в GarageSync выполнен при планировании,
в начале A перепроверяется grep'ом по `rawValue`, `dataCorruptedError`, `throw` в `Packages/GarageAPI/Sources` и
`Packages/GarageSync/Sources`.

| # | Место | Сейчас при незнакомом значении | Становится | Где правка |
|---|---|---|---|---|
| T1 | `entity` в элементе `changes` ответа pull (`ChangeOperation.init(from:)`, `EntityKind(rawValue:)`) | `DecodingError` → не декодируется **весь** `PullResponse`, синхронизация падает | элемент пропускается, имя вида — в `PullResponse.skipped`, лог | A, GarageAPI + `SyncEngine` |
| T2 | `op` в элементе `changes` ответа pull | то же | то же: элемент пропускается (`"op:<значение>"` в `skipped`) | A |
| T3 | `status` в `PushResult` | `DecodingError` → весь `PushResponse`, синхронизация падает | `PushOutcome.unrecognized(status:)`; движок **оставляет изменение в очереди** (безопасный вариант: не теряет локальную правку; повтор идемпотентен по `changeID`), пишет в отчёт (`SyncReport.unrecognizedOutcomes`); `SwiftDataSyncService` пишет `notice` в лог **при каждом прогоне**, где такой исход был (статус, `refKey`, число повторов в этом прогоне), — повтор от прогона к прогону виден в логе (R12) | A, GarageAPI + `SyncEngine`; лог — в `SwiftDataSyncService` (GarageStorage) в B |
| T4 | `current` в `conflict` с незнакомым `entity`/`op` | весь `PushResponse` падает | исход этого элемента — `unrecognized` (как T3), остальные элементы обрабатываются | A |
| T5 | `reason` конфликта (`ConflictReason`) | уже терпимо: `.unknown(String)`, движок решает по LWW из `current` | без изменений; добавить golden-пример | A, только `docs/api.md` + тест |
| T6 | `code` ошибки (`APIErrorCode`) в `rejected` и в теле ошибки HTTP | уже терпимо: `.unknown(String)`; `rejected` с незнакомым кодом идёт общей веткой (изменение снимается с очереди, локальные данные остаются) | без изменений; golden-пример `rejected` с незнакомым кодом + тест движка «общий rejected» | A |
| T7 | `kind` машины (`VehicleDTO.kind` → `VehicleKind(rawValue:)` в `Vehicle(dto:)`) | `SyncMappingError` → изменение машины пропускается; затем **все её записи** — `cannotApply` (нет машины) | сырое значение в `VehicleSyncExtras.rawKind` (как `rawServiceType`), в домене — `.car` для показа; сырое значение **сохраняется при любой правке машины, пока вид не выбран в форме явно**, и уходит push'ем без изменений (решение 9e) | **B**: нужна колонка `VehicleEntity.rawKind` и новая форма `SyncEntity.vehicle` (меняет `switch` в GarageStorage) |
| T8 | `serviceType` записи | уже терпимо (`.other` + `rawServiceType`) | без изменений; golden-пример записи с незнакомым типом | A |
| T9 | `serviceType` и `period` правила (`MaintenanceRuleDTO`, новое) | — | `serviceType` — как T8; незнакомый `period` (`"weeks:2"`) — сырое значение в extras, интервал по времени в домене отсутствует; если не остаётся ни одного известного интервала — правило пропускается (`skipped`) | A — DTO и golden; маппинг — S |
| T10 | новые ключи в любом объекте | уже терпимо (`JSONDecoder` игнорирует) | без изменений; существующий тест `unknownKeysAndNullAreTolerated` | — |

---

## Пробы шага 0

Вопросы (план шага 0 в основном плане).

| # | Вопрос | Как проверить | Что меняет ответ |
|---|---|---|---|
| 0.1 | Показывает ли `requestAuthorization` на симуляторе системный алерт; можно ли выдать разрешение заранее (`xcrun simctl privacy <udid> grant notifications …` — есть ли такая служба) | проба на `Garage UI en` | Нужен ли фейк в UI-режиме только ради алерта (решение 12) или ещё и ради детерминизма |
| 0.2 | Работают ли `add` / `getPendingNotificationRequests` / `removePendingNotificationRequests` без выданного разрешения (статус `.notDetermined` и `.denied`) | проба в хост-приложении `GarageTests` | Можно ли тестировать адаптер в `GarageTests` без алерта; ставить ли уведомления до разрешения |
| 0.3 | Лимит отложенных уведомлений: что происходит при `add` 65-го и 100-го запроса (ошибка, тихий отброс, какие остаются — ближайшие или последние добавленные) | проба: 100 запросов с разными датами, затем `getPendingNotificationRequests` | Окно планирования (решение 14): сами режем до N или доверяем системе |
| 0.4 | `UNCalendarNotificationTrigger(dateMatching:)` без `timeZone` в компонентах: `nextTriggerDate()` после смены часового пояса симулятора и для даты по ту сторону перехода на летнее время (например `America/New_York`, 2027-03-14) | проба: поставить, сменить TZ (`TZ` в окружении процесса / настройки симулятора), прочитать `nextTriggerDate()` | Подтверждает решение 13 (локальное «настенное» время) |
| 0.5 | Добавление запроса с тем же `identifier` заменяет прежний (а не дублирует) | проба | Идемпотентность пересчёта (решение 14) |
| 0.6 | Доставка в тестах: можно ли в XCUITest дождаться реального баннера (короткий `UNTimeIntervalNotificationTrigger`) и найти его через `springboard` | проба | Есть ли вообще UI-тест доставки или доставка — только ручная проверка (риск R3) |
| 0.7 | Приходит ли `ModelContext.didSave` (или другое уведомление SwiftData) для сохранений **из любых** контекстов — свежих контекстов `ServiceLog`/`VehicleLog` и `ModelActor` `SwiftDataSyncStore` — подписчику с `object: nil`; на каком потоке | проба в `GarageStorage`-копии | Источник сигнала «данные изменились» (решение 15): один наблюдатель или явные вызовы после каждой записи |
| 0.8 | `Calendar` с `TimeZone(identifier: "Europe/Moscow")` / `"America/New_York"` и `date(byAdding: .month …)` в контейнере `swift:6.4-noble` (есть ли tzdata) | прогон пробного теста в CI-ветке scratch или `docker run swift:6.4-noble` при наличии Docker | Можно ли тесты DST в GarageCore гонять на Linux; иначе — фиксированные смещения и iOS-тест |
| 0.9 | Переживает ли очередь реальную смену модели (решение 9c): сборка `master` на симуляторе → машина и запись без синхронизации (pending в очереди) → поверх установить сборку с пробной `MaintenanceRuleEntity` и отношением у `VehicleEntity`, без `SchemaMigrationPlan` → открылось ли хранилище, сколько строк `PendingChangeEntity`, декодируются ли они, ушли ли push'ем на локальный сервер с прежними `baseVersion` | проба в scratchpad-копии, локальный сервер из CLAUDE.md | Нужна ли `VersionedSchema` + `SchemaMigrationPlan` в B; какой тест апгрейда возможен автоматически |

### Итоги разведки (2026-10-08)

Пробы — в scratchpad-копии репозитория: временные тесты в `GarageTests` и `GarageStorageTests` (запуск через
`check-runner`), отладочный `NotificationProbe` в копии приложения (аргумент `-NotificationProbe`) на
одноразовом симуляторе `Garage Probe` (iPhone 17, iOS 27.2; удалён после проб). Проба 0.8 — в CI на
временной ветке `probe/tz` (удалена). В `stage-12-reminders` из проб ничего не попало.

| # | Результат | Что меняет в плане |
|---|---|---|
| 0.1 | Алерт показывается (ru: «Приложение «Garage» запрашивает разрешение…», кнопки «Не разрешать» / «Разрешить»), на свежем симуляторе — с задержкой ~25–35 с после запроса. `xcrun simctl privacy` **не знает службы уведомлений** — заранее выдать разрешение нельзя. Из хоста `GarageTests` алерта за ~50 с не дождались (прогон остановлен; вероятно, та же задержка, не выяснялось) | Решение 12 подтверждено и становится обязательным: в UI-режиме только фейк, иначе алерт блокирует сценарий, а выдать разрешение заранее нечем |
| 0.2 | Без разрешения `add` **бросает** `UNErrorDomain 2003` «Source is not authorized» (при статусе `notDetermined`; в `userInfo` — `Denied`); `pending` пуст. Ставить уведомления «заранее, до разрешения» нельзя | A5: `RescheduleReminders` сначала спрашивает `authorization()`; не `authorized` → порт уведомлений не вызывается (не ошибка). Пересчёт — после выдачи разрешения (форма, решение 11) и при `active` (пользователь мог включить в Настройках). Вариант «ставить полный набор при `denied`» отпадает. Адаптер в `GarageTests` автоматически не проверить (нет разрешения и нет способа выдать его) → адаптер максимально тонкий, логика окна — в GarageCore (`nextReminders`), адаптер — ручная проверка B7 (R3 расширяется) |
| 0.3 | Лимит — **64**, `add` сверх него **не бросает**. Система молча оставляет **64 последних добавленных**, а не ближайших: добавление от дальних к ближним сохранило 000–063, от ближних к дальним — 036–099 | Решение 14 обязательно: окно режем сами (60 ближайших) до вызова порта; полагаться на систему нельзя — при порядке «ближние первыми» она выкинула бы ближние |
| 0.4 | `UNCalendarNotificationTrigger` хранит компоненты **без** `timeZone` (`nil` после чтения из pending). `nextTriggerDate()` считает по текущему часовому поясу: 10:00 в Нью-Йорке, Москве, Токио — каждый раз 10:00 местного. День перехода на летнее время (NY 2027-03-14) — 10:00 EDT; 02:30 в «дыре» → 03:30; 01:30 в повторяющемся часе → первое вхождение. С явным `timeZone` — срабатывание по нему | Решение 13 подтверждено (10:00 без TZ). Не проверено: пересчёт системой уже стоящего запроса при смене пояса устройства (проверялся только расчёт в процессе) — риск R14 |
| 0.5 | `add` с тем же `identifier` **заменяет** запрос: один запрос, новое содержимое и дата | Идемпотентность по `maintenance-rule.<UUID>` подтверждена; `replaceAll` может просто `add` изменившиеся и `remove` лишние |
| 0.6 | Доставка на симуляторе работает: `UNTimeIntervalNotificationTrigger(5 s)` → SpringBoard показал баннер (`Presentable did appear as banner … requestIdentifier: probe.banner`), приложение на переднем плане с делегатом `willPresent → [.banner, .list]`. Поиск баннера из XCUITest не пробовали | UI-тесты используют фейк (решение 12), реальный баннер им не нужен. Доставка — ручная проверка B7 на симуляторе (с ожиданием ~30 с алерта на свежем устройстве) |
| 0.7 | `ModelContext.didSave` приходит подписчику с `object: nil` от **всех** сохранений: свежие контексты `VehicleLog`/`ServiceLog`, `ModelActor` `SwiftDataSyncStore`, адаптер, `mainContext`. Поток — тот, где сохраняли (у адаптера — не главный). `userInfo`: `inserted`, `updated`, `deleted`, `historyTokens` | Решение 15: вариант `StoreChanges.saves(of:)` на `NotificationCenter` подходит, порт `DataChangeNotifying` и явные вызовы не нужны. Обязательно: переход на главный актор в координаторе; сигнал приходит и от служебных сохранений синхронизации (`setCursor`, `markApplied`) — дебаунс это гасит, фильтр по типам моделей в `userInfo` — по необходимости |
| 0.8 | Локально Docker нет, поэтому прогон в CI (с согласия пользователя): временная ветка `probe/tz` с `TimeZoneProbeTests` в GarageCore, ручной запуск `ci.yml` (`workflow_dispatch`; push в ветку CI не запускает). Run [37761371561](https://github.com/1gr0k/Garage/actions/runs/37761371561): job `linux` — success, оба теста прошли в `swift:6.4-noble`: `TimeZone(identifier: "Europe/Moscow") != nil`; в `America/New_York` сутки 13→14.03.2027 — 23 часа, 10:00 → 10:00, смещение −5 → −4 ч. Ветка удалена локально и на GitHub | tzdata в образе есть: `ci.yml` не меняется, DST-тесты остаются в GarageCore и идут на Linux; R5 снят |
| 0.9 | Лёгкая миграция SwiftData **сработала без `SchemaMigrationPlan`** для: новой `@Model` с отношением к `VehicleEntity` (`.cascade`), нового `@Relationship` у `VehicleEntity`, новой необязательной колонки `rawKind`. Хранилище фазы 1 (`schemaVersion` 2, 3 строки очереди, одна с `baseVersion 7`) открылось новой моделью: все 3 строки на месте и декодируются, `baseVersion 7` сохранён, версия сущности без pending (`vehicle=9`) удалена, курсор сброшен, `schemaVersion` 3. Каскад новой сущности работает | Решение 9c закрыто: очередь переживает и рост версии, и реальную смену модели. `SchemaMigrationPlan` в B не нужен (пока изменения добавляющие). Тест апгрейда в B1 — на временном файле (воспроизводимо). **Находка:** если на момент роста версии `bootstrapped == false` (в пробе — потому что хранилище создано без `SyncSupport.prepare`), разовый bootstrap снова ставит в очередь как **создание** (`baseVersion nil`) сущности, чьи версии только что удалены, — сервер ответит `conflict/alreadyExists`, движок разрешит по LWW. Потери нет, лишний конфликт есть. В приложении `bootstrapped` обычно `true`; остаётся открытым, если bootstrap пропустил нечитаемую сущность (R15) |

Правки по итогам приняты пользователем и внесены в текст: решение 14 (окно режем сами — 0.3), решение 15
(`StoreChanges` — 0.7), A5 (без разрешения порт не вызывается — 0.2), B1 (лёгкая миграция и тест апгрейда
на файле, включая повторную отправку при незавершённом bootstrap — 0.9), B2 (адаптер без автотестов, чистая
`makeRequest` — 0.1/0.2), риски R3, R14, R15.

---

## Итоги реализации части A (2026-10-08)

Аудит A0: grep по `rawValue`, `dataCorruptedError`, `throw`, `DecodingError` в `Packages/GarageAPI/Sources` и
`Packages/GarageSync/Sources` совпал с таблицей 9a — новых мест нет (`APICoding.swift:45` — формат даты,
остаётся строгим).

**Проверка на зубы** (по одному декодеру: временно вернул строгость только ему, прогон `GarageAPI` и `GarageSync`
через `check-runner`, затем откат правкой; повторена в PR 12 отдельными прогонами, по одному на мутацию):

| Декодер | Мутация | Упавшие тесты |
|---|---|---|
| T1 (`entity`) | `ChangeOperation.init(tolerantFrom:)`: вместо `UnrecognizedChange("entity:…")` — `DecodingError` | GarageAPI: `unknownEntityAndOpAreSkippedBetweenKnownChanges`, `maintenanceRuleIsKnownWhileFutureEntityIsStillSkipped`, `goldenExampleRoundTrips` (`pull-response-unknown-entity`, `push-response-unknown-status`), `conflictWithUnrecognizedCurrentBecomesUnrecognized`; GarageSync: `pullSkipsUnknownEntityAndOpAndKeepsCursor`, `skippedUnrecognizedIsNotCountedTwiceAfterCursorExpired`, `conflictWithUnrecognizedCurrentKeepsChangeQueued` |
| T2 (`op`) | то же для `UnrecognizedChange("op:…")` | GarageAPI: `unknownEntityAndOpAreSkippedBetweenKnownChanges`, `goldenExampleRoundTrips` (`pull-response-unknown-op`), `conflictWithUnrecognizedCurrentBecomesUnrecognized`; GarageSync: `pullSkipsUnknownEntityAndOpAndKeepsCursor` |
| T3 (`status`) | `PushResult`: ветка `default` бросает `DecodingError` вместо `.unrecognized` | GarageAPI: `unknownPushStatusBecomesUnrecognized`, `goldenExampleRoundTrips` (`push-response-unknown-status`); GarageSync: `unrecognizedPushStatusKeepsChangeQueuedAndResendsItWithSameChangeID`, `unrecognizedPushStatusDoesNotBlockNeighbours`, `unrecognizedChangeIsNotResentInLaterRoundsOfTheSameRun` |
| T4 (`current` в `conflict`) | `PushResult`: перехват `UnrecognizedChange` заменён на `DecodingError` | GarageAPI: `conflictWithUnrecognizedCurrentBecomesUnrecognized`, `goldenExampleRoundTrips` (`push-response-unknown-status`); GarageSync: `conflictWithUnrecognizedCurrentKeepsChangeQueued` |
| T5 (`reason`) | `ConflictReason.init(from:)` бросает на `.unknown` | GarageAPI: `unknownConflictReasonBecomesUnknown`, `goldenExampleRoundTrips` (`push-response-unknown-conflict-reason`); GarageSync: `unknownConflictReasonIsResolvedFromCurrent` |
| T6 (`code`) | `APIErrorCode.init(from:)` бросает на `.unknown` | GarageAPI: `unknownErrorCodeBecomesUnknown`, `goldenExampleRoundTrips` (`push-response-unknown-error-code`); GarageSync: `rejectedWithUnknownCodeTakesTheGeneralBranch` |
| T8 (`serviceType` записи) | `ServiceRecord.decoded(from:)`: `catch { throw error }` вместо `.other` + `rawServiceType` | GarageSync: `unknownServiceTypeIsKeptAndSentBack`, `goldenUnknownServiceTypeIsReadAsOtherAndSentBackUnchanged`, `unknownServiceTypeSurvivesLocalEdit`; GarageAPI не падает (декодера `serviceType` там нет, DTO хранит строку) |
| Движок: `unrecognized` → `discard` вместо «оставить в очереди» | GarageSync: `unrecognizedPushStatusKeepsChangeQueuedAndResendsItWithSameChangeID`, `unrecognizedPushStatusDoesNotBlockNeighbours`, `unrecognizedChangeIsNotResentInLaterRoundsOfTheSameRun`, `conflictWithUnrecognizedCurrentKeepsChangeQueued` |
| Движок: без фильтра «не слать повторно в том же прогоне» | GarageSync: `unrecognizedChangeIsNotResentInLaterRoundsOfTheSameRun` (единственный) |

Каждая мутация применялась отдельно. У каждого декодера есть собственный тест, названный по нему: T1 —
`pull-response-unknown-entity`; T2 — `pull-response-unknown-op` (ни при какой другой мутации не падает); T3 —
`unknownPushStatusBecomesUnrecognized`; T4 — `conflictWithUnrecognizedCurrentBecomesUnrecognized`; T5 —
`unknownConflictReasonBecomesUnknown`; T6 — `unknownErrorCodeBecomesUnknown`; T8 — тесты маппинга записи в
GarageSync. Новых тестов не потребовалось. Пересечения неизбежны, потому что декодеры вложены: T1 и T2 разбирают
и `current` внутри `conflict`, поэтому их мутации роняют ещё и тесты T4. Две строки про движок ниже — результат
прежних отдельных прогонов части A.

T9 (`period` правила) в A — строка в DTO без декодера, поэтому зубов в A нет; тест маппинга и его проверка на
зубы — в S. T7 — в B.

**Отклонения от плана:**

1. **`ValidationError` получил четыре случая** (`noInterval`, `periodOutOfRange(Int)`, `distanceOutOfRange(Int)` и
   добавленный `unknownPeriod(String)` для разбора `ServicePeriod`). `ValidationError` исчерпывающе разбирается в
   приложении (`Garage/Shared/Formatting.swift`), поэтому A трогает ещё и приложение: ветки `message` и четыре строки
   в `Garage/Localizable.xcstrings` с русским переводом. Иначе секция `ios` краснеет (урок этапа 9). Часть A поэтому
   проверяется не только `linux`, но и `ios`/`strings`.
2. **`PushOutcome.unrecognized(status:)` для `conflict` с незнакомым `current`** несёт `status = "conflict/entity:<вид>"`
   (или `conflict/op:<значение>`), а не просто `"conflict"`: в логе видно, что именно незнакомо.
3. **Пропуск живёт только в ответах.** `ServerChange.init(from:)` бросает `UnrecognizedChange` (его ловят `PullResponse`
   через поэлементную обёртку и `PushResult`), а `PushChange` (входящий запрос сервера) остаётся строгим — незнакомый
   `entity`/`op` там по-прежнему `DecodingError` → `400`. `PullResponse.skipped` не кодируется (нет на проводе).
   Тесты: `unknownEntityOrOpInPushRequestFails`.
4. **`SyncEngine`:** изменение с `unrecognized` не отправляется повторно в следующих раундах того же прогона
   (иначе при перебазировании соседа оно ушло бы второй раз), и попадает в `SyncReport.stillPending`.
5. **Базис — «самая поздняя по календарному дню»**, а не по точному `Date` (запись с вечерним временем не должна
   перебивать запись того же дня с большим пробегом); при равных днях — больший пробег, затем `id` для детерминизма.
6. **Общий хелпер** `ServiceTypeChoice.serviceType(otherText:)` вынесен из `ServiceRecordDraft` (форма записи и форма
   правила не дублируют переключатель); поведение формы записи не менялось (тесты зелёные).
7. Тесты use case'ов правил — отдельный файл `UseCases/MaintenanceUseCaseTests.swift`, а не `UseCaseTests.swift`;
   декодирование правила, как у `ServiceRecord`, пробрасывает `ValidationError` (не `DecodingError`).
8. В `docs/api.md` у раздела «Правило обслуживания» стоит пометка о статусе: DTO и формат описаны, а `entity:
   "maintenanceRule"` в `/v1/changes` включается в S.

По итогам swift-reviewer (исправлено в части A):

9. **Порог «скоро» зависит от интервала** (уточнение решения 4): `min(soonDays, интервал в днях / 2)` и
   `min(soonKm, distanceKm / 2)` (месяц = 30 дней). `soonDays = 30` и `soonKm = 1 000` остаются верхней границей.
   Иначе правило «каждые 14 дней» или «каждые 500 км» было бы «скоро» сразу после обслуживания.
10. **Расчёт всегда в григорианском календаре** с поясом переданного (`MaintenanceSchedule.gregorian(matching:)`):
    в японском календаре год `CalendarDay` без эпохи неоднозначен (запись 2018 года → «31-й год Рэйва» = 2049).
    **Для B:** адаптер уведомлений обязан задать `fireAt` компоненты с `calendar: Calendar(identifier: .gregorian)`
    (иначе `UNCalendarNotificationTrigger` прочитает год в календаре пользователя). Тест — `japaneseCalendarDoesNotConfuseEras`.
11. `ServicePeriod(storageString:)` принимает только каноничные числа (`"days:+5"`, `"days:007"` — неизвестный
    период, сырое значение сохраняется и уходит обратно без нормализации; важно для T9 в S).
12. Сброс курсора по `cursorExpired` обнуляет `report.skippedUnrecognized` (иначе пропущенное считалось бы дважды);
    ошибка строгого разбора push-запроса указывает на ключ `entity` или `op` по существу.
13. Добавлены тесты: переход на зимнее время (сложение секундами сломало бы `dueDay`), японский календарь, короткие
    интервалы, независимость окна от порядка входа (старый «повтор» теста не мог упасть).

**Известные ограничения / в B:**

- `SyncReport.stillPending` заполняется в конце push, до pull: если pull принёс новую версию сущности с
  `unrecognized`-изменением и перебазировал его, отчёт может перечислить устаревший элемент. Влияет только на лог
  `unrecognizedOutcomes` в B; перенос чтения очереди после pull меняет смысл поля — решаем в B вместе с логом.
- Сообщение `ValidationError.periodOutOfRange` («Интервал вне допустимых пределов») не называет границы 1…3650 дней /
  1…120 месяцев; в B, когда появится форма, сделать сообщение с единицей и диапазоном.

---

## Итоги реализации части S (2026-10-08)

Сделано по плану: `EntityKind.maintenanceRule` / `EntityPayload.maintenanceRule` (GarageAPI), сервер (`Validation`,
`ChangeWriter.upsert` и каскад, `EntityRow.toServerChange`), GarageSync (`RuleSyncExtras`, `SyncEntity.maintenanceRule`,
маппинг, `vehicleNotFound` для правил, контракт `SyncStore.apply`), заглушка в GarageStorage, `schemaVersion` 2 → 3,
`ContractTripwireTests`.

**Миграция сервера не нужна:** таблица `entities` общая, `kind` — свободная строка без enum/CHECK
(`Migrations.swift`, `CreateEntities`), `vehicle_id` уже есть.

**Проверка на зубы** (временные мутации, откат правкой, `git diff` без остатков):

| Мутация | Упавшие тесты |
|---|---|
| Фиктивный `case futureProbe` в `EntityKind` (с ветками в исчерпывающих `switch`), `schemaVersion` не менялась | `ContractTripwireTests.entityKindsMatchTheSnapshotOfTheCurrentSchemaVersion` с сообщением «Изменился набор EntityKind: увеличь GarageStore.schemaVersion и добавь снимок…» (снимок `[vehicle, serviceRecord, maintenanceRule]`, сейчас `[…, futureProbe]`); два других теста набора зелёные |
| T9: сырой `period` не сохраняется (`extras.rawPeriod` не ставится) | `unknownPeriodIsKeptRawAndSentBackWhileDistanceRemains`, `unknownPeriodAndTypeSurviveLocalEdit`, `periodOutOfRangeFailsWhileNonCanonicalStaysRaw` |
| Движок: `vehicleNotFound` только для `.serviceRecord` | `vehicleNotFoundDeletesRuleLocally` |

Мутации T9 и движка применялись одним прогоном, тест, упавший по нескольким причинам, указан у подходящей.

**Отклонения и решения:**

1. **`period` вне границ (`"months:999"`) — не T9.** Сырым хранится только незнакомый формат
   (`ValidationError.unknownPeriod`, включая неканоничные `"days:+5"`); известный формат вне границ — нарушение
   формата, правило пропускается (`skipped`) по принципу «Не трогаем» решения 9a. Сервер отвергает и то, и другое.
2. **`EntityKind.isVehicleChild`** (GarageAPI, исчерпывающий `switch`) и `SyncEntity.parentVehicleID` (GarageSync) —
   общее место для «дочерней сущности машины»: каскад сервера, `vehicleNotFound` и `rejectedVehicles` движка не
   перечисляют виды вручную.
3. **Заглушка GarageStorage:** upsert правила → `SyncStoreError(cannotApply: StorageMappingError.unsupportedEntity)`
   (правило в `skipped`, курсор идёт дальше), delete правила — no-op с запоминанием версии (после роста `schemaVersion`
   в B версии без pending сбрасываются).
4. `RuleSyncExtras.rawPeriod` уходит на сервер, пока `rule.period == nil`. **Открытый вопрос B:** как отличить
   «пользователь убрал интервал по времени» от «не трогал» (аналог решения 9e для вида машины): адаптер должен сбрасывать
   `rawPeriod` только по явному действию в форме.
5. `FakeSyncServer` (тесты GarageStorage) не валидирует содержимое DTO, в отличие от сервера; задокументировано в
   комментарии. Тест T9 «сырой период уходит на сервер» в B нужно гнать против правил валидации (или дополнить фейк).
6. Каскад удаления машины для правил проверен на `InMemorySyncStore` (контракт); на реальном `SwiftDataSyncStore`
   правил ещё нет — тест каскада SwiftData остаётся в B1.

---

## Итоги реализации частей B1 и B2 (2026-10-08)

> **Статус:** B1 (хранилище, T7, уведомления, координатор, composition root) сделан в PR `stage-12-reminders-b`;
> B0, B3, B4, B6 и B7 — в PR `stage-12-reminders-b2` (см. «Итоги реализации части B2»), включая ручную проверку живого
> адаптера на одноразовом симуляторе (R3 закрыт с уточнением). Решения B1, не вошедшие в код: `SyncReport.stillPending` оставлен как есть (влияет только на
> лог `unrecognizedOutcomes`, лог пишется по `unrecognizedOutcomes`, а не по `stillPending`); снимок для пересчёта
> берёт `validVehicles()` (лишняя загрузка `serviceRecords` ради счётчика — R4, оптимизировать, если пересчёт станет
> заметен); тесты «сигнал во время пересчёта» ждут не паузы, а состояния (`needsAnotherRun` при закрытом `Gate`), поэтому ветку
> повтора проходят всегда; мутация «убрать повтор» роняет оба; фиксированные «сегодня» и календарь UI-режима
> (`UITestFixture.today`, `timeZoneIdentifier`) уже проброшены через `AppDependencies.init`. Ещё: сообщение `ValidationError.periodOutOfRange` должно называть границы (форма).

### Итоги реализации части B2 (2026-10-08): B0, B3, B4, B6, B7

Сделано: B0 (отдельным коммитом; `check.sh --only ui` до и после — en 11 / ru 14 зелёные), ViewModel формы и списка
правил, вью (`Features/MaintenanceRules/`, `MaintenanceSection`), `AccessibilityID`, строки с ru, `MaintenanceTests`,
`MaintenanceOverview` в GarageCore (сортировка правил машины, тесты на Linux), сообщение `periodOutOfRange` называет границы.

Отклонения и решения:

1. **`MaintenanceOverview.statuses`** в GarageCore вместо сортировки во вью: порядок (хуже статус → ближайшая дата →
   остаток пробега → `id`) тестируется на Linux. `MaintenanceSchedule.gregorian(matching:)` стала `public`.
2. **Фикстура UI-режима:** правила `ruleOverdue` (Land Cruiser, масло 12 мес / 10 000 км, запись ноябрь 2023 →
   просрочено), `ruleOK` (тормоза каждые 50 000 км, старт сегодня → в норме), `ruleSoon` (CB500X, осмотр 12 мес,
   старт за 346 дня до `today` → срок через 19 дней → скоро). Вместо «CB500X: цепь каждые 500 км → скоро» из плана:
   после правки порога «скоро» (A, п. 9: `min(soonKm, distanceKm / 2)`) при 50 км от последней записи правило «цепь» не
   даёт `dueSoon` ни при каком интервале, кроме ≤ 100 км.
3. **Не сделан UI-сценарий «каскад: удалить Transporter с правилом»:** в UI правило не видно, каскад закрыт тестами
   хранилища и координатора (план сам так оговаривал).
4. **Разрешение** спрашивается только для правила с интервалом по времени (по пробегу уведомление не придёт) — тест
   `mileageOnlyRuleDoesNotAskForPermission`.
5. **Экран машины:** пустое состояние «Нет записей» — строка секции истории, а не оверлей (оверлей перекрывал бы новую
   секцию «Обслуживание»). Ссылка на экран правил — строка «Напоминания» со счётчиком, без plural-строки «Все напоминания (N)».
6. **В форме правки есть «Удалить напоминание»** (как у записи), `delete()` и `ruleGone` из B3.
7. **Debug-лог адаптера:** `UserNotificationsReminderScheduler.replaceAll` в `#if DEBUG` пишет идентификатор и
   `nextTriggerDate()` каждого поставленного запроса и идентификаторы снятых (`category: Reminders`, `info`) — для
   сверки по `log stream` (решение пользователя; план исходно обходился без Debug-кода).
8. **UI-тест статуса:** элемент статуса — один accessibility-элемент (`.accessibilityElement(children: .ignore)`);
   иначе идентификатор достаётся и значку, и тексту, и запрос находит два совпадения.

9. **Разрешение на устройстве, где правила пришли синхронизацией** (находка swift-reviewer): форма — не единственный
   путь к правилам, а `RescheduleReminders` при `notDetermined` ничего не ставит. Экран правил показывает строку
   «Включить уведомления» (`MaintenanceRulesViewModel.canRequestAuthorization`, есть правила с интервалом по времени),
   она зовёт `requestAuthorization()` и просит координатор пересчитать набор. Баннер отказа перечитывается при
   открытии, при `active` и после закрытия формы (`onDismiss`).
10. **Локаль и календарь:** `MaintenanceRuleText` форматирует даты и километры через `Locale.current`/календарь
    пользователя, как и существующие строки записей (архитектура п. 3 — «переход по правилу бойскаута»); `\.locale`
    окружения в новых строках правил не используется — отклонение от B4, зафиксировано здесь. Срок считается в
    григорианском календаре, показывается в календаре пользователя.
11. **Не сделано (замечания ревью, оставлены):** подсказка «неизвестный интервал» в строке списка (форма её показывает);
    дублирование сообщения «интервал вне границ» (общее `ValidationError.message` и точное по единице в форме);
    «сегодня» на открытом экране обновляется только при перерисовке (смена `scenePhase` на экране правил её вызывает,
    на экране машины — нет). Баннер «Уведомления выключены» без UI-сценария: фейк UI-режима не бывает `denied`, покрыт
    тестами ViewModel.

**Проверка на зубы** (временные мутации, каждая откатывалась правкой, `git status` после отката чист):

| Мутация | Упавшие тесты |
|---|---|
| `MaintenanceStatus.accessibilityKey`: `.overdue` → `"ok"` | `testOverdueRuleIsShownOnVehicleScreenAndInList`, `testEditRuleChangesItsStatus` (en и ru) |
| `MaintenanceRuleFormViewModel.save`: ошибки черновика игнорируются, возвращается `true` | `testFormWithoutIntervalShowsErrorAndStaysOpen` (en и ru) |
| `MaintenanceRulesViewModel.delete` не вызывает порт | `testSwipeDeleteRuleCancelThenConfirm` (en и ru) |
| Запрос разрешения без проверки `notDetermined` и интервала по времени | `deniedPermissionIsNotAskedAgain`, `mileageOnlyRuleDoesNotAskForPermission` |
| **UI-режим использует настоящий `UserNotificationsReminderScheduler` вместо `RecordingReminderScheduler`** (`AppDependencies+UITesting.swift`) | `testFirstRuleIsSavedWithoutSystemPermissionAlert` (en): `MaintenanceTests.swift:80` «Форма не закрылась» (сохранение ждёт ответа на запрос разрешения, пока системный алерт перекрывает экран) и `:92` «Появился системный алерт» (`("1") is not equal to ("0")`) |

Замечание к последней строке: с первой попытки прогон убило ядро (SIGKILL, exit 137) при нехватке памяти с двумя
загруженными UI-симуляторами — это не результат мутации; после остановки ru-симулятора тест выполнился и упал с двумя
перечисленными проверками. После падения `xcodebuild` не завершился сам (завис, остановлен вручную): итоговый код возврата
этого прогона не получен, результат взят из лога тестов (`Executed 1 test, with 2 failures`).

ui-checker (ru, светлая/тёмная, крупный шрифт): исправлены подписи полей числа (`LabeledContent`), сжатие пикера единицы,
контраст «В норме» (вторичный цвет), отступ значка статуса, подсказка в пустом экране. Оставлено: дефисация сноски и разрыв
даты в «Последняя запись: …» на `accessibility-large` (косметика).

**Ручная проверка живого адаптера (2026-10-08).** Одноразовый симулятор `Garage Probe B2` (iPhone 17, iOS 27.2, ru_RU,
часовой пояс хоста UTC+4), Debug-сборка без `-GarageUITesting` (боевой `UserNotificationsReminderScheduler`), приложение
подписано на `log stream --predicate 'subsystem == "Garage" AND category == "Reminders"'`. Машина Rockhopper, интервал по
времени «каждые N месяцев», «последнее ТО» — 08.10.2026. Симулятор удалён после проверки.

| # | Действие | Ожидалось | Лог адаптера | Итог |
|---|---|---|---|---|
| 1 | Сохранить первое правило (12 мес.) | системный алерт разрешения после сохранения; запрос на 08.10.2027 10:00 местного | алерт показан (ru: «Приложение «Garage» запрашивает разрешение…»), нажато «Разрешить»; `status=2` (authorized) | алерт ✓ |
| 2 | Первые `add` сразу после выдачи разрешения | запрос поставлен | **`UNErrorDomain 2003 «Source is not authorized», UNAuthorizationStatus=Denied`** при `status=2`, повторяется при каждом пересчёте (22:38, 22:39, 22:40); после **перезагрузки симулятора** тот же код проходит | см. «Находка» ниже |
| 3 | Первое поставленное уведомление (после перезагрузки) | `maintenance-rule.<UUID>`, 10:00 местного | `Scheduled maintenance-rule.DE677ADD… fires at 2027-10-08 06:00:00 +0000` = 10:00 UTC+4; `1 wanted, 0 removed, 1 added` | ✓ |
| 4 | Повторный пересчёт без изменений | набор не меняется | `1 wanted, 0 removed, 0 added` | ✓ идемпотентность |
| 5 | Правка интервала 12 → 6 мес. | тот же id, новая дата | `Scheduled maintenance-rule.DE677ADD… fires at 2027-04-08 06:00:00 +0000` = 10:00 UTC+4; `1 wanted, 0 removed, 1 added` (замена, без дубля) | ✓ |
| 6 | Удаление правила свайпом + подтверждение | запрос снят | `Removed maintenance-rule.DE677ADD…`; `0 wanted, 1 removed, 0 added` | ✓ |
| 7 | Новое правило (12 мес.), затем удаление машины (каскад) | запрос поставлен, затем снят | `Scheduled maintenance-rule.8987382D… fires at 2027-10-08 06:00:00 +0000`; после удаления машины `Removed maintenance-rule.8987382D…`, `0 wanted, 1 removed, 0 added` | ✓ каскад → пересчёт → запрос снят |
| 8 | Второе правило в уже разрешённом приложении | без алерта | алерта нет, форма закрылась сразу | ✓ |

**Находка (строка 2).** На только что созданном симуляторе после «Разрешить» `notificationSettings().authorizationStatus`
уже `authorized`, алерт и центр уведомлений включены, но `UNUserNotificationCenter.add` отвечает 2003 `Denied` — и так минуты
подряд, до перезагрузки симулятора. Это согласуется с пробами 0.1/0.2 (свежий симулятор ведёт себя странно: алерт приходит
с задержкой ~25–35 с). Считаем артефактом демона уведомлений симулятора, а не ошибкой приложения: `RescheduleReminders`
вызывает `replaceAll` только при `authorized`, ошибка логируется (`Reminder recalculation failed`) и не ломает сохранение
правила, а следующий пересчёт (любое сохранение или `active`) повторяет попытку. **Не проверено на реальном устройстве:**
повторяется ли это там; если да — нужен повтор `add` после выдачи разрешения. Для Debug-проверок на свежем симуляторе: после
выдачи разрешения перезагрузить симулятор (`xcrun simctl shutdown` / `boot`).

**Побочное наблюдение.** `numberPad` принимает буквы с аппаратной раскладки симулятора (в поле периода попало «ышч12»);
валидация черновика (`parseInteger`) такой ввод отклоняет сообщением «Введите корректное число», сохранение невозможно.

**R3 закрыт с уточнением:** живой `UNUserNotificationCenter` проверен вручную (разрешение, постановка с датой 10:00
местного, замена при правке, идемпотентность, снятие при удалении правила и машины). Остаются непроверенными: доставка баннера
(проба 0.6 показала её на симуляторе, но с этим адаптером не гонялась), смена часового пояса при уже стоящем запросе
(R14), поведение `add` после выдачи разрешения на реальном устройстве (находка выше).
