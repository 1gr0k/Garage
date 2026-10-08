---
name: new-feature
description: Чек-лист новой фичи приложения по слоям (use case → репозиторий → ViewModel → View → composition root) с тестами каждого слоя. Используй, когда нужно добавить экран, сценарий, действие пользователя или фичу (add a new feature, screen, flow, edit/delete action, use case, view model) в этом проекте.
---

# Новая фича по слоям

Чек-лист. Правила слоёв и сквозной пример «Добавить запись» — только в `docs/architecture.md`, здесь они не повторяются. Прочитай его перед началом.

## План

Фича больше одного файла — сначала план в `docs/plans/stage-<N>-<имя>.md` (образцы: `stage-9-edit-delete-records.md`, `stage-11-ui-tests.md`), потом код. Структура:

1. **Контекст** — зачем, что уже есть, цель списком.
2. **Решения** — нумерованные, каждое с причиной и отвергнутой альтернативой. На них ссылаются ревью (`[contradicts plan]`) и код.
3. **Разбор** — что меняется по слоям (шаги 2–8 ниже); если часть работы можно сделать независимо (например, чистый GarageCore в облаке без Swift-окружения) — делить на **часть A** и **часть B** с отдельными PR; B начинается после мержа A.
4. **Сводка «пункт → тесты»** — таблица: каждый пункт плана → какие тесты его покрывают. Пункт без теста — явно, с причиной.
5. **Риски** — что может не сработать и что делаем тогда.

Правила:

- **Шаг 0 «Разведка → стоп».** Если в плане есть неизвестные (поведение API платформы, формат файла, «а соберётся ли»), первым шагом идут пробы в копии репозитория или в scratchpad, не в коммитах. Результаты — в план (и в `docs/xcproj-notes.md`, если про проект). После разведки **остановись и покажи пользователю итог**, не продолжай к коду, пока решения не пересмотрены с учётом найденного.
- **Отклонения идут обратно в план.** Реализация разошлась с планом — поправь план в том же коммите (решение, шаг или риск) и пометь, что изменилось; план — описание того, что сделано, а не того, что хотелось.
- Статус плана: строка `**Статус: выполнен** — PR` ставится в `/finish-stage`, вручную не нужна.

## 1. Нужен ли use case

Ответь до кода: **есть ли правило или оркестрация?** (валидация, инвариант, несколько портов, порядок шагов, маппинг ошибок)

| | Да | Нет |
|---|---|---|
| Пример | `AddServiceRecord`, `UpdateServiceRecord`, `RegisterDevice`, `ForgetDevice` | `ReceiptImagePreparing`, `SyncService.status()`, удаление записи через `ServiceRecordEditing.delete` |
| ViewModel зависит от | use case (`struct` из GarageCore) | протокола порта напрямую |
| Шаг 3 | делать | пропустить |

Если ответ неочевиден (правило может жить и во VM, и в домене) — спроси пользователя (AskUserQuestion).

Только показ данных без записи — use case и ViewModel не нужны: `@Query` + маппинг из `DisplayMapping` (шаг 6).

## 2. Порт (GarageCore)

- [ ] Протокол в `Packages/GarageCore/Sources/GarageCore/Repositories/`: `Sendable`, методы `async throws`, ошибки доменные (`RepositoryError`, `SyncFailure`), без типов SwiftData/HTTP. Можно расширить существующий протокол.
- [ ] Только `import Foundation`.

## 3. Use case (GarageCore) — если нужен

- [ ] `public struct <Verb><Noun>: Sendable` в `Sources/GarageCore/UseCases/`, зависимости через `init`, один метод `execute(…) async throws`.
- [ ] Тесты в `Tests/GarageCoreTests/UseCases/` с фейками из `Fakes.swift` (добавь фейк нового порта туда): правило срабатывает до порта, успешный путь, проброс/маппинг ошибок.
- [ ] `swift test --package-path Packages/GarageCore`.

## 4. Адаптер (GarageStorage)

- [ ] Реализация порта в `Packages/GarageStorage/Sources/GarageStorage/Adapters/` поверх SwiftData (`ModelContainer` через `init`). Изменение данных ставится в очередь синхронизации **в том же сохранении** (`SyncQueue.enqueueUpsert` / `enqueueDelete`, как `ServiceLog.add`).
- [ ] Ошибки хранилища → доменные (`RepositoryError`).
- [ ] Модель изменилась → bump `GarageStore.schemaVersion`.
- [ ] Тест в `Tests/GarageStorageTests/AdapterTests.swift` на in-memory контейнере: данные записаны, операция в очереди, ошибки маппятся.
- [ ] `(cd Packages/GarageStorage && xcodebuild test -scheme GarageStorage -destination '<CLAUDE.local.md>')`.

## 5. ViewModel (app)

- [ ] `Garage/Features/<Feature>/<Feature>ViewModel.swift`: `@Observable final class`, MainActor по умолчанию таргета. Импорты: `Foundation`, `Observation`, `GarageCore` — без `SwiftData`/`GarageStorage`/`GarageSync`/`GarageAPI`.
- [ ] Асинхронную работу запускает VM; отменяемые/долгие задачи хранит VM; устаревшие результаты отсекает generation-счётчиком; `CancellationError` — не ошибка для пользователя.
- [ ] Тесты в `GarageTests/<Feature>ViewModelTests.swift` (Swift Testing) с фейками из `GarageTests/Fakes.swift`: состояние до/после, ошибки → состояние для показа, гонки (повторное нажатие, отмена).

## 6. View (app)

- [ ] `Garage/Features/<Feature>/<Feature>View.swift` — тонкая: биндинги к VM, вызовы методов VM. Чтение для показа — `@Query` + `validVehicles()` / `validRecords()` (новый маппинг — в `DisplayMapping.swift`).
- [ ] Во вью нет `modelContext`, `.insert(`, `context.save()`, `ServiceLog`/`SyncQueue`/…, `import GarageSync`/`GarageAPI`.
- [ ] Интерактивные элементы и значимые тексты получают `.accessibilityIdentifier(AccessibilityID.<Экран>.<элемент>)`; строки идентификаторов — в `GarageUIIdentifiers/AccessibilityID.swift`, вёрстка не меняется.
- [ ] Новая папка в `Garage/` подхватывается сама (синхронизируемая папка) — `project.xcproj` не трогать.

## 7. Composition root

- [ ] Адаптер и use case создаются в `Garage/App/AppDependencies.swift`; наружу — фабрика `make<Feature>ViewModel(…)` (или общий экземпляр, если состояние одно на приложение). Платформенные значения — замыканием.

## 8. Строки

- [ ] Все новые строки — сразу в `Garage/Localizable.xcstrings` с `ru` (`state: translated`; для количеств — plural one/few/many/other). Пользовательские данные — `Text(verbatim:)`.

## 9. Проверка

- [ ] `scripts/check.sh` целиком (architecture, linux, ios, strings).
- [ ] Сценарий фичи в `GarageUITests/` (по идентификаторам, без текстов из каталога) и `scripts/check.sh --only ui` проходит на en и ru; нужны данные — расширь фикстуру в `GarageUIIdentifiers/UITestFixture.swift` и `Garage/App/AppDependencies+UITesting.swift`.
- [ ] **Проверка на зубы.** Для каждого нового теста (юнит, адаптер, UI) назови строку продакшен-кода, без которой он упадёт, и убедись: временно сломай её (инверсия условия, удаление вызова — правкой в scratchpad-копии или с откатом `git checkout -- <файл>`) и прогони тест — он должен покраснеть. Не покраснел — тест ничего не проверяет. Докстринг и имя теста не обещают больше, чем проверяют ассерты; проверка «не произошло X» имеет парный положительный контроль («X происходит в таком же сценарии»).
- [ ] ui-checker — только визуальная проверка нового UI (обрезка ru-строк, вёрстка, пустые состояния), не регрессия сценариев.
- [ ] swift-reviewer на diff.
- [ ] Появился новый тип правил/слой — обнови `docs/architecture.md`.

## Особенности платформы

Грабли, на которых проект уже обжигался; учитывай при плане и тестах.

- **`confirmationDialog` — popover, без кнопки «Отмена».** В accessibility-дереве это `Popover` → `Sheet` (label = заголовок диалога) и `PopoverDismissRegion`. В UI-тесте отмена — тап по `app.otherElements["PopoverDismissRegion"]`, а не по кнопке; искать кнопку «Отмена» по тексту нельзя (и тексты зависят от языка).
- **Заголовки модальных форм — inline** (`.navigationBarTitleDisplayMode(.inline)`), кнопки с ролями `.close` / `.confirm`. Ru-строки длиннее en: проверь вёрстку формы на ru (ui-checker).
- **Swift Testing недоступен в UI-test bundle** (`Unable to resolve module dependency: '_Testing_Unavailable'`): `GarageUITests` — XCTest, остальные тесты проекта — Swift Testing. Не переносить логику, которую можно проверить юнит-тестом, в UI-тесты.
- **UI-тесты ищут элементы только по `AccessibilityID`**, не по тексту каталога; язык задаётся `-testLanguage` при запуске **по схеме** (`-scheme GarageUITests`), а не через `-xctestrun` — он `-testLanguage` игнорирует.
- **`PhotosPicker` на чистом симуляторе недоступен** — замену фото чека XCUITest не проверит; это зона ui-checker.
