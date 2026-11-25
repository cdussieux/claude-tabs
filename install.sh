#!/bin/bash
# Installs Claude Tabs (or updates it; run it again after a `git pull`):
#  - the Hammerspoon module in ~/.hammerspoon/claude-tabs (your config.lua is kept)
#  - a block that loads it in ~/.hammerspoon/init.lua
#  - the "Claude Tabs Link Router" app in ~/Applications/Claude Tabs
#  - the Claude Code hooks in ~/.claude/settings.json (backed up once first)
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
HSDIR="$HOME/.hammerspoon"
DEST="$HSDIR/claude-tabs"
APPS="$HOME/Applications/Claude Tabs"
ROUTER="$APPS/Claude Tabs Link Router.app"
SETTINGS="$HOME/.claude/settings.json"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "Claude Tabs needs macOS (see docs/linux.md)."
has_app() { osascript -e "id of application id \"$1\"" >/dev/null 2>&1; }
has_app org.hammerspoon.Hammerspoon || die "Hammerspoon is not installed: brew install --cask hammerspoon"
has_app com.anthropic.claudefordesktop || die "Claude Desktop is not installed: https://claude.ai/download"

# 1. The module
mkdir -p "$DEST"
cp "$SRC"/src/init.lua "$SRC"/src/strings.lua "$SRC"/src/hook.sh \
   "$SRC"/src/send-url.js "$SRC"/src/url-handler.js "$DEST"/
chmod +x "$DEST/hook.sh"
if [ ! -f "$DEST/config.lua" ]; then
  cp "$SRC/config.example.lua" "$DEST/config.lua"
  say "Created $DEST/config.lua: edit it to list your accounts."
fi

# 2. Load it from ~/.hammerspoon/init.lua (between markers, so uninstall.sh can remove it)
INIT="$HSDIR/init.lua"
touch "$INIT"
TMP=$(mktemp)
# Drop a previous block, and the unmarked lines of early versions.
awk '
  /^-- >>> claude-tabs/ { skip = 1; next }
  /^-- <<< claude-tabs/ { skip = 0; next }
  skip { next }
  /^ClaudeTabs = require\("claude-tabs"\)/ || /^ClaudeTabs\.start\(\)/ { next }
  /^-- Claude Tabs : onglets pour plusieurs profils Claude Desktop/ { next }
  { print }
' "$INIT" > "$TMP"
cat >> "$TMP" <<'EOF'
-- >>> claude-tabs (managed by claude-tabs/install.sh)
hs.autoLaunch(true)
require("hs.ipc")
ClaudeTabs = require("claude-tabs")
ClaudeTabs.start()
-- <<< claude-tabs
EOF
mv "$TMP" "$INIT"

# 3. The link router used by sign-in mode
mkdir -p "$APPS"
rm -rf "$ROUTER"
osacompile -o "$ROUTER" "$SRC/src/router.applescript"
PL="$ROUTER/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string local.claudetabs.router "$PL"
plutil -replace LSUIElement -bool true "$PL"
plutil -replace CFBundleURLTypes -json '[{"CFBundleURLName":"Claude Tabs link","CFBundleURLSchemes":["claude"]}]' "$PL"
codesign --force --deep -s - "$ROUTER" 2>/dev/null
"$LSREGISTER" -f "$ROUTER"

# 4. Claude Code hooks
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
[ -f "$SETTINGS.bak-claude-tabs" ] || cp "$SETTINGS" "$SETTINGS.bak-claude-tabs"
osascript -l JavaScript "$SRC/scripts/claude-settings.js" add "$SETTINGS" "$DEST/hook.sh" >/dev/null

# 5. (Re)load
HS=/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs
if pgrep -xq Hammerspoon; then
  # The reload drops the CLI's connection, so its exit code means nothing.
  if [ "$("$HS" -t 5 -c 'return 1' 2>/dev/null)" = 1 ]; then
    "$HS" -t 5 -c 'hs.reload()' >/dev/null 2>&1 || true
  else
    say "Reload Hammerspoon (menu bar icon > Reload Config)."
  fi
else
  open -a Hammerspoon
fi

say "Claude Tabs installed in $DEST"
say "Hooks added to $SETTINGS (first backup: $SETTINGS.bak-claude-tabs)"
say "First time? Give Hammerspoon Accessibility access: System Settings > Privacy & Security > Accessibility."
