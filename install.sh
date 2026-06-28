#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
WHISPER_DIR="$HOME/.local/share/whisper.cpp"
MODEL_NAME="small.en"
HAMMERSPOON_CONFIG="$HOME/.hammerspoon/init.lua"

say() { printf "\n\033[1;36m==>\033[0m %s\n" "$*"; }
die() { printf "\n\033[1;31merror:\033[0m %s\n" "$*" >&2; exit 1; }

# 1. Homebrew + deps
say "Checking Homebrew..."
command -v brew >/dev/null || die "Homebrew not installed. See https://brew.sh"

for pkg in sox cmake; do
  if ! brew list "$pkg" >/dev/null 2>&1; then
    say "Installing $pkg..."
    brew install "$pkg"
  fi
done

# 2. Clone whisper.cpp
if [[ ! -d "$WHISPER_DIR" ]]; then
  say "Cloning whisper.cpp into $WHISPER_DIR..."
  mkdir -p "$(dirname "$WHISPER_DIR")"
  git clone https://github.com/ggerganov/whisper.cpp "$WHISPER_DIR"
else
  say "whisper.cpp already present at $WHISPER_DIR (skipping clone)"
fi

# 3. Build with Core ML support
say "Building whisper.cpp with Core ML support..."
pushd "$WHISPER_DIR" >/dev/null
  cmake -B build -DWHISPER_COREML=1
  cmake --build build -j --config Release
popd >/dev/null

# 4. Download model
mkdir -p "$REPO_ROOT/models"
MODEL_BIN="$REPO_ROOT/models/ggml-$MODEL_NAME.bin"
if [[ ! -f "$MODEL_BIN" ]]; then
  say "Downloading $MODEL_NAME model..."
  pushd "$WHISPER_DIR" >/dev/null
    bash ./models/download-ggml-model.sh "$MODEL_NAME"
    cp "./models/ggml-$MODEL_NAME.bin" "$MODEL_BIN"
  popd >/dev/null
else
  say "Model already downloaded at $MODEL_BIN (skipping)"
fi

# 5. Generate Core ML companion model
# PyTorch + coremltools don't yet support Python 3.14, so we maintain an
# isolated venv on python3.11 just for the one-time conversion.
COREML_DIR="$REPO_ROOT/models/ggml-$MODEL_NAME-encoder.mlmodelc"
VENV="$REPO_ROOT/.venv-coreml"
if [[ ! -d "$COREML_DIR" ]]; then
  if ! command -v python3.11 >/dev/null; then
    say "Installing python@3.11 (needed for Core ML conversion)..."
    brew install python@3.11
  fi
  if [[ ! -d "$VENV" ]]; then
    say "Creating Core ML conversion venv at $VENV..."
    python3.11 -m venv "$VENV"
    "$VENV/bin/pip" install --upgrade pip
    "$VENV/bin/pip" install torch coremltools openai-whisper ane_transformers
  fi
  say "Generating Core ML model (one-time, several minutes)..."
  pushd "$WHISPER_DIR" >/dev/null
    PATH="$VENV/bin:$PATH" bash ./models/generate-coreml-model.sh "$MODEL_NAME"
    cp -R "./models/ggml-$MODEL_NAME-encoder.mlmodelc" "$COREML_DIR"
  popd >/dev/null
else
  say "Core ML model already present (skipping generation)"
fi

# 6. Link Hammerspoon config
mkdir -p "$HOME/.hammerspoon"
SRC="$REPO_ROOT/hammerspoon/init.lua"
if [[ -e "$HAMMERSPOON_CONFIG" && ! -L "$HAMMERSPOON_CONFIG" ]]; then
  say "Existing $HAMMERSPOON_CONFIG found (not a symlink)."
  read -r -p "Overwrite with t2s config? [y/N] " ans
  if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
    mv "$HAMMERSPOON_CONFIG" "${HAMMERSPOON_CONFIG}.t2s-backup.$(date +%s)"
    ln -s "$SRC" "$HAMMERSPOON_CONFIG"
  else
    say "Skipped. To install manually: ln -s '$SRC' '$HAMMERSPOON_CONFIG'"
  fi
elif [[ -L "$HAMMERSPOON_CONFIG" ]]; then
  say "Refreshing existing Hammerspoon symlink..."
  ln -sf "$SRC" "$HAMMERSPOON_CONFIG"
else
  ln -s "$SRC" "$HAMMERSPOON_CONFIG"
fi

cat <<'EOF'

✅ Install complete.

Next steps:
  1. brew install --cask hammerspoon   (if not installed)
  2. Open Hammerspoon once.
  3. System Settings → Privacy & Security: grant Hammerspoon access to
       Microphone, Accessibility, and Input Monitoring.
  4. Hammerspoon menu bar icon → Reload Config.
  5. Hold Right Option, speak, release. Text appears in the focused app.

Test the binary directly (sanity check):
  ~/.local/share/whisper.cpp/build/bin/whisper-cli \
    -m ./models/ggml-small.en.bin \
    -f ~/.local/share/whisper.cpp/samples/jfk.wav \
    --no-timestamps
EOF
