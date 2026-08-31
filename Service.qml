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
    audioBitrate: 320
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

  readonly property string playIcon: playbackState === "playing" ? "󰏤" : "󰐊"
  readonly property bool hasTrack: nowPlaying !== null
  readonly property bool atEnd: queueIndex >= 0 && queueIndex >= queue.length - 1

  property string sockPath: (Quickshell.env("XDG_RUNTIME_DIR") || (home + "/.cache")) + "/omaamp-mpv.sock"

  // ------------------------------------------------------------- lifecycle

  Component.onCompleted: loadConfig()

  Component.onDestruction: teardown()

  function teardown() {
    if (ctrlProc.running) {
      sendCtrl({ cmd: "quit" })
    }
    ctrlProc.running = false
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
      root.error = root.cfg.server ? "" : "No Plex server configured (config/omaamp.json)"
      if (root.cfg.autoConnect !== false) root.connect()
    }
    onLoadFailed: {
      root.error = "Missing config: " + root.configPath
      root.connected = false
    }
  }

  // ------------------------------------------------------------- connection

  function connect() {
    if (!root.cfg.server || !root.cfg.token) {
      root.error = "Set server + token in ~/.config/omarchy/omaamp.json"
      return
    }
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
        root.error = "Could not reach Plex / bad token"
        return
      }
      root.serverName = "" + name
      root.connected = true
      root.configurePlayer()
      listLibraries()
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
    fetchApi(Plex.searchPath(q), { "type": "10" }, function(res) {
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
    }
  }

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
    var url = Plex.apiUrl(root.cfg, req.path, req.params)
    apiProc.command = ["curl", "-sS", "-m", "25", "-H", "Accept: application/json", "-H", "X-Plex-Client-Identifier: OmaAmp", url]
    apiProc.running = true
    _activeReq = req
  }

  property var _activeReq: null

  Process {
    id: apiProc
    running: false
    stdout: StdioCollector {
      id: apiOut
      onStreamFinished: {
        var req = root._activeReq
        var res = text || ""
        root._activeReq = null
        root._apiBusy = false
        if (req && req.cb) {
          try { req.cb(res) } catch (e) { console.warn("omaamp api cb error: " + e) }
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
