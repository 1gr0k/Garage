# Этап 8: CI на GitHub Actions

## Контекст

CI в репозитории нет. Правила CLAUDE.md требуют, чтобы GarageCore, GarageAPI, GarageSync (и Server) собирались на Linux, но это ни разу не проверялось: локально только macOS + Xcode 27.2 beta (Swift 6.4), Docker нет. Цель — job `linux` в GitHub Actions, который гоняет `scripts/check.sh --only architecture|linux|strings` в официальном образе Swift, плюс правки, без которых это не соберётся/не пройдёт на Linux. Секция `ios` остаётся только локальной.

Решения, согласованные с пользователем:
- проверка — через ветку `stage-8-ci`, push в origin и PR в master; падения CI чиним в той же ветке до зелёного; push только этой ветки, без force-push и push в master;
- образ `swift:6.4-noble` (как локальный тулчейн); если его нет — последний релизный, расхождение версий записать в CLAUDE.md;
- если swift-format в CI и локально дают противоречивые замечания — не подгонять код по кругу, остановиться и сообщить; `--strict` не ослаблять.

## 1. Workflow `.github/workflows/ci.yml`

- `on`: push в master, pull_request, workflow_dispatch. `concurrency` по ref с `cancel-in-progress`; `permissions: contents: read`.
- Job `linux`: `runs-on: ubuntu-latest`, `container: swift:6.4-noble`.
- Шаги: установка `jq` → checkout → кэш `.build` всех четырёх пакетов (ключ по `Package.resolved` + `Package.swift`: у локальных пакетов нет Package.resolved) → `swift format --version` → `check.sh --only architecture`, `--only linux`, `--only strings` отдельными шагами.

## 2. `scripts/check.sh` без CLAUDE.local.md и DEVELOPER_DIR

DEVELOPER_DIR в check.sh не используется, CLAUDE.local.md читается только в секции `ios`. Добавить понятные предусловия: `ios` — нужен `xcodebuild` (ошибка, не тихий skip), `strings` — нужен `jq`, `architecture` — нужен `swift format`. В шапке — что идёт в CI, что только локально.

## 3. `scripts/test-hooks.sh` — переносимость

- `DEVELOPER_DIR` по умолчанию только на Darwin.
- Кейсы `format-xcproj.sh`, вызывающие `xcprojformatter`, без форматтера печатают `SKIP` и не считаются падением; остальные кейсы идут везде.

## 4. Linux-исправления в коде (финальный список — по логам CI)

- `URLError` на Linux — в FoundationNetworking: тесты GarageSync (`ReceiptTests`, `SyncEngineTests`, `FailureAndCancellationTests`) импортируют его через `#if canImport(FoundationNetworking)`, как уже делают исходники.
- Остальное (URLSession async API на corelibs-foundation, Sendable-различия, Server/Vapor/swift-crypto) — по логу CI.

## 5. Документация

Раздел `## CI` в CLAUDE.md: что проверяется в CI, что только локально, образ и кэш.

## Проверка

- macOS: `scripts/check.sh` (все секции).
- CI: job `linux` зелёный на PR; в логе — `SKIP` двух кейсов format-xcproj, версия swift-format, `swift test` четырёх пакетов.
