-- Claude Tabs configuration.
-- install.sh copies this file to ~/.hammerspoon/claude-tabs/config.lua the
-- first time; edit that copy. Saving it reloads Claude Tabs.
return {
  -- "en" or "fr" (see src/strings.lua).
  language = "en",

  -- "window": the tab bar sits on top of the Claude window; drag the bar (or
  --           the window) to move the group, resize it by the window's edges.
  -- "screen": the bar and the windows take the whole `screen` below.
  mode = "window",
  -- Window mode: the group always fills the screen it is on. Drag it to
  -- another screen and it fills that one. false = free size (double-click the
  -- bar or ⌃⌥F to fill the screen, again to get the previous size back).
  autoFill = true,

  -- Starting screen (window mode) or dedicated screen (screen mode), by name
  -- as macOS shows it in System Settings > Displays (a part of it is enough).
  -- nil, or a screen that is not connected = the main screen.
  screen = nil,

  -- Tabs at first start. After that, add tabs with the "+" button and rename or
  -- remove them with a right-click; they are kept in profiles.json, next to
  -- this file (edit it by hand if you like, then reload).
  -- dataDir = nil is your usual Claude install (the account you are signed in
  -- to today). Each other account gets its own data folder, hence its own
  -- sign-in. No spaces in paths.
  profiles = {
    { id = "main", label = "Personal", color = "#D97757", dataDir = nil },
  },

  -- The "+" button after the last tab.
  addButton = true,

  -- Send the browser's "Open Claude" sign-in link to the tab that started the
  -- sign-in (without this, macOS gives it to the first Claude started).
  autoSignIn = true,

  -- Shortcuts: mods + 1, 2, 3… go to tab n; + F fills the screen; + E moves to
  -- the next screen; + L starts sign-in mode for the current tab.
  hotkeyMods = { "ctrl", "alt" },

  -- Modifier + scroll (mouse or trackpad) while Claude is in front:
  -- up = previous tab, down = next. Modifier: "cmd", "alt", "ctrl" or "shift".
  scrollSwitch = true,
  scrollModifier = "cmd",
  scrollInvert = false,

  barHeight = 30,

  -- Keep the bar above other windows.
  alwaysOnTop = true,

  -- Bring any Claude window that gets focus (Cmd-Tab, a notification…) back
  -- under the tab bar.
  snapOnFocus = true,

  -- Counters in the menu bar (✳︎).
  menubar = true,

  -- A "working" or "waiting" session with no news for this long is forgotten (seconds).
  workingTimeout = 1800,

  -- Path to Claude.app, if it is not found automatically.
  -- claudeApp = "/Applications/Claude.app",
}
