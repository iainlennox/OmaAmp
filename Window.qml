import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// OmaAmp player window. A layer-shell overlay containing a Plexamp/Winamp-style
// player card: library browser, search, queue and now-playing controls.
//
// Lifecycle: omarchy-shell summons this via `shell.summon("iainlennox.omaamp")`
// which calls open(); hide() calls close(). The shell injects the shared
// `service` (the iainlennox.omaamp service) so the UI reads player state.

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false

  readonly property color cardBg: Color.popups.background
  readonly property color fg: Color.popups.text
  readonly property color sub: Qt.darker(Color.popups.text, 1.32)
  readonly property color faint: Qt.darker(Color.popups.text, 1.6)
  readonly property color accent: Color.accent
  readonly property color sep: Color.popups.border
  readonly property int radius: Math.max(12, Style.cornerRadius)

  property bool showQueue: false
  property string query: ""

  readonly property var items: service ? service.items : []
  readonly property var q: service ? service.queue : []
  readonly property var nowPlaying: service ? service.nowPlaying : null
  readonly property bool connected: service ? service.connected : false

  function open(payload) {
    root.opened = true
    root.showQueue = false
  }

  function close() {
    root.opened = false
  }

  function fmtTime(sec) {
    var s = Math.max(0, Math.floor(Number(sec) || 0))
    var m = Math.floor(s / 60)
    var h = Math.floor(m / 60)
    s = s % 60; m = m % 60
    var p2 = function(n) { return (n < 10 ? "0" : "") + String(n) }
    return h > 0 ? (h + ":" + p2(m) + ":" + p2(s)) : (m + ":" + p2(s))
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

  property var navItems: [
    { label: "Home",       icon: "󰋋", view: "home" },
    { label: "Search",     icon: "󰊾", view: "search" },
    { label: "Artists",    icon: "󰚣", view: "artists" },
    { label: "Albums",     icon: "󰏢", view: "albums" },
    { label: "Songs",      icon: "󰎇", view: "tracks" }
  ]

  function viewTitle() {
    if (!service) return ""
    switch (service.currentView) {
      case "home": return "Home"
      case "search": return query.length > 0 ? ("Search: " + query) : "Search"
      case "artists": return "Artists"
      case "albums": return "Albums"
      case "tracks": return "Songs"
      case "album": return nowPlaying ? nowPlaying.albumTitle : "Album"
      case "artist": return "Artists"
      default: return ""
    }
  }

  Timer {
    id: searchDebounce
    interval: 300
    onTriggered: if (service) service.search(root.query)
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "iainlennox-omaamp"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.45)
      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }
    }

    Rectangle {
      id: win
      width: Math.min(panel.width - 96, 1040)
      height: Math.min(panel.height - 64, 680)
      anchors.centerIn: parent
      radius: root.radius
      color: root.cardBg
      border.color: root.sep
      border.width: Math.max(1, Style.normalBorderWidth)

      MouseArea { anchors.fill: parent; onClicked: {} }
      clip: true

      ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---------------- header ----------------
        Rectangle {
          Layout.fillWidth: true
          implicitHeight: 54
          color: Qt.darker(root.cardBg, 1.12)
          radius: root.radius
          Rectangle {
            anchors.fill: parent
            anchors.top: parent.top
            implicitHeight: root.radius
            color: Qt.darker(root.cardBg, 1.12)
            anchors.left: parent.left; anchors.right: parent.right
          }

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 10
            spacing: 12

            GlyphGlyph {
              glyph: "󰎇"
              fontSize: Style.font.iconLarge
              color: root.accent
              Layout.preferredWidth: 28
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
              name: root.connected && service ? service.serverName : "not connected"
              visible: root.connected || true
              Layout.alignment: Qt.AlignVCenter
            }

            Item { Layout.fillWidth: true }

            TextField {
              id: searchField
              placeholderText: "Search music…"
              foreground: root.fg
              accent: root.accent
              text: root.query
              Layout.preferredWidth: 250
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
              onClicked: root.close()
              Layout.alignment: Qt.AlignVCenter
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
            Layout.preferredWidth: 190
            Layout.fillHeight: true
            spacing: 4
            Layout.leftMargin: 12
            Layout.topMargin: 12
            Layout.bottomMargin: 12

            Repeater {
              model: root.navItems
              delegate: Item {
                required property var modelData
                readonly property bool sel: service && service.currentView === modelData.view
                Layout.fillWidth: true
                implicitHeight: 38

                BorderSurface {
                  anchors.fill: parent
                  radius: Style.spacing.labelGap
                  color: sel ? Style.selectedFillFor(root.fg, root.accent) : "transparent"
                  borderSpec: sel ? Border.controlSpec("selected", root.fg, root.accent) : Border.none()
                }

                RowLayout {
                  anchors.left: parent.left; anchors.right: parent.right
                  anchors.leftMargin: 10
                  anchors.rightMargin: 10
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

            Text {
              text: service && service.currentSectionId ? "Library" : ""
              color: root.faint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              Layout.topMargin: 8
              visible: root.sectionList.count > 0
            }

            ListView {
              id: sectionList
              Layout.fillWidth: true
              Layout.preferredHeight: Math.min(140, contentHeight)
              Layout.topMargin: 6
              model: service ? service.libraries : []
              interactive: false
              delegate: Item {
                required property var modelData
                readonly property bool sel: service && service.currentSectionId === modelData.key
                implicitHeight: 32
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
                  onClicked: {
                    if (service) { service.setSection(modelData.key); service.openView("artists", modelData.key) }
                  }
                }
              }
            }

            Item { Layout.fillHeight: true; Layout.topMargin: 8 }
          }

          // content
          Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: Qt.darker(root.cardBg, 1.04)
            border.left: 1
            border.color: Qt.darker(root.cardBg, 1.16)

            ColumnLayout {
              anchors.fill: parent
              anchors.leftMargin: 16
              anchors.rightMargin: 16
              anchors.topMargin: 14
              anchors.bottomMargin: 6
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
                  visible: root.items.length > 0
                  text: root.items.length + " items"
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
                  when: (service ? service.itemsLoading : false) || root.items.length === 0
                }

                ColumnLayout {
                  anchors.centerIn: parent
                  spacing: 8
                  visible: parent.state === "empty"
                  Text {
                    text: service ? (service.itemsLoading ? "Loading…" : "Nothing here yet") : "OmaAmp"
                    color: root.faint
                    font.family: Style.font.family
                    font.pixelSize: Style.font.subtitle
                    Layout.alignment: Qt.AlignHCenter
                  }
                  Text {
                    text: "Connect a Plex server in ~/.config/omarchy/omaamp.json to browse your music library."
                    color: root.faint
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    Layout.alignment: Qt.AlignHCenter
                    visible: service ? !service.connected : false
                  }
                }

                ListView {
                  id: list
                  anchors.fill: parent
                  visible: parent.state !== "empty"
                  model: root.items
                  spacing: Style.space(5)
                  clip: true
                  ScrollBar.vertical: ScrollBar {}

                  delegate: BusyRow {
                    required property var modelData
                    required property int index
      //                width: list.width
                    onTap: root.playItem(modelData)
                  }
                }
              }
            }
          }
        }

        // ---------------- player bar ----------------
        Rectangle {
          Layout.fillWidth: true
          implicitHeight: 78
          color: Qt.darker(root.cardBg, 1.12)
          radius: root.radius
          Rectangle {
            anchors.fill: parent
            anchors.bottom: parent.bottom
            implicitHeight: root.radius
            color: Qt.darker(root.cardBg, 1.12)
            anchors.left: parent.left; anchors.right: parent.right
          }

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            anchors.topMargin: 6
            anchors.bottomMargin: 6
            spacing: 12

            // cover
            BorderSurface {
              width: 60; height: 60
              radius: Style.spacing.labelGap
              color: Qt.darker(root.cardBg, 1.22)
              borderSpec: Border.controlSpec("normal", root.fg, root.accent)
              Image {
                anchors.fill: parent
                anchors.margins: 2
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                source: root.coverSource
                visible: root.coverSource !== ""
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

            // track info
            ColumnLayout {
              spacing: 2
              Layout.preferredWidth: 210
              Layout.fillWidth: true
              Text {
                text: root.nowPlaying ? root.nowPlaying.title : "Nothing playing"
                color: root.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
                Layout.fillWidth: true
              }
              Text {
                text: root.nowPlaying ? (root.nowPlaying.artistTitle || root.nowPlaying.artist || "Unknown artist") : ""
                color: root.sub
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                Layout.fillWidth: true
                visible: root.nowPlaying !== null
              }
              Text {
                text: root.nowPlaying ? (root.nowPlaying.albumTitle || root.nowPlaying.album || "") : ""
                color: root.faint
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                Layout.fillWidth: true
                visible: root.nowPlaying !== null && (root.nowPlaying.albumTitle || root.nowPlaying.album)
              }
            }

            // seek
            ColumnLayout {
              spacing: 2
              Layout.fillWidth: true
              SliderBar {
                Layout.fillWidth: true
                value: service ? service.position : 0
                maximum: Math.max(0.001, service ? service.duration : 0)
                onScrub: function(sec) { if (service) service.seek(sec) }
              }
              RowLayout {
                Layout.fillWidth: true
                Text {
                  text: root.fmtTime(service ? service.position : 0)
                  color: root.faint
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Item { Layout.fillWidth: true }
                Text {
                  text: root.fmtTime(service ? service.duration : 0)
                  color: root.faint
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // transport
            RowLayout {
              spacing: Style.space(8)
              Button {
                iconText: "󰒮"
                tooltipText: "Previous"
                foreground: root.fg
                onClicked: if (service) service.previous()
              }
              Button {
                iconText: service ? service.playIcon : "󰐊"
                iconSize: Style.font.iconLarge
                tooltipText: "Play/Pause"
                foreground: root.fg
                onClicked: if (service) service.togglePlay()
              }
              Button {
                iconText: "󰒭"
                tooltipText: "Next"
                foreground: root.fg
                onClicked: if (service) service.next()
              }
            }

            // extras
            RowLayout {
              spacing: Style.space(4)
              Button {
                iconText: "󰜗"
                tooltipText: root.shuffle ? "Shuffle on" : "Shuffle off"
                foreground: root.shuffle ? root.accent : root.fg
                onClicked: if (service) service.toggleShuffle()
              }
              Button {
                iconText: "󰑖"
                tooltipText: "Repeat " + (service ? service.repeat : "off")
                foreground: root.repeat !== "off" ? root.accent : root.fg
                onClicked: if (service) service.cycleRepeat()
              }
              Button {
                iconText: "󰝝"
                tooltipText: "Queue"
                foreground: root.showQueue ? root.accent : root.fg
                onClicked: root.toggleQueue()
              }
            }

            // volume
            RowLayout {
              spacing: 8
              Button {
                iconText: service && service.muted ? "󰝞" : "󰝟"
                tooltipText: "Mute"
                foreground: service && service.muted ? root.accent : root.fg
                onClicked: if (service) service.toggleMute()
              }
              SliderBar {
                Layout.preferredWidth: 110
                value: service ? service.volume : 0
                maximum: 100
                onScrub: function(v) { if (service) service.setVolume(v) }
              }
            }
          }
        }
      }

      // ---------------- queue drawer ----------------
      Rectangle {
        id: queueDrawer
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        width: 320
        visible: root.showQueue
        color: Qt.darker(root.cardBg, 1.08)
        border.left: 1
        border.color: Qt.darker(root.cardBg, 1.16)
        radius: root.radius

        ColumnLayout {
          anchors.fill: parent
          anchors.leftMargin: 14
          anchors.rightMargin: 14
          anchors.topMargin: 12
          anchors.bottomMargin: 10
          spacing: 8
          RowLayout {
            Layout.fillWidth: true
            Text {
              text: "Queue"
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
              Layout.fillWidth: true
            }
            Button {
              iconText: "󰞭"
              foreground: root.sub
              onClicked: root.toggleQueue()
            }
          }
          PanelSeparator { Layout.fillWidth: true }
          ListView {
            id: queueList
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: root.q
            spacing: Style.space(4)
            clip: true
            ScrollBar.vertical: ScrollBar {}
            delegate: Item {
              required property var modelData
              required property int index
              readonly property bool cur: service && service.queueIndex === index
              implicitHeight: 40
              width: queueList.width
              Rectangle {
                anchors.fill: parent
                radius: Style.spacing.labelGap
                color: cur ? Style.selectedFillFor(root.fg, root.accent) : "transparent"
              }
              RowLayout {
                anchors.left: parent.left; anchors.right: parent.right
                anchors.leftMargin: 8; anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                Text {
                  text: modelData.title
                  color: cur ? root.accent : root.fg
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: cur
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
                Text {
                  text: root.fmtTime(modelData.duration)
                  color: root.faint
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (service) { service.queueIndex = index; service.loadCurrent(0) }
                }
              }
            }
          }
        }
      }
    }
  }

  // Reusable cover source resolver.
  readonly property string coverSource: nowPlaying ? (service ? service.coverUrl(nowPlaying) : "") : ""
  readonly property bool shuffle: service ? service.shuffle : false
  readonly property string repeat: service ? service.repeat : "off"
  readonly property bool canPlayAll: service ? (service.currentView === "tracks" || service.currentView === "album" || service.currentView === "search") && root.items.length > 0 : false

  // Content row delegate: cover thumbnail + title/subtitle + duration.
  component BusyRow: Item {
    signal tap()
    required property var modelData
    required property int index

    readonly property string sub: modelData.type === "artist"
      ? "Artist"
      : (modelData.artistTitle || modelData.artist || modelData.parentTitle || (modelData.type === "album" ? "Album" : ""))
    readonly property bool isTrack: modelData.type === "track" || modelData.kind === "track" || modelData.fileKey

    implicitHeight: 48

    Rectangle {
      anchors.fill: parent
      radius: Style.spacing.labelGap
      color: mouse.containsMouse ? Qt.darker(root.cardBg, 1.18) : "transparent"
    }

    RowLayout {
      anchors.left: parent.left; anchors.right: parent.right
      anchors.leftMargin: 8; anchors.rightMargin: 12
      anchors.verticalCenter: parent.verticalCenter
      spacing: 10
      height: parent.implicitHeight

      BorderSurface {
        width: 40; height: 40
        radius: Style.spacing.labelGap
        color: Qt.darker(root.cardBg, 1.24)
        borderSpec: Border.none()
        Image {
          anchors.fill: parent; anchors.margins: 1
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          source: service ? service.coverUrl(modelData) : ""
          visible: source !== ""
        }
        Text {
          anchors.centerIn: parent
          visible: parent.source === "" || service === null
          text: isTrack ? "󰎇" : "󰏢"
          color: root.faint
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }

      ColumnLayout {
        spacing: 1
        Layout.fillWidth: true
        Text {
          text: modelData.title || "Untitled"
          color: root.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
          Layout.fillWidth: true
        }
        Text {
          text: sub
          color: root.sub
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          Layout.fillWidth: true
          visible: sub !== ""
        }
      }

      Text {
        text: isTrack ? root.fmtTime(modelData.duration) : ""
        color: root.faint
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        visible: root.svcWide
      }
      Text {
        text: isTrack ? "󰐊" : "󰒲"
        color: mouse.containsMouse ? root.accent : root.faint
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tap()
    }
  }

  readonly property bool svcWide: service ? (service.currentView === "tracks" || service.currentView === "album" || service.currentView === "search") : false

  // Inline slider component.
  component SliderBar: Item {
    id: _slider
    property real value: 0
    property real maximum: 100
    property color fg: root.fg
    property color accent: root.accent
    signal scrub(real value)
    implicitHeight: 18
    implicitWidth: 160

    property real clampedMax: maximum > 0 ? maximum : 1
    property real fraction: Math.min(1, Math.max(0, value / clampedMax))

    Rectangle {
      anchors.left: parent.left; anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      height: 4
      radius: 2
      color: Qt.darker(root.cardBg, 1.3)
    }
    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      height: 4
      radius: 2
      width: parent.width * parent.fraction
      color: accent
    }
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: parent.width * parent.fraction - 5
      width: 10; height: 10; radius: 5
      color: fg
    }
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

  // Inline visualizer glyph.
  component GlyphGlyph: Text {
    property string glyph: ""
    property color glyphColor: root.fg
    property int fontSize: Style.font.body
    text: glyph
    color: glyphColor
    font.family: Style.font.family
    font.pixelSize: fontSize
  }

  // Connection status pill.
  component ConnectionPill: Rectangle {
    property bool connected: false
    property string name: ""
    implicitWidth: Math.max(label.implicitWidth + 26, 64)
    implicitHeight: 22
    radius: 11
    color: connected ? Style.selectedFillFor(root.fg, root.accent) : Qt.darker(root.cardBg, 1.22)
    border.color: connected ? Qt.darker(root.accent, 1.1) : root.sub
    border.width: 1
    Row {
      anchors.centerIn: parent
      spacing: 6
      Rectangle {
        width: 8; height: 8; radius: 4
        anchors.verticalCenter: parent.verticalCenter
        color: connected ? Color.accent : Color.muted
      }
      Text {
        id: label
        anchors.verticalCenter: parent.verticalCenter
        text: name
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: Math.min(140, implicitWidth)
      }
    }
  }
}
