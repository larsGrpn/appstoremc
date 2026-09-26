-- radio.lua - 99drei Radio Mittweida auf CC:Tweaked-Speakern
--
-- Aufruf:  radio                      (nutzt DEFAULT_URL)
--          radio ws://1.2.3.4:8765/radio
-- Autostart: in startup.lua  ->  shell.run("radio")

local DEFAULT_URL = "ws://192.168.1.50:8765/radio" -- <- anpassen!
local VOLUME      = 1.0  -- 0.0 bis 3.0
local PREBUFFER   = 2    -- Chunks (je 1 s) puffern, bevor es losgeht
local MAX_QUEUE   = 6    -- mehr gepufferte Chunks -> aelteste verwerfen

local url = ({ ... })[1] or DEFAULT_URL
local dfpwm = require("cc.audio.dfpwm")

local function findSpeakers()
  local list = {}
  for _, sp in ipairs({ peripheral.find("speaker") }) do
    list[peripheral.getName(sp)] = { sp = sp, queue = {}, started = false }
  end
  return list
end

-- Schiebt so viele Chunks wie moeglich in den Speaker-Puffer.
local function feed(s)
  if not s.started then
    if #s.queue < PREBUFFER then return end
    s.started = true
  end
  while s.queue[1] do
    if s.sp.playAudio(s.queue[1], VOLUME) then
      table.remove(s.queue, 1)
    else
      break -- Speaker voll, weiter bei "speaker_audio_empty"
    end
  end
end

-- Eine Verbindung abspielen. Rueckgabe: verbunden?, Grund
local function play()
  local speakers = findSpeakers()
  if next(speakers) == nil then
    return false, "Kein Speaker gefunden"
  end

  print("Verbinde mit " .. url .. " ...")
  local ws, err = http.websocket(url)
  if not ws then return false, err end
  print("Verbunden. Strg+T zum Beenden.")

  local decoder = dfpwm.make_decoder()

  -- Eigene Event-Schleife statt ws.receive(): so gehen keine
  -- Nachrichten verloren, waehrend auf den Speaker gewartet wird.
  local ok, reason = pcall(function()
    while true do
      local ev = { os.pullEvent() }
      local name = ev[1]

      if name == "websocket_message" and ev[2] == url then
        local buffer = decoder(ev[3])
        for _, s in pairs(speakers) do
          s.queue[#s.queue + 1] = buffer
          while #s.queue > MAX_QUEUE do table.remove(s.queue, 1) end
          feed(s)
        end

      elseif name == "speaker_audio_empty" then
        local s = speakers[ev[2]]
        if s then feed(s) end

      elseif name == "websocket_closed" and ev[2] == url then
        error("Verbindung vom Server geschlossen", 0)

      elseif name == "peripheral" or name == "peripheral_detach" then
        -- Speaker an-/abgesteckt -> neu verbinden, Liste neu aufbauen
        error("Peripherie geaendert", 0)
      end
    end
  end)

  pcall(ws.close)
  for _, s in pairs(speakers) do pcall(s.sp.stop) end

  if reason == "Terminated" then error(reason, 0) end
  return true, reason
end

-- Hauptschleife mit Reconnect und Backoff
local delay = 2
while true do
  local connected, reason = play()
  printError(tostring(reason))
  if connected then delay = 2 end
  print(("Neuer Versuch in %d s ..."):format(delay))
  sleep(delay)
  delay = math.min(delay * 2, 30)
end
