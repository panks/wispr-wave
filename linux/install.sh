#!/usr/bin/env bash
# WisprWave Linux installer: venv + models + systemd user service. No sudo —
# system packages (ydotool, wl-clipboard) are listed in README.md.
#
#   ./install.sh                # full install
#   ./install.sh --no-service   # skip systemd (containers, tests)
set -euo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
DATA="${WISPRWAVE_DATA:-$HOME/.local/share/wisprwave}"
MODELS="$DATA/models"
PARAKEET="sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
NO_SERVICE=0
[ "${1:-}" = "--no-service" ] && NO_SERVICE=1

mkdir -p "$MODELS"

# 1. Python env (uv bootstraps without python3-venv/pip)
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
[ -d "$DATA/venv" ] || uv venv "$DATA/venv"
uv pip install --python "$DATA/venv/bin/python" sherpa-onnx numpy

# 2. Models (downloaded only if missing)
if [ ! -d "$MODELS/$PARAKEET" ]; then
    echo "Downloading Parakeet model (~640MB)..."
    curl -L "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$PARAKEET.tar.bz2" \
        | python3 -c "import tarfile,sys; tarfile.open(fileobj=sys.stdin.buffer, mode='r|bz2').extractall('$MODELS', filter='data')"
fi
if [ ! -f "$MODELS/silero_vad.onnx" ]; then
    curl -L -o "$MODELS/silero_vad.onnx" \
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
fi

# 3. systemd user service (rewrites ExecStart to this checkout's path)
if [ "$NO_SERVICE" = 0 ]; then
    mkdir -p "$HOME/.config/systemd/user"
    sed "s|%h/code/wispr-wave/linux|$HERE|" "$HERE/wisprwave.service" \
        > "$HOME/.config/systemd/user/wisprwave.service"
    systemctl --user daemon-reload
    systemctl --user enable --now wisprwave
    echo "Done. Bind a hotkey to: $HERE/wisprwave toggle"
else
    echo "Done (service skipped). Daemon: $DATA/venv/bin/python $HERE/wisprwave_daemon.py serve"
fi
