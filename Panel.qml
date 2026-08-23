import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// larry.status Panel — Larry's control room.
// Services (heartbeat), brain state (ollama / LMF memory), one-click actions.
Panel {
  id: root
  moduleName: "larry.status"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color okColor: "#7fbf7f"

  // Heartbeat state (mirrors BarWidget; panel reads the same status file).
  property bool okOllama: false
  property bool okQdrant: false
  property bool okBackup: false
  property string lastTs: ""
  property int fleetOnline: -1
  property int fleetTotal: 0
  property var fleetDown: []

  // Brain state, refreshed on open.
  property string loadedModel: "(none loaded)"
  property string modelCount: "…"
  property string memLine: "…"
  property string actionNote: ""
  property bool busy: false

  readonly property string home: Quickshell.env("HOME")

  function open() {
    statusFile.reload()
    refreshBrain()
    actionNote = ""
    controller.show()
  }
  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function refreshBrain() {
    ollamaPs.running = true
    ollamaList.running = true
    memStats.running = true
  }

  function parseStatus(text) {
    try {
      var s = JSON.parse(text)
      okOllama = s.ollama === true
      okQdrant = s.qdrant === true
      okBackup = s.backup_timer === true
      lastTs = s.ts || ""
      if (s.fleet) {
        fleetOnline = s.fleet.online
        fleetTotal = s.fleet.total
        fleetDown = s.fleet.down || []
      } else { fleetOnline = -1; fleetTotal = 0; fleetDown = [] }
    } catch (e) { okOllama = okQdrant = okBackup = false; lastTs = ""; fleetOnline = -1; fleetTotal = 0; fleetDown = [] }
  }

  FileView {
    id: statusFile
    path: root.home + "/.claude/MEMORY/STATE/heartbeat.status.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.parseStatus(text())
    onLoadFailed: root.parseStatus("")
  }

  Process {
    id: ollamaPs
    command: ["sh", "-c", "ollama ps 2>/dev/null | awk 'NR==2 {print $1\"  \"$3\" \"$4\"  \"$5\" \"$6}'"]
    stdout: StdioCollector {
      onStreamFinished: root.loadedModel = text.trim() !== "" ? text.trim() : "(none loaded)"
    }
  }
  Process {
    id: ollamaList
    command: ["sh", "-c", "ollama list 2>/dev/null | tail -n +2 | wc -l"]
    stdout: StdioCollector {
      onStreamFinished: root.modelCount = text.trim() + " models installed"
    }
  }
  Process {
    id: memStats
    command: ["sh", "-c",
      "mem stats 2>/dev/null | grep -iE 'total|messages|loa|breadcrumb' | head -3 | tr '\\n' ' · ' || echo unavailable"]
    stdout: StdioCollector {
      onStreamFinished: root.memLine = text.trim() !== "" ? text.trim() : "mem unavailable"
    }
  }

  Process {
    id: heartbeatNow
    command: [root.home + "/bin/larry-heartbeat"]
    onRunningChanged: if (!running) { root.busy = false; root.actionNote = "heartbeat done"; statusFile.reload() }
  }
  Process {
    id: snapNow
    command: ["sh", "-c", root.home + "/bin/larry-snap 'from larry.status panel' 2>&1 | head -1"]
    stdout: StdioCollector { onStreamFinished: root.actionNote = text.trim() }
    onRunningChanged: if (!running) root.busy = false
  }
  Process {
    id: vicupNow
    command: ["sh", "-c", root.home + "/bin/vicup 'save from larry.status panel' 2>&1 | tail -1"]
    stdout: StdioCollector { onStreamFinished: root.actionNote = text.trim() }
    onRunningChanged: if (!running) root.busy = false
  }

  component ServiceRow: RowLayout {
    property string label: ""
    property string detail: ""
    property bool up: false
    Layout.fillWidth: true
    spacing: Style.space(8)
    Rectangle {
      width: Style.space(10); height: Style.space(10); radius: width / 2
      color: up ? root.okColor : root.urgent
    }
    Text {
      text: label
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    Item { Layout.fillWidth: true }
    Text {
      text: up ? detail : "DOWN"
      textFormat: Text.PlainText
      color: up ? root.dim : root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component ActionRow: RowLayout {
    property string label: ""
    property string hint: ""
    signal fired()
    Layout.fillWidth: true
    spacing: Style.space(8)
    PanelActionButton {
      iconText: "󰐊"
      tooltipText: label
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: { if (!root.busy) { root.busy = true; root.actionNote = label + "…"; fired() } }
    }
    Text {
      text: label
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    Item { Layout.fillWidth: true }
    Text {
      text: hint
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "h" || text === "H") { root.busy = true; heartbeatNow.running = true }
        else if (text === "r" || text === "R") { statusFile.reload(); root.refreshBrain() }
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
          id: content
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            Layout.fillWidth: true
            title: "Larry"
            meta: (root.okOllama && root.okQdrant && root.okBackup)
              ? "All systems green"
              : "Attention needed"
            detail: root.lastTs !== "" ? "heartbeat " + root.lastTs.replace("T", " ").substring(0, 16) : "no heartbeat yet"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰚩"
                textFormat: Text.PlainText
                color: (root.okOllama && root.okQdrant && root.okBackup) ? root.okColor : root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          PanelSectionHeader {
            Layout.fillWidth: true
            text: "SERVICES"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          ServiceRow { label: "Ollama";        detail: "port 11434";  up: root.okOllama }
          ServiceRow { label: "Qdrant";        detail: "port 6333";   up: root.okQdrant }
          ServiceRow { label: "Memory backup"; detail: "timer on";    up: root.okBackup }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          PanelSectionHeader {
            Layout.fillWidth: true
            visible: root.fleetOnline >= 0
            text: "FLEET"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          RowLayout {
            Layout.fillWidth: true
            visible: root.fleetOnline >= 0
            spacing: Style.space(8)
            // one dot per fleet host: green = online, red = down
            Flow {
              Layout.fillWidth: true
              spacing: Style.space(5)
              Repeater {
                model: root.fleetTotal
                delegate: Rectangle {
                  required property int index
                  width: Style.space(9); height: Style.space(9); radius: width / 2
                  color: index < (root.fleetTotal - root.fleetDown.length) ? root.okColor : root.urgent
                }
              }
            }
            Text {
              text: root.fleetOnline + "/" + root.fleetTotal
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
          Text {
            Layout.fillWidth: true
            visible: root.fleetDown.length > 0
            text: "down: " + root.fleetDown.join(", ")
            textFormat: Text.PlainText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          PanelSectionHeader {
            Layout.fillWidth: true
            text: "BRAIN"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          Text {
            Layout.fillWidth: true
            text: "Loaded: " + root.loadedModel + "\n" + root.modelCount + "\nMemory: " + root.memLine
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WrapAnywhere
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          PanelSectionHeader {
            Layout.fillWidth: true
            text: "ACTIONS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }
          ActionRow { label: "Heartbeat now";   hint: "check + self-heal (h)"; onFired: heartbeatNow.running = true }
          ActionRow { label: "Snapshot /home";  hint: "btrfs via larry-snap";  onFired: snapNow.running = true }
          ActionRow { label: "Save Larry";      hint: "vicup → both repos";    onFired: vicupNow.running = true }

          Text {
            Layout.fillWidth: true
            visible: root.actionNote !== ""
            text: (root.busy ? "⏳ " : "✓ ") + root.actionNote
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WrapAnywhere
          }
        }
      }
    }
  }
}
