-- FPVDash theme "Glass Cockpit" (tx16s-theme-spec, option A): avionics-style, near-black ground,
-- thin rules. Colour carries meaning only: white measured, cyan pilot-set, amber caution, red
-- warning, magenta home. Designed at 800x480 and scaled; large numbers are sprites from
-- img/cockpit (IBM Plex Mono, Barlow Semi Condensed), labels use the radio's own fonts.
local K = ...
local floor, max, min = math.floor, math.max, math.min
local textW, textH, ascent = K.textW, K.textH, K.ascent
local sText, sSet, sWidth = K.sText, K.sSet, K.sWidth

local RGB = lcd.RGB
local C = {
  bg = RGB(10, 10, 9), line = RGB(42, 41, 37), fg = RGB(242, 240, 234), soft = RGB(196, 193, 183),
  dim = RGB(143, 140, 130), mute = RGB(79, 76, 70), track = RGB(30, 29, 26), pipOff = RGB(58, 57, 52),
  dimBorder = RGB(74, 72, 66), armedCell = RGB(43, 15, 12), cyan = RGB(79, 209, 230),
  amber = RGB(255, 176, 32), red = RGB(255, 59, 48), magenta = RGB(226, 107, 234), tick = RGB(106, 103, 95),
}
local QR_INK, QR_PAPER = RGB(0, 0, 0), RGB(255, 255, 255)
-- severity to colour name (sprite colour bands use the same names)
local SEV = { normal = "fg", home = "fg", set = "cyan", caution = "amber", warn = "red", armed = "red", neutral = "soft" }
local PAGE_OF = { live = "dash", nav = "nav", lost = "lost", summary = "summary", find = "find", log = "log",
                  waiting = "wait", sim = "wait" }
local BLOCKS = 4

local function upper(s) return string.upper(s or "") end
local function num(x) return string.format("%d", floor(x + 0.5)) end
local function sevColor(sev) return C[SEV[sev] or "fg"] end

-- the round range the plan view shows: just above the distance
local RANGES = { 100, 200, 500, 1000, 1500, 2000, 3000, 5000, 10000, 20000, 50000 }
local function range(d)
  for _, r in ipairs(RANGES) do
    if (d or 0) < r then return r end
  end
  return RANGES[#RANGES]
end
local function rangeText(m)
  if m < 1000 then return string.format("%d m", floor(m + 0.5)) end
  return string.format(m % 1000 == 0 and "%d km" or "%.1f km", m / 1000)
end

local function build(w)
  local W, H = w.zone.w, w.zone.h
  local k = min(W / 800, H / 480)
  local small = k < 0.8
  local function P(n) return floor(n * k + 0.5) end
  local S = K.loadSprites(K.DIR .. "img/cockpit/" .. (small and "60" or "100") .. "/fonts.lua")
  if not S then error("sprites missing: " .. K.DIR .. "img/cockpit") end
  local v = w.v
  v.screen, v.blocks, v.stats = "wait", {}, {}
  local SW = K.switches

  local function add(list, objs) for _, o in ipairs(objs) do list[#list + 1] = o end end
  local function on(page) return function() return v.screen == page end end
  -- a label whose baseline is at `base`; right-aligned labels end at x
  local function lab(x, base, font, text, color, right, visible)
    local y = base - ascent(font)
    if right then
      return { type = "label", x = x - P(400), y = y, w = P(400), align = RIGHT, font = font, text = text,
               color = color, visible = visible }
    end
    return { type = "label", x = x, y = y, font = font, text = text, color = color, visible = visible }
  end
  local function rect(x, y, wd, ht, color, extra)
    local r = { type = "rectangle", x = x, y = y, w = wd, h = ht, filled = true, color = color }
    for key, val in pairs(extra or {}) do r[key] = val end
    return r
  end
  local function hline(x, y, wd) return rect(x, y, wd, 1, C.line) end
  local function vline(x, y, ht) return rect(x, y, 1, ht, C.line) end
  local function track(f, em) return (em or 0) * f.px end
  -- a sprite field: the objects go into list, the field is returned
  local function field(list, font, n, x, base, align, em)
    local f = S[font]
    local objs, fld = sText(f, n, x, base, align, track(f, em))
    add(list, objs)
    return fld
  end

  -- Switch strip (dashboard, waiting, simulator) ------------------------------------------
  local strip = {}
  local stripH = P(62)
  local n = #SW
  local cellW = n > 0 and W / n or W
  v.sw = {}
  for i, s in ipairs(SW) do
    local x0, x1 = floor((i - 1) * cellW + 0.5), floor(i * cellW + 0.5)
    local t, tile = w.sw[i], {}
    v.sw[i] = tile
    local right = (i < n) and (x1 - 1) or x1
    strip[#strip + 1] = rect(x0, 0, x1 - x0, stripH, C.armedCell, { visible = function() return t.sev == "armed" end })
    if i < n then strip[#strip + 1] = vline(x1 - 1, 0, stripH) end
    local tx = x0 + P(10)
    local rowBase = P(21)
    local labelEnd = tx + textW(s[1], TINSIZE)
    strip[#strip + 1] = lab(tx, rowBase, TINSIZE, s[1], C.fg)
    if not small then
      strip[#strip + 1] = lab(labelEnd + P(6), rowBase, TINSIZE, upper(s[2]), C.dim)
      labelEnd = labelEnd + P(6) + textW(upper(s[2]), TINSIZE)
    end
    local pipX, pip = right - P(10) - max(2, P(4)), max(2, P(4))
    if s.pot then
      -- the level bar gives way to a long function name
      local tx1 = right - P(10)
      local tw = min(P(24), tx1 - labelEnd - P(6))
      if tw >= P(8) then
        strip[#strip + 1] = rect(tx1 - tw, P(14), tw, pip, C.pipOff)
        strip[#strip + 1] = rect(tx1 - tw, P(14), tw, pip, C.fg,
          { size = function() return max(1, floor(tw * t.level / 100 + 0.5)), pip end })
      end
    else
      local np = t.n
      local y0 = (np == 3) and P(9) or P(10)
      for j = 1, np do
        strip[#strip + 1] = rect(pipX, y0 + (j - 1) * (pip + max(1, P(2))), pip, pip, C.pipOff,
          { color = function() return (t.dot == j) and sevColor(t.sev) or C.pipOff end })
      end
    end
    tile.room = right - P(10) - tx
    tile.fld = field(strip, "sw", 9, tx, P(51), "l", 0.02)
  end
  strip[#strip + 1] = hline(0, stripH, W)

  -- Annunciator: state blocks on the left, GPS and timer on the right -----------------------
  local blockH, blockPad, border = P(34), P(12), max(1, P(2))
  local function annunciator(list, y, key)
    local bv = {}
    v.blocks[key] = bv
    local ty = y + floor((blockH - textH(BOLD)) / 2 + 0.5)
    for i = 1, BLOCKS do
      local has = function() return bv[i] ~= nil end
      local warn = function() return bv[i] ~= nil and bv[i].sev == "warn" end
      -- EdgeTX 3.0 evaluates these callbacks even while the block is hidden, so bv[i] may be nil
      local bx = function() return bv[i] and bv[i].x or P(20) end
      local bw = function() return bv[i] and bv[i].w or P(100) end
      add(list, {
        rect(P(20), y, P(100), blockH, C.red, { rounded = max(1, P(2)), visible = warn,
          pos = function() return bx(), y end, size = function() return bw(), blockH end }),
        { type = "rectangle", x = P(20), y = y, w = P(100), h = blockH, filled = false, thickness = border,
          rounded = max(1, P(2)), visible = function() return bv[i] ~= nil and bv[i].sev ~= "warn" end,
          color = function() return bv[i] and bv[i].border or C.red end,
          pos = function() return bx(), y end, size = function() return bw(), blockH end },
        { type = "label", x = P(20), y = ty, font = BOLD, visible = has,
          text = function() return bv[i] and bv[i].text or "" end,
          color = function() return bv[i] and bv[i].color or C.red end,
          pos = function() return bx() + border + blockPad, ty end },
      })
    end
    return bv
  end
  local function gpsGroup(list, base, key)
    local g = { gpsX = 0, satX = 0, statusX = 0, status = "", statusColor = C.red }
    v[key] = g
    add(list, {
      { type = "label", x = 0, y = base - ascent(TINSIZE), font = TINSIZE, text = "GPS", color = C.dim,
        pos = function() return g.gpsX, base - ascent(TINSIZE) end },
      { type = "label", x = 0, y = base - ascent(TINSIZE), font = TINSIZE, text = "SAT", color = C.dim,
        pos = function() return g.satX, base - ascent(TINSIZE) end },
      { type = "label", x = 0, y = base - ascent(SMLSIZE), font = SMLSIZE, text = function() return g.status end,
        color = function() return g.statusColor end, pos = function() return g.statusX, base - ascent(SMLSIZE) end },
    })
    g.count = field(list, "gps", 3, 0, base, "l", -0.03)
    return g
  end

  -- Instruments: battery and link quality -----------------------------------------------
  local annY = stripH + 1 + P(12)
  local instTop, statsTop = stripH + 1 + P(58), H - P(32) - P(87)
  local barW = P(352)
  local function instrument(dash, x0, key, title, unit, sub, scale)
    local e = { frac = 0, color = C.fg, unitX = x0, detail = "" }
    v[key] = e
    local top = instTop
    add(dash, {
      lab(x0, top + P(30), TINSIZE, title, C.dim),
      lab(x0 + barW, top + P(30), SMLSIZE, function() return e.detail end, C.soft, true),
    })
    e.hero = field(dash, "hero", 5, x0, top + P(148), "l", -0.05)
    add(dash, {
      { type = "label", x = x0, y = top + P(148) - ascent(MIDSIZE), font = MIDSIZE, text = unit, color = C.dim,
        pos = function() return e.unitX, top + P(148) - ascent(MIDSIZE) end },
      { type = "label", x = x0, y = top + P(166) - ascent(TINSIZE), font = TINSIZE, text = sub, color = C.dim,
        pos = function() return e.unitX, top + P(166) - ascent(TINSIZE) end },
    })
    local by, bh = top + P(182), P(14)
    dash[#dash + 1] = rect(x0, by, barW, bh, C.track)
    dash[#dash + 1] = rect(x0, by, barW, bh, C.fg, {
      size = function() return max(1, floor(barW * e.frac + 0.5)), bh end,
      color = function() return e.color end, visible = function() return e.frac > 0 end })
    -- the fill is cut into 10 px segments by 2 px gaps in the ground colour
    local pitch, gap = 12 * k, max(1, P(2))
    local gx = 10 * k
    while gx < barW - 1 do
      dash[#dash + 1] = rect(x0 + floor(gx + 0.5), by, gap, bh, C.bg)
      gx = gx + pitch
    end
    local mx = x0 + floor(barW * scale[4] + 0.5)
    local lb = top + P(218)
    add(dash, {
      rect(mx, by - P(5), max(1, P(2)), P(24), C.amber),
      lab(x0, lb, TINSIZE, scale[1], C.dim),
      { type = "label", x = mx - P(30), y = lb - ascent(TINSIZE), w = P(60) + 1, align = CENTER, font = TINSIZE,
        text = scale[2], color = C.amber },
      lab(x0 + barW, lb, TINSIZE, scale[3], C.dim, true),
    })
  end

  -- stats row: four cells of label, value and unit
  local function statsRow(list, key, labels, arrow)
    local cells = {}
    v.stats[key] = cells
    list[#list + 1] = hline(0, statsTop, W)
    for i = 1, 4 do
      local x0 = P(24) + (i - 1) * P(200)
      if i > 1 then list[#list + 1] = vline((i - 1) * P(200) - 1, statsTop + 1, P(86)) end
      local c = { unitX = x0, unit = "", arrowX = x0, noHome = false }
      cells[i] = c
      local vb = statsTop + P(70)
      list[#list + 1] = lab(x0, statsTop + P(25), TINSIZE, labels[i], C.dim)
      c.fld = field(list, "stat", 6, x0, vb, "l", -0.03)
      list[#list + 1] = { type = "label", x = x0, y = vb - ascent(SMLSIZE), font = SMLSIZE,
        text = function() return c.unit end, color = C.dim, pos = function() return c.unitX, vb - ascent(SMLSIZE) end }
      if arrow and i == 1 then
        local ay = statsTop + P(55)
        local half = P(10) / 10
        local shape = { { 0, -9 * half }, { 7.5 * half, 8.5 * half }, { 0, 4.2 * half }, { -7.5 * half, 8.5 * half } }
        for _, tri in ipairs({ { 1, 2, 3 }, { 1, 3, 4 } }) do
          list[#list + 1] = { type = "triangle", color = C.magenta, visible = function() return c.arrow ~= nil end,
            pts = function()
              local p = K.turn(c.arrowX, ay, c.arrow or 0, shape)
              return { p[tri[1]], p[tri[2]], p[tri[3]] }
            end }
        end
        list[#list + 1] = K.sWord(S.words.nohome, x0, statsTop + P(66), function() return c.noHome end)
      end
    end
    return cells
  end

  local function dashPage()
    local dash = {}
    annunciator(dash, annY, "dash")
    gpsGroup(dash, stripH + 1 + P(38), "dashGps")
    v.dashTimer = field(dash, "timer", 7, W - P(20), stripH + 1 + P(46), "r", -0.03)
    dash[#dash + 1] = vline(P(400) - 1, instTop, statsTop - instTop)
    instrument(dash, P(24), "bat", "BATTERY", "V", "PER CELL", { "3.3", "3.5", "4.2", 0.2 / 0.9 })
    instrument(dash, P(424), "lq", "LINK QUALITY", "%", "LQ", { "0", "50", "100", 0.5 })
    statsRow(dash, "dash", { "HOME", "ALTITUDE", "SPEED", "USED" }, true)
    return dash
  end

  -- Waiting and simulator ------------------------------------------------------------------
  local function waitPage()
    local wait = {}
    annunciator(wait, annY, "wait")
    if w.sim then
      local base = P(284)
      wait[#wait + 1] = K.sWord(S.words.sim, P(28), base)
      wait[#wait + 1] = lab(P(28), base + P(43), 0, "Plug in USB and pick Joystick. The switches work as on the quads.", C.soft)
    else
      gpsGroup(wait, stripH + 1 + P(38), "waitGps")
      v.waitTimer = field(wait, "timer", 7, W - P(20), stripH + 1 + P(46), "r", -0.03)
      local base, word = P(241), S.words.wait
      wait[#wait + 1] = K.sWord(word, P(28), base)
      wait[#wait + 1] = rect(P(28) + floor(word.adv + 0.5) + P(14), base - P(43), P(20), P(44), C.cyan,
        { visible = function() return getTime() % 110 < 55 end })
      wait[#wait + 1] = lab(P(28), base + P(43), 0, "Plug in a battery. Telemetry appears once it links.", C.soft)
      statsRow(wait, "wait", { "BATTERY", "LINK", "HOME", "ALTITUDE" })
    end
    return wait
  end

  -- Nav and link lost: plan view on the left, position and stats on the right --------------
  local cx, cy, R = P(180), P(220), P(130)
  local function planView(list, lost)
    local pv = { x = cx, y = cy, outer = "", inner = "", len = 0, ux = 0, uy = 0 }
    v[lost and "lostPlan" or "navPlan"] = pv
    local face = S.patterns.plan
    local r2 = floor(R / 2 + 0.5)
    add(list, {
      -- rings, ticks and N are one pre-rendered image
      { type = "image", x = cx - floor(face.w / 2), y = cy - floor(face.h / 2), w = face.w, h = face.h, file = face.f },
      lab(cx + P(4), cy - R + P(14), TINSIZE, function() return pv.outer end, C.dim),
      lab(cx + P(4), cy - r2 - P(5), TINSIZE, function() return pv.inner end, C.dim),
    })
    -- EdgeTX 2.12.4 crashes (Emergency mode) when a line whose points come from a function is
    -- hidden before its first points: lines here have no visible function, and the boxes that
    -- hold them show and hide them instead
    local shown = function() return pv.qx ~= nil end
    -- the line home is dashed 4 on 4; LVGL dashes only level and upright lines, so the dashes
    -- are separate segments, and the ones past the quad shrink to nothing
    local dash = max(2, P(4))
    local segs = {}
    for i = 0, floor(R / (2 * dash)) do
      local a0, a1 = 2 * i * dash, 2 * i * dash + dash
      segs[#segs + 1] = { type = "line", color = C.magenta, thickness = max(1, P(1.5)),
        pts = function()
          local s, e = min(a0, pv.len), min(a1, pv.len)
          return { { floor(cx + pv.ux * s + 0.5), floor(cy + pv.uy * s + 0.5) },
                   { floor(cx + pv.ux * e + 0.5), floor(cy + pv.uy * e + 0.5) } }
        end }
    end
    add(list, {
      { type = "box", x = 0, y = 0, w = W, h = H, visible = shown, children = segs },
      { type = "circle", x = cx, y = cy, radius = P(7), filled = false, thickness = max(1, P(2)), color = C.magenta },
      { type = "circle", x = cx, y = cy, radius = max(1, P(2)), filled = true, color = C.magenta },
    })
    local marker
    if lost then
      local r, s = P(11), P(5)
      local function qx() return pv.qx or cx end
      local function qy() return pv.qy or cy end
      marker = {
        { type = "circle", x = cx, y = cy, radius = r, filled = false, thickness = max(1, P(2)), color = C.red,
          pos = function() return qx(), qy() end },
        { type = "line", color = C.red, thickness = max(1, P(2)),
          pts = function() return { { qx() - s, qy() - s }, { qx() + s, qy() + s } } end },
        { type = "line", color = C.red, thickness = max(1, P(2)),
          pts = function() return { { qx() + s, qy() - s }, { qx() - s, qy() + s } } end },
      }
    else
      local u = k
      local shape = { { 0, -12 * u }, { 8 * u, 9 * u }, { 0, 4.5 * u }, { -8 * u, 9 * u } }
      marker = {}
      for _, tri in ipairs({ { 1, 2, 3 }, { 1, 3, 4 } }) do
        marker[#marker + 1] = { type = "triangle", color = C.fg,
          pts = function()
            local p = K.turn(pv.qx or cx, pv.qy or cy, pv.hdg or 0, shape)
            return { p[tri[1]], p[tri[2]], p[tri[3]] }
          end }
      end
    end
    list[#list + 1] = { type = "box", x = 0, y = 0, w = W, h = H, visible = shown, children = marker }
    return pv
  end
  local rx, rRight = P(368), W - P(28)
  local function details(list, key, kicker, coordFont, coordBase, statTop, labels)
    local e = { cells = {}, unit = "", unitX = rx, dir = "" }
    v[key] = e
    list[#list + 1] = lab(rx, P(80), TINSIZE, kicker, C.dim)
    e.dist = field(list, "dist", 6, rx, P(178), "l", -0.05)
    add(list, {
      { type = "label", x = rx, y = P(178) - ascent(MIDSIZE), font = MIDSIZE, text = function() return e.unit end,
        color = C.dim, pos = function() return e.unitX, P(178) - ascent(MIDSIZE) end },
      lab(rRight, P(178), BOLD, function() return e.dir end, C.magenta, true),
    })
    e.coord = field(list, coordFont, 22, rx, coordBase, "l", -0.03)
    list[#list + 1] = hline(rx, P(236), rRight - rx)
    for i = 1, 6 do
      local x = rx + floor(((i - 1) % 3) * (rRight - rx + P(20)) / 3 + 0.5)
      local top = statTop + ((i > 3) and P(71) or 0)
      local c = { unitX = x, unit = "" }
      e.cells[i] = c
      list[#list + 1] = lab(x, top, TINSIZE, labels[i], C.dim)
      c.fld = field(list, "nav", 5, x, top + P(36), "l", -0.03)
      list[#list + 1] = { type = "label", x = x, y = top + P(36) - ascent(SMLSIZE), font = SMLSIZE,
        text = function() return c.unit end, color = C.dim,
        pos = function() return c.unitX, top + P(36) - ascent(SMLSIZE) end }
    end
    return e
  end

  local function navPage()
    local list = {}
    annunciator(list, P(12), "nav")
    gpsGroup(list, P(38), "navGps")
    v.navTimer = field(list, "timer", 7, W - P(20), P(46), "r", -0.03)
    planView(list, false)
    details(list, "navInfo", "FROM HOME", "c22", P(221), P(266),
      { "ALTITUDE", "SPEED", "HEADING", "BATTERY", "LINK", "USED" })
    return list
  end

  local function lostPage()
    local list = {}
    annunciator(list, P(12), "lost")
    local e = { labelX = 0 }
    v.lostHead = e
    add(list, {
      { type = "label", x = 0, y = P(46) - ascent(TINSIZE), font = TINSIZE, text = "SIGNAL LOST", color = C.dim,
        pos = function() return e.labelX, P(46) - ascent(TINSIZE) end },
      lab(W - P(20), P(46), TINSIZE, "AGO", C.dim, true),
    })
    e.timer = field(list, "timer", 7, W - P(20), P(46), "r", -0.03)
    planView(list, true)
    details(list, "lostInfo", "LAST KNOWN POSITION", "c26", P(225), P(270),
      { "MAX DIST", "MAX ALT", "TOP SPEED", "LOWEST CELL", "USED", "FLIGHT TIME" })
    return list
  end

  -- Ground pages: header with the page key ---------------------------------------------------
  local function header(list, title, right)
    add(list, {
      lab(P(24), P(37), BOLD, title, C.fg),
      hline(0, P(57), W),
    })
    if right == "key" and K.VIEW_SWITCH then
      local key = upper(K.VIEW_SWITCH)
      local hintW = textW("NEXT PAGE", TINSIZE)
      local kw = textW(key, TINSIZE) + 2 * P(8)
      local kx = W - P(24) - hintW - P(10) - kw
      add(list, {
        { type = "rectangle", x = kx, y = P(15), w = kw, h = P(26), filled = false, thickness = max(1, P(1.5)),
          rounded = max(1, P(3)), color = C.dimBorder },
        { type = "label", x = kx, y = P(28) - floor(textH(TINSIZE) / 2 + 0.5), w = kw, align = CENTER, font = TINSIZE,
          text = key, color = C.fg },
        lab(W - P(24), P(33), TINSIZE, "NEXT PAGE", C.dim, true),
      })
    end
  end

  local function findPage()
    local list = {}
    header(list, "FIND MY QUAD", "key")
    local e = { has = false, agoUnit = "", agoX = 0, quad = "", when = "", whenX = 0, dist = "", fromX = 0 }
    v.find = e
    local has = function() return e.has end
    local side, qx, qy = P(348), P(24), P(78)
    w.qrSide = side - 2 * P(16)
    add(list, {
      rect(qx, qy, side, side, QR_PAPER, { visible = has }),
      { type = "box", name = "qr", x = qx + P(16), y = qy + P(16), w = w.qrSide, h = w.qrSide, visible = has },
    })
    local x = P(404)
    list[#list + 1] = lab(x, P(90), TINSIZE, "LAST SEEN", C.dim, false, has)
    e.ago = field(list, "seen", 4, x, P(165), "l", -0.03)
    add(list, {
      { type = "label", x = x, y = P(165) - ascent(MIDSIZE), font = MIDSIZE, text = function() return e.agoUnit end,
        color = C.dim, visible = has, pos = function() return e.agoX, P(165) - ascent(MIDSIZE) end },
      lab(x, P(200), SMLSIZE, function() return e.quad end, C.fg, false, has),
      { type = "label", x = x, y = P(200) - ascent(SMLSIZE), font = SMLSIZE, text = function() return e.when end,
        color = C.soft, visible = has, pos = function() return e.whenX, P(200) - ascent(SMLSIZE) end },
      rect(x, P(222), W - P(24) - x, 1, C.line, { visible = has }),
      lab(x, P(251), TINSIZE, "POSITION", C.dim, false, has),
    })
    e.lat = field(list, "c30", 12, x, P(289), "l", -0.03)
    e.lon = field(list, "c30", 12, x, P(329), "l", -0.03)
    add(list, {
      lab(x, P(361), 0, function() return e.dist end, C.fg, false, has),
      { type = "label", x = x, y = P(361) - ascent(TINSIZE), font = TINSIZE, text = "FROM HOME", color = C.magenta,
        visible = function() return e.has and e.distKnown end,
        pos = function() return e.fromX, P(361) - ascent(TINSIZE) end },
    })
    local words, lines, line = {}, {}, ""
    for word in string.gmatch("Scan with your phone camera to open the map at this spot.", "%S+") do words[#words + 1] = word end
    for _, word in ipairs(words) do
      local try = (line == "") and word or (line .. " " .. word)
      if textW(try, SMLSIZE) > W - P(24) - x and line ~= "" then lines[#lines + 1] = line; line = word else line = try end
    end
    lines[#lines + 1] = line
    for i, text in ipairs(lines) do
      list[#list + 1] = lab(x, P(403) + (i - 1) * P(23), SMLSIZE, text, C.soft, false, has)
    end
    add(list, {
      { type = "label", x = 0, y = P(220), w = W, align = CENTER, font = DBLSIZE, text = "No saved position yet",
        color = C.fg, visible = function() return not e.has end },
      { type = "label", x = 0, y = P(220) + textH(DBLSIZE) + P(6), w = W, align = CENTER, font = SMLSIZE,
        text = "It's saved when the link drops or the quad lands with a GPS fix.", color = C.soft,
        visible = function() return not e.has end },
    })
    return list
  end

  local function summaryPage()
    local list = {}
    header(list, "FLIGHT SUMMARY")
    local e = { cells = {}, endedX = 0, ago = "", agoX = 0, landed = "", landedX = 0, dir = "", dirX = 0, pos = "" }
    v.sum = e
    add(list, {
      { type = "label", x = 0, y = P(33) - ascent(TINSIZE), font = TINSIZE, text = "ENDED", color = C.dim,
        pos = function() return e.endedX, P(33) - ascent(TINSIZE) end },
      { type = "label", x = 0, y = P(34) - ascent(SMLSIZE), font = SMLSIZE, text = function() return e.ago end,
        color = C.fg, pos = function() return e.agoX, P(34) - ascent(SMLSIZE) end },
      lab(W - P(24), P(33), TINSIZE, "AGO", C.dim, true),
    })
    local third = W / 3
    local rows = {
      { top = P(58), h = P(150), font = "big", labels = { "FLIGHT TIME", "LOWEST CELL", "USED" }, lb = P(101),
        vb = P(169), uf = 0 },
      { top = P(209), h = P(118), font = "stat", labels = { "MAX DISTANCE", "MAX ALTITUDE", "TOP SPEED" }, lb = P(248),
        vb = P(295), uf = SMLSIZE },
    }
    for r, row in ipairs(rows) do
      list[#list + 1] = hline(0, row.top + row.h, W)
      for i = 1, 3 do
        local x0 = floor((i - 1) * third + 0.5)
        if i < 3 then list[#list + 1] = vline(floor(i * third + 0.5) - 1, row.top, row.h) end
        local c = { unitX = x0, unit = "" }
        e.cells[(r - 1) * 3 + i] = c
        list[#list + 1] = lab(x0 + P(24), row.lb, TINSIZE, row.labels[i], C.dim)
        c.fld = field(list, row.font, 7, x0 + P(24), row.vb, "l", -0.04)
        list[#list + 1] = { type = "label", x = x0, y = row.vb - ascent(row.uf), font = row.uf,
          text = function() return c.unit end, color = C.dim,
          pos = function() return c.unitX, row.vb - ascent(row.uf) end }
      end
    end
    local lb = P(394)
    add(list, {
      lab(P(24), lb, TINSIZE, "LANDED", C.dim),
      { type = "label", x = 0, y = lb - ascent(0), font = 0, text = function() return e.landed end, color = C.fg,
        pos = function() return e.landedX, lb - ascent(0) end },
      { type = "label", x = 0, y = lb - ascent(SMLSIZE), font = SMLSIZE, text = function() return e.dir end,
        color = C.magenta, pos = function() return e.dirX, lb - ascent(SMLSIZE) end },
      lab(W - P(24), lb, SMLSIZE, function() return e.pos end, C.soft, true),
    })
    return list
  end

  local function logPage()
    local list = {}
    header(list, "LOGBOOK", "key")
    local e = { totals = {}, rows = {} }
    v.log = e
    for i = 1, 2 do
      local t = { x = P(24), has = false, quad = "", word = "", wordX = 0, minX = 0 }
      e.totals[i] = t
      local has = function() return t.has end
      add(list, {
        { type = "label", x = 0, y = P(93) - ascent(TINSIZE), font = TINSIZE, text = function() return t.quad end,
          color = C.soft, visible = has, pos = function() return t.x, P(93) - ascent(TINSIZE) end },
        { type = "label", x = 0, y = P(152) - ascent(0), font = 0, text = function() return t.word end, color = C.dim,
          visible = has, pos = function() return t.wordX, P(152) - ascent(0) end },
        { type = "label", x = 0, y = P(152) - ascent(SMLSIZE), font = SMLSIZE, text = "min", color = C.dim,
          visible = has, pos = function() return t.minX, P(152) - ascent(SMLSIZE) end },
      })
      t.count = field(list, "count", 4, P(24), P(152), "l", -0.03)
      t.mins = field(list, "gps", 5, P(24), P(152), "l", -0.03)
    end
    local cols = { 0, 150, 260, 350, 490, 610 }
    local heads = { "DATE", "QUAD", "TIME", "LOWEST CELL", "MAX DIST", "USED" }
    list[#list + 1] = hline(P(24), P(183), W - P(48))
    for j = 1, 6 do list[#list + 1] = lab(P(24) + P(cols[j]), P(206), TINSIZE, heads[j], C.dim) end
    local rowsFit = min(K.BOOK_RECENT, floor((H - P(32) - P(218)) / P(45)))
    for i = 1, rowsFit do
      local top = P(218) + (i - 1) * P(45)
      local r = { "", "", "", "", "", "" }
      e.rows[i] = r
      list[#list + 1] = rect(P(24), top, W - P(48), 1, C.line, { visible = function() return r[1] ~= "" end })
      for j = 1, 6 do
        list[#list + 1] = lab(P(24) + P(cols[j]), top + P(29), SMLSIZE, function() return r[j] end,
          function() return r.colors and r.colors[j] or C.fg end)
      end
    end
    list[#list + 1] = { type = "label", x = 0, y = P(260), w = W, align = CENTER, font = 0,
      text = "No flights yet. Each one is logged when the quad disarms.", color = C.soft,
      visible = function() return e.empty end }
    return list
  end
  w.lazy = { dash = dashPage, wait = waitPage, nav = navPage, lost = lostPage, find = findPage,
             summary = summaryPage, log = logPage }

  -- Footer: the radio's battery -----------------------------------------------------------------
  local foot = {}
  local fy = H - P(32)
  local base = fy + P(22)
  local voltW, pctW = textW("8.8 V", TINSIZE), textW("100%", TINSIZE)
  local xVolt = W - P(20) - voltW
  local xPct = xVolt - P(8) - pctW
  local gw, gh = P(26), P(12)
  local gx, gy = xPct - P(8) - gw, fy + floor((P(32) - gh) / 2 + 0.5)
  local fillW = P(18)
  add(foot, {
    hline(0, fy, W),
    lab(gx - P(8), base, TINSIZE, "RADIO", C.dim, true),
    { type = "rectangle", x = gx, y = gy, w = P(22), h = gh - 1, filled = false, thickness = max(1, P(1.5)),
      rounded = max(1, P(2)), color = function() return v.txLow and C.red or C.soft end },
    rect(gx + P(23), gy + P(4), max(2, P(2)), P(4), C.soft, { color = function() return v.txLow and C.red or C.soft end }),
    rect(gx + P(3), gy + P(3), fillW, gh - 2 * P(3) - 1, C.fg, {
      color = function() return v.txLow and C.red or C.fg end,
      size = function() return max(1, floor(fillW * v.txFrac + 0.5)), gh - 2 * P(3) - 1 end }),
    { type = "label", x = xPct, y = base - ascent(TINSIZE), w = pctW, align = RIGHT, font = TINSIZE,
      text = function() return v.txPct end, color = function() return v.txLow and C.red or C.fg end },
    { type = "label", x = xVolt, y = base - ascent(TINSIZE), w = voltW, align = RIGHT, font = TINSIZE,
      text = function() return v.txVolts end, color = function() return v.txLow and C.red or C.soft end },
  })
  v.txFrac, v.txPct, v.txVolts = 0, "", ""

  w.refs = lvgl.build({
    rect(0, 0, W, H, C.bg),
    { type = "box", x = 0, y = 0, w = W, h = H, children = strip,
      visible = function() return v.screen == "dash" or v.screen == "wait" end },
    { type = "box", name = "dash", x = 0, y = 0, w = W, h = H, visible = on("dash") },
    { type = "box", name = "wait", x = 0, y = 0, w = W, h = H, visible = on("wait") },
    { type = "box", name = "nav", x = 0, y = 0, w = W, h = H, visible = on("nav") },
    { type = "box", name = "lost", x = 0, y = 0, w = W, h = H, visible = on("lost") },
    { type = "box", name = "find", x = 0, y = 0, w = W, h = H, visible = on("find") },
    { type = "box", name = "summary", x = 0, y = 0, w = W, h = H, visible = on("summary") },
    { type = "box", name = "log", x = 0, y = 0, w = W, h = H, visible = on("log") },
    { type = "box", x = 0, y = 0, w = W, h = H, children = foot },
    -- failsafe and link lost: a red frame round the whole screen
    { type = "rectangle", x = 0, y = 0, w = W, h = H, filled = false, thickness = max(2, P(4)), color = C.red,
      visible = function() return v.alarm end },
  })
  w.P, w.S = P, S
end

-- Per frame -----------------------------------------------------------------------------------
-- annunciator blocks from x = 20, each as wide as its word
local function layBlocks(P, bv, list)
  local x, border = P(20), max(1, P(2))
  for i = 1, BLOCKS do
    local b = list and list[i]
    if b then
      local e = bv[i] or {}
      e.text, e.sev = b[1], b[2]
      e.x, e.w = x, textW(b[1], BOLD) + 2 * (P(12) + border)
      e.color = (b[2] == "warn") and C.bg or sevColor(b[2])
      e.border = (b[2] == "neutral") and C.dimBorder or sevColor(b[2])
      bv[i] = e
      x = x + e.w + P(10)
    else
      bv[i] = nil
    end
  end
end

-- put the quad on the plan view: `b` degrees from home, r pixels out
local function plot(pv, b, r)
  local a = math.rad(b)
  pv.qx, pv.qy = max(0, floor(pv.x + math.sin(a) * r + 0.5)), max(0, floor(pv.y - math.cos(a) * r + 0.5))
  pv.len, pv.ux, pv.uy = r, math.sin(a), -math.cos(a)
end

-- the GPS group, right to left from `right`: status, SAT, the count, GPS
local function layGps(P, g, right, count, row, status)
  local x = right - P(26)
  g.status, g.statusColor = status or "", C[row] or C.red
  if status then
    g.statusX = x - textW(status, SMLSIZE)
    x = g.statusX - P(6)
  else
    g.statusX = x
  end
  g.satX = x - textW("SAT", TINSIZE)
  x = g.satX - P(6)
  local cw = sWidth(g.count.f, count, g.count.track)
  sSet(g.count, count, row, x - cw)
  g.gpsX = x - cw - P(6) - textW("GPS", TINSIZE)
end

local function view(w, d)
  local v, P = w.v, w.P
  local gap = P(6)
  local function stat(c, value, unit, row)
    if value then
      local wd = sSet(c.fld, value, row or "fg")
      c.unit, c.unitX = unit or "", c.fld.x + wd + gap
    else
      sSet(c.fld, "~~", "mute")
      c.unit, c.unitX = "", c.fld.x
    end
  end

  v.screen = PAGE_OF[d.screen]
  v.alarm = d.failsafe or d.screen == "lost"
  v.txFrac, v.txLow = d.txFrac, d.txLow
  v.txPct, v.txVolts = string.format("%d%%", floor(d.txFrac * 100 + 0.5)), string.format("%.1f V", d.txV)

  -- switch strip
  if v.screen == "dash" or v.screen == "wait" then
    for i in ipairs(K.switches) do
      local t, tile = w.sw[i], v.sw[i]
      local text = upper(t.text)
      local f = tile.fld
      while #text > 1 and sWidth(f.f, text, f.track) > tile.room do text = string.sub(text, 1, -2) end
      sSet(f, text, SEV[t.sev] or "fg")
    end
  end

  local g, blocks, timer
  if v.screen == "dash" then
    g, blocks, timer = v.dashGps, v.blocks.dash, v.dashTimer
  elseif v.screen == "nav" then
    g, blocks, timer = v.navGps, v.blocks.nav, v.navTimer
  end
  if blocks and g then
    layBlocks(P, blocks, d.blocks)
    local tw = sSet(timer, K.clock(d.timer), "fg")
    local row = (not d.hasGps and "mute") or ((d.gps == "nofix" or d.gps == "nohome") and "red")
      or (d.gps == "few" and "amber") or "fg"
    -- no home is already a block and the HOME cell, so only a missing fix gets a word here
    local status = (d.gps == "nofix") and "NO FIX" or nil
    layGps(P, g, w.zone.w - P(20) - tw, d.hasGps and tostring(d.sats) or "~~", row, status)
  end

  if v.screen == "dash" and v.bat then
    -- battery
    local bat, lq = v.bat, v.lq
    if d.cell then
      local sev = K.cellSev(d.cell)
      local wd = sSet(bat.hero, string.format("%.2f", d.cell), SEV[sev])
      bat.unitX = bat.hero.x + wd + P(10)
      bat.frac, bat.color = max(0, min(1, (d.cell - 3.3) / 0.9)), sevColor(sev)
      bat.detail = string.format("%dS \226\128\162 %.1f V", d.cells, d.v)
    else
      local wd = sSet(bat.hero, "~~", "mute")
      bat.unitX, bat.frac, bat.detail = bat.hero.x + wd + P(10), 0, ""
    end
    local q = d.rqly or 0
    local lsev = K.lqSev(q)
    local wd = sSet(lq.hero, tostring(q), SEV[lsev])
    lq.unitX = lq.hero.x + wd + P(10)
    lq.frac, lq.color = max(0, min(1, q / 100)), sevColor(lsev)
    local sub = {}
    if d.rssi then sub[#sub + 1] = string.format("%d dBm", d.rssi) end
    if d.tpwr then sub[#sub + 1] = string.format("%d mW", d.tpwr) end
    lq.detail = table.concat(sub, " \226\128\162 ")

    -- stats
    local cells = v.stats.dash
    local home = cells[1]
    if d.armed and d.gps == "nohome" then
      sSet(home.fld, "", "fg")
      home.unit, home.noHome, home.arrow = "", true, nil
    else
      home.noHome = false
      local dv, du = K.distVU(d.dist)
      stat(home, d.dist and dv, du)
      home.arrow = d.homeRel
      home.arrowX = home.unitX + textW(home.unit, SMLSIZE) + P(6) + P(10)
    end
    stat(cells[2], d.alt and num(d.alt), "m")
    stat(cells[3], d.spd and num(d.spd), "km/h")
    stat(cells[4], (d.capa and d.capa > 0) and tostring(d.capa), "mAh")
  elseif v.screen == "wait" and v.blocks.wait then
    layBlocks(P, v.blocks.wait, w.sim and { { "SIMULATOR", "set" }, { "USB JOYSTICK", "neutral" } }
      or { { "NO TELEMETRY", "neutral" } })
    if not w.sim then
      local tw = sSet(v.waitTimer, "0:00", "mute")
      layGps(P, v.waitGps, w.zone.w - P(20) - tw, "~~", "mute")
      for _, c in ipairs(v.stats.wait) do stat(c, nil) end
    end
  elseif v.screen == "nav" and v.navInfo then
    local pv, e = v.navPlan, v.navInfo
    local outer = range(d.dist)
    pv.outer, pv.inner = rangeText(outer), rangeText(outer / 2)
    if d.dist and d.fromHome then
      plot(pv, d.fromHome, min(1, d.dist / outer) * P(130))
      pv.hdg = d.hdg or 0
      local dv, du = K.distVU(d.dist)
      local wd = sSet(e.dist, dv, "fg")
      e.unit, e.unitX = du, e.dist.x + wd + P(8)
      e.dir = K.compass(d.fromHome)
    else
      pv.qx = nil
      sSet(e.dist, "~~", "mute")
      e.unit, e.dir = "", ""
    end
    sSet(e.coord, d.pos and string.format("%.6f, %.6f", d.pos.lat, d.pos.lon) or "", "fg")
    local c = e.cells
    stat(c[1], d.alt and num(d.alt), "m")
    stat(c[2], d.spd and num(d.spd), "km/h")
    stat(c[3], d.hdg and tostring(floor(d.hdg + 0.5) % 360), "\194\176")
    stat(c[4], d.cell and string.format("%.2f", d.cell), "V", d.cell and (K.cellSev(d.cell) == "warn") and "amber" or "fg")
    stat(c[5], d.rqly and tostring(d.rqly), "%")
    stat(c[6], (d.capa and d.capa > 0) and tostring(d.capa), "mAh")
  elseif v.screen == "lost" and v.lostInfo then
    local pv, e, s = v.lostPlan, v.lostInfo, w.stats
    layBlocks(P, v.blocks.lost, { { "LINK LOST", "warn" } })
    local head = v.lostHead
    local tw = sSet(head.timer, K.clock((d.now - (w.lostAt or d.now)) / 100), "red",
      w.zone.w - P(20) - textW("AGO", TINSIZE) - P(10))
    head.labelX = head.timer.x - tw - P(10) - textW("SIGNAL LOST", TINSIZE)
    local dist = w.lastDist
    local outer = range(dist)
    pv.outer, pv.inner = rangeText(outer), rangeText(outer / 2)
    if w.home and w.last and dist then
      local b = K.bearing(w.home, w.last)
      plot(pv, b, min(1, dist / outer) * P(130))
      local dv, du = K.distVU(dist)
      local wd = sSet(e.dist, dv, "fg")
      e.unit, e.unitX, e.dir = du, e.dist.x + wd + P(8), K.compass(b)
    else
      pv.qx = nil
      sSet(e.dist, "~~", "mute")
      e.unit, e.dir = "", ""
    end
    sSet(e.coord, w.last and string.format("%.6f, %.6f", w.last.lat, w.last.lon) or "", "fg")
    local c = e.cells
    local md, mu = K.distVU(s.maxDist > 0 and s.maxDist or nil)
    stat(c[1], s.maxDist > 0 and md, mu)
    stat(c[2], s.maxAlt and num(s.maxAlt), "m")
    stat(c[3], s.maxSpd > 0 and num(s.maxSpd), "km/h")
    stat(c[4], s.minCell and string.format("%.2f", s.minCell), "V", (K.lowSev(s.minCell) == "caution") and "amber" or "fg")
    stat(c[5], (s.capa and s.capa > 0) and tostring(s.capa), "mAh")
    stat(c[6], K.clock(d.timer), "")
  elseif v.screen == "find" and v.find then
    local e, s = v.find, w.saved
    e.has = s ~= nil
    if s then
      local secs = s.epoch and (getRtcTime() - s.epoch)
      local n, unit = K.agoParts((secs and secs >= 0) and secs or 0)
      local wd = sSet(e.ago, n, "fg")
      e.agoUnit, e.agoX = unit, e.ago.x + wd + P(8)
      e.quad = s.quad or ""
      e.whenX = e.ago.x + textW(e.quad, SMLSIZE) + P(12)
      e.when = s.when
      sSet(e.lat, string.format("%.6f", s.lat), "fg")
      sSet(e.lon, string.format("%.6f", s.lon), "fg")
      e.distKnown = s.dist ~= nil
      e.dist = s.dist and (s.dist .. " m") or "Distance from home unknown"
      e.fromX = e.ago.x + textW(e.dist, 0) + P(8)
      K.syncQR(w, string.format("https://maps.google.com/?q=%.6f,%.6f", s.lat, s.lon), w.qrSide, QR_INK, QR_PAPER)
    else
      sSet(e.ago, "", "fg")
      sSet(e.lat, "", "fg")
      sSet(e.lon, "", "fg")
      K.syncQR(w, nil, w.qrSide, QR_INK, QR_PAPER)
    end
  elseif v.screen == "summary" and v.sum then
    local e, s = v.sum, w.stats
    local W = w.zone.w
    e.ago = K.clock((d.now - (w.lostAt or d.now)) / 100)
    e.agoX = W - P(24) - textW("AGO", TINSIZE) - P(10) - textW(e.ago, SMLSIZE)
    e.endedX = e.agoX - P(10) - textW("ENDED", TINSIZE)
    local c = e.cells
    local md, mu = K.distVU(s.maxDist > 0 and s.maxDist or nil)
    stat(c[1], K.clock(d.timer), "")
    stat(c[2], s.minCell and string.format("%.2f", s.minCell), "V", (K.lowSev(s.minCell) == "caution") and "amber" or "fg")
    stat(c[3], (s.capa and s.capa > 0) and tostring(s.capa), "mAh")
    stat(c[4], s.maxDist > 0 and md, mu)
    stat(c[5], s.maxAlt and num(s.maxAlt), "m")
    stat(c[6], s.maxSpd > 0 and num(s.maxSpd), "km/h")
    local x = P(24) + textW("LANDED", TINSIZE) + P(16)
    if w.home and w.last and w.lastDist then
      local dv, du = K.distVU(w.lastDist)
      e.landed, e.dir = dv .. " " .. du, K.compass(K.bearing(w.home, w.last)) .. " OF HOME"
    else
      e.landed, e.dir = "--", ""
    end
    e.landedX, e.dirX = x, x + textW(e.landed, 0) + P(14)
    e.pos = w.last and string.format("%.6f, %.6f", w.last.lat, w.last.lon) or ""
  elseif v.screen == "log" and v.log then
    local e, b = v.log, w.book
    local quads = K.topQuads(b, 2)
    local x = P(24)
    for i = 1, 2 do
      local t = e.totals[i]
      local q = quads[i] and b.totals[quads[i]]
      t.has = q ~= nil
      if q then
        t.x, t.quad = x, string.sub(quads[i], 1, 12)
        local cw = sSet(t.count, tostring(q.flights), "fg", x)
        t.word = (q.flights == 1) and "flight" or "flights"
        t.wordX = x + cw + P(8)
        local mx = t.wordX + textW(t.word, 0) + P(28)
        local mw = sSet(t.mins, tostring(floor(q.secs / 60 + 0.5)), "fg", mx)
        t.minX = mx + mw + P(8)
        x = t.minX + textW("min", SMLSIZE) + P(72)
      else
        sSet(t.count, "", "fg")
        sSet(t.mins, "", "fg")
      end
    end
    e.empty = b.recent[1] == nil
    for i, r in ipairs(e.rows) do
      local f = b.recent[i]
      if f then
        local dv, du = K.distVU(f.maxDist)
        r[1], r[2], r[3] = string.sub(f.when, 6), string.sub(f.quad, 1, 9), K.clock(f.secs)
        r[4] = f.minCell and string.format("%.2f V", f.minCell) or "--"
        r[5] = f.maxDist and (dv .. " " .. du) or "--"
        r[6] = f.lost and "LINK LOST" or (f.mah and (f.mah .. " mAh") or "--")
        r.colors = { C.soft, C.fg, C.fg, (K.lowSev(f.minCell) == "caution") and C.amber or C.fg, C.fg,
                     f.lost and C.red or C.fg }
      else
        for j = 1, 6 do r[j] = "" end
      end
    end
  end
end

return { build = build, view = view, page = function(screen) return PAGE_OF[screen] end }
