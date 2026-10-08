// WisprWave shell extension: a tiny session-bus D-Bus service running inside
// GNOME Shell. Everything here uses shell-internal APIs (St.Clipboard,
// global.display), so no focus tricks or phantom windows are needed — the
// things that make clipboard access painful for outside processes on Wayland.
//
// The WisprWave daemon probes for this service and falls back to wl-clipboard
// when it's absent, so the extension is an optional upgrade, not a dependency.

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const BUS_NAME = 'io.github.panks.WisprWave';
const OBJECT_PATH = '/io/github/panks/WisprWave';

const IFACE = `
<node>
  <interface name="${BUS_NAME}">
    <method name="SetClipboard">
      <arg type="s" direction="in" name="text"/>
      <arg type="b" direction="in" name="primary"/>
    </method>
    <method name="GetClipboard">
      <arg type="b" direction="in" name="primary"/>
      <arg type="s" direction="out" name="text"/>
    </method>
    <method name="GetFocusedWindow">
      <arg type="s" direction="out" name="wmClass"/>
    </method>
  </interface>
</node>`;

export default class WisprWaveExtension extends Extension {
    enable() {
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this);
        this._dbus.export(Gio.DBus.session, OBJECT_PATH);
        this._nameId = Gio.DBus.session.own_name(
            BUS_NAME, Gio.BusNameOwnerFlags.NONE, null, null);
    }

    disable() {
        if (this._nameId) {
            Gio.bus_unown_name(this._nameId);
            this._nameId = 0;
        }
        this._dbus?.unexport();
        this._dbus = null;
    }

    SetClipboard(text, primary) {
        const type = primary ? St.ClipboardType.PRIMARY : St.ClipboardType.CLIPBOARD;
        St.Clipboard.get_default().set_text(type, text);
    }

    // Async D-Bus method (GJS convention: <Name>Async gets the invocation)
    // because St.Clipboard reads are callback-based.
    GetClipboardAsync(params, invocation) {
        const [primary] = params;
        const type = primary ? St.ClipboardType.PRIMARY : St.ClipboardType.CLIPBOARD;
        St.Clipboard.get_default().get_text(type, (_clipboard, text) => {
            invocation.return_value(new GLib.Variant('(s)', [text ?? '']));
        });
    }

    GetFocusedWindow() {
        const win = global.display.focus_window;
        return win ? (win.get_wm_class() ?? '') : '';
    }
}
