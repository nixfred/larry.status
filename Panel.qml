import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// larry.status Panel — Larry's control room.
// Agents on deck (click → jump to that window), services (heartbeat),
// fleet, brain state (ollama / LMF memory), one-click actions.
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
  readonly property color amber: "#f0b35a"
  readonly property color cyan: "#5fd7ff"

  // Heartbeat state (mirrors BarWidget; panel reads the same status file).
  property bool okOllama: false
  property bool okQdrant: false
  property bool okBackup: false
  property string lastTs: ""
  property int fleetOnline: -1
  property int fleetTotal: 0
  property var fleetDown: []

  // Agents on deck come from the host widget (single poller).
  readonly property var sessions: hostWidget ? hostWidget.sessions : []
  readonly property string mood: hostWidget ? hostWidget.mood : "idle"
  readonly property var liveSessions: sessions.filter(function(s){ return s.attached })

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
    if (hostWidget) hostWidget.refreshSessions()
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

  function jumpTo(s) {
    if (!hostWidget) return
    if (hostWidget.focusSession(s)) close()
    else actionNote = s.name + " has no window on this host (detached session)"
  }

  function fmtAge(sec) {
    sec = Number(sec) || 0
    if (sec < 60) return sec + "s"
    if (sec < 3600) return Math.floor(sec / 60) + "m"
    var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60)
    return h + "h" + (m ? " " + m + "m" : "")
  }
  function stateLabel(st) {
    switch (st) {
      case "working":  return "working"
      case "thinking": return "thinking"
      case "question": return "needs you"
      default:         return "idle"
    }
  }
  function stateColor(st) {
    switch (st) {
      case "working":
      case "thinking": return root.cyan
      case "question": return root.amber
      default:         return root.dim
    }
  }
  function moodLine() {
    switch (mood) {
      case "sleep":    return "Asleep — no agents running"
      case "alert":    return "Attention needed"
      case "speaking": return "Speaking"
      case "question": return "An agent is waiting on you"
      case "working":  return "Working"
      case "thinking": return "Thinking"
      default:         return "Idle — agents waiting on you"
    }
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

  // Keep the agent list fresh while the panel is open (host polls every 5s anyway).
  Timer {
    interval: 2000
    running: root.opened
    repeat: true
    onTriggered: if (root.hostWidget) root.hostWidget.refreshSessions()
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

  // One agent on deck. Click → jump to its window. Number key → same.
  component AgentRow: Rectangle {
    id: row
    property var s: ({})
    property int ordinal: 0
    readonly property bool busyState: s.state === "working" || s.state === "thinking"
    Layout.fillWidth: true
    implicitHeight: inner.implicitHeight + Style.space(10)
    radius: Style.cornerRadius
    color: hover.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08) : "transparent"
    opacity: s.attached ? 1 : 0.55

    MouseArea {
      id: hover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: row.s.attached ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.jumpTo(row.s)
    }

    RowLayout {
      id: inner
      anchors.fill: parent
      anchors.margins: Style.space(5)
      spacing: Style.space(8)

      // ordinal key hint
      Text {
        text: row.ordinal > 0 && row.ordinal < 10 ? row.ordinal : "·"
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        Layout.preferredWidth: Style.space(10)
      }
      // state dot (pulses while busy)
      Rectangle {
        id: dot
        width: Style.space(9); height: Style.space(9); radius: width / 2
        color: root.stateColor(row.s.state)
        SequentialAnimation on opacity {
          running: row.busyState && root.opened
          loops: Animation.Infinite
          NumberAnimation { to: 0.25; duration: 500 }
          NumberAnimation { to: 1.0;  duration: 500 }
        }
        onVisibleChanged: opacity = 1
      }
      // agent glyph: Claude (Larry) vs Codex
      Text {
        text: row.s.agent === "codex" ? "" : "󰚩"
        textFormat: Text.PlainText
        color: row.s.agent === "codex" ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: 0
        Text {
          Layout.fillWidth: true
          text: row.s.name || "?"
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: row.busyState || row.s.state === "question"
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          text: (row.s.agent === "codex" ? "codex · " : "larry · ")
            + (row.s.cwd || "").replace(root.home, "~")
            + (row.s.attached ? "" : " · detached")
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }
      ColumnLayout {
        spacing: 0
        Text {
          Layout.alignment: Qt.AlignRight
          text: root.stateLabel(row.s.state)
          textFormat: Text.PlainText
          color: root.stateColor(row.s.state)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        Text {
          Layout.alignment: Qt.AlignRight
          text: (row.s.attached ? "ws " + row.s.workspace + " · " : "") + root.fmtAge(row.s.etimes)
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "h" || text === "H") { root.busy = true; heartbeatNow.running = true }
        else if (text === "r" || text === "R") { statusFile.reload(); root.refreshBrain(); if (root.hostWidget) root.hostWidget.refreshSessions() }
        else if (text >= "1" && text <= "9") {
          var i = Number(text) - 1
          if (i < root.sessions.length) root.jumpTo(root.sessions[i])
        }
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
            meta: root.moodLine()
            detail: root.lastTs !== "" ? "heartbeat " + root.lastTs.replace("T", " ").substring(11, 16) : "no heartbeat yet"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              CyberFace {
                size: Style.space(52)
                mood: root.mood
                base: root.foreground
                red: root.urgent
                glow: root.cyan
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

          // -------------------------------------------------- AGENTS ON DECK
          RowLayout {
            Layout.fillWidth: true
            PanelSectionHeader {
              Layout.fillWidth: true
              text: "AGENTS ON DECK"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Text {
              text: root.sessions.length === 0 ? "" : root.sessions.length + " live · click or 1–9 to jump"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          Text {
            Layout.fillWidth: true
            visible: root.sessions.length === 0
            text: "No Claude Code or Codex sessions running on this host. Larry is asleep."
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
          Repeater {
            model: root.sessions
            delegate: AgentRow {
              required property var modelData
              required property int index
              s: modelData
              ordinal: index + 1
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
