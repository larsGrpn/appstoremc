-- katapult.lua - Schleuder-Physikspiel fuer PocketOS
--
-- Schiesse mit dem Katapult Steine auf Tuerme aus Holz, Glas und Stein
-- und erwische alle Wabbel. Einstuerzende Bloecke zerquetschen sie auch!
--
-- Installation: nach /apps/katapult.lua kopieren (oder per App Store).
-- Braucht einen Advanced Pocket Computer (Farbe + Touch).
--
-- Bedienung:
--   Tippen und ziehen (wie eine Schleuder zurueckziehen), loslassen = Wurf
--   Oder: Pfeil hoch/runter = Winkel, links/rechts = Kraft, Leertaste = Wurf
--   Im Levelmenue: Level antippen oder Taste 1-6

local ARGS = { ... }
local TEST = ARGS[1] == "--test"

if not TEST and not term.isColour() then
  print("Katapult braucht einen Advanced")
  print("Pocket Computer (Farbe).")
  print("Taste druecken...")
  os.pullEvent("key")
  return
end

settings.define("pos.katapult.unlocked", {
  description = "Katapult: freigeschaltete Level",
  default = 1,
  type = "number",
})

------------------------------------------------------------------------
-- Konstanten
------------------------------------------------------------------------
local W, H = term.getSize()
local TOP = 2                 -- erste Zeile des Spielfelds
local GROUND = H - 2          -- Bodenzeile
local REST_X, REST_Y = 4.5, GROUND - 2.5 -- Stein in der Schleuder
local GRAVITY = 14            -- Felder pro Sekunde^2
local SPEED_PER_PULL = 3.3    -- Abwurfgeschwindigkeit je gezogenem Feld
local MAX_PULL = 6            -- maximale Zuglaenge in Feldern
local DT = 0.05               -- Sekunden pro Spielschritt
local FALL_EVERY = 2          -- Bloecke fallen jeden 2. Schritt ein Feld
local SPAN = 2                -- so weit tragen Bloecke seitlich (Balken)

local atan2 = math.atan2 or math.atan

local TYPES = {
  W = { name = "Holz", hp = 2, bg = colors.brown, fg = colors.orange, full = "=", hurt = "%", points = 50 },
  S = { name = "Stein", hp = 4, bg = colors.gray, fg = colors.lightGray, full = " ", hurt = "\127", points = 100 },
  G = { name = "Glas", hp = 1, bg = colors.white, fg = colors.lightBlue, full = "/", hurt = "/", points = 30 },
  o = { name = "Wabbel", hp = 1, points = 500 },
}

-- Level: Karte von oben nach unten, alle Zeilen gleich breit.
-- . = leer, W = Holz, S = Stein, G = Glas, o = Wabbel
local LEVELS = {
  { name = "Aufwaermen", shots = 3, map = {
    "..o..",
    ".WWW.",
    ".W.W.",
    ".W.W.",
  } },
  { name = "Zwillinge", shots = 3, map = {
    ".o....o.",
    "WWW..WWW",
    "W.W..W.W",
    "W.W..W.W",
  } },
  { name = "Glashaus", shots = 3, map = {
    "..o...",
    ".GGG..",
    ".GoG.o",
    ".GGGGG",
    ".G.G.G",
  } },
  { name = "Steinfort", shots = 4, map = {
    "...o....",
    "..SSS...",
    "..S.S.o.",
    "..S.SWWW",
    ".oS.SW.W",
    "SSSSSW.W",
  } },
  { name = "Zwei Burgen", shots = 4, map = {
    "..o.....o..",
    ".WWW...SSS.",
    ".WoW...SoS.",
    ".WWW...SSS.",
    ".G.G...W.W.",
    ".G.G...W.W.",
  } },
  { name = "Festung", shots = 5, map = {
    "......o......",
    ".....SSS.....",
    "..o..S.S..o..",
    ".GGG.S.S.WWW.",
    ".GoG.SoS.WoW.",
    ".GGGSSSSSWWWW",
  } },
}

------------------------------------------------------------------------
-- Zustand
------------------------------------------------------------------------
local level, grid, proj, phase, shots, score
local aimAngle, aimPower = 45, 0.7
local aiming, dragged, aimStartX, aimStartY = false, false, 0, 0
local settleQuiet, tickCount = 0, 0
local lastStars = 0

local function starsOf(n)
  return settings.get("pos.katapult.stars." .. n, 0)
end

local function bestOf(n)
  return settings.get("pos.katapult.best." .. n, 0)
end

------------------------------------------------------------------------
-- Spiellogik
------------------------------------------------------------------------
local function newObj(t)
  return { t = t, hp = TYPES[t].hp, fall = 0 }
end

local function isBlock(o)
  return o ~= nil and o.t ~= "o"
end

local function countBlobs()
  local n = 0
  for y = TOP, GROUND - 1 do
    for x = 1, W do
      local o = grid[y][x]
      if o and o.t == "o" then n = n + 1 end
    end
  end
  return n
end

local function objAt(cx, cy)
  if cy < TOP or cy >= GROUND or cx < 1 or cx > W then return nil end
  return grid[cy][cx]
end

-- Ein fallendes Objekt ist aufgekommen: Sturzschaden verteilen
local function landed(o, x, y, kill)
  if kill then
    if o.t == "o" and o.fall >= 2 then
      grid[y][x] = nil -- Wabbel ueberlebt den Sturz nicht
      score = score + TYPES.o.points
    elseif o.t ~= "o" and o.fall >= 3 then
      o.hp = o.hp - 1
      if o.hp <= 0 then
        grid[y][x] = nil
        score = score + TYPES[o.t].points
      end
    end
  end
  o.fall = 0
end

-- Ein Schritt Schwerkraft, von unten nach oben.
-- Gestuetzt ist ein Objekt, wenn direkt darunter etwas liegt. Ruhende
-- Bloecke (keine Wabbel) tragen sich ausserdem bis zu SPAN Felder seitlich
-- ueber eine Reihe von Bloecken, die direkt gestuetzt ist (Balken).
-- Rueckgabe: hat sich etwas bewegt?
local function settleStep(kill)
  local moved = false
  for y = GROUND - 1, TOP, -1 do
    local row = grid[y]
    local below = grid[y + 1] -- nil in der untersten Reihe (Boden)

    local direct, crush = {}, {}
    for x = 1, W do
      local o = row[x]
      if o then
        if not below then
          direct[x] = true
        else
          local b = below[x]
          if b then
            if kill and isBlock(o) and o.fall >= 1 and b.t == "o" then
              crush[x] = true -- fallender Block zerquetscht einen Wabbel
            else
              direct[x] = true
            end
          end
        end
      end
    end

    local supported = {}
    for x = 1, W do
      local o = row[x]
      if o and not crush[x] then
        if direct[x] then
          supported[x] = true
        elseif isBlock(o) and o.fall == 0 then
          for _, dir in ipairs({ -1, 1 }) do
            for k = 1, SPAN do
              local nx = x + dir * k
              if not isBlock(row[nx]) or crush[nx] then break end
              if direct[nx] then
                supported[x] = true
                break
              end
            end
            if supported[x] then break end
          end
        end
      end
    end

    for x = 1, W do
      local o = row[x]
      if o then
        if supported[x] then
          if o.fall > 0 then landed(o, x, y, kill) end
        else
          if crush[x] then score = score + TYPES.o.points end
          below[x], row[x] = o, nil
          o.fall = o.fall + 1
          moved = true
        end
      end
    end
  end
  return moved
end

local function loadLevel(n)
  level = n
  local L = LEVELS[n]
  grid = {}
  for y = TOP, GROUND - 1 do grid[y] = {} end
  local width = #L.map[1]
  local x0 = W - width - 1
  local y0 = GROUND - #L.map
  for r, line in ipairs(L.map) do
    for i = 1, #line do
      local c = line:sub(i, i)
      local x, y = x0 + i, y0 + r - 1
      if TYPES[c] and y >= TOP and x >= 1 and x <= W then
        grid[y][x] = newObj(c)
      end
    end
  end
  shots = L.shots
  score = 0
  proj = nil
  aiming, dragged = false, false
  settleQuiet, tickCount = 0, 0
  for _ = 1, 40 do
    if not settleStep(false) then break end
  end
  phase = "aim"
end

local function launch()
  if phase ~= "aim" or shots <= 0 then return end
  local a = math.rad(aimAngle)
  local sp = aimPower * MAX_PULL * SPEED_PER_PULL
  proj = { x = REST_X, y = REST_Y, vx = math.cos(a) * sp, vy = -math.sin(a) * sp, t = 0, slow = 0 }
  shots = shots - 1
  phase = "fly"
end

local function flyStep(dt)
  local p = proj
  local sp0 = math.sqrt(p.vx * p.vx + p.vy * p.vy) + GRAVITY * dt
  local n = math.max(1, math.ceil(sp0 * dt / 0.35)) -- nie mehr als 0,35 Felder pro Teilschritt
  local h = dt / n
  for _ = 1, n do
    p.vy = p.vy + GRAVITY * h
    local nx, ny = p.x + p.vx * h, p.y + p.vy * h
    if nx < 1 or nx >= W + 1 then
      proj = nil -- aus dem Bild geflogen
      return
    end
    local cx, cy = math.floor(nx), math.floor(ny)
    local sp = math.sqrt(p.vx * p.vx + p.vy * p.vy)
    if cy >= GROUND then
      -- Boden: abprallen und bremsen
      p.x, p.y = nx, GROUND - 0.01
      p.vy = -p.vy * 0.35
      p.vx = p.vx * 0.7
    else
      local o = objAt(cx, cy)
      if not o then
        p.x, p.y = nx, ny
      elseif o.t == "o" then
        grid[cy][cx] = nil
        score = score + TYPES.o.points
        p.vx, p.vy = p.vx * 0.75, p.vy * 0.75
        p.x, p.y = nx, ny
      else
        if sp >= 2 then
          local dmg = sp >= 13 and 3 or (sp >= 7 and 2 or 1)
          o.hp = o.hp - dmg
        end
        if o.hp <= 0 then
          grid[cy][cx] = nil
          score = score + TYPES[o.t].points
          p.vx, p.vy = p.vx * 0.55, p.vy * 0.55
          p.x, p.y = nx, ny
        else
          -- abprallen, Position bleibt
          local ox, oy = math.floor(p.x), math.floor(p.y)
          if ox ~= cx then p.vx = -p.vx * 0.3 end
          if oy ~= cy then p.vy = -p.vy * 0.3 end
          if ox == cx and oy == cy then
            p.vx, p.vy = -p.vx * 0.3, -p.vy * 0.3
          end
        end
      end
    end
  end
  p.t = p.t + dt
  if math.sqrt(p.vx * p.vx + p.vy * p.vy) < 1.5 then
    p.slow = p.slow + dt
  else
    p.slow = 0
  end
  if p.slow > 0.4 or p.t > 7 then proj = nil end
end

local function saveProgress()
  if level < #LEVELS and level + 1 > settings.get("pos.katapult.unlocked") then
    settings.set("pos.katapult.unlocked", level + 1)
  end
  if score > bestOf(level) then settings.set("pos.katapult.best." .. level, score) end
  if lastStars > starsOf(level) then settings.set("pos.katapult.stars." .. level, lastStars) end
  settings.save()
end

local function endTurn()
  if countBlobs() == 0 then
    score = score + shots * 1000
    lastStars = 1 + math.min(2, shots)
    phase = "won"
    saveProgress()
  elseif shots <= 0 then
    phase = "lost"
  else
    phase = "aim"
  end
end

local function tick()
  tickCount = tickCount + 1
  local fallNow = tickCount % FALL_EVERY == 0
  if phase == "fly" then
    flyStep(DT)
    if fallNow then settleStep(true) end
    if not proj then
      phase = "settle"
      settleQuiet = 0
    end
  elseif phase == "settle" then
    if fallNow then
      if settleStep(true) then
        settleQuiet = 0
      else
        settleQuiet = settleQuiet + 1
      end
      if settleQuiet >= 3 then endTurn() end
    end
  end
end

------------------------------------------------------------------------
-- Zeichnen (ganzer Bildschirm per term.blit)
------------------------------------------------------------------------
local HEX = {}
for i = 0, 15 do HEX[2 ^ i] = ("0123456789abcdef"):sub(i + 1, i + 1) end

local cvCh, cvFg, cvBg = {}, {}, {}
local buttons = {}

local function clearCanvas(bg)
  for y = 1, H do
    local ch, fg, b = {}, {}, {}
    for x = 1, W do
      ch[x], fg[x], b[x] = " ", "0", HEX[bg]
    end
    cvCh[y], cvFg[y], cvBg[y] = ch, fg, b
  end
  buttons = {}
end

local function set(x, y, c, f, b)
  x, y = math.floor(x), math.floor(y)
  if x < 1 or x > W or y < 1 or y > H then return end
  if c then cvCh[y][x] = c end
  if f then cvFg[y][x] = HEX[f] end
  if b then cvBg[y][x] = HEX[b] end
end

local function text(x, y, s, f, b)
  for i = 1, #s do set(x + i - 1, y, s:sub(i, i), f, b) end
end

local function centerText(y, s, f, b)
  text(math.floor((W - #s) / 2) + 1, y, s, f, b)
end

local function fillRect(x, y, w, h, b)
  for yy = y, y + h - 1 do
    for xx = x, x + w - 1 do set(xx, yy, " ", nil, b) end
  end
end

local function button(id, x, y, w, h, label, b, f)
  fillRect(x, y, w, h, b)
  label = label:sub(1, w)
  text(x + math.floor((w - #label) / 2), y + math.floor((h - 1) / 2), label, f, b)
  buttons[#buttons + 1] = { id = id, x = x, y = y, w = w, h = h }
end

-- spaeter hinzugefuegte Knoepfe (Ergebnisfenster) haben Vorrang
local function hit(mx, my)
  for i = #buttons, 1, -1 do
    local b = buttons[i]
    if mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h then return b.id end
  end
end

local function present()
  for y = 1, H do
    term.setCursorPos(1, y)
    term.blit(table.concat(cvCh[y]), table.concat(cvFg[y]), table.concat(cvBg[y]))
  end
end

local function renderMenu()
  clearCanvas(colors.black)
  fillRect(1, 1, W, 1, colors.blue)
  text(2, 1, "Katapult", colors.white, colors.blue)
  local unlocked = settings.get("pos.katapult.unlocked")
  for i = 1, #LEVELS do
    local x = 3 + ((i - 1) % 3) * 8
    local y = 3 + math.floor((i - 1) / 3) * 4
    if i <= unlocked then
      button("lvl:" .. i, x, y, 6, 3, tostring(i), colors.orange, colors.white)
      local s = ("*"):rep(starsOf(i))
      text(x + math.floor((6 - #s) / 2), y + 2, s, colors.yellow, colors.orange)
    else
      fillRect(x, y, 6, 3, colors.gray)
      text(x + 2, y + 1, "--", colors.lightGray, colors.gray)
    end
  end
  local help = {
    "Tippen + ziehen = zielen",
    "Loslassen = werfen",
    "Pfeile + Leertaste geht auch",
    "Erwische alle Wabbel \2",
  }
  for i, l in ipairs(help) do text(2, 11 + i, l, colors.lightGray, colors.black) end
  fillRect(1, H, W, 1, colors.blue)
  button("exit", 1, H, 10, 1, "\27 Zurueck", colors.blue, colors.white)
end

local function renderGame()
  clearCanvas(colors.lightBlue)

  -- Kopfzeile
  fillRect(1, 1, W, 1, colors.blue)
  text(2, 1, "Lv" .. level, colors.white, colors.blue)
  centerText(1, tostring(score), colors.yellow, colors.blue)
  local ammo = ("\7"):rep(shots)
  text(W - #ammo, 1, ammo, colors.white, colors.blue)

  -- Boden, Katapult
  fillRect(1, GROUND, W, 1, colors.green)
  set(4, GROUND - 1, "|", colors.brown)
  set(4, GROUND - 2, "Y", colors.brown)

  -- Bloecke und Wabbel
  for y = TOP, GROUND - 1 do
    for x = 1, W do
      local o = grid[y][x]
      if o then
        if o.t == "o" then
          set(x, y, "\2", colors.purple)
        else
          local T = TYPES[o.t]
          set(x, y, o.hp < T.hp and T.hurt or T.full, T.fg, T.bg)
        end
      end
    end
  end

  -- Zielhilfe: die ersten Punkte der Flugbahn
  if phase == "aim" then
    local a = math.rad(aimAngle)
    local sp = aimPower * MAX_PULL * SPEED_PER_PULL
    local x, y = REST_X, REST_Y
    local vx, vy = math.cos(a) * sp, -math.sin(a) * sp
    local dots = 0
    for i = 1, 60 do
      local h = 0.02
      vy = vy + GRAVITY * h
      x, y = x + vx * h, y + vy * h
      local cx, cy = math.floor(x), math.floor(y)
      if cy >= GROUND or x < 1 or x >= W + 1 or objAt(cx, cy) then break end
      if i % 4 == 0 then
        if cy >= TOP then set(cx, cy, "\7", colors.white) end
        dots = dots + 1
        if dots >= 5 then break end
      end
    end
    if shots > 0 then set(4, GROUND - 3, "\7", colors.black) end
  end

  -- Stein im Flug
  if proj then
    local px, py = math.floor(proj.x), math.floor(proj.y)
    if py >= TOP then
      set(px, py, "\7", colors.black)
    else
      set(px, TOP, "^", colors.black) -- ueber dem Bildrand
    end
  end

  -- Infozeile
  fillRect(1, H - 1, W, 1, colors.brown)
  if phase == "aim" then
    text(2, H - 1, ("Winkel %d\176  Kraft %d%%"):format(aimAngle, math.floor(aimPower * 100 + 0.5)),
      colors.white, colors.brown)
  else
    text(2, H - 1, "Wabbel uebrig: " .. countBlobs(), colors.white, colors.brown)
  end

  -- Fusszeile
  fillRect(1, H, W, 1, colors.blue)
  button("menu", 1, H, 9, 1, "\27 Level", colors.blue, colors.white)
  button("retry", W - 9, H, 10, 1, "Neustart", colors.blue, colors.white)

  -- Ergebnis-Fenster
  if phase == "won" or phase == "lost" then
    fillRect(4, 6, W - 6, 8, colors.white)
    if phase == "won" then
      centerText(7, "Geschafft!", colors.green, colors.white)
      local s = ("*"):rep(lastStars) .. ("."):rep(3 - lastStars)
      centerText(9, s, colors.orange, colors.white)
      centerText(10, "Punkte: " .. score, colors.black, colors.white)
      if level < #LEVELS then
        button("next", 5, 12, 9, 1, "Weiter", colors.green, colors.white)
      else
        button("menu", 5, 12, 9, 1, "Levels", colors.green, colors.white)
      end
      button("retry", W - 12, 12, 9, 1, "Nochmal", colors.gray, colors.white)
    else
      centerText(7, "Daneben!", colors.red, colors.white)
      centerText(9, "Noch " .. countBlobs() .. " Wabbel", colors.black, colors.white)
      button("retry", 5, 12, 9, 1, "Nochmal", colors.green, colors.white)
      button("menu", W - 12, 12, 9, 1, "Levels", colors.gray, colors.white)
    end
  end
end

local function render()
  if phase == "menu" then renderMenu() else renderGame() end
  present()
end

------------------------------------------------------------------------
-- Eingabe
------------------------------------------------------------------------
local function clampAim()
  aimAngle = math.max(-20, math.min(85, aimAngle))
  aimPower = math.max(0.1, math.min(1, aimPower))
end

-- Ziehen wie an einer Schleuder: nach links unten ziehen = nach rechts oben werfen
local function aimFrom(mx, my)
  local dx, dy = aimStartX - mx, my - aimStartY
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.5 then return end
  dragged = true
  aimPower = math.min(1, len / MAX_PULL)
  aimAngle = math.floor(math.deg(atan2(dy, dx)) + 0.5)
  clampAim()
end

local running = true

local function onButton(id)
  if id == "exit" then
    running = false
  elseif id == "menu" then
    phase = "menu"
  elseif id == "retry" then
    loadLevel(level)
  elseif id == "next" then
    loadLevel(math.min(#LEVELS, level + 1))
  elseif type(id) == "string" and id:sub(1, 4) == "lvl:" then
    loadLevel(tonumber(id:sub(5)))
  end
end

local function handle(ev)
  local e = ev[1]
  local dirty = false

  if e == "terminate" then
    running = false
  elseif e == "mouse_click" then
    local id = hit(ev[3], ev[4])
    if id then
      onButton(id)
    elseif phase == "aim" and ev[4] >= TOP and ev[4] <= GROUND then
      aiming, dragged = true, false
      aimStartX, aimStartY = ev[3], ev[4]
    end
    dirty = true
  elseif e == "mouse_drag" and aiming then
    aimFrom(ev[3], ev[4])
    dirty = true
  elseif e == "mouse_up" and aiming then
    aiming = false
    aimFrom(ev[3], ev[4])
    if dragged and phase == "aim" then launch() end
    dirty = true
  elseif e == "char" and phase == "menu" then
    local n = tonumber(ev[2])
    if n and n >= 1 and n <= #LEVELS and n <= settings.get("pos.katapult.unlocked") then
      loadLevel(n)
      dirty = true
    end
  elseif e == "key" then
    local k = ev[2]
    if phase == "aim" then
      if k == keys.up then aimAngle = aimAngle + 3
      elseif k == keys.down then aimAngle = aimAngle - 3
      elseif k == keys.right then aimPower = aimPower + 0.05
      elseif k == keys.left then aimPower = aimPower - 0.05
      elseif k == keys.space or k == keys.enter then launch()
      end
      clampAim()
    elseif phase == "won" and k == keys.enter then
      onButton(level < #LEVELS and "next" or "menu")
    elseif phase == "lost" and k == keys.enter then
      onButton("retry")
    end
    if k == keys.backspace then
      if phase == "menu" then running = false else phase = "menu" end
    end
    dirty = true
  end
  return dirty
end

------------------------------------------------------------------------
-- Test-Schnittstelle (nur fuer automatische Tests ausserhalb des Spiels)
------------------------------------------------------------------------
if TEST then
  local function copyGrid(g)
    local c = {}
    for y, row in pairs(g) do
      c[y] = {}
      for x, o in pairs(row) do c[y][x] = { t = o.t, hp = o.hp, fall = o.fall } end
    end
    return c
  end
  return {
    LEVELS = LEVELS,
    loadLevel = loadLevel,
    countBlobs = countBlobs,
    settleStep = settleStep,
    render = render,
    handle = handle,
    hit = hit,
    state = function()
      return { phase = phase, shots = shots, score = score, angle = aimAngle,
        power = aimPower, running = running, level = level, proj = proj }
    end,
    setPhase = function(p) phase = p end,
    tick = tick,
    snapshot = function()
      return { grid = copyGrid(grid), shots = shots, score = score, phase = phase }
    end,
    restore = function(s)
      grid, shots, score, phase = copyGrid(s.grid), s.shots, s.score, s.phase
      proj, tickCount, settleQuiet = nil, 0, 0
    end,
    shoot = function(angle, power)
      aimAngle, aimPower = angle, power
      launch()
      local guard = 0
      while phase == "fly" or phase == "settle" do
        tick()
        guard = guard + 1
        if guard > 5000 then error("Endlosschleife") end
      end
      return phase, countBlobs(), score
    end,
  }
end

------------------------------------------------------------------------
-- Hauptschleife
------------------------------------------------------------------------
phase = "menu"
level = 1
render()
local timer = os.startTimer(DT)

while running do
  local ev = { os.pullEventRaw() }
  local dirty = false
  if ev[1] == "timer" and ev[2] == timer then
    timer = os.startTimer(DT)
    if phase == "fly" or phase == "settle" then
      tick()
      dirty = true
    end
  else
    dirty = handle(ev)
  end
  if dirty and running then render() end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
