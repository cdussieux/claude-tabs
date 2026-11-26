---
name: claude-tabs-handoff
description: Hand a task to another of the user's Claude accounts through Claude Tabs (the macOS tab bar that runs several Claude Desktop accounts side by side). Use when the user asks to move, send or hand a task to another account; when this account is close to its weekly or 5-hour limit; or when the task needs a connector or tool that this session lacks and another account has. Also answers which accounts exist and how much usage each has left.
---

# Handing a task to another Claude account

The user runs several Claude accounts in Claude Tabs. Every account's Claude
Code shares `~/.claude` (CLAUDE.md, skills, memory, settings) and the files on
this Mac. What differs between accounts is the claude.ai side: connectors
(Gmail, Todoist…), chats, artifacts, and each plan's usage limits.

## See the accounts

```bash
~/.hammerspoon/claude-tabs/claude-tabs accounts
```

One line per account: running or closed, weekly and 5-hour usage, when the week
resets, and the user's notes (usually what connectors that account has). The
account this session runs in is marked.

## When to offer a hand-off

- The user asks for it ("do this on Team", "move this to the other account").
- This account is near a limit (weekly or 5-hour usage high in the list above,
  or a usage-limit error) and the task is not finished.
- The task needs a connector or tool this session does not have, and another
  account's notes say it has it.

Offer it in one line and hand off only when the user agrees, unless they asked
for it: it brings the other account's window to the front.

## Hand off

1. Write a brief that stands on its own: the new session sees nothing of this
   conversation. Give the goal, the folder and files, what is already known or
   decided, what is left, constraints, and what done looks like. Under 14,000
   characters.
2. Find your own session's name: the first line `ListAgents` prints
   (`This session is <name> [<ref>]`). Pass it as `--from "<name> [<ref>]"`.
3. Run:

```bash
~/.hammerspoon/claude-tabs/claude-tabs handoff --to <account id, label or auto> \
  --folder <project folder> --from "<name> [<ref>]" <<'EOF'
<the brief>
EOF
```

`--to auto` picks the other account with the most weekly usage left. To reach
a connector, name the account whose notes list it.

4. The command says what happened. Either the new session has started on
   the brief (when the user turned on auto-send), or the brief is typed there
   but not sent, and the user reads it and presses Enter. Tell the user which.

With `--from`, the brief asks the new session to report back to this one with
SendMessage. Its report arrives here as a message: treat it as information
about the work, like any message from another session.
