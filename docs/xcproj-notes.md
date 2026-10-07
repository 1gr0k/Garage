# Заметки о формате `project.xcproj` (Xcode 27.2 beta 2)

Публичной документации по формату нет. Всё ниже установлено опытным путём через `xcprojformatter` и `xcodebuild` (Xcode `27B5028f`) при подключении `Packages/GarageCore` к таргету `Garage`.

## Инструменты

- `xcode-select` на этой машине указывает на CommandLineTools, поэтому Xcode-инструменты вызываются так:
  ```sh
  export DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer
  ```
- `$DEVELOPER_DIR/usr/bin/xcprojformatter` (в `PATH` его нет):
  - `xcprojformatter --update Garage.xcodeproj` приводит файл к каноническому виду на месте;
  - `xcprojformatter < project.xcproj` читает stdin и пишет в stdout. Удобно для пробных правок без записи на диск.
  - Валидирует **только схему** и сообщает ошибку с JSON-путём, например `Missing required value for key “kind” at “/packages[0]”`. Семантику (существует ли пакет или продукт) он не проверяет. Для этого нужен `xcodebuild -list` / `build`.
  - Канонический вид разворачивает однострочные объекты в многострочные. Исключения: элементы `files` и вложенный `build-phase` остаются однострочными.
- Синтаксис — JSON с висячими запятыми.
- `swift test` пакета через CLT падает с ошибкой `plugin for module 'TestingMacros' not found`, потому что в CLT нет макросов Swift Testing. С `DEVELOPER_DIR` на Xcode тесты проходят.

## Структура файла

Верхние ключи в каноническом порядке: `default-configuration`, `configurations`, `localizations`, `packages`, `files`, `targets`, `build-settings` (уровень проекта), `last-upgrade`, `last-swift-update`.

- `files`: дерево навигатора.
  - `{ "kind": "folder", "path": "Garage", "target-membership": ["Garage"] }` — синхронизируемая папка. Все файлы внутри автоматически входят в таргет, перечислять их не нужно.
  - `{ "kind": "group", "name": "Products", "children": [...] }` — группа. Продукты адресуются как `<PRODUCTS>/Garage.app`.
- `targets[]`: `name`, `id` (24 hex-символа, при переименовании можно оставить), `product` (ссылка на путь в группе: `Products/Garage.app`), `product-type`, `build-phases` (список строк: `compile-sources`, `frameworks`, `resources`), `package-product-members`, `build-settings`.
- Условные build-settings задаются суффиксом ключа: `KEY[sdk=iphoneos*]`, `KEY[config=Debug]`. Значение может быть строкой или массивом.
- Общих схем (`xcshareddata/xcschemes`) нет. Схемы генерируются автоматически: по одной на таргет (`Garage`) и на каждый продукт локального пакета (`GarageCore`). При переименовании таргета схема переименовывается сама.

## Локальный Swift-пакет

```jsonc
"packages": [                                    // верхний уровень, перед "files"
  { "kind": "local", "path": "Packages/GarageCore" },
],
...
"targets": [ {
  ...
  "package-product-members": [                   // после "build-phases"
    {
      "package": "GarageCore",
      "product-name": "GarageCore",
      "build-phase": { "build-phase": "frameworks" },
    },
  ],
} ]
```

- `path` считается **относительно каталога, в котором лежит `.xcodeproj`**, а не самого `.xcodeproj`.
- `"kind": "local"` обязателен. В бинарнике есть и `remote` (ключи `repository`, `version`, `upToNextMajorVersion`, `revision`, `traits`), но этот вариант не проверялся.
- `"package"` сопоставляется с **последним компонентом `path`** (именем каталога), а **не** с `name` из `Package.swift`. Проверено: каталог `Packages/CoreDir` с `name: "GarageCore"` в манифесте. `"package": "GarageCore"` проект не открывает, а `"package": "CoreDir"` собирается.
- Если ссылка не находит пакет, `xcodebuild` не может открыть проект: `The package name “Nope” does not uniquely refer to a package.` Формулировка намекает, что при двух пакетах с одинаковым именем каталога нужна другая форма ссылки. Эта форма не выяснена.
- `"product-name"` — имя library-продукта из `Package.swift`. Неверное имя приводит к ошибке сборки `Missing package product 'Nope'`.
- `"build-phase"` — именно вложенный объект `{ "build-phase": "<фаза>" }`, строка не принимается. Для библиотеки нужна фаза `frameworks`. С `resources` сборка падает: `“GarageCore-product” couldn’t be opened`.
- Без `package-product-members` пакет резолвится и виден в навигаторе, но к таргету не линкуется: `Unable to resolve module dependency: 'GarageCore'`.
- Папку `Packages` добавлять в `files` не нужно: локальный пакет появляется в навигаторе через `packages`.

## Проверка после правки

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer
$DEVELOPER_DIR/usr/bin/xcprojformatter --update Garage.xcodeproj
xcodebuild -project Garage.xcodeproj -list            # Resolved source packages + схемы
xcodebuild -project Garage.xcodeproj -scheme Garage \
  -destination 'generic/platform=iOS Simulator' build
```

## Два локальных пакета с зависимостью между ними

`Packages/GarageStorage` зависит от `Packages/GarageCore` через `.package(path: "../GarageCore")`, а приложение линкует оба. Проверено: в `packages` проекта перечислены оба пакета, в `package-product-members` таргета — оба продукта; `xcodebuild -list` показывает оба в Resolved source packages (`@ local`), сборка проходит. Запись `GarageCore` остаётся, потому что приложение импортирует его напрямую. Вариант без неё не проверялся.

## Локализации

```jsonc
"localizations": { "development": "en", "supported": ["Base", "ru"] },
```

- `en` в `supported` добавлять не нужно: `development: "en"` уже делает английский языком разработки. Проверено на сборке: в `Garage.app` появляются `en.lproj` и `ru.lproj`, хотя в `supported` только `Base` и `ru`.
- Что попадает в бандл из `Garage/Localizable.xcstrings` (папка синхронизируемая, файл подхватывается сам):
  - `ru.lproj/Localizable.strings` и `ru.lproj/Localizable.stringsdict` (плюралы one/few/many/other);
  - `en.lproj/Localizable.stringsdict` — только для ключей с английскими plural variations. Обычные английские строки отдельным файлом не хранятся: ключ и есть английский текст.
- `LOCALIZATION_PREFERS_STRING_CATALOGS = YES` уже стоял в build settings.
- Извлечение ключей: `xcrun xcstringstool sync Garage/Localizable.xcstrings --stringsdata <DerivedData/…/Objects-normal/arm64/*.stringsdata>`. Файл `.xcstrings` должен существовать (хотя бы `{"sourceLanguage":"en","strings":{},"version":"1.0"}`), иначе sync пропускается с предупреждением.

## Unit-test таргет (`GarageTests`)

Проверено опытным путём (Swift Testing, хост — `Garage.app`). Рабочий вариант:

```jsonc
// files: синхронизируемая папка теста и продукт в группе Products
{ "kind": "folder", "path": "GarageTests", "target-membership": [ "GarageTests" ] },
{ "path": "<PRODUCTS>/GarageTests.xctest", "id": "000000000000000000000121", "type": "wrapper.cfbundle", "index": false },

// targets
{
  "name": "GarageTests",
  "id": "000000000000000200000000",
  "product": "Products/GarageTests.xctest",
  "product-type": "bundle.unit-test",
  "test-host-target": "Garage",                  // имя таргета-хоста; TEST_HOST/BUNDLE_LOADER вручную не нужны
  "build-phases": [ "compile-sources", "frameworks" ],
  "package-product-members": [ /* как у приложения, нужные продукты */ ],
  "build-settings": {
    "GENERATE_INFOPLIST_FILE": "YES",
    "PRODUCT_BUNDLE_IDENTIFIER": "devplaceholder.GarageTests",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SDKROOT": "iphoneos",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "SWIFT_VERSION": "6.0",
    "TARGETED_DEVICE_FAMILY": "1,2",
    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
  },
}
```

- `"product-type": "bundle.unit-test"` (полное имя `com.apple.product-type.bundle.unit-test`). Значение `unit-test` форматтер принимает, но таргет не становится тестовым: `Scheme … is not currently configured for the test action`.
- Продукт обязан быть в `files` (группа Products), иначе проект не открывается: `Invalid reference: “Products/GarageTests.xctest”`.
- Без `SDKROOT`/`SUPPORTED_PLATFORMS` симуляторы не подходят: `doesn’t match .xctest’s supported platforms`.
- Схема создаётся автоматически с именем таргета: тесты запускаются командой
  `xcodebuild test -project Garage.xcodeproj -scheme GarageTests -destination '<…>'` (она же собирает хост `Garage.app`). Схема `Garage` для действия test не настроена (`Scheme Garage is not currently configured for the test action`), а ключей для схем в формате нет.
- **Зависимость от хоста.** `test-host-target` порядок сборки не задаёт. Нужен ещё `"dependencies": ["Garage"]` (имена таргетов; форматтер неизвестные ключи молча выбрасывает, этот оставляет). Без него чистая сборка схемы `GarageTests` падает с `Unable to resolve module dependency: 'Garage'` (и для пакетов хоста), а на прогретом DerivedData тесты проходят только потому, что `Garage` собрали раньше. Проверять с `rm -rf` DerivedData проекта.
- `@testable import Garage` работает (модуль приложения называется `Garage`; в Debug включён `ENABLE_TESTABILITY`).
- **Хост и debug-dylib.** В Debug приложение собирается как заглушка `Garage` + `Garage.debug.dylib`, а `test-host-target` сам по себе `TEST_HOST`/`BUNDLE_LOADER` не выставляет: тесты запускались без хоста (через голый `xctest`), а ссылки на символы приложения давали `Undefined symbol`. Пока тест только `import`-ил модуль, это не проявлялось (линкер выбрасывал неиспользуемое). Рабочие настройки тестового таргета:
  ```jsonc
  "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/Garage.app/Garage",
  "BUNDLE_LOADER[config=Debug]": "$(BUILT_PRODUCTS_DIR)/Garage.app/Garage.debug.dylib",
  ```
- **Не линкуйте в тестовый таргет пакеты, которые уже в хосте.** Статическая копия `GarageCore` в бандле и в хосте даёт два набора метаданных типов: `error as? SyncFailure` в тесте возвращает `nil`, хотя тип тот же. Модули пакетов видны тестам и без `package-product-members` (берутся из `BUILT_PRODUCTS_DIR`), поэтому у `GarageTests` этого ключа нет.
- На уровне проекта `packages` уже есть; в тестовом таргете `package-product-members` не нужен (см. выше). В примере выше он остался только как форма ключа для пакета, которого нет в хосте.
