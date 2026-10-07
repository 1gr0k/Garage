---
name: new-feature
description: Чек-лист новой фичи приложения по слоям (use case → репозиторий → ViewModel → View → composition root) с тестами каждого слоя. Используй, когда нужно добавить экран, сценарий, действие пользователя или фичу (add a new feature, screen, flow, edit/delete action, use case, view model) в этом проекте.
---

# Новая фича по слоям

Чек-лист. Правила слоёв и сквозной пример «Добавить запись» — только в `docs/architecture.md`, здесь они не повторяются. Прочитай его перед началом.

## 1. Нужен ли use case

Ответь до кода: **есть ли правило или оркестрация?** (валидация, инвариант, несколько портов, порядок шагов, маппинг ошибок)

| | Да | Нет |
|---|---|---|
| Пример | `AddServiceRecord`, `RegisterDevice`, `ForgetDevice` | `ReceiptImagePreparing`, `SyncService.status()` |
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
- [ ] Новая папка в `Garage/` подхватывается сама (синхронизируемая папка) — `project.xcproj` не трогать.

## 7. Composition root

- [ ] Адаптер и use case создаются в `Garage/App/AppDependencies.swift`; наружу — фабрика `make<Feature>ViewModel(…)` (или общий экземпляр, если состояние одно на приложение). Платформенные значения — замыканием.

## 8. Строки

- [ ] Все новые строки — сразу в `Garage/Localizable.xcstrings` с `ru` (`state: translated`; для количеств — plural one/few/many/other). Пользовательские данные — `Text(verbatim:)`.

## 9. Проверка

- [ ] `scripts/check.sh` целиком (architecture, linux, ios, strings).
- [ ] ui-checker: сценарий фичи в симуляторе, на русском и английском.
- [ ] swift-reviewer на diff.
- [ ] Появился новый тип правил/слой — обнови `docs/architecture.md`.
