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
