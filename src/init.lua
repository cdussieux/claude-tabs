-- Claude Tabs: browser-style tabs for several Claude Desktop accounts on macOS.
--
-- Each account ("profile") is its own instance of Claude.app, started with its
-- own --user-data-dir, so each has its own sign-in. All the windows sit at the
-- same place under a tab bar; clicking a tab (or ctrl+alt+N) brings that
-- account's window to the front. Each tab counts its account's Code sessions:
-- working, done but not yet read, and waiting for you (see "Sessions" below).
--
-- Loaded by ~/.hammerspoon/init.lua:  ClaudeTabs = require("claude-tabs"); ClaudeTabs.start()

local M = {}

local BUNDLE = "com.anthropic.claudefordesktop"
local HOME = os.getenv("HOME")
local DIR = hs.configdir .. "/claude-tabs"
local LAUNCHER_DIR = HOME .. "/Applications/Claude Tabs"

local log = hs.logger.new("claudeTabs", "info")
local cfg = dofile(DIR .. "/config.lua")
local STRINGS = dofile(DIR .. "/strings.lua")
local S = STRINGS[cfg.language or "en"] or STRINGS.en
local BAR_H = cfg.barHeight or 30
local CLAUDE_APP = cfg.claudeApp or hs.application.pathForBundleID(BUNDLE) or "/Applications/Claude.app"
local MODS = cfg.hotkeyMods or { "ctrl", "alt" }

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function readFile(path)
  local f = io.open(path, "r"); if not f then return nil end
  local s = f:read("a"); f:close(); return s
end

local function writeFile(path, s)
  local f = assert(io.open(path, "w")); f:write(s); f:close()
end

local function sameRect(a, b, tol)
  tol = tol or 2
  return math.abs(a.x - b.x) <= tol and math.abs(a.y - b.y) <= tol
    and math.abs(a.w - b.w) <= tol and math.abs(a.h - b.h) <= tol
end

---------------------------------------------------------------------------
-- Profiles
---------------------------------------------------------------------------

local function expand(p)
  if not p then return nil end
  return (p:gsub("^~", HOME):gsub("/+$", ""))
end

-- The tabs live in profiles.json, edited by the "+" button and the tab menu
-- (right-click). On first start it is seeded from config.profiles.
local PROFILES_FILE = DIR .. "/profiles.json"
local PALETTE = { "#D97757", "#4F8EF7", "#3DBE8B", "#B07CE8", "#E8B13C", "#E86A8C", "#4FC3C7", "#9AA0A6" }

local function newProfile(p, i)
  return {
    id = p.id, label = p.label or p.id, color = p.color or PALETTE[(i - 1) % #PALETTE + 1],
    rawDataDir = p.dataDir, dataDir = expand(p.dataDir), index = i,
    pid = nil,
    sessions = {},  -- cliSessionId -> { state = "working"|"done"|"attention", at = ms, file = path }
  }
end

local function loadProfileList()
  local s = readFile(PROFILES_FILE)
  local ok, list = pcall(function() return s and hs.json.decode(s) end)
  if ok and type(list) == "table" and #list > 0 then return list end
  list = {}
  for _, p in ipairs(cfg.profiles or { { id = "main", label = "Claude" } }) do
    list[#list + 1] = { id = p.id, label = p.label, color = p.color, dataDir = p.dataDir }
  end
  writeFile(PROFILES_FILE, hs.json.encode(list, true))
  return list
end

local profiles, byId = {}, {}
for i, p in ipairs(loadProfileList()) do
  profiles[i] = newProfile(p, i)
  byId[p.id] = profiles[i]
end

local function saveProfileList()
  local list = {}
  for _, p in ipairs(profiles) do
    list[#list + 1] = { id = p.id, label = p.label, color = p.color, dataDir = p.rawDataDir }
  end
  writeFile(PROFILES_FILE, hs.json.encode(list, true))
end

local activeId = nil
local signInTarget = nil  -- profile in sign-in mode (see M.startSignIn)
local pidCache = {}       -- pid -> profile (or false when unknown)

-- Which profile does a Claude process belong to? Read from its command line.
local function profileForCommand(cmd)
  local flag = "--user-data-dir="
  local s = cmd:find(flag, 1, true)
  if not s then
    for _, p in ipairs(profiles) do if not p.dataDir then return p end end
    return nil
  end
  local rest = cmd:sub(s + #flag)
  for _, p in ipairs(profiles) do
    if p.dataDir and rest:sub(1, #p.dataDir) == p.dataDir then
      local after = rest:sub(#p.dataDir + 1, #p.dataDir + 1)
      if after == "" or after == "/" or after:match("%s") then return p end
    end
  end
  return nil
end

local function pidProfile(pid)
  if not pid then return nil end
  if pidCache[pid] == nil then
    local out = hs.execute("/bin/ps -p " .. math.tointeger(pid) .. " -o command=") or ""
    out = out:gsub("%s+$", "")
    pidCache[pid] = (out ~= "" and profileForCommand(out)) or false
  end
  return pidCache[pid] or nil
end

local function refresh()
  local seen = {}
  for _, app in ipairs(hs.application.applicationsForBundleID(BUNDLE)) do
    local pid = app:pid()
    local p = pidProfile(pid)
    if p then p.pid = pid; seen[p.id] = true end
  end
  for _, p in ipairs(profiles) do
    if not seen[p.id] then
      p.pid = nil
      -- Instance closed: nothing runs or waits any more; unread sessions stay unread.
      for id, s in pairs(p.sessions) do
        if s.state ~= "done" then p.sessions[id] = nil end
      end
    end
  end
end

local function isFrontmost(p)
  local front = hs.application.frontmostApplication()
  return p.pid ~= nil and front ~= nil and front:pid() == p.pid
end

---------------------------------------------------------------------------
-- Sessions: who is working, who is done, who is waiting for you
--
-- Claude Code hooks (hook.sh) report when a session starts a turn (prompt),
-- ends it (stop), or waits for you (question, permission). Claude Desktop
-- writes one file per Code session (claude-code-sessions/…/local_*.json) with
-- lastFocusedAt (last time you opened it) and lastTurnEdgeAt (start or end of
-- the last turn). A finished session counts as read once you open it after
-- its turn ended: it becomes idle again and leaves the counters.
---------------------------------------------------------------------------

local SESSIONS_KEY = "claudeTabs.sessions"

local function nowMs() return math.floor(hs.timer.secondsSinceEpoch() * 1000) end

local function dataDir(p)
  return p.dataDir or (HOME .. "/Library/Application Support/Claude")
end

local function sessionsDir(p) return dataDir(p) .. "/claude-code-sessions" end

local function findSessionFile(p, cliId)
  if not cliId or not cliId:match("^[%w%-]+$") then return nil end
  local out = hs.execute("/usr/bin/grep -r -l -F --include='local_*.json' "
    .. shq('"cliSessionId":"' .. cliId .. '"') .. " " .. shq(sessionsDir(p)) .. " 2>/dev/null")
  return out and out:match("[^\n]+") or nil
end

local function sessionInfo(path)
  local s = path and readFile(path)
  if not s then return nil end
  return {
    focused = tonumber(s:match('"lastFocusedAt":(%d+)')) or 0,
    edge = tonumber(s:match('"lastTurnEdgeAt":(%d+)')) or 0,
    archived = s:find('"isArchived":true', 1, true) ~= nil,
  }
end

-- The session shown in an account's window: the one opened last.
local function displayedSessionFile(p)
  local out = hs.execute("/usr/bin/grep -r -o -E --include='local_*.json' '\"lastFocusedAt\":[0-9]+' "
    .. shq(sessionsDir(p)) .. " 2>/dev/null") or ""
  local bestPath, best = nil, -1
  for path, t in out:gmatch('([^\n]+):"lastFocusedAt":(%d+)') do
    t = tonumber(t)
    if t > best then best, bestPath = t, path end
  end
  return bestPath
end

local function saveSessions()
  local all = {}
  for _, p in ipairs(profiles) do all[p.id] = p.sessions end
  hs.settings.set(SESSIONS_KEY, all)
end

local function loadSessions()
  local all = hs.settings.get(SESSIONS_KEY) or {}
  -- Copy each table: equal saved values (e.g. empty ones) can come back as
  -- one shared Lua table, which would make every tab show the same sessions.
  for _, p in ipairs(profiles) do
    p.sessions = {}
    for id, s in pairs(all[p.id] or {}) do
      p.sessions[id] = { state = s.state, at = s.at, file = s.file }
    end
  end
end

local function counts(p)
  local w, d, a = 0, 0, 0
  for _, s in pairs(p.sessions) do
    if s.state == "working" then w = w + 1
    elseif s.state == "done" then d = d + 1
    elseif s.state == "attention" then a = a + 1 end
  end
  return w, d, a
end

local function setSession(p, cliId, state)
  local s = p.sessions[cliId] or {}
  s.state, s.at = state, nowMs()
  s.file = s.file or findSessionFile(p, cliId)
  p.sessions[cliId] = s
  return s
end

-- The displayed session has been seen: if it had finished, it is no longer unread.
local function markDisplayedSeen(p)
  local shown = displayedSessionFile(p)
  if not shown then return false end
  local changed = false
  for id, s in pairs(p.sessions) do
    if s.state == "done" and s.file == shown then p.sessions[id] = nil; changed = true end
  end
  return changed
end

-- Re-read the files of the tracked sessions.
local function rescan(p)
  local changed = false
  for id, s in pairs(p.sessions) do
    s.file = s.file or findSessionFile(p, id)
    local info = s.file and sessionInfo(s.file)
    if s.file and (not info or info.archived) then
      p.sessions[id] = nil; changed = true            -- deleted or archived
    elseif info and s.state == "done" and info.focused > s.at then
      p.sessions[id] = nil; changed = true            -- opened since: read
    elseif info and s.state == "working" and info.edge > s.at + 2000 then
      p.sessions[id] = nil; changed = true            -- turn ended without "stop" (interrupted)
    end
  end
  if changed then saveSessions() end
  return changed
end

---------------------------------------------------------------------------
-- Layout: where the bar and the windows go
---------------------------------------------------------------------------

local function configuredScreen()
  return cfg.screen and hs.screen.find(cfg.screen) or nil
end

local function targetScreen()
  return configuredScreen() or hs.screen.primaryScreen()
end

-- Two modes (config.mode):
--  "screen": the bar and the windows take the whole configured screen.
--  "window": the group (bar + window) moves and resizes like a window; its
--            place is remembered.
local WINDOW_MODE = (cfg.mode or "window") == "window"
-- autoFill: the group always fills the screen it is on. Moving it (bar or
-- window) to another screen makes it fill that screen.
local AUTO_FILL = WINDOW_MODE and cfg.autoFill ~= false
local GROUP_KEY = "claudeTabs.groupFrame"
local groupFrame  -- window mode: the group's frame, bar included

local function onSomeScreen(f)
  for _, s in ipairs(hs.screen.allScreens()) do
    local i = s:frame():intersect(f)
    if i.w >= 200 and i.h >= 100 then return true end
  end
  return false
end

local function currentGroupFrame()
  if not WINDOW_MODE then return targetScreen():frame() end
  if not groupFrame then
    local saved = hs.settings.get(GROUP_KEY)
    if saved and saved.w then groupFrame = hs.geometry.rect(saved.x, saved.y, saved.w, saved.h) end
  end
  if not groupFrame or not onSomeScreen(groupFrame) then
    groupFrame = targetScreen():frame()
  end
  return groupFrame
end

local function setGroupFrame(f)
  groupFrame = hs.geometry.rect(f.x, f.y, f.w, f.h)
  hs.settings.set(GROUP_KEY, { x = f.x, y = f.y, w = f.w, h = f.h })
end

local function zone()
  local f = currentGroupFrame()
  return {
    bar = hs.geometry.rect(f.x, f.y, f.w, BAR_H),
    win = hs.geometry.rect(f.x, f.y + BAR_H, f.w, f.h - BAR_H),
  }
end

-- The screen the group is on (the one under the middle of its bar).
local function groupScreen()
  local g = currentGroupFrame()
  local center = hs.geometry.point(g.x + g.w / 2, g.y + BAR_H / 2)
  for _, s in ipairs(hs.screen.allScreens()) do
    if center:inside(s:fullFrame()) then return s end
  end
  return targetScreen()
end

local function isTabWindow(w)
  if not w or not w:isStandard() then return false end
  local f = w:frame()
  return f.w >= 400 and f.h >= 300
end

local function placeWindow(w)
  -- A macOS full-screen window lives on its own Space and cannot be stacked
  -- with the others: take it out of full screen, then place it once the
  -- animation is over.
  if w:isFullScreen() then
    w:setFullScreen(false)
    local tries = 0
    local t
    t = hs.timer.doEvery(0.5, function()
      tries = tries + 1
      if not w:isFullScreen() then
        local target = zone().win
        w:setFrame(target, 0)
        local f = w:frame()
        if (math.abs(f.y - target.y) <= 1 and math.abs(f.h - target.h) <= 1) or tries >= 10 then
          t:stop(); w:focus()
        end
      elseif tries >= 10 then
        t:stop()
      end
    end)
    return
  end
  local target = zone().win
  if not sameRect(w:frame(), target, 1) then
    w:setFrame(target, 0)
    -- Claude sometimes ignores a small shrink (e.g. when the Dock shows up):
    -- go through a smaller size first, then the right one.
    if not sameRect(w:frame(), target, 2) then
      w:setSize({ w = target.w - 50, h = target.h - 50 })
      w:setFrame(target, 0)
    end
  end
end

local function profileWindow(p)
  if not p.pid then return nil end
  local app = hs.application.applicationForPID(p.pid)
  if not app then return nil end
  local w = app:mainWindow()
  if isTabWindow(w) then return w end
  for _, win in ipairs(app:allWindows()) do
    if isTabWindow(win) then return win end
  end
  return nil
end

-- When is the bar shown?
--  "screen" mode, configured screen connected: always.
--  otherwise: only while a Claude window is in front, so it never covers other apps.
local function barVisible()
  if not WINDOW_MODE and configuredScreen() then return true end
  local front = hs.application.frontmostApplication()
  if not front or front:bundleID() ~= BUNDLE then return false end
  if WINDOW_MODE then
    local p = activeId and byId[activeId]
    local w = p and profileWindow(p)
    if w and (w:isFullScreen() or w:isMinimized()) then return false end
  end
  return true
end

---------------------------------------------------------------------------
-- Launching profiles, and one small launcher .app per profile
---------------------------------------------------------------------------

local function launchCommand(p)
  local cmd = "/usr/bin/open -n -a " .. shq(CLAUDE_APP)
  if p.dataDir then cmd = cmd .. " --args --user-data-dir=" .. shq(p.dataDir) end
  return cmd
end

local function launch(p)
  if p.dataDir then hs.execute("mkdir -p " .. shq(p.dataDir)) end
  log.i("launching profile " .. p.id)
  hs.execute(launchCommand(p))
end

-- ~/Applications/Claude Tabs/Claude <Label>.app, for Spotlight and the Dock.
function M.makeLaunchers()
  hs.execute("mkdir -p " .. shq(LAUNCHER_DIR))
  for _, p in ipairs(profiles) do
    local app = LAUNCHER_DIR .. "/Claude " .. p.label .. ".app"
    local script = "#!/bin/sh\n"
    if p.dataDir then script = script .. "mkdir -p " .. shq(p.dataDir) .. "\n" end
    script = script .. "exec " .. launchCommand(p) .. "\n"
    local exe = app .. "/Contents/MacOS/launch"
    if readFile(exe) ~= script then
      hs.execute("mkdir -p " .. shq(app .. "/Contents/MacOS") .. " " .. shq(app .. "/Contents/Resources"))
      writeFile(exe, script)
      hs.execute("chmod +x " .. shq(exe))
      hs.execute("cp " .. shq(CLAUDE_APP .. "/Contents/Resources/electron.icns") .. " "
        .. shq(app .. "/Contents/Resources/AppIcon.icns") .. " 2>/dev/null")
      writeFile(app .. "/Contents/Info.plist", ([[
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>launch</string>
  <key>CFBundleIdentifier</key><string>local.claudetabs.%s</string>
  <key>CFBundleName</key><string>Claude %s</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
]]):format(p.id, p.label))
      log.i("launcher written: " .. app)
    end
  end
end

---------------------------------------------------------------------------
-- Plan usage
--
-- Claude itself writes each usage reading of its account to
-- plan-usage-history.json in its data folder (u.sd = weekly %, u.fh = 5-hour
-- %). Reading that file costs nothing and needs no credentials. But Claude
-- only keeps reading in the background (every 5 to 15 min) while its own
-- usage menu (right-click on its menu bar icon) was opened in the last 24 h.
-- So when an account's numbers go stale and you are away from the keyboard,
-- Claude Tabs opens that menu for a moment and closes it (Escape). The menu
-- also gives the time left before the weekly reset, which the file lacks.
---------------------------------------------------------------------------

local SHOW_USAGE = cfg.usage ~= false
local USAGE_REFRESH = SHOW_USAGE and cfg.usageRefresh ~= false
local USAGE_IDLE = cfg.usageIdle or 120   -- seconds without keyboard or mouse
local USAGE_STALE = 40 * 60               -- Claude reads at least every 15 min
local USAGE_RETRY = 30 * 60               -- between two tries for one account
local RESET_KEY = "claudeTabs.usageResetWindow"
local WEEK = 7 * 86400
-- profile id -> { lo = s, hi = s }: the weekly reset falls between lo and hi.
-- Each clue narrows it down: the menu's rounded "Resets 3d" (about 3 days from
-- now), and a drop of the weekly % in the history (a reset between those two
-- readings). The reset comes back every 7 days, so an old clue still holds,
-- a whole number of weeks later.
local resetWin = {}
local pokeAt = {}                          -- profile id -> last try (epoch s)

local function nowS() return hs.timer.secondsSinceEpoch() end

-- The same window, moved by whole weeks to the next reset still to come.
local function ahead(lo, hi, now)
  while hi <= now do lo, hi = lo + WEEK, hi + WEEK end
  return lo, hi
end

local function addResetClue(p, lo, hi)
  local now = nowS()
  lo, hi = ahead(lo, hi, now)
  local w = resetWin[p.id]
  if w then
    local wlo, whi = ahead(w.lo, w.hi, now)
    local nlo, nhi = math.max(lo, wlo), math.min(hi, whi)
    -- No overlap: the reset time changed. Start over from the new clue.
    if nlo < nhi then lo, hi = nlo, nhi end
  end
  if not w or w.lo ~= lo or w.hi ~= hi then
    resetWin[p.id] = { lo = lo, hi = hi }
    hs.settings.set(RESET_KEY, resetWin)
  end
end

-- Middle of the next reset window, and its width (seconds).
local function resetInfo(p)
  local w = resetWin[p.id]
  if not w then return nil end
  local lo, hi = ahead(w.lo, w.hi, nowS())
  return (lo + hi) / 2, hi - lo
end

-- Re-read an account's usage file if it changed. Returns true when it did.
local function readUsage(p)
  local path = dataDir(p) .. "/plan-usage-history.json"
  local attr = hs.fs.attributes(path)
  local mtime = attr and attr.modification or false
  if mtime == p.usageMtime then return false end
  p.usageMtime = mtime
  local s = mtime and readFile(path)
  local ok, d = pcall(function() return s and hs.json.decode(s) end)
  local samples = {}
  for _, x in ipairs(ok and type(d) == "table" and type(d.samples) == "table" and d.samples or {}) do
    if type(x) == "table" and tonumber(x.t) and type(x.u) == "table" then samples[#samples + 1] = x end
  end
  table.sort(samples, function(a, b) return a.t < b.t end)
  local last = samples[#samples]
  p.usage = last and { week = tonumber(last.u.sd), five = tonumber(last.u.fh), at = last.t / 1000 } or nil
  -- The weekly % only grows until the reset: the last clear drop between two
  -- close readings of this account dates the reset.
  local prev, drop
  for _, x in ipairs(samples) do
    if x.org == last.org then
      local a, b = prev and tonumber(prev.u.sd), tonumber(x.u.sd)
      if a and b and b < a and (b <= 1 or a - b >= 2) and x.t - prev.t <= 3 * 3600 * 1000 then
        drop = { prev.t / 1000, x.t / 1000 }
      end
      prev = x
    end
  end
  if drop then addResetClue(p, drop[1], drop[2]) end
  return true
end

-- "3j 7h", "7h", "<1h"
local function countdown(secs)
  local d, h = math.floor(secs / 86400), math.floor(secs % 86400 / 3600)
  if d > 0 then return d .. S.unitDay .. (h > 0 and (" " .. h .. S.unitHour) or "") end
  if h > 0 then return h .. S.unitHour end
  return "<1" .. S.unitHour
end

-- "dim. 17h" when known to the hour, else "~dim.".
local function resetLabel(p)
  local mid, width = resetInfo(p)
  if not mid then return nil end
  local exact = width <= 3 * 3600
  local d = os.date("*t", math.floor(exact and mid + 1800 or mid))
  local today = os.date("*t")
  local day = (d.year == today.year and d.yday == today.yday) and S.today or S.days[d.wday]
  return exact and S.resetAt:format(day, d.hour) or ("~" .. day), exact
end

-- Share of the week gone by (0 to 1), when the reset is known.
local function weekElapsed(p)
  local mid = resetInfo(p)
  if not mid then return nil end
  return math.max(0, math.min(1, 1 - (mid - nowS()) / WEEK))
end

-- "over": at this pace, over 100 % before the reset. "ahead": using it faster
-- than the week goes by. Without a known reset, plain thresholds.
local function pace(p)
  local u, e = p.usage.week, weekElapsed(p)
  if not e then return u >= 80 and "over" or u >= 50 and "ahead" or "ok" end
  if u >= 90 or (e >= 0.1 and u / e >= 100) then return "over" end
  if u >= 10 and u > e * 100 then return "ahead" end
  return "ok"
end
local PACE_COLORS = { over = "#FF453A", ahead = "#F5A623" }

local function usageStale(p)
  return not p.usage or nowS() - p.usage.at > USAGE_STALE
end

-- For the tab: "  ·  8 %  ·  ↻ dim. 17h", coloured by pace, dimmed when stale.
-- `style(color, font)` gives the tab's text attributes.
local function usageTag(p, style)
  if not SHOW_USAGE or not p.usage or not p.usage.week then return nil end
  local hex = PACE_COLORS[pace(p)]
  local color = hex and { hex = hex } or { white = 1 }
  color.alpha = usageStale(p) and 0.4 or 0.85
  local text = hs.styledtext.new("  ·  " .. S.pct:format(p.usage.week), style(color))
  local r = resetLabel(p)
  if r then
    local soft = { white = 1, alpha = color.alpha }
    text = text .. hs.styledtext.new("  ·  ", style(soft))
      -- The arrow is missing from Helvetica Neue: take it from the system font.
      .. hs.styledtext.new("↻ ", style(soft, { name = ".AppleSystemUIFont", size = 12 }))
      .. hs.styledtext.new(r, style(soft))
  end
  return text
end

-- For the menus: "semaine 8 % · ↻ dim. 17h (dans 3j 7h) · 5 h 3 % · il y a 4 min"
local function usageDetail(p)
  if not p.usage then return nil end
  local parts = {}
  if p.usage.week then
    local part = S.usageWeek:format(S.pct:format(p.usage.week))
    local r, exact = resetLabel(p)
    if r then
      local mid = resetInfo(p)
      part = part .. " · ↻ " .. r .. " (" .. S.inTime:format((exact and "" or "~")
        .. countdown(math.max(0, mid - nowS()))) .. ")"
    end
    parts[#parts + 1] = part
  end
  if p.usage.five then parts[#parts + 1] = S.usageFive:format(S.pct:format(p.usage.five)) end
  local age = nowS() - p.usage.at
  parts[#parts + 1] = age < 60 and S.usageNow
    or S.usageAge:format(age < 3600 and (math.floor(age / 60) .. " " .. S.unitMin) or countdown(age))
  return table.concat(parts, " · ")
end

-- Time to the weekly reset, from the open usage menu: a "Weekly · all models"
-- row followed by "12% · Resets 3d" (or "4h", "2d 5h"…). Claude rounds down:
-- "3d" is between 3 and 4 days. Returns the earliest and latest number of
-- seconds it can mean.
local UNITS = { d = 86400, h = 3600, m = 60 }
local function weeklyResetFromMenu(menu)
  for _, item in ipairs(menu:attributeValue("AXChildren") or {}) do
    local group = (item:attributeValue("AXChildren") or {})[1]
    local texts = {}
    for _, c in ipairs(group and group:attributeValue("AXChildren") or {}) do
      local v = c:attributeValue("AXValue")
      if type(v) == "string" then texts[#texts + 1] = v end
    end
    if texts[1] and texts[1]:match("^Weekly") and texts[2] then
      local rest = texts[2]:match("Resets%s+(.*)")
      if not rest then return nil end
      local secs, smallest = 0, nil
      for n, u in rest:gmatch("(%d+)%s*([dhm])") do
        secs = secs + tonumber(n) * UNITS[u]
        smallest = math.min(smallest or math.huge, UNITS[u])
      end
      if not smallest then return nil end
      return secs, secs + smallest
    end
  end
end

-- Open this account's usage menu (right-click on its Claude's menu bar icon),
-- read the reset time, close it. Claude counts that as "menu opened": it
-- refreshes now and keeps refreshing for 24 h. `done(ok)` is called after.
local function pokeUsage(p, done)
  done = done or function() end
  pokeAt[p.id] = nowS()
  local app = p.pid and hs.application.applicationForPID(p.pid)
  local ax = app and hs.axuielement.applicationElement(app)
  local bar = ax and ax:attributeValue("AXExtrasMenuBar")
  local icon = bar and (bar:attributeValue("AXChildren") or {})[1]
  local f = icon and icon:attributeValue("AXFrame")
  if not f then log.i("usage: no menu bar icon for " .. p.id); return done(false) end
  local pt = { x = f.x + f.w / 2, y = f.y + f.h / 2 }
  -- Only click if that spot really shows this Claude's icon (not hidden
  -- behind the notch, nor covered).
  local hit = hs.axuielement.systemElementAtPosition(pt)
  if not hit or hit:pid() ~= p.pid then
    log.i("usage: menu bar icon of " .. p.id .. " not visible"); return done(false)
  end
  local back = hs.mouse.absolutePosition()
  hs.eventtap.rightClick(pt)
  -- The menu opens under the icon: check it is there before pressing Escape,
  -- so the key can never reach a window (and stop a session). Claude can take
  -- a moment to build it: look for up to 2 s.
  local tries = 0
  local function check()
    tries = tries + 1
    local e = hs.axuielement.systemElementAtPosition({ x = pt.x, y = f.y + f.h + 20 })
    local open = e and e:pid() == p.pid and e:attributeValue("AXRole") == "AXMenuItem"
    if not open and tries < 8 then hs.timer.doAfter(0.25, check); return end
    if open then
      local lo, hi = weeklyResetFromMenu(e:attributeValue("AXParent"))
      if lo then addResetClue(p, nowS() + lo - 60, nowS() + hi + 60) end
      hs.eventtap.keyStroke({}, "escape", 0)
      log.i("usage: opened the usage menu of " .. p.id)
    else
      log.i("usage: menu of " .. p.id .. " did not open")
    end
    hs.mouse.absolutePosition(back)
    done(open)
  end
  hs.timer.doAfter(0.4, check)
end

---------------------------------------------------------------------------
-- Tab bar and menu bar item
---------------------------------------------------------------------------

local COLORS = {
  bg = { hex = "#1B1B1D" },
  tab = { hex = "#2C2C2F" },
  working = { hex = "#F5A623" },
  done = { hex = "#34C759" },
  attention = { hex = "#FF453A" },
}

local canvas, menubar
local draw, drawBar

local function stateText(p)
  if signInTarget == p.id then return S.signInHint end
  if not p.pid then return S.closed end
  return ""
end

-- Counters as text, for the menu: "1 working · 3 done · 1 waiting for you".
local function countsText(p)
  local w, d, a = counts(p)
  local parts = {}
  if w > 0 then parts[#parts + 1] = S.working(w) end
  if d > 0 then parts[#parts + 1] = S.done(d) end
  if a > 0 then parts[#parts + 1] = S.waiting(a) end
  return table.concat(parts, " · ")
end

-- Numbered badges, left to right: working, done, waiting for you.
local BADGE_R, BADGE_GAP = 8, 4
local function badgeList(p)
  local w, d, a = counts(p)
  local list = {}
  if w > 0 then list[#list + 1] = { n = w, color = COLORS.working, text = { hex = "#1B1B1D" } } end
  if d > 0 then list[#list + 1] = { n = d, color = COLORS.done, text = { hex = "#1B1B1D" } } end
  if a > 0 then list[#list + 1] = { n = a, color = COLORS.attention, text = { white = 1 } } end
  return list
end

-- Put every tab's window at the group's place (without changing the front one).
local function applyGroup()
  for _, p in ipairs(profiles) do
    local w = profileWindow(p)
    if w then
      if w:isFullScreen() then
        placeWindow(w)
      else
        w:setFrame(zone().win, 0)
        -- When changing screens, macOS sometimes caps the size on the first try.
        hs.timer.doAfter(0.4, function() placeWindow(w) end)
      end
    end
  end
  drawBar()
end

-- Fill the screen the group is on (or the given one), bar included. Without
-- autoFill, doing it again restores the previous size, like a window's green button.
local beforeFill
function M.fillScreen(screen)
  if not WINDOW_MODE then return end
  screen = screen or groupScreen()
  local target = screen:frame()
  local g = currentGroupFrame()
  local filled = sameRect(g, target)
  if AUTO_FILL then
    if not filled then setGroupFrame(target) end
  elseif filled and beforeFill and onSomeScreen(beforeFill) then
    setGroupFrame(beforeFill)
    beforeFill = nil
  else
    if not filled then beforeFill = hs.geometry.rect(g.x, g.y, g.w, g.h) end
    setGroupFrame(target)
  end
  applyGroup()
end

-- Move the group to the next screen and fill it.
function M.nextScreen()
  if not WINDOW_MODE then return end
  beforeFill = nil
  setGroupFrame(groupScreen():next():frame())
  applyGroup()
end

-- Click on a tab = switch. In window mode, dragging the bar moves the whole
-- group like a title bar, and double-clicking it fills the screen.
local dragTap
local lastDown = { t = 0, x = -100 }
local PLUS_W = cfg.addButton == false and 0 or 32
local tabMenu  -- defined with the tab actions below
local function tabWidth() return (zone().bar.w - PLUS_W) / #profiles end

local function onBarClick(_, msg, _, x, _)
  if msg ~= "mouseDown" then return end
  local buttons = hs.eventtap.checkMouseButtons()
  local flags = hs.eventtap.checkKeyboardModifiers()
  local onPlus = PLUS_W > 0 and x >= zone().bar.w - PLUS_W
  if onPlus then
    hs.timer.doAfter(0, function() M.addProfile() end)
    return
  end
  -- Right-click (or ctrl-click) on a tab: its menu.
  if buttons.right or flags.ctrl then
    local p = profiles[math.floor(x / tabWidth()) + 1]
    if p then hs.timer.doAfter(0, function() tabMenu(p) end) end
    return
  end
  local now = hs.timer.secondsSinceEpoch()
  if WINDOW_MODE and now - lastDown.t < 0.35 and math.abs(x - lastDown.x) < 6 then
    lastDown.t = 0
    if dragTap then dragTap:stop(); dragTap = nil end
    M.fillScreen()
    return
  end
  lastDown = { t = now, x = x }
  local i = math.floor(x / tabWidth()) + 1
  if not WINDOW_MODE then
    if profiles[i] then M.switchTo(profiles[i].id) end
    return
  end
  local types = hs.eventtap.event.types
  local start = hs.mouse.absolutePosition()
  local g0 = currentGroupFrame()
  local p = activeId and byId[activeId]
  local w = p and profileWindow(p)
  local moved = false
  if dragTap then dragTap:stop() end
  dragTap = hs.eventtap.new({ types.leftMouseDragged, types.leftMouseUp }, function(e)
    local pos = hs.mouse.absolutePosition()
    local dx, dy = pos.x - start.x, pos.y - start.y
    if e:getType() == types.leftMouseUp then
      dragTap:stop(); dragTap = nil
      if moved then
        if AUTO_FILL then
          -- Dropped on a screen: the group fills it.
          local target = hs.mouse.getCurrentScreen() or groupScreen()
          setGroupFrame(target:frame())
          applyGroup()
        else
          setGroupFrame(hs.geometry.rect(g0.x + dx, g0.y + dy, g0.w, g0.h))
          if w then w:setFrame(zone().win, 0) end
          drawBar()
        end
      elseif profiles[i] then
        M.switchTo(profiles[i].id)
      end
      return false
    end
    if not moved and math.abs(dx) + math.abs(dy) < 4 then return false end
    moved = true
    groupFrame = hs.geometry.rect(g0.x + dx, g0.y + dy, g0.w, g0.h)
    canvas:topLeft({ x = groupFrame.x, y = groupFrame.y })
    if w then w:setTopLeft({ x = groupFrame.x, y = groupFrame.y + BAR_H }) end
    return false
  end):start()
end

drawBar = function()
  local z = zone()
  if not canvas then
    canvas = hs.canvas.new(z.bar)
    canvas:level(cfg.alwaysOnTop ~= false and hs.canvas.windowLevels.floating
      or hs.canvas.windowLevels.normal)
    canvas:behavior({ "canJoinAllSpaces", "stationary" })
    canvas:clickActivating(false)
    canvas:canvasMouseEvents(true, false, false, false)
    canvas:mouseCallback(onBarClick)
  else
    canvas:frame(z.bar)
  end

  local tabW = (z.bar.w - PLUS_W) / #profiles
  local els = { { type = "rectangle", action = "fill", fillColor = COLORS.bg } }
  if PLUS_W > 0 then  -- "+" button after the last tab: add an account
    els[#els + 1] = {
      type = "text",
      frame = { x = z.bar.w - PLUS_W, y = (BAR_H - 22) / 2, w = PLUS_W, h = 22 },
      text = hs.styledtext.new("+", {
        font = { name = "HelveticaNeue-Light", size = 20 },
        color = { white = 1, alpha = 0.7 },
        paragraphStyle = { alignment = "center" },
      }),
    }
  end
  for i, p in ipairs(profiles) do
    local x0 = (i - 1) * tabW
    local active = (p.id == activeId) and p.pid ~= nil
    local _, nDone, nAtt = counts(p)
    local fill = { hex = p.color, alpha = 0.9 }
    if not active then
      fill = (nDone > 0 or nAtt > 0) and { hex = p.color, alpha = 0.35 } or COLORS.tab
    end
    local badges = badgeList(p)
    local badgesW = #badges * (2 * BADGE_R + BADGE_GAP)
    els[#els + 1] = {
      type = "rectangle", action = "fill", fillColor = fill,
      frame = { x = x0 + 3, y = 3, w = tabW - 6, h = BAR_H - 6 },
      roundedRectRadii = { xRadius = 6, yRadius = 6 },
    }
    local week = SHOW_USAGE and p.usage and p.usage.week
    if week then
      -- Usage gauge, in the account's colour (or the pace's): the bar is the
      -- weekly usage, the tick how much of the week has gone by.
      local mx, mw = x0 + 10, tabW - 20
      local paceHex = PACE_COLORS[pace(p)]
      local dim = usageStale(p) and 0.5 or 1
      els[#els + 1] = {
        type = "rectangle", action = "fill",
        fillColor = active and { white = 0, alpha = 0.25 } or { white = 1, alpha = 0.15 },
        frame = { x = mx, y = BAR_H - 7, w = mw, h = 3 },
        roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 },
      }
      els[#els + 1] = {
        type = "rectangle", action = "fill",
        fillColor = { hex = paceHex or (active and "#FFFFFF" or p.color), alpha = dim },
        frame = { x = mx, y = BAR_H - 7, w = math.max(2, mw * math.min(week, 100) / 100), h = 3 },
        roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 },
      }
      local e = weekElapsed(p)
      if e then
        els[#els + 1] = {
          type = "rectangle", action = "fill",
          fillColor = active and { hex = "#1B1B1D", alpha = 0.9 } or { white = 1, alpha = 0.9 },
          frame = { x = mx + mw * e - 1, y = BAR_H - 9, w = 2, h = 7 },
        }
      end
    elseif not active then  -- coloured underline to recognise the account
      els[#els + 1] = {
        type = "rectangle", action = "fill", fillColor = { hex = p.color },
        frame = { x = x0 + 3, y = BAR_H - 5, w = tabW - 6, h = 2 },
      }
    end
    local label = i .. "  " .. p.label
    local st = stateText(p)
    if st ~= "" then label = label .. "  ·  " .. st end
    local function style(color, font)
      return {
        font = font or { name = active and "HelveticaNeue-Medium" or "Helvetica Neue", size = 13 },
        color = color,
        paragraphStyle = { alignment = "center", lineBreak = "truncateTail" },
      }
    end
    local text = hs.styledtext.new(label, style({ white = 1, alpha = p.pid and 1 or 0.45 }))
    local tag = usageTag(p, style)
    if tag then text = text .. tag end
    els[#els + 1] = {
      type = "text",
      frame = { x = x0 + 12, y = (BAR_H - 17) / 2, w = tabW - 24 - badgesW, h = 18 },
      text = text,
    }
    local bx = x0 + tabW - 8 - badgesW + BADGE_GAP
    for _, b in ipairs(badges) do
      local cx = bx + BADGE_R
      els[#els + 1] = {
        type = "circle", action = "fill", fillColor = b.color,
        center = { x = cx, y = BAR_H / 2 }, radius = BADGE_R,
      }
      els[#els + 1] = {
        type = "text",
        frame = { x = cx - BADGE_R, y = BAR_H / 2 - 7, w = 2 * BADGE_R, h = 14 },
        text = hs.styledtext.new(b.n > 9 and "9+" or tostring(b.n), {
          font = { name = "HelveticaNeue-Bold", size = b.n > 9 and 8 or 10 },
          color = b.text,
          paragraphStyle = { alignment = "center" },
        }),
      }
      bx = bx + 2 * BADGE_R + BADGE_GAP
    end
  end
  canvas:replaceElements(els)
  if barVisible() then canvas:show() else canvas:hide() end
end

local function drawMenubar()
  if cfg.menubar == false then return end
  if not menubar then menubar = hs.menubar.new() end
  local work, done, att = 0, 0, 0
  for _, p in ipairs(profiles) do
    local w, d, a = counts(p)
    work, done, att = work + w, done + d, att + a
  end
  local font = { size = 13 }
  local title = hs.styledtext.new("✳︎", { color = { white = 0.6 }, font = { size = 14 } })
  if work > 0 then title = title .. hs.styledtext.new(" " .. work, { color = COLORS.working, font = font }) end
  if done > 0 then title = title .. hs.styledtext.new(" " .. done, { color = COLORS.done, font = font }) end
  if att > 0 then title = title .. hs.styledtext.new(" " .. att, { color = COLORS.attention, font = font }) end
  menubar:setTitle(title)
  menubar:setMenu(function()
    local items = {}
    for i, p in ipairs(profiles) do
      local st = stateText(p)
      if st == "" then st = countsText(p) end
      items[#items + 1] = {
        title = i .. "  " .. p.label .. (st ~= "" and ("  —  " .. st) or ""),
        checked = (p.id == activeId),
        fn = function() M.switchTo(p.id) end,
      }
      local u = SHOW_USAGE and usageDetail(p)
      if u then items[#items + 1] = { title = "      " .. u, disabled = true } end
    end
    items[#items + 1] = { title = "-" }
    local active = activeId and byId[activeId]
    if signInTarget then
      items[#items + 1] = { title = S.menuStopSignIn:format(byId[signInTarget].label),
        fn = function() M.stopSignIn() end }
    else
      items[#items + 1] = {
        title = S.menuSignIn:format(active and active.label or "?"),
        disabled = not active,
        fn = function() M.startSignIn() end,
      }
    end
    items[#items + 1] = { title = "-" }
    if WINDOW_MODE then
      items[#items + 1] = { title = S.menuFill, fn = function() M.fillScreen() end }
      items[#items + 1] = { title = S.menuNextScreen, fn = function() M.nextScreen() end }
      items[#items + 1] = { title = "-" }
    end
    items[#items + 1] = { title = S.menuAdd, fn = function() M.addProfile() end }
    items[#items + 1] = { title = "-" }
    items[#items + 1] = { title = S.menuConfig, fn = function()
      hs.execute("open -t " .. shq(DIR .. "/config.lua")) end }
    items[#items + 1] = { title = S.menuReload, fn = hs.reload }
    return items
  end)
end

draw = function()
  drawBar()
  drawMenubar()
end

---------------------------------------------------------------------------
-- Switching tabs
---------------------------------------------------------------------------

-- An account's window was just brought forward: the session it shows has been
-- seen. Slightly later, to let Claude write its lastFocusedAt.
local seenTimers = {}
local function markSeenSoon(p)
  if seenTimers[p.id] then seenTimers[p.id]:stop() end
  seenTimers[p.id] = hs.timer.doAfter(0.5, function()
    seenTimers[p.id] = nil
    local a = markDisplayedSeen(p)
    local b = rescan(p)
    if a or b then saveSessions(); draw() end
  end)
end

function M.switchTo(id)
  local p = byId[id]
  if not p then return end
  refresh()
  local w = profileWindow(p)
  if not w then
    -- Not running, or its window was closed: launching the profile again opens it.
    launch(p)
    activeId = id
    draw()
    return
  end
  if w:isMinimized() then w:unminimize() end
  placeWindow(w)
  w:focus()
  activeId = id
  markSeenSoon(p)
  draw()
end

-- Next (dir = 1) or previous (dir = -1) tab, wrapping around, skipping
-- profiles that are not running.
function M.cycle(dir)
  refresh()
  local n = #profiles
  local start = (activeId and byId[activeId] and byId[activeId].index) or 1
  for step = 1, n - 1 do
    local p = profiles[((start - 1 + dir * step) % n) + 1]
    if p.pid then M.switchTo(p.id); return end
  end
end

---------------------------------------------------------------------------
-- Adding, renaming and removing tabs ("+" button, right-click on a tab)
---------------------------------------------------------------------------

M.hotkeys = {}
local function bindTabHotkey(p)
  if p.index <= 9 then
    M.hotkeys[#M.hotkeys + 1] = hs.hotkey.bind(MODS, tostring(p.index), function() M.switchTo(p.id) end)
  end
end

local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function uniqueId(label)
  local id = label:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if id == "" then id = "account" end
  local base, n = id, 2
  while byId[id] do id = base .. "-" .. n; n = n + 1 end
  return id
end

local function ask(title, prompt, default, okButton)
  hs.focus()
  local button, text = hs.dialog.textPrompt(title, prompt, default or "", okButton, S.cancel)
  if button ~= okButton then return nil end
  local t = trim(text)
  return t ~= "" and t or nil
end

-- New account: a new tab with its own data folder. Launches it; you sign in
-- in its window, and the sign-in comes back to it (see watchClaudeLog).
function M.addProfile(label)
  label = label or ask(S.addTitle, S.addPrompt, "", S.addButton)
  if not label then return end
  local used = {}
  for _, p in ipairs(profiles) do used[p.color] = true end
  local color = PALETTE[#profiles % #PALETTE + 1]
  for _, c in ipairs(PALETTE) do if not used[c] then color = c; break end end
  local id = uniqueId(label)
  local p = newProfile({ id = id, label = label, color = color, dataDir = "~/.claude-profiles/" .. id }, #profiles + 1)
  profiles[#profiles + 1] = p
  byId[id] = p
  saveProfileList()
  M.makeLaunchers()
  bindTabHotkey(p)
  hs.alert.show(S.addedHint:format(label), 6)
  M.switchTo(id)
  return id
end

function M.renameProfile(id, label)
  local p = byId[id]
  if not p then return end
  label = label or ask(S.renameTitle, S.renamePrompt, p.label, S.renameButton)
  if not label or label == p.label then return end
  hs.execute("rm -rf " .. shq(LAUNCHER_DIR .. "/Claude " .. p.label .. ".app"))
  p.label = label
  saveProfileList()
  M.makeLaunchers()
  draw()
end

-- Removes the tab (and quits its Claude). Its data folder is kept.
function M.removeProfile(id, confirmed)
  local p = byId[id]
  if not p or #profiles <= 1 then return end
  if not confirmed then
    hs.focus()
    local where = p.rawDataDir or "~/Library/Application Support/Claude"
    local answer = hs.dialog.blockAlert(S.removeTitle:format(p.label), S.removeText:format(where),
      S.removeButton, S.cancel, "warning")
    if answer ~= S.removeButton then return end
  end
  if p.pid and p.dataDir then  -- never quit the main Claude
    local app = hs.application.applicationForPID(p.pid)
    if app then app:kill() end
  end
  hs.execute("rm -rf " .. shq(LAUNCHER_DIR .. "/Claude " .. p.label .. ".app"))
  table.remove(profiles, p.index)
  byId[id] = nil
  saveProfileList()
  hs.reload()  -- simplest way to renumber tabs and shortcuts
end

tabMenu = function(p)
  local items = {
    { title = S.menuSignInTab, fn = function() M.startSignIn(p.id) end },
    { title = S.menuRename, fn = function() M.renameProfile(p.id) end },
    { title = S.menuRemove, disabled = #profiles <= 1, fn = function() M.removeProfile(p.id) end },
    { title = "-" },
  }
  if SHOW_USAGE then
    local u = usageDetail(p)
    if u then items[#items + 1] = { title = u, disabled = true } end
    items[#items + 1] = { title = S.menuUsageRefresh, disabled = not p.pid,
      fn = function() M.refreshUsage(p.id) end }
    items[#items + 1] = { title = "-" }
  end
  for _, it in ipairs({
    { title = S.menuAdd, fn = function() M.addProfile() end },
  }) do items[#items + 1] = it end
  if M.tabPopup then M.tabPopup:delete() end
  M.tabPopup = hs.menubar.new(false)
  M.tabPopup:setMenu(items)
  M.tabPopup:popupMenu(hs.mouse.absolutePosition())
end

-- Modifier + scroll (mouse or trackpad) while Claude is in front: one notch =
-- one tab. A trackpad sends bursts of small steps: add them up to a threshold,
-- ignore momentum, and wait a little between two switches so one gesture
-- doesn't run through every tab.
local function scrollSwitcher()
  local T = hs.eventtap.event.types
  local P = hs.eventtap.event.properties
  local mod = cfg.scrollModifier or "cmd"
  local others = { cmd = true, alt = true, ctrl = true, shift = true }
  others[mod] = nil
  local acc, lastEvent, cooldownUntil = 0, 0, 0
  return hs.eventtap.new({ T.scrollWheel }, function(e)
    local flags = e:getFlags()
    if not flags[mod] then return false end
    for m in pairs(others) do if flags[m] then return false end end
    local front = hs.application.frontmostApplication()
    if not front or front:bundleID() ~= BUNDLE then return false end

    local now = hs.timer.secondsSinceEpoch()
    if e:getProperty(P.scrollWheelEventMomentumPhase) ~= 0 then return true end
    if now < cooldownUntil then return true end
    local continuous = e:getProperty(P.scrollWheelEventIsContinuous) ~= 0
    local delta = continuous and e:getProperty(P.scrollWheelEventPointDeltaAxis1)
      or e:getProperty(P.scrollWheelEventDeltaAxis1)
    if delta == 0 then return true end
    if now - lastEvent > 0.3 or (acc ~= 0 and (acc > 0) ~= (delta > 0)) then acc = 0 end
    lastEvent = now
    acc = acc + delta
    local threshold = continuous and 30 or 1
    if math.abs(acc) >= threshold then
      local dir = acc > 0 and -1 or 1          -- scroll up = previous tab
      if cfg.scrollInvert then dir = -dir end
      acc = 0
      cooldownUntil = now + 0.35
      hs.timer.doAfter(0, function() M.cycle(dir) end)
    end
    return true   -- ours: Claude does not get this event
  end)
end

---------------------------------------------------------------------------
-- Signing in to another account
--
-- claude:// links (like the "Open Claude" button after a Google sign-in in
-- the browser) always go to the first Claude instance that was started. In
-- sign-in mode, a tiny "Claude Tabs Link Router" app becomes the claude://
-- handler for a while. Claude notices it is no longer the handler and signs in
-- through macOS' own authentication sheet (ASWebAuthenticationSession), which
-- answers the right instance directly. If a claude:// link still arrives, the
-- router hands it over and send-url.js delivers it to the right instance.
-- Either way, Claude becomes the claude:// handler again afterwards.
---------------------------------------------------------------------------

local ROUTER_ID = "local.claudetabs.router"
local PENDING_LINK = DIR .. "/.pending-link"
local CLAUDE_LOG = HOME .. "/Library/Logs/Claude/main.log"
local signInTimer, logWatcher, logOffset

-- Send a claude:// link to one given instance instead of letting macOS pick.
function M.sendLink(url, id)
  refresh()
  local p = byId[id or activeId]
  if not p or not p.pid then hs.alert.show(S.notRunning); return false end
  local out, ok = hs.execute("/usr/bin/osascript -l JavaScript " .. shq(DIR .. "/send-url.js")
    .. " " .. math.tointeger(p.pid) .. " " .. shq(url) .. " 2>&1")
  if ok then
    log.i("claude:// link sent to " .. p.id .. " (pid " .. math.tointeger(p.pid) .. ")")
    hs.alert.show(S.linkSent:format(p.label))
    M.switchTo(p.id)
  else
    hs.alert.show(S.sendFailed:format(out or ""))
    log.e("send-url: " .. tostring(out))
  end
  return ok
end

local function urlHandler(action, bundle)
  local cmd = "/usr/bin/osascript -l JavaScript " .. shq(DIR .. "/url-handler.js") .. " " .. action
  if bundle then cmd = cmd .. " " .. shq(bundle) end
  local out, ok = hs.execute(cmd .. " 2>&1")
  out = (out or ""):gsub("%s+$", "")
  if not ok then log.e("url-handler: " .. out) end
  return ok and out or nil
end

function M.stopSignIn()
  if signInTimer then signInTimer:stop(); signInTimer = nil end
  if signInTarget then log.i("sign-in mode off for " .. signInTarget) end
  signInTarget = nil
  if urlHandler("get") ~= BUNDLE then urlHandler("set", BUNDLE) end
  draw()
end

-- quiet = started automatically from the log (the account is already in front).
function M.startSignIn(id, quiet)
  local p = byId[id or activeId]
  if not p then return end
  if urlHandler("set", ROUTER_ID) ~= ROUTER_ID then
    hs.alert.show(S.signInFailed)
    return
  end
  signInTarget = p.id
  log.i("sign-in mode on for " .. p.id .. (quiet and " (detected in Claude's log)" or ""))
  if signInTimer then signInTimer:stop() end
  signInTimer = hs.timer.doAfter(300, function()
    M.stopSignIn()
    hs.alert.show(S.signInTimeout)
  end)
  if quiet then
    hs.alert.show(S.signInAuto:format(p.label), 4)
  else
    hs.alert.show(S.signInOn:format(p.label), 4)
    M.switchTo(p.id)
  end
  draw()
end

-- Claude's log (shared by all instances). Two lines matter:
--  "[Auth] Using system browser for: /login/…": an account just opened a sign-in
--    in the browser, from the window in front. Route the coming "Open Claude"
--    link to it: start sign-in mode for that account, quietly.
--  "ASWebAuth completed" / "verified sign-in": the sign-in is done.
-- Polled every second: Claude keeps its log open, so macOS file events don't
-- report its writes.
local function watchClaudeLog()
  local attrs = hs.fs.attributes(CLAUDE_LOG)
  logOffset = attrs and attrs.size or 0
  logWatcher = hs.timer.doEvery(1, function()
    local a = hs.fs.attributes(CLAUDE_LOG)
    if not a or a.size == logOffset then return end
    if a.size < logOffset then logOffset = 0 end  -- log rotated
    local f = io.open(CLAUDE_LOG, "r")
    if not f then return end
    f:seek("set", logOffset)
    local chunk = f:read("a") or ""
    logOffset = f:seek()
    f:close()
    if signInTarget and (chunk:find("ASWebAuth completed", 1, true) or chunk:find("verified sign-in", 1, true)) then
      local target = signInTarget
      M.stopSignIn()
      hs.alert.show(S.signInDone)
      if target then hs.timer.doAfter(1.5, function() M.switchTo(target) end) end
    elseif cfg.autoSignIn ~= false and not signInTarget
      and chunk:find("[Auth] Using system browser for:", 1, true) then
      -- The browser has usually come forward by now: then the account that
      -- started the sign-in is the last Claude tab that was in front.
      local front = hs.application.frontmostApplication()
      local p = front and front:bundleID() == BUNDLE and pidProfile(front:pid())
      p = p or (activeId and byId[activeId])
      if p then M.startSignIn(p.id, true) end
    end
  end)
  return logWatcher
end

-- hammerspoon://claude-tabs-link, sent by the router with the link in PENDING_LINK.
local function onRouterLink()
  local url = readFile(PENDING_LINK)
  os.remove(PENDING_LINK)
  local target = signInTarget or activeId
  M.stopSignIn()
  url = (url or ""):gsub("%s+$", "")
  if url:match("^claude://") then
    M.sendLink(url, target)
  else
    log.w("router: empty or invalid link")
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

-- Sent by hook.sh: hammerspoon://claude-tabs?event=…&pid=…&session=…
-- (URL event names must be lowercase: macOS lowercases the host part.)
local function onHookEvent(_, params)
  local pid = tonumber(params.pid)
  local p = pid and pidProfile(pid)
  if not p then refresh(); p = pid and pidProfile(pid) end
  if not p then return end
  p.pid = pid
  local cli = params.session
  if not cli or cli == "" then return end
  local ev = params.event
  if ev == "prompt" then
    setSession(p, cli, "working")
  elseif ev == "stop" then
    local s = setSession(p, cli, "done")
    -- Finished right in front of you (this account's window in front, on this session): already read.
    if isFrontmost(p) and s.file and s.file == displayedSessionFile(p) then p.sessions[cli] = nil end
  elseif ev == "attention" then
    setSession(p, cli, "attention")
  elseif ev == "answered" then
    local s = p.sessions[cli]
    if s and s.state == "attention" then setSession(p, cli, "working") end
  end
  saveSessions()
  draw()
end

-- Window mode without autoFill: if there is no room for the bar above the
-- window (window at the top of the screen, maximised…), move it down a bit.
local roomTimer, autoFillTimer
local function makeRoomForBar(w)
  if roomTimer then roomTimer:stop() end
  roomTimer = hs.timer.doAfter(0.5, function()
    roomTimer = nil
    if not w:isVisible() or w:isFullScreen() then return end
    local f, s = w:frame(), w:screen():frame()
    if f.y - BAR_H < s.y - 1 then
      local top = s.y + BAR_H
      local h = math.max(300, f.h - (top - f.y))
      w:setFrame(hs.geometry.rect(f.x, top, f.w, h), 0)
    end
  end)
end

local function onWindowEvent(w, _, event)
  if not w then return end
  local app = w:application()
  if not app or app:bundleID() ~= BUNDLE then return end
  local p = pidProfile(app:pid())
  if not p then return end
  p.pid = app:pid()
  if not isTabWindow(w) then return end
  local wf = hs.window.filter
  if event == wf.windowMoved then
    -- The front window was moved or resized: the group follows.
    if AUTO_FILL and p.id == activeId and not w:isFullScreen() then
      -- Once the gesture is over: fill the screen the window is on.
      if autoFillTimer then autoFillTimer:stop() end
      autoFillTimer = hs.timer.doAfter(0.6, function()
        autoFillTimer = nil
        if not w:isVisible() or w:isFullScreen() then return end
        local s = w:screen()
        if not s then return end
        local z = s:frame()
        if not sameRect(w:frame(), hs.geometry.rect(z.x, z.y + BAR_H, z.w, z.h - BAR_H)) then
          setGroupFrame(z); applyGroup()
        end
      end)
    elseif WINDOW_MODE and p.id == activeId and not w:isFullScreen() then
      local f = w:frame()
      setGroupFrame(hs.geometry.rect(f.x, f.y - BAR_H, f.w, f.h + BAR_H))
      makeRoomForBar(w)
    end
    drawBar()
    return
  end
  if event == wf.windowMinimized or event == wf.windowUnminimized then
    drawBar()
    return
  end
  if event == wf.windowFocused then
    activeId = p.id
    markSeenSoon(p)
  end
  if cfg.snapOnFocus ~= false then placeWindow(w) end
  draw()
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------

function M.start()
  hs.window.animationDuration = 0
  -- A Claude instance that is starting or busy can be slow to answer the
  -- accessibility API: don't let it freeze the bar for long.
  hs.window.timeout(2)
  M.makeLaunchers()
  loadSessions()
  refresh()

  local front = hs.application.frontmostApplication()
  if front and front:bundleID() == BUNDLE then
    local p = pidProfile(front:pid()); if p then activeId = p.id end
  end
  if not activeId then
    for _, p in ipairs(profiles) do if p.pid then activeId = p.id; break end end
  end

  M.appWatcher = hs.application.watcher.new(function(name, ev)
    -- Window mode or shared screen: show or hide the bar with the front app.
    if (ev == hs.application.watcher.activated or ev == hs.application.watcher.deactivated)
      and (WINDOW_MODE or not configuredScreen()) then
      drawBar()
    end
    if name ~= "Claude" then return end
    if ev == hs.application.watcher.launched or ev == hs.application.watcher.terminated then
      if ev == hs.application.watcher.terminated then pidCache = {} end
      hs.timer.doAfter(0.5, function() refresh(); draw() end)
    end
  end):start()

  M.windowFilter = hs.window.filter.new({ "Claude" })
  local wf = hs.window.filter
  M.windowFilter:subscribe({ wf.windowFocused, wf.windowCreated, wf.windowMoved,
    wf.windowMinimized, wf.windowUnminimized }, onWindowEvent)

  -- A screen's usable area also changes without any screen change: the Dock
  -- moves to another screen, the menu bar hides… Every 2 s, check that the
  -- group and the front window still match it.
  if AUTO_FILL then
    M.layoutGuard = hs.timer.doEvery(2, function()
      if dragTap or hs.eventtap.checkMouseButtons()["left"] then return end  -- gesture in progress
      local z = groupScreen():frame()
      if not sameRect(currentGroupFrame(), z) then
        setGroupFrame(z); applyGroup(); return
      end
      local p = activeId and byId[activeId]
      local w = p and profileWindow(p)
      if w and w:isVisible() and not w:isFullScreen() and not sameRect(w:frame(), zone().win) then
        placeWindow(w)
      end
    end)
  end

  M.screenWatcher = hs.screen.watcher.new(function()
    if AUTO_FILL then
      -- Screen plugged, unplugged, woken up: fill the one the group is on.
      hs.timer.doAfter(1, function()
        setGroupFrame(groupScreen():frame())
        applyGroup()
      end)
      return
    end
    draw()
    local p = activeId and byId[activeId]
    local w = p and profileWindow(p)
    if w then placeWindow(w) end
  end):start()

  -- Session files: when Claude rewrites one (you open a session, a turn
  -- ends…), re-read the tracked ones.
  M.sessionWatchers = {}
  local scanTimers = {}
  local function watchSessions(p)
    if M.sessionWatchers[p.id] or not hs.fs.attributes(sessionsDir(p)) then return end
    M.sessionWatchers[p.id] = hs.pathwatcher.new(sessionsDir(p), function()
      if next(p.sessions) == nil then return end
      if scanTimers[p.id] then scanTimers[p.id]:stop() end
      scanTimers[p.id] = hs.timer.doAfter(1, function()
        scanTimers[p.id] = nil
        if rescan(p) then draw() end
      end)
    end):start()
  end

  -- Every minute: safety re-read, and forget "working" / "waiting" sessions
  -- that went silent (session killed, etc.).
  M.staleTimer = hs.timer.doEvery(60, function()
    local limit = nowMs() - (cfg.workingTimeout or 1800) * 1000
    local changed = false
    for _, p in ipairs(profiles) do
      watchSessions(p)
      for id, s in pairs(p.sessions) do
        if s.state ~= "done" and s.at < limit then p.sessions[id] = nil; changed = true end
      end
      if rescan(p) then changed = true end
    end
    if changed then saveSessions(); draw() end
  end)
  for _, p in ipairs(profiles) do watchSessions(p); rescan(p) end

  -- Usage: every minute, re-read the files Claude wrote (a stat each, unless
  -- they changed). When an account's numbers are stale, and you have been
  -- away from the keyboard for a while with the screen on, open its usage
  -- menu (one account per minute, one try per account every 30 min).
  if SHOW_USAGE then
    for id, w in pairs(hs.settings.get(RESET_KEY) or {}) do
      if type(w) == "table" and tonumber(w.lo) and tonumber(w.hi) then
        resetWin[id] = { lo = tonumber(w.lo), hi = tonumber(w.hi) }
      end
    end
    hs.settings.clear("claudeTabs.usageReset")  -- older format
    local screens = { asleep = false, saver = false, locked = false, away = false }
    local W = hs.caffeinate.watcher
    local events = {
      [W.screensDidSleep] = { "asleep", true }, [W.screensDidWake] = { "asleep", false },
      [W.screensaverDidStart] = { "saver", true }, [W.screensaverDidStop] = { "saver", false },
      [W.screensDidLock] = { "locked", true }, [W.screensDidUnlock] = { "locked", false },
      [W.sessionDidResignActive] = { "away", true }, [W.sessionDidBecomeActive] = { "away", false },
      [W.systemWillSleep] = { "asleep", true }, [W.systemDidWake] = { "asleep", false },
    }
    M.screensWatcher = W.new(function(ev)
      local e = events[ev]
      if e then screens[e[1]] = e[2] end
    end):start()
    local function canPoke()
      if not USAGE_REFRESH or hs.host.idleTime() < USAGE_IDLE then return false end
      for _, v in pairs(screens) do if v then return false end end
      local props = hs.caffeinate.sessionProperties() or {}
      if props.CGSSessionScreenIsLocked then return false end
      for _, down in pairs(hs.eventtap.checkMouseButtons()) do if down then return false end end
      return true
    end
    for _, p in ipairs(profiles) do readUsage(p) end
    M.usageTimer = hs.timer.doEvery(60, function()
      local changed = false
      for _, p in ipairs(profiles) do if readUsage(p) then changed = true end end
      if changed then draw() end
      if not canPoke() then return end
      local now = nowS()
      for _, p in ipairs(profiles) do
        if p.pid and usageStale(p) and now - (pokeAt[p.id] or 0) > USAGE_RETRY then
          pokeUsage(p, function() draw() end); return
        end
      end
    end)
  end

  -- Right-click on a tab: its menu. The canvas only reports left clicks, so
  -- catch right clicks that land on the bar here.
  M.rightClickTap = hs.eventtap.new({ hs.eventtap.event.types.rightMouseDown }, function(e)
    if not canvas or not canvas:isShowing() then return false end
    local pt, bar = e:location(), canvas:frame()
    if pt.x < bar.x or pt.x > bar.x + bar.w or pt.y < bar.y or pt.y > bar.y + bar.h then return false end
    local p = profiles[math.floor((pt.x - bar.x) / tabWidth()) + 1]
    if p then hs.timer.doAfter(0, function() tabMenu(p) end) end
    return true
  end):start()

  if cfg.scrollSwitch ~= false then
    M.scrollTap = scrollSwitcher():start()
    -- macOS disables an event tap that was too slow; restart it if needed.
    M.scrollGuard = hs.timer.doEvery(5, function()
      if not M.scrollTap:isEnabled() then M.scrollTap:start() end
    end)
  end

  for _, p in ipairs(profiles) do bindTabHotkey(p) end
  M.hotkeys[#M.hotkeys + 1] = hs.hotkey.bind(MODS, "F", function() M.fillScreen() end)
  M.hotkeys[#M.hotkeys + 1] = hs.hotkey.bind(MODS, "E", function() M.nextScreen() end)
  M.hotkeys[#M.hotkeys + 1] = hs.hotkey.bind(MODS, "L", function()
    if signInTarget then M.stopSignIn(); hs.alert.show(S.signInStopped)
    else M.startSignIn() end
  end)

  hs.urlevent.bind("claude-tabs", onHookEvent)
  hs.urlevent.bind("claude-tabs-link", onRouterLink)
  M.logWatcher = watchClaudeLog()
  -- If Hammerspoon restarted during sign-in mode, give claude:// links back to Claude.
  if urlHandler("get") == ROUTER_ID then urlHandler("set", BUNDLE) end

  M.configWatcher = hs.pathwatcher.new(DIR, function(files)
    for _, f in ipairs(files) do
      if f:match("%.lua$") then hs.reload(); return end
    end
  end):start()

  draw()
  log.i(S.ready:format(targetScreen():name()))
end

---------------------------------------------------------------------------
-- Debugging and tests (from the Hammerspoon console or `hs -c`)
---------------------------------------------------------------------------

function M.geometry()
  return string.format("group=%s bar=%s showing=%s", tostring(currentGroupFrame()),
    tostring(canvas and canvas:frame()), tostring(canvas and canvas:isShowing()))
end

function M.resetGroup()
  groupFrame = nil
  hs.settings.clear(GROUP_KEY)
  applyGroup()
end

-- cliId, or a prefix ending with "*".
function M.forgetSession(cliId)
  local prefix = cliId:match("^(.*)%*$")
  for _, p in ipairs(profiles) do
    for id in pairs(p.sessions) do
      if id == cliId or (prefix and id:sub(1, #prefix) == prefix) then p.sessions[id] = nil end
    end
  end
  saveSessions(); draw()
end

function M.state()
  local out = { "signIn=" .. tostring(signInTarget) }
  for _, p in ipairs(profiles) do
    local w, d, a = counts(p)
    out[#out + 1] = string.format("%s pid=%s working=%d done=%d attention=%d active=%s",
      p.id, tostring(p.pid), w, d, a, tostring(p.id == activeId))
    for id, s in pairs(p.sessions) do
      out[#out + 1] = string.format("   %s %s %s", id:sub(1, 8), s.state,
        s.file and s.file:match("local_[%w%-]+") or "(no file)")
    end
  end
  return table.concat(out, "\n")
end

-- Open an account's usage menu now (tab menu > Refresh usage), then re-read.
function M.refreshUsage(id)
  local p = byId[id or activeId]
  if not p or not p.pid then return false end
  pokeUsage(p, function()
    draw()  -- the reset time may have changed
    -- Claude writes the file once its request comes back.
    for _, delay in ipairs({ 1, 3, 8 }) do
      hs.timer.doAfter(delay, function() if readUsage(p) then draw() end end)
    end
  end)
  return true
end

function M.usage()
  local out = {}
  for _, p in ipairs(profiles) do
    local mid, width = resetInfo(p)
    out[#out + 1] = string.format("%s week=%s five=%s age=%s reset=%s width=%s elapsed=%s pace=%s stale=%s",
      p.id, tostring(p.usage and p.usage.week), tostring(p.usage and p.usage.five),
      p.usage and math.floor(nowS() - p.usage.at) .. "s" or "-",
      mid and os.date("%a %d %H:%M", math.floor(mid)) or "-", width and math.floor(width / 60) .. "min" or "-",
      tostring(weekElapsed(p) and math.floor(weekElapsed(p) * 100) .. "%"),
      p.usage and p.usage.week and pace(p) or "-", tostring(usageStale(p)))
  end
  return table.concat(out, "\n")
end

-- true when the bar and the front tab's window are where they should be.
function M.layoutOk()
  local p = activeId and byId[activeId]
  local w = p and profileWindow(p)
  if AUTO_FILL and not sameRect(currentGroupFrame(), groupScreen():frame()) then return false end
  if w and not w:isFullScreen() and not sameRect(w:frame(), zone().win) then return false end
  return canvas ~= nil and sameRect(canvas:frame(), zone().bar)
end

-- Pure helpers, exposed for tests.
M._test = { profileForCommand = profileForCommand, counts = counts, sameRect = sameRect }

return M
