#!/bin/bash
# Static checks, no running app needed: shell, AppleScript and JavaScript
# syntax, Lua syntax (with Hammerspoon's Lua if it is running, else `luac`),
# and a round trip of the settings.json editor.
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
ok()   { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf '  skip  %s\n' "$*"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "Shell"
for f in install.sh uninstall.sh src/hook.sh scripts/*.sh tests/*.sh; do
  bash -n "$f" && ok "$f" || fail "$f"
done
if command -v shellcheck >/dev/null; then
  shellcheck -S warning install.sh uninstall.sh src/hook.sh scripts/*.sh tests/*.sh && ok shellcheck || fail shellcheck
else
  skip "shellcheck (not installed)"
fi

echo "AppleScript / JavaScript"
osacompile -o "$TMP/r.scpt" src/router.applescript 2>/dev/null && ok src/router.applescript || fail src/router.applescript
for f in src/send-url.js src/url-handler.js scripts/claude-settings.js; do
  osacompile -l JavaScript -o "$TMP/j.scpt" "$f" 2>/dev/null && ok "$f" || fail "$f"
done

echo "Lua"
HS=/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs
for f in src/init.lua src/strings.lua config.example.lua; do
  if pgrep -xq Hammerspoon && [ -x "$HS" ]; then
    for _ in 1 2 3; do  # hs refuses calls for a moment after a reload: retry
      out=$(perl -e 'alarm shift; exec @ARGV' 10 "$HS" -c "local f, e = loadfile('$PWD/$f'); return f and 'ok' or e" 2>&1)
      [ "$out" = ok ] && break; sleep 2
    done
    [ "$out" = ok ] && ok "$f" || fail "$f: $out"
  elif command -v luac >/dev/null; then
    luac -p "$f" && ok "$f" || fail "$f"
  else
    skip "$f (start Hammerspoon or install luac)"
  fi
done

echo "settings.json editor"
cat > "$TMP/settings.json" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "Stop": [ { "hooks": [ { "type": "command", "command": "say done" } ] } ]
  }
}
EOF
cp "$TMP/settings.json" "$TMP/orig.json"
J="osascript -l JavaScript scripts/claude-settings.js"
$J add "$TMP/settings.json" /x/claude-tabs/hook.sh >/dev/null
$J add "$TMP/settings.json" /x/claude-tabs/hook.sh >/dev/null   # twice: must not duplicate
n=$(grep -c 'claude-tabs/hook.sh' "$TMP/settings.json")
[ "$n" = 5 ] && ok "add is idempotent (5 hooks)" || fail "add: expected 5 hooks, got $n"
grep -q '"say done"' "$TMP/settings.json" && ok "other hooks kept" || fail "other hooks lost"
$J remove "$TMP/settings.json" "" >/dev/null
norm() { tr -d ' \n' < "$1"; }
[ "$(norm "$TMP/settings.json")" = "$(norm "$TMP/orig.json")" ] && ok "remove restores the file" || fail "remove did not restore the file"

echo
if [ "$fails" = 0 ]; then echo "All checks passed."; else echo "$fails check(s) failed."; fi
exit "$fails"
