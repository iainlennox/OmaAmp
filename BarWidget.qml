import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// Bar widget for OmaAmp. Shows a music glyph plus the now-playing track when
// playing. Left-click opens the player window; right-click toggles play/pause.

BarWidget {
  id: root
  moduleName: "iainlennox.omaamp"

  readonly property var svc: bar?.shell ? bar.shell.serviceFor("iainlennox.omaamp") : null
  readonly property bool hasTrack: svc ? svc.hasTrack : false
  readonly property bool playing: svc ? svc.playbackState === "playing" : false
  readonly property string title: svc && svc.nowPlaying ? svc.nowPlaying.title : ""
  readonly property string artist: svc && svc.nowPlaying ? (svc.nowPlaying.artistTitle || svc.nowPlaying.artist || "") : ""
  readonly property string status: !svc ? "OmaAmp"
    : (!svc.connected ? "Connect…" : title + (artist ? " – " + artist : ""))

  property bool popupOpen: false

  implicitWidth: row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    WidgetButton {
      id: btn
      text: playing ? "󰎇" : "󰎇"
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      foreground: playing
        ? (root.bar ? root.bar.barForeground : Color.foreground)
        : (root.bar ? Qt.darker(root.bar.barForeground, 1.4) : Qt.darker(Color.foreground, 1.4))
      bar: root.bar
      tooltipText: root.status
      onPressed: function(button) {
        if (root.svc && button === Qt.RightButton) {
          root.svc.togglePlay()
        } else if (root.bar && root.bar.shell) {
          root.bar.shell.toggle("iainlennox.omaamp")
        }
      }
    }

    Text {
      id: label
      anchors.verticalCenter: parent.verticalCenter
      text: root.title + (root.artist ? "  ·  " + root.artist : "")
      color: root.bar ? root.bar.barForeground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      visible: root.hasTrack && !root.bar.vertical
      elide: Text.ElideRight
      width: Math.min(180, implicitWidth)
      Behavior on opacity { NumberAnimation { duration: 160 } }
    }
  }
}
