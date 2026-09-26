-- blackjack.lua - Blackjack fuer PocketOS
--
-- Installation: nach /apps/blackjack.lua kopieren (oder per App Store).
-- Gespielt wird mit virtuellen Credits, sie werden auf dem Geraet gespeichert.
-- Mit Speaker-Upgrade gibt es Soundeffekte.
--
-- Regeln: 6 Decks, Dealer steht auf 17 (auch weich), Blackjack zahlt 3:2,
--         Doppeln auf die ersten zwei Karten. Kein Teilen, keine Versicherung.
--
-- Bedienung: Austeilen = Leertaste / Enter, +/- = Einsatz
--            Karte = K / Leertaste, Halt = H / Enter, Doppeln = D
--            R = Regeln, Backspace = zurueck (laufender Einsatz ist dann weg)

if not term.isColour() then
  print("Blackjack braucht einen")
  print("Advanced Pocket Computer (Farbe).")
  print("Taste druecken...")
  os.pullEvent("key")
  return
end

settings.define("pos.blackjack.credits", { description = "Blackjack: Credits", default = 100, type = "number" })
settings.define("pos.blackjack.best", { description = "Blackjack: hoechster Gewinn", default = 0, type = "number" })
settings.define("pos.blackjack.bet", { description = "Blackjack: Einsatz-Stufe", default = 1, type = "number" })
settings.define("pos.blackjack.sound", { description = "Blackjack: Ton an", default = true, type = "boolean" })

local W, H = term.getSize()
local START_CREDITS = 100
local BETS = { 2, 4, 10, 20, 50, 100, 200 } -- gerade, damit 3:2 aufgeht
local DECKS = 6
local RESHUFFLE_AT = 0.25 -- neu mischen, wenn weniger als 25 % im Schlitten
local DEALER_STANDS = 17
local DEAL_DELAY = 0.3

local FELT = colors.green
local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }
local SUITS = {
  { char = "\3", fg = colors.red }, -- Herz
  { char = "\4", fg = colors.red }, -- Karo
  { char = "\5", fg = colors.black }, -- Kreuz
  { char = "\6", fg = colors.black }, -- Pik
}

------------------------------------------------------------------------
-- Zustand
------------------------------------------------------------------------
local credits = settings.get("pos.blackjack.credits")
local best = settings.get("pos.blackjack.best")
local betIndex = math.max(1, math.min(#BETS, settings.get("pos.blackjack.bet")))
local sound = settings.get("pos.blackjack.sound")
local speaker = peripheral.find("speaker")

local state = "bet" -- "bet" = Einsatz waehlen, "play" = Runde laeuft
local player, dealer = {}, {}
local hideHole = false
local stake = 0
local shoe = {}

local message, messageColor = "Einsatz waehlen", colors.lightGray
local quit = false

local function save()
  settings.set("pos.blackjack.credits", credits)
  settings.set("pos.blackjack.best", best)
  settings.set("pos.blackjack.bet", betIndex)
  settings.set("pos.blackjack.sound", sound)
  settings.save()
end

------------------------------------------------------------------------
-- Karten
------------------------------------------------------------------------
local function newShoe()
  shoe = {}
  for _ = 1, DECKS do
    for s = 1, #SUITS do
      for r = 1, #RANKS do shoe[#shoe + 1] = { rank = r, suit = s } end
    end
  end
  for i = #shoe, 2, -1 do
    local j = math.random(i)
    shoe[i], shoe[j] = shoe[j], shoe[i]
  end
end

local function drawFromShoe()
  if #shoe == 0 then newShoe() end
  return table.remove(shoe)
end

-- Summe und ob ein Ass als 11 zaehlt (weiche Hand)
local function handValue(hand)
  local total, aces = 0, 0
  for _, c in ipairs(hand) do
    if c.rank == 1 then aces = aces + 1 end
    total = total + math.min(c.rank, 10)
  end
  if aces > 0 and total + 10 <= 21 then return total + 10, true end
  return total, false
end

local function valueText(hand)
  local v, soft = handValue(hand)
  if soft and v < 21 then return (v - 10) .. "/" .. v end
  return tostring(v)
end

local function isBlackjack(hand)
  return #hand == 2 and handValue(hand) == 21
end

------------------------------------------------------------------------
-- Ton
------------------------------------------------------------------------
local function note(instrument, pitch, volume)
  if sound and speaker then
    pcall(speaker.playNote, instrument, volume or 1, pitch)
  end
end

local function melody(instrument, pitches, delay)
  for _, p in ipairs(pitches) do
    note(instrument, p)
    local t = os.startTimer(delay)
    repeat
      local e, id = os.pullEventRaw()
      if e == "terminate" then quit = true return end
    until e == "timer" and id == t
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

local CARD_W = 4
local DEALER_Y = 4 -- Beschriftung, Karten darunter
local PLAYER_Y = 9

local function drawCard(x, y, card, hidden)
  if hidden then
    fill(x, y, CARD_W, 3, colors.blue)
    put(x + 1, y + 1, "\127\127", colors.lightBlue, colors.blue)
    return
  end
  local r, s = RANKS[card.rank], SUITS[card.suit]
  fill(x, y, CARD_W, 3, colors.white)
  put(x, y, r, s.fg, colors.white)
  put(x + 1, y + 1, s.char .. s.char, s.fg, colors.white)
  put(x + CARD_W - #r, y + 2, r, s.fg, colors.white)
end

-- Bei vielen Karten ruecken sie zusammen und ueberlappen
local function drawHand(y, hand, hideSecond)
  fill(1, y, W, 3, FELT)
  local n = #hand
  local step = CARD_W + 1
  if n > 1 then step = math.max(2, math.min(step, math.floor((W - 2 - CARD_W) / (n - 1)))) end
  for i, c in ipairs(hand) do
    drawCard(2 + (i - 1) * step, y, c, hideSecond and i == 2)
  end
end

local function bet() return BETS[betIndex] end

local function canDouble()
  return state == "play" and #player == 2 and credits >= stake
end

local function drawTable()
  fill(1, DEALER_Y, W, 10, FELT)
  if #dealer > 0 then
    local v = hideHole and valueText({ dealer[1] }) or valueText(dealer)
    put(2, DEALER_Y, "Dealer: " .. v, colors.white, FELT)
  else
    put(2, DEALER_Y, "Dealer", colors.white, FELT)
  end
  drawHand(DEALER_Y + 1, dealer, hideHole)

  put(2, PLAYER_Y, #player > 0 and "Du: " .. valueText(player) or "Du", colors.white, FELT)
  if stake > 0 then
    local s = "Einsatz " .. stake
    put(W - #s, PLAYER_Y, s, colors.yellow, FELT)
  end
  drawHand(PLAYER_Y + 1, player, false)
end

local function drawInfo()
  fill(1, 3, W, 1, colors.black)
  put(2, 3, "Credits: " .. credits, colors.yellow, colors.black)
  local b = "Beste: " .. best
  put(W - #b, 3, b, colors.lightGray, colors.black)
  fill(1, 14, W, 1, colors.black)
  center(14, message:sub(1, W), messageColor, colors.black)
end

local function drawControls()
  fill(1, 16, W, 3, colors.black)
  if state == "bet" then
    button("minus", 2, 16, 3, 1, "-", colors.lightGray, colors.black)
    center(16, "Einsatz: " .. bet(), colors.white, colors.black)
    button("plus", W - 3, 16, 3, 1, "+", colors.lightGray, colors.black)
    if credits >= BETS[1] then
      button("deal", 2, 17, W - 2, 2, "AUSTEILEN", colors.green, colors.white)
    else
      button("refill", 2, 17, W - 2, 2, "Nachfuellen +" .. START_CREDITS, colors.orange, colors.white)
    end
  else
    local bw = math.floor((W - 4) / 3)
    local x3 = 4 + 2 * bw
    button("hit", 2, 17, bw, 2, "Karte", colors.lime, colors.black)
    button("stand", 3 + bw, 17, bw, 2, "Halt", colors.red, colors.white)
    button("double", x3, 17, W - x3, 2, "Doppeln", colors.orange, colors.white, not canDouble())
  end
end

local function drawAll()
  buttons = {}
  term.setBackgroundColor(colors.black)
  term.clear()

  fill(1, 1, W, 1, colors.green)
  put(2, 1, "Blackjack", colors.white, colors.green)
  local t = textutils.formatTime(os.time(), true)
  put(W - #t, 1, t, colors.white, colors.green)

  drawTable()
  drawInfo()
  drawControls()

  fill(1, H, W, 1, colors.green)
  button("back", 1, H, 10, 1, "\27 Zurueck", colors.green, colors.white)
  button("rules", 12, H, 7, 1, "Regeln", colors.green, colors.white)
  button("sound", W - 5, H, 6, 1, sound and "Ton:an" or "Ton:0", colors.green, colors.white)
end

local function drawRules()
  term.setBackgroundColor(colors.black)
  term.clear()
  fill(1, 1, W, 1, colors.green)
  put(2, 1, "Regeln", colors.white, colors.green)
  local lines = {
    "Ziel: naeher an 21 als der",
    "Dealer, ohne drueber.",
    "",
    "Bildkarten = 10, Ass = 1/11",
    "Dealer zieht bis " .. DEALER_STANDS .. ".",
    "",
    "Sieg        zahlt 1:1",
    "Blackjack   zahlt 3:2",
    "Gleichstand Einsatz zurueck",
    "",
    "Doppeln: Einsatz x2, genau",
    "eine Karte, dann Halt.",
    "",
    DECKS .. " Decks, neu gemischt bei",
    math.floor(RESHUFFLE_AT * 100) .. " % Rest.",
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
local function fitBet()
  while betIndex > 1 and BETS[betIndex] > credits do betIndex = betIndex - 1 end
end

local function giveCard(hand)
  hand[#hand + 1] = drawFromShoe()
  drawTable()
  note("hat", 18, 0.6)
  wait(DEAL_DELAY)
end

-- Runde abrechnen. dealerPlays = false bei ueberkauft oder Blackjack.
local function finish(dealerPlays)
  hideHole = false
  drawTable()
  note("snare", 12, 0.5)
  wait(DEAL_DELAY)

  if dealerPlays then
    while not quit and handValue(dealer) < DEALER_STANDS do giveCard(dealer) end
  end

  local p, d = handValue(player), handValue(dealer)
  local pBJ, dBJ = isBlackjack(player), isBlackjack(dealer)
  local payout, text
  if p > 21 then
    payout, text = 0, "Ueberkauft"
  elseif pBJ and dBJ then
    payout, text = stake, "Beide Blackjack"
  elseif pBJ then
    payout, text = stake + math.floor(stake * 3 / 2), "BLACKJACK!"
  elseif dBJ then
    payout, text = 0, "Dealer hat Blackjack"
  elseif d > 21 then
    payout, text = 2 * stake, "Dealer ueberkauft"
  elseif p > d then
    payout, text = 2 * stake, "Gewonnen"
  elseif p == d then
    payout, text = stake, "Unentschieden"
  else
    payout, text = 0, "Verloren"
  end

  credits = credits + payout
  local profit = payout - stake
  if profit > best then best = profit end
  if profit > 0 then
    message, messageColor = ("%s +%d"):format(text, profit), colors.lime
  elseif profit == 0 then
    message, messageColor = text, colors.white
  else
    message, messageColor = ("%s -%d"):format(text, stake), colors.red
  end

  state = "bet"
  fitBet()
  save()
  drawAll()

  if quit then return end
  if pBJ and profit > 0 then
    melody("bell", { 12, 16, 19, 24, 19, 24 }, 0.12)
  elseif profit > 0 then
    melody("bell", { 12, 16, 19, 24 }, 0.12)
  elseif profit == 0 then
    note("chime", 12, 0.6)
  else
    note("didgeridoo", 6, 0.6)
  end
end

local function deal()
  local b = bet()
  if credits < b then return end
  local shuffled = false
  if #shoe < DECKS * 52 * RESHUFFLE_AT then
    newShoe()
    shuffled = true
  end

  credits = credits - b
  stake = b
  player, dealer = {}, {}
  hideHole = true
  state = "play"
  message, messageColor = shuffled and "Neu gemischt" or "", colors.lightGray
  save()
  drawAll()
  -- waehrend des Austeilens keine Knoepfe
  buttons = {}
  fill(1, 16, W, 3, colors.black)

  giveCard(player)
  giveCard(dealer)
  giveCard(player)
  giveCard(dealer)
  if quit then return end

  if isBlackjack(player) or isBlackjack(dealer) then
    finish(false)
  else
    message = ""
    drawAll()
  end
end

local function hitCard()
  giveCard(player)
  local v = handValue(player)
  if v > 21 then
    finish(false)
  elseif v == 21 then
    finish(true)
  else
    drawAll()
  end
end

local function double()
  if not canDouble() then return end
  credits = credits - stake
  stake = stake * 2
  save()
  drawAll()
  buttons = {}
  giveCard(player)
  finish(handValue(player) <= 21)
end

------------------------------------------------------------------------
-- Hauptschleife
------------------------------------------------------------------------
newShoe()
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
    local c = ev[2]:lower()
    if state == "bet" then
      if c == " " then action = "deal"
      elseif c == "+" or c == "=" then action = "plus"
      elseif c == "-" then action = "minus"
      end
    else
      if c == " " or c == "k" then action = "hit"
      elseif c == "h" then action = "stand"
      elseif c == "d" then action = "double"
      end
    end
    if c == "r" then action = "rules" end
  elseif e == "key" then
    if ev[2] == keys.enter then action = state == "bet" and "deal" or "stand"
    elseif ev[2] == keys.backspace then action = "back"
    end
  elseif e == "timer" and ev[2] == clock then
    clock = os.startTimer(10)
    drawAll() -- Uhrzeit aktualisieren
  end

  if action == "back" then
    break
  elseif state == "bet" and action == "deal" then
    deal()
  elseif state == "bet" and action == "refill" then
    if credits < BETS[1] then
      credits = START_CREDITS
      message, messageColor = "Credits aufgefuellt", colors.orange
      save()
    end
  elseif state == "bet" and action == "plus" then
    if betIndex < #BETS and BETS[betIndex + 1] <= credits then betIndex = betIndex + 1 end
    save()
  elseif state == "bet" and action == "minus" then
    if betIndex > 1 then betIndex = betIndex - 1 end
    save()
  elseif state == "play" and action == "hit" then
    hitCard()
  elseif state == "play" and action == "stand" then
    finish(true)
  elseif state == "play" and action == "double" then
    double()
  elseif action == "sound" then
    sound = not sound
    save()
  elseif action == "rules" then
    drawRules()
  end

  if action and not quit then drawAll() end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
