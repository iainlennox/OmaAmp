# OmaAmp

A Plex music player that lives in the Omarchy shell. It talks to your Plex
Media Server, streams the audio locally with `mpv`, and gives you a
Plexamp-/Winamp-style window to browse your library, search, queue and control
playback — with a now-playing widget in the status bar.

<img width="1042" height="671" alt="image" src="https://github.com/user-attachments/assets/b8ef27d5-dd97-4b51-b0b7-e670f9caa0ca" />

## What it gives you

- **Player panel** (a bar-anchored popup that drops down below the status bar):
  library browser (artists / albums / songs), search, track queue, and full
  transport controls (play/pause, next/prev, seek, shuffle, repeat, volume,
  mute) with album art and elapsed/total time.
- **Real-time spectrum visualiser**: a retro, 1980s hi-fi style analyser with
  discrete block levels and peak-hold markers driven by *actual* audio (via
  `cava` tapping the PipeWire output monitor) — not fake animation. It hides
  cleanly if the analyser backend isn't available.
- **Graphic equaliser**: a hardware-style 8-band EQ drawer (square faders,
  monospace labels) that genuinely reshapes mpv's audio through audio filters
  — no plugin restarts, and it disables back to flat instantly.
- **Bar widget**: a music glyph + scrolling now-playing title; left-click opens
  the player, right-click toggles play/pause.
- **Global IPC target** `omaamp` (no-arg methods) so you can bind keys or
  script it: `status`, `nowInfo`, `libraries`, `browse`, `playPause`, `next`,
  `previous`, `togglePlayer`, `ping`.

## Requirements

- Omarchy (Quickshell shell)
- `mpv`, `python3`, `curl` (all preflighted at startup; see [Dependencies](#dependencies))
- `cava` (optional — only needed for the spectrum visualiser; the player and
  equaliser work without it)
- A Plex Media Server and an auth token

OmaAmp does **not** bundle `mpv`, `python3`, or `curl`. On startup it preflights
the toolchain and shows a clear message (in the player connection pill) if any
binary is missing, rather than failing silently later. Install them from your
distro's official repositories — e.g. on Debian/Ubuntu `apt install mpv python3
curl` and on Arch/Fedora `pacman -S mpv python curl` (and optionally `cava` via
`apt install cava` / `pacman -S cava`).

## Install

From the marketplace (recommended), clone and enable it as an Omarchy shell
plugin:

```bash
omarchy plugin add https://github.com/iainlennox/OmaAmp.git --enable
```

Or deploy this repo directly as a symlink (so edits hot-reload):

```bash
ln -sfn "$PWD" ~/.config/omarchy/plugins/iainlennox.omaamp
omarchy plugin enable iainlennox.omaamp --section left
```

## Remove

```bash
omarchy plugin remove iainlennox.omaamp
rm -f ~/.config/omarchy/omaamp.json   # optional: drop saved Plex credentials
```

Removal stops the playback engine (the mpv bridge is self-cleaning) and removes
the bar widget and service. Your Plex token is only ever stored in
`~/.config/omarchy/omaamp.json`, never in the plugin or its code.

## Configure

Copy the template and fill in your server + token:

```bash
cp config/omaamp.json.example ~/.config/omarchy/omaamp.json
chmod 600 ~/.config/omarchy/omaamp.json
# edit ~/.config/omarchy/omaamp.json
```

OmaAmp also enforces a private (`0600`) mode on this file automatically at
startup, so the token is protected at rest even if you forget the `chmod`.

```json
{
  "server": "https://192.168.1.10:32400",
  "token": "YOUR_PLEX_TOKEN",
  "clientIdentifier": "OmaAmp",
  "autoConnect": true,
  "transcode": false,
  "audioBitrate": 320,
  "outputDevice": "",
  "refreshIntervalSeconds": 0,
  "defaultView": "home",
  "allowInsecureHttp": false
}
```

- `server` — your Plex Media Server base URL. **Use `https://`.** Plain `http://`
  is refused unless you explicitly set `allowInsecureHttp: true` below; OmaAmp
  will not send your token or metadata over an unencrypted link by default.
- `token` — your Plex auth token (see below). **Never commit this.**
- `transcode` — `false` for direct play of the original audio; `true` to have
  Plex transcode to an mp3 stream first (more compatible, lower bandwidth).
- `audioBitrate` — kbps used when transcoding.
- `visualizer` — `true` to enable the spectrum visualiser (default).
- `visualizerBands` — number of analyser bands (default `12`; `8`, `12` and
  `16` all render cleanly).
- `equalizer` — `true` to enable the graphic equaliser controls (default).
- `eqEnabled` — start with the equaliser applied (`true`) or flat (`false`,
  default). You can also toggle it live in the EQ drawer.
- `allowInsecureHttp` — set to `true` only to allow a plain-`http://` server you
  trust on a private, isolated LAN. This is an explicit, prominent opt-in: while
  `false` (the default), OmaAmp refuses to connect over HTTP at all.

### Getting a Plex token

Open your Plex server's web UI, then visit the token helper URL, or sign in to
[plex.tv](https://app.plex.tv) and read the `X-Plex-Token` from the network
request headers. Enter it in `~/.config/omarchy/omaamp.json`.

## Usage

- Click the music glyph in the bar to open the player window.
- Browse `Artists`, `Albums`, or `Songs` in the sidebar, pick a library section
  if you have more than one.
- Click a track to play it and queue the rest of the current view.
- The queue drawer (button in the player bar) shows what's up next.
- `VIS` toggles the spectrum analyser strip; `EQ` opens the graphic equaliser
  (see [Visualiser & equaliser](#visualiser--equaliser)).
- Click outside the window to close it.

### Optional keybinds (Hyprland)

```ini
bind = SUPER, P, exec, omarchy-shell omaamp togglePlayer
bind = SUPER, comma, exec, omarchy-shell omaamp previous
bind = SUPER, period, exec, omarchy-shell omaamp next
```

## How playback works

`Service.qml` talks to Plex's JSON API over `curl` to list libraries, artists,
albums, tracks, and search results, and builds stream URLs from the item's
media `key` (or the universal transcode endpoint).

Audio is played by `mpv`. Because the shell can't open raw Unix sockets, a
tiny bundled Python bridge (`bin/omaamp-mpv.py`) is the mpv control plane:

- it spawns `mpv --idle=yes --no-video` with a JSON IPC socket,
- commands arrive on its stdin and are forwarded to mpv,
- it relays mpv's property changes back to the shell as newline-delimited JSON
  (read in `Service.qml` via `SplitParser`).

This keeps transport, seeking, volume and "track ended" auto-advance in one
place and integrates with your existing audio sink (PipeWire/WirePlumber).

## Visualiser & equaliser

### Spectrum visualiser

A retro analyser sits above the play bar (`SPECTRUM` / a `[VIS]` toggle). It
renders **discrete, quantised bar blocks** with classic peak-hold markers, the
Omarchy accent colour for the bars, and monospace frequency labels — no
gradients, no round bars, no 60fps animation.

It does **not** fake animation. A small bundled bridge
(`bin/omaamp-visualizer.py`) spawns `cava` — if it's installed — pointed at the
PipeWire output monitor:

```
Plex → Service.qml → mpv → PipeWire → CAVA → raw bytes → omaamp-visualizer.py → SpectrumVisualiser
```

- `cava` taps the audio **output** (the monitor), never the microphone.
- `omaamp-visualizer.py` owns CAVA, reads its raw frames, applies the fast
  attack / slower release + peak-hold envelopes, and streams compact values to
  the shell ~25×/s. Envelope work lives in Python so the shell stays light and
  just renders rectangles.
- The `visProc` process is started once and stopped on teardown (matching the
  mpv bridge lifecycle). Killing the bridge takes CAVA with it — no orphans.

**Optional dependency, graceful fallback.** If `cava` is missing (or exits),
OmaAmp prints a single quiet "unavailable" status, hides the visualiser, and
keeps playing. There are no error loops and no failed startup. You only need
`cava` if you want the bars; audio, the EQ and everything else work without it.
Install it with your distro (e.g. `apt install cava` / `pacman -S cava`).

### Graphic equaliser

The `[EQ]` control opens a hardware-style drawer: eight square faders with thin
tracks, `+12…-12` scale and a preset row (`FLAT`, `BASS+`, `BASS-`, `TREBLE+`,
`TREBLE-`, `VOCAL`, `ROCK`, `ELECTRONIC`). Dragging a fader sets the preset to
`CUSTOM`.

The EQ is entirely mpv-side DSP (FFmpeg peaking filters), updated live through
the `af` property — no DSP in QML/Python, no audio restart when you drag a
fader, and it carries across track changes. `EQ` → `OFF`/`ON` clears or restores
the filters; your band values are remembered while disabled.

## Files

```
manifest.json          Plugin manifest (service, bar-widget)
Service.qml            Plex client + mpv engine + queue + analyser + EQ + IPC
Plex.js                Plex REST helpers / item normalization
BarWidget.qml          Now-playing status bar widget
PlayerPanel.qml        The player popup UI (browser, search, queue, spectrum, EQ)
SpectrumVisualiser.qml Reusable retro spectrum analyser renderer
bin/omaamp-mpv.py      mpv JSON-IPC bridge (spawns + controls mpv)
bin/omaamp-visualizer.py  CAVA spectrum bridge (spawns + parses CAVA)
config/omaamp.json.example
```

## Security

This section documents the mitigations OmaAmp applies so you can review them.

**Token at rest.** Your Plex token lives in `~/.config/omarchy/omaamp.json` —
outside this repo. `config/omaamp.json` is git-ignored, and the plugin forces
the file to `0600` at startup. Keep the token out of any screenshot or log.

**Token in transit.** HTTP API requests are routed through
`bin/omaamp-http.py`, which reads the token from disk and hands it to `curl`
through a private, owner-verified, `0600` header file — the token never appears
in a process command line (`argv`) or in the request URL on the command line.
Audio stream URLs still carry the token, as Plex requires it, but they are
passed to `mpv` over the plugin's private unix socket, never on a command line.
Plain `http://` is refused by default; an `https://` server (or an explicit
`allowInsecureHttp: true` opt-in for a private, trusted LAN) is required.

**Bounded network memory.** `bin/omaamp-http.py` caps every API response at
20 MiB and drops curl failures/oversized responses with a clean error.
`Plex.js` caps the number of items retained per view (4000), the number of
queue entries (2000), and the length of every normalized string field (512
chars), so a hostile or malformed Plex response cannot balloon memory.

**Safe temporary files.** `omaamp-visualizer.py` (CAVA) and `omaamp-http.py`
write their config/header files in a private, owner-verified directory and
create files atomically with `O_NOFOLLOW` and `0600` permissions, never
following or overwriting pre-planted symlinks. The CAVA config is removed on
teardown.

**Server-controlled text and images.** Every title, artist, album, and library
name rendered from Plex is displayed with `textFormat: Text.PlainText`, so
server-supplied rich text cannot be interpreted. Image URLs are constrained to
the configured server over `http`/`https` only.

**Dependencies.** `mpv`, `python3`, and `curl` are preflighted at startup; a
clear message is shown if any are missing, and you install them from your
distro's official repositories (see [Requirements](#requirements)).
