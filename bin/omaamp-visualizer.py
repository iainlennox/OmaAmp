#!/usr/bin/env python3
"""OmaAmp <-> CAVA spectrum bridge.

Respects the same lifecycle philosophy as bin/omaamp-mpv.py: the Quickshell
plugin owns this process, drives it through stdin (one JSON command per line),
and reads normalized spectrum data on stdout (one compact JSON line per tick).

CAVA is the real-time audio analyser: it taps the PipeWire/PulseAudio output
monitor (the audio actually reaching your speakers — never the microphone) and
emits per-band magnitudes. This script wraps CAVA so the shell never has to:

  - write CAVA config files,
  - parse CAVA's raw byte stream,
  - or do per-frame envelope + peak-hold math, which is cheaper here (Python)
    than on the Qt side (the shell avoids per-frame allocations).

CAVA is an *optional* dependency. If it is not installed, this script prints a
single "unavailable" status line and exits 0 — the plugin hides the visualiser
cleanly instead of erroring or failing to start.

Audio never stops working without CAVA: the bridge and mpv are independent.

  omaamp-visualizer.py --bars <n> [--rate <hz>] [--runtime <dir>] [--source <s>]

stdout lines (newline-delimited JSON):
  {"type":"ready","bars":<n>}
  {"type":"unavailable","reason":<str>}            (once, then exit 0)
  {"type":"spectrum","v":[...],"p":[...]}          (periodic)
"""

import json
import os
import select
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

DEFAULT_BARS = 12
DEFAULT_RATE = 25.0

MAX_STDIN_LINE = 1 << 20  # cap on any single control command (1 MiB)


def log(msg):
    sys.stderr.write("[omaamp-vis] %s\n" % msg)
    sys.stderr.flush()


def emit(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def child_preexec():
    """Kill CAVA (SIGTERM) if this bridge process dies — even by SIGKILL.

    Matches mpv_preexec() in omaamp-mpv.py: without this, a hard-killed bridge
    orphans a CAVA still attached to the audio monitor.
    """
    try:
        import ctypes
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        libc.prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG
    except Exception:
        pass


def self_preexec():
    """Kill this bridge if the owning shell dies (hard fallback for SIGKILL)."""
    try:
        import ctypes
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        libc.prctl(1, signal.SIGTERM)
    except Exception:
        pass


def find_cava():
    return shutil.which("cava")


def verify_private_dir(d, create=True):
    """Ensure `d` is a real, non-symlink directory owned by us with 0700.

    If `create` is True and the dir does not exist, create it with
    `os.makedirs(exist_ok=True)` (which refuses to follow an existing symlink
    on the final component). We then re-verify ownership/mode so a pre-existing
    hostile directory is never trusted.
    """
    if create:
        try:
            os.makedirs(d, mode=0o700, exist_ok=True)
        except OSError as exc:
            log("could not create dir %s: %s" % (d, exc))
            return False
    try:
        st = os.lstat(d)
    except OSError:
        return False
    if not stat.S_ISDIR(st.st_mode) or os.path.islink(d):
        return False
    if st.st_uid != os.geteuid():
        log("refusing %s: not owned by us" % d)
        return False
    if st.st_mode & 0o077:
        try:
            os.chmod(d, 0o700)
        except OSError as exc:
            log("could not tighten %s: %s" % (d, exc))
            return False
    return True


def atomic_write_private(path, contents):
    """Create a file atomically with 0600, refusing to follow symlinks.

    `os.open(..., O_NOFOLLOW)` rejects opening a pre-existing symlink; the
    file is 0600 from the moment it is created, so no intermediate world-
    readable state exists.
    """
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    try:
        flags |= getattr(os, "O_NOFOLLOW", 0)
    except AttributeError:
        flags = flags  # best-effort on platforms without O_NOFOLLOW
    try:
        fd = os.open(path, flags, 0o600)
    except OSError as exc:
        log("could not open %s: %s" % (path, exc))
        return False
    try:
        os.write(fd, contents)
        os.fchmod(fd, 0o600)
        os.close(fd)
    except OSError as exc:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(path)
        except OSError:
            pass
        log("could not write %s: %s" % (path, exc))
        return False
    return True


def build_config(bars, runtime_dir):
    """Write a CAVA config that streams raw bars for our own rendering.

    `[input] method = pulse` attaches to the PulseAudio-compatible server
    (PipeWire's pipewire-pulse) and `source = auto` monitors the default output
    sink. `[output] method = raw` + `target = -` writes 8-bit bar values
    (0..255) straight to stdout, one `bars`-sized frame at a time.

    The config is created in a private, owner-verified directory with an
    atomic, no-follow, 0600 write.
    """
    conf = """\
[general]
bars = %d
framerate = 60
sleep_time = 0

[output]
method = raw
target = -
bit_format = 8bit
async = 0

[input]
method = pulse
source = auto
channels = 2

[smoothing]
noise_reduction = 0.5
""" % bars

    if not verify_private_dir(runtime_dir):
        return None
    cfg_path = os.path.join(runtime_dir, "omaamp-cava.conf")
    if not atomic_write_private(cfg_path, conf.encode("utf-8")):
        return None
    return cfg_path


def main():
    bars = DEFAULT_BARS
    rate = DEFAULT_RATE
    runtime_dir = os.path.join(
        (os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()), "omaamp"
    )
    min_source = ""
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--bars" and i + 1 < len(args):
            bars = int(args[i + 1]); i += 2
        elif args[i] == "--rate" and i + 1 < len(args):
            rate = float(args[i + 1]); i += 2
        elif args[i] == "--runtime" and i + 1 < len(args):
            runtime_dir = args[i + 1]; i += 2
        elif args[i] == "--source" and i + 1 < len(args):
            min_source = args[i + 1]; i += 2
        else:
            i += 1

    if bars < 1:
        bars = DEFAULT_BARS
    if rate <= 0:
        rate = DEFAULT_RATE

    # Die if the owning shell dies, so CAVA is torn down with us.
    try:
        import ctypes
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        libc.prctl(1, signal.SIGTERM)
    except Exception:
        pass

    cava = find_cava()
    if not cava:
        emit(json.dumps({"type": "unavailable", "reason": "cava"}))
        log("cava not found")
        return 0

    cfg_path = build_config(bars, runtime_dir)
    if not cfg_path:
        emit(json.dumps({"type": "unavailable", "reason": "config"}))
        log("could not create a private CAVA config")
        return 0
    command = [cava, "-p", cfg_path]
    if min_source:
        command += ["--source", min_source]

    try:
        proc = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            preexec_fn=child_preexec,
        )
    except OSError as exc:
        emit(json.dumps({"type": "unavailable", "reason": "spawn"}))
        log("could not spawn cava: %s" % exc)
        return 0

    # Brief grace period for CAVA to attach to the audio monitor. If it dies
    # immediately (no sink / wrong method), treat the analyser as unavailable.
    time.sleep(0.25)
    if proc.poll() is not None:
        emit(json.dumps({"type": "unavailable", "reason": "exit"}))
        log("cava exited immediately (%s)" % proc.returncode)
        return 0

    emit(json.dumps({"type": "ready", "bars": bars}))

    # Rolling byte buffer: CAVA writes `bars` bytes per frame, back to back.
    buf = bytearray()
    current = bytearray(bars)
    have_frame = [False] * bars
    stdin_buf = b""

    # Envelope + peak-hold per bar (0..1). Attack is instant (retro feel);
    # main bars recede to ~0 in ~0.55s, peaks linger ~2x longer.
    level = [0.0] * bars
    peak = [0.0] * bars
    main_decay = 1.0 / (0.55 * rate)
    peak_decay = 1.0 / (1.1 * rate)

    next_tick = time.time() + (1.0 / rate)
    running = True
    try:
        while running and proc.poll() is None:
            rlist, _, _ = select.select([sys.stdin, proc.stdout], [], [], 0.05)
            now = time.time()

            if proc.stdout in rlist:
                try:
                    chunk = proc.stdout.read1(4096)
                except Exception:
                    chunk = b""
                if chunk == b"":
                    break
                buf.extend(chunk)
                while len(buf) >= bars:
                    frame = buf[:bars]
                    del buf[:bars]
                    current[:] = frame
                    for idx in range(bars):
                        have_frame[idx] = True

            if sys.stdin in rlist:
                data = os.read(sys.stdin.fileno(), 4096)
                if not data:
                    break
                stdin_buf += data
                if len(stdin_buf) > MAX_STDIN_LINE:
                    log("stdin frame too large; dropping input")
                    stdin_buf = b""
                    continue
                while b"\n" in stdin_buf:
                    line, stdin_buf = stdin_buf.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        cmd = json.loads(line)
                    except Exception:
                        continue
                    if cmd.get("cmd") == "quit":
                        running = False

            if now >= next_tick:
                next_tick = now + (1.0 / rate)
                for idx in range(bars):
                    frame = (current[idx] / 255.0) if have_frame[idx] else 0.0
                    if frame >= level[idx]:
                        level[idx] = frame
                    else:
                        level[idx] = max(frame, level[idx] - main_decay)
                    if level[idx] >= peak[idx]:
                        peak[idx] = level[idx]
                    else:
                        peak[idx] = max(level[idx], peak[idx] - peak_decay)
                emit(json.dumps({"type": "spectrum", "v": level, "p": peak}))
    except KeyboardInterrupt:
        pass
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=2)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        try:
            if cfg_path and os.path.exists(cfg_path):
                os.unlink(cfg_path)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
