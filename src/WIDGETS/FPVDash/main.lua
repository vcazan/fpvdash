-- FPVDash - telemetry dashboard for EdgeTX colour radios (ELRS or Crossfire + Betaflight)
-- Needs EdgeTX 2.11 or later (LVGL widget API). Use it on a Full screen layout.
-- The look comes from a theme in themes/, picked in the widget's settings (long-press the
-- dashboard, Widget settings, Theme). Other settings: copy config.example.lua to config.lua.
--
-- Screens, switched automatically:
--   Waiting    - radio on, no quad seen yet ("Simulator" when no RF module is on)
--   Dashboard  - linked; battery, link, mode, GPS, home, altitude, speed, mAh
--   Link lost  - the link dropped while armed; last known position (also logged to SD) and stats
--   Summary    - the quad landed and was unplugged; the flight's numbers
-- The view switch (SH by default) steps through pages: while linked, dashboard and GPS view;
-- otherwise the screen above, then Find (last saved position as a QR code for a phone's map)
-- and Logbook.

local VERSION = "1.1.3"
local DIR = "/WIDGETS/FPVDash/"

-- the Theme setting's choices in the order EdgeTX stores them (1-based); add new ones at the end
local THEMES = { "cockpit", "hivis", "classic" }
local options = {
  { "Cells", VALUE, 0, 0, 12 },                                     -- 0 = auto-detect per pack
  { "Theme", CHOICE, 1, { "Glass Cockpit", "Hi-Vis", "Classic" } },
}

-- Defaults, overridden by /WIDGETS/FPVDash/config.lua when it exists (see config.example.lua)
local CONFIG = {
  cells = { 4, 6 },        -- pack sizes flown, for auto-detect; their 3.0-4.4 V/cell ranges must not overlap
  quadNames = {},          -- logbook name by cell count; otherwise the model name
  homeSats = 8,            -- Betaflight's gps_rescue_min_sats: fewer at arming = no home
  viewSwitch = "sh",       -- momentary switch that steps through the pages; false for none
  switches = nil,          -- switch strip; nil builds it from the model's mixer
  tabularDigits = false,   -- Hi-Vis: every digit the same width, so numbers hold still as they change
  debugLog = false,        -- writes /LOGS/fpvdash-debug.txt: page builds and switches, for crash reports
}
do
  local chunk = loadScript(DIR .. "config.lua")
  local ok, user = pcall(function() return chunk and chunk() end)
  if ok and type(user) == "table" then
    for k, v in pairs(user) do CONFIG[k] = v end
  end
end

local RESET_AFTER  = 30 * 100      -- link down > 30 s then back = new flight (10 ms ticks)
local LOG_PATH     = "/LOGS/fpvdash-lastpos.txt"     -- one line per link loss or landing
local FLIGHTS_PATH = "/LOGS/fpvdash-flights.csv"    -- every flight, appended
local BOOK_PATH    = "/LOGS/fpvdash-logbook.txt"     -- per-quad totals and the latest flights
local QUAD_FOR_CELLS = CONFIG.quadNames
local HOME_SATS    = CONFIG.homeSats
local MIN_FLIGHT   = 10            -- seconds armed before a flight goes in the logbook
local BOOK_RECENT  = 6
local PACK_CELLS   = CONFIG.cells
local VIEW_SWITCH  = CONFIG.viewSwitch or nil
local floor, max, min = math.floor, math.max, math.min
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

-- the file is closed after every line so the last one survives a radio crash
local DEBUG_PATH = "/LOGS/fpvdash-debug.txt"
local function crumb(msg)
  if not CONFIG.debugLog then return end
  local f = io.open(DEBUG_PATH, "a")
  if not f then return end
  local free = getAvailableMemory and getAvailableMemory() or -1024
  io.write(f, string.format("%d %s lua=%dK free=%dK\n", getTime(), msg, floor(collectgarbage("count")), floor(free / 1024)))
  io.close(f)
end

-- Geo & formatting --------------------------------------------------------------
local function distance(a, b)
  local r = math.rad
  local dLat, dLon = r(b.lat - a.lat), r(b.lon - a.lon)
  local h = math.sin(dLat / 2) ^ 2 + math.cos(r(a.lat)) * math.cos(r(b.lat)) * math.sin(dLon / 2) ^ 2
  return 6371000 * 2 * math.asin(min(1, math.sqrt(h)))
end

local function bearing(a, b)
  local r = math.rad
  local p1, p2, dl = r(a.lat), r(b.lat), r(b.lon - a.lon)
  local y = math.sin(dl) * math.cos(p2)
  local x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
  return (math.deg(atan2(y, x)) + 360) % 360
end

local DIRS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
local function compass(deg) return DIRS[floor(((deg % 360) + 22.5) / 45) % 8 + 1] end

local function distVU(d)
  if not d then return "--", "" end
  if d >= 1000 then return string.format("%.1f", d / 1000), "km" end
  return string.format("%d", floor(d + 0.5)), "m"
end

local function clock(s)
  s = floor(math.abs(s or 0))
  if s >= 3600 then return string.format("%d:%02d:%02d", floor(s / 3600), floor(s / 60) % 60, s % 60) end
  return string.format("%d:%02d", floor(s / 60), s % 60)
end

local function ago(secs)
  if secs < 60 then return "Just now" end
  local m = floor(secs / 60)
  if m < 60 then return m .. " min ago" end
  local h = floor(m / 60)
  if h < 48 then return h .. " h " .. (m % 60) .. " min ago" end
  return floor(h / 24) .. " days ago"
end

-- the same as a number and the words after it, for pages that set the number large
local function agoParts(secs)
  local m = floor(secs / 60)
  if m < 60 then return tostring(m), "min ago" end
  local h = floor(m / 60)
  if h < 48 then return tostring(h), "h ago" end
  return tostring(floor(h / 24)), "days ago"
end

local function hm(secs)
  local m = floor(secs / 60 + 0.5)
  return (m >= 60) and string.format("%d h %02d min", floor(m / 60), m % 60) or (m .. " min")
end

-- Severity, the same for every theme: "normal", "caution" or "warn"
local function cellSev(v) return (v and v < 3.5) and "warn" or "normal" end
local function lowSev(v) return (v and v < 3.7) and "caution" or "normal" end    -- lowest cell of a flight
local function lqSev(q) return (q and q < 50) and "warn" or "normal" end

-- Betaflight's flight mode telemetry: the name shown and how it reads
local MODES = {
  ACRO = { "ACRO", "set" }, AIR = { "AIR", "set" }, ANGL = { "ANGLE", "set" }, STAB = { "ANGLE", "set" },
  HOR = { "HORIZON", "set" }, RTH = { "RESCUE", "caution" }, WAIT = { "WAIT GPS", "caution" },
  ["!FS!"] = { "FAILSAFE", "warn" }, ["!ERR"] = { "CAN'T ARM", "warn" }, MANU = { "MANUAL", "set" },
}

-- State -----------------------------------------------------------------------
-- nil unless the value is current: EdgeTX keeps the last value after the link
-- drops, and a stale reading must not be taken for a live one
local function sensor(name)
  if getFieldInfo(name) == nil then return nil end
  if not getSourceValue then return getValue(name) end
  local v, current = getSourceValue(name)
  if current then return v end
end

local function packCells(v)
  local best, bestOff
  for _, n in ipairs(PACK_CELLS) do
    local c = v / n
    local off = (c < 3.0 and 3.0 - c) or (c > 4.4 and c - 4.4) or 0
    if not best or off < bestOff then best, bestOff = n, off end
  end
  return best or math.ceil(v / 4.35)
end

local function newStats() return { maxDist = 0, maxAlt = nil, maxSpd = 0, minCell = nil } end

local function reset(w)
  w.cells, w.home, w.last, w.lastDist, w.armedHome, w.stats = 0, nil, nil, nil, false, newStats()
  w.cellsLocked, w.flight, w.flew, w.lostArmed = false, nil, false, false
  w.altSrc = getFieldInfo("Alt") and "Alt" or "GAlt"
end

local function quadName(cells)
  if QUAD_FOR_CELLS[cells] then return QUAD_FOR_CELLS[cells] end
  local info = model.getInfo()
  if info and info.name and info.name ~= "" then return info.name end
  return ((cells or 0) > 0 and (cells .. "S")) or "QUAD"
end

local function stamp()
  local dt = getDateTime()
  return string.format("%04d-%02d-%02d %02d:%02d", dt.year, dt.mon, dt.day, dt.hour, dt.min), dt.sec
end

local function split(line)
  local fields = {}
  for x in string.gmatch(line, "[^,]+") do fields[#fields + 1] = x end
  return fields
end

-- A LOG_PATH line: "2026-09-29 18:20:05  45.500000,-73.600000  312m from home  5INCH  @1790...".
-- Older lines end after "from home".
local function parseLastPos(line)
  local lat, lon = string.match(line, "(%-?%d+%.%d+),(%-?%d+%.%d+)")
  if not lat then return nil end
  return { lat = tonumber(lat), lon = tonumber(lon), when = string.sub(line, 1, 16),
           dist = tonumber(string.match(line, "(%d+)m from home") or ""),
           quad = string.match(line, "from home  (%w+)"), epoch = tonumber(string.match(line, "@(%d+)") or "") }
end

local function saveLastPos(w)
  if not w.last then return end
  local when, sec = stamp()
  local line = string.format("%s:%02d  %.6f,%.6f  %s from home  %s  @%d", when, sec, w.last.lat, w.last.lon,
    w.lastDist and string.format("%dm", floor(w.lastDist + 0.5)) or "?", quadName(w.cells), getRtcTime())
  w.saved = parseLastPos(line)
  pcall(function()
    local f = io.open(LOG_PATH, "a")
    if not f then return end
    io.write(f, line .. "\n")
    io.close(f)
  end)
end

-- the newest line of LOG_PATH, so the find page survives a radio restart
local function loadLastPos(w)
  pcall(function()
    local info = fstat(LOG_PATH)
    local f = info and io.open(LOG_PATH, "r")
    if not f then return end
    io.seek(f, max(0, info.size - 200))
    local tail = io.read(f, 200)
    io.close(f)
    local last
    for line in string.gmatch(tail or "", "[^\n]+") do last = line end
    w.saved = last and parseLastPos(last)
  end)
end

-- Logbook. A flight is one arm to disarm (or to a link loss while armed). BOOK_PATH holds
-- "total,<quad>,<flights>,<seconds>" lines and the newest flights as "flight,<csv>", where
-- csv matches a FLIGHTS_PATH row: date, quad, seconds, lowest cell V, max distance m,
-- max altitude m, top speed km/h, mAh used, link lost (1/0); "-" when unknown.
local function parseFlight(csv)
  local f = split(csv)
  return { csv = csv, when = f[1], quad = f[2], secs = tonumber(f[3]) or 0, minCell = tonumber(f[4]),
           maxDist = tonumber(f[5]), maxAlt = tonumber(f[6]), maxSpd = tonumber(f[7]), mah = tonumber(f[8]),
           lost = f[9] == "1" }
end

local function loadBook(w)
  w.book = { totals = {}, recent = {} }
  pcall(function()
    local f = io.open(BOOK_PATH, "r")
    if not f then return end
    local text = io.read(f, 4096)
    io.close(f)
    for line in string.gmatch(text or "", "[^\n]+") do
      local kind, rest = string.match(line, "^(%a+),(.*)$")
      local t = rest and split(rest)
      if kind == "total" and #t >= 3 then
        w.book.totals[t[1]] = { flights = tonumber(t[2]) or 0, secs = tonumber(t[3]) or 0 }
      elseif kind == "flight" and #t >= 9 and #w.book.recent < BOOK_RECENT then
        w.book.recent[#w.book.recent + 1] = parseFlight(rest)
      end
    end
  end)
end

local function saveBook(w)
  local out = {}
  for quad, t in pairs(w.book.totals) do out[#out + 1] = string.format("total,%s,%d,%d", quad, t.flights, t.secs) end
  for _, r in ipairs(w.book.recent) do out[#out + 1] = "flight," .. r.csv end
  pcall(function()
    local f = io.open(BOOK_PATH, "w")
    if not f then return end
    io.write(f, table.concat(out, "\n") .. "\n")
    io.close(f)
  end)
end

-- the quads with the most flights, most first
local function topQuads(book, n)
  local quads = {}
  for quad in pairs(book.totals) do quads[#quads + 1] = quad end
  table.sort(quads, function(a, c) return book.totals[a].flights > book.totals[c].flights end)
  while #quads > n do table.remove(quads) end
  return quads
end

local function endFlight(w, lost)
  local fl = w.flight
  w.flight = nil
  if not fl then return end
  local secs = floor((getTime() - fl.start) / 100)
  if secs < MIN_FLIGHT then return end
  local function num(x, fmt) return x and (fmt and string.format(fmt, x) or tostring(floor(x + 0.5))) or "-" end
  local used = w.capaNow and w.capaNow >= fl.capa0 and (w.capaNow - fl.capa0) or nil
  -- a props-off bench test doesn't move and draws a few mAh; a hover uses hundreds
  if (fl.maxDist or 0) < 10 and (fl.maxAlt or 0) < 2 and used and used < 30 then return end
  local quad = quadName(fl.cells)
  local csv = table.concat({ (stamp()), quad, tostring(secs), num(fl.minCell, "%.2f"), num(fl.maxDist),
    num(fl.maxAlt), num(fl.maxSpd), num(used), lost and "1" or "0" }, ",")
  pcall(function()
    local new = fstat(FLIGHTS_PATH) == nil
    local f = io.open(FLIGHTS_PATH, "a")
    if not f then return end
    if new then
      io.write(f, "date,quad,seconds,lowest_cell_v,max_distance_m,max_altitude_m,top_speed_kmh,used_mah,link_lost\n")
    end
    io.write(f, csv .. "\n")
    io.close(f)
  end)
  local t = w.book.totals[quad] or { flights = 0, secs = 0 }
  t.flights, t.secs = t.flights + 1, t.secs + secs
  w.book.totals[quad] = t
  table.insert(w.book.recent, 1, parseFlight(csv))
  while #w.book.recent > BOOK_RECENT do table.remove(w.book.recent) end
  saveBook(w)
end

local function track(w)
  local d = { now = getTime() }
  d.rqly = sensor("RQly")
  d.linked = d.rqly ~= nil and d.rqly > 0

  if d.linked then
    if not w.linked and w.lostAt and d.now - w.lostAt > RESET_AFTER then w.pendingReset = true end
    w.lostAt, w.seen = nil, true
  elseif w.linked then
    w.lostAt, w.page, w.lostArmed = d.now, 0, w.armed == true
    saveLastPos(w)
    if w.armed then endFlight(w, true) end
  end
  w.linked = d.linked
  if not d.linked then return d end

  -- flight mode. While disarmed Betaflight ends it with * (ready to arm), ! (arming disabled)
  -- or ? (GPS Rescue not ready); 4.5 only ever used *. Nothing while armed. !FS! (failsafe) has
  -- no suffix either way, so it keeps the last known state. EdgeTX strings have no methods, so
  -- the string library is called directly.
  local fm = sensor("FM")
  if type(fm) == "string" and fm ~= "" then
    local last = string.sub(fm, -1)
    if fm == "!FS!" then
      d.armed, d.fm = w.armed, fm
    elseif last == "*" or last == "!" or last == "?" then
      d.armed, d.ready, d.fm = false, last, string.sub(fm, 1, -2)
    else
      d.armed, d.fm = true, fm
    end
  end

  -- a reconnect after a long gap is a new flight, unless the quad is still in the air
  if w.pendingReset and d.armed ~= nil then
    w.pendingReset = nil
    if not d.armed then
      reset(w)
      model.resetTimer(0)
    end
  end

  -- battery; the cell count follows the resting voltage until the first arm, then holds
  local v = sensor("RxBt")
  if v and v > 0.5 then
    local cells = w.options.Cells or 0
    if cells == 0 then
      if not w.cellsLocked then w.cells = packCells(v) end
      w.cellsLocked = w.cellsLocked or d.armed == true
      cells = w.cells
    end
    d.v, d.cells, d.cell = v, cells, v / cells
    if d.armed and (not w.stats.minCell or d.cell < w.stats.minCell) then w.stats.minCell = d.cell end
  end
  d.capa = sensor("Capa")
  if d.capa then w.capaNow = d.capa end
  if d.capa and d.capa > 0 then w.stats.capa = d.capa end
  d.rssi, d.tpwr = sensor("1RSS"), sensor("TPWR")

  -- GPS; home = where it armed with enough satellites (Betaflight's rescue home), else the
  -- first solid fix, for distances only
  local gps = sensor("GPS")
  local sats = sensor("Sats")
  d.hasGps, d.sats = sats ~= nil or type(gps) == "table", sats or 0
  d.fix = type(gps) == "table" and gps.lat ~= 0 and d.sats >= 5
  local alt = sensor(w.altSrc)
  d.spd, d.hdg = sensor("GSpd"), sensor("Hdg")
  if d.spd and d.spd > w.stats.maxSpd then w.stats.maxSpd = d.spd end

  if d.fix then
    local pos = { lat = gps.lat, lon = gps.lon }
    w.last, d.pos = pos, pos
    if d.armed and not w.armed and not w.armedHome and d.sats >= HOME_SATS then
      w.home, w.armedHome = { lat = pos.lat, lon = pos.lon, alt = alt or 0 }, true
    elseif w.home == nil and d.sats >= 6 then
      w.home = { lat = pos.lat, lon = pos.lon, alt = alt or 0 }
    end
    if w.home then
      d.dist = distance(w.home, pos)
      d.toHome = bearing(pos, w.home)
      d.fromHome = bearing(w.home, pos)
      w.lastDist = d.dist
      if d.dist > w.stats.maxDist then w.stats.maxDist = d.dist end
      if alt then
        d.alt = alt - w.home.alt
        if not w.stats.maxAlt or d.alt > w.stats.maxAlt then w.stats.maxAlt = d.alt end
      end
    end
  end

  local fl = w.flight
  if d.armed then
    if not fl then
      fl = { start = d.now, capa0 = d.capa or 0, cells = d.cells or w.cells, maxDist = 0, maxSpd = 0 }
      w.flight, w.flew = fl, true
    end
    if d.cell and (not fl.minCell or d.cell < fl.minCell) then fl.minCell = d.cell end
    if d.dist and d.dist > fl.maxDist then fl.maxDist = d.dist end
    if d.alt and (not fl.maxAlt or d.alt > fl.maxAlt) then fl.maxAlt = d.alt end
    if d.spd and d.spd > fl.maxSpd then fl.maxSpd = d.spd end
  elseif d.armed == false and fl then
    saveLastPos(w)
    endFlight(w, false)
  end
  if d.armed ~= nil then w.armed = d.armed end
  return d
end

-- What the numbers mean, worked out once for every theme ---------------------------------------
-- d.gps: "ok", "few" (a fix, but too few satellites for a rescue home), "nohome" (armed without a
-- rescue home) or "nofix". d.blocks: the annunciators in order, { text, severity, key }.
local function derive(w, d)
  local t = model.getTimer(0)
  d.timer = t and t.value or 0

  -- the radio's own battery against its settings, as the EdgeTX top bar shows it; smoothed so
  -- the reading doesn't flicker with load
  local g, volts = w.gs, getValue("tx-voltage") or 0
  w.txV = w.txV and (w.txV + (volts - w.txV) * 0.05) or volts
  local span = g.battMax - g.battMin
  d.txFrac = span > 0 and max(0, min(1, (w.txV - g.battMin) / span)) or 0
  d.txV, d.txLow, d.txWarn = w.txV, w.txV <= g.battWarn, d.txFrac < 0.35

  if not d.linked then
    if w.page == 1 then d.screen = "find"
    elseif w.page == 2 then d.screen = "log"
    elseif w.lostArmed then d.screen = "lost"
    elseif w.flew then d.screen = "summary"
    else d.screen = w.sim and "sim" or "waiting" end
    return
  end
  d.screen = w.navView and "nav" or "live"
  d.failsafe = d.fm == "!FS!"
  local mode = d.fm and (MODES[d.fm] or { d.fm, "set" })

  if not d.hasGps then d.gps = "none"
  elseif not d.fix then d.gps = "nofix"
  elseif d.armed and not w.armedHome then d.gps = "nohome"
  elseif d.sats < HOME_SATS then d.gps = "few"
  else d.gps = "ok" end

  local b = {}
  if d.failsafe then
    b[1], b[2] = { "FAILSAFE", "warn" }, { "ARMED", "warn" }
  else
    b[1] = d.armed and { "ARMED", "warn" } or { "DISARMED", "neutral" }
    if mode then b[#b + 1] = { mode[1], mode[2] } end
    if d.armed then
      if d.gps == "nohome" then b[#b + 1] = { "NO HOME", "caution", "nohome" } end
    else
      if d.ready == "!" then b[#b + 1] = { "CAN'T ARM", "caution", "arming" } end
      if d.ready == "?" or d.gps == "few" or d.gps == "nofix" then b[#b + 1] = { "NO RESCUE", "caution", "rescue" } end
    end
  end
  d.blocks = b

  -- the arrow home turns with the quad, so it needs a course: moving, with a heading
  if d.dist and d.dist > 5 and d.hdg and d.spd and d.spd >= 3 then d.homeRel = (d.toHome - d.hdg) % 360 end
end

-- Switches ----------------------------------------------------------------------
-- A tile is { name, function, positions (up, middle, down) }, a position being { text, severity }:
-- "home" for the first, "set" for the others, "caution" for "TEXT!", "armed" for "TEXT!!". Pots
-- show their level; the view switch names the page on screen. Built from CONFIG.switches or,
-- by default, from the model's mixer.
local SWITCHES = {}
local PAGES = { "DASH", "GPS", "FIND", "LOG" }
local SEV_OF = { bad = "armed", warn = "caution", dim = "home", faint = "home", ink = "home" }

local function position(p, first)
  if type(p) == "table" then return { p[1], SEV_OF[p[2]] or (first and "home" or "set") } end
  local text, bangs = string.match(p, "^(.-)(!*)$")
  if bangs == "!!" then return { text, "armed" } end
  if bangs == "!" then return { text, "caution" } end
  return { text, first and "home" or "set" }
end

local function configSwitches(list)
  local out = {}
  for _, e in ipairs(list) do
    if e.view then
      out[#out + 1] = { e[1], e[2] or "VIEW", view = true }
    elseif e.pot then
      out[#out + 1] = { e[1], e[2], pot = { string.lower(e[1]) } }
    else
      local ps = {}
      for i = 3, #e do ps[#ps + 1] = position(e[i], i == 3) end
      out[#out + 1] = { e[1], e[2], ps, quiet = e.quiet }
    end
  end
  return out
end

-- channels named after a Betaflight on/off mode read OFF above and ON at the bottom, where
-- those modes usually sit; any other channel shows where its switch is
local ONOFF = { BEEP = true, BEEPER = true, BUZZER = true, TURTLE = true, FLIP = true, RESCUE = true,
                ["GPS RESCUE"] = true, RTH = true, PREARM = true, BLACKBOX = true, LAUNCH = true }

-- one tile per channel driven by a switch or knob, labelled with the channel's name
local function autoSwitches()
  local out = {}
  local view = VIEW_SWITCH and string.upper(VIEW_SWITCH)
  for ch = 0, 15 do
    local mix = (model.getMixesCount(ch) or 0) > 0 and model.getMix(ch, 0)
    -- menus prefix switch names with a glyph; ASCII ranges keep the match locale-independent
    local name = mix and string.match(getSourceName(mix.source) or "", "(S[A-Z0-9]+)$")
    local knob = name and string.match(name, "^S[0-9]$")
    if name and name ~= view and (knob or string.match(name, "^S[A-Z]$") or string.match(name, "^SW[0-9]$")) then
      local output = model.getOutput(ch)
      local label = (output and output.name ~= "" and string.upper(output.name)) or ("CH" .. (ch + 1))
      if knob then
        out[#out + 1] = { name, label, pot = { mix.source } }
      else
        local ps
        if label == "ARM" then ps = { { "OFF", "home" }, { "OFF", "home" }, { "ARMED", "armed" } }
        elseif ONOFF[label] then ps = { { "OFF", "home" }, { "OFF", "home" }, { "ON", "set" } }
        else ps = { { "UP", "home" }, { "MID", "set" }, { "DOWN", "set" } } end
        out[#out + 1] = { name, label, ps, src = mix.source }
      end
    end
  end
  if view then out[#out + 1] = { view, "VIEW", view = true } end
  return out
end

local function buildSwitches(w)
  local ok, list = pcall(function()
    return CONFIG.switches and configSwitches(CONFIG.switches) or autoSwitches()
  end)
  SWITCHES = ok and list or {}
  w.sw = {}
  for i, s in ipairs(SWITCHES) do
    local src = s.src
    for _, name in ipairs(s.pot or { string.lower(s[1]) }) do
      if not src and (type(name) == "number" or getFieldInfo(name)) then src = name end
    end
    w.sw[i] = { src = src, n = s.view and 2 or (s[3] and #s[3]) or 0, level = 0, text = "--", sev = "home" }
  end
end

-- switch positions come straight from the radio, so the strip follows a flip at once
local function readSwitches(w)
  for i, s in ipairs(SWITCHES) do
    local t = w.sw[i]
    local raw = t.src and getValue(t.src)
    if s.pot then
      t.level = raw and floor((raw + 1024) * 100 / 2048 + 0.5) or 0
      t.text, t.sev = raw and (t.level .. "%") or "--", "home"
    elseif s.view then
      -- the state names the page on screen; the dot shows the button itself
      local page = w.linked and (w.navView and 2 or 1) or ((w.page == 0) and 1 or w.page + 2)
      t.pos, t.dot = page, ((raw or 0) > 0) and 2 or 1
      t.text, t.sev = PAGES[page], (page == 1) and "home" or "set"
    elseif not raw then
      t.pos, t.text, t.sev = nil, "--", "home"
    else
      local n = #s[3]
      t.pos = (n == 2) and ((raw > 0) and 2 or 1) or ((raw < -512 and 1) or (raw > 512 and 3) or 2)
      t.dot = t.pos
      t.text, t.sev = s[3][t.pos][1], s[3][t.pos][2]
    end
  end
end

-- The view switch steps through the pages: dashboard and GPS view while linked, otherwise the
-- waiting, link lost or summary screen, the find page and the logbook
local function readViewSwitch(w)
  if not VIEW_SWITCH then return end
  local down = (getValue(VIEW_SWITCH) or 0) > 0
  if down and not w.viewDown then
    if w.linked then w.navView = not w.navView else w.page = (w.page + 1) % 3 end
  end
  w.viewDown = down
end

-- the SIM model has no RF module on and is used as a USB joystick
local function isSim()
  for i = 0, 1 do
    local m = model.getModule(i)
    if m and m.Type and m.Type ~= 0 then return false end
  end
  return true
end

-- Toolkit for themes ------------------------------------------------------------
local function textW(s, f) return (lcd.sizeText(s, f)) end
local function textH(f) return select(2, lcd.sizeText("0", f)) end
-- EdgeTX draws a label from the top of its line; the baseline sits at about 0.785 of the
-- line height in every built-in font
local function ascent(f) return floor(textH(f) * 0.785 + 0.5) end

local function fit(ref, maxW, fonts)
  for _, f in ipairs(fonts) do
    if textW(ref, f) <= maxW then return f end
  end
  return fonts[#fonts]
end

-- point at `ang` radians (0 = up) and `rad` from cx,cy; triangles take unsigned points
local function pt(cx, cy, ang, rad)
  return { max(0, floor(cx + math.sin(ang) * rad + 0.5)), max(0, floor(cy - math.cos(ang) * rad + 0.5)) }
end

-- points given as { x, y } offsets from a centre, turned by deg (clockwise) and moved to cx, cy
local function turn(cx, cy, deg, pts)
  local a = math.rad(deg)
  local s, c = math.sin(a), math.cos(a)
  local out = {}
  for i, p in ipairs(pts) do
    out[i] = { max(0, floor(cx + p[1] * c - p[2] * s + 0.5)), max(0, floor(cy + p[1] * s + p[2] * c + 0.5)) }
  end
  return out
end

-- Sprite text: theme fonts are pre-rendered sheets (tools/sprites.py). A character is shown by
-- placing its font's sheet inside a clipping box one cell wide; a field has a fixed number of
-- slots and unused ones show the sheet's blank first cell. Every character of a font uses the
-- same file, so LVGL decodes each sheet once.
-- tabular: use the evenly spaced digits a font's metrics offer instead of its natural spacing
local function loadSprites(path, tabular)
  local chunk = loadScript(path)
  local fonts = chunk and chunk()
  if type(fonts) ~= "table" then return nil end
  for _, f in pairs(fonts) do
    if f.chars then
      f.idx = {}
      for i = 1, #f.chars do f.idx[string.sub(f.chars, i, i)] = i end
      if tabular and f.tadv then f.adv, f.off = f.tadv, f.toff end
    end
  end
  return fonts
end

-- whole pixels, as LVGL positions must be
local function sWidth(f, s, track)
  track = track or 0
  local w, idx, adv = 0, f.idx, f.adv
  for i = 1, #s do w = w + adv[idx[string.sub(s, i, i)] or 1] + track end
  return (#s > 0) and floor(w - track + 0.5) or 0
end

-- the objects for a field of n characters with its baseline at y, aligned "l", "r" or "c" on x
local function sText(f, n, x, y, align, track)
  local fld = { f = f, n = n, x = x, top = y - f.base, align = align or "l", track = track or 0,
                bx = {}, ix = {}, iy = {}, width = 0 }
  local objs = {}
  for i = 1, n do
    fld.bx[i], fld.ix[i], fld.iy[i] = x, 0, 0
    objs[i] = { type = "box", x = x, y = fld.top, w = f.cw, h = f.rh,
                pos = function() return fld.bx[i], fld.top end,
                children = { { type = "image", x = 0, y = 0, w = f.w, h = f.h, file = f.f,
                               pos = function() return fld.ix[i], fld.iy[i] end } } }
  end
  return objs, fld
end

-- show s in the named colour band; returns the text's width
local function sSet(fld, s, row, x)
  x = x or fld.x
  if s == fld.s and row == fld.row and x == fld.x then return fld.width end
  local f = fld.f
  fld.s, fld.row, fld.x = s, row, x
  local band = (f.rows[row] or 0) * f.span
  local width = sWidth(f, s, fld.track)
  local pen = (fld.align == "r" and x - width) or (fld.align == "c" and x - width / 2) or x
  local idx, adv, off, sx, sy = f.idx, f.adv, f.off, f.sx, f.sy
  for i = 1, fld.n do
    local k = (i <= #s) and (idx[string.sub(s, i, i)] or 1) or 1
    fld.bx[i] = floor(pen + off[k] + 0.5)
    fld.ix[i], fld.iy[i] = -sx[k], -(sy[k] + band)
    if i <= #s then pen = pen + adv[k] + fld.track end
  end
  fld.width = width
  return width
end

-- a pre-rendered word with its baseline at y, starting at x
local function sWord(word, x, y, visible)
  return { type = "image", x = floor(x + word.off + 0.5), y = y - word.base, w = word.w, h = word.h,
           file = word.f, visible = visible }
end

-- the QR code's data is fixed once built, so a new position means a new QR object
local function syncQR(w, data, side, ink, paper)
  local box = w.refs and w.refs.qr
  if data == w.qrShown or not box then return end
  box:clear()
  if data then
    box:build({ { type = "qrcode", x = 0, y = 0, w = side, h = side, data = data, color = ink, bgColor = paper } })
  end
  w.qrShown = data
end

local K = {
  VERSION = VERSION, DIR = DIR, CONFIG = CONFIG, HOME_SATS = HOME_SATS, VIEW_SWITCH = VIEW_SWITCH,
  BOOK_RECENT = BOOK_RECENT, switches = SWITCHES,
  distance = distance, bearing = bearing, compass = compass, distVU = distVU, clock = clock, ago = ago,
  agoParts = agoParts, hm = hm, topQuads = topQuads, cellSev = cellSev, lowSev = lowSev, lqSev = lqSev,
  textW = textW, textH = textH, ascent = ascent, fit = fit, pt = pt, turn = turn,
  loadSprites = loadSprites, sWidth = sWidth, sText = sText, sSet = sSet, sWord = sWord, syncQR = syncQR,
}

-- Themes ------------------------------------------------------------------------
local function showError(w, msg)
  lvgl.clear()
  w.refs = nil
  lvgl.build({
    { type = "rectangle", x = 0, y = 0, w = w.zone.w, h = w.zone.h, filled = true, color = lcd.RGB(0, 0, 0) },
    { type = "label", x = 10, y = 10, w = w.zone.w - 20, font = 0, color = lcd.RGB(255, 90, 95),
      text = "FPVDash " .. VERSION .. ": " .. tostring(msg) },
  })
end

local function loadTheme(w)
  local id = THEMES[w.options.Theme or 0] or THEMES[1]
  if id == w.themeId then return end
  w.themeId, w.theme, w.v = id, nil, {}
  local chunk = loadScript(DIR .. "themes/" .. id .. ".lua")
  if not chunk then return end
  local ok, theme = pcall(chunk, K)
  if ok and type(theme) == "table" then w.theme = theme else w.themeError = theme end
end

-- builds a page the first time it's on screen: building them all at once would take update()
-- past EdgeTX's limit of 20000 Lua instructions per call
local function showPage(w, screen)
  local name = w.theme.page and w.theme.page(screen) or screen
  local make, box = w.lazy and w.lazy[name], w.refs and w.refs[name]
  if not (make and box) then return false end
  w.lazy[name] = nil
  crumb("build " .. name)
  local refs = box:build(make())
  if refs then
    for k, r in pairs(refs) do w.refs[k] = r end
  end
  crumb("built " .. name)
  return true
end

-- Widget ------------------------------------------------------------------------
local function create(zone, opts)
  local w = { zone = zone, options = opts, linked = false, seen = false, armed = false, page = 0, v = {},
              gs = getGeneralSettings() }
  reset(w)
  loadLastPos(w)
  loadBook(w)
  crumb("create " .. VERSION)
  return w
end

local function update(w, opts)
  w.options = opts
  loadTheme(w)
  crumb("update " .. tostring(w.themeId))
  buildSwitches(w)
  K.switches = SWITCHES
  w.sim = isSim()
  w.refs, w.lazy, w.qrShown = nil, nil, nil
  lvgl.clear()
  if not w.theme then
    showError(w, w.themeError or ("theme missing: " .. DIR .. "themes/" .. tostring(w.themeId) .. ".lua"))
    return
  end
  local ok, err = pcall(w.theme.build, w)
  if not ok then showError(w, err) end
  crumb(ok and "update done" or ("update error " .. tostring(err)))
end

local function refresh(w)
  readViewSwitch(w)
  readSwitches(w)
  local d = track(w)
  derive(w, d)
  w.d = d
  if CONFIG.debugLog then
    if d.screen ~= w.dbgScreen then
      crumb("screen " .. tostring(w.dbgScreen) .. " > " .. d.screen)
      w.dbgScreen, w.dbgFrames = d.screen, 3
    elseif (w.dbgFrames or 0) > 0 then
      crumb("frame " .. (4 - w.dbgFrames) .. " " .. d.screen)
      w.dbgFrames = w.dbgFrames - 1
    end
  end
  if not (w.theme and w.refs) then return end
  -- a page built in this call appears in the next one, filled in: building and showing it in
  -- the same call would come close to the instruction limit
  if showPage(w, d.screen) then return end
  w.theme.view(w, d)
end

-- EdgeTX only calls refresh while the widget is on screen
local function background(w) track(w) end

return { name = "FPVDash", options = options, create = create, update = update, refresh = refresh,
  background = background, useLvgl = true }
