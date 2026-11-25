# Claude Tabs

Browser-style tabs for several **Claude Desktop** accounts on macOS: one tab per
account, all in one window, with live counters of your Claude Code sessions.

```
┌──────────────────────────────────────────────────────────────────────┐
│ 1  Personal   ①②  │ 2  Work            ③ │ 3  Client · closed        │
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
- **Behaves like one window**: drag the tab bar to move the group to another
  screen; it fills the screen it is on (`autoFill`), and follows the Dock and
  screens being plugged or woken up. `⌃⌥E` moves it to the next screen.
- **Sign-in mode** (`⌃⌥L`) to sign in to an extra account in its own tab (see below).
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
2. Edit `~/.hammerspoon/claude-tabs/config.lua`: one entry per account. The
   entry with `dataDir = nil` is the Claude you already use; each other entry
   gets its own data folder. Saving reloads Claude Tabs.
3. Click each new tab once and sign in (next section).

`install.sh` also updates: run it again after a `git pull`. Your `config.lua`
is kept.

## Signing in to another account

Claude's sign-in ends with an "Open Claude" button in your browser, and macOS
sends that link to the first Claude instance it finds, not to the new tab.
So, for each extra account:

1. Click its tab, then press **`⌃⌥L`** (sign-in mode). The tab says
   "sign-in: click “Open Claude”".
2. Sign in in that window, and click "Open Claude" in the browser if asked.

The account lands in the right tab and sign-in mode turns itself off. How: for
the duration, a tiny router app takes over `claude://` links; Claude notices
and signs in through macOS' own sign-in sheet, which answers the right
instance. Any `claude://` link that still arrives is forwarded to the right
instance. Claude gets `claude://` links back right after.

## Shortcuts

| | |
|---|---|
| `⌃⌥1` … `⌃⌥9` | go to tab n |
| `⌘ + scroll` | previous / next tab (Claude in front) |
| drag the tab bar | move the group; drop it on a screen to fill that screen |
| `⌃⌥E` | move to the next screen |
| `⌃⌥F`, double-click the bar | fill the screen (with `autoFill = false`: toggle) |
| `⌃⌥L` | sign-in mode for the current tab |

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

More detail and the pitfalls met on the way: [docs/how-it-works.md](docs/how-it-works.md).

## Limits

- Only **Code** sessions are counted, not chat conversations.
- `~/.claude` (Claude Code settings, transcripts) is shared by all accounts.
- macOS only. Thoughts on Linux: [docs/linux.md](docs/linux.md).

## Tests

```bash
scripts/check.sh   # static checks, no running app needed
tests/smoke.sh     # live test of the installed copy (Hammerspoon + one Claude open)
```

## Uninstall

```bash
./uninstall.sh           # keeps your config.lua
./uninstall.sh --purge   # removes everything Claude Tabs added
```

Your accounts' data folders (`~/.claude-profiles/…`) are never removed: they
hold your sign-ins and sessions.

## License

MIT
