#!/bin/bash
# Definition of done in one command (see CLAUDE.md).
#   scripts/check.sh                       all sections
#   scripts/check.sh --only linux|ios|strings
# Stops at the first failure and reports which section failed.
# New local package: add it to `linux` (swift test) or `ios` (xcodebuild test).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

only=""
case "${1:-}" in
    "") ;;
    --only)
        only="${2:-}"
        [[ "$only" =~ ^(linux|ios|strings)$ ]] || { echo "usage: $0 [--only linux|ios|strings]" >&2; exit 64; }
        ;;
    *) echo "usage: $0 [--only linux|ios|strings]" >&2; exit 64 ;;
esac

current=""
trap 'status=$?; [[ $status -eq 0 || -z "$current" ]] || echo "check.sh: section \"$current\" FAILED" >&2' EXIT

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
    echo "==> xcodebuild build Garage"
    xcodebuild -project Garage.xcodeproj -scheme Garage -destination 'generic/platform=iOS Simulator' build
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

for name in linux ios strings; do
    [[ -z "$only" || "$only" == "$name" ]] || continue
    current=$name
    echo "### $name"
    "section_$name"
done
current=""
echo "check.sh: all checks passed"
