import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// larry.status — Larry's face in the bar, alive.
//
// The face reacts to what Larry is actually doing on this host:
//   • agents on deck (Claude Code + Codex sessions) → idle / thinking / working / question
//   • ElevenLabs voice playing                       → speaking (mouth equalizer)
//   • heartbeat.status.json (qdrant/ollama/backups)   → alert (red) when something is down
//   • no agents at all                                → asleep
//
// Left-click = control panel. Middle-click = heartbeat now.
// Right-click = jump to the next agent window (cycles through live sessions).
BarWidget {
  id: root
  moduleName: "larry.status"

  readonly property string home: Quickshell.env("HOME")
  readonly property string statusPath: home + "/.claude/MEMORY/STATE/heartbeat.status.json"
  readonly property string voicePath: home + "/.claude/voice.json"
  readonly property string sessionsScript:
    Qt.resolvedUrl("larry_sessions.sh").toString().replace(/^file:\/\//, "")

  // ---- heartbeat (services)
  property bool okOllama: false
  property bool okQdrant: false
  property bool okBackup: false
  property string lastTs: ""
  property bool stale: true
  readonly property bool allGreen: okOllama && okQdrant && okBackup && !stale

  // ---- agents on deck
  property var sessions: []            // [{pid,sid,name,cwd,project,state,agent,attached,address,workspace,etimes}]
  readonly property int sessionCount: sessions.length
  readonly property int workingCount: sessions.filter(function(s){ return s.state === "working" || s.state === "thinking" }).length
  readonly property int questionCount: sessions.filter(function(s){ return s.state === "question" }).length
  property int focusCursor: -1

  // ---- voice
  property bool voiceEnabled: false
  property bool speaking: false

  // ---- mood → face
  readonly property string mood:
    !allGreen ? "alert"
    : speaking ? "speaking"
    : questionCount > 0 ? "question"
    : sessions.some(function(s){ return s.state === "working" }) ? "working"
    : sessions.some(function(s){ return s.state === "thinking" }) ? "thinking"
    : sessionCount > 0 ? "idle"
    : "sleep"

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

  // ------------------------------------------------------------ heartbeat
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
  Timer { interval: 60000; running: true; repeat: true; onTriggered: root.staleCheck() }

  Process {
    id: heartbeatNow
    command: [root.home + "/bin/larry-heartbeat"]
  }

  // ------------------------------------------------------------ agents on deck
  function refreshSessions() { if (!sessionsProc.running) sessionsProc.running = true }
  Process {
    id: sessionsProc
    command: ["bash", root.sessionsScript]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.sessions = JSON.parse(text.trim() || "[]") }
        catch (e) { root.sessions = [] }
      }
    }
  }
  Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refreshSessions() }

  // Focus an agent's terminal window by Hyprland address.
  Process { id: focusProc }
  function focusSession(s) {
    if (!s || !s.attached || !s.address) return false
    // Hyprland ≥0.56: `hyprctl dispatch` takes Lua; classic `focuswindow address:` is rejected.
    focusProc.command = ["hyprctl", "dispatch", 'hl.dsp.focus({ window = "address:' + s.address + '" })']
    focusProc.running = true
    return true
  }
  function focusNext() {
    var live = sessions.filter(function(s){ return s.attached })
    if (live.length === 0) return
    focusCursor = (focusCursor + 1) % live.length
    focusSession(live[focusCursor])
  }

  // ------------------------------------------------------------ voice
  FileView {
    path: root.voicePath
    watchChanges: true
    onFileChanged: reload()
    onLoaded: { try { root.voiceEnabled = JSON.parse(text()).enabled === true } catch (e) { root.voiceEnabled = false } }
    onLoadFailed: root.voiceEnabled = false
  }
  // mpv only runs under the VoiceServer on this box when Larry is talking.
  Process {
    id: speakProc
    command: ["sh", "-c", "pgrep -f '[m]pv --no-video --really-quiet' >/dev/null && echo 1 || echo 0"]
    stdout: StdioCollector { onStreamFinished: root.speaking = text.trim() === "1" }
  }
  Timer {
    interval: 1200
    running: root.voiceEnabled
    repeat: true
    onTriggered: if (!speakProc.running) speakProc.running = true
    onRunningChanged: if (!running) root.speaking = false
  }

  // ------------------------------------------------------------ IPC
  IpcHandler {
    target: root.moduleName
    function status(): string {
      return "mood=" + root.mood + " agents=" + root.sessionCount + " working=" + root.workingCount
        + " ollama=" + root.okOllama + " qdrant=" + root.okQdrant
        + " backup=" + root.okBackup + " stale=" + root.stale + " ts=" + root.lastTs
    }
    function sessions(): string { return JSON.stringify(root.sessions) }
    function refresh(): void { root.refreshSessions() }
    function next(): void { root.focusNext() }
    function check(): void { heartbeatNow.running = true }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  // ------------------------------------------------------------ bar button
  function tooltip() {
    var parts = []
    if (root.sessionCount === 0) parts.push("Larry is asleep — no agents running")
    else {
      parts.push(root.sessionCount + " agent" + (root.sessionCount === 1 ? "" : "s") + " on deck"
        + (root.workingCount ? ", " + root.workingCount + " working" : "")
        + (root.questionCount ? ", " + root.questionCount + " waiting on you" : ""))
    }
    if (root.speaking) parts.push("speaking")
    if (!root.allGreen) parts.push("ollama=" + (root.okOllama ? "up" : "DOWN")
        + " qdrant=" + (root.okQdrant ? "up" : "DOWN")
        + " backup=" + (root.okBackup ? "on" : "OFF")
        + (root.stale ? " [heartbeat stale]" : ""))
    return parts.join(" · ") + "\nleft: panel · middle: heartbeat · right: next agent"
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    hasVisualContent: true
    labelVisible: false
    keepSpace: true
    fixedWidth: content.implicitWidth + Style.spaceReal(horizontalMargin) * 2
    dimmed: root.stale && root.sessionCount === 0
    active: !root.allGreen
    useActiveColor: false
    tooltipText: root.tooltip()
    onPressed: function(code) {
      if (code === Qt.MiddleButton) heartbeatNow.running = true
      else if (code === Qt.RightButton) root.focusNext()
      else root.toggle()
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.spaceReal(4)

      CyberFace {
        id: face
        anchors.verticalCenter: parent.verticalCenter
        size: Math.round((root.bar ? root.bar.barSize : Style.bar.sizeHorizontal) * 0.68)
        mood: root.mood
        base: button.foreground
        red: button.activeColor
        glow: "#5fd7ff"   // fixed cyber cyan — theme accents can be red, which must stay reserved for alert
      }

      // agent count badge — hidden when asleep
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.sessionCount > 0
        text: root.sessionCount
        textFormat: Text.PlainText
        color: root.questionCount > 0 ? face.amber : button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        renderType: Text.NativeRendering
      }
    }
  }
}
