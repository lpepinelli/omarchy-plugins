import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root
  moduleName: "pepinelli.split-keyboard-battery"
  ipcTarget: "pepinelli.split-keyboard-battery"

  property bool connected: false
  property string deviceName: ""
  property var halves: []

  readonly property string scriptPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/pepinelli.split-keyboard-battery/read-batteries.py"
  readonly property int refreshMs: Math.max(15, Number(setting("refreshIntervalSec", 60))) * 1000
  readonly property int lowPercent: Number(setting("lowPercent", 20))
  readonly property bool refreshing: queryProc.running
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool low: {
    for (var i = 0; i < halves.length; i++) {
      if (Number(halves[i].percent) <= lowPercent) return true
    }
    return false
  }

  function refresh() {
    if (queryProc.running) return
    queryProc.running = true
  }

  function applyReading(text) {
    var data
    try {
      data = JSON.parse(text || "")
    } catch (e) {
      return
    }
    if (!data || data.error) return
    var keyboards = data.keyboards || []
    if (!data.connected || keyboards.length === 0) {
      connected = false
      deviceName = ""
      halves = []
      return
    }
    var collected = []
    var names = []
    for (var i = 0; i < keyboards.length; i++) {
      var keyboard = keyboards[i]
      names.push(keyboard.name || "Keyboard")
      var keyboardHalves = keyboard.halves || []
      for (var j = 0; j < keyboardHalves.length; j++) collected.push(keyboardHalves[j])
    }
    deviceName = names.join(", ")
    halves = collected
    connected = collected.length > 0
  }

  function percentages() {
    var parts = []
    for (var i = 0; i < halves.length; i++) parts.push(String(halves[i].percent))
    return parts
  }

  function labelText() {
    var parts = percentages()
    if (parts.length === 0) return ""
    if (bar && bar.vertical) return parts.join("\n")
    return "󰌌 " + parts.join("/")
  }

  function tooltip() {
    if (!connected || opened) return ""
    var lines = [deviceName]
    for (var i = 0; i < halves.length; i++) {
      lines.push(halves[i].label + " " + halves[i].percent + "%")
    }
    return lines.join("\n")
  }

  function batteryIcon(percent) {
    var icons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    var index = Math.max(0, Math.min(9, Math.floor(Number(percent) / 10)))
    return icons[index]
  }

  function halfDetail(label) {
    if (String(label).indexOf("Right") === 0) return "Other half"
    return "Paired here"
  }

  function estimateText() {
    if (halves.length === 0) return ""
    var parts = []
    var known = 0
    for (var i = 0; i < halves.length; i++) {
      var half = halves[i]
      var name = String(half.label || "").toUpperCase()
      if (half.estimate) {
        known++
        parts.push(name + " ~" + String(half.estimate).toUpperCase())
      } else {
        parts.push(name + " …")
      }
    }
    if (known === 0) return "ESTIMATING TIME LEFT"
    return parts.join("  ·  ")
  }

  onOpenedChanged: if (opened) refresh()
  onConnectedChanged: if (!connected) close()

  Timer {
    interval: root.refreshMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: stallTimer
    interval: 10000
    onTriggered: queryProc.running = false
  }

  Process {
    id: queryProc
    command: ["python3", root.scriptPath]
    onRunningChanged: running ? stallTimer.restart() : stallTimer.stop()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyReading(text)
    }
  }

  visible: connected
  implicitWidth: connected ? button.implicitWidth : 0
  implicitHeight: connected ? button.implicitHeight : 0

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.labelText()
    fontSize: Style.font.bodySmall
    active: root.low
    tooltipText: root.tooltip()
    onPressed: function(b) {
      if (!root.connected) return
      if (b === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.connected
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { if (text === "r" || text === "R") root.refresh() }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(16)

        PanelHero {
          width: parent.width
          title: root.deviceName || "Keyboard"
          meta: root.low ? "Low battery" : "Split keyboard"
          foreground: root.low ? root.urgent : root.foreground
          fontFamily: root.fontFamily
          iconComponent: keyboardIcon
          trailingControl: refreshControl
        }

        Row {
          id: halfRow
          width: parent.width
          spacing: Style.space(10)

          Repeater {
            model: root.halves

            HalfCard {
              required property var modelData
              width: root.halves.length > 0
                ? (halfRow.width - halfRow.spacing * (root.halves.length - 1)) / root.halves.length
                : halfRow.width
              label: modelData.label
              percent: Number(modelData.percent)
            }
          }
        }

        Text {
          visible: root.estimateText() !== ""
          width: parent.width
          text: root.estimateText()
          textFormat: Text.PlainText
          horizontalAlignment: Text.AlignHCenter
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.1
        }
      }
    }
  }

  Component {
    id: refreshControl
    PanelActionButton {
      iconText: "󰑐"
      tooltipText: "Refresh"
      foreground: root.foreground
      fontFamily: root.fontFamily
      enabled: !root.refreshing
      onClicked: root.refresh()
    }
  }

  Component {
    id: keyboardIcon
    Text {
      textFormat: Text.PlainText
      text: "󰌌"
      color: root.low ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.display
    }
  }

  component HalfCard: Rectangle {
    id: card
    property string label: ""
    property int percent: 0

    readonly property bool drained: percent <= root.lowPercent
    readonly property color ink: drained ? root.urgent : root.foreground
    readonly property real fill: Math.max(0, Math.min(1, percent / 100))

    implicitHeight: cardBody.implicitHeight + Style.space(28)
    radius: Style.cornerRadius
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)

    Column {
      id: cardBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(14)
      spacing: Style.space(8)

      Text {
        width: parent.width
        text: card.label.toUpperCase()
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.1
      }

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          text: root.batteryIcon(card.percent)
          textFormat: Text.PlainText
          color: card.ink
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: card.percent + "%"
          textFormat: Text.PlainText
          color: card.ink
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Item {
        width: parent.width
        implicitHeight: Style.space(8)

        Rectangle {
          id: track
          anchors.fill: parent
          radius: height / 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
        }

        Rectangle {
          anchors.left: track.left
          anchors.verticalCenter: track.verticalCenter
          height: track.height
          radius: track.radius
          color: card.ink
          width: Math.max(track.height, track.width * card.fill)

          Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
          Behavior on color { ColorAnimation { duration: 220 } }
        }
      }

      Text {
        width: parent.width
        text: root.halfDetail(card.label)
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
