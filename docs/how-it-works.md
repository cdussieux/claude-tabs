# How it works, and the pitfalls

## Files once installed

| Where | What |
|---|---|
| `~/.hammerspoon/claude-tabs/` | the module (`init.lua`, `strings.lua`), `config.lua`, `profiles.json` (the tabs), `hook.sh`, `send-url.js`, `url-handler.js` |
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
- **Knowing which tab is signing in**: Claude logs `[Auth] Using system browser for:` when a
  window starts a browser sign-in (the log is shared by all instances, without pid); the
  window in front at that moment is the one signing in.
- **Claude keeps its log file open**, so macOS file events never report its
  writes: the log is polled every second (by size) instead.
- **The browser comes forward before the log line is read**: the account
  signing in is then the last Claude tab that was in front.
- **The `hs` command line has no real time limit** (`-t` is not one) and hangs
  or refuses calls while Hammerspoon reloads: scripts cap it with
  `perl -e 'alarm N; exec @ARGV'` and retry.
- **Canvases only report left clicks**: right-clicks on the bar are caught with
  an event tap.
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

## Plan usage

- Claude Desktop appends each usage reading of its account to
  `<data dir>/plan-usage-history.json` (`{"version":2,"samples":[{"t":ms,"org":…,"u":{"fh":5-hour %,"sd":weekly %,…}}]}`),
  at most one sample every 4.5 min. Plain JSON, unencrypted: Claude Tabs takes
  the latest sample. No reset time in it.
- Claude polls usage every 15 min (5 min after you looked at it), but only while
  its tray usage menu was opened in the last 24 h (`[plan-usage] background poll
  paused: tray not opened recently` in `main.log`). It also reads once at launch.
- That menu opens on a **right-click** on Claude's menu bar icon (a left click
  opens the window). Each instance has its own icon, reachable through the
  accessibility API (`AXExtrasMenuBar` of the app). Claude Tabs right-clicks it
  only if `systemElementAtPosition` at that spot belongs to the same pid (icon
  not hidden), and presses Escape only once an `AXMenuItem` of that pid is
  under the icon, so the key can never reach a window and stop a session.
- The open menu's rows read "Weekly · all models" / "12% · Resets 2d": that is
  where the reset time comes from (rounded by Claude).
