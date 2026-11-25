#!/bin/bash
# Removes Claude Tabs. Keeps your config.lua and tabs (profiles.json) unless you pass --purge.
# Never touches your accounts' data folders (~/.claude-profiles/…): they hold
# your sign-ins and sessions. Delete them yourself if you want them gone.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
HSDIR="$HOME/.hammerspoon"
DEST="$HSDIR/claude-tabs"
APPS="$HOME/Applications/Claude Tabs"
ROUTER="$APPS/Claude Tabs Link Router.app"
SETTINGS="$HOME/.claude/settings.json"
HS=/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

# claude:// links back to Claude, in case sign-in mode was on.
if [ "$(osascript -l JavaScript "$SRC/src/url-handler.js" get 2>/dev/null)" = local.claudetabs.router ]; then
  osascript -l JavaScript "$SRC/src/url-handler.js" set com.anthropic.claudefordesktop >/dev/null
fi

# Hooks
[ -f "$SETTINGS" ] && osascript -l JavaScript "$SRC/scripts/claude-settings.js" remove "$SETTINGS" "" >/dev/null

# Loader block in ~/.hammerspoon/init.lua
if [ -f "$HSDIR/init.lua" ]; then
  TMP=$(mktemp)
  awk '
    /^-- >>> claude-tabs/ { skip = 1; next }
    /^-- <<< claude-tabs/ { skip = 0; next }
    skip { next }
    /^ClaudeTabs = require\("claude-tabs"\)/ || /^ClaudeTabs\.start\(\)/ { next }
    /^-- Claude Tabs : onglets pour plusieurs profils Claude Desktop/ { next }
    { print }
  ' "$HSDIR/init.lua" > "$TMP" && mv "$TMP" "$HSDIR/init.lua"
fi

# Launchers and router
[ -d "$ROUTER" ] && "$LSREGISTER" -u "$ROUTER" 2>/dev/null || true
rm -rf "$APPS"

# Module (config.lua and profiles.json kept unless --purge)
if [ -d "$DEST" ]; then
  if [ "$PURGE" = 1 ]; then
    rm -rf "$DEST"
  else
    find "$DEST" -mindepth 1 ! -name config.lua ! -name profiles.json -exec rm -rf {} +
  fi
fi

# Saved state (group position, session counters) and reload
if pgrep -xq Hammerspoon; then
  if [ "$PURGE" = 1 ]; then
    "$HS" -c 'for _, k in ipairs({"claudeTabs.groupFrame", "claudeTabs.sessions"}) do hs.settings.clear(k) end' >/dev/null 2>&1 || true
  fi
  "$HS" -c 'hs.reload()' >/dev/null 2>&1 || true
fi

echo "Claude Tabs removed."
[ "$PURGE" = 1 ] || echo "Kept $DEST/config.lua and profiles.json (use --purge to remove them)."
echo "Your accounts' data folders (~/.claude-profiles/…) were not touched."
