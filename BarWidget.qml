import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// Now-playing bar widget for OmaAmp. Left-click opens/closes the player window,
// right-click toggles play/pause, scroll wheel skips tracks. Uses a full-widget
// MouseArea (like the built-in media widget) so clicks always register.

BarWidget {
  id: root
  moduleName: "iainlennox.omaamp"

  readonly property var svc: bar?.shell ? bar.shell.serviceFor("iainlennox.omaamp") : null
  readonly property bool hasTrack: svc ? svc.hasTrack : false
  readonly property bool playing: svc ? svc.playbackState === "playing" : false
  readonly property string title: svc && svc.nowPlaying ? svc.nowPlaying.title : ""
  readonly property string artist: svc && svc.nowPlaying ? (svc.nowPlaying.artistTitle || svc.nowPlaying.artist || "") : ""
  readonly property string status: !svc ? "OmaAmp"
    : (!svc.connected ? "Connecting…" : (title ? (title + (artist ? " – " + artist : "")) : "OmaAmp"))

  implicitWidth: row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      id: glyph
      anchors.verticalCenter: parent.verticalCenter
      text: playing ? "󰎇" : "󰎇"
      color: root.bar ? root.bar.barForeground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      opacity: playing ? 1.0 : 0.85
    }

    Text {
      id: label
      anchors.verticalCenter: parent.verticalCenter
      text: root.title + (root.artist ? "  ·  " + root.artist : "")
      color: root.bar ? root.bar.barForeground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      visible: root.hasTrack && !root.bar.vertical && root.title !== ""
      elide: Text.ElideRight
      clip: true
      width: Math.min(170, implicitWidth)
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (!root.bar) return
      if (mouse.button === Qt.MiddleButton) {
        root.bar.run("omarchy-shell omaamp next")
      } else if (mouse.button === Qt.RightButton) {
        root.bar.run("omarchy-shell omaamp playPause")
      } else {
        root.bar.run("omarchy-shell shell toggle iainlennox.omaamp '{}'")
      }
    }
    onWheel: function(wheel) {
      if (!root.bar) return
      if (wheel.angleDelta.y > 0) root.bar.run("omarchy-shell omaamp previous")
      else if (wheel.angleDelta.y < 0) root.bar.run("omarchy-shell omaamp next")
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.status)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }
}
