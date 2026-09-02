// Plex REST helpers for OmaAmp.
//
// These are pure functions over the Plex Media Server HTTP API. JSON is
// requested with `Accept: application/json` (the modern, documented way to get
// JSON instead of XML). Everything here is intentionally Quickshell/JS-safe:
// no classes, no arrow functions, no template literals, no `const`.

// ------------------------------------------------------------------ limits
// Defence against unbounded network-controlled data: these caps bound how many
// items we keep and how long any single string field may be. Values are
// generous enough for real libraries but bound memory regardless.

var MAX_ITEMS = 4000           // max items retained per view/response
var MAX_FIELD = 512            // max chars for any normalized string field
var MAX_QUEUE = 2000           // max tracks retained in the play queue

// ------------------------------------------------------------------ utilities

function has(obj, key) {
  return obj !== null && obj !== undefined && obj[key] !== undefined
}

function bool(v) {
  return v === true || v === "1" || v === "true"
}

// Truncate a server-supplied string to MAX_FIELD chars.
function cap(s) {
  if (s === null || s === undefined) return ""
  s = String(s)
  return s.length > MAX_FIELD ? s.substring(0, MAX_FIELD) : s
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
  if (obj.title) return cap(obj.title)
  if (obj.titleSort) return cap(obj.titleSort)
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
// Only http/https schemes are ever used as image sources — never file://,
// data:, javascript:, etc. Absolute URLs are only accepted when their host is
// exactly the configured Plex server, and relative paths are resolved against
// that same server. This keeps a hostile Plex response from pointing QML's
// Image at an arbitrary host or a local file path.
function trustedResource(cfg, resource) {
  if (!resource) return ""
  var s = String(resource)
  if (s.length > MAX_FIELD) return ""
  var l = s.toLowerCase()
  var server = String(cfg.server || "").replace(/\/+$/, "").toLowerCase()
  if (l.indexOf("http://") === 0 || l.indexOf("https://") === 0) {
    var hostStart = s.indexOf("://") + 3
    var slash = s.indexOf("/", hostStart)
    var host = slash === -1 ? s.substring(hostStart) : s.substring(hostStart, slash)
    if (slash === -1) return ""
    // Only trust the configured server's host.
    var serverHostStart = server.indexOf("://") + 3
    var serverSlash = server.indexOf("/", serverHostStart)
    var serverHost = serverSlash === -1 ? server.substring(serverHostStart) : server.substring(serverHostStart, serverSlash)
    if (host.toLowerCase() !== serverHost.toLowerCase()) return ""
    return apiUrl(cfg, s)
  }
  // Relative server path: safe to resolve against the configured server.
  return apiUrl(cfg, s)
}

function thumbUrl(cfg, obj) {
  if (!obj) return ""
  var t = obj.thumb || obj.art || obj.thumbnail || obj.poster || ""
  return trustedResource(cfg, t)
}

function artUrl(cfg, obj) {
  if (!obj) return ""
  var t = obj.art || obj.thumb || obj.background || ""
  return trustedResource(cfg, t)
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
// All string fields are capped (MAX_FIELD) so no single hostile field can
// balloon memory or justify an oversized UI element.
function normalizeItem(raw) {
  if (!raw) return null
  var r = {}
  r.key = cap(raw.key || raw.ratingKey || "")
  r.ratingKey = cap(raw.ratingKey || "")
  r.type = String(raw.type || raw.viewGroup || "").substring(0, 32)
  r.title = titleOf(raw) || "Untitled"
  r.titleSort = cap(raw.titleSort || r.title)
  r.year = Math.max(0, Math.round(Number(raw.year) || 0))
  r.trackCount = Math.max(0, Math.round(Number(raw.leafCount || raw.childCount || 0))) || 0
  r.durationMs = millisecondsOf(raw)
  r.duration = secondsOf(raw)
  r.thumb = cap(raw.thumb || raw.art || "")
  r.art = cap(raw.art || raw.thumb || "")
  r._thumb = r.thumb
  r._art = r.art
  r.artist = cap(raw.originalTitle || raw.artist || raw.grandparentTitle || "")
  r.album = cap(raw.album || raw.parentTitle || "")
  r.artistKey = cap(raw.parentKey || raw.grandparentKey || "")
  r.albumKey = cap(raw.grandparentKey || raw.parentKey || "")
  r.artistTitle = cap(raw.artist || raw.originalTitle || raw.grandparentTitle || raw.parentTitle || "")
  r.albumTitle = cap(raw.album || raw.parentTitle || "")
  r.grandparentTitle = cap(raw.grandparentTitle || "")
  r.parentTitle = cap(raw.parentTitle || "")
  r.viewGroup = String(raw.viewGroup || raw.type || "").substring(0, 32)
  r.fileKey = cap(partKeyOf(raw))
  return r
}

// Collect at most MAX_ITEMS normalized records from an array.
function capList(items) {
  if (!items || !Array.isArray(items)) return []
  return items.length > MAX_ITEMS ? items.slice(0, MAX_ITEMS) : items
}

// Extract music sections from a `/library/sections` response.
function fromSections(container) {
  var c = unpadded(container)
  var out = []
  var dirs = capList(c.Directory)
  for (var i = 0; i < dirs.length; i++) {
    var d = dirs[i]
    var type = String(d.type || "")
    // Music libraries report type "artist" (Plex types music as artists).
    var isMusic = type === "artist" || type === "music" || type === "artist,album,track"
    out.push({
      key: cap(d.key || d.id || ""),
      type: type.substring(0, 32),
      title: titleOf(d) || "Music",
      viewGroup: cap(d.viewGroup || ""),
      music: isMusic
    })
  }
  return out
}

function fromMetadata(container) {
  var c = unpadded(container)
  var out = []
  var items = capList(c.Metadata)
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
  // /library/search returns SearchResult[] each wrapping a Metadata object.
  var srs = capList(c.SearchResult)
  var md = capList(c.Metadata)
  for (var i = 0; i < srs.length; i++) {
    var raw = srs[i] && srs[i].Metadata ? srs[i].Metadata : null
    if (!raw) raw = md[i]
    if (!raw) continue
    var it = normalizeItem(raw)
    var t = it.type
    if (t === "artist") it.kind = "artist"
    else if (t === "album") it.kind = "album"
    else if (t === "track") it.kind = "track"
    else if (it.viewGroup === "track") it.kind = "track"
    else if (it.viewGroup === "album") it.kind = "album"
    else if (it.album) it.kind = "track"
    else it.kind = "track"
    it._thumb = raw.thumb || raw.art || ""
    it._art = raw.art || ""
    it.fileKey = cap(partKeyOf(raw))
    if (it.fileKey) it.kind = "track"
    out.push(it)
  }
  return out
}

// ------------------------------------------------------------------ paths

function sectionsPath() {
  return "/library/sections"
}

// Music library browsing. This server build does not expose the named
// `/library/sections/{id}/artists|albums|tracks` routes, so use the `type`
// filter on `/all` instead (artist=8, album=9, track=10).
function sectionArtistsPath(sectionId) {
  return "/library/sections/" + sectionId + "/all?type=8"
}

function sectionAlbumsPath(sectionId) {
  return "/library/sections/" + sectionId + "/all?type=9"
}

function sectionTracksPath(sectionId) {
  return "/library/sections/" + sectionId + "/all?type=10"
}

function sectionAllPath(sectionId) {
  return "/library/sections/" + sectionId + "/all"
}

function childrenPath(key) {
  var k = String(key || "")
  // Some server builds already return the children path as the item key.
  if (/\/children$/.test(k)) return k
  if (k.indexOf("/library/metadata/") === 0) return k.replace(/\/$/, "") + "/children"
  if (k.indexOf("/library/") === 0) return "/library/metadata/" + k.replace("/library/", "").replace(/\/$/, "") + "/children"
  return "/library/metadata/" + k.replace(/\/$/, "") + "/children"
}

function searchPath(query) {
  return "/library/search?query=" + encodeURIComponent(query || "")
}

function playQueueAll(container) {
  // Used by advanced playlists; not needed for v1.
  return fromMetadata(container)
}
