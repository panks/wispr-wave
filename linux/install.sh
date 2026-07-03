#!/usr/bin/env bash
# WisprWave Linux installer: venv + models + systemd user service. No sudo —
# system packages (ydotool, wl-clipboard) are listed in README.md.
#
#   ./install.sh                   # full install
#   ./install.sh --no-service      # skip systemd (containers, tests)
#   ./install.sh --keep-mic-awake  # also install the WirePlumber drop-in
#                                  # (mic naps only after 5 min idle; use if
#                                  # the start beep arrives late after breaks)
set -euo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
DATA="${WISPRWAVE_DATA:-$HOME/.local/share/wisprwave}"
MODELS="$DATA/models"
PARAKEET="sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
NO_SERVICE=0
KEEP_MIC_AWAKE=0
for arg in "$@"; do
    case "$arg" in
        --no-service) NO_SERVICE=1 ;;
        --keep-mic-awake) KEEP_MIC_AWAKE=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

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

# 3. systemd user services + desktop integration (paths rewritten to this checkout)
if [ "$NO_SERVICE" = 0 ]; then
    mkdir -p "$HOME/.config/systemd/user" "$HOME/.local/share/applications" \
             "$HOME/.local/share/icons/hicolor/256x256/apps" \
             "$HOME/.local/share/icons/hicolor/64x64/apps"
    sed "s|%h/code/wispr-wave/linux|$HERE|" "$HERE/wisprwave.service" \
        > "$HOME/.config/systemd/user/wisprwave.service"
    sed "s|%h/code/wispr-wave/linux|$HERE|" "$HERE/wisprwave-tray.service" \
        > "$HOME/.config/systemd/user/wisprwave-tray.service"
    sed "s|%h/code/wispr-wave/linux|$HERE|" "$HERE/wisprwave.desktop" \
        > "$HOME/.local/share/applications/wisprwave.desktop"
    cp "$HERE/assets/wisprwave-app.png" "$HOME/.local/share/icons/hicolor/256x256/apps/wisprwave-app.png"
    cp "$HERE/assets/wisprwave-app-64.png" "$HOME/.local/share/icons/hicolor/64x64/apps/wisprwave-app.png"
    cp -r "$HERE/assets/tray/hicolor/." "$HOME/.local/share/icons/hicolor/"
    # GNOME Shell extension: flicker-free clipboard + focused-window info.
    # Optional — the daemon falls back to wl-clipboard without it. Loads at
    # the NEXT login (Wayland can't hot-load extensions); enabling it in
    # gsettings now means no manual step after logging back in.
    EXT_UUID="wisprwave@panks.github.io"
    EXT_DIR="$HOME/.local/share/gnome-shell/extensions/$EXT_UUID"
    mkdir -p "$EXT_DIR"
    cp "$HERE/gnome-extension/$EXT_UUID/"* "$EXT_DIR/"
    gnome-extensions enable "$EXT_UUID" 2>/dev/null || true
    python3 - "$EXT_UUID" <<'PYEOF'
import ast, subprocess, sys
uuid = sys.argv[1]
cur = subprocess.run(["gsettings", "get", "org.gnome.shell", "enabled-extensions"],
                     capture_output=True, text=True).stdout.strip()
try:
    lst = ast.literal_eval(cur) if cur.startswith("[") else []
except (ValueError, SyntaxError):
    lst = []
if uuid not in lst:
    lst.append(uuid)
    subprocess.run(["gsettings", "set", "org.gnome.shell", "enabled-extensions", str(lst)])
PYEOF

    systemctl --user daemon-reload
    systemctl --user enable --now wisprwave
    if python3 -c "import gi; gi.require_version('AyatanaAppIndicator3','0.1')" 2>/dev/null \
    || python3 -c "import gi; gi.require_version('AppIndicator3','0.1')" 2>/dev/null; then
        systemctl --user enable --now wisprwave-tray
    else
        echo "NOTE: tray icon skipped — install its library first:"
        echo "        sudo apt install gir1.2-ayatanaappindicator3-0.1"
        echo "      then run: systemctl --user enable --now wisprwave-tray"
    fi
    echo "Done. Bind a hotkey to: $HERE/wisprwave toggle"
else
    echo "Done (service skipped). Daemon: $DATA/venv/bin/python $HERE/wisprwave_daemon.py serve"
fi

# Opt-in: slow-waking mics (typically USB, via kernel autosuspend) lose the
# race to the first word without a warm-up window. WisprWave's beep waits for
# real audio either way; this only makes the beep arrive fast during active
# dictation sessions. System-wide audio policy — hence not a default.
if [ "$KEEP_MIC_AWAKE" = 1 ]; then
    WP_DIR="$HOME/.config/wireplumber/wireplumber.conf.d"
    mkdir -p "$WP_DIR"
    if ! cmp -s "$HERE/99-wisprwave-mic-no-suspend.conf" "$WP_DIR/99-wisprwave-mic-no-suspend.conf"; then
        cp "$HERE/99-wisprwave-mic-no-suspend.conf" "$WP_DIR/"
        systemctl --user restart wireplumber 2>/dev/null || true
    fi
    echo "Installed WirePlumber mic keep-awake drop-in (5 min idle timeout)."
fi
