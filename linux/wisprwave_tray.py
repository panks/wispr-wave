#!/usr/bin/env python3
"""
WisprWave tray indicator — GNOME status-bar companion for the daemon.

Runs on the system python3 (needs python3-gi + gir1.2-ayatanaappindicator3-0.1
and the AppIndicator GNOME extension, enabled by default on Ubuntu). Talks to
the daemon over its Unix socket; polls status once a second. Deliberately a
separate process: if the tray dies, dictation keeps working.
"""

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

ICONS = {
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
        self.indicator = AppIndicator.Indicator.new(
            "wisprwave", ICONS["down"],
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
            self.indicator.set_icon_full(ICONS[state], status_text)
            self.last_state = state
        self.indicator.set_label(label, "0:00")
        self.status_item.set_label(status_text)
        self.toggle_item.set_sensitive(state != "down")
        self.cancel_item.set_sensitive(state == "recording")
        self.start_item.set_sensitive(state == "down")

    def poll(self):
        reply = daemon_cmd("status")
        if reply is None:
            self.set_state("down", "Daemon not running")
        elif reply.startswith("recording"):
            secs = reply.split()[-1].rstrip("s") if " " in reply else "0"
            try:
                mins, rem = divmod(int(float(secs)), 60)
                label = f"{mins}:{rem:02d}"
            except ValueError:
                label = ""
            self.set_state("recording", "Recording — click Toggle or press your hotkey to stop", label)
        elif reply == "finalizing":
            self.set_state("finalizing", "Transcribing…")
        else:
            self.set_state("idle", "Idle — ready to dictate")
        return True  # keep the GLib timer running


def main():
    if not shutil.which("systemctl"):
        print("tray requires systemd user session", file=sys.stderr)
        return 1
    Tray()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
