import QtQuick

// Filled history graph. Values are plotted oldest-to-newest left-to-right and
// scaled against `maxValue`, or against the running peak when `autoScale` is
// set (used for the network and disk graphs, whose ranges are unbounded).
Canvas {
  id: root

  property var values: []
  property color stroke: "white"
  property real maxValue: 100
  property bool autoScale: false
  property real lineWidth: 1.5
  property real fillOpacity: 0.16
  property int slots: 60

  readonly property real scale: {
    if (!autoScale) return Math.max(1, maxValue)
    var peak = 0
    for (var i = 0; i < values.length; i++) peak = Math.max(peak, values[i])
    return Math.max(1, peak)
  }

  onValuesChanged: requestPaint()
  onStrokeChanged: requestPaint()
  onScaleChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    if (width <= 0 || height <= 0) return

    var n = values.length
    if (n < 2) return

    // Anchor the newest sample at the right edge so a partially-filled
    // history grows leftward instead of stretching across the whole width.
    var step = width / Math.max(1, slots - 1)
    var originX = width - (n - 1) * step
    var pad = lineWidth
    var usable = Math.max(1, height - pad * 2)

    function pointX(i) { return originX + i * step }
    function pointY(i) {
      var v = Math.max(0, Math.min(scale, values[i]))
      return pad + usable - (v / scale) * usable
    }

    ctx.beginPath()
    ctx.moveTo(pointX(0), pointY(0))
    for (var i = 1; i < n; i++) ctx.lineTo(pointX(i), pointY(i))

    ctx.lineTo(pointX(n - 1), height)
    ctx.lineTo(pointX(0), height)
    ctx.closePath()
    ctx.fillStyle = Qt.rgba(stroke.r, stroke.g, stroke.b, fillOpacity)
    ctx.fill()

    ctx.beginPath()
    ctx.moveTo(pointX(0), pointY(0))
    for (var j = 1; j < n; j++) ctx.lineTo(pointX(j), pointY(j))
    ctx.strokeStyle = stroke
    ctx.lineWidth = lineWidth
    ctx.lineJoin = "round"
    ctx.lineCap = "round"
    ctx.stroke()
  }
}
