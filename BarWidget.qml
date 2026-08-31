import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// OmaAmp bar widget. The music glyph sits in the status bar; left-click drops
// the player panel down below the bar at this widget's position, right-click
// toggles play/pause, scroll wheel skips tracks. Exposes the open()/close()/
// opened contract so `omarchy-shell omaamp togglePlayer` (and the bar host)
// can also summon the popup.

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

  property bool opened: false
  function open() { opened = true }
  function close() { opened = false }

  implicitWidth: btnRow.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Row {
    id: btnRow
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "󰎇"
      color: root.bar ? root.bar.barForeground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      opacity: playing ? 1.0 : 0.85
    }

    Text {
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
        if (root.opened) root.close()
        else root.open()
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

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.opened
    triggerMode: "click"
    padding: 0
    contentWidth: popup.fittedContentWidth(1040)
    contentHeight: popup.fittedContentHeight(640)

    PlayerPanel {
      anchors.fill: parent
      service: root.svc
      onDismiss: root.close()
    }
  }
}
