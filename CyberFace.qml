import QtQuick

// CyberFace — Larry's face, drawn live in QML so it can react.
// Everything scales from `size` (the face height). Used tiny in the bar
// and large in the panel hero.
//
// mood:
//   sleep     no agents running          eyes closed, dim
//   idle      agents waiting on Fred     steady glow, blinks
//   thinking  a session is reasoning     narrowed eyes, slow pulse
//   working   a session is executing     bright eyes, fast pulse
//   question  a session needs an answer  amber, eyes look up
//   speaking  ElevenLabs is talking      mouth equalizer
//   alert     a service is down          red, wide eyes
Item {
  id: root

  property real size: 24
  property string mood: "idle"
  property color base: "#cacccc"           // head chrome (bar foreground)
  property color glow: "#5fd7ff"           // default eye color (cyber cyan)
  property color amber: "#f0b35a"
  property color red: "#e0564f"
  property color green: "#7fdc8a"
  property bool animate: true

  readonly property bool asleep: mood === "sleep"
  readonly property bool busy: mood === "working" || mood === "thinking"
  readonly property color eyeColor:
    mood === "alert" ? red
    : mood === "question" ? amber
    : mood === "speaking" ? green
    : glow

  implicitWidth: size
  implicitHeight: size
  width: implicitWidth
  height: implicitHeight

  // ---------------------------------------------------------------- head
  Rectangle {
    id: head
    anchors.centerIn: parent
    width: root.size * 0.94
    height: root.size * 0.94
    radius: root.size * 0.22
    color: "transparent"
    border.width: Math.max(1, root.size * 0.055)
    border.color: root.base
    opacity: root.asleep ? 0.55 : 1
    Behavior on opacity { NumberAnimation { duration: 400 } }
  }

  // side "ears" — cyber audio ports
  Repeater {
    model: 2
    Rectangle {
      required property int index
      width: Math.max(1, root.size * 0.07)
      height: root.size * 0.30
      radius: width / 2
      color: root.base
      opacity: head.opacity
      y: head.y + head.height * 0.36
      x: index === 0 ? head.x - width * 0.35 : head.x + head.width - width * 0.65
    }
  }

  // top visor strip
  Rectangle {
    width: head.width * 0.42
    height: Math.max(1, root.size * 0.05)
    radius: height / 2
    color: root.base
    opacity: head.opacity * 0.8
    x: head.x + (head.width - width) / 2
    y: head.y + head.border.width * 2.2
  }

  // ---------------------------------------------------------------- eyes
  // Eye geometry (fractions of size) driven by mood.
  readonly property real eyeW: size * 0.24
  readonly property real eyeHBase:
    asleep ? size * 0.035
    : mood === "thinking" ? size * 0.10
    : mood === "alert" ? size * 0.22
    : size * 0.15
  readonly property real eyeLift: mood === "question" ? -size * 0.05 : 0
  property real blink: 1.0          // 1 = open, ~0.1 = blink
  property real pulse: 1.0          // eye brightness multiplier

  Repeater {
    model: 2
    Item {
      required property int index
      readonly property real cx: head.x + head.width * (index === 0 ? 0.30 : 0.70)
      readonly property real cy: head.y + head.height * 0.42 + root.eyeLift
      x: cx - root.eyeW / 2
      y: cy - root.eyeHBase / 2
      width: root.eyeW
      height: root.eyeHBase

      // soft glow halo
      Rectangle {
        anchors.centerIn: parent
        width: parent.width * 1.5
        height: Math.max(parent.height * 2.2, root.size * 0.12)
        radius: height / 2
        color: root.eyeColor
        opacity: root.asleep ? 0 : 0.22 * root.pulse
        visible: !root.asleep
      }
      // eye itself
      Rectangle {
        anchors.centerIn: parent
        width: parent.width
        height: Math.max(1, parent.height * root.blink)
        radius: height / 2
        color: root.eyeColor
        opacity: root.asleep ? 0.45 : (0.65 + 0.35 * root.pulse)
        Behavior on color { ColorAnimation { duration: 300 } }
        Behavior on height { enabled: !blinkAnim.running; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      }
    }
  }

  // ---------------------------------------------------------------- mouth
  // Five segment equalizer: flat line when quiet, dances when speaking.
  readonly property int barsN: 5
  property var barLevels: [0.2, 0.2, 0.2, 0.2, 0.2]

  Row {
    id: mouth
    spacing: Math.max(1, root.size * 0.035)
    x: head.x + (head.width - width) / 2
    y: head.y + head.height * 0.64
    opacity: head.opacity
    Repeater {
      model: root.barsN
      Rectangle {
        required property int index
        width: Math.max(1, root.size * 0.07)
        height: Math.max(1, root.size * 0.20 * (root.barLevels[index] || 0.2))
        radius: width / 2
        color: root.mood === "speaking" ? root.green : root.base
        opacity: root.mood === "speaking" ? 1 : 0.85
        anchors.verticalCenter: parent.verticalCenter
        Behavior on height { NumberAnimation { duration: 110 } }
        Behavior on color { ColorAnimation { duration: 200 } }
      }
    }
  }

  // ---------------------------------------------------------------- animation
  // Blink: random-ish interval, never while asleep.
  Timer {
    id: blinkTimer
    interval: 3200 + Math.floor(Math.random() * 2800)
    running: root.animate && !root.asleep && root.visible
    repeat: true
    onTriggered: {
      interval = 2800 + Math.floor(Math.random() * 3200)
      blinkAnim.restart()
    }
  }
  SequentialAnimation {
    id: blinkAnim
    NumberAnimation { target: root; property: "blink"; to: 0.12; duration: 70 }
    NumberAnimation { target: root; property: "blink"; to: 1.0; duration: 110; easing.type: Easing.OutCubic }
  }

  // Pulse: thinking slow, working fast, otherwise steady.
  // Stepped (~10 fps) on purpose: a continuous 60 fps NumberAnimation in the
  // bar keeps quickshell repainting the whole bar layer all day.
  property int pulseStep: 0
  Timer {
    id: pulseTimer
    interval: root.mood === "working" ? 90 : 180
    running: root.animate && root.busy && root.visible
    repeat: true
    onTriggered: {
      root.pulseStep = (root.pulseStep + 1) % 10
      // triangle wave 1.0 → 0.35 → 1.0 over 10 steps
      var t = root.pulseStep < 5 ? root.pulseStep / 5 : (10 - root.pulseStep) / 5
      root.pulse = 1.0 - 0.65 * t
    }
    onRunningChanged: if (!running) { root.pulse = 1.0; root.pulseStep = 0 }
  }

  // Mouth equalizer while speaking.
  Timer {
    interval: 120
    running: root.animate && root.mood === "speaking" && root.visible
    repeat: true
    onTriggered: {
      var l = []
      for (var i = 0; i < root.barsN; i++) l.push(0.25 + Math.random() * 0.75)
      root.barLevels = l
    }
    onRunningChanged: if (!running) root.barLevels = [0.2, 0.2, 0.2, 0.2, 0.2]
  }
}
