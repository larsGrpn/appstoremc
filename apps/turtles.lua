-- turtles.lua - Turtle-Monitor fuer PocketOS
--
-- Zeigt den Status aller Turtles mit TurtleOS 1.1+, die ein Ender- oder
-- Wireless-Modem ausgeruestet haben. Laufende Auftraege lassen sich aus
-- der Ferne abbrechen.
--
-- Installation: nach /apps/turtles.lua kopieren (oder per App Store).
-- Braucht: Pocket Computer mit Ender Modem (oder Wireless Modem).

local STATUS_PROTOCOL = "tos_status"
local CMD_PROTOCOL = "tos_cmd"
local OFFLINE_AFTER = 10 -- Sekunden ohne Meldung -> "offline"

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then
  printError("Kein Ender- oder Wireless-Modem gefunden.")
  print("Der Pocket Computer braucht ein Modem-Upgrade.")
  print("Taste druecken...")
  os.pullEvent("key")
  return
end
rednet.open(peripheral.getName(modem))

local W, H = term.getSize()
local COLOR = term.isColour()
local C
if COLOR then
  C = {
    bg = colors.black, fg = colors.white, dim = colors.lightGray,
    bar = colors.blue, barFg = colors.white,
    sel = colors.gray, btn = colors.gray, btnFg = colors.white,
    stop = colors.red, stopFg = colors.white,
    ok = colors.lime, warn = colors.orange, err = colors.red, info = colors.lightBlue,
  }
else
  C = {
    bg = colors.black, fg = colors.white, dim = colors.white,
    bar = colors.white, barFg = colors.black,
    sel = colors.black, btn = colors.white, btnFg = colors.black,
    stop = colors.white, stopFg = colors.black,
    ok = colors.white, warn = colors.white, err = colors.white, info = colors.white,
  }
end

local STATES = {
  running = { "Graebt", "warn" },
  idle = { "Bereit", "info" },
  done = { "Fertig", "ok" },
  stopped = { "Gestoppt", "err" },
  offline = { "Offline", "dim" },
}

local turtles = {} -- [id] = { data = {...}, seen = os.clock() }
local buttons = {}

------------------------------------------------------------------------
-- Zeichnen
------------------------------------------------------------------------
local function fill(x, y, w, h, bg)
  term.setBackgroundColor(bg)
  local line = (" "):rep(w)
  for i = 0, h - 1 do
    term.setCursorPos(x, y + i)
    term.write(line)
  end
end

local function put(x, y, s, fg, bg)
  term.setCursorPos(x, y)
  term.setTextColor(fg or C.fg)
  term.setBackgroundColor(bg or C.bg)
  term.write(s)
end

local function fit(s, n)
  s = tostring(s)
  if #s <= n then return s end
  return s:sub(1, n - 2) .. ".."
end

local function button(id, x, y, w, h, label, bg, fg)
  fill(x, y, w, h, bg)
  label = fit(label, w)
  put(x + math.floor((w - #label) / 2), y + math.floor((h - 1) / 2), label, fg, bg)
  buttons[#buttons + 1] = { id = id, x = x, y = y, w = w, h = h }
end

local function hit(mx, my)
  for _, b in ipairs(buttons) do
    if mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h then
      return b.id
    end
  end
end

local function header(title)
  buttons = {}
  term.setBackgroundColor(C.bg)
  term.clear()
  fill(1, 1, W, 1, C.bar)
  put(2, 1, fit(title, W - 8), C.barFg, C.bar)
  local t = textutils.formatTime(os.time(), true)
  put(W - #t, 1, t, C.barFg, C.bar)
end

------------------------------------------------------------------------
-- Daten
------------------------------------------------------------------------
local function stateOf(t)
  if os.clock() - t.seen > OFFLINE_AFTER then return "offline" end
  return t.data.state or "idle"
end

local function nameOf(id, t)
  return t.data.label or ("Turtle #" .. id)
end

local function sortedIds()
  local ids = {}
  for id in pairs(turtles) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

local function fuelText(d)
  if d.fuel == "unlimited" then return "unbegrenzt" end
  if type(d.fuel) ~= "number" then return "?" end
  if type(d.fuelLimit) == "number" and d.fuelLimit > 0 then
    return d.fuel .. " (" .. math.floor(d.fuel / d.fuelLimit * 100) .. "%)"
  end
  return tostring(d.fuel)
end

local function ping()
  rednet.broadcast({ cmd = "ping" }, CMD_PROTOCOL)
end

------------------------------------------------------------------------
-- Ansichten
------------------------------------------------------------------------
local view, current, scroll, notice = "list", nil, 0, ""
local confirmUntil = 0

local ROWS_PER = 4
local listTop = 3
local perView = math.max(1, math.floor((H - 1 - listTop) / ROWS_PER))

local function drawList()
  local ids = sortedIds()
  header("Turtles (" .. #ids .. ")")
  if #ids == 0 then
    put(2, 4, "Noch keine Turtle", C.dim)
    put(2, 5, "gemeldet...", C.dim)
    put(2, 7, fit("Turtle braucht TurtleOS", W - 2), C.dim)
    put(2, 8, fit("1.1 und ein Ender Modem.", W - 2), C.dim)
  end
  scroll = math.max(0, math.min(scroll, #ids - perView))
  for i = 1, perView do
    local id = ids[scroll + i]
    if not id then break end
    local t = turtles[id]
    local d = t.data
    local y = listTop + (i - 1) * ROWS_PER
    local st = STATES[stateOf(t)] or { stateOf(t), "fg" }
    put(2, y, fit(nameOf(id, t), W - 12), C.fg)
    put(W - #st[1], y, st[1], C[st[2]])
    local line2 = d.state == "running" and (d.status or "") or (d.result ~= "" and d.result or "-")
    put(2, y + 1, fit(line2, W - 2), C.dim)
    put(2, y + 2, fit("Fuel " .. fuelText(d) .. "  Frei " .. tostring(d.free or "?"), W - 2), C.dim)
    buttons[#buttons + 1] = { id = id, x = 1, y = y, w = W, h = ROWS_PER - 1 }
  end
  if scroll > 0 then put(W, listTop, "\30", C.dim) end
  if scroll + perView < #ids then put(W, H - 2, "\31", C.dim) end

  fill(1, H, W, 1, C.bar)
  button("exit", 1, H, 9, 1, "Beenden", C.bar, C.barFg)
  button("ping", W - 9, H, 10, 1, "Aktual.", C.bar, C.barFg)
end

local function row(y, label, value, color)
  put(2, y, label, C.dim)
  put(11, y, fit(tostring(value), W - 11), color or C.fg)
end

local function drawDetail()
  local t = turtles[current]
  if not t then
    view = "list"
    return drawList()
  end
  local d = t.data
  local stateKey = stateOf(t)
  local st = STATES[stateKey] or { stateKey, "fg" }
  header(nameOf(current, t))

  row(3, "Zustand:", st[1], C[st[2]])
  row(4, "ID:", current)
  if d.state == "running" then
    row(5, "Status:", d.status or "-")
  elseif d.result and d.result ~= "" then
    row(5, "Ergebnis:", d.result)
  end

  if d.length then
    row(7, "Feld:", ("%dx%d, %s"):format(d.length, d.width,
      d.depth > 0 and (d.depth .. " tief") or "bis Grund"))
    row(8, "Ebene:", tostring(d.layer or "?") .. (d.depth > 0 and (" / " .. d.depth) or ""))
    row(9, "Position:", ("%d/%d, %d tief"):format(d.x or 0, d.y or 0, d.z or 0))
    row(10, "Bloecke:", d.blocks or 0)
  end
  row(11, "Fuel:", fuelText(d))
  row(12, "Frei:", tostring(d.free or "?") .. " Slots")

  if d.depth and d.depth > 0 and d.layer then
    local frac = math.max(0, math.min(1, (d.layer - 3) / d.depth)) -- grob: fertige Durchgaenge
    if d.state == "done" then frac = 1 end
    local barW = W - 8
    local filled = math.floor(frac * barW + 0.5)
    put(2, 14, ("="):rep(filled) .. ("-"):rep(barW - filled), C.fg)
    put(W - 4, 14, math.floor(frac * 100) .. "%", C.dim)
  end

  put(2, 15, fit("Letzte Meldung vor " .. math.floor(os.clock() - t.seen) .. " s", W - 2), C.dim)
  if notice ~= "" then put(2, 16, fit(notice, W - 2), C.warn) end

  if d.state == "running" and stateKey ~= "offline" then
    local label = os.clock() < confirmUntil and "Wirklich abbrechen?" or "Abbrechen"
    button("abort", 2, 17, W - 2, 2, label, C.stop, C.stopFg)
  end

  fill(1, H, W, 1, C.bar)
  button("back", 1, H, 10, 1, "\27 Zurueck", C.bar, C.barFg)
end

local function draw()
  if view == "list" then drawList() else drawDetail() end
end

------------------------------------------------------------------------
-- Hauptschleife
------------------------------------------------------------------------
ping()
local timer = os.startTimer(1)
draw()

while true do
  local ev = { os.pullEventRaw() }
  local e = ev[1]
  local redraw = false

  if e == "terminate" then
    break
  elseif e == "rednet_message" and ev[4] == STATUS_PROTOCOL and type(ev[3]) == "table" then
    turtles[ev[2]] = { data = ev[3], seen = os.clock() }
    redraw = true
  elseif e == "timer" and ev[2] == timer then
    timer = os.startTimer(1)
    redraw = true
  elseif e == "mouse_click" then
    local id = hit(ev[3], ev[4])
    if view == "list" then
      if id == "exit" then
        break
      elseif id == "ping" then
        ping()
      elseif type(id) == "number" then
        view, current, notice, confirmUntil = "detail", id, "", 0
      end
    else
      if id == "back" then
        view = "list"
      elseif id == "abort" then
        if os.clock() < confirmUntil then
          rednet.send(current, { cmd = "abort" }, CMD_PROTOCOL)
          notice, confirmUntil = "Abbruch gesendet", 0
        else
          confirmUntil = os.clock() + 3
        end
      end
    end
    redraw = true
  elseif e == "mouse_scroll" and view == "list" then
    scroll = scroll + ev[2]
    redraw = true
  elseif e == "key" then
    local k = ev[2]
    if view == "detail" and k == keys.backspace then
      view = "list"
    elseif view == "list" and k == keys.backspace then
      break
    elseif view == "list" and k == keys.down then
      scroll = scroll + 1
    elseif view == "list" and k == keys.up then
      scroll = scroll - 1
    end
    redraw = true
  elseif e == "term_resize" then
    W, H = term.getSize()
    redraw = true
  end

  if redraw then draw() end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
