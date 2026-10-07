# Этап 11: UI-тесты (XCUITest) для регрессии на en и ru

## Контекст

Сейчас вью проверяет только ui-checker: агент запускает приложение в симуляторе, тапает по координатам
со снимков и отчитывается текстом (`.claude/agents/ui-checker.md`). Сценарии B6 этапов 9 и 10 прогоняются
так вручную на `en` и `ru`. Это медленно, недетерминированно (координаты, демо-данные установки,
состояние Keychain) и не ловит регрессии между этапами.

Этап — инфраструктура, а не фича: use case'ов, портов, адаптеров и ViewModel нет. По чек-листу
`new-feature` затронуты только composition root (п. 7), вью (п. 6, только идентификаторы доступности)
и проверка (п. 9). Новых пользовательских строк нет: идентификаторы — не текст для пользователя и в
каталог не идут.

Цель:

- таргет `GarageUITests` (XCUITest) с регрессионными сценариями B6 этапа 10 и правки/удаления записей
  этапа 9; сценарии не зависят от языка;
- отдельные проверки ru-текстов, которые уже ломались: склонения записей и год без разделителей тысяч;
- запуск на `en` и `ru` параллельно на двух симуляторах одной сборкой;
- секция `ui` в `scripts/check.sh`;
- ui-checker остаётся только для визуальной проверки.

Всё делается локально: нужны Xcode и симулятор, в CI (Linux) этап не попадает.

## Решения

1. **XCTest, а не Swift Testing.** `XCUIApplication` работает в `XCTestCase`; остальные тесты проекта на
   Swift Testing, и это исключение. На шаге 0 проверить, поддерживает ли Xcode 27.2 UI-автоматизацию из
   Swift Testing (`@Test` + `XCUIApplication`). Если поддерживает и запуск стабилен — взять Swift Testing
   ради единообразия, иначе XCTest. Выбор записать в `docs/xcproj-notes.md`.

2. **Таргет без хоста.** UI-тесты идут в отдельном процессе-раннере и управляют `Garage.app` снаружи.
   `TEST_HOST`/`BUNDLE_LOADER` не нужны. Ловушка `GarageTests` с двумя копиями `GarageCore` здесь
   не действует (процессы разные), поэтому `GarageCore` можно линковать в тестовый таргет (решение 4).

3. **Тестовый режим запуска — только в composition root и только `#if DEBUG`.** Аргумент запуска
   (`-GarageUITesting`) переключает `GarageApp` на `AppDependencies.bootstrapForUITesting()`:
   - SwiftData в памяти: `AppBootstrap.prepare(inMemory: true, defaults:)` — параметры уже есть,
     GarageStorage не меняется;
   - изолированный `UserDefaults`: `UserDefaults(suiteName: "Garage.UITests")` и
     `removePersistentDomain(forName:)` перед каждым запуском. Флаг сида `SampleSeeder` из обычной
     установки не мешает, и каждый запуск сидит заново;
   - свежий сид: демо-машины (`SampleSeeder` через `prepare`), затем фикстура записей через порт
     `ServiceRecordRepository.add` адаптера `SwiftDataServiceRecordRepository`. Это обычный путь записи;
     в очередь синхронизации ставятся изменения, но отправлять их некому;
   - синхронизация выключена: вместо `KeychainCredentialsStore` — `InMemoryCredentialsStore` (пустой, в
     памяти; Keychain симулятора переживает переустановку, и токен из ручного прогона включил бы sync),
     вместо `SyncAPIDeviceRegistrar` — `DisabledDeviceRegistrar` (бросает `SyncFailure.network`, в сеть
     не ходит). Без токена `SyncViewModel.isRegistered == false`, кнопка «Sync Now» неактивна;
     автоматического sync в приложении нет.

   Файлы: `Garage/App/AppDependencies+UITesting.swift` (всё содержимое в `#if DEBUG`) и выбор bootstrap в
   `GarageApp.swift`. В Release кода режима нет, аргумент ничего не делает. `AppDependencies.init` уже
   принимает `credentials` и `registrar` — менять его не нужно.

4. **Идентификаторы и фикстура — в общей синхронизируемой папке `GarageUIIdentifiers/`** с
   `"target-membership": ["Garage", "GarageUITests"]`. `target-membership` в формате — массив, так что
   одна папка может входить в два таргета (проверить на шаге 1; в бинарнике `xcprojformatter` есть ещё
   `membership-exceptions`). Строки идентификаторов существуют в одном месте, приложение и тесты
   компилируют один и тот же файл.
   - `AccessibilityID.swift` — `nonisolated enum AccessibilityID` с вложенными пространствами по экранам
     (`VehicleList.add`, `VehicleList.row(_ id: UUID)`, `VehicleList.rowSubtitle(_:)`, `VehicleForm.year`,
     `VehicleForm.yearError`, `ServiceRecordForm.deleteRecord`, …). Строки вида `vehicleList.row.<uuid>`.
     Компилируется и в Release: вью используют его всегда.
   - `UITestFixture.swift` (`#if DEBUG`) — аргумент запуска и описание фикстуры:
     `launchArgument = "-GarageUITesting"`; число записей по машине
     (`Vehicle.SampleID.landCruiser: 1`, `.transporter: 3`, `.cb500x: 5`, `.rockhopper: 0` — для склонений
     one/few/many и нуля); фиксированные UUID записей, на которых работают сценарии (`recordToEdit`,
     `recordWithReceipt`, `recordToDelete`). Файл импортирует `GarageCore` (ради `Vehicle.SampleID`),
     поэтому `GarageUITests` линкует `GarageCore` через `package-product-members`. UUID демо-машин
     не дублируются.
   - Сборка самих записей фикстуры (`ServiceRecord`, байты чека — PNG 1×1 из `UIGraphicsImageRenderer`)
     живёт в `AppDependencies+UITesting.swift`, а не в общей папке: тестам нужны только идентификаторы и
     ожидаемые количества.
   - Запасной вариант, если папка в двух таргетах не работает: локальный пакет `Packages/GarageUIIdentifiers`
     (скилл `add-local-package`), который линкуют оба таргета.

5. **Тесты находят элементы только по идентификаторам.** Не по тексту кнопок и не по индексам.
   Пользовательские данные (марка, год, пробег) — тоже данные, а не перевод, поэтому их можно сравнивать
   на любом языке (поле марки содержит `Toyota`). Тексты из каталога проверяют только тесты из
   `LocalizedTextTests` (решение 7).

6. **Запуск на двух языках без схем и тест-планов.** Флаги в текущем `xcodebuild` (Xcode 27.2, `27B5028f`)
   есть — проверено `xcodebuild -help`: `-testLanguage` (ISO 639-1), `-testRegion` (ISO 3166-1),
   `-xctestrun`, `-only-testing`/`-skip-testing`, `-resultBundlePath`, `-parallel-testing-enabled`.
   Порядок:
   1. `xcodebuild build-for-testing -project Garage.xcodeproj -scheme GarageUITests
      -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ui` — один раз;
   2. два фоновых `xcodebuild test-without-building -xctestrun .build/ui/Build/Products/GarageUITests_*.xctestrun
      -destination id=<udid> -testLanguage <en|ru> -testRegion <US|RU> -resultBundlePath .build/ui/<lang>.xcresult
      -parallel-testing-enabled NO`, затем `wait` обоих.

   `.build/` уже в `.gitignore`. Собственный `-derivedDataPath` делает проверку «с чистого DerivedData»
   однозначной (`rm -rf .build/ui`) и не трогает четыре `Garage-*` в `~/Library/Developer/Xcode/DerivedData`.

   **Симуляторы.** Два устройства `Garage UI en` и `Garage UI ru` с типом и рантаймом устройства из
   `CLAUDE.local.md` (`iPhone 17`, UDID там же). `xcrun simctl clone` требует выключенный исходный
   симулятор, а `iPhone 17` обычно запущен (сейчас — `Booted`); кроме того, клон переносит установленные
   приложения и Keychain. Поэтому скрипт ищет устройства по имени и, если их нет, создаёт
   `xcrun simctl create "<имя>" <devicetype> <runtime>`, где тип и рантайм взяты из
   `simctl list -j devices` для исходного UDID. Это «клон по конфигурации»: тот же экран и iOS, чистое
   состояние. Если на шаге 0 окажется, что `clone` работает и с запущенным источником, допустимо и он, но
   тогда перед прогоном удалить приложение (`simctl uninstall`). Имена устройств — в `CLAUDE.local.md`.

7. **Проверки ru-текстов — отдельный класс `LocalizedTextTests`** с явным
   `launchArguments += ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]`. От `-testLanguage` они
   не зависят и детерминированы. Запускаются только в ru-проходе: en-проход вызывается с
   `-skip-testing:GarageUITests/LocalizedTextTests`. Ожидаемые строки в тесте написаны литералами ru: это
   проверка того, что увидит пользователь. Так golden-примеры API не копируются: каталог — не golden-источник
   `docs/api.md`.

8. **`check.sh --only ui`, но не в общем прогоне.** Секция медленная (сборка + два симулятора). Список
   по умолчанию остаётся `architecture linux ios strings`; `ui` принимается только через `--only`.
   В CI не идёт.

## Шаги

### 0. Разведка (до правок, результаты — в `docs/xcproj-notes.md`)

- `xcodebuild -help`: `-testLanguage`/`-testRegion` — есть (сделано при планировании).
- Работают ли `-testLanguage`/`-testRegion` вместе с `test-without-building -xctestrun`, а не только со
  `-scheme`: проверочный тест печатает `Locale.preferredLanguages` приложения (через видимый элемент или
  лог) на прогоне `ru`. Если флаг с `-xctestrun` игнорируется — вариант
  `test-without-building -scheme GarageUITests -derivedDataPath .build/ui`. Если не работает и он —
  язык передаётся через окружение раннера `TEST_RUNNER_GARAGE_UI_LANGUAGE=ru` (xcodebuild снимает
  префикс `TEST_RUNNER_`), и тест сам добавляет `-AppleLanguages`.
- `xcrun simctl clone` с запущенным источником — ошибка или нет (решение 6).
- Swift Testing + `XCUIApplication` (решение 1).
- `confirmationDialog` в XCUITest: popover с `PopoverDismissRegion` (ожидается, как на этапах 9 и 10) или
  лист — от этого зависит `dismissDialog()` (см. «Риски»).
- Как формат описывает UI-test bundle. В `xcprojformatter` из тестовых ключей есть только
  `test-host-target` (`strings` по бинарнику; значения `product-type` форматтер не проверяет — он
  валидирует только схему, а неизвестные ключи молча выбрасывает). Кандидаты, по порядку:
  - `"product-type": "bundle.ui-testing"` (полное имя `com.apple.product-type.bundle.ui-testing`, по
    аналогии с `bundle.unit-test`; короткое `ui-testing` по опыту `unit-test` не сработает);
  - целевое приложение — `"test-host-target": "Garage"`; проверить по
    `xcodebuild -showBuildSettings -scheme GarageUITests`, выставляется ли `TEST_TARGET_NAME = Garage`
    (для UI-тестов нужен он, а не `TEST_HOST`). Если нет — задать `TEST_TARGET_NAME` в build-settings явно;
  - `"dependencies": ["Garage"]` — по уроку `GarageTests`: без него чистая сборка не знает порядок;
  - `TEST_HOST`/`BUNDLE_LOADER` не задавать: если `test-host-target` их выставит, тесты попытаются
    загрузиться в приложение. Проверить в `-showBuildSettings`, при необходимости обнулить.

### 1. Таргет `GarageUITests` в `project.xcproj`

По методу `docs/xcproj-notes.md`:

1. Правка вручную (Edit):
   - `files`: `{ "kind": "folder", "path": "GarageUITests", "target-membership": ["GarageUITests"] }`,
     `{ "kind": "folder", "path": "GarageUIIdentifiers", "target-membership": ["Garage", "GarageUITests"] }`,
     продукт `<PRODUCTS>/GarageUITests.xctest` (`wrapper.cfbundle`, новый `id`) в группе Products;
   - `targets`: `GarageUITests`, `id` `000000000000000300000000`, `product-type` и связь с приложением по
     шагу 0, `dependencies: ["Garage"]`, `build-phases: ["compile-sources", "frameworks"]`,
     `package-product-members`: `GarageCore` (фаза `frameworks`), build-settings как у `GarageTests`
     (`GENERATE_INFOPLIST_FILE`, `PRODUCT_BUNDLE_IDENTIFIER = devplaceholder.GarageUITests`, `SDKROOT`,
     `SUPPORTED_PLATFORMS`, `SWIFT_VERSION`, `TARGETED_DEVICE_FAMILY`), но **без**
     `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: XCTest-методы UI-тестов и так `@MainActor`, а файл из
     общей папки должен одинаково компилироваться в обоих таргетах (поэтому `nonisolated enum`).
2. `$DEVELOPER_DIR/usr/bin/xcprojformatter --update Garage.xcodeproj`; проверить, что ни один ключ не
   выброшен (`git diff`).
3. `xcodebuild -project Garage.xcodeproj -list` — схема `GarageUITests` появилась.
4. `rm -rf .build/ui`, затем `build-for-testing` (решение 6) и один пустой тест `testLaunches`:
   приложение стартует, раннер его видит.
5. Отрицательные проверки, как для `GarageTests`: без `dependencies` на чистом DerivedData; без продукта в
   `files`; общая папка — оба таргета видят `AccessibilityID`, а `Garage.app` в Release собирается без
   `UITestFixture` (`#if DEBUG`).
6. Новый раздел в `docs/xcproj-notes.md` — «UI-test таргет (`GarageUITests`)»: рабочий JSON,
   `product-type`, как задаётся целевое приложение, что выставляет `test-host-target` для UI-bundle,
   папка в двух таргетах (или почему пакет), что `-testLanguage` работает с `-xctestrun` (или нет).

### 2. Общая папка `GarageUIIdentifiers/`

- `AccessibilityID.swift`, `UITestFixture.swift` (решение 4). Комментарии — по-русски.
- `scripts/check.sh` → `swift format lint`: добавить пути `GarageUITests GarageUIIdentifiers`.
- Правило слоёв: в общей папке нет SwiftUI/SwiftData/GarageStorage — только `Foundation` и `GarageCore`
  (новое правило `forbid` в секции `architecture`).

### 3. Тестовый режим запуска (composition root)

- `Garage/App/AppDependencies+UITesting.swift` (`#if DEBUG`):
  - `static func bootstrapForUITesting() async throws -> AppDependencies`: defaults-сьют, очистка,
    `AppBootstrap.prepare(inMemory: true, defaults:)`, фикстура записей через
    `SwiftDataServiceRecordRepository(container:).add(_:receiptImage:)`, затем
    `AppDependencies(container:credentials: InMemoryCredentialsStore(), registrar: DisabledDeviceRegistrar())`;
  - `InMemoryCredentialsStore`, `DisabledDeviceRegistrar` — `private`, рядом;
  - `static var launchBootstrap: () async throws -> AppDependencies` — выбирает по
    `ProcessInfo.processInfo.arguments.contains(UITestFixture.launchArgument)`.
- `GarageApp.swift`: `LaunchModel(bootstrap: AppDependencies.launchBootstrap)`; в Release
  `launchBootstrap` — это `bootstrap` (ветка без `#if DEBUG`).
- Слои (GarageCore, GarageStorage, GarageSync) не меняются. Архитектурная проверка уже разрешает
  `GarageStorage`/`GarageSync` в `Garage/App/`.
- Тест в `GarageTests/LaunchModelTests.swift` не нужен: логика — выбор замыкания. Проверка — сами
  UI-тесты (все они запускаются в этом режиме) и сборка Release.

### 4. Идентификаторы во вью

Только `.accessibilityIdentifier(AccessibilityID.…)`, без изменения вёрстки:

- `VehicleListView`: «+», строка машины (`row(id)`), подзаголовок строки (`rowSubtitle(id)`; уже
  `.accessibilityElement(children: .combine)`, поэтому `label` = «2019 · 1 запись»), кнопка свайпа
  «Удалить», кнопка подтверждения в диалоге (кнопки отмены нет — popover), «No Vehicles».
- `VehicleDetailView`: меню «…», «Изменить», «Удалить машину», «Добавить запись», строка записи
  (`record(id)`), скрепка чека, свайп «Удалить», диалоги, «Vehicle Not Found».
- `VehicleFormView`: тип, марка, модель, год, пробег, ошибки под полями, `.close`/`.confirm`.
- `ServiceRecordFormView`: пробег, «Заменить фото», «Удалить фото», «Удалить запись», диалог, `.close`/`.confirm`.

Кнопки внутри `confirmationDialog` и `swipeActions` — на шаге 0/4 проверить, доходит ли до них
`accessibilityIdentifier` (см. «Риски»).

### 5. Сценарии (`GarageUITests/`)

Каждый тест запускает приложение заново с `UITestFixture.launchArgument`, то есть на свежих данных в
памяти; тесты независимы. Ожидание — `waitForExistence(timeout:)`, без `sleep`. Помощники
(`launchGarage()`, `openVehicle(_:)`, `swipeDelete(_:)`) — в `GarageUITests/Support.swift`.

`VehicleTests` (B6 этапа 10):
1. `testAddVehicleShowsErrorsThenSaves` — «+» → сохранить пустую форму → ошибки марки/модели/года
   существуют → заполнить → сохранить → строк машин на одну больше (предикат `identifier BEGINSWITH
   'vehicleList.row.'`).
2. `testEditVehicleYearUpdatesDetailAndList` — экран Land Cruiser → «…» → «Изменить» → поле марки
   `Toyota`, год `2019` → год `2020` → сохранить → подзаголовок строки в списке начинается с `2020`.
3. `testSwipeDeleteCancelKeepsRowThenConfirmRemoves` — Transporter: свайп → «Удалить» → диалог
   (popover без «Отмены», см. «Риски») → отмена тапом по `app.otherElements["PopoverDismissRegion"]`
   (строка есть) → повтор с подтверждением (строки нет). Отмена — помощник `dismissDialog()` в
   `Support.swift`, общий для обоих тестов «Cancel…».
4. `testDeleteFromDetailReturnsToList` — CB500X: «…» → «Удалить машину» → подтвердить → сразу после
   тапа `vehicleNotFound` не существует → список, строки CB500X нет. Проверка «нет мигания» слабая
   (см. «Риски»).

`ServiceRecordTests` (B6 этапа 9):
1. `testEditRecordMileageUpdatesRow` — тап по `recordToEdit` → форма, поле пробега заполнено → новый
   пробег → сохранить → в строке записи новый пробег (число — данные; сравнивать по цифрам без
   разделителей, чтобы не зависеть от языка).
2. `testRemoveReceiptPhoto` — `recordWithReceipt`: скрепка есть → форма → «Удалить фото» → сохранить →
   скрепки нет. «Заменить фото» идёт через `PhotosPicker`, а он работает вне процесса приложения: на
   шаге 0 проверить, доступны ли его элементы раннеру (`XCUIApplication(bundleIdentifier:)` пикера или
   `springboard`). Не доступны — замена фото остаётся в списке визуальных проверок ui-checker'а, и это
   пишется в описание агента.
3. `testSwipeDeleteRecordCancelThenConfirm` — свайп → «Удалить» → отмена через `dismissDialog()`
   (тап по `PopoverDismissRegion`; строка есть) → повтор с подтверждением (строки нет).
4. `testDeleteRecordFromForm` — форма `recordToDelete` → «Удалить запись» → подтвердить → форма закрыта,
   строки нет.

`LocalizedTextTests` (только ru, решение 7):
1. `testRecordCountPluralsInList` — подзаголовки: Land Cruiser `2019 · 1 запись`, Transporter
   `2015 · 3 записи`, CB500X `2021 · 5 записей`, Rockhopper `2022 · 0 записей`.
2. `testVehicleDeletionDialogPlural` — свайп по Transporter → текст диалога с «3 записи»; по CB500X — с
   «5 записей». Точные строки взять из `Garage/Localizable.xcstrings` при реализации.
3. `testYearHasNoThousandsSeparator` — подзаголовок строки содержит `2019`, но не `2 019`, `2 019`
   (неразрывный пробел) и `2,019`; форма машины с годом `1800` → ошибка «Введите год от 1900 до
   <текущий+1>» без разделителей (текущий год считает тест: `Calendar.current`); поле года в правке — `2019`.

### 6. `scripts/check.sh` — секция `ui`

- `sections="architecture linux ios strings"` остаётся списком по умолчанию; `optional_sections="ui"`;
  `--only` принимает оба списка, `usage` печатает `ui` с пометкой «not part of the default run».
- `section_ui`:
  1. `require xcodebuild ui`, `require xcrun ui`;
  2. `ui_simulator <lang>`: найти по имени `Garage UI <lang>` или создать (решение 6) из устройства
     `sim_destination`; UDID исходного — из `CLAUDE.local.md` или `$SIM_UDID`; загрузить (`simctl boot`,
     ошибку «уже запущен» игнорировать);
  3. `build-for-testing` в `.build/ui`;
  4. два `test-without-building` в фоне (`&`, логи в `.build/ui/<lang>.log`), `wait` каждого PID; en-проход с
     `-skip-testing:GarageUITests/LocalizedTextTests`;
  5. при падении — какой язык упал, хвост лога и путь к `.xcresult`; секция падает, если упал хотя бы один.
  6. `xcodebuild -scheme Garage -configuration Release -destination 'generic/platform=iOS Simulator' build`
     в тот же `.build/ui` — тестовый режим не протёк в Release.
- Шапка скрипта и CI-комментарий: `ui` локальная и не входит в `scripts/check.sh` без аргументов.

### 7. Документация и агенты

- `CLAUDE.md`:
  - Commands: `scripts/check.sh --only ui` и пример одиночного прогона
    (`-only-testing:GarageUITests/VehicleTests/testAddVehicleShowsErrorsThenSaves`);
  - Architecture: строка про `GarageUITests/` и `GarageUIIdentifiers/` (общая папка двух таргетов,
    тестовый режим — `-GarageUITesting`, только Debug);
  - Definition of done: новый пункт «Изменён UI (`Garage/Features`, `Garage/Shared`, `Garage/App` вью) —
    `scripts/check.sh --only ui` проходит; новый экран или действие получает идентификаторы и сценарий в
    `GarageUITests`»; в п. 1 уточнить, что `ui` в общий прогон не входит.
- `docs/architecture.md`: в таблице «Тесты и фейки» строка «вью» → `GarageUITests` (регрессия,
  идентификаторы, тестовый режим), ui-checker — визуальная проверка; раздел «Тестовый режим запуска» —
  что подменяется и почему только в composition root.
- `.claude/skills/new-feature/SKILL.md`, п. 6 — идентификаторы в `AccessibilityID`; п. 9 —
  `scripts/check.sh --only ui` и сценарий в `GarageUITests`; ui-checker — только для визуальной проверки
  нового UI.
- `.claude/agents/ui-checker.md` (решение по роли — п. 8 ниже).
- `CLAUDE.local.md`: имена `Garage UI en` / `Garage UI ru` (UDID — после создания).

### 8. Роль ui-checker'а

Регрессию ведут UI-тесты; ui-checker смотрит то, что тесты по идентификаторам не видят. Новое описание:

> Visual check of iOS UI in the Simulator: truncation, layout, overlap, dark mode, Dynamic Type and
> how new or changed screens look on en and ru. Not for regression of existing flows — those are
> covered by `scripts/check.sh --only ui` (GarageUITests). Use PROACTIVELY after a visual UI change or
> for a new screen before it has UI tests.

В теле: явный список «не делай» (не повторять сценарии из `GarageUITests`), фокус отчёта — обрезанные
строки (ru длиннее en), наложения, выравнивание, пустые состояния; плюс сценарии, недоступные XCUITest
(замена фото через `PhotosPicker`, если шаг 5 это подтвердит).

### 9. Проверка

- `scripts/check.sh` (все секции по умолчанию) и `scripts/check.sh --only ui` — оба языка зелёные.
- Повторить `--only ui` после `rm -rf .build/ui` (чистая сборка).
- Намеренно сломать склонение в ru-каталоге локально (не коммитить) → `LocalizedTextTests` падает →
  вернуть. Так видно, что проверка ловит ту ошибку, ради которой написана.
- `xcprojformatter --update` и минимальный `git diff` `project.xcproj`.
- swift-reviewer на diff; ui-checker — одним визуальным проходом по экранам, где добавлены
  идентификаторы (вёрстка не должна измениться).

## Риски

- **`confirmationDialog` — popover без кнопки «Отмена».** На этой версии iOS диалог показывается
  popover'ом, и кнопки отмены в нём нет (выяснено на этапах 9 и 10). Отмена в тестах — тап по
  `app.otherElements["PopoverDismissRegion"]` (системный идентификатор, от языка не зависит), в одном
  помощнике `dismissDialog()`. Если на шаге 0 окажется, что диалог всё же лист (`app.sheets`), —
  `dismissDialog()` нажимает кнопку отмены по роли (`.cancel`), а не по тексту; тесты не меняются.
  Найденное записать в `docs/xcproj-notes.md`.
- **`accessibilityIdentifier` в `confirmationDialog` и `swipeActions`.** Кнопка подтверждения в диалоге и
  кнопка свайпа могут не получить идентификатор. Тогда подтверждение — единственная кнопка popover'а
  (листа), свайп — единственная кнопка действий строки; это не завязано на язык. Решить на шаге 4.
- **Мигание «Vehicle Not Found» (B6 этапа 10, п. 4).** XCUITest не гарантирует снимок промежуточного
  состояния: проверка «элемента нет сразу после тапа» ловит только устойчивую ошибку. Основная защита —
  тест `VehicleDetailViewModel` (`isDeleting`). Это осознанное ослабление по сравнению со снимком
  ui-checker'а.
- **`PhotosPicker` вне процесса.** См. шаг 5, п. 2; при неудаче замена фото остаётся ручной.
- **Год в ошибке зависит от даты.** Тест считает ожидаемый верхний год сам; в полночь 31 декабря
  возможна гонка — приемлемо.
- **Два симулятора параллельно.** Память и время сборки на ноутбуке; при нехватке — `--only ui` с
  `UI_SERIAL=1` (последовательно, тот же порядок). Флаг добавить, только если понадобится.
- **Формат `project.xcproj` без документации.** Ключ связи UI-bundle с приложением может отличаться от
  `test-host-target`; форматтер выбрасывает неизвестные ключи молча, поэтому после `--update` сверять
  `git diff`, а связь — по `-showBuildSettings` (шаг 0).
- **Общая папка в двух таргетах.** Если формат или сборка этого не допускают — пакет
  `GarageUIIdentifiers` (решение 4). План шагов 2–5 от этого не меняется, кроме путей.
