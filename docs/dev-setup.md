# Окружение разработки

Редко нужные детали, вынесенные из `CLAUDE.md` (чтобы тот оставался коротким). Команды — как были, без изменений.

## Toolchain

Нужен Xcode 27.2 (beta). В этом репозитории `DEVELOPER_DIR` задан в `.claude/settings.local.json` — в сессии Claude Code его не экспортируют и не ставят перед командой. В обычном терминале:

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer
```

Без него `swift test` падает с `plugin for module 'TestingMacros' not found`.

## Один UI-тест

Запускается по схеме, а не через `-xctestrun` (он игнорирует `-testLanguage`), после `build-for-testing` в `.build/ui`. Проще всего — `scripts/check.sh --test ui <Target/Suite/test>` (язык из `$UI_LANG`, по умолчанию `en`). Вручную:

```sh
TEST_RUNNER_GARAGE_EXPECTED_LANGUAGE=en xcodebuild test-without-building -project Garage.xcodeproj -scheme GarageUITests \
  -derivedDataPath .build/ui -destination 'id=<udid of Garage UI en>' -testLanguage en -testRegion US \
  -only-testing:GarageUITests/VehicleTests/testAddVehicleShowsErrorsThenSaves
```

Симуляторы `Garage UI en` и `Garage UI ru` создаёт `scripts/check.sh --only ui` при первом запуске (UDID — `xcrun simctl list devices`).

### Таймауты и память

- `scripts/check.sh --only ui` и `--test ui` запускают `xcodebuild test-without-building` с `-test-timeouts-enabled YES`, лимитом 120 с на тест по умолчанию и 240 с максимум.
- Таймаутов XCTest мало: после упавшего теста сам `xcodebuild` может не завершиться (так было при мутации в B2 этапа 12). Поэтому на весь прогон каждого языка есть внешний предел — `UI_DEADLINE` секунд (по умолчанию 900), сторож убивает `xcodebuild` и печатает `ui: … did not finish in …s`.
- `UI_SERIAL=1` гонит en и ru по очереди. На Mac с малой памятью два загруженных UI-симулятора не помещаются: ядро убивает процесс сигналом 9 (exit 137). Здесь `UI_SERIAL=1` стоит в `.claude/settings.local.json` → `env`.

## Локальный сервер для сквозных проверок

```sh
TMP=<scratchpad>/e2e; mkdir -p $TMP; openssl rand -hex 16 > $TMP/secret
GARAGE_DB_PATH=$TMP/garage.sqlite GARAGE_SETUP_SECRET=$(cat $TMP/secret) \
  swift run --package-path Server GarageServer serve --hostname 127.0.0.1 --port 8080   # запускать в фоне
```

В приложении на симуляторе — `http://127.0.0.1:8080` (обычный http принимается только для localhost) и секрет из `$TMP/secret`. Для чистой базы сначала удалить приложение: `xcrun simctl uninstall <udid> <bundle id>`. Секрет установки приложение не сохраняет.

## CI

`.github/workflows/ci.yml` (push в master, pull request, ручной запуск): одна задача `linux` в контейнере `swift:6.4-noble` (тот же toolchain, что у локального Xcode 27.2, Swift 6.4) с установленным `jq`. Шаги — `scripts/check.sh --only architecture`, `--only linux` и `--only strings`, каждый отдельно. Секция `ios` (Xcode, симулятор) идёт только локально. Каталоги `.build` пакетов GarageCore, GarageAPI, GarageSync и Server кэшируются по хэшу `Package.resolved` + `Package.swift` (у локальных пакетов `Package.resolved` нет). `scripts/test-hooks.sh` печатает `SKIP` для двух кейсов format-xcproj, которым нужен `xcprojformatter` (только macOS).
