-- stot: push-to-talk dictation
-- Hold the hotkey, speak, release. Transcript is typed into the focused app.

-- ============================================================================
-- EDIT THIS to point at wherever you cloned the stot repo:
local REPO_ROOT = os.getenv("HOME") .. "/personal/stot"
-- ============================================================================

local DICTATE_SCRIPT = REPO_ROOT .. "/bin/stot-dictate.sh"
local SOX_BIN = "/opt/homebrew/bin/sox"  -- Apple Silicon brew path; use /usr/local/bin/sox on Intel Macs

-- CGEventFlag bit for the modifier key that triggers dictation.
-- Right Option = 0x00000040 (default; rarely used in normal typing).
-- Right Command = 0x00000010, Right Shift = 0x00000004, Right Control = 0x00002000.
local HOTKEY_FLAG = 0x00000040

local state = "idle"  -- idle | recording | transcribing
local sox_task = nil
local wav_path = nil
local hotkey_down = false

-- ──────────────────────────────────────────────────────────────────────────
-- Menubar indicator
-- ──────────────────────────────────────────────────────────────────────────
-- Colors per state. Emoji glyph picked because Hammerspoon's menubar text
-- supports inline color via styled strings; using a single Unicode dot keeps
-- the menubar footprint small.
local STATE_GLYPHS = {
  idle         = {char = "●", color = {white = 0.55, alpha = 1.0}, tooltip = "stot — idle (hold Right Option to dictate)"},
  recording    = {char = "●", color = {red = 1.0, green = 0.15, blue = 0.15, alpha = 1.0}, tooltip = "stot — recording…"},
  transcribing = {char = "●", color = {red = 1.0, green = 0.75, blue = 0.0, alpha = 1.0}, tooltip = "stot — transcribing…"},
}

local menubar = hs.menubar.new()

local function render_menubar()
  if not menubar then return end
  local glyph = STATE_GLYPHS[state] or STATE_GLYPHS.idle
  menubar:setTitle(hs.styledtext.new(glyph.char, {
    color = glyph.color,
    font = {name = ".AppleSystemUIFont", size = 16},
  }))
  menubar:setTooltip(glyph.tooltip)
end

local function set_state(new_state)
  local old_state = state
  state = new_state
  render_menubar()
  if old_state ~= new_state then
    print(string.format("stot: state changed: %s -> %s", old_state, new_state))
  end
end

local function uuid()
  local f = io.popen("uuidgen")
  local id = f:read("*l")
  f:close()
  return id
end

local function start_recording()
  if state ~= "idle" then
    print(string.format("stot: start_recording ignored (state=%s)", state))
    return
  end
  set_state("recording")
  wav_path = "/tmp/stot-" .. uuid() .. ".wav"
  print(string.format("stot: starting recording to %s", wav_path))
  sox_task = hs.task.new(
    SOX_BIN,
    function(exit_code, stdout, stderr)
      if exit_code ~= 0 and exit_code ~= 15 then  -- 15 = SIGTERM (normal stop)
        print(string.format("stot: sox exited with code %d: %s", exit_code, stderr or ""))
      end
    end,
    {"-d", "-r", "16000", "-c", "1", "-b", "16", wav_path}
  )
  sox_task:start()
end

local function transcribe_and_type()
  if state ~= "recording" then
    print(string.format("stot: transcribe_and_type ignored (state=%s)", state))
    return
  end
  print("stot: stopping recording, starting transcription")
  set_state("transcribing")

  if sox_task then
    sox_task:terminate()  -- SIGTERM; sox flushes the WAV header cleanly
    sox_task = nil
  end

  local captured_wav = wav_path
  wav_path = nil

  -- Give sox ~150ms to finalize the WAV file on disk before transcribing.
  hs.timer.doAfter(0.15, function()
    print(string.format("stot: transcribing %s", captured_wav))
    local dictate = hs.task.new(
      DICTATE_SCRIPT,
      function(exit_code, stdout, stderr)
        os.remove(captured_wav)
        if exit_code == 0 and stdout and #stdout > 0 then
          local trimmed = stdout:gsub("^%s+", ""):gsub("%s+$", "")
          if #trimmed > 0 then
            print(string.format("stot: typing %d chars: %s", #trimmed, trimmed:sub(1, 50)))
            hs.eventtap.keyStrokes(trimmed)
          else
            print("stot: transcription empty (after trim)")
          end
        elseif exit_code ~= 0 then
          print(string.format("stot: dictate script failed (exit=%d): %s", exit_code, stderr or ""))
        else
          print("stot: transcription empty")
        end
        set_state("idle")
      end,
      {captured_wav}
    )
    dictate:start()
  end)
end

-- Click handler: toggle recording. Lets the user dictate hands-free from the
-- menubar in addition to the hold-to-talk hotkey.
local function toggle_recording_from_menubar()
  print(string.format("stot: menubar clicked (state=%s)", state))
  if state == "idle" then
    start_recording()
  elseif state == "recording" then
    transcribe_and_type()
  end
  -- If transcribing, ignore the click — wait for it to finish.
end

if menubar then
  menubar:setClickCallback(toggle_recording_from_menubar)
end
render_menubar()

local watcher = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
  local flags = event:getRawEventData().CGEventData.flags
  local is_hotkey_down = (flags & HOTKEY_FLAG) ~= 0

  if is_hotkey_down and not hotkey_down then
    hotkey_down = true
    print("stot: hotkey pressed")
    start_recording()
  elseif not is_hotkey_down and hotkey_down then
    hotkey_down = false
    print("stot: hotkey released")
    transcribe_and_type()
  end
  return false
end)

print("stot: starting eventtap watcher")
watcher:start()
if watcher:isEnabled() then
  print("stot: eventtap started successfully")
else
  print("stot: WARNING - eventtap failed to start! Check Accessibility permissions.")
end

-- Watchdog: auto-restart the eventtap if macOS disables it.
-- Checks every 5 seconds; if the watcher is stopped, restart it.
local watchdog_check_count = 0
local function ensure_watcher_running()
  watchdog_check_count = watchdog_check_count + 1
  if watcher and not watcher:isEnabled() then
    print(string.format("stot: [check #%d] eventtap was disabled, restarting...", watchdog_check_count))
    watcher:start()
    if watcher:isEnabled() then
      print("stot: eventtap restarted successfully")
      hs.alert.show("stot: auto-restarted", 1)
    else
      print("stot: WARNING - eventtap restart failed!")
    end
  end
end

local watchdog_timer = hs.timer.new(5, ensure_watcher_running)
watchdog_timer:start()
print("stot: watchdog timer started (checks every 5 seconds)")

hs.alert.show("stot dictation loaded", 1)
