#!/bin/bash
# Definition of done in one command (see CLAUDE.md).
#   scripts/check.sh                       default sections (architecture linux ios strings)
#   scripts/check.sh --only architecture|linux|ios|strings|ui
# CI (GitHub Actions, Linux) runs only `architecture`, `linux` and `strings`;
# `ios` needs Xcode and a simulator and runs locally only.
# `ui` (XCUITest on en and ru, two simulators) is slow and local only: it is not part of the default run,
# only `--only ui`. Env: UI_EXPECTED_LANGUAGE_EN / UI_EXPECTED_LANGUAGE_RU override the expected language
# passed to `testRunsInExpectedLanguage` (to check that the test fails when the language is wrong).
# Stops at the first failure and reports which section failed.
# New local package: add it to `linux` (swift test) or `ios` (xcodebuild test).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

sections="architecture linux ios strings"
# Секции, которые идут только по `--only`, но не в общем прогоне.
optional_sections="ui"
usage="usage: $0 [--only ${sections// /|}|ui]  (ui is not part of the default run)"
only=""
case "${1:-}" in
    "") ;;
    --only)
        only="${2:-}"
        [[ " $sections $optional_sections " == *" $only "* && -n "$only" ]] || { echo "$usage" >&2; exit 64; }
        ;;
    *) echo "$usage" >&2; exit 64 ;;
esac

# require <команда> <секция>: понятная ошибка вместо падения посреди секции.
require() {
    command -v "$1" >/dev/null 2>&1 || { echo "check.sh: section \"$2\" needs \`$1\`, which is not installed" >&2; return 1; }
}

current=""
trap 'status=$?; [[ $status -eq 0 || -z "$current" ]] || echo "check.sh: section \"$current\" FAILED" >&2' EXIT

# Границы слоёв из docs/architecture.md, swift-format и кейсы хуков. Быстрая, идёт первой.
# Каждое нарушение печатается как `file:line: rule`.
architecture_violations=0

# forbid <rule> <ERE> <files...>: каждая совпавшая строка — нарушение.
forbid() {
    local rule=$1 pattern=$2 location
    shift 2
    [[ $# -gt 0 ]] || return 0
    while IFS= read -r location; do
        echo "$location: $rule" >&2
        architecture_violations=$((architecture_violations + 1))
    done < <(grep_or_fail -HnE "$pattern" "$@" | cut -d: -f1,2)
}

# grep, у которого «нет совпадений» (1) — не ошибка, а сломанное правило (2) — нарушение.
grep_or_fail() {
    local status=0
    grep "$@" || status=$?
    if ((status > 1)); then
        echo "check.sh: grep failed (exit $status): grep $*" >&2
        # Код выхода из `< <(…)` теряется, поэтому сбой передаётся строкой и считается нарушением.
        echo "grep-error:0:"
    fi
    return 0
}

# Читает пути (по одному на строку) из stdin в массив `files`; пустой ввод — пустой массив.
read_files() {
    local file
    files=()
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then files+=("$file"); fi
    done
}

section_architecture() {
    require swift architecture
    swift format --version >/dev/null 2>&1 || { echo "check.sh: section \"architecture\" needs \`swift format\`" >&2; return 1; }
    # Начало строки импорта до имени модуля: атрибуты (`@_exported`, `@_spi(X)`, `@preconcurrency`),
    # уровень доступа (`public import`) и импорт отдельного объявления (`import struct M.T`).
    local import='^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*((public|package|internal|fileprivate|private)[[:space:]]+)?import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?'
    local module_end='([.[:space:]]|$)'
    local files

    # Вью: файлы *View.swift в Features и всё, что объявляет `: View {`.
    read_files < <({
        find Garage/Features -name '*View.swift'
        grep -rlE '(struct|extension)[[:space:]][^{]*:([^{]*[^A-Za-z])?[[:space:]]*View[[:space:]]*[,{]' Garage \
            --include='*.swift' || true
    } | sort -u)
    if [[ ${#files[@]} -gt 0 ]]; then
        forbid "view imports GarageSync/GarageAPI" "${import}(GarageSync|GarageAPI)${module_end}" "${files[@]}"
        forbid "view touches modelContext (writes go through a ViewModel)" 'modelContext' "${files[@]}"
        # `viewModel.save()` и `selection.insert(id)` разрешены: запрещена запись через контекст SwiftData.
        forbid "view inserts or saves models" 'ModelContext\(|[Cc]ontext\.(insert|save|delete)\(' "${files[@]}"
        forbid "view calls storage/sync internals" \
            '(^|[^A-Za-z])(ServiceLog|VehicleLog|SyncQueue|SyncEngine|SyncSupport)([^A-Za-z]|$)' "${files[@]}"
    fi

    read_files < <(find Garage -name '*ViewModel.swift')
    if [[ ${#files[@]} -gt 0 ]]; then
        forbid "ViewModel imports a storage/sync module" \
            "${import}(SwiftData|GarageStorage|GarageSync|GarageAPI)${module_end}" "${files[@]}"
    fi

    read_files < <(find Garage -name '*.swift' -not -path 'Garage/App/*')
    if [[ ${#files[@]} -gt 0 ]]; then
        forbid "GarageSync is imported only in Garage/App (composition root)" \
            "${import}GarageSync${module_end}" "${files[@]}"
    fi

    # Общая папка приложения и UI-тестов: только Foundation и GarageCore, без UI и хранилища.
    read_files < <(find GarageUIIdentifiers -name '*.swift')
    if [[ ${#files[@]} -gt 0 ]]; then
        forbid "GarageUIIdentifiers imports only Foundation and GarageCore" \
            "${import}(SwiftUI|UIKit|XCTest|SwiftData|GarageStorage|GarageSync|GarageAPI)${module_end}" "${files[@]}"
    fi

    local location
    while IFS= read -r location; do
        echo "$location: GarageCore imports only Foundation" >&2
        architecture_violations=$((architecture_violations + 1))
    done < <(grep_or_fail -rnE "$import" Packages/GarageCore/Sources --include='*.swift' \
        | { grep -vE "^[^:]+:[0-9]+:${import#^}Foundation${module_end}" || true; } \
        | cut -d: -f1,2)

    echo "==> swift format lint --strict"
    if ! swift format lint --strict -r Garage GarageTests GarageUITests GarageUIIdentifiers Packages/*/Sources Packages/*/Tests \
        Server/Sources Server/Tests Packages/*/Package.swift Server/Package.swift; then
        architecture_violations=$((architecture_violations + 1))
    fi

    echo "==> scripts/test-hooks.sh"
    scripts/test-hooks.sh || architecture_violations=$((architecture_violations + 1))

    if ((architecture_violations > 0)); then
        echo "$architecture_violations architecture violation(s); rules: docs/architecture.md" >&2
        return 1
    fi
}

# Everything that builds without Xcode or a simulator.
section_linux() {
    local pkg
    for pkg in Packages/GarageCore Packages/GarageAPI Packages/GarageSync Server; do
        echo "==> swift test $pkg"
        swift test --package-path "$pkg"
    done
}

# Destination: $SIM_DESTINATION, else the first `platform=...` line of CLAUDE.local.md.
sim_destination() {
    if [[ -n "${SIM_DESTINATION:-}" ]]; then
        printf '%s\n' "$SIM_DESTINATION"
        return
    fi
    local dest=""
    [[ -f CLAUDE.local.md ]] && dest=$(grep -m1 '^platform=' CLAUDE.local.md || true)
    [[ -n "$dest" ]] || { echo "SIM_DESTINATION is not set and CLAUDE.local.md has no 'platform=...' line" >&2; return 1; }
    printf '%s\n' "$dest"
}

section_ios() {
    require xcodebuild ios
    local dest
    dest=$(sim_destination)
    echo "==> xcodebuild test GarageStorage ($dest)"
    (cd Packages/GarageStorage && xcodebuild test -scheme GarageStorage -destination "$dest")
    # Схема GarageTests собирает хост Garage.app, так что отдельная сборка приложения не нужна.
    echo "==> xcodebuild test GarageTests ($dest)"
    xcodebuild test -project Garage.xcodeproj -scheme GarageTests -destination "$dest"
}

# UDID исходного симулятора для `ui_simulator`: $SIM_UDID или первый UUID из CLAUDE.local.md.
sim_source_udid() {
    if [[ -n "${SIM_UDID:-}" ]]; then
        printf '%s\n' "$SIM_UDID"
        return
    fi
    local udid=""
    [[ -f CLAUDE.local.md ]] && udid=$(grep -oEm1 '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' CLAUDE.local.md || true)
    [[ -n "$udid" ]] || { echo "SIM_UDID is not set and CLAUDE.local.md has no simulator UDID" >&2; return 1; }
    printf '%s\n' "$udid"
}

# ui_simulator <lang>: UDID устройства `Garage UI <lang>`. Нет такого — создаём с типом и рантаймом
# исходного симулятора (`simctl clone` не работает с запущенным источником и переносит приложения
# и Keychain). Устройство запускается и ждёт готовности.
ui_simulator() {
    local name="Garage UI $1" devices udid source runtime device_type
    devices=$(xcrun simctl list -j devices)
    udid=$(jq -r --arg name "$name" '[.devices[][] | select(.name == $name and .isAvailable)][0].udid // empty' <<<"$devices")
    if [[ -z "$udid" ]]; then
        source=$(sim_source_udid)
        runtime=$(jq -r --arg udid "$source" '.devices | to_entries[] | select(.value[] | .udid == $udid) | .key' <<<"$devices")
        device_type=$(jq -r --arg udid "$source" '[.devices[][] | select(.udid == $udid)][0].deviceTypeIdentifier // empty' <<<"$devices")
        [[ -n "$runtime" && -n "$device_type" ]] || { echo "Simulator $source not found" >&2; return 1; }
        udid=$(xcrun simctl create "$name" "$device_type" "$runtime")
    fi
    xcrun simctl bootstatus "$udid" -b >/dev/null
    printf '%s\n' "$udid"
}

# Регрессия вью: XCUITest на en и ru параллельно на двух симуляторах одной сборкой.
# Не входит в общий прогон (медленно, нужны симуляторы): только `--only ui`.
section_ui() {
    require xcodebuild ui
    require xcrun ui
    require jq ui
    local build=.build/ui langs="en ru" lang udid status=0
    local -a pids=() udids=() codes=()
    echo "==> build-for-testing GarageUITests"
    xcodebuild build-for-testing -project Garage.xcodeproj -scheme GarageUITests \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$build"
    for lang in $langs; do
        udid=$(ui_simulator "$lang")
        udids+=("$udid")
        echo "==> Garage UI $lang: $udid"
    done
    local index=0 region expected skip
    for lang in $langs; do
        case $lang in
            en) region=US expected=${UI_EXPECTED_LANGUAGE_EN:-en} skip=(-skip-testing:GarageUITests/LocalizedTextTests) ;;
            ru) region=RU expected=${UI_EXPECTED_LANGUAGE_RU:-ru} skip=() ;;
        esac
        rm -rf "$build/$lang.xcresult"
        echo "==> test $lang (log: $build/$lang.log)"
        TEST_RUNNER_GARAGE_EXPECTED_LANGUAGE=$expected xcodebuild test-without-building \
            -project Garage.xcodeproj -scheme GarageUITests -derivedDataPath "$build" \
            -destination "id=${udids[index]}" -testLanguage "$lang" -testRegion "$region" \
            ${skip[@]+"${skip[@]}"} -resultBundlePath "$build/$lang.xcresult" >"$build/$lang.log" 2>&1 &
        pids+=($!)
        index=$((index + 1))
        # UI_SERIAL=1: языки по очереди (на слабой или занятой машине два симулятора подвисают).
        if [[ -n "${UI_SERIAL:-}" ]]; then
            if wait "${pids[index - 1]}"; then codes+=(0); else codes+=(1); fi
        fi
    done
    index=0
    for lang in $langs; do
        if [[ -z "${UI_SERIAL:-}" ]]; then
            if wait "${pids[index]}"; then codes+=(0); else codes+=(1); fi
        fi
        if [[ "${codes[index]}" == 0 ]]; then
            echo "ui: $lang passed"
        else
            status=1
            echo "ui: $lang FAILED, result: $build/$lang.xcresult" >&2
            grep -E "error:|failed" "$build/$lang.log" | head -20 >&2 || true
            tail -n 15 "$build/$lang.log" >&2
        fi
        index=$((index + 1))
    done
    ((status == 0)) || return 1

    # Тестовый режим не должен протечь в Release.
    echo "==> Release build (test mode must not leak)"
    xcodebuild build -project Garage.xcodeproj -scheme Garage -configuration Release \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$build"
    if strings "$build/Build/Products/Release-iphonesimulator/Garage.app/Garage" | grep -q 'GarageUITesting'; then
        echo "ui: the Release build contains the UI-testing launch argument" >&2
        return 1
    fi
}

# Lists catalog keys that are stale, lack `ru`, have a `ru` state other than
# `translated`, or have a `ru` plural missing one/few/many/other.
section_strings() {
    require jq strings
    local catalog=Garage/Localizable.xcstrings keys
    keys=$(jq -r '.strings | to_entries[]
      | select(.value.shouldTranslate != false)
      | .key as $k | .value as $v | $v.localizations.ru as $ru
      | select($v.extractionState == "stale"
          or $ru == null
          or ([$ru | .. | .state? // empty] | any(. != "translated"))
          or ($ru.variations.plural != null
              and ([$ru.variations.plural | has("one","few","many","other")] | all | not)))
      | $k' "$catalog")
    if [[ -n "$keys" ]]; then
        echo "Untranslated keys: $(paste -sd ',' - <<<"$keys" | sed 's/,/, /g')" >&2
        echo "Add/fix the ru translations in $catalog (state: translated; plurals need one/few/many/other)." >&2
        return 1
    fi
}

for name in $sections $optional_sections; do
    if [[ -z "$only" ]]; then
        [[ " $sections " == *" $name "* ]] || continue
    else
        [[ "$only" == "$name" ]] || continue
    fi
    current=$name
    echo "### $name"
    "section_$name"
done
current=""
echo "check.sh: all checks passed"
