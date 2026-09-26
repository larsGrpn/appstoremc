-- snake.lua - Snake fuer Pocket Computer (CC:Tweaked)
--
-- Steuerung: Pfeiltasten / WASD, oder auf dem Bildschirm antippen
--            (Antippen links/rechts bzw. oben/unten der Schlange = abbiegen)
--            P oder Tippen auf die Kopfzeile = Pause, Q = Beenden

local START_DELAY = 0.20  -- Sekunden pro Schritt am Anfang
local MIN_DELAY   = 0.07  -- schnellstes Tempo
local SPEEDUP     = 0.006 -- Beschleunigung pro gefressenem Futter
local SCORE_FILE  = ".snake_highscore"

local color = term.isColor()
local W, H = term.getSize()
local FW, FH = W, H - 1 -- Spielfeld; Zeile 1 ist die Kopfzeile

local KEYS = {
  [keys.up] = "up",     [keys.w] = "up",
  [keys.down] = "down", [keys.s] = "down",
  [keys.left] = "left", [keys.a] = "left",
  [keys.right] = "right", [keys.d] = "right",
}
local VEC = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }

local SKIN = color and {
  empty = { ch = " ", bg = colors.black },
  head  = { ch = " ", bg = colors.lime },
  body  = { ch = " ", bg = colors.green },
  food  = { ch = " ", bg = colors.red },
} or {
  empty = { ch = " " },
  head  = { ch = "@" },
  body  = { ch = "o" },
  food  = { ch = "*" },
}

local function loadBest()
  if not fs.exists(SCORE_FILE) then return 0 end
  local f = fs.open(SCORE_FILE, "r")
  if not f then return 0 end
  local n = tonumber(f.readAll())
  f.close()
  return n or 0
end

local function saveBest(n)
  local f = fs.open(SCORE_FILE, "w")
  if f then
    f.write(tostring(n))
    f.close()
  end
end

local function setColors(fg, bg)
  if color then
    term.setTextColor(fg)
    term.setBackgroundColor(bg)
  end
end

local function drawCell(x, y, kind)
  local s = SKIN[kind]
  term.setCursorPos(x, y + 1)
  setColors(colors.white, s.bg or colors.black)
  term.write(s.ch)
end

local function drawHeader(score, best, paused)
  setColors(colors.yellow, colors.black)
  term.setCursorPos(1, 1)
  term.clearLine()
  term.write(paused and "PAUSE" or ("Punkte " .. score))
  local right = "Best " .. best
  term.setCursorPos(W - #right + 1, 1)
  term.write(right)
end

local function center(y, text, fg)
  setColors(fg or colors.white, colors.black)
  term.setCursorPos(math.floor((W - #text) / 2) + 1, y)
  term.write(text)
end

-- Verwirft Eingaben kurz, damit ein Tastendruck aus dem Spiel
-- nicht gleich den naechsten Bildschirm ueberspringt.
local function flushInput()
  local id = os.startTimer(0.6)
  repeat
    local ev, a = os.pullEvent()
  until ev == "timer" and a == id
end

-- Zeigt einen Textbildschirm. Rueckgabe: "go" oder "quit"
local function screen(lines)
  setColors(colors.white, colors.black)
  term.clear()
  local y = math.max(1, math.floor((H - #lines) / 2))
  for i, l in ipairs(lines) do
    center(y + i - 1, l.text, l.color)
  end
  flushInput()
  while true do
    local ev, a = os.pullEvent()
    if ev == "key" then
      if a == keys.q then return "quit" end
      return "go"
    elseif ev == "mouse_click" then
      return "go"
    end
  end
end

-- Eine Runde spielen. Rueckgabe: Punkte, gewonnen?, beendet?
local function playRound(best)
  setColors(colors.white, colors.black)
  term.clear()

  local function key(x, y) return (y - 1) * FW + x end

  local cx, cy = math.floor(FW / 2), math.floor(FH / 2)
  local snake = { { x = cx, y = cy }, { x = cx - 1, y = cy }, { x = cx - 2, y = cy } }
  local occ = {}
  for i, seg in ipairs(snake) do
    occ[key(seg.x, seg.y)] = true
    drawCell(seg.x, seg.y, i == 1 and "head" or "body")
  end

  local function placeFood()
    local free = {}
    for y = 1, FH do
      for x = 1, FW do
        if not occ[key(x, y)] then free[#free + 1] = { x = x, y = y } end
      end
    end
    if #free == 0 then return nil end
    local f = free[math.random(#free)]
    drawCell(f.x, f.y, "food")
    return f
  end

  local food = placeFood()
  local dir, queue = "right", {}
  local score, delay, paused = 0, START_DELAY, false
  drawHeader(score, best, paused)

  local function turn(d)
    local last = queue[#queue] or dir
    if d ~= last and d ~= OPPOSITE[last] and #queue < 2 then
      queue[#queue + 1] = d
    end
  end

  local function step()
    if queue[1] then dir = table.remove(queue, 1) end
    local v = VEC[dir]
    local head = snake[1]
    local nx, ny = head.x + v[1], head.y + v[2]
    if nx < 1 or ny < 1 or nx > FW or ny > FH then return "dead" end

    local eating = nx == food.x and ny == food.y
    if not eating then
      -- Das Schwanzende rueckt weg, das Feld ist danach frei.
      local tail = table.remove(snake)
      occ[key(tail.x, tail.y)] = nil
      drawCell(tail.x, tail.y, "empty")
    end
    if occ[key(nx, ny)] then return "dead" end

    drawCell(head.x, head.y, "body")
    table.insert(snake, 1, { x = nx, y = ny })
    occ[key(nx, ny)] = true
    drawCell(nx, ny, "head")

    if eating then
      score = score + 1
      delay = math.max(MIN_DELAY, delay - SPEEDUP)
      food = placeFood()
      if not food then return "won" end
      drawHeader(score, math.max(best, score), paused)
    end
  end

  local timer = os.startTimer(delay)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == timer then
      if not paused then
        local result = step()
        if result == "dead" then return score, false, false end
        if result == "won" then return score, true, false end
      end
      timer = os.startTimer(delay)

    elseif ev == "key" then
      if KEYS[a] then
        turn(KEYS[a])
      elseif a == keys.p or a == keys.space then
        paused = not paused
        drawHeader(score, math.max(best, score), paused)
      elseif a == keys.q then
        return score, false, true
      end

    elseif ev == "mouse_click" then
      if c == 1 then
        paused = not paused
        drawHeader(score, math.max(best, score), paused)
      else
        -- Beim Fahren nach links/rechts biegt Antippen oben/unten ab, und umgekehrt.
        local head = snake[1]
        local dx, dy = b - head.x, (c - 1) - head.y
        local last = queue[#queue] or dir
        if last == "left" or last == "right" then
          if dy ~= 0 then turn(dy < 0 and "up" or "down") end
        else
          if dx ~= 0 then turn(dx < 0 and "left" or "right") end
        end
      end
    end
  end
end

local function main()
  math.randomseed(os.epoch("utc"))
  local best = loadBest()

  local start = screen({
    { text = "S N A K E", color = color and colors.lime or colors.white },
    { text = "" },
    { text = "Pfeile/WASD: steuern" },
    { text = "Antippen: abbiegen" },
    { text = "P: Pause  Q: Ende" },
    { text = "" },
    { text = "Taste druecken", color = color and colors.yellow or colors.white },
  })
  if start == "quit" then return end

  while true do
    local score, won, quit = playRound(best)
    local record = score > best
    if record then
      best = score
      saveBest(best)
    end
    if quit then return end

    local action = screen({
      { text = won and "GEWONNEN!" or "GAME OVER", color = color and (won and colors.lime or colors.red) or colors.white },
      { text = "" },
      { text = "Punkte: " .. score },
      { text = record and "NEUER REKORD!" or ("Rekord: " .. best), color = color and colors.yellow or colors.white },
      { text = "" },
      { text = "Taste: nochmal" },
      { text = "Q: Ende" },
    })
    if action == "quit" then return end
  end
end

local ok, err = pcall(main)
setColors(colors.white, colors.black)
term.clear()
term.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then error(err, 0) end
