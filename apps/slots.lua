-- slots.lua - Einarmiger Bandit fuer PocketOS
--
-- Installation: nach /apps/slots.lua kopieren (oder per App Store).
-- Gespielt wird mit virtuellen Credits, sie werden auf dem Geraet gespeichert.
-- Mit Speaker-Upgrade gibt es Soundeffekte.
--
-- Bedienung: SPIN / Leertaste / Enter = drehen, +/- = Einsatz,
--            T = Gewinntabelle, Backspace = zurueck

if not term.isColour() then
  print("Der Einarmige Bandit braucht einen")
  print("Advanced Pocket Computer (Farbe).")
  print("Taste druecken...")
  os.pullEvent("key")
  return
end

settings.define("pos.slots.credits", { description = "Bandit: Credits", default = 100, type = "number" })
settings.define("pos.slots.best", { description = "Bandit: hoechster Gewinn", default = 0, type = "number" })
settings.define("pos.slots.bet", { description = "Bandit: Einsatz-Stufe", default = 1, type = "number" })
settings.define("pos.slots.sound", { description = "Bandit: Ton an", default = true, type = "boolean" })

local W, H = term.getSize()
local START_CREDITS = 100
local BETS = { 1, 2, 5, 10, 25, 50, 100 }
local HEART = 1 -- Index des Herz-Symbols (2 Herzen = 3x Einsatz)

-- weight = Haeufigkeit auf der Walze, pay = Faktor fuer 3 gleiche
-- Auszahlungsquote ca. 91 %, etwa jeder 5. Dreh gewinnt.
local SYMBOLS = {
  { name = "Herz", char = "\3", fg = colors.red, bg = colors.white, weight = 8, pay = 5 },
  { name = "Pik", char = "\6", fg = colors.black, bg = colors.white, weight = 7, pay = 10 },
  { name = "Sonne", char = "\15", fg = colors.orange, bg = colors.white, weight = 5, pay = 15 },
  { name = "Klee", char = "\5", fg = colors.green, bg = colors.white, weight = 4, pay = 25 },
  { name = "Diamant", char = "\4", fg = colors.cyan, bg = colors.white, weight = 3, pay = 50 },
  { name = "Sieben", char = "7", fg = colors.purple, bg = colors.white, weight = 2, pay = 100 },
  { name = "Jackpot", char = "$", fg = colors.black, bg = colors.yellow, weight = 1, pay = 250 },
}

------------------------------------------------------------------------
-- Zustand
------------------------------------------------------------------------
local credits = settings.get("pos.slots.credits")
local best = settings.get("pos.slots.best")
local betIndex = math.max(1, math.min(#BETS, settings.get("pos.slots.bet")))
local sound = settings.get("pos.slots.sound")
local speaker = peripheral.find("speaker")

local message, messageColor = "Viel Glueck!", colors.lightGray
local highlight = false
local quit = false

local function save()
  settings.set("pos.slots.credits", credits)
  settings.set("pos.slots.best", best)
  settings.set("pos.slots.bet", betIndex)
  settings.set("pos.slots.sound", sound)
  settings.save()
end

-- Walzen: jedes Symbol so oft wie sein Gewicht, dann gemischt
local strips = {}
for r = 1, 3 do
  local strip = {}
  for i, s in ipairs(SYMBOLS) do
    for _ = 1, s.weight do strip[#strip + 1] = i end
  end
  for i = #strip, 2, -1 do
    local j = math.random(i)
    strip[i], strip[j] = strip[j], strip[i]
  end
  strips[r] = strip
end
local pos = { math.random(#strips[1]), math.random(#strips[2]), math.random(#strips[3]) }

local function wrap(r, i)
  local n = #strips[r]
  return ((i - 1) % n) + 1
end

------------------------------------------------------------------------
-- Ton
------------------------------------------------------------------------
local function note(instrument, pitch, volume)
  if sound and speaker then
    pcall(speaker.playNote, instrument, volume or 1, pitch)
  end
end

local function wait(seconds)
  local t = os.startTimer(seconds)
  while true do
    local e, p = os.pullEventRaw()
    if e == "terminate" then
      quit = true
      return
    end
    if e == "timer" and p == t then return end
  end
end

------------------------------------------------------------------------
-- Zeichnen
------------------------------------------------------------------------
local buttons = {}

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
  term.setTextColor(fg)
  term.setBackgroundColor(bg)
  term.write(s)
end

local function center(y, s, fg, bg)
  put(math.floor((W - #s) / 2) + 1, y, s, fg, bg)
end

local function button(id, x, y, w, h, label, bg, fg)
  fill(x, y, w, h, bg)
  label = label:sub(1, w)
  put(x + math.floor((w - #label) / 2), y + math.floor((h - 1) / 2), label, fg, bg)
  buttons[#buttons + 1] = { id = id, x = x, y = y, w = w, h = h }
end

local function hit(mx, my)
  for _, b in ipairs(buttons) do
    if mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h then return b.id end
  end
end

local REEL_X = { 3, 11, 19 }
local REEL_W = 6
local REEL_TOP = 5

-- mode: "dim" (oben/unten), "line" (Gewinnlinie), "win" (Gewinn)
local function drawCell(x, y, symIndex, mode)
  local s = SYMBOLS[symIndex]
  local bg = s.bg
  if mode == "dim" then bg = colors.lightGray elseif mode == "win" then bg = colors.lime end
  fill(x, y, REEL_W, 3, bg)
  put(x + 2, y + 1, s.char .. s.char, s.fg, bg)
end

local function drawReels()
  for r = 1, 3 do
    local x = REEL_X[r]
    drawCell(x, REEL_TOP, strips[r][wrap(r, pos[r] - 1)], "dim")
    drawCell(x, REEL_TOP + 3, strips[r][pos[r]], highlight and "win" or "line")
    drawCell(x, REEL_TOP + 6, strips[r][wrap(r, pos[r] + 1)], "dim")
  end
end

local function bet() return BETS[betIndex] end

local function drawInfo()
  fill(1, 3, W, 1, colors.black)
  put(2, 3, "Credits: " .. credits, colors.yellow, colors.black)
  local b = "Beste: " .. best
  put(W - #b, 3, b, colors.lightGray, colors.black)
  fill(1, 15, W, 1, colors.black)
  center(15, message:sub(1, W), messageColor, colors.black)
end

local function drawAll()
  buttons = {}
  term.setBackgroundColor(colors.black)
  term.clear()

  fill(1, 1, W, 1, colors.red)
  put(2, 1, "Einarmiger Bandit", colors.white, colors.red)
  local t = textutils.formatTime(os.time(), true)
  put(W - #t, 1, t, colors.white, colors.red)

  -- Automat
  fill(1, 4, W, 11, colors.gray)
  put(1, REEL_TOP + 4, ">", colors.yellow, colors.gray)
  put(W, REEL_TOP + 4, "<", colors.yellow, colors.gray)
  drawReels()
  drawInfo()

  -- Einsatz
  button("minus", 2, 16, 3, 1, "-", colors.lightGray, colors.black)
  center(16, "Einsatz: " .. bet(), colors.white, colors.black)
  button("plus", W - 3, 16, 3, 1, "+", colors.lightGray, colors.black)

  if credits >= BETS[1] then
    button("spin", 2, 17, W - 2, 2, "SPIN", colors.green, colors.white)
  else
    button("refill", 2, 17, W - 2, 2, "Nachfuellen +" .. START_CREDITS, colors.orange, colors.white)
  end

  fill(1, H, W, 1, colors.red)
  button("back", 1, H, 10, 1, "\27 Zurueck", colors.red, colors.white)
  button("table", 12, H, 8, 1, "Tabelle", colors.red, colors.white)
  button("sound", W - 5, H, 6, 1, sound and "Ton:an" or "Ton:0", colors.red, colors.white)
end

local function drawPaytable()
  term.setBackgroundColor(colors.black)
  term.clear()
  fill(1, 1, W, 1, colors.red)
  put(2, 1, "Gewinntabelle", colors.white, colors.red)
  put(2, 3, "3 gleiche auf der Linie:", colors.lightGray, colors.black)
  for i, s in ipairs(SYMBOLS) do
    local y = 4 + i
    fill(3, y, 4, 1, s.bg)
    put(4, y, s.char .. s.char, s.fg, s.bg)
    put(9, y, s.name, colors.white, colors.black)
    local p = s.pay .. "x"
    put(W - #p - 1, y, p, colors.yellow, colors.black)
  end
  local y = 5 + #SYMBOLS + 1
  fill(3, y, 4, 1, SYMBOLS[HEART].bg)
  put(4, y, SYMBOLS[HEART].char .. SYMBOLS[HEART].char, SYMBOLS[HEART].fg, SYMBOLS[HEART].bg)
  put(9, y, "2 Herzen", colors.white, colors.black)
  put(W - 3, y, "3x", colors.yellow, colors.black)
  put(2, y + 2, "Faktor mal Einsatz.", colors.lightGray, colors.black)
  center(H, "Tippen = zurueck", colors.lightGray, colors.black)
  repeat
    local e = os.pullEventRaw()
    if e == "terminate" then quit = true end
  until e == "mouse_click" or e == "key" or e == "terminate"
end

------------------------------------------------------------------------
-- Spiel
------------------------------------------------------------------------
local function fitBet()
  while betIndex > 1 and BETS[betIndex] > credits do betIndex = betIndex - 1 end
end

local function evaluate()
  local a, b, c = strips[1][pos[1]], strips[2][pos[2]], strips[3][pos[3]]
  if a == b and b == c then
    return SYMBOLS[a].pay * bet(), "3x " .. SYMBOLS[a].name, SYMBOLS[a].pay >= 100
  end
  local hearts = (a == HEART and 1 or 0) + (b == HEART and 1 or 0) + (c == HEART and 1 or 0)
  if hearts >= 2 then return 3 * bet(), "2 Herzen", false end
  return 0
end

local function celebrate(big)
  local melody = big and { 12, 16, 19, 24, 19, 24 } or { 12, 16, 19, 24 }
  for i, p in ipairs(melody) do
    note("bell", p)
    if big then
      highlight = i % 2 == 1
      drawReels()
    end
    if not quit then wait(0.12) end
  end
  highlight = true
  drawReels()
end

local function spin()
  if credits < bet() then return end
  credits = credits - bet()
  save()
  highlight = false
  message, messageColor = "", colors.lightGray
  drawInfo()

  -- Ergebnis steht vorher fest, die Animation laeuft darauf zu
  local target = { math.random(#strips[1]), math.random(#strips[2]), math.random(#strips[3]) }
  local stopAt = { 12, 18, 24 }
  for t = 1, stopAt[3] do
    for r = 1, 3 do
      if t <= stopAt[r] then pos[r] = wrap(r, target[r] - (stopAt[r] - t)) end
      if t == stopAt[r] then note("basedrum", 8, 1.5) end
    end
    if quit then break end
    drawReels()
    note("hat", 12, 0.4)
    wait(t > stopAt[3] - 4 and 0.1 or 0.05)
  end
  for r = 1, 3 do pos[r] = target[r] end
  drawReels()

  local win, what, big = evaluate()
  if win > 0 then
    credits = credits + win
    if win > best then best = win end
    message, messageColor = ("+%d  (%s)"):format(win, what), colors.lime
    save()
    drawInfo()
    if not quit then celebrate(big) end
  else
    message, messageColor = "Leider nichts", colors.lightGray
    note("didgeridoo", 6, 0.6)
  end
  fitBet()
  save()
end

------------------------------------------------------------------------
-- Hauptschleife
------------------------------------------------------------------------
fitBet()
drawAll()
local clock = os.startTimer(10)

while not quit do
  local ev = { os.pullEventRaw() }
  local e = ev[1]
  local action

  if e == "terminate" then
    break
  elseif e == "mouse_click" then
    action = hit(ev[3], ev[4])
  elseif e == "char" then
    local c = ev[2]
    if c == " " then action = "spin"
    elseif c == "+" or c == "=" then action = "plus"
    elseif c == "-" then action = "minus"
    elseif c == "t" or c == "T" then action = "table"
    end
  elseif e == "key" then
    if ev[2] == keys.enter then action = "spin"
    elseif ev[2] == keys.backspace then action = "back"
    end
  elseif e == "timer" and ev[2] == clock then
    clock = os.startTimer(10)
    drawAll() -- Uhrzeit aktualisieren
  end

  if action == "back" then
    break
  elseif action == "spin" then
    if credits >= BETS[1] then spin() end
  elseif action == "refill" then
    if credits < BETS[1] then
      credits = START_CREDITS
      message, messageColor = "Credits aufgefuellt", colors.orange
      save()
    end
  elseif action == "plus" then
    if betIndex < #BETS and BETS[betIndex + 1] <= credits then betIndex = betIndex + 1 end
    save()
  elseif action == "minus" then
    if betIndex > 1 then betIndex = betIndex - 1 end
    save()
  elseif action == "sound" then
    sound = not sound
    save()
  elseif action == "table" then
    drawPaytable()
  end

  if action then drawAll() end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
