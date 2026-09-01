.pragma library

// Formatting and shaping helpers for the sysmon panel. Kept out of the QML so
// the view stays declarative and these stay unit-testable by eye.

var ICON = {
  cpu: "\u{F0EE0}",
  memory: "\u{E266}",
  gpu: "\u{F08AE}",
  disk: "\u{F02CA}",
  network: "\u{F06F3}",
  temperature: "\u{F050F}",
  processes: "\u{F0279}",
  clock: "\u{F0150}",
  swap: "\u{F04E1}",
  battery: "\u{F0079}",
  speed: "\u{F04C5}",
  chip: "\u{F061A}"
}

// Hand-rolled rather than String.padStart so the alignment the bar text and
// tooltip depend on does not hinge on the QML engine's ES level.
function padLeft(text, width) {
  var s = String(text)
  while (s.length < width) s = " " + s
  return s
}

function padRight(text, width) {
  var s = String(text)
  while (s.length < width) s = s + " "
  return s
}

function num(value, fallback) {
  var n = Number(value)
  return isFinite(n) ? n : (fallback === undefined ? 0 : fallback)
}

// Binary units, matching what btop and df -h report.
function bytes(value, digits) {
  var n = num(value, -1)
  if (n < 0) return "—"
  var units = ["B", "K", "M", "G", "T", "P"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024
    i++
  }
  var places = digits !== undefined ? digits : (n >= 100 || i === 0 ? 0 : 1)
  return n.toFixed(places) + units[i]
}

function rate(value) {
  var n = num(value, -1)
  if (n < 0) return "—"
  return bytes(n) + "/s"
}

function percent(value, digits) {
  var n = num(value, null)
  if (n === null) return "—"
  return n.toFixed(digits === undefined ? 0 : digits) + "%"
}

function temperature(value) {
  var n = Number(value)
  if (!isFinite(n)) return "—"
  return Math.round(n) + "°"
}

function frequency(mhz) {
  var n = Number(mhz)
  if (!isFinite(n) || n <= 0) return "—"
  return n >= 1000 ? (n / 1000).toFixed(2) + " GHz" : Math.round(n) + " MHz"
}

function uptime(seconds) {
  var s = Math.max(0, Math.floor(num(seconds)))
  var d = Math.floor(s / 86400)
  var h = Math.floor((s % 86400) / 3600)
  var m = Math.floor((s % 3600) / 60)
  if (d > 0) return d + "d " + h + "h " + m + "m"
  if (h > 0) return h + "h " + m + "m"
  return m + "m " + (s % 60) + "s"
}

function loadText(load) {
  if (!load || load.length < 3) return "—"
  return load.map(function(v) { return Number(v).toFixed(2) }).join("  ")
}

// Shorten a mount path so long nesting still fits the fixed label column.
function mountLabel(mount) {
  var m = String(mount || "")
  if (m.length <= 18) return m
  var parts = m.split("/").filter(function(p) { return p.length > 0 })
  if (parts.length <= 1) return m.slice(0, 17) + "…"
  return "…/" + parts[parts.length - 1]
}

function procName(name) {
  var n = String(name || "")
  return n.length > 20 ? n.slice(0, 19) + "…" : n
}

// Pick the interface the session is actually using: prefer an up link with
// traffic, then any up link, then whatever exists.
function primaryInterface(list) {
  if (!list || list.length === 0) return null
  for (var i = 0; i < list.length; i++)
    if (list[i].up && (list[i].rx > 0 || list[i].tx > 0)) return list[i]
  for (var j = 0; j < list.length; j++)
    if (list[j].up) return list[j]
  return list[0]
}

function totalIo(list) {
  var read = 0, write = 0, util = 0
  if (!list) return { read: read, write: write, util: util }
  for (var i = 0; i < list.length; i++) {
    read += num(list[i].read)
    write += num(list[i].write)
    util = Math.max(util, num(list[i].util))
  }
  return { read: read, write: write, util: util }
}

function gpuLabel(gpu) {
  if (!gpu) return "No GPU detected"
  if (gpu.name) return gpu.name
  return gpu.vendor ? gpu.vendor.toUpperCase() + " GPU" : "GPU"
}

// Append a sample to a fixed-length ring used by the sparklines. Returns a new
// array so QML property bindings actually see the change.
function pushHistory(history, value, limit) {
  var next = (history || []).slice()
  next.push(num(value))
  while (next.length > limit) next.shift()
  return next
}

// Load severity, 0..1, driving the accent-to-urgent colour ramp. Everything
// below `warn` reads as normal so the panel is calm at idle.
function severity(value, warn, critical) {
  var n = num(value)
  var lo = warn === undefined ? 70 : warn
  var hi = critical === undefined ? 90 : critical
  if (n <= lo) return 0
  if (n >= hi) return 1
  return (n - lo) / (hi - lo)
}
