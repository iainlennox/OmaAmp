// OmaAmp central service: owns the Plex client, the mpv playback engine,
// and the queue. The overlay window and the bar widget read state from this
// object (injected into the window via the shell's `service` property and
// reachable from the bar through `bar.shell.serviceFor("iainlennox.omaamp")`).

import QtQuick
import Quickshell
import Quickshell.Io
import "Plex.js" as Plex

Item {
  id: root

  property var shell: null
  property var manifest: null

  // ------------------------------------------------------------- config
  property string home: Quickshell.env("HOME")
  property string configPath: home + "/.config/omarchy/omaamp.json"
  property var cfg: ({
    server: "",
    token: "",
    clientIdentifier: "OmaAmp",
    transcode: false,
    audioBitrate: 320,
    visualizer: true,
    visualizerBands: 12,
    equalizer: true,
    eqEnabled: false,
    allowInsecureHttp: false
  })

  // ------------------------------------------------------------- connection
  property bool connecting: false
  property bool connected: false
  property string serverName: ""
  property string error: ""

  // Library + browse state
  property var libraries: []
  property string currentSectionId: ""
  property string currentView: "home"
  property var items: []
  property bool itemsLoading: false
  property var tracks: []
  property string searchQuery: ""
  property int searchSerial: 0

  // Playback state
  property bool mpvReady: false
  property bool mpvDied: false
  property var nowPlaying: null           // current track record
  property var queue: []                  // array of track records
  property int queueIndex: -1
  property string playbackState: "stopped" // stopped | playing | paused
  property real position: 0
  property real duration: 0
  property int volume: 100
  property bool muted: false
  property bool shuffle: false
  property string repeat: "off"           // off | all | one

  // ------------------------------------------------------------- spectrum
  // Real-time analyser data, produced by bin/omaamp-visualizer.py (CAVA).
  // `spectrumAvailable` is false until the analyser has genuinely connected;
  // `spectrumBands`/`spectrumPeaks` are fixed-length 0..1 arrays (current and
  // peak-hold level per band) refreshed ~25Hz by the producer.
  property var spectrumBands: []
  property var spectrumPeaks: []
  property bool spectrumReady: false
  property bool spectrumAvailable: false
  readonly property int spectrumBandCount: (Number(root.cfg.visualizerBands) > 0) ? Math.round(Number(root.cfg.visualizerBands)) : 12

  // ------------------------------------------------------------- equaliser
  // The EQ is 100% mpv-side audio filters (FFmpeg peaking filters set through
  // the `af` property, which mpv updates live and carries across tracks).
  // The shell only edits this state; bin/omaamp-mpv.py forwards the `af` set.
  property bool eqEnabled: root.cfg.eqEnabled === true
  readonly property bool eqAvailable: root.cfg.equalizer !== false
  property string eqPreset: "FLAT"
  property var eqBandFreqs: [60, 170, 310, 600, 1000, 3000, 6000, 12000]
  property var eqGains: [0, 0, 0, 0, 0, 0, 0, 0]
  property var eqPresets: ({
    FLAT: [0, 0, 0, 0, 0, 0, 0, 0],
    "BASS+": [6, 5, 3, 1, 0, 0, 0, 0],
    "BASS-": [-6, -5, -3, -1, 0, 0, 0, 0],
    "TREBLE+": [0, 0, 0, 0, 1, 3, 5, 6],
    "TREBLE-": [0, 0, 0, 0, -1, -3, -5, -6],
    VOCAL: [-2, -1, 0, 2, 3, 2, 1, 0],
    ROCK: [4, 3, 1, 0, -1, 0, 2, 3],
    ELECTRONIC: [6, 4, 1, 0, -1, 2, 3, 4]
  })

  readonly property string playIcon: playbackState === "playing" ? "󰏤" : "󰐊"
  readonly property bool hasTrack: nowPlaying !== null
  readonly property bool atEnd: queueIndex >= 0 && queueIndex >= queue.length - 1

  property string sockPath: (Quickshell.env("XDG_RUNTIME_DIR") || (home + "/.cache")) + "/omaamp-mpv.sock"

  // ------------------------------------------------------------- lifecycle

  Component.onCompleted: loadConfig()

  Component.onDestruction: teardown()

  function teardown() {
    root._tearingDown = true
    if (ctrlProc.running) {
      sendCtrl({ cmd: "quit" })
    }
    ctrlProc.running = false
    if (visProc.running) {
      visProc.write(JSON.stringify({ cmd: "quit" }) + "\n")
    }
    visProc.running = false
  }

  // ------------------------------------------------------------- config

  function loadConfig() {
    cfgFile.reload()
  }

  FileView {
    id: cfgFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var parsed = {}
      try { parsed = JSON.parse(text()) || {} } catch (e) { parsed = {} }
      var next = {}
      for (var k in root.cfg) next[k] = root.cfg[k]
      for (var k2 in parsed) {
        if (parsed[k2] !== undefined && parsed[k2] !== null) next[k2] = parsed[k2]
      }
      root.cfg = next
      // Enforce a private config so the Plex token is protected at rest.
      root.secureConfigFile()
      root.error = root.cfg.server ? "" : "No Plex server configured (config/omaamp.json)"
      root.startVisualizer()
      if (root.cfg.autoConnect !== false) root.connect()
    }
    onLoadFailed: {
      root.error = "Missing config: " + root.configPath
      root.connected = false
      root.startVisualizer()
    }
  }

  // The Plex token lives in ~/.config/omarchy/omaamp.json. Ensure the config
  // file is private (0600) so the token is not world-readable at rest. We only
  // adjust the file, not the shared ~/.config/omarchy directory, which other
  // Omarchy plugins may rely on.
  function secureConfigFile() {
    cfgPermProc.command = ["sh", "-c", "[ -e \"$1\" ] && chmod 600 \"$1\"; true", "sh", root.configPath]
    cfgPermProc.running = true
  }

  Process {
    id: cfgPermProc
    running: false
    stdout: StdioCollector { }
    stderr: StdioCollector { }
  }

  // Preflight the runtime toolchain (mpv, python3, curl) so missing binaries
  // are surfaced clearly instead of failing silently at playback time.
  function preflight() {
    progProc.command = ["sh", "-c",
      "for b in mpv python3 curl; do command -v \"$b\" >/dev/null 2>&1 || echo \"missing:$b\"; done; echo done"]
    progProc.running = true
  }

  property var missingTools: []

  Process {
    id: progProc
    running: false
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        if (line === "done") return
        if (line.indexOf("missing:") === 0) {
          var t = line.substring(8)
          var m = root.missingTools.slice()
          if (m.indexOf(t) === -1) m.push(t)
          root.missingTools = m
        }
      }
    }
    onExited: root.checkToolchain()
  }

  function checkToolchain() {
    if (root.missingTools.length > 0) {
      root.error = "Missing runtime dependencies: " + root.missingTools.join(", ") + " (see README)"
    } else if (root.cfg.server) {
      root.error = ""
    }
  }

  // Verify the connection transport is safe: HTTPS is required unless the user
  // has explicitly opted into an insecure LAN connection via allowInsecureHttp.
  function transportError() {
    var s = String(root.cfg.server || "")
    if (!s) return "No Plex server configured"
    if (s.toLowerCase().indexOf("https://") === 0) return ""
    if (s.toLowerCase().indexOf("http://") === 0) {
      if (root.cfg.allowInsecureHttp === true) return ""
      return "Insecure HTTP server. Use https://, or set \"allowInsecureHttp\": true in omaamp.json only for a private LAN you trust."
    }
    return "Server URL must start with http:// or https://"
  }

  // ------------------------------------------------------------- connection

  function connect() {
    if (!root.cfg.server || !root.cfg.token) {
      root.error = "Set server + token in ~/.config/omarchy/omaamp.json"
      return
    }
    // Refuse to send the token over an unencrypted link unless the user has
    // explicitly opted into an insecure LAN connection.
    var tErr = root.transportError()
    if (tErr) {
      root.connecting = false
      root.connected = false
      root.error = tErr
      return
    }
    root.preflight()
    root.connecting = true
    root.error = ""
    fetchApi("/identity", null, function(res) {
      root.connecting = false
      var ok = false
      var name = ""
      try {
        var j = JSON.parse(res)
        var mc = j.MediaContainer || j
        name = mc.friendlyName || mc.newIdentifier || ""
        ok = true
      } catch (e) { ok = false }
      if (!ok) {
        root.connected = false
        if (!root.error) root.error = "Could not reach Plex / bad token"
        return
      }
      root.serverName = "" + name
      root.connected = true
      root.configurePlayer()
      listLibraries()
      // The identity endpoint omits friendlyName on some builds; fetch it.
      fetchApi("/", null, function(res) {
        try {
          var j = JSON.parse(res)
          var mc = j.MediaContainer || j
          if (mc.friendlyName) root.serverName = "" + mc.friendlyName
        } catch (e) { /* ignore */ }
      })
    })
  }

  function listLibraries() {
    fetchApi(Plex.sectionsPath(), null, function(res) {
      var sections = []
      try { sections = Plex.fromSections(JSON.parse(res)) } catch (e) { sections = [] }
      var music = []
      for (var i = 0; i < sections.length; i++) {
        if (sections[i].music) {
          sections[i].title = sections[i].title || "Music"
          music.push(sections[i])
        }
      }
      root.libraries = music
      if (music.length === 0) {
        root.error = "No music libraries found on the server"
      } else if (!root.currentSectionId) {
        root.currentSectionId = music[0].key
        openView("artists")
      }
    })
  }

  // ------------------------------------------------------------- browse

  function coverUrl(item) {
    if (!item) return ""
    return Plex.thumbUrl(root.cfg, item)
  }

  function streamUrlFor(item) {
    if (!item) return ""
    return Plex.streamUrl(root.cfg, item)
  }

  function setSection(sectionId) {
    root.currentSectionId = String(sectionId)
  }

  function openView(view, sectionId) {
    var sec = sectionId || root.currentSectionId
    if (view === "home") {
      root.currentView = "home"
      root.items = []
    } else if (view === "search") {
      root.currentView = "search"
      root.items = []
    } else if (view === "artists" || view === "albums" || view === "tracks") {
      root.currentView = view
      root.currentSectionId = sec
      browseSection(view, sec)
    } else {
      root.currentView = view
      browseSection(view, sec)
    }
  }

  function browseSection(view, sectionId) {
    root.itemsLoading = true
    var path
    if (view === "artists") path = Plex.sectionArtistsPath(sectionId)
    else if (view === "albums") path = Plex.sectionAlbumsPath(sectionId)
    else path = Plex.sectionTracksPath(sectionId)
    fetchApi(path, null, function(res) {
      var list = []
      try { list = Plex.fromMetadata(JSON.parse(res)) } catch (e) { list = [] }
      setBrowseItems(view, list)
    })
  }

  function openAlbum(albumKey) {
    root.itemsLoading = true
    fetchApi(Plex.childrenPath(albumKey), null, function(res) {
      var list = []
      try { list = Plex.fromMetadata(JSON.parse(res)) } catch (e) { list = [] }
      root.currentView = "album"
      root.tracks = list
      root.items = list
      root.itemsLoading = false
    })
  }

  function openArtist(artistKey) {
    root.itemsLoading = true
    fetchApi(Plex.childrenPath(artistKey), null, function(res) {
      var list = []
      try { list = Plex.fromMetadata(JSON.parse(res)) } catch (e) { list = [] }
      root.currentView = "artist"
      root.items = list
      root.itemsLoading = false
    })
  }

  // Play an entire album: fetch its children once, then reuse the existing
  // queue/playback path instead of duplicating it. No N+1 — one request total.
  function playAlbum(item) {
    if (!item || !item.key) return
    fetchApi(Plex.childrenPath(item.key), null, function(res) {
      var list = []
      try { list = Plex.fromMetadata(JSON.parse(res)) } catch (e) { list = [] }
      playItemList(list, 0)
    })
  }

  function setBrowseItems(view, list) {
    root.items = list
    if (view === "tracks") root.tracks = list
    else {
      // Keep a flat track list for the current view so "play all" works.
      root.tracks = []
    }
    root.itemsLoading = false
  }

  function playListStart(index, listRef) {
    // Play a specific item in a provided list (used by album / search views).
    var list = listRef || root.items
    if (viewIsTrackList()) {
      playItemList(root.items, index)
    } else {
      // Album/artist selected: open it.
      var item = list[index]
      if (!item) return
      if (item.type === "track") {
        playItemList(root.items, index)
      } else if (item.viewGroup === "album" || item.type === "album") {
        openAlbum(item.key)
      } else if (item.type === "artist") {
        openArtist(item.key)
      } else {
        openAlbum(item.key)
      }
    }
  }

  function viewIsTrackList() {
    return root.currentView === "album" || root.currentView === "artist" ||
      root.currentView === "tracks" || root.currentView === "search"
  }

  // ------------------------------------------------------------- search

  function search(q) {
    root.searchQuery = q
    if (!q || q.length === 0) {
      root.items = []
      return
    }
    root.itemsLoading = true
    var serial = ++root.searchSerial
    // No `type` filter: search artists, albums and tracks. Plex.fromSearch()
    // already tags each hit with `kind` so the UI can tell them apart.
    fetchApi(Plex.searchPath(q), null, function(res) {
      if (serial !== root.searchSerial) return
      var list = []
      try { list = Plex.fromSearch(JSON.parse(res)) } catch (e) { list = [] }
      root.items = list
      root.tracks = list.filter(function(t) { return t.kind === "track" })
      root.itemsLoading = false
    })
  }

  // ------------------------------------------------------------- queue

  function playItemList(list, index) {
    if (!list || list.length === 0) return
    var q = []
    for (var i = 0; i < list.length; i++) {
      var it = list[i]
      if (it.kind && it.kind !== "track") continue
      if (it.fileKey || it._fileKey) q.push(it)
      else if (it.type === "track") q.push(it)
    }
    if (q.length === 0) return
    if (root.shuffle) q = shuffle(q)
    if (q.length > Plex.MAX_QUEUE) q = q.slice(0, Plex.MAX_QUEUE)
    root.queue = q
    root.queueIndex = Math.max(0, Math.min(index, q.length - 1))
    loadCurrent(0)
  }

  function playNow(item) {
    playItemList([item], 0)
  }

  function addToQueue(item) {
    if (!item) return
    var q = root.queue.slice()
    q.push(item)
    if (q.length > Plex.MAX_QUEUE) q = q.slice(q.length - Plex.MAX_QUEUE)
    root.queue = q
  }

  function shuffle(arr) {
    var a = arr.slice()
    for (var i = a.length - 1; i > 0; i--) {
      var j = Math.floor(Math.random() * (i + 1))
      var t = a[i]; a[i] = a[j]; a[j] = t
    }
    return a
  }

  function loadCurrent(offsetSec) {
    if (root.queueIndex < 0 || root.queueIndex >= root.queue.length) return
    var item = root.queue[root.queueIndex]
    root.nowPlaying = item
    var url = Plex.streamUrl(root.cfg, item) || item._streamUrl
    if (!url) {
      root.error = "No playable source for " + item.title
      next()
      return
    }
    startMpv(url, offsetSec)
  }

  // ------------------------------------------------------------- transport

  function togglePlay() {
    if (root.playbackState === "playing") pause()
    else play()
  }

  function play() {
    sendCtrl({ cmd: "set", prop: "pause", value: false })
    root.playbackState = "playing"
  }

  function pause() {
    sendCtrl({ cmd: "set", prop: "pause", value: true })
    root.playbackState = "paused"
  }

  function stop() {
    sendCtrl({ cmd: "stop" })
    root.playbackState = "stopped"
    root.position = 0
    root.nowPlaying = null
  }

  function next() {
    if (root.queueIndex < 0 && root.queue.length === 0) return
    var idx = root.queueIndex + 1
    if (idx >= root.queue.length) {
      if (root.repeat === "all" && root.queue.length > 0) idx = 0
      else { root.playbackState = "stopped"; root.position = 0; return }
    }
    root.queueIndex = idx
    loadCurrent(0)
  }

  function previous() {
    if (root.queueIndex <= 0) {
      if (root.position > 3) { seek(0); return }
      if (root.queue.length === 0) return
    }
    root.queueIndex = Math.max(0, root.queueIndex - 1)
    loadCurrent(0)
  }

  function towardStart() {
    if (root.position > 3) seek(0)
    else previous()
  }

  function seek(sec) {
    sendCtrl({ cmd: "seek", value: sec })
    root.position = sec
  }

  function setVolume(v) {
    var vol = Math.max(0, Math.min(100, Math.round(Number(v))))
    root.volume = vol
    sendCtrl({ cmd: "set", prop: "volume", value: vol })
    if (root.muted) { root.muted = false; sendCtrl({ cmd: "set", prop: "mute", value: false }) }
  }

  function toggleMute() {
    root.muted = !root.muted
    sendCtrl({ cmd: "set", prop: "mute", value: root.muted })
  }

  function toggleShuffle() {
    root.shuffle = !root.shuffle
    if (root.shuffle && root.queue.length > 0) {
      var q = shuffle(root.queue)
      // Keep the current track first, at the front.
      var cur = root.nowPlaying
      var rest = q.filter(function(t) { return t.key !== (cur ? cur.key : "") })
      root.queue = (cur ? [cur] : []).concat(rest)
      root.queueIndex = 0
    }
  }

  function cycleRepeat() {
    if (root.repeat === "off") root.repeat = "all"
    else if (root.repeat === "all") root.repeat = "one"
    else root.repeat = "off"
  }

  // ------------------------------------------------------------- mpv engine
  //
  // mpv is run through a small bundled Python bridge (bin/omaamp-mpv.py) that
  // owns the mpv JSON-IPC socket: the bridge emits normalized status lines on
  // stdout (read here via SplitParser) and accepts identical command lines on
  // stdin (sent with Process.write). This avoids the non-creatable Quickshell
  // Socket and keeps mpv control fully in one place.

  readonly property string helperPath:
    (root.manifest && root.manifest.__sourceDir ? root.manifest.__sourceDir : (home + "/Work/OmaAmp"))
    + "/bin/omaamp-mpv.py"

  readonly property string visHelperPath:
    (root.manifest && root.manifest.__sourceDir ? root.manifest.__sourceDir : (home + "/Work/OmaAmp"))
    + "/bin/omaamp-visualizer.py"

  readonly property string httpHelperPath:
    (root.manifest && root.manifest.__sourceDir ? root.manifest.__sourceDir : (home + "/Work/OmaAmp"))
    + "/bin/omaamp-http.py"

  function configurePlayer() {
    if (ctrlProc.running) return
    ctrlProc.command = ["python3", root.helperPath, "--socket", root.sockPath, "--volume", String(root.volume)]
    ctrlProc.running = true
  }

  Process {
    id: ctrlProc
    running: false
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.onCtrlLine(line) }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        if (text && text.trim().length > 0) root.mpvDied = true
      }
    }
    onStarted: {
      root.mpvReady = true
      root.mpvDied = false
      root.applyEq()
      if (root._pendingLoad) {
        var p = root._pendingLoad
        root._pendingLoad = null
        root.startMpv(p.url, p.offset)
      }
    }
    onExited: function(status) {
      root.mpvReady = false
      root.mpvDied = true
      if (root.playbackState === "playing" || root.playbackState === "paused") {
        root.playbackState = "stopped"
      }
      if (root.connected && !root._tearingDown) respawnTimer.restart()
    }
  }

  Timer {
    id: respawnTimer
    interval: 1500
    repeat: false
    onTriggered: if (root.connected && !root._tearingDown) root.configurePlayer()
  }

  property bool _tearingDown: false

  function startMpv(url, offsetSec) {
    if (!mpvReady) {
      // Bridge not ready yet; remember this so playback starts the moment it is.
      _pendingLoad = { url: url, offset: offsetSec || 0 }
      return
    }
    sendCtrl({ cmd: "loadfile", url: url, start: offsetSec || 0 })
    root.playbackState = "playing"
    root.position = offsetSec || 0
  }

  property var _pendingLoad: null

  function sendCtrl(obj) {
    if (!mpvReady) return
    ctrlProc.write(JSON.stringify(obj) + "\n")
  }

  function onCtrlLine(line) {
    var obj
    try { obj = JSON.parse(line) } catch (e) { return }
    if (obj.type === "event" && obj.event === "end-file") {
      if (obj.reason === "eof") {
        if (root.repeat === "one") { loadCurrent(0); return }
        root.position = 0
        next()
      } else if (obj.reason === "error") {
        root.error = "Playback error"
        next()
      }
      return
    }
    if (obj.type !== "status") return
    if (obj.paused === true) root.playbackState = "paused"
    else if (obj.playing === true) root.playbackState = "playing"
    else if (root.playbackState !== "stopped") root.playbackState = "stopped"
    if (obj.time !== undefined) root.position = Number(obj.time) || 0
    if (obj.duration !== undefined) root.duration = Number(obj.duration) || 0
    if (obj.volume !== undefined) root.volume = Math.max(0, Math.min(100, Math.round(Number(obj.volume) || 0)))
    if (obj.muted !== undefined) root.muted = obj.muted === true
  }

  // ------------------------------------------------------------- visualiser
  //
  // Real audio spectrum via bin/omaamp-visualizer.py (which owns CAVA). One
  // persistent process while the plugin is loaded — started once, stopped on
  // destruction, never duplicated, and never respawned after it exits (so a
  // missing CAVA hides the visualiser quietly instead of error-looping).

  function startVisualizer() {
    if (root.cfg.visualizer === false) return
    if (root._visUnavailable) return
    if (visProc.running) return
    visProc.command = ["python3", root.visHelperPath, "--bars", String(root.spectrumBandCount), "--rate", "25"]
    visProc.running = true
  }

  function onVisLine(line) {
    var obj
    try { obj = JSON.parse(line) } catch (e) { return }
    if (!obj) return
    if (obj.type === "ready") {
      root.spectrumAvailable = true
      return
    }
    if (obj.type === "unavailable") {
      root.spectrumAvailable = false
      root.spectrumReady = false
      root._visUnavailable = true
      return
    }
    if (obj.type === "spectrum") {
      root.spectrumBands = obj.v || []
      root.spectrumPeaks = obj.p || []
    }
  }

  Process {
    id: visProc
    running: false
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.onVisLine(line) }
    }
    stderr: StdioCollector { }
    onStarted: {
      root.spectrumReady = true
    }
    onExited: function(status) {
      // No respawn: the analyser is a best-effort, optional enhancement.
      // If it died (or CAVA is absent) the player keeps working; the UI
      // hides the visualiser. Guard against the teardown path and against
      // the "unavailable" exit which already cleared the flags.
      root.spectrumReady = false
      if (root.spectrumAvailable || root._visUnavailable) {
        root.spectrumAvailable = false
        root._visUnavailable = true
      }
      root.spectrumBands = []
      root.spectrumPeaks = []
    }
  }

  property bool _visUnavailable: false

  // Debounce live fader drags so we don't flood mpv with `af` updates while the
  // user slides; presets and the ON/OFF toggle still apply immediately.
  Timer {
    id: eqDebounce
    interval: 90
    onTriggered: root.applyEq()
  }

  // ------------------------------------------------------------- equaliser
  //
  // mpv exposes FFmpeg's peaking `equalizer` filter natively. We build an
  // 8-band chain and push it through the `af` property (one live set_property,
  // no restart, persists across tracks). Setting `af` to "" restores flat.

  function eqFilterString() {
    var parts = []
    for (var i = 0; i < root.eqBandFreqs.length; i++) {
      var g = Math.max(-12, Math.min(12, Math.round(Number(root.eqGains[i]) || 0)))
      parts.push("equalizer=f=" + root.eqBandFreqs[i] + ":t=q:w=1:g=" + g)
    }
    return parts.join(",")
  }

  function applyEq() {
    if (!root.mpvReady) return
    sendCtrl({ cmd: "set", prop: "af", value: root.eqEnabled ? root.eqFilterString() : "" })
  }

  function setEqEnabled(b) {
    root.eqEnabled = b === true
    root.applyEq()
  }

  function setEqGain(i, db) {
    var idx = Math.max(0, Math.min(root.eqGains.length - 1, Math.round(Number(i) || 0)))
    var g = Math.max(-12, Math.min(12, Math.round(Number(db) || 0)))
    var gains = root.eqGains.slice()
    gains[idx] = g
    root.eqGains = gains
    root.eqPreset = "CUSTOM"
    eqDebounce.restart()
  }

  function setEqPreset(name) {
    var p = root.eqPresets[name]
    if (!p) return
    root.eqGains = p.slice()
    root.eqPreset = name
    if (root.eqEnabled) root.applyEq()
  }

  // ------------------------------------------------------------- requests

  property var _reqQueue: []
  property bool _apiBusy: false

  function fetchApi(path, params, cb) {
    _reqQueue.push({ path: path, params: params, cb: cb })
    pumpApi()
  }

  function pumpApi() {
    if (_apiBusy) return
    if (_reqQueue.length === 0) return
    _apiBusy = true
    var req = _reqQueue.shift()
    // Route the request through the private HTTP bridge (bin/omaamp-http.py):
    // it attaches the auth token via a header file (never argv/URL on the
    // command line) and enforces a hard response-size cap. The `path` already
    // carries any query string from the caller.
    apiProc.command = ["python3", root.httpHelperPath]
    apiProc.running = true
    _activeReq = req
    apiProc.write(JSON.stringify({ path: req.path }) + "\n")
  }

  property var _activeReq: null

  Process {
    id: apiProc
    running: false
    stdinEnabled: true
    stdout: StdioCollector {
      id: apiOut
      onStreamFinished: {
        var req = root._activeReq
        var res = ""
        var ok = false
        try {
          var parsed = JSON.parse(text || "{}")
          if (parsed.ok === true) { res = parsed.body; ok = true }
          else if (parsed.reason === "missing-config") root.error = "Set server + token in ~/.config/omarchy/omaamp.json"
          else if (parsed.reason === "too-large") root.error = "Plex response too large (capped by OmaAmp)"
          else if (parsed.reason === "curl-spawn") root.error = "curl not found or failed to start"
          else if (parsed.reason === "curl-error") root.error = "Plex request failed (HTTP error)"
          else root.error = "Plex request failed"
        } catch (e) { /* non-JSON / empty response */ }
        root._activeReq = null
        root._apiBusy = false
        if (req && req.cb) {
          try { req.cb(ok ? res : "") } catch (e) { console.warn("omaamp api cb error: " + e) }
        }
        root.pumpApi()
      }
    }
    stderr: StdioCollector { }
  }

  // ------------------------------------------------------------- IPC

  IpcHandler {
    target: "omaamp"

    function status(): string {
      return JSON.stringify({
        connected: root.connected,
        serverName: root.serverName,
        playbackState: root.playbackState,
        title: root.nowPlaying ? root.nowPlaying.title : "",
        artist: root.nowPlaying ? (root.nowPlaying.artistTitle || root.nowPlaying.artist || "") : "",
        album: root.nowPlaying ? (root.nowPlaying.albumTitle || root.nowPlaying.album || "") : "",
        position: root.position,
        duration: root.duration,
        hasTrack: root.hasTrack,
        volume: root.volume,
        muted: root.muted,
        shuffle: root.shuffle,
        repeat: root.repeat
      })
    }

    function togglePlayer(): string {
      if (root.shell && typeof root.shell.toggle === "function") root.shell.toggle("iainlennox.omaamp")
      return "ok"
    }

    function playPause(): string {
      root.togglePlay()
      return "ok"
    }

    function next(): string {
      root.next()
      return "ok"
    }

    function previous(): string {
      root.previous()
      return "ok"
    }

    function libraries(): string {
      return JSON.stringify(root.libraries)
    }

    function browse(): string {
      return JSON.stringify(root.items)
    }

    function nowInfo(): string {
      return JSON.stringify({
        title: root.nowPlaying ? root.nowPlaying.title : "",
        artist: root.nowPlaying ? (root.nowPlaying.artistTitle || root.nowPlaying.artist || "") : "",
        state: root.playbackState,
        position: root.position,
        duration: root.duration,
        queueLength: root.queue.length
      })
    }

    function ping(): string {
      return "ok"
    }
  }
}
