#!/usr/bin/env python3
"""
WisprWave tray indicator — GNOME status-bar companion for the daemon.

Runs on the system python3 (needs python3-gi + gir1.2-ayatanaappindicator3-0.1
and the AppIndicator GNOME extension, enabled by default on Ubuntu). Talks to
the daemon over its Unix socket; polls status once a second. Deliberately a
separate process: if the tray dies, dictation keeps working.
"""

import fcntl
import json
import os
import shutil
import socket
import subprocess
import sys

try:
    import gi
    gi.require_version("Gtk", "3.0")
    try:
        gi.require_version("AyatanaAppIndicator3", "0.1")
        from gi.repository import AyatanaAppIndicator3 as AppIndicator
    except ValueError:
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3 as AppIndicator
    from gi.repository import Gtk, GLib
except (ImportError, ValueError) as e:
    print(f"tray needs GTK AppIndicator bindings: {e}\n"
          "install with: sudo apt install gir1.2-ayatanaappindicator3-0.1",
          file=sys.stderr)
    sys.exit(1)

RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
SOCKET_PATH = os.environ.get("WISPRWAVE_SOCKET", os.path.join(RUNTIME_DIR, "wisprwave.sock"))
UNITS = ["wisprwave", "wisprwave-tray"]

# WisprWave app icon with state badges, installed into the user's hicolor
# theme by install.sh (assets/tray/hicolor). Falls back to stock symbolic
# icons if the custom set isn't installed.
#
# NOTE: GNOME Shell caches panel icons by NAME — when the artwork changes,
# these names must change too (cache-bust), or users see stale icons until
# they log out.
ICONS = {
    "idle": "wisprwave-panel",
    "recording": "wisprwave-panel-recording",
    "finalizing": "wisprwave-panel-busy",
    "down": "wisprwave-panel-down",
}
FALLBACK_ICONS = {
    "idle": "audio-input-microphone-symbolic",
    "recording": "media-record-symbolic",
    "finalizing": "emblem-synchronizing-symbolic",
    "down": "microphone-sensitivity-muted-symbolic",
}


def daemon_cmd(cmd, timeout=0.5):
    """Send a command to the daemon; returns reply or None if unreachable."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(SOCKET_PATH)
        s.sendall(cmd.encode())
        return s.recv(4096).decode().strip()
    except OSError:
        return None
    finally:
        try:
            s.close()
        except Exception:
            pass


def systemctl(*args):
    return subprocess.run(["systemctl", "--user", *args],
                          capture_output=True, text=True)


class Tray:
    def __init__(self):
        self.icons = ICONS
        if not Gtk.IconTheme.get_default().has_icon(ICONS["idle"]):
            self.icons = FALLBACK_ICONS
        self.indicator = AppIndicator.Indicator.new(
            "wisprwave", self.icons["down"],
            AppIndicator.IndicatorCategory.APPLICATION_STATUS)
        self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.indicator.set_title("WisprWave")
        self.last_state = None
        self.build_menu()
        GLib.timeout_add(1000, self.poll)
        self.poll()

    def build_menu(self):
        menu = Gtk.Menu()

        self.status_item = Gtk.MenuItem(label="…")
        self.status_item.set_sensitive(False)
        menu.append(self.status_item)
        menu.append(Gtk.SeparatorMenuItem())

        self.toggle_item = Gtk.MenuItem(label="Toggle dictation")
        self.toggle_item.connect("activate", lambda *_: daemon_cmd("toggle"))
        menu.append(self.toggle_item)

        self.cancel_item = Gtk.MenuItem(label="Cancel recording")
        self.cancel_item.connect("activate", lambda *_: daemon_cmd("cancel"))
        menu.append(self.cancel_item)

        menu.append(Gtk.SeparatorMenuItem())

        # Checked = streaming (chunked commits during speech, fast stop).
        # Unchecked = single-pass decode at stop: best accuracy, wait grows
        # with dictation length.
        self.mode_item = Gtk.CheckMenuItem(label="Streaming mode (fast)")
        self.mode_item.set_active(daemon_cmd("mode") != "single")
        self._mode_handler = self.mode_item.connect("toggled", self.on_mode_toggled)
        menu.append(self.mode_item)

        # Paste keystroke. Shift+Insert works in terminals AND regular apps
        # (the daemon fills both clipboard and primary selection for it);
        # the others are escape hatches for apps that don't honor it.
        paste_root = Gtk.MenuItem(label="Paste method")
        paste_menu = Gtk.Menu()
        self.paste_items = {}
        self._paste_handlers = {}
        group = None
        for key, label in [("shift_insert", "Shift+Insert (universal)"),
                           ("ctrl_v", "Ctrl+V"),
                           ("ctrl_shift_v", "Ctrl+Shift+V (terminals)")]:
            item = Gtk.RadioMenuItem.new_with_label_from_widget(group, label)
            group = group or item
            self._paste_handlers[key] = item.connect(
                "toggled", self.on_paste_toggled, key)
            self.paste_items[key] = item
            paste_menu.append(item)
        paste_root.set_submenu(paste_menu)
        self.paste_root = paste_root
        menu.append(paste_root)

        # Decoding strategy. Beam costs ~nothing on this model and is
        # slightly more accurate on ambiguous audio; switching reloads the
        # model (~3s, daemon shows "loading").
        decode_root = Gtk.MenuItem(label="Decoding")
        decode_menu = Gtk.Menu()
        self.decoding_items = {}
        self._decoding_handlers = {}
        group = None
        for key, label in [("greedy", "Greedy (default)"),
                           ("beam", "Beam search (slightly more accurate)")]:
            item = Gtk.RadioMenuItem.new_with_label_from_widget(group, label)
            group = group or item
            self._decoding_handlers[key] = item.connect(
                "toggled", self.on_decoding_toggled, key)
            self.decoding_items[key] = item
            decode_menu.append(item)
        decode_root.set_submenu(decode_menu)
        self.decode_root = decode_root
        menu.append(decode_root)

        self.autostart_item = Gtk.CheckMenuItem(label="Run on startup")
        enabled = systemctl("is-enabled", "wisprwave").stdout.strip() == "enabled"
        self.autostart_item.set_active(enabled)
        self._autostart_handler = self.autostart_item.connect(
            "toggled", self.on_autostart_toggled)
        menu.append(self.autostart_item)

        menu.append(Gtk.SeparatorMenuItem())

        self.start_item = Gtk.MenuItem(label="Start daemon")
        self.start_item.connect(
            "activate", lambda *_: systemctl("restart", "wisprwave"))
        menu.append(self.start_item)

        quit_item = Gtk.MenuItem(label="Quit WisprWave")
        quit_item.connect("activate", self.on_quit)
        menu.append(quit_item)

        menu.show_all()
        self.indicator.set_menu(menu)

    def on_mode_toggled(self, item):
        daemon_cmd("mode streaming" if item.get_active() else "mode single")

    def on_paste_toggled(self, item, key):
        if item.get_active():
            daemon_cmd(f"paste {key}")

    def on_decoding_toggled(self, item, key):
        if item.get_active():
            daemon_cmd(f"decoding {key}")

    def _sync_settings(self, info):
        daemon_up = info is not None
        self.mode_item.set_sensitive(daemon_up)
        self.paste_root.set_sensitive(daemon_up)
        if not daemon_up:
            return
        active = info.get("mode") == "streaming"
        if active != self.mode_item.get_active():
            self.mode_item.handler_block(self._mode_handler)
            self.mode_item.set_active(active)
            self.mode_item.handler_unblock(self._mode_handler)
        paste = info.get("paste")
        item = self.paste_items.get(paste)
        if item is not None and not item.get_active():
            for k, it in self.paste_items.items():
                it.handler_block(self._paste_handlers[k])
            item.set_active(True)
            for k, it in self.paste_items.items():
                it.handler_unblock(self._paste_handlers[k])
        self.decode_root.set_sensitive(daemon_up)
        decoding = info.get("decoding")
        item = self.decoding_items.get(decoding)
        if item is not None and not item.get_active():
            for k, it in self.decoding_items.items():
                it.handler_block(self._decoding_handlers[k])
            item.set_active(True)
            for k, it in self.decoding_items.items():
                it.handler_unblock(self._decoding_handlers[k])

    def on_autostart_toggled(self, item):
        action = "enable" if item.get_active() else "disable"
        for unit in UNITS:
            systemctl(action, unit)

    def on_quit(self, *_):
        daemon_cmd("quit")
        if os.environ.get("INVOCATION_ID"):  # running under systemd
            systemctl("stop", "wisprwave", "wisprwave-tray")
        Gtk.main_quit()

    def set_state(self, state, status_text, label=""):
        if state != self.last_state:
            self.indicator.set_icon_full(self.icons[state], status_text)
            self.last_state = state
        self.indicator.set_label(label, "0:00")
        self.status_item.set_label(status_text)
        self.toggle_item.set_sensitive(state != "down")
        self.cancel_item.set_sensitive(state == "recording")
        self.start_item.set_sensitive(state == "down")

    def poll(self):
        info = None
        reply = daemon_cmd("info")
        if reply:
            try:
                info = json.loads(reply)
            except ValueError:
                info = None
        if info is None:
            self.set_state("down", "Daemon not running")
        elif info.get("state") == "recording":
            mins, rem = divmod(int(info.get("seconds", 0)), 60)
            self.set_state("recording",
                           "Recording — click Toggle or press your hotkey to stop",
                           f"{mins}:{rem:02d}")
        elif info.get("state") == "finalizing":
            self.set_state("finalizing", "Transcribing…")
        elif info.get("state") == "loading":
            self.set_state("finalizing", "Loading model…")
        else:
            self.set_state("idle", "Idle — ready to dictate")
        self._sync_settings(info)
        return True  # keep the GLib timer running


def acquire_single_instance_lock():
    """flock-based guard so a second tray (e.g. launched from the app grid
    while the systemd one runs) exits instead of showing a duplicate icon."""
    f = open(os.path.join(RUNTIME_DIR, "wisprwave-tray.lock"), "w")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return None
    f.write(str(os.getpid()))
    f.flush()
    return f


def main():
    if not shutil.which("systemctl"):
        print("tray requires systemd user session", file=sys.stderr)
        return 1
    lock = acquire_single_instance_lock()
    if lock is None:
        print("wisprwave tray is already running")
        return 0
    Tray()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
