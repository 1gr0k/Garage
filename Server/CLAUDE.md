# CLAUDE.md (Server)

Сервер синхронизации Garage на Vapor. Отдельный SwiftPM-пакет, в `Garage.xcodeproj` не подключается. Контракт — `docs/api.md`.

## Команды

```sh
swift build --package-path Server
swift test --package-path Server
swift test --package-path Server --filter deleteWinsOverEdit   # один тест
GARAGE_DB_PATH=/path/garage.sqlite GARAGE_SETUP_SECRET=... swift run --package-path Server GarageServer serve
```

## Переменные окружения

- `GARAGE_DB_PATH` — путь к SQLite-файлу (обязательна; в тестах используется in-memory база).
- `GARAGE_SETUP_SECRET` — секрет регистрации устройств (обязателен; без него старт падает с понятной ошибкой).

## Архитектура

- `Sources/GarageServer/main.swift` — только entrypoint. Вся логика в цели `App`.
- `ChangeWriter` (actor) — единственный писатель строк `entities` и счётчика версий. Каждый элемент push — одна транзакция, следующий начинается после коммита предыдущего.
- Валидация содержимого DTO — `Validation.swift`, строго через инициализаторы `GarageCore`.
- Даты: сервер хранит и отдаёт миллисекунды как есть; округление при кодировании делает `APICoding` (GarageAPI), обходных путей на сервере нет.

## Сервер рассчитан на один экземпляр процесса

Последовательность версий держится на in-process `actor ChangeWriter` и SQLite-файле. Второй процесс или реплика на ту же БД нарушит порядок коммитов (pull сможет пропустить версию), поэтому горизонтальное масштабирование запрещено.

## Правила

- Контракт — `docs/api.md`; сервер его не меняет (вопросы — в отчёт).
- DTO только из `GarageAPI`, валидация через `GarageCore`; своих проверок сверх домена нет.
- Сервер должен собираться на Linux: `Crypto` (swift-crypto) вместо CryptoKit, без Apple-only фреймворков.
- Golden JSON не копировать: тесты строят запросы и разбирают ответы через DTO.
- Записи в `entities` и счётчик идут только через `ChangeWriter`.
- Пакет не подключать к `project.xcproj`.
- Скретч-файлы и отладочные БД — только в scratchpad, не в репозитории.
- macOS: не использовать `sed -i`; команды `timeout` нет.

## Definition of done

1. `swift build --package-path Server` и `swift test --package-path Server` — зелёные.
2. Регрессия: `swift test` для `GarageCore`, `GarageSync`, `GarageAPI` — зелёные.
3. Ручной smoke при изменении эндпоинтов: `swift run` с временной БД, `curl` на `POST /v1/devices` → `POST /v1/changes` → `GET /v1/changes`.
4. `git status`: изменения только в `Server/` (и в плане `docs/plans/`, если он правился).
