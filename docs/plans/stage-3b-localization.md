# Этап 3b: русская локализация

## Контекст
Интерфейс приложения сейчас только английский. Добавляем русский язык, английский остаётся языком разработки. Все пользовательские строки идут через String Catalog. Плюралы оформляются через plural variations. Пробег форматируется по локали, чтобы в русском интерфейсе было «км».

Что выяснилось при разборе кода:
- `Formatting.swift` уже возвращает `LocalizedStringResource`, а не `String`. Проблем две. Первая: список названий работ продублирован в `ServiceType.title` и `ServiceTypeChoice.title`. Вторая: `case .other(let text): "\(text)"` попадает в каталог под ключом `%@`, хотя это пользовательский текст и переводить его не нужно.
- Строк «число + существительное» в UI пока нет. Решено с пользователем добавить два счётчика: в списке техники («2019 · 3 записи», по `VehicleEntity.serviceRecords.count`) и в строке записи («2 запчасти», только если запчасти есть).
- «km» сейчас зашит в строки в трёх местах: `VehicleDetailView` (шапка и строка записи) и подсказка в форме.

## Первый шаг реализации
Сохранить этот план в `docs/plans/stage-3b-localization.md`.

## GarageCore (только Foundation, без строк UI)
- `ServiceTypeChoice.init(_ type: ServiceType)`: отображение типа работ в вариант формы, `.other(_)` → `.other`. Это даёт один источник названий.
- Тест в `ServiceRecordDraftTests` или `ServiceTypeTests`: обратимость с `makeRecord` для всех вариантов, кроме `.other`, и `.other("x")` → `.other`.

## Приложение
- **`Garage/Formatting.swift`**
  - Названия работ остаются только в `ServiceTypeChoice.title: LocalizedStringResource`.
  - `ServiceType.title: String`: для `.other(text)` возвращает `text` как есть, иначе `String(localized: ServiceTypeChoice(self).title)`. В строке записи используется `Text(record.serviceType.title)` (String, без поиска в каталоге).
  - Сообщения ошибок (`FieldError.message`, `ValidationError.message`) уже `LocalizedStringResource`. Они остаются как есть и получают переводы в каталоге.
  - Новое: `extension Int { var kilometers: String }` (или свободная функция `formattedKm(_:)`) — `Measurement(value: Double(km), unit: UnitLength.kilometers).formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))`. Обязательно `usage: .asProvided`, иначе в en_US км пересчитаются в мили.
  - `Money.formatted` (`.currency(code: "RUB")`) зависит от локали. Проверяется на скриншотах: в ru должно быть «1 250,00 ₽».
- **`VehicleDetailView`**: `LabeledContent("Mileage", value: mileage.kilometers)`. В строке записи `Text(verbatim: "\(date) · \(km)")` — разделитель не переводится. Дополнительно, при `!record.parts.isEmpty`, текст `Text("\(record.parts.count) parts")` (плюрал).
- **`ContentView`**: в списке хранятся пары (vehicle, recordCount = `entity.serviceRecords.count`). Подзаголовок собирается из `Text(verbatim: "\(String(vehicle.year)) · ")` и `Text("\(count) records")`. Составного ключа нет.
- **`ServiceRecordFormView`**: подсказка — `String(localized: "Vehicle mileage will be \(value.kilometers)")`. Метка «Mileage, km» остаётся строкой каталога («Пробег, км»).

## String Catalog `Garage/Localizable.xcstrings`
- Папка синхронизируемая, поэтому файл попадает в таргет автоматически.
- Порядок создания: собрать приложение → `xcrun xcstringstool sync Garage/Localizable.xcstrings --stringsdata <DerivedData/…/*.stringsdata>`, чтобы извлечь все ключи → дописать `ru` для каждого ключа. Если `sync` в этой бете не работает, каталог пишется вручную по grep строк, а полноту проверяет повторный `sync` или сборка без warning'ов о недостающих ключах.
- Плюралы `%lld records` и `%lld parts`: `variations.plural` для en (one/other) и ru (one/few/many/other): запись/записи/записей, запчасть/запчасти/запчастей.
- Перевод всех ключей: заголовки, кнопки, алерты, `ContentUnavailableView`, ошибки, названия работ, `accessibilityLabel("Has receipt")`. «Garage» → «Гараж».
- В итоговом каталоге не должно остаться ключей `%@` и ключей со state `new`/`stale`.

## project.xcproj
- `"localizations": { "development": "en", "supported": ["Base", "ru"] }`. Форматирование выполняет хук. Затем `xcodebuild -list` и сборка; проверить, что в `Garage.app` есть `ru.lproj` (скомпилированные `Localizable.strings`/`.stringsdict`).
- В `docs/xcproj-notes.md` добавить раздел «Локализации» с результатом: нужен ли `en` в `supported` и что попадает в бандл.

## Документация
- `CLAUDE.md`, раздел Rules: «Все новые пользовательские строки сразу добавляются в `Garage/Localizable.xcstrings` с русским переводом (для числительных — plural variations one/few/many/other). Пользовательские данные (например, `.other(text)`) в каталог не попадают: `Text(verbatim:)` / `String`.»

- `CLAUDE.md`, Definition of done: новый пункт «Каталог полностью переведён: команда ниже ничего не выводит». Команда выводит ключи, которые: stale; не имеют `ru`; имеют в ru хотя бы один state, отличный от `translated` (например, `needs_review`); имеют ru-плюрал без какой-либо из форм one/few/many/other:
  ```sh
  jq -r '.strings | to_entries[]
    | select(.value.shouldTranslate != false)
    | .key as $k | .value as $v | $v.localizations.ru as $ru
    | select($v.extractionState == "stale"
        or $ru == null
        or ([$ru | .. | .state? // empty] | any(. != "translated"))
        or ($ru.variations.plural != null
            and ([$ru.variations.plural | has("one","few","many","other")] | all | not)))
    | $k' Garage/Localizable.xcstrings
  ```
  Проверка самой команды на копии каталога в scratchpad (сам каталог не трогаем). Исходно вывод пустой. Затем по очереди, каждый раз с ожиданием, что в выводе появится ровно изменённый ключ:
  - удалить ru-перевод обычного ключа;
  - поставить ru-state `needs_review`;
  - убрать форму `few` у плюрала;
  - пометить ключ `"extractionState": "stale"`.

## Проверка
1. `swift test --package-path Packages/GarageCore` — включая новый тест `ServiceTypeChoice.init(_:)`.
2. `xcodebuild test` для GarageStorage на `platform=iOS Simulator,name=iPhone 17`.
3. Сборка приложения командой из CLAUDE.md. Warning'ов о локализации нет, в `.app` есть `ru.lproj`.
4. `git diff Garage.xcodeproj/project.xcproj` — только строка `"ru"`.
5. Проверка в симуляторе (UDID `22F52CEA-…`): `attach`, сборка под симулятор, `launch`, затем перезапуск с аргументами `xcrun simctl launch --terminate-running-process <udid> <bundle-id> -AppleLanguages "(ru)" -AppleLocale ru_RU`. Скриншоты:
   - список техники: «Гараж», «· N записей» с правильной формой;
   - экран техники: «Пробег 87 400 км», сумма «… ₽», строки с датой по-русски и «N запчасти»;
   - форма: «Сохранить» с пустым пробегом, добавленной пустой запчастью и пустым «Другое» → русские сообщения у полей.
   Плюралы few/many: подобрать или добавить через форму записи так, чтобы встретились 1, 2–4 и 5+ (например, запчасти в одной записи). Для контроля один прогон на `en`: «87,400 km», а не мили.
