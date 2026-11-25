# How it works, and the pitfalls

## Files once installed

| Where | What |
|---|---|
| `~/.hammerspoon/claude-tabs/` | the module (`init.lua`, `strings.lua`), `config.lua`, `hook.sh`, `send-url.js`, `url-handler.js` |
| `~/.hammerspoon/init.lua` | a block between `-- >>> claude-tabs` and `-- <<< claude-tabs` that loads it |
| `~/Applications/Claude Tabs/` | one launcher per account, and `Claude Tabs Link Router.app` |
| `~/.claude/settings.json` | the hooks (first backup: `settings.json.bak-claude-tabs`) |
| `~/.claude-profiles/<id>/` | each extra account's Claude data folder (sign-in, Code sessions) |

## Pitfalls met on the way

- **`CLAUDE_USER_DATA_DIR` is ignored** by signed Claude builds. The
  `--user-data-dir=` switch works.
- **`hammerspoon://` event names are lowercased** by macOS: `claudeTabs` arrives
  as `claudetabs`. Use lowercase names (`claude-tabs`).
- **Signing in to a second instance**: the browser's "Open Claude" link goes to
  the first instance. When Claude is not the `claude://` handler, it signs in
  through `ASWebAuthenticationSession` instead, which answers the instance that
  asked. Sign-in mode makes a router app the handler for a moment to trigger
  that, then gives the handler back. Claude re-registers itself as handler at
  every launch anyway.
- **Sending a link to one instance**: `send-url.js` sends the `GURL` Apple Event
  to a pid, which `open` cannot do.
- **Full-screen windows** live on their own Space and cannot be stacked: they
  are taken out of full screen first.
- **Claude ignores a small shrink** of its window sometimes (e.g. when the Dock
  appears): going through a smaller size first works.
- **The usable area of a screen changes** with the Dock moving between screens,
  without any screen event: a 2-second check keeps the group in place.
- **Hooks fire for sessions already open**: Claude Code picks up hook changes
  without a restart.
- **The Stop hook does not fire on an interrupted turn** (Esc): the session
  file's `lastTurnEdgeAt` moving past the start of the turn ends it.
- **`lastFocusedAt` only changes when you switch sessions**, not while you look
  at one: the session shown when a window comes forward counts as seen, and a
  session that finishes while shown in the front window never counts as unread.
- **Event taps run on Hammerspoon's main thread**: a test that posts mouse
  events in a blocking loop never reaches them; post them from timers.
