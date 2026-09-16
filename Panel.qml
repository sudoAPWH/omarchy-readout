import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// System monitor bar widget with two levels of detail.
//
// Clicking the widget opens the essentials popup — the handful of numbers you
// actually want at a glance. "More details" swaps that for a centered window
// carrying the full btop-style breakdown.
//
// All telemetry comes from one long-lived `bin/sysmon-collect` process that
// streams a JSON line per sample. Spawning a process per metric per tick was
// never going to survive a 1s cadence, and the collector also owns the delta
// state (jiffies, byte counters, RC6 residency) that rates are derived from.
// The panel steers it over stdin, escalating only as far as the visible view
// needs: `bar` while closed, `essentials` for the popup, `full` for the window.
Panel {
  id: root

  moduleName: "io.github.sudoapwh.readout"
  ipcTarget: "omarchy-readout"

  // ------------------------------------------------------------- settings
  readonly property real idleInterval: Math.max(0.5, Number(setting("interval", 2)) || 2)
  readonly property real openInterval: Math.max(0.5, Number(setting("openInterval", 1)) || 1)
  readonly property string terminalCommand: setting("terminalCommand", "omarchy-launch-or-focus-tui btop")
  readonly property int processCount: Math.max(1, Math.min(40, Number(setting("processCount", 7)) || 7))

  // ------------------------------------------------------------- live data
  property var stats: ({})
  property bool primed: false

  // The full-detail window. Kept separate from `opened` (which owns the
  // essentials popup) so each surface has its own lifecycle.
  property bool detailOpen: false

  readonly property var cpu: stats.cpu || ({})
  readonly property var mem: stats.mem || ({})
  readonly property var gpu: stats.gpu || null
  readonly property var disks: stats.disks || []
  readonly property var io: stats.io || []
  readonly property var net: stats.net || []
  readonly property var procs: stats.procs || []
  readonly property var sensors: stats.sensors || []
  readonly property var battery: stats.battery || null

  readonly property real cpuPct: Model.num(cpu.total)
  readonly property real memPct: Model.num(mem.pct)
  readonly property real gpuPct: gpu ? Model.num(gpu.busy) : 0
  readonly property bool hasGpu: gpu !== null && gpu !== undefined
  readonly property var rootDisk: disks.length > 0 ? disks[0] : null

  readonly property var primaryNet: Model.primaryInterface(net)
  readonly property var ioTotals: Model.totalIo(io)

  // Fixed-length rings feeding the sparklines. 60 samples is one minute at the
  // default open cadence, which is the window btop's graphs default to.
  readonly property int historyLength: 60
  property var cpuHistory: []
  property var memHistory: []
  property var gpuHistory: []
  property var netRxHistory: []
  property var netTxHistory: []
  property var ioReadHistory: []
  property var ioWriteHistory: []

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property string face: bar ? bar.fontFamily : Style.font.family

  function tint(value, warn, critical) {
    var s = Model.severity(value, warn, critical)
    return s > 0 ? Qt.tint(fg, Qt.rgba(urgentColor.r, urgentColor.g, urgentColor.b, s)) : fg
  }

  function dim(alpha) {
    return Qt.rgba(fg.r, fg.g, fg.b, alpha)
  }

  // ------------------------------------------------------------- collector
  readonly property string collectorPath:
    String(Qt.resolvedUrl("bin/sysmon-collect")).replace(/^file:\/\//, "")

  // Only the process scan behind `full` is genuinely expensive — it walks
  // every /proc/<pid> — so that is the one thing gated behind the detail
  // window. Everything else is a handful of reads and stays on always, which
  // is what lets the hover tooltip carry disk and network figures.
  readonly property string desiredMode: detailOpen ? "full" : "bar"
  readonly property real desiredInterval: (opened || detailOpen) ? openInterval : idleInterval

  function send(line) {
    if (collector.running) collector.write(line + "\n")
  }

  function applySample(line) {
    // Our own collector's samples are a few KB. Anything wildly past that is
    // not a sample, and is not worth handing to the parser.
    if (!line || line.length > 1048576) return

    var parsed
    try {
      parsed = JSON.parse(line)
    } catch (e) {
      return
    }
    if (!parsed || !parsed.cpu) return

    stats = parsed
    primed = true

    cpuHistory = Model.pushHistory(cpuHistory, parsed.cpu.total, historyLength)
    memHistory = Model.pushHistory(memHistory, parsed.mem ? parsed.mem.pct : 0, historyLength)
    gpuHistory = Model.pushHistory(gpuHistory, parsed.gpu ? parsed.gpu.busy : 0, historyLength)

    // Network and disk history only advance in the modes that sample them;
    // padding the rings with zeroes would draw a flatline through the graph
    // every time the panel closes.
    if (parsed.mode !== "bar") {
      var link = Model.primaryInterface(parsed.net)
      netRxHistory = Model.pushHistory(netRxHistory, link ? link.rx : 0, historyLength)
      netTxHistory = Model.pushHistory(netTxHistory, link ? link.tx : 0, historyLength)
      var totals = Model.totalIo(parsed.io)
      ioReadHistory = Model.pushHistory(ioReadHistory, totals.read, historyLength)
      ioWriteHistory = Model.pushHistory(ioWriteHistory, totals.write, historyLength)
    }
  }

  Process {
    id: collector
    // Named interpreter rather than the script's shebang, so nothing is looked
    // up on $PATH. -I ignores PYTHONPATH and the user site directory, -S skips
    // site imports; the collector is stdlib-only.
    command: ["/usr/bin/python3", "-I", "-S", root.collectorPath]
    running: true
    stdinEnabled: true

    onStarted: {
      root.collectorStartedAt = Date.now()
      root.send("procs " + root.processCount)
      root.send("interval " + root.desiredInterval)
      root.send("mode " + root.desiredMode)
    }

    // The shell outlives any single collector; if python dies (an update
    // swapping the interpreter, an OOM kill) bring it straight back rather
    // than leaving the widget frozen on its last sample for the session.
    //
    // A collector that dies immediately, every time, is a different thing: the
    // interpreter is missing, or the script cannot run here. Backing off turns
    // that from a process spawned every three seconds for the rest of the
    // session into a handful of attempts and a message.
    onExited: {
      var ranLong = Date.now() - root.collectorStartedAt > 30000
      root.collectorFailures = ranLong ? 0 : root.collectorFailures + 1
      if (root.collectorFailures <= root.maxCollectorRetries) {
        restartTimer.interval = Math.min(60000, 3000 * Math.pow(2, Math.max(0, root.collectorFailures - 1)))
        restartTimer.restart()
      }
    }

    stdout: SplitParser {
      onRead: function(line) { root.applySample(line) }
    }
  }

  Timer {
    id: restartTimer
    interval: 3000
    onTriggered: if (!collector.running) collector.running = true
  }

  property double collectorStartedAt: 0
  property int collectorFailures: 0
  readonly property int maxCollectorRetries: 5

  // Surfaced in the panel footer and the bar tooltip once the collector has
  // stopped coming back, rather than leaving both on a frozen last sample with
  // no explanation.
  readonly property bool collectorLost: collectorFailures > maxCollectorRetries

  // Driving the collector off derived state rather than off each open/close
  // handler means the two surfaces can hand off to each other — the popout
  // coordinator closes one as the other opens — without either racing to set
  // a mode the other just changed.
  onDesiredModeChanged: send("mode " + desiredMode)
  onDesiredIntervalChanged: send("interval " + desiredInterval)
  onProcessCountChanged: send("procs " + processCount)

  Component.onDestruction: if (collector.running) root.send("quit")

  // ------------------------------------------------------------ bar widget
  function showDetail() { detailOpen = true }

  function hideDetail() {
    detailOpen = false
    close()
  }

  IpcHandler {
    target: "omarchy-readout.detail"

    function open(): void { root.showDetail() }
    function close(): void { root.hideDetail() }
    function toggle(): void { root.detailOpen ? root.hideDetail() : root.showDetail() }
  }

  // The bar carries a single chip glyph rather than a run of percentages:
  // the numbers are a hover or a click away, and a fixed-size icon keeps the
  // widget from resizing its slot — and shuffling its neighbours — every time
  // a reading crosses 9% or 99%.
  //
  // One resource per row, aligned in the bar's monospace face, so the tooltip
  // is read down a column instead of parsed across a line.
  readonly property string barTooltip: {
    if (collectorLost) return "Readout — the collector stopped"
    if (!primed) return "Readout — waiting for the first sample"

    function row(label, reading, detail) {
      return Model.padRight(label, 5) + Model.padLeft(reading, 5) + "   " + detail
    }

    var lines = [
      row("CPU", Model.percent(cpuPct),
        cpu.temp ? Model.temperature(cpu.temp) : Model.frequency(cpu.freq)),
      row("RAM", Model.percent(memPct),
        Model.bytes(mem.used) + " / " + Model.bytes(mem.total))
    ]
    if (hasGpu)
      lines.push(row("GPU", Model.percent(gpuPct),
        gpu.temp ? Model.temperature(gpu.temp) : Model.frequency(gpu.freq)))

    // The shared tooltip centers each line, which staggers a table's rows.
    // Padding every line to a common width makes that centering a no-op —
    // but the pad has to be U+00A0, because Qt discards trailing ASCII
    // whitespace when it measures a line for alignment.
    var width = 0
    for (var i = 0; i < lines.length; i++) width = Math.max(width, lines[i].length)
    for (var j = 0; j < lines.length; j++) {
      while (lines[j].length < width) lines[j] += "\u00A0"
    }
    return lines.join("\n")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.ICON.chip
    tooltipText: root.barTooltip
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.bar.run(root.terminalCommand)
        return
      }
      // While the detail window is up the widget is the way back out of it,
      // rather than a route to the popup that window replaced.
      if (root.detailOpen) root.hideDetail()
      else root.toggle()
    }
  }

  // ------------------------------------------------------ essentials popup
  KeyboardPanel {
    id: essentials
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && !root.detailOpen
    focusTarget: essentialsKeys
    contentWidth: essentials.fittedContentWidth(Style.space(430))
    contentHeight: essentials.fittedContentHeight(essentialsBody.implicitHeight)

    PanelKeyCatcher {
      id: essentialsKeys
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.showDetail()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: essentialsBody
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // -------- header
        Item {
          width: parent.width
          implicitHeight: Math.max(essentialsHost.implicitHeight, essentialsUptime.implicitHeight)

          Text {
            id: essentialsHost
            textFormat: Text.PlainText
            text: root.stats.host || "System"
            color: root.fg
            font.family: root.face
            font.pixelSize: Style.font.subtitle
            font.bold: true
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: essentialsUptime
            textFormat: Text.PlainText
            text: root.cpu.uptime ? "up " + Model.uptime(root.cpu.uptime) : ""
            color: root.dim(0.5)
            font.family: root.face
            font.pixelSize: Style.font.caption
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // -------- the four numbers worth glancing at
        Column {
          width: parent.width
          spacing: Style.space(9)

          EssentialRow {
            width: parent.width
            icon: Model.ICON.cpu
            label: "CPU"
            value: root.cpuPct
            trailing: root.cpu.temp ? Model.temperature(root.cpu.temp) : Model.frequency(root.cpu.freq)
          }

          EssentialRow {
            width: parent.width
            icon: Model.ICON.memory
            label: "RAM"
            value: root.memPct
            warn: 75
            critical: 92
            trailing: Model.bytes(root.mem.used) + "/" + Model.bytes(root.mem.total)
          }

          EssentialRow {
            width: parent.width
            visible: root.hasGpu
            icon: Model.ICON.gpu
            label: "GPU"
            value: root.gpuPct
            trailing: root.gpu && root.gpu.temp
              ? Model.temperature(root.gpu.temp)
              : (root.gpu ? Model.frequency(root.gpu.freq) : "")
          }

          EssentialRow {
            width: parent.width
            visible: root.rootDisk !== null
            icon: Model.ICON.disk
            label: "DISK"
            value: root.rootDisk ? Model.num(root.rootDisk.pct) : 0
            warn: 80
            critical: 93
            trailing: root.rootDisk
              ? Model.bytes(root.rootDisk.free) + " free"
              : ""
          }
        }

        PanelSeparator { foreground: root.fg }

        // -------- live rates and load
        Column {
          width: parent.width
          spacing: Style.space(5)

          StatRow {
            width: parent.width
            leading: Model.ICON.network + "  ↓ " + Model.rate(root.primaryNet ? root.primaryNet.rx : 0)
              + "   ↑ " + Model.rate(root.primaryNet ? root.primaryNet.tx : 0)
            trailing: root.primaryNet ? root.primaryNet.iface : "no link"
          }

          StatRow {
            width: parent.width
            leading: Model.ICON.disk + "  ↓ " + Model.rate(root.ioTotals.read)
              + "   ↑ " + Model.rate(root.ioTotals.write)
            trailing: root.stats.diskTemp ? Model.temperature(root.stats.diskTemp) : ""
          }

          StatRow {
            width: parent.width
            leading: Model.ICON.speed + "  " + Model.loadText(root.cpu.load)
            trailing: root.stats.procCount ? root.stats.procCount + " procs" : ""
          }
        }

        // -------- footer
        Item {
          width: parent.width
          implicitHeight: moreButton.implicitHeight

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.battery
              ? Model.ICON.battery + " " + root.battery.capacity + "%"
                + (root.battery.power ? "  ·  " + root.battery.power.toFixed(1) + " W" : "")
              : ""
            color: root.dim(0.5)
            font.family: root.face
            font.pixelSize: Style.font.caption
          }

          Button {
            id: moreButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "More details"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.face
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            onClicked: root.showDetail()
          }
        }
      }
    }
  }

  // ------------------------------------------------------- detail window
  //
  // Centered rather than anchored under the widget: at this size it reads as
  // a window you opened, not as a popup hanging off the bar.
  QtObject {
    id: detailOwner
    property bool popoutSwitchClosing: false
    function close() { root.hideDetail() }
  }

  KeyboardPanel {
    id: detail
    anchorItem: button
    owner: detailOwner
    bar: root.bar
    open: root.detailOpen
    centerOnBar: true
    focusTarget: detailKeys
    contentWidth: detail.fittedContentWidth(Style.space(880))
    contentHeight: detail.fittedContentHeight(detailBody.implicitHeight)

    PanelKeyCatcher {
      id: detailKeys
      anchors.fill: parent
      onCloseRequested: root.hideDetail()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) detailScroller.flick(0, dy > 0 ? -600 : 600)
      }

      // Sized to its content, but a short screen (or a large font scale) can
      // still cap it. Scrolling beats clipping the process table off the end.
      Flickable {
        id: detailScroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: detailBody.implicitHeight
        clip: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: detailBody
          width: detailScroller.width
          spacing: Style.space(10)

          // ------------------------------------------------- hero gauges
          Item {
            width: parent.width
            implicitHeight: Math.max(identity.implicitHeight, gauges.implicitHeight)

            Column {
              id: identity
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: gauges.left
              anchors.rightMargin: Style.space(16)
              spacing: Style.space(3)

              Text {
                textFormat: Text.PlainText
                text: root.stats.host || "System"
                color: root.fg
                font.family: root.face
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: {
                  var bits = []
                  if (root.cpu.model) bits.push(root.cpu.model)
                  if (root.cpu.count) bits.push(root.cpu.count + " threads")
                  return bits.join("  ·  ")
                }
                color: root.dim(0.6)
                font.family: root.face
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: {
                  var bits = [Model.ICON.clock + " up " + Model.uptime(root.cpu.uptime)]
                  if (root.stats.kernel) bits.push(root.stats.kernel)
                  if (root.battery)
                    bits.push(Model.ICON.battery + " " + root.battery.capacity + "%"
                      + (root.battery.power ? " · " + root.battery.power.toFixed(1) + "W" : ""))
                  return bits.join("  ·  ")
                }
                color: root.dim(0.6)
                font.family: root.face
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }

            Row {
              id: gauges
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(18)

              Gauge { label: "CPU"; value: root.cpuPct; history: root.cpuHistory }
              Gauge { label: "RAM"; value: root.memPct; history: root.memHistory }
              Gauge {
                label: "GPU"
                value: root.gpuPct
                history: root.gpuHistory
                visible: root.hasGpu
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          // ------------------------------------------------- two columns
          Row {
            width: parent.width
            spacing: Style.space(20)

            readonly property real columnWidth: (width - spacing) / 2

            // ============================== left: cpu · memory · gpu
            Column {
              width: parent.columnWidth
              spacing: Style.space(10)

              SectionHeader {
                title: "PROCESSOR"
                meta: {
                  var bits = []
                  if (root.cpu.freq) bits.push(Model.frequency(root.cpu.freq))
                  if (root.cpu.temp) bits.push(Model.temperature(root.cpu.temp))
                  return bits.join("  ·  ")
                }
              }

              Meter {
                width: parent.width
                label: "Total"
                value: Model.percent(root.cpuPct, 1)
                fraction: root.cpuPct / 100
                severity: Model.severity(root.cpuPct)
                foreground: root.fg
                urgent: root.urgentColor
                fontFamily: root.face
              }

              Sparkline {
                width: parent.width
                height: Style.space(32)
                values: root.cpuHistory
                slots: root.historyLength
                stroke: root.tint(root.cpuPct)
                maxValue: 100
              }

              // Per-core load as a column of thin bars — the layout scales to
              // any core count, where btop's per-core rows would not.
              Item {
                width: parent.width
                implicitHeight: Style.space(26)
                visible: root.cpu.cores !== undefined && root.cpu.cores.length > 0

                Row {
                  id: coreRow
                  anchors.fill: parent
                  spacing: Math.max(1, Style.space(2))

                  readonly property int count: root.cpu.cores ? root.cpu.cores.length : 0
                  readonly property real cellWidth: count > 0
                    ? Math.max(2, (width - spacing * (count - 1)) / count)
                    : 0

                  Repeater {
                    model: root.cpu.cores || []

                    Rectangle {
                      required property var modelData
                      required property int index

                      width: coreRow.cellWidth
                      height: parent.height
                      radius: Math.min(width, Style.space(2)) / 2
                      color: root.dim(0.06)

                      Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        radius: parent.radius
                        height: Math.max(1, parent.height * Math.min(1, Model.num(modelData) / 100))
                        color: root.tint(Model.num(modelData))

                        Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                        Behavior on color { ColorAnimation { duration: 220 } }
                      }
                    }
                  }
                }
              }

              StatRow {
                width: parent.width
                leading: "Load  " + Model.loadText(root.cpu.load)
                trailing: root.stats.procCount ? root.stats.procCount + " processes" : ""
              }

              PanelSeparator { foreground: root.fg }

              SectionHeader {
                title: "MEMORY"
                meta: Model.bytes(root.mem.total) + " total"
              }

              Meter {
                width: parent.width
                label: "RAM"
                value: Model.bytes(root.mem.used) + " / " + Model.bytes(root.mem.total)
                fraction: root.memPct / 100
                severity: Model.severity(root.memPct, 75, 92)
                foreground: root.fg
                urgent: root.urgentColor
                fontFamily: root.face
              }

              Meter {
                width: parent.width
                visible: Model.num(root.mem.swapTotal) > 0
                label: "Swap"
                value: Model.bytes(root.mem.swapUsed) + " / " + Model.bytes(root.mem.swapTotal)
                fraction: Model.num(root.mem.swapPct) / 100
                severity: Model.severity(root.mem.swapPct, 40, 80)
                foreground: root.fg
                urgent: root.urgentColor
                fontFamily: root.face
              }

              StatRow {
                width: parent.width
                leading: "Cached  " + Model.bytes(root.mem.cached)
                trailing: "Available  " + Model.bytes(root.mem.available)
              }

              PanelSeparator { foreground: root.fg; visible: root.hasGpu }

              SectionHeader {
                visible: root.hasGpu
                title: "GRAPHICS"
                meta: Model.gpuLabel(root.gpu)
              }

              Meter {
                width: parent.width
                visible: root.hasGpu
                label: "Load"
                value: Model.percent(root.gpuPct, 1)
                fraction: root.gpuPct / 100
                severity: Model.severity(root.gpuPct)
                foreground: root.fg
                urgent: root.urgentColor
                fontFamily: root.face
              }

              Meter {
                width: parent.width
                visible: root.hasGpu && root.gpu && Model.num(root.gpu.memTotal) > 0
                label: "VRAM"
                value: Model.bytes(root.gpu ? root.gpu.memUsed : 0) + " / " + Model.bytes(root.gpu ? root.gpu.memTotal : 0)
                fraction: root.gpu && root.gpu.memTotal ? Model.num(root.gpu.memUsed) / Model.num(root.gpu.memTotal) : 0
                severity: root.gpu && root.gpu.memTotal ? Model.severity(Model.num(root.gpu.memUsed) / Model.num(root.gpu.memTotal) * 100, 75, 92) : 0
                foreground: root.fg
                urgent: root.urgentColor
                fontFamily: root.face
              }

              StatRow {
                width: parent.width
                visible: root.hasGpu
                leading: root.gpu && root.gpu.freq
                  ? "Clock  " + Model.frequency(root.gpu.freq)
                    + (root.gpu.freqMax ? " / " + Model.frequency(root.gpu.freqMax) : "")
                  : ""
                trailing: root.gpu && root.gpu.temp ? "Temp  " + Model.temperature(root.gpu.temp) : ""
              }

              // Sensors live in this column rather than in a full-width strip:
              // the process table makes the right column much the taller of the
              // two, and the slack down here is otherwise wasted.
              PanelSeparator { foreground: root.fg; visible: root.sensors.length > 0 }

              SectionHeader {
                visible: root.sensors.length > 0
                title: "SENSORS"
              }

              Flow {
                width: parent.width
                spacing: Style.space(12)
                visible: root.sensors.length > 0

                Repeater {
                  model: root.sensors

                  Text {
                    required property var modelData

                    textFormat: Text.PlainText
                    text: modelData.label + "  " + Model.temperature(modelData.value)
                    color: root.tint(modelData.value, 65, 85)
                    font.family: root.face
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            // ============================== right: storage · network · processes
            Column {
              width: parent.columnWidth
              spacing: Style.space(10)

              SectionHeader {
                title: "STORAGE"
                meta: root.ioTotals.util > 0 ? Model.percent(root.ioTotals.util) + " busy" : ""
              }

              Repeater {
                model: root.disks

                Meter {
                  required property var modelData

                  width: parent.width
                  label: Model.mountLabel(modelData.mount) + "  " + modelData.fs
                  value: Model.bytes(modelData.used) + " / " + Model.bytes(modelData.total)
                  fraction: Model.num(modelData.pct) / 100
                  severity: Model.severity(modelData.pct, 80, 93)
                  foreground: root.fg
                  urgent: root.urgentColor
                  fontFamily: root.face
                }
              }

              Repeater {
                model: root.io

                StatRow {
                  required property var modelData

                  width: parent.width
                  leading: Model.ICON.disk + " " + modelData.dev
                    + (modelData.temp ? "  " + Model.temperature(modelData.temp) : "")
                  trailing: "↓ " + Model.rate(modelData.read) + "   ↑ " + Model.rate(modelData.write)
                    + "   " + Model.percent(modelData.util)
                }
              }

              Sparkline {
                width: parent.width
                height: Style.space(26)
                visible: root.ioReadHistory.length > 1
                values: root.ioReadHistory
                slots: root.historyLength
                stroke: root.dim(0.75)
                autoScale: true
              }

              PanelSeparator { foreground: root.fg }

              SectionHeader {
                title: "NETWORK"
                meta: root.primaryNet ? root.primaryNet.iface : "no link"
              }

              StatRow {
                width: parent.width
                leading: "↓ " + Model.rate(root.primaryNet ? root.primaryNet.rx : 0)
                  + "   ↑ " + Model.rate(root.primaryNet ? root.primaryNet.tx : 0)
                trailing: root.primaryNet
                  ? "Σ ↓ " + Model.bytes(root.primaryNet.rxTotal) + "  ↑ " + Model.bytes(root.primaryNet.txTotal)
                  : ""
              }

              Sparkline {
                width: parent.width
                height: Style.space(26)
                visible: root.netRxHistory.length > 1
                values: root.netRxHistory
                slots: root.historyLength
                stroke: root.dim(0.75)
                autoScale: true
              }

              PanelSeparator { foreground: root.fg }

              SectionHeader {
                title: "PROCESSES"
                meta: "by cpu"
              }

              Column {
                width: parent.width
                spacing: Style.space(3)

                ProcessRow {
                  width: parent.width
                  header: true
                  name: "NAME"
                  pid: "PID"
                  user: "USER"
                  cpu: "CPU"
                  memory: "MEM"
                }

                Repeater {
                  model: root.procs

                  ProcessRow {
                    required property var modelData

                    width: parent.width
                    name: Model.procName(modelData.name)
                    pid: String(modelData.pid)
                    user: String(modelData.user)
                    cpu: Model.percent(modelData.cpu, 1)
                    memory: Model.bytes(modelData.rss)
                    load: Model.num(modelData.cpu)
                  }
                }
              }
            }
          }

          // ------------------------------------------------- footer
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.collectorLost
              ? "the collector stopped; restart the shell to try again"
              : root.primed
                ? "sampling every " + root.openInterval + "s  ·  esc to close"
                : "waiting for first sample…"
            color: root.dim(0.45)
            font.family: root.face
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // --------------------------------------------------------- sub-components

  // One line of the essentials popup: glyph, label, inline track, reading and
  // a trailing detail. Fixed side columns keep the tracks aligned to each
  // other as the readings change width.
  component EssentialRow: Item {
    property string icon: ""
    property string label: ""
    property real value: 0
    property string trailing: ""
    property real warn: 70
    property real critical: 90

    readonly property real severity: Model.severity(value, warn, critical)
    readonly property color accent: severity > 0
      ? Qt.tint(root.fg, Qt.rgba(root.urgentColor.r, root.urgentColor.g, root.urgentColor.b, severity))
      : root.fg

    implicitHeight: Math.max(rowLabel.implicitHeight, rowValue.implicitHeight)

    Text {
      id: rowIcon
      textFormat: Text.PlainText
      text: icon
      color: root.dim(0.75)
      font.family: root.face
      font.pixelSize: Style.font.body
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: rowLabel
      textFormat: Text.PlainText
      text: label
      color: root.dim(0.62)
      font.family: root.face
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 0.8
      anchors.left: rowIcon.right
      anchors.leftMargin: Style.space(7)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(34)
    }

    Text {
      id: rowTrailing
      textFormat: Text.PlainText
      text: trailing
      color: root.dim(0.5)
      font.family: root.face
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      width: Style.space(84)
      elide: Text.ElideRight
    }

    Text {
      id: rowValue
      textFormat: Text.PlainText
      text: Math.round(value) + "%"
      color: parent.accent
      font.family: root.face
      font.pixelSize: Style.font.body
      anchors.right: rowTrailing.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      width: Style.space(38)

      Behavior on color { ColorAnimation { duration: 240 } }
    }

    Rectangle {
      id: rowTrack
      anchors.left: rowLabel.right
      anchors.leftMargin: Style.space(10)
      anchors.right: rowValue.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(6)
      radius: height / 2
      color: root.dim(0.1)

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: Math.max(parent.height, parent.width * Math.max(0, Math.min(1, value / 100)))
        color: parent.parent.accent

        Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 240 } }
      }
    }
  }

  // Big-number readout with its own miniature history graph, used for the
  // three headline resources at the top of the detail window.
  component Gauge: Item {
    property string label: ""
    property real value: 0
    property var history: []

    implicitWidth: Style.space(96)
    implicitHeight: gaugeColumn.implicitHeight

    Column {
      id: gaugeColumn
      width: parent.width
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        text: label
        color: root.dim(0.55)
        font.family: root.face
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
        anchors.right: parent.right
      }

      Text {
        textFormat: Text.PlainText
        text: Math.round(value) + "%"
        color: root.tint(value)
        font.family: root.face
        font.pixelSize: Style.font.display
        font.bold: true
        anchors.right: parent.right

        Behavior on color { ColorAnimation { duration: 240 } }
      }

      Sparkline {
        width: parent.width
        height: Style.space(18)
        values: history
        slots: root.historyLength
        stroke: root.tint(value)
        maxValue: 100
        lineWidth: 1
      }
    }
  }

  component SectionHeader: Item {
    property string title: ""
    property string meta: ""

    width: parent ? parent.width : 0
    implicitHeight: Math.max(titleText.implicitHeight, metaText.implicitHeight)

    PanelSectionHeader {
      id: titleText
      text: title
      foreground: root.fg
      fontFamily: root.face
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: metaText
      textFormat: Text.PlainText
      text: meta
      color: root.dim(0.5)
      font.family: root.face
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.left: titleText.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideRight
    }
  }

  // Caption-weight key/value line for figures that don't warrant a bar.
  // `leading` / `trailing` rather than left/right: Item reserves those names
  // for its FINAL anchor lines.
  component StatRow: Item {
    property string leading: ""
    property string trailing: ""

    implicitHeight: Math.max(leftText.implicitHeight, rightText.implicitHeight)
    visible: leading !== "" || trailing !== ""

    Text {
      id: leftText
      textFormat: Text.PlainText
      text: leading
      color: root.dim(0.62)
      font.family: root.face
      font.pixelSize: Style.font.caption
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
    }

    Text {
      id: rightText
      textFormat: Text.PlainText
      text: trailing
      color: root.dim(0.8)
      font.family: root.face
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // One line of the process table. Column widths are fixed so the numeric
  // columns stay aligned as values change width.
  component ProcessRow: Item {
    property bool header: false
    property string name: ""
    property string pid: ""
    property string user: ""
    property string cpu: ""
    property string memory: ""
    property real load: 0

    implicitHeight: nameText.implicitHeight + Style.space(2)

    readonly property color rowColor: header
      ? root.dim(0.45)
      : (load >= 10 ? root.tint(load, 10, 80) : root.dim(0.85))

    // Faint load bar behind the row, so a runaway process is visible before
    // the numbers are read.
    Rectangle {
      visible: !header && load > 0
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      height: parent.height
      width: parent.width * Math.min(1, load / 100)
      radius: Style.space(2)
      color: root.dim(0.07)
    }

    Text {
      id: memText
      textFormat: Text.PlainText
      text: memory
      color: parent.rowColor
      font.family: root.face
      font.pixelSize: Style.font.caption
      font.bold: header
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      width: Style.space(48)
    }

    Text {
      id: cpuText
      textFormat: Text.PlainText
      text: cpu
      color: parent.rowColor
      font.family: root.face
      font.pixelSize: Style.font.caption
      font.bold: header
      anchors.right: memText.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      width: Style.space(46)
    }

    Text {
      id: userText
      textFormat: Text.PlainText
      text: user
      color: root.dim(header ? 0.45 : 0.55)
      font.family: root.face
      font.pixelSize: Style.font.caption
      font.bold: header
      anchors.right: cpuText.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(56)
      elide: Text.ElideRight
    }

    Text {
      id: pidText
      textFormat: Text.PlainText
      text: pid
      color: root.dim(header ? 0.45 : 0.55)
      font.family: root.face
      font.pixelSize: Style.font.caption
      font.bold: header
      anchors.right: userText.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(46)
      horizontalAlignment: Text.AlignRight
    }

    Text {
      id: nameText
      textFormat: Text.PlainText
      text: name
      color: parent.rowColor
      font.family: root.face
      font.pixelSize: Style.font.caption
      font.bold: header
      anchors.left: parent.left
      anchors.leftMargin: Style.space(2)
      anchors.right: pidText.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
    }
  }
}
