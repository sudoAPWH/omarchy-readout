# omarchy-stats

A system monitor for the [Omarchy](https://omarchy.org/) shell — a Quickshell
bar widget with two levels of detail behind it.

The bar carries a single chip glyph. Hover it for the three numbers you
usually want, click it for the essentials, and open the detail window when you
actually need to know what the machine is doing.

## The three surfaces

**Hover** — one resource per row, aligned:

```
CPU    3%   40°
RAM   28%   2.1G / 7.5G
GPU    8%   350 MHz
```

**Click** — the essentials popup: CPU, RAM, GPU and root-filesystem meters,
each with a trailing detail; network and disk throughput; load average;
process count; battery.

**More details** — a centered window with the full breakdown:

| Column | Sections |
|---|---|
| Left | Processor (frequency, package temperature, total load, one-minute graph, per-core bars, load average) · Memory (RAM, swap, cached, available) · Graphics (load, clock, VRAM where the vendor reports it) · Sensors |
| Right | Storage (per-filesystem meters, per-disk throughput, busy percentage and drive temperature, I/O graph) · Network (rates, session totals, graph) · Processes (top by CPU, with a load bar behind each row) |

Right-clicking the bar widget launches a full TUI monitor (`btop` by default).

## Install

The plugin is the repository, so it installs the way any third-party Omarchy
plugin does:

```bash
omarchy plugin add https://git.hutlet.ca/ahutlet/omarchy-stats.git --enable --yes
```

To install a working copy by hand instead:

```bash
git clone https://git.hutlet.ca/ahutlet/omarchy-stats.git ~/.config/omarchy/plugins/omarchy-stats
omarchy-shell shell rescanPlugins
omarchy plugin enable omarchy-stats
```

The directory name must match the `id` in `manifest.json`. Move the widget
around the bar with `omarchy bar move omarchy-stats --section right`.

## Requirements

Python 3 and a Nerd Font (Omarchy ships both). Nothing here needs root, and
nothing is installed outside the plugin directory.

## Settings

Settings live inline on the widget's entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "omarchy-stats", "openInterval": 0.5, "processCount": 12 }
```

| Key | Default | Meaning |
|---|---|---|
| `interval` | `2` | Seconds between samples while every surface is closed |
| `openInterval` | `1` | Seconds between samples while a surface is open |
| `processCount` | `7` | Rows in the detail window's process table |
| `terminalCommand` | `omarchy-launch-or-focus-tui btop` | Run on right-click |

## Development

Omarchy loads plugins from `~/.config/omarchy/plugins/<id>/`, so a checkout
kept anywhere else needs that path to point at it:

```bash
ln -s ~/Projects/omarchy-stats ~/.config/omarchy/plugins/omarchy-stats
omarchy restart shell
```

Two caveats, both learned the hard way:

- **Symlinked plugin directories do not hot-reload.** Omarchy reloads plugin
  code when a file under `~/.config/omarchy/plugins/` changes, but the watcher
  does not traverse a symlink — editing through either path triggers nothing.
  Apply changes with `omarchy restart shell`.
- **`omarchy-shell shell rescanPlugins` can serve a stale compile.** Even on a
  real directory it has been observed re-running the previous build of a QML
  file. `omarchy restart shell` is the reliable way to apply a change.

Validate the manifest and typecheck the QML before restarting:

```bash
omarchy plugin validate .
qmllint -I /usr/share/omarchy/shell -I . Panel.qml
```

`qmllint` will not catch a call to an undefined QML function — those resolve
at runtime — so exercise both surfaces after a change:

```bash
omarchy-shell omarchy-stats open            # essentials popup
omarchy-shell omarchy-stats.detail open     # detail window
```

The collector runs standalone, which is the fastest way to check a metric
without involving the shell at all:

```bash
{ printf 'mode full\n'; sleep 3; } | ./bin/sysmon-collect | tail -1 | python3 -m json.tool
```

## How it works

`bin/sysmon-collect` is a single long-lived Python process that streams one
JSON object per line on stdout. The panel steers it over stdin.

One process rather than one per metric: at a 1s cadence, spawning a process
per reading is not viable, and the collector also has to own the delta state —
CPU jiffies, byte counters, RC6 residency — that every rate is derived from.

It has two modes. Everything but the process table costs a handful of reads
and is collected always, which is what lets the hover tooltip carry disk and
network figures without any surface having been opened. Walking every
`/proc/<pid>` is the one genuinely expensive part, so it waits for the detail
window.

```
mode bar | full     escalate or de-escalate collection
interval <secs>     sampling period
procs <n>           rows the process table carries
sample              emit one sample
quit
```

Everything comes from `/proc` and `/sys`.

### GPU load

Dispatched by vendor, since no two expose it the same way:

| Vendor | Source |
|---|---|
| AMD | `gpu_busy_percent`, plus VRAM and temperature from the card's hwmon |
| NVIDIA | `nvidia-smi`, polled on its own slower cadence — it costs tens of milliseconds |
| Intel | Derived from RC6 residency |

Intel has no busy-percentage file. The i915 PMU that `intel_gpu_top` reads
needs perf access that `perf_event_paranoid=2` denies, so instead the load is
taken from the RC6 (render idle) residency counter: whatever fraction of wall
time the render engine was *not* parked in RC6 is time it was working. It
tracks `intel_gpu_top` closely and needs no privileges.

## Layout notes

A few things in here are load-bearing and easy to undo by accident:

- Component properties are named `leading`/`trailing`, not `left`/`right` —
  `Item` reserves those for its FINAL anchor lines and QML refuses to load.
- The collector reads its raw stdin fd rather than `readline()`. A buffered
  read pulls every queued command into Python's own buffer and returns only
  the first, leaving the rest invisible to the next `select()` — so a burst
  like `interval 1\nmode full\n` would apply its second line only when some
  later command happened to wake the loop.
- Tooltip rows are padded to a common width with U+00A0. Omarchy's shared
  tooltip centers each line, and Qt discards trailing ASCII whitespace when it
  measures a line for alignment, so ordinary padding leaves the table
  staggered.
- Bar percentages are gone in favour of one fixed-width glyph. A readout that
  resizes as values cross 9% and 99% reflows the widgets beside it and drags
  the popup anchored beneath it back and forth.

## License

MIT — see [LICENSE](LICENSE).
