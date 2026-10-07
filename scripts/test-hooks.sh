#!/bin/bash
# Кейсы хуков из .claude/hooks: подаёт им JSON, как Claude Code, и сверяет код выхода
# (и, где важно, текст stderr). Всё работает во временном каталоге, репозиторий не трогается.
# Вызывается из секции `architecture` в scripts/check.sh.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
hooks=$root/.claude/hooks
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

: "${DEVELOPER_DIR:=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer}"
export DEVELOPER_DIR

failures=0
input=""

# expect <hook> <case> <код> <подстрока stderr или ""> -- <команда...>; stdin — $input.
expect() {
    local hook=$1 name=$2 want=$3 needle=$4 got=0 err
    shift 5
    err=$("$@" <<<"$input" 2>&1 >/dev/null) || got=$?
    if [[ "$got" == "$want" && ( -z "$needle" || "$err" == *"$needle"* ) ]]; then
        echo "PASS $hook: $name"
    else
        echo "FAIL $hook: $name (exit $got, expected $want${needle:+ with \"$needle\"})" >&2
        [[ -z "$err" ]] || sed 's/^/    /' <<<"$err" >&2
        failures=$((failures + 1))
    fi
}

# --- deny-shell-writes.sh -------------------------------------------------------------
proj=$tmp/proj
outside=$tmp/scratchpad
mkdir -p "$proj" "$outside"

# shell_case <код> <case> <команда для Bash tool>
shell_case() {
    input=$(jq -n --arg cmd "$3" --arg cwd "$proj" '{tool_name: "Bash", cwd: $cwd, tool_input: {command: $cmd}}')
    expect deny-shell-writes "$2" "$1" "$([[ $1 == 2 ]] && echo 'Write/Edit')" \
        -- env CLAUDE_PROJECT_DIR="$proj" "$hooks/deny-shell-writes.sh"
}

shell_case 2 'echo > relative file' 'echo x > a.swift'
shell_case 2 'append to relative file' 'echo x >> docs/a.md'
shell_case 2 'no space before target' 'echo x>a.swift'
shell_case 2 'clobber >|' 'printf x >| notes.txt'
shell_case 2 '&> to file' 'xcodebuild build &> build.log'
shell_case 2 'tee' 'swift test | tee out.txt'
shell_case 2 'tee -a' 'echo x | tee -a log.txt'
shell_case 2 'heredoc into file' $'cat <<EOF > Sources/A.swift\nlet a = 1\nEOF'
shell_case 2 'heredoc via tee' $'tee README.md <<\'EOF\'\n# Title\nEOF'
shell_case 2 'absolute path in project' "echo x > $proj/Garage/A.swift"
shell_case 2 'quoted target in project' 'echo x > "Garage/My File.swift"'
shell_case 2 'variable pointing into project' "DIR=$proj/docs; echo x > \$DIR/a.md"
shell_case 2 'unresolved variable' 'echo x > $UNKNOWN_DIR_FOR_HOOK_TEST/a.md'
shell_case 2 'second command in chain' 'swift build 2>&1 && echo done > status.txt'
shell_case 2 'relative cd inside project' '(cd docs && echo x > a.md)'
shell_case 2 'cd into project' "cd $proj && echo x > a.txt"
shell_case 2 'last assignment wins' "X=/tmp/a; X=$proj/b; echo x > \$X/c"
shell_case 2 '.. that stays in project' 'echo x > Garage/../a.swift'
shell_case 2 'tee after redirect-stripped args' 'swift test 2>/dev/null | tee result.txt'

shell_case 0 '2>&1' 'swift test 2>&1 | tail -20'
shell_case 0 '>&2' 'echo oops >&2'
shell_case 0 '/dev/null' 'git fetch > /dev/null 2>&1'
shell_case 0 '&>/dev/null' 'xcrun simctl list &>/dev/null'
shell_case 0 '/tmp' 'echo x > /tmp/hook-test.txt'
shell_case 0 'scratchpad' "echo x > $outside/out.txt"
shell_case 0 'scratchpad via variable' "TMP=$outside/e2e; openssl rand -hex 16 > \$TMP/secret"
shell_case 0 'tee to scratchpad' "swift test 2>&1 | tee $outside/test.log"
shell_case 0 '> inside quotes' 'echo "a > b" | grep ">"'
shell_case 0 'escaped >' 'echo a \> b'
shell_case 0 'heredoc commit message' $'git commit -m "$(cat <<\'EOF\'\nFix > and >> in docs\nEOF\n)"'
shell_case 0 'heredoc as stdin' $'jq . <<EOF\n{"a": "x > y"}\nEOF'
shell_case 0 'here-string' 'jq . <<< "{}"'
shell_case 0 'no redirect' 'xcodebuild -project Garage.xcodeproj -list | grep -A5 Schemes'
shell_case 0 'committee is not tee' 'echo committee'
shell_case 0 'arithmetic comparison' 'n=3; (( n > 0 )) && echo yes'
shell_case 0 'arithmetic expansion' 'echo $(( 5 > 3 ))'
shell_case 0 '[[ ]] string comparison' '[[ $a > $b ]] && echo later'
shell_case 0 'cd to scratchpad, relative target' "(cd $outside/e2e && openssl rand -hex 16 > secret)"
shell_case 0 'cd to unknown dir' '(cd $SOME_UNSET_DIR_FOR_HOOK_TEST && make > out.txt)'
shell_case 0 'tee as grep argument' 'grep -n "tee" .claude/hooks/deny-shell-writes.sh'
shell_case 0 'tee as rg argument' 'rg tee scripts'
shell_case 0 'tee with stderr redirect' 'swift test | tee /tmp/x.log 2>/dev/null'
shell_case 0 'variable from mktemp' 'out=$(mktemp); swift test > $out'
shell_case 0 'variable from backticks' 'out=`mktemp`; swift test > $out'
shell_case 0 '.. leaving the project' 'echo x > ../outside.txt'

# --- format-xcproj.sh -----------------------------------------------------------------
xproj=$tmp/xproj
mkdir -p "$xproj"
cp -R "$root/Garage.xcodeproj" "$xproj/Garage.xcodeproj"
rm -rf "$xproj/Garage.xcodeproj/xcuserdata"
xcproj=$xproj/Garage.xcodeproj/project.xcproj

edit_case() {
    input=$(jq -n --arg path "$3" '{tool_name: "Edit", tool_input: {file_path: $path}}')
    expect format-xcproj "$2" "$1" "${4:-}" -- env CLAUDE_PROJECT_DIR="$xproj" "$hooks/format-xcproj.sh"
}

edit_case 0 'valid project' "$xcproj"
edit_case 0 'not a project file' "$xproj/Garage/A.swift"
edit_case 0 'project outside CLAUDE_PROJECT_DIR' "$tmp/elsewhere/Garage.xcodeproj/project.xcproj"
awk '/"kind":/ && !removed { removed = 1; next } { print }' "$xcproj" >"$tmp/broken.xcproj"
cp "$tmp/broken.xcproj" "$xcproj"
edit_case 2 'package entry without "kind"' "$xcproj" 'xcprojformatter --update failed'

# --- check-translations.sh ------------------------------------------------------------
repo=$tmp/repo
mkdir -p "$repo/scripts" "$repo/Garage"
cp "$root/scripts/check.sh" "$repo/scripts/check.sh"
catalog=$repo/Garage/Localizable.xcstrings
translated='{"sourceLanguage": "en", "version": "1.0", "strings": {
  "Hello": {"localizations": {"ru": {"stringUnit": {"state": "translated", "value": "Привет"}}}}}}'
untranslated='{"sourceLanguage": "en", "version": "1.0", "strings": {
  "Hello": {"localizations": {"ru": {"stringUnit": {"state": "translated", "value": "Привет"}}}},
  "Goodbye": {}}}'
printf '%s\n' "$untranslated" >"$catalog"
printf 'let a = 1\n' >"$repo/Garage/A.swift"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.name=hooks -c user.email=hooks@example.invalid commit -qm init

stop_case() {
    input=$2
    expect check-translations "$3" "$1" "${4:-}" -- env CLAUDE_PROJECT_DIR="$repo" "$hooks/check-translations.sh"
}

stop_case 0 '{}' 'no changes since HEAD'
printf 'let a = 2\n' >"$repo/Garage/A.swift"
stop_case 2 '{}' 'swift changed, key without ru' 'Goodbye'
stop_case 0 '{"stop_hook_active": true}' 'stop_hook_active prevents a loop'
printf '%s\n' "$translated" >"$catalog"
stop_case 0 '{}' 'catalog fully translated'

if ((failures > 0)); then
    echo "test-hooks.sh: $failures case(s) failed" >&2
    exit 1
fi
echo "test-hooks.sh: all cases passed"
