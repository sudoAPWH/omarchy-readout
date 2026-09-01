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

Omarchy loads plugins from `~/.config/omarchy/plugins/<id>/`. To work from a
checkout elsewhere, point that path at it:

```bash
ln -s ~/Projects/omarchy-stats ~/.config/omarchy/plugins/omarchy-stats
```

Apply changes with `omarchy restart shell`. Hot-reload does not fire for a
symlinked plugin directory, and `rescanPlugins` can re-run the previous build
of a QML file.

Check the manifest and the QML before restarting:

```bash
omarchy plugin validate .
qmllint -I /usr/share/omarchy/shell -I . Panel.qml
```

Neither catches a call to an undefined QML function, so exercise both surfaces
after a change:

```bash
omarchy-shell omarchy-stats open            # essentials popup
omarchy-shell omarchy-stats.detail open     # detail window
```

The collector runs standalone, without the shell:

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

## License

MIT — see [LICENSE](LICENSE).
