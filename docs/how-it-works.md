# How it works, and the pitfalls

## Files once installed

| Where | What |
|---|---|
| `~/.hammerspoon/claude-tabs/` | the module (`init.lua`, `strings.lua`), `config.lua`, `profiles.json` (the tabs), `hook.sh`, `send-url.js`, `url-handler.js`, the `claude-tabs` command, `accounts.tsv` (what `claude-tabs accounts` reads) and `handoff/` (briefs on their way) |
| `~/.hammerspoon/init.lua` | a block between `-- >>> claude-tabs` and `-- <<< claude-tabs` that loads it |
| `~/Applications/Claude Tabs/` | one launcher per account, and `Claude Tabs Link Router.app` |
| `~/.claude/settings.json` | the hooks (first backup: `settings.json.bak-claude-tabs`) |
| `~/.claude/skills/claude-tabs-handoff/` | the hand-off skill, read by every account's Claude Code |
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
  where the reset time comes from. Claude rounds it down ("3d" was 3 d 17 h),
  in hours on the last day. Each reading is a window ("between 3 and 4 days
  from now"); Claude Tabs keeps the intersection of the windows, moved by
  whole weeks, and starts over if a new one does not fit (schedule changed).
- The history gives the other clue: the weekly % only grows until the reset,
  so a drop between two readings a few minutes apart dates it.
- If you know an account's exact reset from elsewhere (claude.ai usage
  settings, a Claude session's usage tool), give it once:
  `hs -c 'ClaudeTabs.setReset("<id>", <epoch seconds>)'`. It holds for the
  following weeks.

## Session states

The hooks say when a turn starts, stops, or stops for a permission or a
question. Three things they miss, read from Claude's files instead:

- **Agents left running in the background.** A session can end its turn
  ("the interface agent is still working, I'll pick up its report") while
  agents keep working; Claude shows it as busy, the `Stop` hook said done. Their
  transcripts are `~/.claude/projects/<folder>/<cli id>/subagents/agent-*.jsonl`;
  one written in the last 3 min counts as at work. Their last line does not say
  whether they are finished (it is often a tool result), so the date is the
  only signal. `<folder>` is the session's `cwd` with every character other
  than a letter or digit turned into `-`; a session moved to another folder
  keeps its old one, so Claude Tabs falls back to looking for `<cli id>.jsonl`
  in every folder (then remembers it).
- **Turns Claude starts by itself** (when such an agent reports back) fire no
  `UserPromptSubmit`. The main transcript, when written in the last minute and
  not ending with an assistant message whose `stop_reason` is `end_turn`,
  counts as a turn going on.
- **A question asked in the last message.** After each turn Claude writes a
  `postTurnSummary` in the session file: `status_category` (`completed`,
  `blocked`, `review_ready`…), `status_detail`, and `needs_action` (what it needs
  from you, in the session's language). It is about the last turn only when
  `postTurnSummaryFor` equals `lastAssistantUuid`. A non-empty `needs_action`
  (or `blocked`) makes the session "waiting for you" until its next turn, for
  24 h at most (`waitingMaxAge`), or until you ⌥-click it away (kept in
  `hs.settings` "claudeTabs.dismissed", per session and turn).

Claude Desktop's own "Sessions waiting for you" (Dock menu) only counts
pending permissions (`pendingToolPermissions`, kept in memory, not in the
file); the hooks already see those.

Session files are decoded only when their date changed, and only those touched
in the last 24 h plus the ones the hooks track: a full pass takes 10 to 20 ms.

Opening a session: `claude://code/continue?session=local_…` (the link Claude's
Dock menu and Spotlight use), sent to the account's instance like a sign-in
link. To check from a terminal:

```bash
hs -c 'return ClaudeTabs.sessions()'        # what each tab shows
hs -c 'return ClaudeTabs.menuText("queue")' # the red button's menu (or a tab's id)
```

## Hand-off between accounts

What every account shares, because Claude Code runs with the same `~/.claude`:
`CLAUDE.md`, skills, memory, settings, hooks, transcripts, and the list of live
sessions (`~/.claude/sessions/<pid>.json`, with one socket each in
`/tmp/cc-socks`). That list is what Claude Code's own messages between
sessions use, so a session can already message one in another account. What
is not shared lives on claude.ai: connectors, chats, artifacts, usage limits.

So Claude Tabs does not carry messages. It starts work in another account:

1. `claude-tabs handoff` writes the brief to `handoff/<id>.prompt` and opens
   `hammerspoon://claude-tabs-handoff?id=…&to=…&folder=…&from=<Claude pid>`
   (the pid of the instance it runs in, found like `hook.sh` does).
2. Claude Tabs picks the account (`auto`: the most weekly usage left, other
   than the sender's; one past 90 % of its 5-hour limit comes after the
   others), starts it if needed, and sends it
   `claude://code/new?q=<brief>&folder=<folder>`: Claude's own link for a new
   Code session, the one its Finder service uses. The prompt is typed in, not
   sent; Claude keeps its first 14,336 characters.
3. With `handoffAutoSend = true`, Claude Tabs then presses Enter for you,
   through macOS accessibility (it asks Electron to expose its interface with
   `AXManualAccessibility`). It waits up to 25 s until a text area of that
   account holds the brief, the account is in front, that text area has the
   focus and you have not touched keyboard or mouse for 1 s; then it checks the text area
   emptied. Anything else in front, such as a "trust this folder?" prompt,
   and the brief stays typed for you: it never presses Enter on something
   else.
4. The answer goes to `handoff/<id>.result`, which the command waits for:
   `ok`, the account, then `sent` or `typed: <why not>`.

Without auto-send the brief stays a prompt you send yourself: a message from
another session is only a teammate's request to the agent that gets it, while
a prompt you send is your instruction. With auto-send, the agent's brief gets
that weight without you reading it: keep it for agents you trust to ask you
first (the skill tells them to). With `--from "<session name>"`, the brief ends by asking the new
session to report back to the sender.

```bash
~/.hammerspoon/claude-tabs/claude-tabs accounts
~/.hammerspoon/claude-tabs/claude-tabs handoff --to perso "Say hello"
```

## Session ring

`src/ring.lua`, built by `init.lua` with what it needs (the list, how to open
a session, colours). The list: every account's `local_*.json` sorted by date,
then the newest ones read until `ringCount` are not archived, sorted by
`lastActivityAt`. The ring started as its own Hammerspoon module and opened in
~380 ms: decoding the whole file (~200 KB, with dozens of nested `"title"`
keys from MCP tools). It now reads `sessionId`, `isArchived`,
`lastActivityAt` and the session's title (the `"title"` just before
`"titleSource"`) from the text, cached by date, and decodes the whole file
only when that fails. The state comes from what the tabs already computed.

The ring is a canvas at the pointer, moved back inside the screen near an
edge. While it is open an event tap swallows clicks (a click never reaches
the window under it); Esc, right-click or the middle closes it. Opening a
session in a closed account starts that account first, waits for its window,
then sends `claude://code/continue?session=…`.

```bash
hs -c 'return ClaudeTabs.ring.text()'                 # the slices, clockwise
hs -c 'return ClaudeTabs.ring.snapshot("/tmp/r.png", 2)' # a picture, slice 2 lit
```

