-- tetris.lua - Tetris fuer Pocket Computer (CC:Tweaked)
--
-- Steuerung: Links/Rechts oder A/D = bewegen, Hoch/W/X = drehen, Z = zurueckdrehen
--            Runter/S = schneller fallen, Leertaste = fallen lassen
--            P oder Tippen auf die Kopfzeile = Pause, Q = Beenden
--            Antippen: linkes Drittel = links, rechtes Drittel = rechts,
--                      Mitte oben = drehen, Mitte unten = fallen lassen

local START_DELAY     = 0.80 -- Sekunden pro Fallschritt in Level 1
local MIN_DELAY       = 0.08 -- schnellstes Tempo
local LEVEL_FACTOR    = 0.82 -- Tempo-Faktor pro Level
local LINES_PER_LEVEL = 10
local LINE_SCORE      = { 100, 300, 500, 800 } -- 1 bis 4 Zeilen, mal Level
local COLS            = 10
local SCORE_FILE      = ".tetris_highscore"

local color = term.isColor()
local W, H = term.getSize()
local BH = math.min(20, H - 1) -- Spielfeldhoehe; Zeile 1 ist die Kopfzeile
local CW = (W >= COLS * 2 + 6) and 2 or 1 -- Zeichen pro Spielfeldzelle
local SBW = (W >= COLS * CW + 10) and 10 or 6 -- Breite der Seitenleiste
local PCW = SBW >= 9 and 2 or 1 -- Zeichen pro Zelle der Vorschau
local OX = math.max(1, math.floor((W - (COLS * CW + SBW)) / 2) + 1) -- Spielfeld links
local SX = OX + COLS * CW -- Seitenleiste links

local KEYS = {
  [keys.left] = "left", [keys.a] = "left",
  [keys.right] = "right", [keys.d] = "right",
  [keys.up] = "rotate", [keys.w] = "rotate", [keys.x] = "rotate",
  [keys.z] = "rotateBack",
  [keys.down] = "soft", [keys.s] = "soft",
  [keys.space] = "hard",
}

local function parse(rows)
  local cells = {}
  for y, row in ipairs(rows) do
    for x = 1, #row do
      if row:sub(x, x) == "X" then cells[#cells + 1] = { x - 1, y - 1 } end
    end
  end
  return cells, #rows
end

local SHAPES = {}
for _, def in ipairs({
  { colors.cyan,   { "....", "XXXX", "....", "...." } }, -- I
  { colors.yellow, { "XX", "XX" } },                     -- O
  { colors.purple, { ".X.", "XXX", "..." } },            -- T
  { colors.lime,   { ".XX", "XX.", "..." } },            -- S
  { colors.red,    { "XX.", ".XX", "..." } },            -- Z
  { colors.blue,   { "X..", "XXX", "..." } },            -- J
  { colors.orange, { "..X", "XXX", "..." } },            -- L
}) do
  local cells, n = parse(def[2])
  SHAPES[#SHAPES + 1] = { color = def[1], cells = cells, n = n }
end

-- Zellen einer n x n Figur drehen (dir > 0 im Uhrzeigersinn).
local function rotate(cells, n, dir)
  local out = {}
  for i, c in ipairs(cells) do
    if dir > 0 then
      out[i] = { n - 1 - c[2], c[1] }
    else
      out[i] = { c[2], n - 1 - c[1] }
    end
  end
  return out
end

-- Text/Vordergrund/Hintergrund (fuer term.blit) je Zellart: 0 = leer, 1..7 = Figur
local CELL = {}
for k = 0, #SHAPES do
  if color then
    CELL[k] = {
      text = string.rep(" ", CW),
      fg = string.rep("0", CW),
      bg = string.rep(k == 0 and colors.toBlit(colors.gray) or colors.toBlit(SHAPES[k].color), CW),
    }
  else
    local text
    if k == 0 then
      text = CW == 2 and " ." or "."
    else
      text = CW == 2 and "[]" or "#"
    end
    CELL[k] = { text = text, fg = string.rep("0", CW), bg = string.rep("f", CW) }
  end
end

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

local function center(y, text, fg)
  setColors(fg or colors.white, colors.black)
  term.setCursorPos(math.floor((W - #text) / 2) + 1, y)
  term.write(text)
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

local function drawSide(kind, level, lines)
  local function put(y, text, fg)
    setColors(fg or colors.white, colors.black)
    term.setCursorPos(SX + 1, y)
    term.write(text .. string.rep(" ", SBW - 1 - #text))
  end

  put(2, "Next", colors.yellow)
  setColors(colors.white, colors.black)
  for y = 3, 4 do
    term.setCursorPos(SX, y)
    term.write(string.rep(" ", SBW))
  end
  local s = SHAPES[kind]
  local minX, minY = math.huge, math.huge
  for _, c in ipairs(s.cells) do
    minX = math.min(minX, c[1])
    minY = math.min(minY, c[2])
  end
  setColors(colors.white, s.color)
  for _, c in ipairs(s.cells) do
    term.setCursorPos(SX + 1 + (c[1] - minX) * PCW, 3 + c[2] - minY)
    term.write(string.rep(color and " " or "#", PCW))
  end

  put(7, "Level", colors.yellow)
  put(8, tostring(level))
  put(10, "Lines", colors.yellow)
  put(11, tostring(lines))
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

-- Eine Runde spielen. Rueckgabe: Punkte, Zeilen, beendet?
local function playRound(best)
  setColors(colors.white, colors.black)
  term.clear()

  local board = {}
  local function emptyRow()
    local row = {}
    for x = 1, COLS do row[x] = 0 end
    return row
  end
  for y = 1, BH do board[y] = emptyRow() end

  local bag = {}
  local function nextKind()
    if #bag == 0 then
      for i = 1, #SHAPES do bag[i] = i end
      for i = #bag, 2, -1 do
        local j = math.random(i)
        bag[i], bag[j] = bag[j], bag[i]
      end
    end
    return table.remove(bag)
  end

  local function newPiece(kind)
    local s = SHAPES[kind]
    local minY = math.huge
    for _, c in ipairs(s.cells) do minY = math.min(minY, c[2]) end
    return {
      kind = kind, cells = s.cells, n = s.n,
      x = math.floor((COLS - s.n) / 2) + 1, y = 1 - minY,
    }
  end

  local function fits(cells, x, y)
    for _, c in ipairs(cells) do
      local bx, by = x + c[1], y + c[2]
      if bx < 1 or bx > COLS or by < 1 or by > BH or board[by][bx] ~= 0 then
        return false
      end
    end
    return true
  end

  local piece = newPiece(nextKind())
  local upcoming = nextKind()
  local score, lines, level = 0, 0, 1
  local delay, paused, timer = START_DELAY, false, nil

  local function drawBoard()
    local over = {}
    for _, c in ipairs(piece.cells) do
      over[(piece.y + c[2] - 1) * COLS + piece.x + c[1]] = piece.kind
    end
    for y = 1, BH do
      local t, f, b = {}, {}, {}
      for x = 1, COLS do
        local cell = CELL[over[(y - 1) * COLS + x] or board[y][x]]
        t[x], f[x], b[x] = cell.text, cell.fg, cell.bg
      end
      term.setCursorPos(OX, y + 1)
      term.blit(table.concat(t), table.concat(f), table.concat(b))
    end
  end

  local function refresh()
    drawBoard()
    drawHeader(score, math.max(best, score), paused)
    drawSide(upcoming, level, lines)
  end

  local function tryMove(dx, dy)
    if fits(piece.cells, piece.x + dx, piece.y + dy) then
      piece.x, piece.y = piece.x + dx, piece.y + dy
      return true
    end
    return false
  end

  -- Drehen; bei Kollision mit der Wand seitlich ausweichen.
  local function tryRotate(dir)
    local cells = rotate(piece.cells, piece.n, dir)
    for _, kick in ipairs({ 0, -1, 1, -2, 2 }) do
      if fits(cells, piece.x + kick, piece.y) then
        piece.cells, piece.x = cells, piece.x + kick
        return
      end
    end
  end

  -- Figur ablegen, volle Zeilen entfernen, naechste Figur holen.
  -- Rueckgabe: "dead", wenn fuer die neue Figur kein Platz ist.
  local function lock()
    for _, c in ipairs(piece.cells) do
      board[piece.y + c[2]][piece.x + c[1]] = piece.kind
    end

    local cleared, y = 0, BH
    while y >= 1 do
      local full = true
      for x = 1, COLS do
        if board[y][x] == 0 then full = false break end
      end
      if full then
        table.remove(board, y)
        table.insert(board, 1, emptyRow())
        cleared = cleared + 1
      else
        y = y - 1
      end
    end

    if cleared > 0 then
      score = score + LINE_SCORE[cleared] * level
      lines = lines + cleared
      level = math.floor(lines / LINES_PER_LEVEL) + 1
      delay = math.max(MIN_DELAY, START_DELAY * LEVEL_FACTOR ^ (level - 1))
    end

    piece = newPiece(upcoming)
    upcoming = nextKind()
    timer = os.startTimer(delay)
    if not fits(piece.cells, piece.x, piece.y) then return "dead" end
  end

  timer = os.startTimer(delay)
  refresh()
  while true do
    local ev, a, b, c = os.pullEvent()
    local result

    if ev == "timer" and a == timer then
      if not paused and not tryMove(0, 1) then result = lock() end
      timer = os.startTimer(delay)

    elseif ev == "key" then
      local action = KEYS[a]
      if a == keys.q then
        return score, lines, true
      elseif a == keys.p then
        paused = not paused
      elseif paused then
        -- Bewegung ignorieren
      elseif action == "left" then
        tryMove(-1, 0)
      elseif action == "right" then
        tryMove(1, 0)
      elseif action == "rotate" then
        tryRotate(1)
      elseif action == "rotateBack" then
        tryRotate(-1)
      elseif action == "soft" then
        if tryMove(0, 1) then score = score + 1 end
      elseif action == "hard" then
        while tryMove(0, 1) do score = score + 2 end
        result = lock()
      end

    elseif ev == "mouse_click" then
      if c == 1 then
        paused = not paused
      elseif paused then
        paused = false
      else
        local third = COLS * CW / 3
        if b < OX + third then
          tryMove(-1, 0)
        elseif b >= OX + 2 * third then
          tryMove(1, 0)
        elseif c - 1 <= BH / 2 then
          tryRotate(1)
        else
          while tryMove(0, 1) do score = score + 2 end
          result = lock()
        end
      end
    end

    if result == "dead" then return score, lines, false end
    if ev == "timer" or ev == "key" or ev == "mouse_click" then refresh() end
  end
end

local function main()
  math.randomseed(os.epoch("utc"))
  local best = loadBest()

  local start = screen({
    { text = "T E T R I S", color = color and colors.cyan or colors.white },
    { text = "" },
    { text = "Pfeile/AD: bewegen" },
    { text = "Hoch/W: drehen" },
    { text = "Runter/S: schneller" },
    { text = "Leertaste: fallen" },
    { text = "P: Pause  Q: Ende" },
    { text = "" },
    { text = "Antippen: links/rechts," },
    { text = "Mitte: drehen/fallen" },
    { text = "" },
    { text = "Taste druecken", color = color and colors.yellow or colors.white },
  })
  if start == "quit" then return end

  while true do
    local score, lines, quit = playRound(best)
    local record = score > best
    if record then
      best = score
      saveBest(best)
    end
    if quit then return end

    local action = screen({
      { text = "GAME OVER", color = color and colors.red or colors.white },
      { text = "" },
      { text = "Punkte: " .. score },
      { text = "Zeilen: " .. lines },
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
