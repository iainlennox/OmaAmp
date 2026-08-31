#!/usr/bin/env python3
"""OmaAmp <-> mpv JSON IPC bridge.

Owned by the OmaAmp Quickshell plugin. Spawns an `mpv` audio-only player,
connects to its JSON IPC unix socket, and relays:

  stdin (one JSON command per line) -> mpv
  mpv  -> stdout (one JSON status line per event, plus a 500ms tick while
          playing) so the shell can render progress and transport state.

Must only talk to localhost audio (no remote control surface). The script is
invoked as:

  omaamp-mpv.py --socket <sock> --volume <vol>
"""

import json
import os
import select
import signal
import subprocess
import sys
import time

MPV_ARGS = [
    "mpv", "--no-config", "--idle=yes", "--no-video",
    "--audio-display=no", "--no-terminal", "--force-window=no",
]


def log(msg):
    sys.stderr.write("[omaamp-mpv] %s\n" % msg)
    sys.stderr.flush()


def mpv_preexec():
    """Kill mpv (SIGTERM) if this bridge process dies — even by SIGKILL.

    Without this, a hard-killed bridge orphans an idle mpv that holds onto the
    IPC socket, leaving strays across shell restarts.
    """
    try:
        import ctypes
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        libc.prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG
    except Exception:
        pass


def send(sock, obj):
    try:
        sock.sendall((json.dumps(obj) + "\n").encode("utf-8"))
    except OSError as exc:
        log("send failed: %s" % exc)


def emit(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def main():
    sock_path = ""
    volume = "100"
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--socket" and i + 1 < len(args):
            sock_path = args[i + 1]; i += 2
        elif args[i] == "--volume" and i + 1 < len(args):
            volume = args[i + 1]; i += 2
        else:
            i += 1

    if not sock_path:
        log("no --socket given")
        return 2

    try:
        os.unlink(sock_path)
    except OSError:
        pass

    mpv_proc = subprocess.Popen(MPV_ARGS + ["--input-ipc-server=" + sock_path] +
                                ["--volume=" + volume],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, preexec_fn=mpv_preexec)

    sock = None
    state = {"time": 0.0, "duration": 0.0, "playing": False, "paused": False, "volume": 100, "muted": False, "idle": True}
    last_tick = 0.0
    observed = ["time-pos", "duration", "pause", "volume", "mute", "idle-active"]

    def emit_status():
        emit(json.dumps({"type": "status", "time": round(state["time"], 3), "duration": round(state["duration"], 3),
                         "playing": state["playing"], "paused": state["paused"], "volume": state["volume"],
                         "muted": state["muted"], "idle": state["idle"]}))

    def connect():
        nonlocal sock
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                s = __import__("socket").socket(__import__("socket").AF_UNIX, __import__("socket").SOCK_STREAM)
                s.connect(sock_path)
                sock = s
                break
            except OSError:
                time.sleep(0.2)
        if sock is None:
            log("could not connect to mpv socket")
            return False
        for idx, prop in enumerate(observed):
            send(sock, {"command": ["observe_property", idx + 1, prop]})
        return True

    if not connect():
        mpv_proc.terminate()
        return 1

    buf = b""

    def handle_mpv_line(line):
        nonlocal state, last_tick
        line = line.strip()
        if not line:
            return
        try:
            ev = json.loads(line)
        except Exception:
            return
        etype = ev.get("event")
        if etype == "file-loaded":
            state["playing"] = True
            state["paused"] = False
            state["idle"] = False
            emit_status()
        elif etype == "end-file":
            state["playing"] = False
            state["paused"] = False
            emit(json.dumps({"type": "event", "event": "end-file", "reason": ev.get("reason", "eof")}))
        elif etype == "property-change":
            name = ev.get("name")
            data = ev.get("data")
            if name == "time-pos":
                state["time"] = float(data) if isinstance(data, (int, float)) else 0.0
            elif name == "duration":
                state["duration"] = float(data) if isinstance(data, (int, float)) else 0.0
            elif name == "pause":
                state["paused"] = data is True
                state["playing"] = (data is not True) and not state["idle"]
            elif name == "volume":
                state["volume"] = int(data) if isinstance(data, (int, float)) else 0
            elif name == "mute":
                state["muted"] = data is True
            elif name == "idle-active":
                state["idle"] = data is True
                if data is True:
                    state["playing"] = False
                    state["paused"] = False
            emit_status()

    def handle_stdin_line(line):
        line = line.strip()
        if not line:
            return
        try:
            cmd = json.loads(line)
        except Exception:
            return
        op = cmd.get("cmd")
        if op == "loadfile":
            url = cmd.get("url", "")
            if url:
                send(sock, {"command": ["loadfile", url, "replace"]})
                start = cmd.get("start", 0)
                if start and start > 0:
                    send(sock, {"command": ["seek", start, "absolute"]})
        elif op == "set":
            send(sock, {"command": ["set_property", cmd.get("prop", ""), cmd.get("value")]})
        elif op == "seek":
            send(sock, {"command": ["seek", cmd.get("value", 0), "absolute"]})
        elif op == "volume":
            send(sock, {"command": ["set_property", "volume", cmd.get("value", 100)]})
        elif op == "stop":
            send(sock, {"command": ["stop"]})
        elif op == "quit":
            send(sock, {"command": ["quit"]})
            return False
        return True

    running = True
    try:
        while running and mpv_proc.poll() is None:
            rlist, _, _ = select.select([sys.stdin, sock], [], [], 0.25)
            now = time.time()
            if sys.stdin in rlist:
                data = os.read(sys.stdin.fileno(), 4096)
                if not data:
                    break
                for part in data.decode("utf-8", "replace").split("\n"):
                    if part.strip() and handle_stdin_line(part) is False:
                        running = False
                        break
            if sock in rlist:
                data = sock.recv(65536)
                if not data:
                    break
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    handle_mpv_line(line.decode("utf-8", "replace"))
            if state["playing"] and (now - last_tick) >= 0.5:
                last_tick = now
                emit_status()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            sock.close()
        except Exception:
            pass
        try:
            send_dummy = None
            mpv_proc.terminate()
            mpv_proc.wait(timeout=3)
        except Exception:
            try:
                mpv_proc.kill()
            except Exception:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
