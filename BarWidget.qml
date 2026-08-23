import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// larry.status — Larry's infrastructure at a glance.
// Reads ~/.claude/MEMORY/STATE/heartbeat.status.json, written every 10 min
// by larry-heartbeat.timer. Left-click opens the control panel; middle-click
// runs a heartbeat check immediately.
BarWidget {
  id: root
  moduleName: "larry.status"

  readonly property string statusPath:
    Quickshell.env("HOME") + "/.claude/MEMORY/STATE/heartbeat.status.json"

  property bool okOllama: false
  property bool okQdrant: false
  property bool okBackup: false
  property string lastTs: ""
  property bool stale: true

  readonly property bool allGreen: okOllama && okQdrant && okBackup && !stale

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.anchorItem = button
    target.hostWidget = root
  }
  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  function staleCheck() {
    if (lastTs === "") { stale = true; return }
    var age = (Date.now() - Date.parse(lastTs)) / 60000
    stale = !(age >= 0 && age < 25)
  }

  function parse(text) {
    try {
      var s = JSON.parse(text)
      okOllama = s.ollama === true
      okQdrant = s.qdrant === true
      okBackup = s.backup_timer === true
      lastTs = s.ts || ""
    } catch (e) {
      okOllama = okQdrant = okBackup = false
      lastTs = ""
    }
    staleCheck()
  }

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: root.parse("")
  }

  // Staleness can only be detected by the passage of time, not file events.
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.staleCheck()
  }

  Process {
    id: heartbeatNow
    command: [Quickshell.env("HOME") + "/bin/larry-heartbeat"]
  }

  IpcHandler {
    target: root.moduleName
    function status(): string {
      return "ollama=" + root.okOllama + " qdrant=" + root.okQdrant
        + " backup=" + root.okBackup + " stale=" + root.stale
        + " ts=" + root.lastTs
    }
    function check(): void { heartbeatNow.running = true }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰚩"
    dimmed: root.stale
    active: !root.allGreen
    tooltipText: root.allGreen
      ? "Larry: all systems green — click for panel"
      : "Larry: ollama=" + (root.okOllama ? "up" : "DOWN")
        + " qdrant=" + (root.okQdrant ? "up" : "DOWN")
        + " backup=" + (root.okBackup ? "on" : "OFF")
        + (root.stale ? " [heartbeat stale]" : "")
        + " — click for panel"
    onPressed: function(code) {
      if (code === Qt.MiddleButton) heartbeatNow.running = true
      else root.toggle()
    }
  }
}
