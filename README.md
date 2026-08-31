# OmaAmp

A Plex music player that lives in the Omarchy shell. It talks to your Plex
Media Server, streams the audio locally with `mpv`, and gives you a
Plexamp-/Winamp-style window to browse your library, search, queue and control
playback — with a now-playing widget in the status bar.

## What it gives you

- **Player window** (a layer-shell overlay, summoned from the bar or a keybind):
  library browser (artists / albums / songs), search, track queue, and full
  transport controls (play/pause, next/prev, seek, shuffle, repeat, volume,
  mute) with album art and elapsed/total time.
- **Bar widget**: a music glyph + scrolling now-playing title; left-click opens
  the player, right-click toggles play/pause.
- **Global IPC target** `omaamp` so you can bind keys to
  `/playPause`, `/next`, `/previous`, `/togglePlayer`.

## Requirements

- Omarchy (Quickshell shell)
- `mpv`, `python3`, `curl`
- A Plex Media Server and an auth token

## Install

This repo is the plugin source. Deploy it into the Omarchy user plugin
directory (a symlink so edits hot-reload):

```bash
ln -sfn "$PWD" ~/.config/omarchy/plugins/iainlennox.omaamp
omarchy plugin enable iainlennox.omaamp --section left
```

## Configure

Copy the template and fill in your server + token:

```bash
cp config/omaamp.json.example ~/.config/omarchy/omaamp.json
# edit ~/.config/omarchy/omaamp.json
```

```json
{
  "server": "http://192.168.1.10:32400",
  "token": "YOUR_PLEX_TOKEN",
  "clientIdentifier": "OmaAmp",
  "autoConnect": true,
  "transcode": false,
  "audioBitrate": 320,
  "outputDevice": "",
  "refreshIntervalSeconds": 0,
  "defaultView": "home"
}
```

- `server` — your Plex Media Server base URL.
- `token` — your Plex auth token (see below). **Never commit this.**
- `transcode` — `false` for direct play of the original audio; `true` to have
  Plex transcode to an mp3 stream first (more compatible, lower bandwidth).
- `audioBitrate` — kbps used when transcoding.

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

## Files

```
manifest.json        Plugin manifest (service, overlay, bar-widget)
Service.qml          Plex client + mpv engine + queue + IPC ("omaamp" target)
Plex.js              Plex REST helpers / item normalization
Window.qml           The player overlay window (Plexamp/Winamp-style UI)
BarWidget.qml        Now-playing status bar widget
bin/omaamp-mpv.py    mpv JSON-IPC bridge (spawns + controls mpv)
config/omaamp.json.example
```

## Security

Your Plex token lives in `~/.config/omarchy/omaamp.json` — outside this repo.
`config/omaamp.json` is git-ignored so your real credentials never get
committed. Keep the token out of any screenshot or log.
