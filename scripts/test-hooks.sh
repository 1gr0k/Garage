#!/bin/bash
# Кейсы хуков из .claude/hooks: подаёт им JSON, как Claude Code, и сверяет код выхода
# (и, где важно, текст stderr). Всё работает во временном каталоге, репозиторий не трогается.
# Вызывается из секции `architecture` в scripts/check.sh.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
hooks=$root/.claude/hooks
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Путь к Xcode по умолчанию — только на macOS; на Linux (CI) xcprojformatter нет.
if [[ "$(uname)" == Darwin ]]; then
    : "${DEVELOPER_DIR:=/Applications/Xcode-27.2.0-Beta.2.app/Contents/Developer}"
    export DEVELOPER_DIR
fi
formatter=${DEVELOPER_DIR:+$DEVELOPER_DIR/usr/bin/xcprojformatter}

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

# Кейсы, которые реально запускают xcprojformatter, пропускаются без него (Linux).
if [[ -n "$formatter" && -x "$formatter" ]]; then
    edit_case 0 'valid project' "$xcproj"
else
    echo "SKIP format-xcproj: valid project (no xcprojformatter)"
fi
edit_case 0 'not a project file' "$xproj/Garage/A.swift"
edit_case 0 'project outside CLAUDE_PROJECT_DIR' "$tmp/elsewhere/Garage.xcodeproj/project.xcproj"
if [[ -n "$formatter" && -x "$formatter" ]]; then
    awk '/"kind":/ && !removed { removed = 1; next } { print }' "$xcproj" >"$tmp/broken.xcproj"
    cp "$tmp/broken.xcproj" "$xcproj"
    edit_case 2 'package entry without "kind"' "$xcproj" 'xcprojformatter --update failed'
else
    echo "SKIP format-xcproj: package entry without \"kind\" (no xcprojformatter)"
fi

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

# --- session-context.sh ---------------------------------------------------------------
# Хук пишет сводку в stdout, поэтому сверяем stdout (и число строк), а не stderr.
ctx=$tmp/ctx
mkdir -p "$ctx/docs/plans"
git -C "$ctx" init -q -b master
printf 'a\n' >"$ctx/a.txt"
printf '# Stage 9\n\n**Статус: выполнен** — PR\n' >"$ctx/docs/plans/stage-9-old.md"
printf '# Stage 10\n\nin progress\n' >"$ctx/docs/plans/stage-10-new.md"
git -C "$ctx" add -A
git -C "$ctx" -c user.name=hooks -c user.email=hooks@example.invalid commit -qm one
base=$(git -C "$ctx" rev-parse HEAD)
git -C "$ctx" update-ref refs/remotes/origin/master "$base"
# Сеть не нужна: удалённый репозиторий недостижим, хук обязан читать только локальные ссылки.
git -C "$ctx" remote add origin https://invalid.example.invalid/none.git

# context_case <case> <ожидаемая подстрока> <present|absent>
context_case() {
    local out
    out=$(CLAUDE_PROJECT_DIR="$ctx" "$hooks/session-context.sh" </dev/null 2>&1) || {
        echo "FAIL session-context: $1 (hook exited non-zero)" >&2
        failures=$((failures + 1))
        return
    }
    if [[ ( "$3" == present && "$out" == *"$2"* ) || ( "$3" == absent && "$out" != *"$2"* ) ]] \
        && (($(wc -l <<<"$out") <= 10)); then
        echo "PASS session-context: $1"
    else
        echo "FAIL session-context: $1 (wanted $3 \"$2\", at most 10 lines)" >&2
        sed 's/^/    /' <<<"$out" >&2
        failures=$((failures + 1))
    fi
}

context_case 'branch name' 'Branch: master' present
context_case 'in sync with origin/master' '0 behind, 0 ahead' present
context_case 'clean tree' 'Uncommitted: none' present
# stage-10 по номеру последний; при сортировке по строке им был бы stage-9 (с отметкой) — тест отличает.
context_case 'latest plan by number is unmarked' 'Plan not marked done: docs/plans/stage-10-new.md' present
printf 'b\n' >"$ctx/b.txt"
context_case 'untracked file listed' '  b.txt' present
for n in 1 2 3 4 5 6 7; do printf 'x\n' >"$ctx/extra$n.txt"; done
context_case 'many files are collapsed to a count' '… and 3 more' present
rm -f "$ctx"/extra*.txt "$ctx/b.txt"
printf '# Stage 10\n\n**Статус: выполнен** — PR\n' >"$ctx/docs/plans/stage-10-new.md"
context_case 'marked latest plan is silent' 'Plan not marked done' absent
# Второй уровень плана (`-notes.md`) отметки не несёт и не должен считаться планом без статуса.
printf '# Stage 10 notes\n\nno status here\n' >"$ctx/docs/plans/stage-10-new-notes.md"
context_case 'notes file of a marked plan is silent' 'Plan not marked done' absent
rm -f "$ctx/docs/plans/stage-10-new-notes.md"
printf 'c\n' >"$ctx/c.txt"
git -C "$ctx" add -A
git -C "$ctx" -c user.name=hooks -c user.email=hooks@example.invalid commit -qm two
context_case 'ahead of origin/master' '0 behind, 1 ahead' present
git -C "$ctx" reset -q --hard "$base"
remote_tip=$(git -C "$ctx" -c user.name=hooks -c user.email=hooks@example.invalid commit-tree -p "$base" -m remote 'HEAD^{tree}')
git -C "$ctx" update-ref refs/remotes/origin/master "$remote_tip"
context_case 'behind and ahead after divergence' '1 behind, 0 ahead' present
git -C "$ctx" update-ref -d refs/remotes/origin/master
context_case 'no origin/master ref' 'origin/master: no local ref' present

nogit=$tmp/nogit
mkdir -p "$nogit"
out=$(CLAUDE_PROJECT_DIR="$nogit" "$hooks/session-context.sh" </dev/null 2>&1) && rc=0 || rc=$?
if [[ "$rc" == 0 && -z "$out" ]]; then
    echo "PASS session-context: not a git repository"
else
    echo "FAIL session-context: not a git repository (exit $rc, output: $out)" >&2
    failures=$((failures + 1))
fi

if ((failures > 0)); then
    echo "test-hooks.sh: $failures case(s) failed" >&2
    exit 1
fi
echo "test-hooks.sh: all cases passed"
