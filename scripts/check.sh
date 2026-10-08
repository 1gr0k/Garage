#!/bin/bash
# Definition of done in one command (see CLAUDE.md).
#   scripts/check.sh                       default sections (architecture linux ios strings)
#   scripts/check.sh --only architecture|linux|ios|strings|ui
# CI (GitHub Actions, Linux) runs only `architecture`, `linux` and `strings`;
# `ios` needs Xcode and a simulator and runs locally only.
# `ui` (XCUITest on en and ru, two simulators) is slow and local only: it is not part of the default run,
# only `--only ui`. Env: UI_EXPECTED_LANGUAGE_EN / UI_EXPECTED_LANGUAGE_RU override the expected language
# passed to `testRunsInExpectedLanguage` (to check that the test fails when the language is wrong).
# UI_SERIAL=1 runs en and ru one after another (two simulators do not fit in memory on a small Mac).
# Every UI `xcodebuild test-without-building` has XCTest timeouts per test (120 s default, 240 s max)
# and an outer limit of $UI_DEADLINE seconds (default 900) per language: a hung run is killed.
#   scripts/check.sh --test GarageCore|GarageSync|GarageAPI|Server <regex>   one `swift test --filter`
#   scripts/check.sh --test GarageStorage|app|ui <Target/Suite/test>         one `xcodebuild -only-testing`
#                                                                           (ui: language from $UI_LANG, default en)
# The full output of every section (and of --test) also goes to .build/check-logs/<section>.log
# (test-<target>.log for --test); the path is printed at the end. The exit code is that of the check;
# --test also fails when the filter matched no test.
# Stops at the first failure and reports which section failed.
# New local package: add it to `linux` (swift test) or `ios` (xcodebuild test).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

sections="architecture linux ios strings"
# Секции, которые идут только по `--only`, но не в общем прогоне.
optional_sections="ui"
test_targets="GarageCore GarageSync GarageAPI Server GarageStorage app ui"
usage="usage: $0 [--only ${sections// /|}|ui]  (ui is not part of the default run)
       $0 --test ${test_targets// /|} <filter>"
only=""
test_target=""
test_filter=""
case "${1:-}" in
    "") ;;
    --only)
        only="${2:-}"
        [[ " $sections $optional_sections " == *" $only "* && -n "$only" ]] || { echo "$usage" >&2; exit 64; }
        ;;
    --test)
        test_target="${2:-}"
        test_filter="${3:-}"
        [[ " $test_targets " == *" $test_target "* && -n "$test_target" && -n "$test_filter" && $# -eq 3 ]] \
            || { echo "$usage" >&2; exit 64; }
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
        source=$(sim_source_udid) || return 1
        runtime=$(jq -r --arg udid "$source" '.devices | to_entries[] | select(.value[] | .udid == $udid) | .key' <<<"$devices")
        device_type=$(jq -r --arg udid "$source" '[.devices[][] | select(.udid == $udid)][0].deviceTypeIdentifier // empty' <<<"$devices")
        [[ -n "$runtime" && -n "$device_type" ]] || { echo "Simulator $source not found" >&2; return 1; }
        # В bash 3.2 `set -e` не действует внутри `$(…)`: каждый шаг проверяется явно.
        udid=$(xcrun simctl create "$name" "$device_type" "$runtime") || return 1
    fi
    [[ -n "$udid" ]] || { echo "Simulator \"$name\" was not created" >&2; return 1; }
    xcrun simctl bootstatus "$udid" -b >/dev/null || return 1
    printf '%s\n' "$udid"
}

# Таймауты XCTest на каждый тест: повисший тест падает с ошибкой, а не держит прогон.
ui_test_timeouts=(-test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 240)

# На macOS нет `timeout`. Сторож убивает процесс, если он не закончился за <секунд> (по умолчанию
# $UI_DEADLINE, 900). Таймауты XCTest этого не заменяют: после упавшего теста сам `xcodebuild`
# может не завершиться (так было при мутации в B2), и их он не видит. Сторож выходит сам,
# когда процесс закончился (проверка раз в секунду), поэтому его не нужно останавливать.
# start_deadline <pid> <метка> [секунд]
start_deadline() {
    local pid=$1 label=$2 limit=${3:-${UI_DEADLINE:-900}} i
    (
        for ((i = 0; i < limit; i++)); do
            sleep 1
            kill -0 "$pid" 2>/dev/null || exit 0
        done
        echo "ui: $label did not finish in ${limit}s, killing xcodebuild (pid $pid)" >&2
        kill "$pid" 2>/dev/null || exit 0
        sleep 10
        kill -9 "$pid" 2>/dev/null || true
    ) &
}

# Регрессия вью: XCUITest на en и ru параллельно на двух симуляторах одной сборкой.
# Не входит в общий прогон (медленно, нужны симуляторы): только `--only ui`.
section_ui() {
    require xcodebuild ui
    require xcrun ui
    require jq ui
    local build=.build/ui langs="en ru" lang udid status=0
    local -a pids=() udids=() codes=()
    # Прерывание скрипта не должно оставлять фоновые xcodebuild.
    trap 'kill ${pids[@]+"${pids[@]}"} 2>/dev/null || true' INT TERM
    echo "==> build-for-testing GarageUITests"
    xcodebuild build-for-testing -project Garage.xcodeproj -scheme GarageUITests \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$build"
    for lang in $langs; do
        udid=$(ui_simulator "$lang") && [[ -n "$udid" ]] || return 1
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
            "${ui_test_timeouts[@]}" ${skip[@]+"${skip[@]}"} \
            -resultBundlePath "$build/$lang.xcresult" >"$build/$lang.log" 2>&1 &
        pids+=($!)
        start_deadline "${pids[index]}" "test $lang"
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
    # `grep -c` читает весь вывод: `grep -q` закрыл бы канал раньше, и `strings` под pipefail дал бы 141.
    # Короткая строка может лежать в коде инлайном, поэтому ищем ещё и символ тестового режима.
    local release_binary=$build/Build/Products/Release-iphonesimulator/Garage.app/Garage leaks
    leaks=$(strings -a "$release_binary" | grep -cE 'GarageUITesting|bootstrapForUITesting|InMemoryCredentialsStore' || true)
    if [[ "$leaks" != 0 ]]; then
        echo "ui: the Release build contains the UI-testing mode ($leaks matches)" >&2
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

# Одиночный тест: `--test <цель> <фильтр>`.
#   GarageCore|GarageSync|GarageAPI|Server — `swift test --filter <фильтр>` (регулярное выражение);
#   GarageStorage|app|ui — `xcodebuild -only-testing:<фильтр>`, фильтр — полный идентификатор вида
#   `GarageTests/VehicleListViewModelTests/testX` (для GarageStorage — цель из его пакета).
#   `ui` гоняет один язык: $UI_LANG (по умолчанию en).
test_run() {
    local target=$1 filter=$2 dest lang region expected udid build=.build/ui
    case $target in
        GarageCore | GarageSync | GarageAPI)
            echo "==> swift test Packages/$target --filter $filter"
            swift test --package-path "Packages/$target" --filter "$filter"
            ;;
        Server)
            echo "==> swift test Server --filter $filter"
            swift test --package-path Server --filter "$filter"
            ;;
        GarageStorage)
            require xcodebuild "test $target"
            dest=$(sim_destination)
            echo "==> xcodebuild test GarageStorage -only-testing:$filter ($dest)"
            (cd Packages/GarageStorage && xcodebuild test -scheme GarageStorage -destination "$dest" "-only-testing:$filter")
            ;;
        app)
            require xcodebuild "test $target"
            dest=$(sim_destination)
            echo "==> xcodebuild test GarageTests -only-testing:$filter ($dest)"
            xcodebuild test -project Garage.xcodeproj -scheme GarageTests -destination "$dest" "-only-testing:$filter"
            ;;
        ui)
            require xcodebuild "test $target"
            require xcrun "test $target"
            require jq "test $target"
            lang=${UI_LANG:-en}
            case $lang in
                en) region=US expected=${UI_EXPECTED_LANGUAGE_EN:-en} ;;
                ru) region=RU expected=${UI_EXPECTED_LANGUAGE_RU:-ru} ;;
                *) echo "check.sh: UI_LANG must be en or ru" >&2; return 1 ;;
            esac
            echo "==> build-for-testing GarageUITests"
            xcodebuild build-for-testing -project Garage.xcodeproj -scheme GarageUITests \
                -destination 'generic/platform=iOS Simulator' -derivedDataPath "$build"
            udid=$(ui_simulator "$lang") && [[ -n "$udid" ]] || return 1
            echo "==> test $lang -only-testing:$filter (Garage UI $lang: $udid)"
            TEST_RUNNER_GARAGE_EXPECTED_LANGUAGE=$expected xcodebuild test-without-building \
                -project Garage.xcodeproj -scheme GarageUITests -derivedDataPath "$build" \
                -destination "id=$udid" -testLanguage "$lang" -testRegion "$region" \
                "${ui_test_timeouts[@]}" "-only-testing:$filter" &
            local test_pid=$!
            start_deadline "$test_pid" "test $lang"
            wait "$test_pid"
            ;;
    esac
}

# run_logged <имя> <команда...>: полный вывод идёт в консоль и в .build/check-logs/<имя>.log
# (каталог вне git); в конце печатается путь к логу. Код возврата — команды, а не tee.
# `set -e` включён явно в подоболочке: внутри `||`/`if` он бы не действовал.
run_logged() {
    local name=$1 log code
    shift
    log=.build/check-logs/$name.log
    mkdir -p .build/check-logs
    set +e
    (
        set -e
        "$@"
    ) 2>&1 | tee "$log"
    code=${PIPESTATUS[0]}
    set -e
    echo "check.sh: log: $log"
    # `--test`: фильтр без совпадений даёт код 0 и «пустой» успех. Тесты были, если в логе есть
    # итог Swift Testing («Test run with N tests») или XCTest («Executed N tests») с N > 0;
    # `Executed 0 tests` встречается и в нормальном прогоне Swift Testing, поэтому по нему одному нельзя.
    if [[ "$code" -eq 0 && -n "$test_target" ]] \
        && ! grep -qE 'Test run with [1-9][0-9]* tests?|Executed [1-9][0-9]* tests?' "$log"; then
        echo "check.sh: фильтр не нашёл ни одного теста" >&2
        code=1
    fi
    return "$code"
}

if [[ -n "$test_target" ]]; then
    current="test-$test_target"
    echo "### $current"
    run_logged "$current" test_run "$test_target" "$test_filter"
else
    for name in $sections $optional_sections; do
        if [[ -z "$only" ]]; then
            [[ " $sections " == *" $name "* ]] || continue
        else
            [[ "$only" == "$name" ]] || continue
        fi
        current=$name
        echo "### $name"
        run_logged "$name" "section_$name"
    done
fi
current=""
echo "check.sh: all checks passed"
