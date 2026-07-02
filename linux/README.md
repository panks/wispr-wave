# WisprWave for Linux

Local, private push-to-toggle dictation for Ubuntu/GNOME Wayland — a port of
the WisprWave macOS app's flow, tuned for low-power x86 (built and benchmarked
on an Intel N150).

- **Engine:** NVIDIA Parakeet TDT 0.6B v2 (int8) via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
- **Segmentation:** Silero VAD — chunks are only cut at real pauses, so words
  are never split across segments
- **Latency strategy:** hybrid. Short dictations get one full-context decode at
  stop (~1–3s). Long dictations are committed in ~10s chunks *while you speak*
  (each chunk decoded once, with 2s of re-fed left context reconciled by token
  timestamps), so the wait at stop stays ~1–2s regardless of length.
- **Injection:** clipboard save → `wl-copy` → Ctrl+V via `ydotool` (kernel
  uinput — no Wayland portal dialogs, survives suspend) → clipboard restore.
  Falls back to `ydotool type` if wl-clipboard is missing.

## Setup

System packages (the only sudo steps):

```bash
sudo apt install ydotool wl-clipboard          # uinput typing + clipboard
sudo usermod -aG input $USER                   # then log out/in (or reboot)
systemctl --user enable --now ydotool
```

App setup (no sudo):

```bash
./install.sh        # venv + models (~640MB download if not present) + service
```

`./install.sh --no-service` skips the systemd step (containers, tests). To
remove: `./uninstall.sh` (keeps the downloaded models), `./uninstall.sh
--purge` (removes everything under `~/.local/share/wisprwave`).

Bind a key: GNOME Settings → Keyboard → Custom Shortcuts → command:

```
/home/YOU/code/wispr-wave/linux/wisprwave toggle
```

Press once to start recording, again to stop; text pastes into the focused
app. `wisprwave cancel` discards a recording, `wisprwave status` reports state.

## Configuration (environment variables, set in the systemd unit)

| Variable | Default | Meaning |
|---|---|---|
| `WISPRWAVE_MODEL_DIR` | `~/.local/share/wisprwave/models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8` | Parakeet model directory |
| `WISPRWAVE_THREADS` | 4 | decode threads |
| `WISPRWAVE_COMMIT_MIN_SEC` | 6 | speech seconds before chunked commitment engages |
| `WISPRWAVE_CONTEXT_SEC` | 2.0 | committed audio re-fed as left context |
| `WISPRWAVE_MIN_SILENCE` | 0.4 | pause length that closes a phrase |
| `WISPRWAVE_PASTE` | `ctrl_v` | `ctrl_shift_v` for terminals |
| `WISPRWAVE_SOUNDS` | 1 | start/done audio cues (freedesktop theme) |

## Troubleshooting

- `journalctl --user -u wisprwave -f` — daemon logs (commits, decode timings)
- Paste lands nowhere: the focused app must accept Ctrl+V; for terminals set
  `WISPRWAVE_PASTE=ctrl_shift_v`
- Nothing types at all: check `systemctl --user status ydotool` and that your
  user is in the `input` group (`id`)
- Test the pipeline without a mic: `./wisprwave test-wav path/to/16k-mono.wav`

## Design notes

Why chunks never split words: cuts happen only where Silero VAD confirmed
≥0.4s of silence — a word cannot span a pause. The pathological no-pause case
force-splits at 20s (Silero's max-speech guard); the 2s left-context re-feed
means the next chunk still decodes the boundary with acoustic context.

Why not live preview like Handy: re-decoding the growing buffer every second
falls behind real time on this class of CPU (measured 0.63x RT at 23s of
audio, 17s post-stop backlog). Decoding each second of audio exactly once is
what keeps the daemon real-time.
