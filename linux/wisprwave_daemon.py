#!/usr/bin/env python3
"""
WisprWave Linux daemon — local, private push-to-toggle dictation.

Port of the WisprWave macOS app's dictation flow to Ubuntu/GNOME Wayland:

  toggle (GNOME shortcut -> `wisprwave toggle`)
    -> capture mic @16kHz (arecord/pw-record subprocess, no audio libs)
    -> Silero VAD finds phrase boundaries while you speak
    -> Parakeet TDT 0.6B int8 (sherpa-onnx) decodes committed chunks
       DURING recording; only the short tail is decoded after you stop
    -> text injected into the focused app via clipboard + Ctrl+V (ydotool)

Hybrid latency strategy (see repo discussion):
  - Short dictations (< ~10s of speech): one full-context decode at stop.
    Best quality, ~1-3s wait.
  - Long dictations: chunks are committed at VAD silences once >=10s of
    speech is uncommitted. Each commit re-feeds the last 2s of committed
    audio as left context and drops the duplicated tokens by timestamp,
    so boundary words keep acoustic context. Wait at stop stays ~1-2s
    regardless of dictation length. Cuts only happen at real pauses, so
    words are never split.

Usage:
  wisprwave_daemon.py serve            # run the daemon (systemd user unit)
  wisprwave_daemon.py toggle           # start/stop dictation (bind to hotkey)
  wisprwave_daemon.py start|stop|cancel|status|quit
  wisprwave_daemon.py test-wav FILE    # run the full pipeline on a wav file

The client subcommands only use the stdlib, so they run with the system
python3; `serve` needs the venv (numpy + sherpa-onnx).
"""

import ast
import json
import os
import sys
import shutil
import socket
import subprocess
import threading
import time
import logging

# ---------------------------------------------------------------------------
# Configuration (env-overridable)
# ---------------------------------------------------------------------------

RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
SOCKET_PATH = os.environ.get("WISPRWAVE_SOCKET", os.path.join(RUNTIME_DIR, "wisprwave.sock"))

DATA_DIR = os.path.expanduser(os.environ.get("WISPRWAVE_DATA", "~/.local/share/wisprwave"))
MODEL_DIR = os.environ.get(
    "WISPRWAVE_MODEL_DIR",
    os.path.join(DATA_DIR, "models", "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"),
)
VAD_MODEL = os.environ.get("WISPRWAVE_VAD_MODEL", os.path.join(DATA_DIR, "models", "silero_vad.onnx"))

SAMPLE_RATE = 16000
NUM_THREADS = int(os.environ.get("WISPRWAVE_THREADS", "4"))

# Decoding: "greedy" or "beam" (modified_beam_search, 4 paths). Measured on
# this model/CPU beam costs ~nothing (the encoder dominates TDT compute);
# gains are small on clean audio. Beam is also the prerequisite for hotword
# biasing. Env is the initial default; tray/CLI choice persists in settings.
DECODING_DEFAULT = os.environ.get("WISPRWAVE_DECODING", "greedy")
DECODING_CHOICES = ("greedy", "beam")

# Chunked-commitment tuning. Lower commit threshold = shorter tail at stop
# (less wait) but more chunk boundaries; 6s keeps the wait ~1-2s while each
# decode window (chunk + 2s context) stays large enough for good accuracy.
COMMIT_MIN_SEC = float(os.environ.get("WISPRWAVE_COMMIT_MIN_SEC", "6"))
CONTEXT_SEC = float(os.environ.get("WISPRWAVE_CONTEXT_SEC", "2.0"))
PAD_SEC = 0.25
# Tokens stamped within SEAM_SEC after a cut belong to the earlier chunk.
# Both sides of a seam test against the same absolute threshold, so no token
# can be emitted twice. Safe because cuts sit at the start of >=0.4s of
# VAD-confirmed silence: real next-utterance speech is always beyond it.
SEAM_SEC = 0.2
VAD_MIN_SILENCE = float(os.environ.get("WISPRWAVE_MIN_SILENCE", "0.4"))
VAD_WINDOW = 512  # samples per silero inference, fixed by the model

# Capture: stop grace period so trailing words aren't clipped
STOP_GRACE_SEC = 0.15

# Decode-window padding kept around VAD speech boundaries when trimming
# leading/trailing silence (silence costs ~0.2-0.4s of decode per second
# of audio on this class of CPU, so think-pauses are worth cutting).
TRIM_PAD_SEC = 0.3

# Injection
PASTE_COMBO = {
    # linux input-event codes, "<code>:<1=down|0=up>" (ctrl=29, shift=42,
    # v=47, insert=110)
    "shift_insert": ["42:1", "110:1", "110:0", "42:0"],
    "ctrl_v": ["29:1", "47:1", "47:0", "29:0"],
    "ctrl_shift_v": ["29:1", "42:1", "47:1", "47:0", "42:0", "29:0"],
}
# shift_insert is the default: GTK/Qt widgets, browsers, AND terminals all
# honor it, so no per-app combo switching is needed. Some terminals wire it
# to the primary selection rather than the clipboard, so inject_text() sets
# both buffers. Env var is the initial default; a choice made via the tray
# or `wisprwave paste ...` persists in settings.json and wins.
PASTE_METHOD = os.environ.get("WISPRWAVE_PASTE", "shift_insert")
PASTE_DELAY = 0.06
CLIPBOARD_RESTORE_DELAY = 0.5

SOUNDS_ENABLED = os.environ.get("WISPRWAVE_SOUNDS", "1") != "0"
SOUND_DIR = "/usr/share/sounds/freedesktop/stereo"
SOUND_START = os.path.join(SOUND_DIR, "audio-volume-change.oga")
SOUND_DONE = os.path.join(SOUND_DIR, "message.oga")

log = logging.getLogger("wisprwave")

SETTINGS_PATH = os.path.join(DATA_DIR, "settings.json")


def load_settings():
    try:
        with open(SETTINGS_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_settings(settings):
    os.makedirs(DATA_DIR, exist_ok=True)
    tmp = SETTINGS_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
    os.rename(tmp, SETTINGS_PATH)


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def play_sound(path):
    if not SOUNDS_ENABLED or not os.path.exists(path):
        return
    player = shutil.which("pw-play") or shutil.which("paplay")
    if player:
        try:
            subprocess.Popen([player, path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass


def notify(summary, body=""):
    if shutil.which("notify-send"):
        try:
            subprocess.Popen(
                ["notify-send", "--app-name=WisprWave", "--expire-time=3000", summary, body],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        except OSError:
            pass


_PUNCT = ".,!?;:"


MODEL_RELEASE_BASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"


def ensure_models():
    """First-run: download models if missing, so a packaged install can ship
    without 640MB of weights. Extracts to a temp dir then renames, so an
    interrupted download never leaves a half-usable model behind."""
    import tarfile
    import tempfile
    import urllib.request

    models_root = os.path.dirname(MODEL_DIR)
    os.makedirs(models_root, exist_ok=True)

    if not os.path.isdir(MODEL_DIR):
        name = os.path.basename(MODEL_DIR)
        url = f"{MODEL_RELEASE_BASE}/{name}.tar.bz2"
        log.info("model missing; downloading %s", url)
        notify("WisprWave", "First run: downloading speech model (~460MB)…")
        tmp = tempfile.mkdtemp(dir=models_root, prefix=".download-")
        try:
            with urllib.request.urlopen(url) as resp:
                with tarfile.open(fileobj=resp, mode="r|bz2") as tar:
                    tar.extractall(tmp, filter="data")
            os.rename(os.path.join(tmp, name), MODEL_DIR)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        notify("WisprWave", "Speech model ready")
        log.info("model downloaded")

    if not os.path.isfile(VAD_MODEL):
        log.info("VAD model missing; downloading")
        tmp_path = VAD_MODEL + ".part"
        urllib.request.urlretrieve(f"{MODEL_RELEASE_BASE}/silero_vad.onnx", tmp_path)
        os.rename(tmp_path, VAD_MODEL)


def normalize_join(parts):
    out = []
    for p in (p.strip() for p in parts if p and p.strip()):
        # Sentence-final punctuation at a chunk seam can be emitted by both
        # sides of the timestamp cutoff: strip it from the new piece, and if
        # the previous piece lacked it, attach one mark there instead.
        lead = ""
        while p and p[0] in _PUNCT:
            lead += p[0]
            p = p[1:].lstrip()
        if lead and out and out[-1][-1] not in _PUNCT:
            out[-1] += lead[0]
        if not p:
            continue
        # A chunk decoded without its left text can start lowercase right
        # after a committed sentence end; fix the casing at the seam.
        if out and out[-1][-1] in ".!?" and p[0].islower():
            p = p[0].upper() + p[1:]
        out.append(p)
    return " ".join(" ".join(out).split())


# ---------------------------------------------------------------------------
# Text injection: clipboard + Ctrl+V (like the macOS TextInjector), with a
# ydotool-type fallback when wl-clipboard is not installed.
# ---------------------------------------------------------------------------

# --- GNOME Shell extension bridge (see gnome-extension/) ------------------
# The extension sets/reads the clipboard from inside the shell — no phantom
# windows, no dock flicker. wl-clipboard has to create an invisible focused
# window per call because Mutter offers no data-control protocol. Probed per
# injection; everything falls back to wl-clipboard when it's absent.

EXT_BUS = "io.github.panks.WisprWave"
EXT_PATH = "/io/github/panks/WisprWave"


def _ext_call(method, *args):
    cmd = ["gdbus", "call", "--session", "--dest", EXT_BUS,
           "--object-path", EXT_PATH, "--method", f"{EXT_BUS}.{method}", *args]
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=2)
    except (subprocess.TimeoutExpired, OSError):
        return None
    return r.stdout.decode() if r.returncode == 0 else None


def _ext_probe():
    """Focused window's wm_class via the extension, or None if unavailable."""
    out = _ext_call("GetFocusedWindow")
    if out is None:
        return None
    try:
        val = ast.literal_eval(out.strip())
        return val[0] if isinstance(val, tuple) else str(val)
    except (ValueError, SyntaxError):
        return ""


def _read_buffer(primary=False, use_ext=False):
    if use_ext:
        out = _ext_call("GetClipboard", "true" if primary else "false")
        if out is None:
            return None
        try:
            val = ast.literal_eval(out.strip())
            text = val[0] if isinstance(val, tuple) else ""
            return text.encode() if text else None
        except (ValueError, SyntaxError):
            return None
    args = ["wl-paste", "--no-newline"] + (["--primary"] if primary else [])
    try:
        r = subprocess.run(args, capture_output=True, timeout=2)
        if r.returncode == 0:
            return r.stdout
    except (subprocess.TimeoutExpired, OSError):
        pass
    return None


def _write_buffer(data, primary=False, use_ext=False):
    if use_ext:
        text = (data or b"").decode(errors="replace")
        _ext_call("SetClipboard", text, "true" if primary else "false")
        return
    args = ["wl-copy"] + (["--primary"] if primary else [])
    if data is None:
        subprocess.run(args + ["--clear"], timeout=5)
    else:
        subprocess.run(args, input=data, timeout=5)


def inject_text(text, method=None):
    if not text.strip():
        return "nothing to inject"

    method = method if method in PASTE_COMBO else PASTE_METHOD
    combo = PASTE_COMBO.get(method, PASTE_COMBO["shift_insert"])
    have_clipboard = shutil.which("wl-copy") and shutil.which("wl-paste")

    focused = _ext_probe()
    use_ext = focused is not None
    if use_ext:
        log.info("clipboard via shell extension (focused: %s)", focused or "?")

    if not use_ext and not have_clipboard:
        # Fallback: type directly through uinput. Slower and ASCII-safest;
        # install wl-clipboard for the paste path.
        log.warning("wl-clipboard not found; falling back to `ydotool type`")
        r = subprocess.run(["ydotool", "type", "--key-delay", "4", "--", text],
                           capture_output=True, timeout=60)
        return "typed via ydotool" if r.returncode == 0 else f"ydotool type failed: {r.stderr.decode(errors='replace')[:200]}"

    # Terminals bind Shift+Insert to either the clipboard or the primary
    # selection depending on the emulator — feed both so it never matters.
    use_primary = method == "shift_insert"

    # 1. Save current buffers (text only; non-text content is not restored)
    old_clip = _read_buffer(use_ext=use_ext)
    old_primary = _read_buffer(primary=True, use_ext=use_ext) if use_primary else None

    # 2. Set the transcript
    _write_buffer(text.encode(), use_ext=use_ext)
    if use_primary:
        _write_buffer(text.encode(), primary=True, use_ext=use_ext)
    time.sleep(PASTE_DELAY)

    # 3. Paste keystroke through uinput (portal-free, survives suspend)
    r = subprocess.run(["ydotool", "key", *combo], capture_output=True, timeout=5)
    if r.returncode != 0:
        return f"ydotool key failed: {r.stderr.decode(errors='replace')[:200]}"

    # 4. Restore previous buffers after the target app has read the paste
    time.sleep(CLIPBOARD_RESTORE_DELAY)
    _write_buffer(old_clip, use_ext=use_ext)
    if use_primary:
        _write_buffer(old_primary, primary=True, use_ext=use_ext)
    return f"pasted via {method}" + (" [ext]" if use_ext else " [wl-clipboard]")


# ---------------------------------------------------------------------------
# Microphone capture via a CLI subprocess (no audio library needed).
# arecord first: it starts ~700ms faster than pw-record on this machine.
# ---------------------------------------------------------------------------

CAPTURE_CANDIDATES = [
    ["arecord", "-q", "-f", "S16_LE", "-r", str(SAMPLE_RATE), "-c", "1", "-t", "raw"],
    ["pw-record", "--raw", "--rate", str(SAMPLE_RATE), "--channels", "1", "--format", "s16", "-"],
    ["parec", "--format=s16le", f"--rate={SAMPLE_RATE}", "--channels=1", "--raw"],
]


def capture_command():
    for cmd in CAPTURE_CANDIDATES:
        if shutil.which(cmd[0]):
            return cmd
    raise RuntimeError("no capture tool found (need arecord, pw-record, or parec)")


class Capture:
    """Reads raw s16le mono PCM from a recorder subprocess into a queue."""

    def __init__(self, out_queue):
        self.q = out_queue
        self.proc = None
        self.thread = None
        self._stop = threading.Event()
        # Fired from the reader thread when the first chunk arrives — i.e.
        # when the mic is REALLY live. The start cue hangs off this so that
        # "speak after the beep" is reliable even on a cold mic.
        self.on_first_audio = None
        self.started_at = None

    def start(self):
        self.started_at = time.monotonic()
        self.proc = subprocess.Popen(
            capture_command(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
        )
        self.thread = threading.Thread(target=self._reader, daemon=True)
        self.thread.start()

    def _reader(self):
        stdout = self.proc.stdout
        first = True
        while True:
            data = stdout.read(4096)
            if not data:
                break
            if first:
                first = False
                log.info("mic live %.0fms after capture start",
                         (time.monotonic() - self.started_at) * 1000)
                if self.on_first_audio:
                    try:
                        self.on_first_audio()
                    except Exception:
                        log.exception("on_first_audio callback failed")
            self.q.put(data)
        self.q.put(None)  # sentinel: capture finished

    def stop(self):
        # Grace period so the tail of the last word lands in the pipe,
        # then terminate and let the reader drain to EOF.
        time.sleep(STOP_GRACE_SEC)
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
        if self.thread:
            self.thread.join(timeout=3)


# ---------------------------------------------------------------------------
# ASR engine (loaded once, kept warm)
# ---------------------------------------------------------------------------

class Engine:
    def __init__(self, decoding="greedy"):
        import sherpa_onnx  # lazy: client subcommands don't need it

        self._sherpa = sherpa_onnx
        self.decoding = decoding if decoding in DECODING_CHOICES else "greedy"
        t0 = time.monotonic()
        self.recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=os.path.join(MODEL_DIR, "encoder.int8.onnx"),
            decoder=os.path.join(MODEL_DIR, "decoder.int8.onnx"),
            joiner=os.path.join(MODEL_DIR, "joiner.int8.onnx"),
            tokens=os.path.join(MODEL_DIR, "tokens.txt"),
            num_threads=NUM_THREADS,
            sample_rate=SAMPLE_RATE,
            feature_dim=80,
            decoding_method="modified_beam_search" if self.decoding == "beam"
                            else "greedy_search",
            max_active_paths=4,
            model_type="nemo_transducer",
        )
        log.info("model loaded in %.2fs (%s decoding)",
                 time.monotonic() - t0, self.decoding)

        # Warmup so the first real dictation doesn't pay one-time graph costs
        import numpy as np
        self.decode(np.zeros(SAMPLE_RATE // 2, dtype=np.float32))
        log.info("warmup decode done")

    def new_vad(self):
        cfg = self._sherpa.VadModelConfig()
        cfg.silero_vad.model = VAD_MODEL
        cfg.silero_vad.threshold = 0.5
        cfg.silero_vad.min_silence_duration = VAD_MIN_SILENCE
        cfg.silero_vad.min_speech_duration = 0.25
        cfg.silero_vad.max_speech_duration = 20
        cfg.sample_rate = SAMPLE_RATE
        return self._sherpa.VoiceActivityDetector(cfg, buffer_size_in_seconds=300)

    def decode(self, samples):
        """Returns (text, tokens, timestamps). timestamps are seconds relative
        to the start of `samples`."""
        s = self.recognizer.create_stream()
        s.accept_waveform(SAMPLE_RATE, samples)
        self.recognizer.decode_stream(s)
        r = s.result
        tokens = list(getattr(r, "tokens", []) or [])
        stamps = list(getattr(r, "timestamps", []) or [])
        return r.text, tokens, stamps


# ---------------------------------------------------------------------------
# A dictation session: buffering, VAD-gated chunk commitment, finalize.
# ---------------------------------------------------------------------------

class Session:
    def __init__(self, engine, single_pass=False):
        import numpy as np
        self.np = np
        self.engine = engine
        # Single-pass mode: no mid-speech commits — one full-context decode
        # at stop. Best accuracy; wait grows with dictation length. VAD still
        # runs in both modes: it locates speech so decode windows can skip
        # leading/trailing silence (think-pauses are pure wasted decode).
        self.single_pass = single_pass
        self.vad = engine.new_vad()
        self.speech_spans = []    # completed VAD segments: (start, end) samples
        self.chunks = []          # list of float32 arrays (full session audio)
        self.n_samples = 0
        self.vad_residual = np.zeros(0, dtype=np.float32)
        self.committed_end = 0    # sample index up to which text is committed
        self.parts = []           # committed text pieces
        self.commit_time = 0.0    # cumulative decode seconds spent during speech
        self.cancelled = False

    # -- audio ingestion ----------------------------------------------------

    def feed_bytes(self, data):
        np = self.np
        if len(data) % 2:
            data = data[:-1]
        samples = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0
        self.chunks.append(samples)
        self.n_samples += len(samples)
        self._feed_vad(samples)

    def _feed_vad(self, samples):
        np = self.np
        buf = np.concatenate([self.vad_residual, samples])
        pos = 0
        while pos + VAD_WINDOW <= len(buf):
            self.vad.accept_waveform(buf[pos:pos + VAD_WINDOW])
            pos += VAD_WINDOW
        self.vad_residual = buf[pos:]

        while not self.vad.empty():
            seg = self.vad.front
            seg_end = seg.start + len(seg.samples)
            self.vad.pop()
            self.speech_spans.append((seg.start, seg_end))
            if not self.single_pass:
                self._maybe_commit(seg_end)

    # -- chunk commitment ---------------------------------------------------

    def _audio(self):
        np = self.np
        if len(self.chunks) > 1:
            self.chunks = [np.concatenate(self.chunks)]
        return self.chunks[0] if self.chunks else np.zeros(0, dtype=np.float32)

    def _decode_window(self, start, end, drop_context, keep_until=None):
        """Decode audio[start:end]. If drop_context, discard tokens stamped at
        or before the previous seam (that audio was re-fed as left context
        only). If keep_until is set (sample index), discard tokens stamped
        past that seam — the pad beyond it is right-context only; the next
        chunk owns that audio."""
        audio = self._audio()
        window = audio[start:end]
        if len(window) < SAMPLE_RATE // 4:
            return "", 0.0
        t0 = time.monotonic()
        text, tokens, stamps = self.engine.decode(window)
        dt = time.monotonic() - t0
        lo = None
        if drop_context and self.committed_end > start:
            lo = (self.committed_end - start) / SAMPLE_RATE + SEAM_SEC
        hi = None
        if keep_until is not None:
            hi = (keep_until - start) / SAMPLE_RATE + SEAM_SEC
        if lo is None and hi is None:
            return text.strip(), dt
        if tokens and stamps and len(tokens) == len(stamps):
            kept = [tok for tok, ts in zip(tokens, stamps)
                    if (lo is None or ts > lo) and (hi is None or ts <= hi)]
            return "".join(kept).strip(), dt
        return text.strip(), dt  # no timestamps: accept possible overlap

    def _maybe_commit(self, seg_end):
        if seg_end <= self.committed_end:
            return
        uncommitted_sec = (seg_end - self.committed_end) / SAMPLE_RATE
        if uncommitted_sec < COMMIT_MIN_SEC:
            return
        start = max(0, self.committed_end - int(CONTEXT_SEC * SAMPLE_RATE))
        start = self._trim_leading(start)
        end = min(self.n_samples, seg_end + int(PAD_SEC * SAMPLE_RATE))
        piece, dt = self._decode_window(start, end, drop_context=True,
                                        keep_until=seg_end)
        self.commit_time += dt
        if piece:
            self.parts.append(piece)
        self.committed_end = seg_end
        log.info("committed %.1fs..%.1fs in %.2fs: %r",
                 start / SAMPLE_RATE, seg_end / SAMPLE_RATE, dt, piece[:80])

    # -- silence trimming ---------------------------------------------------

    def _trim_leading(self, start):
        """Skip silence before the first detected speech (nothing is committed
        yet, so the window start is free to move forward)."""
        if self.committed_end == 0 and self.speech_spans:
            speech_start = self.speech_spans[0][0] - int(TRIM_PAD_SEC * SAMPLE_RATE)
            return max(start, min(speech_start, self.n_samples))
        return start

    def _vad_in_speech(self):
        """Whether the VAD currently has an open (uncompleted) speech segment.
        Conservative default: if the binding can't tell us, assume speech so
        the tail is never trimmed away."""
        checker = getattr(self.vad, "is_speech_detected", None)
        if callable(checker):
            try:
                return bool(checker())
            except Exception:
                return True
        return True

    # -- finalize -----------------------------------------------------------

    def finalize(self):
        """Decode whatever is left past the last commit; returns final text."""
        if self.cancelled:
            return ""
        start = max(0, self.committed_end - int(CONTEXT_SEC * SAMPLE_RATE))
        start = self._trim_leading(start)
        end = self.n_samples
        # Trailing-silence trim: only when the last speech closed as a VAD
        # segment (no open segment = nothing being said) and the silent tail
        # is big enough to be worth cutting.
        if self.speech_spans:
            tail_silence = self.n_samples - self.speech_spans[-1][1]
            if tail_silence > SAMPLE_RATE and not self._vad_in_speech():
                end = min(end, self.speech_spans[-1][1] + int(TRIM_PAD_SEC * SAMPLE_RATE))
        piece, dt = self._decode_window(start, end,
                                        drop_context=self.committed_end > 0)
        log.info("final tail decode (%.1fs..%.1fs of %.1fs) took %.2fs",
                 start / SAMPLE_RATE, end / SAMPLE_RATE,
                 self.n_samples / SAMPLE_RATE, dt)
        if piece:
            self.parts.append(piece)
        return normalize_join(self.parts)

    @property
    def seconds(self):
        return self.n_samples / SAMPLE_RATE


# ---------------------------------------------------------------------------
# Daemon: unix-socket command server driving sessions
# ---------------------------------------------------------------------------

class Daemon:
    def __init__(self):
        settings = load_settings()
        self.single_pass = bool(settings.get("single_pass", False))
        saved_paste = settings.get("paste_method")
        self.paste_method = saved_paste if saved_paste in PASTE_COMBO else PASTE_METHOD
        saved_decoding = settings.get("decoding")
        self.decoding = saved_decoding if saved_decoding in DECODING_CHOICES else DECODING_DEFAULT
        self.engine = Engine(decoding=self.decoding)
        log.info("mode: %s, paste: %s, decoding: %s",
                 "single_pass" if self.single_pass else "streaming",
                 self.paste_method, self.decoding)
        self.state = "idle"        # idle | recording | finalizing
        self.lock = threading.Lock()
        self.session = None
        self.capture = None
        self.queue = None
        self.proc_thread = None

    # -- session control ----------------------------------------------------

    def start_recording(self):
        import queue as queue_mod
        with self.lock:
            if self.state != "idle":
                return f"busy: {self.state}"
            self.state = "recording"
        self.session = Session(self.engine, single_pass=self.single_pass)
        self.queue = queue_mod.Queue()
        self.capture = Capture(self.queue)
        self.capture.on_first_audio = lambda: play_sound(SOUND_START)
        self.capture.start()
        self.proc_thread = threading.Thread(target=self._process_loop, daemon=True)
        self.proc_thread.start()
        log.info("recording started")
        return "recording"

    def _process_loop(self):
        while True:
            data = self.queue.get()
            if data is None:
                break
            try:
                self.session.feed_bytes(data)
            except Exception:
                log.exception("processing error")
        self._finalize()

    def stop_recording(self, cancelled=False):
        with self.lock:
            if self.state != "recording":
                return f"not recording: {self.state}"
            self.state = "finalizing"
        self.session.cancelled = cancelled
        threading.Thread(target=self.capture.stop, daemon=True).start()
        return "finalizing" if not cancelled else "cancelled"

    def _finalize(self):
        try:
            text = self.session.finalize()
            secs = self.session.seconds
            if text:
                outcome = inject_text(text, self.paste_method)
                play_sound(SOUND_DONE)
                log.info("session %.1fs -> %d chars (%s): %r",
                         secs, len(text), outcome, text[:120])
            else:
                if not self.session.cancelled:
                    notify("WisprWave", "No speech detected")
                log.info("session %.1fs -> no text", secs)
        except Exception as e:
            log.exception("finalize failed")
            notify("WisprWave error", str(e)[:200])
        finally:
            with self.lock:
                self.state = "idle"
            self.session = None

    # -- commands -----------------------------------------------------------

    def handle(self, cmd):
        if cmd == "toggle":
            with self.lock:
                state = self.state
            if state == "idle":
                return self.start_recording()
            if state == "recording":
                return self.stop_recording()
            return "busy: finalizing"
        if cmd == "start":
            return self.start_recording()
        if cmd == "stop":
            return self.stop_recording()
        if cmd == "cancel":
            return self.stop_recording(cancelled=True)
        if cmd == "status":
            with self.lock:
                if self.state == "recording" and self.session:
                    return f"recording {self.session.seconds:.1f}s"
                return self.state
        if cmd == "mode" or cmd.startswith("mode "):
            arg = cmd[5:].strip()
            if arg in ("single", "streaming"):
                self.single_pass = arg == "single"
                settings = load_settings()
                settings["single_pass"] = self.single_pass
                save_settings(settings)
                log.info("mode set to %s", arg)
            elif arg:
                return "usage: mode [single|streaming]"
            return "single" if self.single_pass else "streaming"
        if cmd == "paste" or cmd.startswith("paste "):
            arg = cmd[6:].strip()
            if arg in PASTE_COMBO:
                self.paste_method = arg
                settings = load_settings()
                settings["paste_method"] = arg
                save_settings(settings)
                log.info("paste method set to %s", arg)
            elif arg:
                return f"usage: paste [{'|'.join(PASTE_COMBO)}]"
            return self.paste_method
        if cmd == "decoding" or cmd.startswith("decoding "):
            arg = cmd[9:].strip()
            if arg in DECODING_CHOICES and arg != self.decoding:
                # Rebuilding the recognizer takes ~2-3s; gate on idle and do
                # it off the socket thread so the tray keeps polling.
                with self.lock:
                    if self.state != "idle":
                        return f"busy: {self.state}"
                    self.state = "loading"
                self.decoding = arg
                settings = load_settings()
                settings["decoding"] = arg
                save_settings(settings)
                threading.Thread(target=self._rebuild_engine, daemon=True).start()
                log.info("decoding set to %s (reloading model)", arg)
            elif arg and arg not in DECODING_CHOICES:
                return f"usage: decoding [{'|'.join(DECODING_CHOICES)}]"
            return self.decoding
        if cmd == "info":
            with self.lock:
                seconds = self.session.seconds if (
                    self.state == "recording" and self.session) else 0.0
            return json.dumps({
                "state": self.state,
                "seconds": round(seconds, 1),
                "mode": "single" if self.single_pass else "streaming",
                "paste": self.paste_method,
                "decoding": self.decoding,
            })
        if cmd == "quit":
            threading.Thread(target=lambda: (time.sleep(0.2), os._exit(0)), daemon=True).start()
            return "bye"
        return f"unknown command: {cmd}"

    def _rebuild_engine(self):
        try:
            self.engine = Engine(decoding=self.decoding)
        except Exception as e:
            log.exception("engine rebuild failed")
            notify("WisprWave error", f"Model reload failed: {e}")
        finally:
            with self.lock:
                self.state = "idle"

    # -- socket server ------------------------------------------------------

    def serve(self):
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o600)
        srv.listen(4)
        log.info("listening on %s", SOCKET_PATH)
        notify("WisprWave", "Dictation daemon ready")
        while True:
            conn, _ = srv.accept()
            try:
                cmd = conn.recv(256).decode().strip()
                reply = self.handle(cmd) if cmd else "empty command"
                conn.sendall((reply + "\n").encode())
            except Exception:
                log.exception("client error")
            finally:
                conn.close()


# ---------------------------------------------------------------------------
# Client + test-wav mode
# ---------------------------------------------------------------------------

def client(cmd):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(SOCKET_PATH)
    except (FileNotFoundError, ConnectionRefusedError):
        print("wisprwave daemon is not running (systemctl --user start wisprwave)", file=sys.stderr)
        return 1
    s.sendall(cmd.encode())
    print(s.recv(4096).decode().strip())
    return 0


def read_wav_mono16k(path):
    import wave
    import numpy as np
    with wave.open(path) as w:
        assert w.getframerate() == SAMPLE_RATE and w.getnchannels() == 1, \
            "test wav must be 16kHz mono"
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype=np.int16)


def test_wav(path, single=False, beam=False):
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    engine = Engine(decoding="beam" if beam else DECODING_DEFAULT)
    session = Session(engine, single_pass=single)
    pcm = read_wav_mono16k(path)
    # feed in 100ms slices, as live capture would
    step = SAMPLE_RATE // 10
    for i in range(0, len(pcm), step):
        session.feed_bytes(pcm[i:i + step].tobytes())
    n_commits = len(session.parts)
    t0 = time.monotonic()
    text = session.finalize()
    tail = time.monotonic() - t0
    print(f"\naudio: {session.seconds:.1f}s")
    print(f"commits during speech: {n_commits}"
          f" (cumulative {session.commit_time:.2f}s decode)")
    print(f"perceived wait (tail decode at stop): {tail:.2f}s")
    print(f"text: {text}")
    return 0


def main():
    # Strip stray whitespace from args: hotkey dialogs (e.g. KDE's command
    # shortcuts) can smuggle a pasted trailing newline into argv.
    args = [a.strip() for a in sys.argv[1:] if a.strip()]
    if not args:
        print(__doc__)
        return 2
    cmd = args[0]
    if cmd == "serve":
        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
        try:
            ensure_models()
        except Exception as e:
            log.error("model download failed: %s", e)
            notify("WisprWave error", f"Model download failed: {e}")
            return 1
        Daemon().serve()
        return 0
    if cmd == "test-wav":
        return test_wav(args[1], single="single" in args[2:],
                        beam="beam" in args[2:])
    if cmd in ("mode", "paste", "decoding"):
        return client(" ".join(args))
    if cmd in ("toggle", "start", "stop", "cancel", "status", "info", "quit"):
        return client(cmd)
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
