-- stot: push-to-talk dictation
-- Hold the hotkey, speak, release. Transcript is typed into the focused app.

-- ============================================================================
-- EDIT THIS to point at wherever you cloned the stot repo:
local REPO_ROOT = os.getenv("HOME") .. "/stot"
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
  state = new_state
  render_menubar()
end

local function uuid()
  local f = io.popen("uuidgen")
  local id = f:read("*l")
  f:close()
  return id
end

local function start_recording()
  if state ~= "idle" then return end
  set_state("recording")
  wav_path = "/tmp/stot-" .. uuid() .. ".wav"
  sox_task = hs.task.new(
    SOX_BIN,
    function() end,
    {"-d", "-r", "16000", "-c", "1", "-b", "16", wav_path}
  )
  sox_task:start()
end

local function transcribe_and_type()
  if state ~= "recording" then return end
  set_state("transcribing")

  if sox_task then
    sox_task:terminate()  -- SIGTERM; sox flushes the WAV header cleanly
    sox_task = nil
  end

  local captured_wav = wav_path
  wav_path = nil

  -- Give sox ~150ms to finalize the WAV file on disk before transcribing.
  hs.timer.doAfter(0.15, function()
    local dictate = hs.task.new(
      DICTATE_SCRIPT,
      function(exit_code, stdout, stderr)
        os.remove(captured_wav)
        if exit_code == 0 and stdout and #stdout > 0 then
          local trimmed = stdout:gsub("^%s+", ""):gsub("%s+$", "")
          if #trimmed > 0 then
            hs.eventtap.keyStrokes(trimmed)
          end
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
    start_recording()
  elseif not is_hotkey_down and hotkey_down then
    hotkey_down = false
    transcribe_and_type()
  end
  return false
end)
watcher:start()

hs.alert.show("stot dictation loaded", 1)
