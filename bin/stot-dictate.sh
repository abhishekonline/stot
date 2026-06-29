#!/usr/bin/env bash
set -euo pipefail

# Hammerspoon spawns subprocesses with a minimal PATH that omits Homebrew.
# Make sure soxi and friends resolve.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

WAV="${1:-}"
if [[ -z "$WAV" || ! -f "$WAV" ]]; then
  echo "usage: stot-dictate.sh <wav-file>" >&2
  exit 2
fi

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &> /dev/null && pwd)"
WHISPER_BIN="${STOT_WHISPER_BIN:-$HOME/.local/share/whisper.cpp/build/bin/whisper-cli}"
MODEL="${STOT_MODEL:-$REPO_ROOT/models/ggml-small.en.bin}"

if [[ ! -x "$WHISPER_BIN" ]]; then
  echo "whisper-cli not found at $WHISPER_BIN" >&2
  exit 3
fi
if [[ ! -f "$MODEL" ]]; then
  echo "model not found at $MODEL" >&2
  exit 4
fi

# Skip the duration guard if soxi isn't on PATH; whisper.cpp tolerates short
# clips fine, the guard is just a perf optimization.
if command -v soxi >/dev/null 2>&1; then
  DURATION_MS="$(soxi -D "$WAV" 2>/dev/null | awk '{printf "%d\n", $1 * 1000}')"
  if [[ -n "$DURATION_MS" && "$DURATION_MS" -lt 300 ]]; then
    exit 0
  fi
fi

"$WHISPER_BIN" \
  -m "$MODEL" \
  -f "$WAV" \
  -l en \
  --no-timestamps \
  --no-prints \
  2>/dev/null \
  | tr '\n' ' ' \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]]\{2,\}/ /g'
