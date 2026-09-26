-- roulette.lua - Roulette fuer PocketOS
--
-- Installation: nach /apps/roulette.lua kopieren (oder per App Store).
-- Gespielt wird mit virtuellen Credits, sie werden auf dem Geraet gespeichert.
-- Mit Speaker-Upgrade gibt es Soundeffekte.
--
-- Regeln: Europaeisches Roulette (eine Null). Zahl zahlt 35:1,
--         Dutzend 2:1, Rot/Schwarz, Gerade/Ungerade, 1-18/19-36 zahlen 1:1.
--         Bei Null verlieren alle einfachen Chancen.
--
-- Bedienung: Feld antippen = Chip setzen, Rechtsklick = Chip wegnehmen
--            DREHEN / Leertaste / Enter = drehen, +/- = Chipwert
--            C = Tisch leeren, W = letzte Einsaetze wiederholen
--            R = Regeln, Backspace = zurueck (Einsaetze gibt es zurueck)

if not term.isColour() then
  print("Roulette braucht einen")
  print("Advanced Pocket Computer (Farbe).")
  print("Taste druecken...")
  os.pullEvent("key")
  return
end

settings.define("pos.roulette.credits", { description = "Roulette: Credits", default = 100, type = "number" })
settings.define("pos.roulette.best", { description = "Roulette: hoechster Gewinn", default = 0, type = "number" })
settings.define("pos.roulette.chip", { description = "Roulette: Chip-Stufe", default = 1, type = "number" })
settings.define("pos.roulette.sound", { description = "Roulette: Ton an", default = true, type = "boolean" })

local W, H = term.getSize()
local START_CREDITS = 100
local CHIPS = { 1, 5, 10, 25, 50, 100 }
local HISTORY = 7 -- so viele letzte Zahlen werden angezeigt
local SPIN_ROUNDS = 2 -- volle Umdrehungen der Anzeige vor dem Auslaufen
local SPIN_FAST = 0.05 -- Sekunden pro Feld am Anfang
local SPIN_SLOW = 0.25 -- zusaetzliche Sekunden pro Feld am Ende

-- Reihenfolge der Zahlen auf dem europaeischen Kessel
local WHEEL = {
  0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11, 30, 8, 23, 10,
  5, 24, 16, 33, 1, 20, 14, 31, 9, 22, 18, 29, 7, 28, 12, 35, 3, 26,
}
local RED = {}
for _, n in ipairs({ 1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36 }) do
  RED[n] = true
end

local FELT = colors.green

------------------------------------------------------------------------
-- Zustand
------------------------------------------------------------------------
local credits = settings.get("pos.roulette.credits")
local best = settings.get("pos.roulette.best")
local chipIndex = math.max(1, math.min(#CHIPS, settings.get("pos.roulette.chip")))
local sound = settings.get("pos.roulette.sound")
local speaker = peripheral.find("speaker")

local bets = {} -- Feld-ID -> gesetzte Credits
local lastBets = {}
local history = {}
local lastResult -- zuletzt gefallene Zahl (wird im Tableau markiert)
local wheelPos = math.random(#WHEEL)
local spinning = false

local message, messageColor = "Chips setzen", colors.lightGray
local quit = false

local function save()
  settings.set("pos.roulette.credits", credits)
  settings.set("pos.roulette.best", best)
  settings.set("pos.roulette.chip", chipIndex)
  settings.set("pos.roulette.sound", sound)
  settings.save()
end

local function chip() return CHIPS[chipIndex] end

local function total(t)
  local sum = 0
  for _, v in pairs(t) do sum = sum + v end
  return sum
end

local function numColor(n)
  if n == 0 then return colors.green end
  return RED[n] and colors.red or colors.black
end

-- Faktor, mit dem ein Feld bei Zahl n gewinnt (0 = verloren)
local function payFactor(id, n)
  local num = id:match("^n(%d+)$")
  if num then return tonumber(num) == n and 35 or 0 end
  local doz = id:match("^doz(%d)$")
  if doz then return (n > 0 and math.ceil(n / 12) == tonumber(doz)) and 2 or 0 end
  if n == 0 then return 0 end
  local win = (id == "low" and n <= 18) or (id == "high" and n >= 19)
    or (id == "even" and n % 2 == 0) or (id == "odd" and n % 2 == 1)
    or (id == "red" and RED[n]) or (id == "black" and not RED[n])
  return win and 1 or 0
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

local function melody(instrument, pitches, delay)
  for _, p in ipairs(pitches) do
    if quit then return end
    note(instrument, p)
    wait(delay)
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

local function button(id, x, y, w, h, label, bg, fg, disabled)
  if disabled then bg, fg = colors.gray, colors.lightGray end
  fill(x, y, w, h, bg)
  label = label:sub(1, w)
  put(x + math.floor((w - #label) / 2), y + math.floor((h - 1) / 2), label, fg, bg)
  if not disabled then
    buttons[#buttons + 1] = { id = id, x = x, y = y, w = w, h = h }
  end
end

local function hit(mx, my)
  for _, b in ipairs(buttons) do
    if mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h then return b.id end
  end
end

-- Kessel-Ausschnitt: 7 Felder, das mittlere unter dem Zeiger
local STRIP_Y = 4
local function drawStrip()
  local x0 = math.floor((W - 21) / 2) + 1
  fill(1, STRIP_Y - 1, W, 2, colors.black)
  put(x0 + 10, STRIP_Y - 1, "v", colors.yellow, colors.black)
  for k = -3, 3 do
    local n = WHEEL[(wheelPos - 1 + k) % #WHEEL + 1]
    local s = #tostring(n) == 1 and " " .. n .. " " or " " .. n
    local fg = k == 0 and colors.yellow or colors.white
    put(x0 + (k + 3) * 3, STRIP_Y, s, fg, numColor(n))
  end
end

-- Tableau: Null links, 12 Spalten zu je 3 Zahlen, darunter Aussenfelder
local GRID_Y = 7
local GX = math.floor((W - 26) / 2) + 1

local function cellColors(id, bg, fg)
  if bets[id] then return colors.yellow, colors.black end
  return bg, fg
end

local function drawBoard()
  local active = not spinning
  fill(1, GRID_Y, W, 6, FELT)

  local function cell(id, x, y, w, h, label, bg, fg)
    bg, fg = cellColors(id, bg, fg)
    if active then
      button(id, x, y, w, h, label, bg, fg)
    else
      fill(x, y, w, h, bg)
      put(x + math.floor((w - #label) / 2), y + math.floor((h - 1) / 2), label, fg, bg)
    end
  end

  local zbg = lastResult == 0 and colors.lime or colors.green
  cell("n0", GX, GRID_Y, 2, 3, "0", zbg, colors.white)
  for n = 1, 36 do
    local col = math.ceil(n / 3)
    local row = 2 - (n - 1) % 3
    local bg = n == lastResult and colors.lime or numColor(n)
    local label = n < 10 and " " .. n or tostring(n)
    cell("n" .. n, GX + 2 + (col - 1) * 2, GRID_Y + row, 2, 1, label, bg, colors.white)
  end

  local y = GRID_Y + 3
  cell("doz1", GX + 2, y, 8, 1, "1-12", colors.lightGray, colors.black)
  cell("doz2", GX + 10, y, 8, 1, "13-24", colors.gray, colors.white)
  cell("doz3", GX + 18, y, 8, 1, "25-36", colors.lightGray, colors.black)
  cell("low", GX + 2, y + 1, 8, 1, "1-18", colors.gray, colors.white)
  cell("even", GX + 10, y + 1, 8, 1, "Gerade", colors.lightGray, colors.black)
  cell("red", GX + 18, y + 1, 8, 1, "Rot", colors.red, colors.white)
  cell("black", GX + 2, y + 2, 8, 1, "Schwarz", colors.black, colors.white)
  cell("odd", GX + 10, y + 2, 8, 1, "Ungerade", colors.gray, colors.white)
  cell("high", GX + 18, y + 2, 8, 1, "19-36", colors.lightGray, colors.black)
end

local function drawInfo()
  fill(1, 2, W, 1, colors.black)
  put(2, 2, "Credits: " .. credits, colors.yellow, colors.black)
  local b = "Beste: " .. best
  put(W - #b, 2, b, colors.lightGray, colors.black)

  fill(1, 5, W, 2, colors.black)
  center(5, message:sub(1, W), messageColor, colors.black)
  local staked = total(bets)
  if staked > 0 then center(6, "Gesetzt: " .. staked, colors.yellow, colors.black) end

  fill(1, 14, W, 1, colors.black)
  if #history > 0 then
    put(2, 14, "Letzte:", colors.lightGray, colors.black)
    local x = 10
    for _, n in ipairs(history) do
      local s = tostring(n)
      if x + #s - 1 > W then break end
      put(x, 14, s, colors.white, numColor(n))
      x = x + #s + 1
    end
  end
end

local function drawControls()
  fill(1, 15, W, 4, colors.black)
  if spinning then return end
  button("minus", 2, 15, 3, 1, "-", colors.lightGray, colors.black)
  center(15, "Chip: " .. chip(), colors.white, colors.black)
  button("plus", W - 3, 15, 3, 1, "+", colors.lightGray, colors.black)

  local staked = total(bets)
  if staked == 0 and credits < CHIPS[1] then
    button("refill", 2, 17, W - 2, 2, "Nachfuellen +" .. START_CREDITS, colors.orange, colors.white)
    return
  end
  local bw = math.floor((W - 4) / 3)
  local x3 = 4 + 2 * bw
  local canRepeat = next(lastBets) ~= nil and total(lastBets) <= credits + staked
  button("clear", 2, 17, bw, 2, "Leeren", colors.red, colors.white, staked == 0)
  button("repeat", 3 + bw, 17, bw, 2, "Wieder", colors.blue, colors.white, not canRepeat)
  button("spin", x3, 17, W - x3, 2, "DREHEN", colors.green, colors.white, staked == 0)
end

local function drawAll()
  buttons = {}
  term.setBackgroundColor(colors.black)
  term.clear()

  fill(1, 1, W, 1, colors.green)
  put(2, 1, "Roulette", colors.white, colors.green)
  local t = textutils.formatTime(os.time(), true)
  put(W - #t, 1, t, colors.white, colors.green)

  drawInfo()
  drawStrip()
  drawBoard()
  drawControls()

  fill(1, H, W, 1, colors.green)
  if not spinning then
    button("back", 1, H, 10, 1, "\27 Zurueck", colors.green, colors.white)
    button("rules", 12, H, 7, 1, "Regeln", colors.green, colors.white)
    button("sound", W - 5, H, 6, 1, sound and "Ton:an" or "Ton:0", colors.green, colors.white)
  end
end

local function drawRules()
  term.setBackgroundColor(colors.black)
  term.clear()
  fill(1, 1, W, 1, colors.green)
  put(2, 1, "Regeln", colors.white, colors.green)
  local lines = {
    "Chips auf Felder setzen,",
    "dann drehen. Rechtsklick",
    "nimmt einen Chip weg.",
    "",
    "Zahl (0-36)      35:1",
    "Dutzend           2:1",
    "Rot / Schwarz     1:1",
    "Gerade/Ungerade   1:1",
    "1-18 / 19-36      1:1",
    "",
    "Faellt die 0, verlieren",
    "alle 1:1-Felder und",
    "Dutzende.",
    "",
    "C = leeren, W = wieder",
  }
  for i, l in ipairs(lines) do
    put(2, 2 + i, l, colors.white, colors.black)
  end
  center(H, "Tippen = zurueck", colors.lightGray, colors.black)
  repeat
    local e = os.pullEventRaw()
    if e == "terminate" then quit = true end
  until e == "mouse_click" or e == "key" or e == "terminate"
end

------------------------------------------------------------------------
-- Spiel
------------------------------------------------------------------------
local function fitChip()
  while chipIndex > 1 and CHIPS[chipIndex] > credits do chipIndex = chipIndex - 1 end
end

local function placeBet(id)
  local c = chip()
  if credits < c then
    message, messageColor = "Nicht genug Credits", colors.red
    return
  end
  credits = credits - c
  bets[id] = (bets[id] or 0) + c
  message, messageColor = "", colors.lightGray
  note("hat", 14, 0.5)
  save()
end

local function removeBet(id)
  local amount = bets[id]
  if not amount then return end
  local c = math.min(chip(), amount)
  credits = credits + c
  bets[id] = amount - c > 0 and amount - c or nil
  note("hat", 8, 0.5)
  save()
end

local function clearBets()
  credits = credits + total(bets)
  bets = {}
  save()
end

local function repeatBets()
  local need = total(lastBets)
  if need == 0 or need > credits + total(bets) then return end
  clearBets()
  for id, v in pairs(lastBets) do bets[id] = v end
  credits = credits - need
  message, messageColor = "", colors.lightGray
  note("hat", 14, 0.5)
  save()
end

local function spin()
  local staked = total(bets)
  if staked == 0 then return end

  -- Ergebnis steht vorher fest, die Anzeige laeuft nur darauf zu
  local target = math.random(#WHEEL)
  local steps = SPIN_ROUNDS * #WHEEL + (target - wheelPos) % #WHEEL
  spinning = true
  lastResult = nil
  message, messageColor = "Nichts geht mehr", colors.lightGray
  drawAll()

  for i = 1, steps do
    if quit then break end
    wheelPos = wheelPos % #WHEEL + 1
    drawStrip()
    note("hat", 20, 0.4)
    wait(SPIN_FAST + SPIN_SLOW * (i / steps) ^ 4)
  end
  wheelPos = target

  local n = WHEEL[target]
  local payout = 0
  for id, v in pairs(bets) do
    local f = payFactor(id, n)
    if f > 0 then payout = payout + v * (f + 1) end
  end
  credits = credits + payout
  local profit = payout - staked
  if profit > best then best = profit end

  lastBets = bets
  bets = {}
  lastResult = n
  table.insert(history, 1, n)
  if #history > HISTORY then table.remove(history) end

  local name = n == 0 and "0 Null" or n .. (RED[n] and " Rot" or " Schwarz")
  if profit > 0 then
    message, messageColor = ("%s  +%d"):format(name, profit), colors.lime
  elseif profit == 0 then
    message, messageColor = ("%s  +-0"):format(name), colors.white
  else
    message, messageColor = ("%s  -%d"):format(name, -profit), colors.red
  end

  spinning = false
  fitChip()
  save()
  drawAll()

  if quit then return end
  if profit >= staked * 10 then
    melody("bell", { 12, 16, 19, 24, 19, 24 }, 0.12)
  elseif profit > 0 then
    melody("bell", { 12, 16, 19, 24 }, 0.12)
  elseif profit == 0 then
    note("chime", 12, 0.6)
  else
    note("didgeridoo", 6, 0.6)
  end
end

------------------------------------------------------------------------
-- Hauptschleife
------------------------------------------------------------------------
fitChip()
drawAll()
local clock = os.startTimer(10)

while not quit do
  local ev = { os.pullEventRaw() }
  local e = ev[1]
  local action, mouseButton

  if e == "terminate" then
    break
  elseif e == "mouse_click" then
    mouseButton = ev[2]
    action = hit(ev[3], ev[4])
  elseif e == "char" then
    local c = ev[2]:lower()
    if c == " " then action = "spin"
    elseif c == "+" or c == "=" then action = "plus"
    elseif c == "-" then action = "minus"
    elseif c == "c" then action = "clear"
    elseif c == "w" then action = "repeat"
    elseif c == "r" then action = "rules"
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
    spin()
  elseif action == "refill" then
    if credits < CHIPS[1] and total(bets) == 0 then
      credits = START_CREDITS
      message, messageColor = "Credits aufgefuellt", colors.orange
      save()
    end
  elseif action == "plus" then
    if chipIndex < #CHIPS and CHIPS[chipIndex + 1] <= credits then chipIndex = chipIndex + 1 end
    save()
  elseif action == "minus" then
    if chipIndex > 1 then chipIndex = chipIndex - 1 end
    save()
  elseif action == "clear" then
    clearBets()
  elseif action == "repeat" then
    repeatBets()
  elseif action == "sound" then
    sound = not sound
    save()
  elseif action == "rules" then
    drawRules()
  elseif action then
    -- Tableau-Feld
    if mouseButton == 2 then removeBet(action) else placeBet(action) end
  end

  if action and not quit then drawAll() end
end

-- Nicht gedrehte Einsaetze zurueckgeben
if not spinning and next(bets) then clearBets() end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
