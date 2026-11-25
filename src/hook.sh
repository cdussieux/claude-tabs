#!/bin/bash
# Claude Tabs: Claude Code hook (UserPromptSubmit, Stop, Notification,
# PreToolUse/PostToolUse on AskUserQuestion).
# Finds the Claude Desktop instance that runs this session (by walking up the
# parent processes) and tells the Hammerspoon tab bar.
# Usage: hook.sh prompt|stop|attention|answered   (the hook's JSON comes on stdin)
# Does nothing for sessions outside Claude Desktop, or when Hammerspoon is not
# running. Never writes to stdout.
# CLAUDE_TABS_TEST_PID=<pid> skips the process walk (used by the tests).

event="$1"
input=$(cat)

/usr/bin/pgrep -xq Hammerspoon || exit 0

# The "Claude is waiting for your input" reminder (after 60 s idle) is not a real request.
if [ "$event" = attention ] && printf '%s' "$input" | grep -q '"notification_type"[[:space:]]*:[[:space:]]*"idle_prompt"'; then
  exit 0
fi

session=$(printf '%s' "$input" | tr -d '\n' \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p')

notify() {
  /usr/bin/open -g "hammerspoon://claude-tabs?event=${event}&pid=$1&session=${session}"
}

if [ -n "$CLAUDE_TABS_TEST_PID" ]; then
  notify "$CLAUDE_TABS_TEST_PID"
  exit 0
fi

p=$PPID
while [ -n "$p" ] && [ "$p" -gt 1 ]; do
  case "$(/bin/ps -p "$p" -o comm= 2>/dev/null)" in
    */Claude.app/Contents/MacOS/Claude)
      notify "$p"
      exit 0
      ;;
  esac
  p=$(/bin/ps -p "$p" -o ppid= 2>/dev/null | tr -d ' ')
done
exit 0
