-- t2s: push-to-talk dictation
-- Hold the hotkey, speak, release. Transcript is typed into the focused app.

-- ============================================================================
-- EDIT THIS to point at wherever you cloned the t2s repo:
local REPO_ROOT = os.getenv("HOME") .. "/t2s"
-- ============================================================================

local DICTATE_SCRIPT = REPO_ROOT .. "/bin/t2s-dictate.sh"
local SOX_BIN = "/opt/homebrew/bin/sox"  -- Apple Silicon brew path; use /usr/local/bin/sox on Intel Macs

-- CGEventFlag bit for the modifier key that triggers dictation.
-- Right Option = 0x00000040 (default; rarely used in normal typing).
-- Right Command = 0x00000010, Right Shift = 0x00000004, Right Control = 0x00002000.
local HOTKEY_FLAG = 0x00000040

local state = "idle"  -- idle | recording | transcribing
local sox_task = nil
local wav_path = nil
local hotkey_down = false

local function uuid()
  local f = io.popen("uuidgen")
  local id = f:read("*l")
  f:close()
  return id
end

local function start_recording()
  if state ~= "idle" then return end
  state = "recording"
  wav_path = "/tmp/t2s-" .. uuid() .. ".wav"
  hs.alert.show("● Listening", 0.5)
  sox_task = hs.task.new(
    SOX_BIN,
    function() end,
    {"-d", "-r", "16000", "-c", "1", "-b", "16", wav_path}
  )
  sox_task:start()
end

local function transcribe_and_type()
  if state ~= "recording" then return end
  state = "transcribing"

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
            hs.alert.show("✓", 0.3)
          end
        end
        state = "idle"
      end,
      {captured_wav}
    )
    dictate:start()
  end)
end

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

hs.alert.show("t2s dictation loaded", 1)
