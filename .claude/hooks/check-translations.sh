#!/bin/bash
# Stop: block finishing while Garage/Localizable.xcstrings has untranslated keys.
# Runs only if Garage/*.swift or the catalog changed since HEAD (or are new).
# Exit 2 feeds the key list back to Claude; stop_hook_active prevents a loop.
set -euo pipefail

input=$(cat)
[[ $(jq -r '.stop_hook_active // false' <<<"$input") == "true" ]] && exit 0

cd "${CLAUDE_PROJECT_DIR:-$PWD}"
catalog=Garage/Localizable.xcstrings
[[ -f "$catalog" ]] || exit 0

changed=$({
    git diff --name-only HEAD
    git ls-files --others --exclude-standard
} 2>/dev/null | grep -E '^Garage/(.*\.swift|Localizable\.xcstrings)$' || true)
[[ -n "$changed" ]] || exit 0

keys=$(jq -r '.strings | to_entries[]
  | select(.value.shouldTranslate != false)
  | .key as $k | .value as $v | $v.localizations.ru as $ru
  | select($v.extractionState == "stale"
      or $ru == null
      or ([$ru | .. | .state? // empty] | any(. != "translated"))
      or ($ru.variations.plural != null
          and ([$ru.variations.plural | has("one","few","many","other")] | all | not)))
  | $k' "$catalog")
[[ -n "$keys" ]] || exit 0

echo "Untranslated keys: $(paste -sd ',' - <<<"$keys" | sed 's/,/, /g')" >&2
echo "Add/fix the ru translations in $catalog (state: translated; plurals need one/few/many/other)." >&2
exit 2
