import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The OmaAmp player UI, hosted inside a bar-widget PopupCard so it drops down
// directly below the status bar at the widget's position. `service` is the
// shared iainlennox.omaamp service (injected by the bar widget).

Item {
  id: root

  property var service: null
  signal dismiss()

  focus: true
  Keys.onPressed: root.handleKeyPressed(event)
  Component.onCompleted: root.forceActiveFocus()

  readonly property color cardBg: Color.popups.background
  readonly property color fg: Color.popups.text
  readonly property color sub: Qt.darker(Color.popups.text, 1.32)
  readonly property color faint: Qt.darker(Color.popups.text, 1.6)
  readonly property color accent: Color.accent

  property bool showQueue: false
  property bool showEq: false
  property bool showSpectrum: true
  property string query: ""
  property bool showRemainingTime: false
  property int selectedIndex: -1

  readonly property bool spectrumShown: root.showSpectrum && service ? true : false
  readonly property bool spectrumAvailable: service ? service.spectrumAvailable : false
  readonly property int spectrumStripH: 38
  readonly property int playerBarH: root.spectrumShown ? (90 + root.spectrumStripH) : 90
  readonly property int eqDrawerW: 392
  readonly property int eqFaderW: 40
  readonly property var eqPresetNames: ["FLAT", "BASS+", "BASS-", "TREBLE+", "TREBLE-", "VOCAL", "ROCK", "ELECTRONIC"]
  readonly property bool homeHeroActive: service ? service.currentView === "home" && service.nowPlaying !== null : false
  readonly property int heroArt: 76

  property var items: service ? service.items : []
  onItemsChanged: root.selectedIndex = -1
  readonly property var nowPlaying: service ? service.nowPlaying : null
  readonly property bool connected: service ? service.connected : false
  readonly property string coverSource: nowPlaying ? (service ? service.coverUrl(nowPlaying) : "") : ""
  readonly property bool shuffle: service ? service.shuffle : false
  readonly property string repeat: service ? service.repeat : "off"
  readonly property bool svcWide: service ? (service.currentView === "tracks" || service.currentView === "album" || service.currentView === "search") : false
  readonly property bool canPlayAll: service ? (service.currentView === "tracks" || service.currentView === "album" || service.currentView === "search") && (service ? service.items.length : 0) > 0 : false

  property var navItems: [
    { label: "Home",    icon: "󰋋", view: "home" },
    { label: "Search",  icon: "󰊾", view: "search" },
    { label: "Artists", icon: "󰚣", view: "artists" },
    { label: "Albums",  icon: "󰏢", view: "albums" },
    { label: "Songs",   icon: "󰎇", view: "tracks" }
  ]

  function fmtTime(sec) {
    var s = Math.max(0, Math.floor(Number(sec) || 0))
    var m = Math.floor(s / 60)
    var h = Math.floor(m / 60)
    s = s % 60; m = m % 60
    var p2 = function(n) { return (n < 10 ? "0" : "") + String(n) }
    return h > 0 ? (h + ":" + p2(m) + ":" + p2(s)) : (m + ":" + p2(s))
  }

  function freqLabel(f) {
    f = Math.max(0, Math.round(Number(f) || 0))
    if (f >= 1000) {
      var k = f / 1000
      return (k >= 10 ? String(Math.round(k)) : String(Math.round(k * 10) / 10)) + "K"
    }
    return String(f)
  }

  function eqBandLabel(i, n) {
    if (!service || !service.eqBandFreqs || i >= service.eqBandFreqs.length) return String(i + 1)
    return root.freqLabel(service.eqBandFreqs[i])
  }

  function go(view) {
    if (!service) return
    service.openView(view)
    if (view === "search") searchField.forceActiveFocus()
  }

  function playItem(item) {
    if (!service || !item) return
    var t = item.type || item.kind
    if (item.kind === "track" || t === "track" || item.fileKey) {
      service.playNow(item)
    } else if (t === "album" || item.viewGroup === "album" || item.album) {
      service.openAlbum(item.key)
    } else if (t === "artist") {
      service.openArtist(item.key)
    } else {
      service.openAlbum(item.key)
    }
  }

  function playAll() {
    if (!service) return
    service.playItemList(service.items, 0)
  }

  function toggleQueue() {
    root.showQueue = !root.showQueue
  }

  function playAlbum(item) {
    if (service && item) service.playAlbum(item)
  }

  function countLabel() {
    if (!service) return ""
    var n = service.items.length
    if (n === 0) return ""
    var word
    switch (service.currentView) {
      case "albums": word = "album"; break
      case "artists": word = "artist"; break
      case "tracks": word = "song"; break
      case "album": word = "song"; break
      case "artist": word = "song"; break
      case "search": word = "result"; break
      default: word = "item"
    }
    return n + " " + word + (n === 1 ? "" : "s")
  }

  function moveSelection(delta) {
    var n = root.items.length
    if (n === 0) return
    var cur = root.selectedIndex < 0 ? 0 : root.selectedIndex
    var nxt = Math.max(0, Math.min(n - 1, cur + delta))
    root.selectedIndex = nxt
    root.ensureRowVisible(nxt)
    root.forceActiveFocus()
  }

  function ensureRowVisible(i) {
    var row = itemsRep.itemAt(i)
    if (!row || !itemsFlick) return
    var viewH = itemsFlick.height
    var y = row.y
    if (y < itemsFlick.contentY) itemsFlick.contentY = y
    else if (y + row.implicitHeight > itemsFlick.contentY + viewH) itemsFlick.contentY = y + row.implicitHeight - viewH
  }

  function activateSelection() {
    var idx = root.selectedIndex
    if (idx < 0 || idx >= root.items.length) return
    var item = root.items[idx]
    if (item) root.playItem(item)
  }

  function queueSelection() {
    var idx = root.selectedIndex
    if (idx < 0 || idx >= root.items.length) return
    var item = root.items[idx]
    if (!item) return
    if (item.type === "track" || item.kind === "track" || item.fileKey) service.addToQueue(item)
  }

  function handleKeyPressed(event) {
    // Never fire global shortcuts while typing into the search field.
    if (searchField.activeFocus) {
      if (event.key === Qt.Key_Escape) {
        searchField.focus = false
        root.forceActiveFocus()
        event.accepted = true
      }
      return
    }
    if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_K) {
      searchField.forceActiveFocus()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Slash) {
      searchField.forceActiveFocus()
      event.accepted = true
      return
    }
    switch (event.key) {
      case Qt.Key_Space:
        if (service) service.togglePlay()
        event.accepted = true
        break
      case Qt.Key_Escape:
        if (root.showQueue) root.showQueue = false
        else root.dismiss()
        event.accepted = true
        break
      case Qt.Key_Up:
        root.moveSelection(-1)
        event.accepted = true
        break
      case Qt.Key_Down:
        root.moveSelection(1)
        event.accepted = true
        break
      case Qt.Key_Return:
      case Qt.Key_Enter:
        root.activateSelection()
        event.accepted = true
        break
      case Qt.Key_Q:
        root.queueSelection()
        event.accepted = true
        break
    }
  }

  function viewTitle() {
    if (!service) return ""
    switch (service.currentView) {
      case "home": return "Home"
      case "search": return query.length > 0 ? ("Search: " + query) : "Search"
      case "artists": return "Artists"
      case "albums": return "Albums"
      case "tracks": return "Songs"
      case "album": return "Album"
      case "artist": return "Artists"
      default: return ""
    }
  }

  Timer {
    id: searchDebounce
    interval: 300
    onTriggered: if (service) service.search(root.query)
  }

  // ------------------------------------------------------------------ shell

  Rectangle {
    anchors.fill: parent
    color: "transparent"
    clip: true

    ColumnLayout {
      anchors.fill: parent
      spacing: 0

      // ---------------- header ----------------
      Rectangle {
        Layout.fillWidth: true
        implicitHeight: 50
        color: Qt.darker(root.cardBg, 1.08)

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: 14
          anchors.rightMargin: 10
          spacing: 12

          Text {
            text: "󰎇"
            color: root.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.iconLarge
            Layout.alignment: Qt.AlignVCenter
          }
          Text {
            text: "OmaAmp"
            color: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
            Layout.alignment: Qt.AlignVCenter
          }
          ConnectionPill {
            connected: root.connected
            connecting: service ? service.connecting : false
            name: root.connected && service ? service.serverName : "not connected"
            Layout.alignment: Qt.AlignVCenter
          }

          Item { Layout.fillWidth: true }

          TextField {
            id: searchField
            placeholderText: "Search music…"
            foreground: root.fg
            accent: root.accent
            text: root.query
            Layout.preferredWidth: 230
            Layout.alignment: Qt.AlignVCenter
            onTextChanged: {
              root.query = text
              searchDebounce.restart()
            }
          }

          Button {
            iconText: "󰞭"
            tooltipText: "Close"
            foreground: root.sub
            onClicked: root.dismiss()
          }
        }
      }

      // ---------------- body ----------------
      RowLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: 0

        // sidebar
        ColumnLayout {
          Layout.preferredWidth: 180
          Layout.fillWidth: false
          Layout.fillHeight: true
          spacing: 4
          Layout.leftMargin: 10
          Layout.topMargin: 10
          Layout.bottomMargin: 10

          Repeater {
            model: root.navItems
            delegate: Item {
              required property var modelData
              readonly property bool sel: service && service.currentView === modelData.view
              Layout.fillWidth: true
              implicitHeight: 36

              BorderSurface {
                anchors.fill: parent
                radius: Style.spacing.labelGap
                color: sel ? Style.selectedFillFor(root.fg, root.accent) : "transparent"
                borderSpec: sel ? Border.controlSpec("selected", root.fg, root.accent) : Border.none()
              }
              RowLayout {
                anchors.left: parent.left; anchors.right: parent.right
                anchors.leftMargin: 10; anchors.rightMargin: 10
                spacing: 10
                Text {
                  text: modelData.icon
                  color: sel ? root.accent : root.sub
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  Layout.preferredWidth: 20
                  Layout.alignment: Qt.AlignVCenter
                }
                Text {
                  text: modelData.label
                  color: sel ? root.fg : root.sub
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: sel
                  Layout.fillWidth: true
                  Layout.alignment: Qt.AlignVCenter
                }
              }
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.go(modelData.view)
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true; Layout.topMargin: 8 }

          ListView {
            id: sectionList
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(120, contentHeight)
            Layout.topMargin: 6
            model: service ? service.libraries : []
            interactive: false
            delegate: Item {
              required property var modelData
              readonly property bool sel: service && service.currentSectionId === modelData.key
              implicitHeight: 30
              width: sectionList.width
              RowLayout {
                anchors.left: parent.left; anchors.right: parent.right
                anchors.leftMargin: 12; anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  text: modelData.title
                  color: sel ? root.accent : root.sub
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: sel
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
              }
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { if (service) { service.setSection(modelData.key); service.openView("artists", modelData.key) } }
              }
            }
          }

          Item { Layout.fillHeight: true; Layout.topMargin: 8 }
        }

        // content
        Rectangle {
          Layout.fillWidth: true
          Layout.fillHeight: true
          color: Qt.darker(root.cardBg, 1.03)
          Rectangle { anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.left: parent.left; width: 1; color: Qt.darker(root.cardBg, 1.16) }

          ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            anchors.topMargin: 12
            anchors.bottomMargin: 8
            spacing: 8

            RowLayout {
              Layout.fillWidth: true
              Text {
                text: root.viewTitle()
                color: root.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                font.bold: true
                Layout.fillWidth: true
                elide: Text.ElideRight
              }
              Text {
                visible: root.countLabel() !== ""
                text: root.countLabel()
                color: root.faint
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              Button {
                text: "Play all"
                iconText: "󰐊"
                visible: root.canPlayAll
                onClicked: root.playAll()
              }
            }

            PanelSeparator { Layout.fillWidth: true }

            Item {
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true

              states: State {
                name: "empty"
                when: (service ? service.itemsLoading : false) || (service ? service.items.length : 0) === 0
              }

              ColumnLayout {
                anchors.centerIn: parent
                spacing: 8
                visible: parent.state === "empty" && !root.homeHeroActive
                Text { text: service ? (service.itemsLoading ? "Loading…" : "Nothing here yet") : "OmaAmp"; color: root.faint; font.family: Style.font.family; font.pixelSize: Style.font.subtitle; Layout.alignment: Qt.AlignHCenter }
                Text { text: "Connect a Plex server in ~/.config/omarchy/omaamp.json to browse your music library."; color: root.faint; font.family: Style.font.family; font.pixelSize: Style.font.caption; Layout.alignment: Qt.AlignHCenter; visible: service ? !service.connected : false }
              }

              // Home "now playing" hero: larger artwork + metadata with the
              // spectrum analyser, in the shell's own design language.
              ColumnLayout {
                id: homeHero
                anchors.fill: parent
                anchors.topMargin: Style.space(6)
                visible: root.homeHeroActive
                spacing: Style.space(8)

                RowLayout {
                  Layout.fillWidth: true
                  Text { text: "NOW PLAYING"; color: root.accent; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                  Item { Layout.fillWidth: true }
                  Text { text: root.nowPlaying ? (root.nowPlaying.albumTitle || root.nowPlaying.album || "") : ""; color: root.faint; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: 14
                  BorderSurface {
                    id: heroCover
                    Layout.preferredWidth: root.heroArt
                    Layout.preferredHeight: root.heroArt
                    radius: Style.spacing.labelGap
                    color: Qt.darker(root.cardBg, 1.22)
                    borderSpec: Border.controlSpec("normal", root.fg, root.accent)
                    Image {
                      anchors.fill: parent; anchors.margins: 2
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      source: root.coverSource
                      visible: source !== ""
                    }
                    Text {
                      anchors.centerIn: parent
                      visible: root.coverSource === ""
                      text: "󰎇"
                      color: root.faint
                      font.family: Style.font.family
                      font.pixelSize: Style.font.displayLarge
                    }
                  }
                  ColumnLayout {
                    spacing: 2
                    Layout.alignment: Qt.AlignVCenter
                    Text { text: root.nowPlaying ? root.nowPlaying.title : "Nothing playing"; color: root.fg; font.family: Style.font.family; font.pixelSize: Style.font.title; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                    Text { text: root.nowPlaying ? (root.nowPlaying.artistTitle || root.nowPlaying.artist || "") : ""; color: root.sub; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight; Layout.fillWidth: true }
                    Text { text: root.nowPlaying ? (root.nowPlaying.albumTitle || root.nowPlaying.album || "") : ""; color: root.faint; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true; visible: root.nowPlaying !== null && (root.nowPlaying.albumTitle || root.nowPlaying.album) }
                  }
                  Item { Layout.fillWidth: true }
                }

                SpectrumVisualiser {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 38
                  Layout.topMargin: Style.space(2)
                  bands: service ? service.spectrumBands : []
                  peaks: service ? service.spectrumPeaks : []
                  bandCount: service ? service.spectrumBandCount : 12
                  foreground: root.fg
                  accent: root.accent
                  active: service ? service.playbackState === "playing" : false
                  available: service ? service.spectrumAvailable : false
                  barHeight: 26
                  showTitle: true
                  title: "SPECTRUM"
                }

                Item { Layout.fillHeight: true; Layout.topMargin: 8 }
              }

              Flickable {
                id: itemsFlick
                anchors.fill: parent
                visible: parent.state !== "empty"
                contentHeight: col.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                clip: true
                ScrollBar.vertical: ScrollBar {}
                Column {
                  id: col
                  width: parent.width
                  spacing: Style.space(5)
                  Repeater {
                    id: itemsRep
                    model: service ? service.items : []
                    delegate: BusyRow {
                      width: col.width
                      highlighted: root.selectedIndex === index
                      onTap: { root.selectedIndex = index; root.forceActiveFocus(); root.playItem(modelData) }
                    }
                  }
                }
              }
            }
          }
        }
      }

      // ---------------- player bar ----------------
      // Three broad regions (LEFT metadata / CENTRE seek+transport / RIGHT
      // secondary + volume) separated by widths and spacing, no hard dividers.
      // A retro spectrum analyser strip sits above the transport row when the
      // analyser backend is available and the visualiser is shown.
      Rectangle {
        Layout.fillWidth: true
        implicitHeight: root.playerBarH
        color: Qt.darker(root.cardBg, 1.08)

        ColumnLayout {
          anchors.fill: parent
          spacing: 0

          // SPECTRUM strip
          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: root.spectrumStripH
            visible: root.spectrumShown
            color: "transparent"

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: 12
              anchors.rightMargin: 12
              spacing: 12
              Text {
                text: "SPECTRUM"
                color: root.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                Layout.alignment: Qt.AlignVCenter
              }
              SpectrumVisualiser {
                visible: root.spectrumAvailable
                Layout.fillWidth: true
                Layout.preferredHeight: root.spectrumStripH
                bands: service ? service.spectrumBands : []
                peaks: service ? service.spectrumPeaks : []
                bandCount: service ? service.spectrumBandCount : 12
                quantizeLevels: 12
                foreground: root.fg
                accent: root.accent
                active: service ? service.playbackState === "playing" : false
                available: root.spectrumAvailable
                barHeight: root.spectrumStripH - 16
                showTitle: false
              }
              Text {
                visible: !root.spectrumAvailable
                text: "unavailable"
                color: root.faint
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                elide: Text.ElideRight
              }
            }
          }

          // main transport row
          RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 14

          // LEFT: artwork + now-playing metadata
          Item {
            Layout.preferredWidth: 260
            Layout.minimumWidth: 180
            Layout.maximumWidth: 320
            Layout.fillHeight: true
            RowLayout {
              anchors.fill: parent
              spacing: 10
              BorderSurface {
                Layout.preferredWidth: 54
                Layout.preferredHeight: 54
                radius: Style.spacing.labelGap
                color: Qt.darker(root.cardBg, 1.22)
                borderSpec: Border.controlSpec("normal", root.fg, root.accent)
                Image {
                  anchors.fill: parent; anchors.margins: 2
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  source: root.coverSource
                  visible: source !== ""
                }
                Text {
                  anchors.centerIn: parent
                  visible: root.coverSource === ""
                  text: "󰎇"
                  color: root.faint
                  font.family: Style.font.family
                  font.pixelSize: Style.font.displayLarge
                }
              }
              ColumnLayout {
                spacing: 2
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                Text { text: root.nowPlaying ? root.nowPlaying.title : "Nothing playing"; color: root.fg; font.family: Style.font.family; font.pixelSize: Style.font.subtitle; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                Text { text: root.nowPlaying ? (root.nowPlaying.artistTitle || root.nowPlaying.artist || "Unknown artist") : ""; color: root.sub; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight; Layout.fillWidth: true; visible: root.nowPlaying !== null }
                Text { text: root.nowPlaying ? (root.nowPlaying.albumTitle || root.nowPlaying.album || "") : ""; color: root.faint; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight; Layout.fillWidth: true; visible: root.nowPlaying !== null && (root.nowPlaying.albumTitle || root.nowPlaying.album) }
              }
            }
          }

          // CENTRE: seek + transport
          ColumnLayout {
            Layout.fillWidth: true
            Layout.minimumWidth: 240
            Layout.alignment: Qt.AlignVCenter
            spacing: 3
            SliderBar {
              Layout.fillWidth: true
              value: service ? service.position : 0
              maximum: Math.max(0.001, service ? service.duration : 0)
              onScrub: function(sec) { if (service) service.seek(sec) }
            }
            RowLayout {
              Layout.fillWidth: true
              Text { text: root.fmtTime(service ? service.position : 0); color: root.faint; font.family: Style.font.family; font.pixelSize: Style.font.caption }
              Item { Layout.fillWidth: true }
              Text {
                readonly property real remaining: service ? Math.max(0, service.duration - service.position) : 0
                text: root.showRemainingTime ? "-" + root.fmtTime(remaining) : root.fmtTime(service ? service.duration : 0)
                color: root.faint
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.showRemainingTime = !root.showRemainingTime
                }
              }
            }
            RowLayout {
              Layout.fillWidth: true
              Item { Layout.fillWidth: true }
              Button { iconText: "󰒮"; iconSize: Style.font.heading; tooltipText: "Previous"; foreground: root.fg; onClicked: if (service) service.previous() }
              Button { iconText: service ? service.playIcon : "󰐊"; iconSize: Style.font.iconLarge + 6; tooltipText: "Play/Pause"; foreground: root.fg; onClicked: if (service) service.togglePlay() }
              Button { iconText: "󰒭"; iconSize: Style.font.heading; tooltipText: "Next"; foreground: root.fg; onClicked: if (service) service.next() }
              Item { Layout.fillWidth: true }
            }
          }

          // RIGHT: shuffle/repeat/queue + volume
          ColumnLayout {
            spacing: Style.space(5)
            Layout.alignment: Qt.AlignVCenter
            RowLayout {
              spacing: Style.space(4)
              Button { iconText: "󰜗"; iconSize: Style.font.body; tooltipText: root.shuffle ? "Shuffle on" : "Shuffle off"; foreground: root.shuffle ? root.accent : root.fg; onClicked: if (service) service.toggleShuffle() }
              Button { iconText: "󰑖"; iconSize: Style.font.body; tooltipText: "Repeat " + root.repeat; foreground: root.repeat !== "off" ? root.accent : root.fg; onClicked: if (service) service.cycleRepeat() }
              Button { iconText: "󰝝"; iconSize: Style.font.body; tooltipText: "Queue"; foreground: root.showQueue ? root.accent : root.fg; onClicked: root.toggleQueue() }
            }
            RowLayout {
              spacing: 8
              Button { iconText: service && service.muted ? "󰝞" : "󰝟"; iconSize: Style.font.body; tooltipText: "Mute"; foreground: service && service.muted ? root.accent : root.fg; onClicked: if (service) service.toggleMute() }
              SliderBar { Layout.preferredWidth: 96; value: service ? service.volume : 0; maximum: 100; onScrub: function(v) { if (service) service.setVolume(v) } }
            }
            RowLayout {
              spacing: Style.space(2)
              Button {
                text: "VIS"
                fontSize: Style.font.caption
                fontFamily: Style.font.family
                verticalPadding: 2
                horizontalPadding: Style.spacing.xs
                tooltipText: root.spectrumShown ? "Hide spectrum" : (root.spectrumAvailable ? "Show spectrum" : "Spectrum needs the optional 'cava' analyser to be installed")
                foreground: root.spectrumShown ? root.accent : (service && service.spectrumAvailable ? root.fg : root.sub)
                enabled: service ? true : false
                onClicked: if (service) root.showSpectrum = !root.showSpectrum
              }
              Button {
                text: "EQ"
                fontSize: Style.font.caption
                fontFamily: Style.font.family
                verticalPadding: 2
                horizontalPadding: Style.spacing.xs
                tooltipText: root.showEq ? "Close equaliser" : "Open equaliser"
                foreground: service && service.eqAvailable && service.eqEnabled ? root.accent : (service && service.eqAvailable ? root.fg : root.faint)
                enabled: service ? service.eqAvailable : false
                onClicked: if (service && service.eqAvailable) root.showEq = !root.showEq
              }
            }
          }
        }
      }
    }
    }

    // ---------------- equaliser drawer ----------------
    Rectangle {
      id: eqDrawer
        anchors.top: parent.top
        anchors.topMargin: 50
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.playerBarH
        anchors.right: parent.right
        width: root.eqDrawerW
        visible: root.showEq && service
        color: Qt.darker(root.cardBg, 1.06)
        z: 20
        Rectangle { anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.left: parent.left; width: 1; color: Qt.darker(root.cardBg, 1.16) }

        ColumnLayout {
          anchors.fill: parent
          anchors.leftMargin: 14; anchors.rightMargin: 14
          anchors.topMargin: 12; anchors.bottomMargin: 10
          spacing: 8
          RowLayout {
            Layout.fillWidth: true
            Text { text: "EQUALIZER"; color: root.fg; font.family: Style.font.family; font.pixelSize: Style.font.heading; font.bold: true; Layout.fillWidth: true }
            Button {
              text: service && service.eqEnabled ? "ON" : "OFF"
              fontSize: Style.font.caption
              fontFamily: Style.font.family
              tooltipText: service && service.eqEnabled ? "Equaliser on (click to disable)" : "Equaliser off (click to enable)"
              foreground: service && service.eqEnabled ? root.accent : root.sub
              onClicked: if (service) service.setEqEnabled(!service.eqEnabled)
            }
            Button { iconText: "󰞭"; foreground: root.sub; onClicked: root.showEq = false }
          }

          // 8-band faders.
          RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: 4
            spacing: Style.space(4)
            Repeater {
              model: service ? service.eqBandFreqs : []
              delegate: EqFader {
                implicitWidth: root.eqFaderW
                required property var modelData
                required property int index
                band: root.eqBandLabel(index, service ? service.eqBandFreqs.length : 0)
                bandIndex: index
                value: service ? Number(service.eqGains[index]) : 0
                onChanged: function(v) { if (service) service.setEqGain(bandIndex, v) }
              }
            }
          }

          // Presets.
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            Text { text: "PRESET"; color: root.faint; font.family: Style.font.family; font.pixelSize: Style.font.caption }
            GridLayout {
              Layout.fillWidth: true
              columns: 4
              columnSpacing: Style.space(4)
              rowSpacing: Style.space(4)
              Repeater {
                model: root.eqPresetNames
                delegate: Button {
                  required property var modelData
                  text: modelData
                  fontSize: Style.font.caption
                  fontFamily: Style.font.family
                  foreground: service && service.eqPreset === modelData ? root.accent : root.sub
                  implicitHeight: 22
                  onClicked: if (service) service.setEqPreset(modelData)
                }
              }
            }
          }
        }
      }

      // ---------------- queue drawer ----------------
    Rectangle {
      id: queueDrawer
      anchors.top: parent.top
      anchors.topMargin: 50
      anchors.bottom: parent.bottom
      anchors.bottomMargin: root.playerBarH
      anchors.right: parent.right
      width: 320
      visible: root.showQueue
      color: Qt.darker(root.cardBg, 1.06)
      z: 20
      Rectangle { anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.left: parent.left; width: 1; color: Qt.darker(root.cardBg, 1.16) }

      ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 14; anchors.rightMargin: 14
        anchors.topMargin: 12; anchors.bottomMargin: 10
        spacing: 8
        RowLayout {
          Layout.fillWidth: true
          Text { text: "Queue"; color: root.fg; font.family: Style.font.family; font.pixelSize: Style.font.heading; font.bold: true; Layout.fillWidth: true }
          Button { iconText: "󰞭"; foreground: root.sub; onClicked: root.toggleQueue() }
        }
        PanelSeparator { Layout.fillWidth: true }
        ListView {
          id: queueList
          Layout.fillWidth: true
          Layout.fillHeight: true
          model: service ? service.queue : []
          spacing: Style.space(4)
          clip: true
          ScrollBar.vertical: ScrollBar {}
          delegate: Item {
            required property var modelData
            required property int index
            readonly property bool cur: service && service.queueIndex === index
            implicitHeight: 40
            width: queueList.width
            Rectangle { anchors.fill: parent; radius: Style.spacing.labelGap; color: cur ? Style.selectedFillFor(root.fg, root.accent) : (qHover.containsMouse ? Qt.darker(root.cardBg, 1.14) : "transparent") }
            Rectangle {
              width: 3; height: parent.height - 12
              anchors.left: parent.left; anchors.leftMargin: 3
              anchors.verticalCenter: parent.verticalCenter
              radius: 1.5; color: root.accent; visible: cur
            }
            RowLayout {
              anchors.left: parent.left; anchors.right: parent.right
              anchors.leftMargin: 12; anchors.rightMargin: 8
              anchors.verticalCenter: parent.verticalCenter
              spacing: 8
              Text { text: modelData.title; color: cur ? root.accent : root.fg; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; font.bold: cur; elide: Text.ElideRight; Layout.fillWidth: true }
              Text { text: root.fmtTime(modelData.duration); color: root.faint; font.family: Style.font.family; font.pixelSize: Style.font.caption }
            }
            MouseArea {
              id: qHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { if (service) { service.queueIndex = index; service.loadCurrent(0) } }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------------ bits

  // Content list row: cover + metadata + a context-aware right affordance.
  // A single MouseArea handles the row: album artwork and the trailing action
  // glyph both trigger album playback, everything else opens/plays the row.
  // This keeps nested-MouseArea event handling out of the picture entirely.
  component BusyRow: Item {
    signal tap()
    required property var modelData
    required property int index
    property bool highlighted: false

    readonly property bool isArtist: modelData.type === "artist" || modelData.kind === "artist" || modelData.viewGroup === "artist"
    readonly property bool isAlbum: modelData.type === "album" || modelData.kind === "album" || modelData.viewGroup === "album"
    readonly property bool isTrack: modelData.type === "track" || modelData.kind === "track" || modelData.fileKey
    readonly property string _artist: modelData.artistTitle || modelData.artist || modelData.originalTitle || modelData.parentTitle || ""
    readonly property int _trackCount: Number(modelData.trackCount) || 0
    readonly property bool _isNow: isTrack && service && service.nowPlaying && modelData.key === service.nowPlaying.key
    readonly property bool _ctxAlbum: service && service.currentView === "album"

    function subtitleText() {
      if (isAlbum) {
        var a = []
        if (_artist) a.push(_artist)
        if (Number(modelData.year) > 0) a.push(String(modelData.year))
        return a.join(" · ")
      }
      if (isTrack) {
        var b = []
        if (_artist) b.push(_artist)
        var alb = modelData.albumTitle || modelData.album || ""
        if (alb && alb !== (modelData.title || "") && !_ctxAlbum) b.push(alb)
        return b.join(" · ")
      }
      return ""
    }

    implicitHeight: 58

    Rectangle {
      anchors.fill: parent
      radius: Style.spacing.labelGap
      color: highlighted ? Style.selectedFillFor(root.fg, root.accent)
        : (m.containsMouse ? Qt.darker(root.cardBg, 1.16) : "transparent")
    }

    Rectangle {
      width: 3; height: parent.height - 16
      anchors.left: parent.left; anchors.leftMargin: 2
      anchors.verticalCenter: parent.verticalCenter
      radius: 1.5
      color: root.accent
      visible: _isNow
    }

    BorderSurface {
      id: cover
      x: 6
      anchors.verticalCenter: parent.verticalCenter
      width: 46; height: 46
      radius: Style.spacing.labelGap
      color: Qt.darker(root.cardBg, 1.22)
      borderSpec: Border.none()
      Image { anchors.fill: parent; anchors.margins: 1; fillMode: Image.PreserveAspectCrop; asynchronous: true; source: service ? service.coverUrl(modelData) : ""; visible: source !== "" }
      Text { anchors.centerIn: parent; visible: parent.source === "" || service === null; text: isTrack ? "󰎇" : "󰏢"; color: root.faint; font.family: Style.font.family; font.pixelSize: Style.font.body }
    }

    Rectangle {
      id: playOverlay
      x: cover.x
      anchors.verticalCenter: parent.verticalCenter
      width: cover.width; height: cover.height
      radius: cover.radius
      color: root.cardBg
      opacity: 0.66
      visible: isAlbum && m.containsMouse
      Text { anchors.centerIn: parent; text: "󰐊"; color: root.accent; font.family: Style.font.family; font.pixelSize: Style.font.iconLarge }
    }

    Column {
      id: labelCol
      anchors.left: cover.right
      anchors.right: rightBits.left
      anchors.leftMargin: 10
      anchors.rightMargin: 10
      anchors.verticalCenter: parent.verticalCenter
      spacing: 2
      Text { text: modelData.title || "Untitled"; color: _isNow ? root.accent : root.fg; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; font.bold: true; elide: Text.ElideRight; width: parent.width }
      Text { text: subtitleText(); color: root.sub; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight; width: parent.width; visible: subtitleText() !== "" }
    }

    RowLayout {
      id: rightBits
      anchors.right: parent.right
      anchors.rightMargin: 12
      anchors.verticalCenter: parent.verticalCenter
      spacing: 10

      Text {
        visible: isAlbum && _trackCount > 0
        text: _trackCount + " " + (_trackCount === 1 ? "track" : "tracks")
        color: root.faint
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      Text {
        id: durText
        visible: root.svcWide && isTrack
        text: root.fmtTime(modelData.duration)
        color: _isNow ? root.accent : root.faint
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Item {
        Layout.preferredWidth: 24
        Layout.preferredHeight: 24
        Text {
          visible: isAlbum
          anchors.centerIn: parent
          text: "⋯"
          color: m.containsMouse ? root.accent : root.faint
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Text {
          visible: isArtist
          anchors.centerIn: parent
          text: "→"
          color: m.containsMouse ? root.accent : root.faint
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Text {
          visible: isTrack && !_isNow
          anchors.centerIn: parent
          text: "󰐊"
          color: m.containsMouse ? root.accent : root.faint
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
        RowLayout {
          visible: isTrack && _isNow
          anchors.centerIn: parent
          spacing: 2
          Rectangle { width: 3; height: 10; color: root.accent; Layout.alignment: Qt.AlignVCenter }
          Rectangle { width: 3; height: 15; color: root.accent; Layout.alignment: Qt.AlignVCenter }
          Rectangle { width: 3; height: 7; color: root.accent; Layout.alignment: Qt.AlignVCenter }
        }
      }
    }

    MouseArea {
      id: m
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        var w = width
        if (isAlbum) {
          if (mouse.x <= cover.x + cover.width || mouse.x >= w - 30) {
            root.selectedIndex = index
            root.forceActiveFocus()
            root.playAlbum(modelData)
            return
          }
        }
        tap()
      }
    }
  }

  // Progress / volume slider.
  component SliderBar: Item {
    id: _slider
    property real value: 0
    property real maximum: 100
    property color fg: root.fg
    property color accent: root.accent
    signal scrub(real value)
    implicitHeight: 18
    implicitWidth: 150
    property real clampedMax: maximum > 0 ? maximum : 1
    property real fraction: Math.min(1, Math.max(0, value / clampedMax))
    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; height: 4; radius: 2; color: Qt.darker(root.cardBg, 1.3) }
    Rectangle { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; height: 4; radius: 2; width: parent.width * parent.fraction; color: accent }
    Rectangle { anchors.verticalCenter: parent.verticalCenter; x: parent.width * parent.fraction - 5; width: 10; height: 10; radius: 5; color: fg }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onPressed: function(m) { _slider.setFromX(m.x) }
      onPositionChanged: function(m) { if (m.buttons & Qt.LeftButton) _slider.setFromX(m.x) }
    }
    function setFromX(x) {
      var frac = Math.min(1, Math.max(0, x / width))
      scrub(frac * clampedMax)
    }
  }

  // Vertical graphic-EQ fader: thin 1px-ish track, square handle, monospace
  // dB label and frequency tag. Pure in the Omarchy palette, no gloss.
  component EqFader: Item {
    id: fader
    property string band: ""
    required property int bandIndex
    property real value: 0
    property color accent: root.accent

    signal changed(real v)

    Layout.fillWidth: true
    Layout.fillHeight: true
    implicitWidth: 40
    implicitHeight: 130

    readonly property real maxV: 12
    readonly property real minV: -12
    readonly property real trackTop: 16
    readonly property real trackH: Math.max(28, height - 34)
    readonly property real trackBottom: trackTop + trackH
    readonly property real _frac: Math.max(0, Math.min(1, (maxV - value) / (maxV - minV)))

    // thin track
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: 2
      y: fader.trackTop
      height: fader.trackH
      color: Qt.darker(root.cardBg, 1.3)
    }
    // accent fill from the bottom up to the handle
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: 2
      y: fader.trackTop + fader._frac * fader.trackH
      height: Math.max(0, fader.trackH * (1 - fader._frac))
      color: fader.accent
      visible: fader.trackH * (1 - fader._frac) > 1
    }
    // square handle, 1px border
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: 13; height: 11
      radius: 0
      color: root.fg
      y: fader.trackTop + fader._frac * fader.trackH - 5
      border.width: 1
      border.color: fader.accent
    }

    // db value at the top
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      text: fader.valueLabel()
      color: fader.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    // scale markers on the left
    Text { anchors.left: parent.left; anchors.leftMargin: 1; y: fader.trackTop - 9; text: "+12"; color: root.faint; font.family: Style.font.family; font.pixelSize: Style.font.caption }
    Text { anchors.left: parent.left; anchors.leftMargin: 1; y: fader.trackTop + fader.trackH / 2 - 6; text: "0"; color: root.faint; font.family: Style.font.family; font.pixelSize: Style.font.caption }
    Text { anchors.left: parent.left; anchors.leftMargin: 1; y: fader.trackBottom - 9; text: "-12"; color: root.faint; font.family: Style.font.family; font.pixelSize: Style.font.caption }
    // frequency tag at the bottom
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      text: fader.band
      color: root.sub
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.UpArrowCursor
      onPressed: function(m) { fader.setFromY(m.y) }
      onPositionChanged: function(m) { if (m.buttons & Qt.LeftButton) fader.setFromY(m.y) }
    }

    function valueLabel() {
      var r = Math.round(value)
      return (r > 0 ? "+" : "") + String(r)
    }
    function setFromY(y) {
      var f = (y - trackTop) / trackH
      f = Math.max(0, Math.min(1, f))
      var v = Math.round(maxV - f * (maxV - minV))
      v = Math.max(minV, Math.min(maxV, v))
      if (v !== value) {
        value = v
        changed(v)
      }
    }
  }

  // Connection status pill: connected / connecting / disconnected.
  component ConnectionPill: Rectangle {
    property bool connected: false
    property bool connecting: false
    property string name: ""
    readonly property bool _connecting: connecting && !connected
    implicitWidth: Math.max(label.implicitWidth + 24, 60)
    implicitHeight: 22
    radius: 11
    color: connected ? Style.selectedFillFor(root.fg, root.accent) : Qt.darker(root.cardBg, 1.2)
    border.color: connected ? Qt.darker(root.accent, 1.1) : (_connecting ? root.sub : Qt.lighter(root.sub, 1.6))
    border.width: 1
    Row {
      anchors.centerIn: parent
      spacing: 6
      Rectangle { width: 8; height: 8; radius: 4; anchors.verticalCenter: parent.verticalCenter; color: connected ? Color.accent : (_connecting ? root.sub : Color.muted) }
      Text {
        id: label
        anchors.verticalCenter: parent.verticalCenter
        text: _connecting ? "Connecting…" : name
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: Math.min(130, implicitWidth)
      }
    }
  }
}
