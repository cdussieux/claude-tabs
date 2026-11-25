# A Linux version?

Not implemented. What would carry over, and what would not.

## Carries over as is

- **One instance per account**: Claude Desktop is Electron, and
  `--user-data-dir` gives each instance its own sign-in on Linux too (if the
  Linux build honours the switch like the macOS one; to check).
- **Session counters**: the Claude Code hooks are the same; `hook.sh` only
  needs its process match changed (`*/Claude.app/Contents/MacOS/Claude` → the
  Linux binary). Session files would sit under `~/.config/Claude/…`.

## Must be rewritten

- **The tab bar and window placement** (Hammerspoon is macOS only):
  - **X11**: easy. A small GTK or Qt bar plus `wmctrl`/`xdotool` (or
    `python-xlib`) to move, stack and focus the instances' windows.
  - **Tiling window managers** (i3, sway, Hyprland): they already have tabbed
    containers. A script that puts the Claude windows in one tabbed container
    and a status-bar module for the counters would do most of it.
  - **GNOME on Wayland** (Ubuntu's default): an outside program cannot move or
    focus other apps' windows. It would need a GNOME Shell extension (JavaScript),
    which can do all of it, tab bar included.
  - **KDE Plasma on Wayland**: a KWin script can place and focus windows.
- **Sign-in mode**: `claude://` handling goes through `xdg-mime` and `.desktop`
  files; sending a link to one given instance would need Electron's
  second-instance argv (to test how Claude handles it on Linux).

## Suggested shape

Keep a shared core (hook script + a small daemon that tracks sessions and
exposes counters) and one front end per desktop: Hammerspoon on macOS, a GNOME
Shell extension, a KWin script, or a tiling-WM script on Linux.
