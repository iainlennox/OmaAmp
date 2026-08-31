// Plex REST helpers for OmaAmp.
//
// These are pure functions over the Plex Media Server HTTP API. JSON is
// requested with `Accept: application/json` (the modern, documented way to get
// JSON instead of XML). Everything here is intentionally Quickshell/JS-safe:
// no classes, no arrow functions, no template literals, no `const`.

// ------------------------------------------------------------------ utilities

function has(obj, key) {
  return obj !== null && obj !== undefined && obj[key] !== undefined
}

function bool(v) {
  return v === true || v === "1" || v === "true"
}

// Strip trailing slashes and build a request URL with the auth token.
function apiUrl(cfg, path, extraParams) {
  var server = String(cfg.server || "").replace(/\/+$/, "")
  var q = []
  q.push("X-Plex-Token=" + encodeURIComponent(cfg.token || ""))
  if (extraParams) {
    for (var k in extraParams) {
      if (!has(extraParams, k)) continue
      var v = extraParams[k]
      if (v === null || v === undefined || v === "") continue
      q.push(encodeURIComponent(k) + "=" + encodeURIComponent(String(v)))
    }
  }
  var base = server + (path.charAt(0) === "/" ? "" : "/") + path
  if (path.indexOf("?") !== -1) return base + "&" + q.join("&")
  return base + "?" + q.join("&")
}

function titleOf(obj) {
  if (!obj) return ""
  if (obj.title) return String(obj.title)
  if (obj.titleSort) return String(obj.titleSort)
  return ""
}

function unpadded(container) {
  var c = container && container.MediaContainer ? container.MediaContainer : (container || {})
  return c
}

// A track's direct-play file key. Plex nests it as Media[0].Part[0].key
// (e.g. "/music/164/file.mp3"). Relative to the server root.
function partKeyOf(item) {
  if (!item) return ""
  if (item.fileKey) return String(item.fileKey)
  if (item.Part) item = item
  var media = item.Media
  if (has(item, "Media") && Array.isArray(item.Media)) {
    var parts = item.Media[0] ? item.Media[0].Part : null
    if (parts && Array.isArray(parts) && parts[0]) return String(parts[0].key || "")
  }
  return ""
}

// Thumbnail / art URLs are server-relative and require the auth token.
function thumbUrl(cfg, obj) {
  if (!obj) return ""
  var t = obj.thumb || obj.art || obj.thumbnail || obj.poster || ""
  if (!t) return ""
  if (String(t).indexOf("http") === 0) return String(t)
  return apiUrl(cfg, String(t))
}

function artUrl(cfg, obj) {
  if (!obj) return ""
  var t = obj.art || obj.thumb || obj.background || ""
  if (!t) return ""
  if (String(t).indexOf("http") === 0) return String(t)
  return apiUrl(cfg, String(t))
}

// Build a playable stream URL for a track item object (already normalized).
// `direct` uses the media file key; `transcode` routes through the universal
// audio transcode endpoint so mpv gets a universally-decodable stream.
function streamUrl(cfg, track) {
  if (!track) return ""
  if (track._streamUrl) return track._streamUrl
  var key = partKeyOf(track)
  if (!key && track.fileKey) key = track.fileKey
  if (!key) return ""
  if (cfg.transcode === true) {
    var bitrate = Number(cfg.audioBitrate) > 0 ? Number(cfg.audioBitrate) : 320
    var params = {
      "path": key,
      "mediaIndex": "0",
      "partIndex": "0",
      "protocol": "http",
      "audioCodec": "mp3",
      "container": "mp3",
      "audioBitrate": String(bitrate),
      "audioChannelCount": "2"
    }
    var server = String(cfg.server || "").replace(/\/+$/, "")
    var query = "path=" + encodeURIComponent(key) + "&mediaIndex=0&partIndex=0&protocol=http&audioCodec=mp3&container=mp3&audioBitrate=" + String(bitrate) + "&audioChannelCount=2&X-Plex-Token=" + encodeURIComponent(cfg.token || "")
    return server + "/music/transcode/universal/start?" + query
  }
  return apiUrl(cfg, key)
}

function secondsOf(item) {
  var d = item.duration || item.trackDuration || 0
  if (!d) return 0
  return Math.round(Number(d) / 1000)
}

function millisecondsOf(item) {
  var d = item.duration || item.trackDuration || 0
  return Number(d) || 0
}

// ------------------------------------------------------------------ normalization

// Normalize one Plex library object into a display-friendly record.
function normalizeItem(raw) {
  if (!raw) return null
  var r = {}
  r.key = String(raw.key || raw.ratingKey || "")
  r.ratingKey = String(raw.ratingKey || "")
  r.type = String(raw.type || raw.viewGroup || "")
  r.title = titleOf(raw) || "Untitled"
  r.titleSort = raw.titleSort || r.title
  r.year = raw.year || 0
  r.durationMs = millisecondsOf(raw)
  r.duration = secondsOf(raw)
  r.thumb = raw.thumb || raw.art || ""
  r.art = raw.art || raw.thumb || ""
  r._thumb = raw.thumb || raw.art || ""
  r._art = raw.art || ""
  r.artist = raw.originalTitle || raw.artist || ""
  r.album = raw.album || raw.parentTitle || ""
  r.artistKey = raw.parentKey || ""
  r.albumKey = raw.grandparentKey || ""
  r.artistTitle = raw.artist || raw.parentTitle || ""
  r.albumTitle = raw.album || raw.grandparentTitle || ""
  r.grandparentTitle = raw.grandparentTitle || ""
  r.parentTitle = raw.parentTitle || ""
  r.viewGroup = String(raw.viewGroup || raw.type || "")
  r.fileKey = partKeyOf(raw)
  return r
}

// Extract music sections from a `/library/sections` response.
function fromSections(container) {
  var c = unpadded(container)
  var out = []
  var dirs = c.Directory || []
  for (var i = 0; i < dirs.length; i++) {
    var d = dirs[i]
    var type = String(d.type || "")
    // Music libraries report type "artist" (Plex types music as artists).
    var isMusic = type === "artist" || type === "music" || type === "artist,album,track"
    out.push({
      key: String(d.key || d.id || ""),
      type: type,
      title: titleOf(d) || "Music",
      viewGroup: String(d.viewGroup || ""),
      music: isMusic
    })
  }
  return out
}

function fromMetadata(container) {
  var c = unpadded(container)
  var out = []
  var items = c.Metadata || []
  for (var i = 0; i < items.length; i++) {
    var it = normalizeItem(items[i])
    if (it.key) {
      it._thumb = items[i].thumb || ""
      it._art = items[i].art || ""
      it.fileKey = partKeyOf(items[i])
      out.push(it)
    }
  }
  return out
}

function fromSearch(container) {
  var c = unpadded(container)
  var out = []
  var items = c.Metadata || []
  for (var i = 0; i < items.length; i++) {
    var raw = items[i]
    var it = normalizeItem(raw)
    var t = it.type
    it.kind = ""
    if (t === "artist") it.kind = "artist"
    else if (t === "album") it.kind = "album"
    else if (t === "track") it.kind = "track"
    else if (it.viewGroup === "album") it.kind = "album"
    else if (it.viewGroup === "track") it.kind = "track"
    else if (it.viewGroup === "artist") it.kind = "artist"
    if (!it.kind) {
      if (it.album) it.kind = "track"
      else it.kind = "track"
    }
    it._thumb = raw.thumb || ""
    it._art = raw.art || ""
    it.fileKey = partKeyOf(raw)
    if (it.fileKey) it.kind = "track"
    out.push(it)
  }
  return out
}

// ------------------------------------------------------------------ paths

function sectionsPath() {
  return "/library/sections"
}

function sectionArtistsPath(sectionId) {
  return "/library/sections/" + sectionId + "/artists"
}

function sectionAlbumsPath(sectionId) {
  return "/library/sections/" + sectionId + "/albums"
}

function sectionTracksPath(sectionId) {
  return "/library/sections/" + sectionId + "/tracks"
}

function sectionAllPath(sectionId, which) {
  // `which` is one of artists | albums | tracks | playlists
  return "/library/sections/" + sectionId + "/" + String(which)
}

function childrenPath(key) {
  var k = String(key || "")
  if (k.indexOf("/library/metadata/") === 0) return k + "/children"
  if (k.indexOf("/library/") === 0) return "/library/metadata/" + k.replace("/library/", "") + "/children"
  return "/library/metadata/" + k + "/children"
}

function searchPath(query) {
  return "/library/search?query=" + encodeURIComponent(query || "")
}

function playQueueAll(container) {
  // Used by advanced playlists; not needed for v1.
  return fromMetadata(container)
}
