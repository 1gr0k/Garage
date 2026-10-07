#!/bin/bash
# Definition of done in one command (see CLAUDE.md).
#   scripts/check.sh                       all sections
#   scripts/check.sh --only architecture|linux|ios|strings
# Stops at the first failure and reports which section failed.
# New local package: add it to `linux` (swift test) or `ios` (xcodebuild test).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

sections="architecture linux ios strings"
usage="usage: $0 [--only ${sections// /|}]"
only=""
case "${1:-}" in
    "") ;;
    --only)
        only="${2:-}"
        [[ " $sections " == *" $only "* && -n "$only" ]] || { echo "$usage" >&2; exit 64; }
        ;;
    *) echo "$usage" >&2; exit 64 ;;
esac

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

    local location
    while IFS= read -r location; do
        echo "$location: GarageCore imports only Foundation" >&2
        architecture_violations=$((architecture_violations + 1))
    done < <(grep_or_fail -rnE "$import" Packages/GarageCore/Sources --include='*.swift' \
        | { grep -vE "^[^:]+:[0-9]+:${import#^}Foundation${module_end}" || true; } \
        | cut -d: -f1,2)

    echo "==> swift format lint --strict"
    if ! swift format lint --strict -r Garage GarageTests Packages/*/Sources Packages/*/Tests \
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
    local dest
    dest=$(sim_destination)
    echo "==> xcodebuild test GarageStorage ($dest)"
    (cd Packages/GarageStorage && xcodebuild test -scheme GarageStorage -destination "$dest")
    # Схема GarageTests собирает хост Garage.app, так что отдельная сборка приложения не нужна.
    echo "==> xcodebuild test GarageTests ($dest)"
    xcodebuild test -project Garage.xcodeproj -scheme GarageTests -destination "$dest"
}

# Lists catalog keys that are stale, lack `ru`, have a `ru` state other than
# `translated`, or have a `ru` plural missing one/few/many/other.
section_strings() {
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

for name in $sections; do
    [[ -z "$only" || "$only" == "$name" ]] || continue
    current=$name
    echo "### $name"
    "section_$name"
done
current=""
echo "check.sh: all checks passed"
