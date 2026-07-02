# WisprWave for Linux

Local, private push-to-toggle dictation for Ubuntu/GNOME Wayland — a port of
the WisprWave macOS app's flow, tuned for low-power x86 (built and benchmarked
on an Intel N150).

- **Engine:** NVIDIA Parakeet TDT 0.6B v2 (int8) via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
- **Segmentation:** Silero VAD — chunks are only cut at real pauses, so words
  are never split across segments
- **Latency strategy:** hybrid. Short dictations get one full-context decode
  at stop (~2s). Long dictations are committed in ~6s chunks *while you speak*
  (each chunk decoded once, with 2s of re-fed left context reconciled by token
  timestamps), so the wait at stop stays ~3s flat regardless of length.
- **Injection:** clipboard save → `wl-copy` → paste keystroke via `ydotool`
  (kernel uinput — no Wayland portal dialogs, survives suspend) → clipboard
  restore. Default keystroke is **Shift+Insert**, which regular apps *and*
  terminals honor; the daemon fills both the clipboard and the primary
  selection so it works regardless of which buffer the terminal reads.
  Ctrl+V / Ctrl+Shift+V are selectable per taste (tray menu → Paste method,
  or `wisprwave paste ctrl_v|ctrl_shift_v|shift_insert`; persisted in
  settings.json). Falls back to `ydotool type` if wl-clipboard is missing.
- **Tray icon:** status-bar mic indicator (red + live timer while recording)
  with toggle/cancel, a "Streaming mode" switch, a "Paste method" submenu,
  a "Run on startup" switch, and quit.
- **Two transcription modes:** streaming (default — chunked commits, fast
  flat wait) and single-pass (best accuracy: one full-context decode at stop;
  wait grows ~0.25s per second of speech). Switch from the tray menu or
  `wisprwave mode single|streaming`; the choice persists in
  `~/.local/share/wisprwave/settings.json`. Short dictations (under ~6s of
  speech) are identical in both modes.

## Requirements

Ubuntu 24.04+ (or similar) with GNOME on Wayland, systemd user session,
`python3` and `curl` (both preinstalled on Ubuntu).

| Package | Why | Needed? |
|---|---|---|
| `ydotool` | sends the paste keystroke through kernel uinput | required |
| `wl-clipboard` | clipboard save/set/restore around the paste | strongly recommended |
| `gir1.2-ayatanaappindicator3-0.1` | tray icon bindings for Python | optional — tray only; the legacy `gir1.2-appindicator3-0.1` also works and may already be present (e.g. installed alongside Handy) |
| `alsa-utils` *or* PipeWire tools | mic capture (`arecord`/`pw-record`/`parec`, first found wins) | preinstalled on Ubuntu |

Everything else is user-local: `install.sh` bootstraps
[uv](https://docs.astral.sh/uv/) into `~/.local/bin` if missing, creates a
private venv with `sherpa-onnx` + `numpy`, and the daemon downloads the
speech models (~460MB, one time) on first start if they aren't present.
Nothing outside `~/.local` and `~/.config` is written without sudo.

## Install

```bash
# 1. System packages + uinput access (the only sudo steps)
sudo apt install ydotool wl-clipboard gir1.2-ayatanaappindicator3-0.1
sudo usermod -aG input $USER        # uinput permission; log out/in (or reboot)
systemctl --user enable --now ydotool

# 2. App install (no sudo)
cd linux && ./install.sh
```

`install.sh` sets up the venv, fetches models if missing, installs the
`wisprwave` + `wisprwave-tray` systemd user services, the desktop entry, and
the app icon — then starts everything. It is idempotent: re-run it any time.
`./install.sh --no-service` skips the systemd/desktop steps (containers, CI).

**3. Bind a hotkey:** GNOME Settings → Keyboard → Custom Shortcuts → add a
shortcut whose command is:

```
/path/to/wispr-wave/linux/wisprwave toggle
```

Press once to start recording, again to stop; the text pastes into whatever
app has focus. Also available: `wisprwave cancel` (discard the current
recording), `wisprwave status`, and the same actions from the tray menu.
"Run on startup" in the tray menu controls whether both services start at
login (they do after install).

## Updating

```bash
git pull && cd linux && ./install.sh && systemctl --user restart wisprwave wisprwave-tray
```

## Uninstall

```bash
cd linux
./uninstall.sh            # stops/removes services, desktop entry, venv; keeps models
./uninstall.sh --purge    # also deletes ~/.local/share/wisprwave (incl. 640MB models)
```

Not removed automatically (one-time system setup, shared with other tools):
the apt packages, your `input` group membership, the ydotool user service,
uv in `~/.local/bin`, and the GNOME custom shortcut (delete it in Settings →
Keyboard).

## Configuration (environment variables, set in the systemd unit)

| Variable | Default | Meaning |
|---|---|---|
| `WISPRWAVE_MODEL_DIR` | `~/.local/share/wisprwave/models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8` | Parakeet model directory |
| `WISPRWAVE_THREADS` | 4 | decode threads |
| `WISPRWAVE_COMMIT_MIN_SEC` | 6 | speech seconds before chunked commitment engages |
| `WISPRWAVE_CONTEXT_SEC` | 2.0 | committed audio re-fed as left context |
| `WISPRWAVE_MIN_SILENCE` | 0.4 | pause length that closes a phrase |
| `WISPRWAVE_PASTE` | `shift_insert` | initial default only — a choice made via tray/CLI persists in settings.json and wins |
| `WISPRWAVE_SOUNDS` | 1 | start/done audio cues (freedesktop theme) |

## Troubleshooting

- `journalctl --user -u wisprwave -f` — daemon logs (commits, decode timings);
  `-u wisprwave-tray` for the tray
- Paste lands nowhere in some app: it probably doesn't honor Shift+Insert —
  switch Paste method in the tray menu (Ctrl+V for regular apps,
  Ctrl+Shift+V for terminals)
- Nothing types at all: check `systemctl --user status ydotool` and that your
  user is in the `input` group (`id`)
- No tray icon: install one of the `gir1.2-*appindicator3*` packages and make
  sure the AppIndicator GNOME extension is enabled (default on Ubuntu)
- Test the pipeline without a mic: `./wisprwave test-wav path/to/16k-mono.wav`

## Design notes

Why chunks never split words: cuts happen only where Silero VAD confirmed
≥0.4s of silence — a word cannot span a pause. The pathological no-pause case
force-splits at 20s (Silero's max-speech guard); the 2s left-context re-feed
means the next chunk still decodes the boundary with acoustic context.

Seam ownership: both sides of a cut filter tokens against the same absolute
threshold (cut + 0.2s, by token timestamp), so decoder pad regions can't
emit a token twice — that double-emission strip was the source of occasional
phantom words before it was partitioned.

Why not live preview like Handy: re-decoding the growing buffer every second
falls behind real time on N100 class CPUs (measured 0.63x RT at 23s of
audio, 17s post-stop backlog). Decoding each second of audio exactly once is
what keeps the daemon real-time.
