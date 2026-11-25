# Claude Tabs

Browser-style tabs for several **Claude Desktop** accounts on macOS: one tab per
account, all in one window, with live counters of your Claude Code sessions.

```
┌──────────────────────────────────────────────────────────────────────┐
│ 1  Personal   ①②  │ 2  Work            ③ │ 3  Client · closed   │ + │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│              the Claude Desktop window of the active tab             │
│                                                                      │
```

Claude Desktop signs in to one account at a time. Claude Tabs runs one Claude
instance per account, each with its own data folder (so its own sign-in), and
stacks their windows under a tab bar drawn by [Hammerspoon](https://www.hammerspoon.org).

> Unofficial. Not affiliated with or endorsed by Anthropic. It relies on
> Claude Desktop details that are not a public API (data folder layout, session
> files, log lines) and may need fixes after a Claude update.

## Features

- **One tab per account**, any number of accounts. Click a tab, `⌃⌥1…9`, or
  `⌘ + scroll` (mouse or trackpad) to switch. A closed account starts on click.
- **Session counters on each tab**, for that account's Code sessions:
  🟠 working · 🟢 done and not read yet · 🔴 waiting for you (question or
  permission). A done session leaves the counter when you open it. Totals also
  sit in the menu bar (✳︎).
- **Plan usage on each tab**: the account's weekly usage and the time to its
  reset (`Team · 12% · 2d`), orange from 50%, red from 80%, dimmed when the
  reading is old. The menus add the 5-hour limit.
- **Behaves like one window**: drag the tab bar to move the group to another
  screen; it fills the screen it is on (`autoFill`), and follows the Dock and
  screens being plugged or woken up. `⌃⌥E` moves it to the next screen.
- **`+` button** after the last tab to add an account; **right-click a tab** to
  rename or remove it.
- **Sign-ins land in the right tab**: the browser's "Open Claude" link goes back
  to the tab that started the sign-in, automatically (see below).
- **Launchers**: `~/Applications/Claude Tabs/Claude <Account>.app`, for Spotlight.
- English and French interface.

## Requirements

- macOS, [Claude Desktop](https://claude.ai/download)
- [Hammerspoon](https://www.hammerspoon.org): `brew install --cask hammerspoon`

## Install

```bash
git clone https://github.com/cdussieux/claude-tabs.git
cd claude-tabs
./install.sh
```

Then:

1. Give Hammerspoon **Accessibility** access: System Settings → Privacy &
   Security → Accessibility (it moves and focuses windows).
2. The bar shows one tab: the Claude you already use. Click **`+`**, name the
   new account, and sign in in the window that opens. Repeat for each account.
3. Optional: `~/.hammerspoon/claude-tabs/config.lua` (language, screen,
   shortcuts…). Saving reloads Claude Tabs. The tabs themselves are kept in
   `profiles.json` next to it.

`install.sh` also updates: run it again after a `git pull`. Your `config.lua`
is kept.

## Signing in to another account

Claude's sign-in ends with an "Open Claude" button in your browser, and macOS
sends that `claude://` link to the first Claude instance it finds, not to the
tab you are signing in. Claude Tabs fixes that by itself: just sign in in the
tab's window and click "Open Claude".

How: when a Claude window starts a browser sign-in, Claude writes
`[Auth] Using system browser for: /login/…` in its log. Claude Tabs sees it,
notes which account's window is in front, and for a few minutes makes a tiny
router app the `claude://` handler. The "Open Claude" link reaches the router,
which hands it to Hammerspoon, which sends it to that account's instance only
(an Apple Event addressed to its pid). Claude gets `claude://` links back right
after.

If it ever fails, **`⌃⌥L`** (or right-click → "Sign in to this account") turns
sign-in mode on by hand before you start: Claude then signs in through macOS'
own sign-in sheet, which answers the right instance directly.

## Shortcuts

| | |
|---|---|
| `⌃⌥1` … `⌃⌥9` | go to tab n |
| `⌘ + scroll` | previous / next tab (Claude in front) |
| drag the tab bar | move the group; drop it on a screen to fill that screen |
| `⌃⌥E` | move to the next screen |
| `⌃⌥F`, double-click the bar | fill the screen (with `autoFill = false`: toggle) |
| `+` after the last tab | add an account |
| right-click a tab | sign in, rename, remove |
| `⌃⌥L` | sign-in mode for the current tab, by hand |

All are configurable in `config.lua`.

## How it works

- **Profiles**: `open -n -a Claude --args --user-data-dir=~/.claude-profiles/<id>`.
  Electron keeps one instance per data folder, so each account is a separate
  app instance with its own sign-in and its own Code sessions list.
- **Tab bar**: a Hammerspoon canvas above the active window. Every tab's window
  is kept at the same frame; switching focuses the right instance.
- **Counters**: Claude Code hooks in `~/.claude/settings.json`
  (`UserPromptSubmit`, `Stop`, `Notification`, `PreToolUse`/`PostToolUse` on
  `AskUserQuestion`) call `hook.sh`, which finds the Claude instance that runs
  the session by walking up its parent processes and tells Hammerspoon
  (`hammerspoon://claude-tabs?...`). Whether you have read a finished session
  comes from Claude Desktop's own session files (`lastFocusedAt`).

- **Usage**: Claude Desktop saves each usage reading of its account to
  `plan-usage-history.json` in its data folder; Claude Tabs reads that file (no
  network, no credentials). Claude only keeps reading in the background while
  its usage menu (right-click on its menu bar icon) was opened in the last 24 h,
  so when a tab's numbers go stale and you are idle, Claude Tabs opens that
  menu for a moment and closes it. Tab menu > "Refresh usage" does it now.

More detail and the pitfalls met on the way: [docs/how-it-works.md](docs/how-it-works.md).

## Limits

- Only **Code** sessions are counted, not chat conversations.
- Usage needs Claude's menu bar icon to be visible (not hidden behind the notch
  or by a menu bar manager); the reset time is rounded by Claude ("2d").
- `~/.claude` (Claude Code settings, transcripts) is shared by all accounts.
- macOS only. Thoughts on Linux: [docs/linux.md](docs/linux.md).

## Tests

```bash
scripts/check.sh   # static checks, no running app needed
tests/smoke.sh     # live test of the installed copy (Hammerspoon + one Claude open)
```

## Uninstall

```bash
./uninstall.sh           # keeps your config.lua and tabs (profiles.json)
./uninstall.sh --purge   # removes everything Claude Tabs added
```

Your accounts' data folders (`~/.claude-profiles/…`) are never removed: they
hold your sign-ins and sessions.

## License

MIT
