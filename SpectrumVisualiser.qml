import QtQuick
import QtQuick.Layouts
import qs.Commons

// A terminal-era hi-fi spectrum analyser. Renders a fixed number of
// frequency bands as discrete, quantised block levels with a classic
// peak-hold marker above each bar — monochrome palette, square geometry,
// monospace labels, and the Omarchy accent colour for the bars.
//
// This component is purely a *renderer*: it owns no audio acquisition and
// runs no timers. It renders whatever the parent feeds it through `bands`
// (current level, 0..1) and `peaks` (peak-hold level, 0..1). Envelope and
// peak shaping live in the data producer (bin/omaamp-visualizer.py) so the
// shell stays allocation-light — only the fixed Repeater count here.
//
// Usage:
//   SpectrumVisualiser {
//     bands: service ? service.spectrumBands : []
//     peaks: service ? service.spectrumPeaks : []
//     bandCount: 12
//     accent: root.accent
//   }
Item {
  id: root

  // Data (0..1 floats, length == bandCount).
  property var bands: []
  property var peaks: []

  // Presentation.
  property bool active: true            // dims bars when nothing is playing
  property bool available: true         // false => render a quiet baseline only
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color background: "transparent"
  property int bandCount: 12
  property int quantizeLevels: 12       // discrete block steps for each band
  property int barHeight: 26
  property bool showTitle: true
  property string title: "SPECTRUM"
  property var bandLabels: ["60", "170", "310", "600", "1K", "3K", "6K", "12K"]

  // Derived geometry.
  readonly property real _h: barHeight
  readonly property real _cellH: Math.max(1, _h / Math.max(1, quantizeLevels))
  readonly property real _bandW: width / Math.max(1, bandCount)

  implicitHeight: showTitle ? (_h + 20) : (_h + 14)
  implicitWidth: 200

  // Round a continuous 0..1 value down onto the fixed level ladder so the
  // bar lands on whole block steps instead of gliding smoothly.
  function quantize(v) {
    var x = Number(v) || 0
    x = Math.max(0, Math.min(1, x))
    return Math.floor(x * quantizeLevels + 1e-6) / quantizeLevels
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: 0

    // Header: title left, dB scale right.
    RowLayout {
      visible: root.showTitle
      Layout.fillWidth: true
      implicitHeight: 11
      spacing: 0
      Text {
        text: root.title
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        Layout.alignment: Qt.AlignVCenter
      }
      Item { Layout.fillWidth: true }
      Text {
        visible: root.available
        text: "+6     0     -12"
        color: Qt.darker(root.foreground, 1.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }
      Text {
        visible: !root.available
        text: "offline"
        color: Qt.darker(root.foreground, 1.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }
    }

    // Bars.
    Item {
      id: barsArea
      Layout.fillWidth: true
      Layout.preferredHeight: root._h
      Layout.alignment: Qt.AlignTop

      // Baseline.
      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.28)
        visible: root.available
      }

      // Faint horizontal gridlines at each block step -> segmented hardware
      // look without hundreds of objects.
      Repeater {
        model: root.available ? Math.max(1, root.quantizeLevels - 1) : 0
        delegate: Rectangle {
          readonly property int i: index
          width: barsArea.width
          height: 1
          y: barsArea.height - (i + 1) * root._cellH
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
          visible: root.available
        }
      }

      // One column per band: a square block bar + peak marker above it.
      Repeater {
        model: root.bandCount
        delegate: Item {
          readonly property int bandIndex: index
          readonly property real bandVal: {
            var a = root.bands
            var v = bandIndex < a.length ? Number(a[bandIndex]) : 0
            return Number.isFinite(v) ? v : 0
          }
          readonly property real peakVal: {
            var a = root.peaks
            var v = bandIndex < a.length ? Number(a[bandIndex]) : 0
            return Number.isFinite(v) ? v : 0
          }
          width: root._bandW
          height: root._h
          y: 0

          // Discrete bar block.
          Rectangle {
            id: bar
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.max(2, root._bandW - 2)
            height: Math.max(0, root.quantize(bandVal) * parent.height - 1)
            color: root.accent
            opacity: root.active ? 1.0 : 0.45
            visible: root.available && height > 0
          }

          // Peak-hold marker: rises with the signal, lingers above the bar,
          // decays slower than the bar (shaped by the producer).
          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            height: 2
            width: Math.max(2, root._bandW - 2)
            y: Math.max(0, parent.height * (1 - root.quantize(peakVal)) - 3)
            color: Qt.lighter(root.accent, 1.35)
            visible: root.available && peakVal > 0.001
          }
        }
      }
    }

    // Frequency labels.
    RowLayout {
      Layout.fillWidth: true
      spacing: 0
      Layout.topMargin: 2
      Repeater {
        model: root.bandCount
        delegate: Item {
          readonly property int li: index
          width: root._bandW
          implicitHeight: 11
          Text {
            anchors.centerIn: parent
            text: root.bandLabels.length === root.bandCount
              ? String(root.bandLabels[li]) : root.defaultLabel(li, root.bandCount)
            color: root.available ? Qt.darker(root.foreground, 1.45) : Qt.darker(root.foreground, 1.7)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // Humanised log-spaced frequency label for a given band index.
  function defaultLabel(i, n) {
    if (n === 8) {
      var fixed = ["60", "170", "310", "600", "1K", "3K", "6K", "12K"]
      return fixed[i]
    }
    var lo = 30, hi = 12000
    var f = lo * Math.pow(hi / lo, i / Math.max(1, n - 1))
    if (f >= 1000) {
      var k = f / 1000
      return (k >= 10 ? String(Math.round(k)) : String(Math.round(k * 10) / 10)) + "K"
    }
    return String(Math.round(f))
  }
}
