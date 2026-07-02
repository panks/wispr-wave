#!/usr/bin/env bash
# WisprWave Linux uninstaller.
#
#   ./uninstall.sh                 # remove service + venv, keep models
#   ./uninstall.sh --purge         # also remove models (~640MB re-download)
#   ./uninstall.sh --no-service    # file cleanup only (containers, tests)
#
# Not removed: system packages (ydotool, wl-clipboard), the GNOME custom
# shortcut (Settings -> Keyboard), and the repo itself.
set -euo pipefail
DATA="${WISPRWAVE_DATA:-$HOME/.local/share/wisprwave}"
PURGE=0
NO_SERVICE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        --no-service) NO_SERVICE=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [ "$NO_SERVICE" = 0 ]; then
    systemctl --user disable --now wisprwave wisprwave-tray 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/wisprwave.service" \
          "$HOME/.config/systemd/user/wisprwave-tray.service"
    systemctl --user daemon-reload 2>/dev/null || true
    rm -f "$HOME/.local/share/applications/wisprwave.desktop" \
          "$HOME/.local/share/icons/hicolor/256x256/apps/"wisprwave*.png \
          "$HOME/.local/share/icons/hicolor/64x64/apps/"wisprwave*.png
    for size in 22x22 24x24 32x32 48x48; do
        rm -f "$HOME/.local/share/icons/hicolor/$size/status/"wisprwave-tray*.png \
              "$HOME/.local/share/icons/hicolor/$size/status/"wisprwave-panel*.png
    done
    echo "services and desktop entry removed"
fi

rm -rf "$DATA/venv"
echo "venv removed"

if [ "$PURGE" = 1 ]; then
    rm -rf "$DATA"
    echo "data dir removed ($DATA)"
else
    echo "models kept in $DATA/models (use --purge to remove)"
fi
