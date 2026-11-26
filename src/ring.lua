-- Session ring: your latest Code sessions, all accounts mixed, in a ring
-- around the pointer (config.ringHotkey, ⌃⌥⇧⌘R by default; a mouse button can
-- send it, e.g. through Logi Options+). Move toward a slice, then left-click
-- or press the shortcut again to open that session in its account. Esc,
-- right-click or a click in the middle closes it.
--
-- Built by init.lua: dofile(".../ring.lua")(deps), where deps gives
--   entries()  -> { { id, title, at (ms), state?, p = profile }, … }, newest first
--   open(e)    opens that session
--   colors, glyphs: by state; ago(ms) -> "3 min"; empty: text when there is none

return function(deps)
  local M = {}

  local R_OUT, R_IN = 190, 52            -- the ring's radii (points)
  local LABEL_W, LABEL_H = 140, 54
  local FONT = ".AppleSystemUIFont"
  local SIZE = R_OUT * 2 + 4

  local canvas, tap, escKey, center, entries, selected

  local function color(hex, alpha)
    local c = hs.drawing.color.asRGB({ hex = hex or "#D97757" })
    c.alpha = alpha or 1
    return c
  end

  local function truncate(s, n)
    local len = utf8.len(s)
    if len and len > n then return s:sub(1, utf8.offset(s, n) - 1) .. "…" end
    return s
  end

  -- Angle of slice i (0 = top, clockwise), in radians.
  local function sliceAngle(i, n) return (i - 1) * 2 * math.pi / n end

  local function wedge(i, n)
    local half = math.pi / n
    local a0, a1 = sliceAngle(i, n) - half, sliceAngle(i, n) + half
    local pts, steps, c = {}, 24, SIZE / 2
    for k = 0, steps do
      local a = a0 + (a1 - a0) * k / steps
      pts[#pts + 1] = { x = c + R_OUT * math.sin(a), y = c - R_OUT * math.cos(a) }
    end
    for k = steps, 0, -1 do
      local a = a0 + (a1 - a0) * k / steps
      pts[#pts + 1] = { x = c + R_IN * math.sin(a), y = c - R_IN * math.cos(a) }
    end
    return pts
  end

  local function draw()
    local n = #entries
    local els = {}
    for i, e in ipairs(entries) do
      local on = (i == selected)
      els[#els + 1] = {
        type = "segments", closed = true, action = "strokeAndFill",
        coordinates = wedge(i, n),
        fillColor = on and color(e.p.color, 0.92) or { white = 0.12, alpha = 0.88 },
        strokeColor = { white = 1, alpha = on and 0.9 or 0.25 }, strokeWidth = on and 2 or 1,
      }
      local a, r = sliceAngle(i, n), (R_OUT + R_IN) / 2
      local small = { name = FONT, size = 10 }
      local centred = { alignment = "center" }
      local text = hs.styledtext.new(truncate(e.title, 30) .. "\n", {
        font = { name = FONT, size = 12 }, color = { white = 1 },
        paragraphStyle = { alignment = "center", lineBreak = "wordWrap" },
      })
      -- The session's state, as on the tabs: ! waiting for you, ⋯ working, ✓ done.
      if e.state and deps.glyphs[e.state] then
        text = text .. hs.styledtext.new(deps.glyphs[e.state] .. "  ", {
          font = { name = FONT, size = 11 }, paragraphStyle = centred,
          color = on and { white = 1 } or deps.colors[e.state],
        })
      end
      text = text .. hs.styledtext.new(e.p.label .. " · " .. deps.ago(e.at), {
        font = small, paragraphStyle = centred,
        color = on and { white = 1, alpha = 0.9 } or color(e.p.color, 1),
      })
      els[#els + 1] = { type = "text", text = text, frame = {
        x = SIZE / 2 + r * math.sin(a) - LABEL_W / 2,
        y = SIZE / 2 - r * math.cos(a) - LABEL_H / 2,
        w = LABEL_W, h = LABEL_H,
      } }
    end
    els[#els + 1] = {
      type = "circle", center = { x = SIZE / 2, y = SIZE / 2 }, radius = R_IN - 6,
      fillColor = { white = 0.08, alpha = 0.85 }, strokeColor = { white = 1, alpha = 0.25 },
      action = "strokeAndFill",
    }
    els[#els + 1] = {
      type = "text", text = hs.styledtext.new(n == 0 and deps.empty or "✳︎", {
        font = { name = FONT, size = n == 0 and 11 or 20 }, color = color("#D97757"),
        paragraphStyle = { alignment = "center" },
      }),
      frame = { x = SIZE / 2 - 40, y = SIZE / 2 - (n == 0 and 15 or 13), w = 80, h = 32 },
    }
    canvas:replaceElements(els)
  end

  -- The slice under a point, if any.
  local function pick(pos)
    local dx, dy = pos.x - center.x, pos.y - center.y
    local n = #entries
    if n == 0 or dx * dx + dy * dy < R_IN * R_IN then return nil end
    local a = math.atan(dx, -dy)          -- 0 at the top, clockwise
    if a < 0 then a = a + 2 * math.pi end
    return math.floor((a + math.pi / n) / (2 * math.pi / n)) % n + 1
  end

  -- Around the pointer, moved back inside its screen near an edge.
  local function place()
    local pos = hs.mouse.absolutePosition()
    local scr = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local f = scr:fullFrame()
    local h = SIZE / 2
    center = {
      x = math.max(f.x + h, math.min(f.x + f.w - h, pos.x)),
      y = math.max(f.y + h, math.min(f.y + f.h - h, pos.y)),
    }
  end

  local function build()
    entries = deps.entries()
    selected = nil
    place()
    if canvas then canvas:delete() end
    canvas = hs.canvas.new({ x = center.x - SIZE / 2, y = center.y - SIZE / 2, w = SIZE, h = SIZE })
    canvas:level(hs.canvas.windowLevels.popUpMenu)
    canvas:behavior({ "canJoinAllSpaces", "transient" })
    draw()
  end

  function M.close()
    if tap then tap:stop(); tap = nil end
    if escKey then escKey:delete(); escKey = nil end
    if canvas then canvas:delete(); canvas = nil end
  end

  local function choose()
    local e = selected and entries[selected]
    M.close()
    if e then deps.open(e) end
  end

  function M.isOpen() return tap ~= nil end

  -- Open the ring; when it is open, the same shortcut opens the chosen slice.
  function M.toggle()
    if tap then choose(); return end
    build()
    canvas:show()
    local T = hs.eventtap.event.types
    tap = hs.eventtap.new({ T.mouseMoved, T.leftMouseDown, T.leftMouseUp, T.rightMouseDown, T.rightMouseUp },
      function(ev)
        local t = ev:getType()
        if t == T.mouseMoved then
          local s = pick(hs.mouse.absolutePosition())
          if s ~= selected then selected = s; draw() end
          return false
        elseif t == T.leftMouseDown then
          selected = pick(hs.mouse.absolutePosition())
          hs.timer.doAfter(0, choose)
        elseif t == T.rightMouseDown then
          hs.timer.doAfter(0, M.close)
        end
        return true                       -- clicks never reach what is under the ring
      end)
    tap:start()
    escKey = hs.hotkey.bind({}, "escape", M.close)
  end

  -- Checks: a picture of the ring (slice i highlighted), without showing it.
  function M.snapshot(path, i)
    local shown = tap ~= nil
    if not shown then build() end
    if i then selected = i; draw() end
    local ok = canvas:imageFromCanvas():saveToFile(path)
    if not shown then canvas:delete(); canvas = nil end
    return ok
  end

  -- Checks: the slices as text, clockwise from the top.
  function M.text()
    local out = {}
    for i, e in ipairs(deps.entries()) do
      out[#out + 1] = ("%d  %-9s %-12s %-8s %s"):format(i, e.state or "-", e.p.id, deps.ago(e.at), e.title)
    end
    return table.concat(out, "\n")
  end

  return M
end
