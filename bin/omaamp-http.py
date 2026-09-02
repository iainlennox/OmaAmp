#!/usr/bin/env python3
"""OmaAmp <-> curl HTTP bridge.

The Quickshell shell cannot open raw network sockets, so Plex API requests go
through `curl`. Compared to shelling out to curl directly from QML, this wrapper:

  * keeps the Plex auth token out of the process command line (`argv`) and out
    of the request URL on the command line. The token is read from the plugin's
    on-disk config (0600) and handed to curl through a private, owner-verified,
    O_EXCL header file instead of as an argument.
  * enforces a hard byte cap on every API response, so an oversized or
    misbehaving Plex server cannot balloon the shell's memory.
  * reports curl spawn/failure/oversize conditions explicitly so the shell can
    surface a clean error instead of silently parsing truncated data.

Request (one JSON object per line on stdin):
  {"path": "/library/sections?X-Plex-...", "timeoutSeconds": 25}

Response (one JSON object on stdout):
  {"ok": true,  "body": "<raw response body>"}
  {"ok": false, "reason": "<reason>"}        missing-config | private-dir |
                                             token-file | bad-request |
                                             too-large | curl-spawn | curl-error
"""

import json
import os
import stat
import subprocess
import sys
import tempfile

CONFIG_PATH = os.path.expanduser("~/.config/omarchy/omaamp.json")
MAX_BODY = 20 * 1024 * 1024  # 20 MiB cap on any single API response


def log(msg):
    sys.stderr.write("[omaamp-http] %s\n" % msg)
    sys.stderr.flush()


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def load_config():
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def private_dir():
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    d = os.path.join(base, "omaamp")
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
    except OSError as exc:
        log("could not create %s: %s" % (d, exc))
        d = tempfile.mkdtemp(prefix="omaamp-", dir="/tmp")
    return d


def verify_private_dir(d):
    """The dir must exist, be a non-symlink directory owned by us with 0700."""
    try:
        st = os.lstat(d)
    except OSError:
        return False
    if not stat.S_ISDIR(st.st_mode) or os.path.islink(d):
        return False
    if st.st_uid != os.geteuid():
        return False
    if st.st_mode & 0o077:
        try:
            os.chmod(d, 0o700)
        except OSError:
            return False
    return True


def write_token_header(d, token):
    """Write the auth header to a private file. O_EXCL + O_NOFOLLOW so we
    never overwrite or traverse a pre-planted symlink; 0600 when created."""
    header_path = os.path.join(d, "token.%d.header" % os.getpid())
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    try:
        flags |= getattr(os, "O_NOFOLLOW", 0)
    except AttributeError:
        flags = flags  # O_NOFOLLOW is best-effort on platforms without it
    try:
        fd = os.open(header_path, flags, 0o600)
    except OSError as exc:
        log("could not create header file: %s" % exc)
        return None, None
    try:
        os.write(fd, ("X-Plex-Token: %s\n" % token).encode("utf-8"))
        os.fchmod(fd, 0o600)
        os.close(fd)
    except OSError as exc:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(header_path)
        except OSError:
            pass
        log("could not write header file: %s" % exc)
        return None, None
    return header_path, True


def run_request(cfg, path, header_path, timeout):
    server = str(cfg.get("server") or "").rstrip("/")
    if not server or not path:
        return {"ok": True, "body": ""}
    url = server + ("" if path.startswith("/") else "/") + path

    argv = [
        "curl", "-sS", "-m", str(timeout or 25), "--fail",
        "-H", "@" + header_path,
        "-H", "Accept: application/json",
        "-H", "X-Plex-Client-Identifier: OmaAmp",
        url,
    ]
    try:
        proc = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
        )
    except OSError as exc:
        return {"ok": False, "reason": "curl-spawn", "detail": str(exc)}

    body = bytearray()
    over = False
    while True:
        chunk = proc.stdout.read(65536)
        if not chunk:
            break
        body += chunk
        if len(body) > MAX_BODY:
            over = True
            proc.kill()
            break
    proc.wait()
    if over:
        return {"ok": False, "reason": "too-large"}
    if proc.returncode != 0:
        return {"ok": False, "reason": "curl-error", "code": proc.returncode}
    return {"ok": True, "body": body.decode("utf-8", "replace")}


def main():
    cfg = load_config()
    token = str(cfg.get("token") or "")
    if not token or not cfg.get("server"):
        emit({"ok": False, "reason": "missing-config"})
        return 1

    d = private_dir()
    if not verify_private_dir(d):
        emit({"ok": False, "reason": "private-dir"})
        return 0

    header_path, _ = write_token_header(d, token)
    if header_path is None:
        emit({"ok": False, "reason": "token-file"})
        return 0

    try:
        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            try:
                req = json.loads(raw)
            except Exception:
                emit({"ok": False, "reason": "bad-request"})
                continue
            path = req.get("path")
            if not isinstance(path, str):
                emit({"ok": False, "reason": "bad-request"})
                continue
            result = run_request(cfg, path, header_path, req.get("timeoutSeconds"))
            emit(result)
    finally:
        try:
            os.unlink(header_path)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
