#!/bin/bash
# Live test of an installed Claude Tabs: Hammerspoon must be running with
# Claude Tabs loaded, and at least one configured account open in Claude.
# Sends fake hook events for a fake session and checks the counters, then
# checks the layout and the claude:// handler. Leaves nothing behind.
set -uo pipefail

HS=/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs
HOOK="$HOME/.hammerspoon/claude-tabs/hook.sh"
fails=0
ok()   { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
# hs alone has no time limit, and refuses calls for a moment after a reload: cap and retry.
q()    { local r i; for i in 1 2 3; do r=$(perl -e 'alarm shift; exec @ARGV' 15 "$HS" -c "$1" 2>/dev/null) && { printf '%s\n' "$r"; return 0; }; sleep 2; done; return 1; }

pgrep -xq Hammerspoon || { echo "Hammerspoon is not running."; exit 1; }
[ "$(q 'return ClaudeTabs ~= nil')" = true ] || { echo "Claude Tabs is not loaded (run install.sh)."; exit 1; }

PID=$(q 'for _, a in ipairs(hs.application.applicationsForBundleID("com.anthropic.claudefordesktop")) do return a:pid() end return ""')
[ -n "$PID" ] || { echo "No Claude instance running."; exit 1; }
SID="ct$(printf '%06d' $(( (RANDOM * 32768 + RANDOM) % 1000000 )))-claude-tabs-test"
SHORT=${SID:0:8}
q "ClaudeTabs.forgetSession('ct*')" >/dev/null                 # leftovers of interrupted runs
q "ClaudeTabs.forgetSession('claude-tabs-test*')" >/dev/null   # (older naming)

# Sends one hook event the way Claude Code would, then reads the test session's state.
send() {
  printf '{"session_id":"%s"%s}' "$SID" "${2:-}" | CLAUDE_TABS_TEST_PID=$PID "$HOOK" "$1"
  sleep 1
  q 'return ClaudeTabs.state()' | awk -v s="$SHORT" '$1 == s { print $2 }'
}
expect() { [ "$2" = "$3" ] && ok "$1 -> ${3:-gone}" || fail "$1: expected '${3:-gone}', got '${2:-gone}'"; }

echo "Session counters (pid $PID)"
expect "prompt"                "$(send prompt)" working
expect "listed as working"     "$(q 'return ClaudeTabs.sessions()' | awk -v s="$SHORT" '$5 == s { print $2 }')" working
expect "idle reminder ignored" "$(send attention ',"notification_type":"idle_prompt"')" working
expect "question asked"        "$(send attention ',"notification_type":"permission_prompt"')" attention
expect "question answered"     "$(send answered)" working
expect "stop"                  "$(send stop)" done
q "ClaudeTabs.forgetSession('$SID')" >/dev/null
expect "cleanup"               "$(q 'return ClaudeTabs.state()' | awk -v s="$SHORT" '$1 == s { print $2 }')" ""

echo "Layout"
[ "$(q 'return ClaudeTabs.layoutOk()')" = true ] && ok "bar and front window in place" \
  || fail "layout: $(q 'return ClaudeTabs.geometry()')"

echo "Session ring"
n=$(q 'return ClaudeTabs.ring and ClaudeTabs.ring.text() or "none"' | grep -c '^[0-9]')
[ "$n" -ge 1 ] && ok "ring lists $n session(s)" || fail "ring: $(q 'return ClaudeTabs.ring and ClaudeTabs.ring.text() or "none"' | head -3)"

echo "Hand-off command"
CT="$HOME/.hammerspoon/claude-tabs/claude-tabs"
n=$("$CT" accounts 2>/dev/null | awk 'NR > 1 && NF >= 3 && $3 ~ /running|closed/' | wc -l | tr -d ' ')
[ "$n" -ge 1 ] && ok "accounts lists $n account(s)" || fail "accounts: $("$CT" accounts 2>&1 | head -3)"
out=$("$CT" handoff --to no-such-account "test" 2>&1)
case "$out" in *"unknown account"*) ok "unknown account refused" ;; *) fail "handoff: $out" ;; esac

echo "claude:// handler"
h=$(osascript -l JavaScript "$HOME/.hammerspoon/claude-tabs/url-handler.js" get 2>&1)
[ "$h" = com.anthropic.claudefordesktop ] && ok "Claude handles claude:// links" || fail "handler is $h"

echo
if [ "$fails" = 0 ]; then echo "Smoke test passed."; else echo "$fails test(s) failed."; fi
exit "$fails"
