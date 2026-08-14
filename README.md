# DMS Power Status

Compact adaptive battery and power usage widget for DankMaterialShell.

It replaces the built-in `battery` bar widget when you want battery percentage
plus live charge/discharge power and estimated time remaining in the same small
bar pill — and adds a 24h charge history chart with usage stats as its popout.

## Features

- Battery icon + percentage in a compact pill.
- Live charge/discharge wattage and time remaining (charge-limit aware).
- 24h battery history popout: themed canvas chart with charging / on-battery /
  plugged-in coloring, asleep periods, legend, and a newest-sample marker. The
  on-battery line is rate-tinted — it fades from a muted hue at low draw to the
  full on-battery color at the window's max observed draw.
- Battery stats in the popout: design capacity, charge limit, and health.
- One continuous popout surface with a fixed 24h chart, compact legend, and
  battery facts; only the longer session details scroll internally on short or
  scaled displays.
- State-aware current/last battery-session stats: starting energy/charge and
  duration, estimated asleep use, measured awake use, battery drop, and
  low/average/high awake draw. Empty or newly started sessions show concise
  guidance instead of unavailable-value grids. A completed session is frozen
  at the confirmed plug/charge boundary and retained as the durable last
  session across reloads and rolling-sample pruning. While on battery, the
  current session is shown; while plugged in, the latest completed session is
  shown directly as the last battery session.
- Descriptive pill accessibility metadata and a short-screen scrollbar for
  the session details.
- Charge limit read from firmware via sysfs, so the ETA and graph respect it.
- Supports both `energy_*` (µWh) and `charge_*` (µAh) batteries, converting
  charge values with `voltage_now`; multiple system batteries are aggregated.
- Ignores peripheral/device-scope batteries and battery-type `online` entries
  when deciding whether the laptop is plugged in.
- Reads battery data directly from sysfs (like the zsh battery prompt); no DMS
  `BatteryService` dependency.
- All bar/screen instances share one process-wide sampler and history writer;
  a short-lived leader handoff keeps reloads and multi-monitor bars consistent.
- DMS 1.5.3's first state-write quirk is handled with one bounded, idempotent
  retry after the shell's persistence debounce.
- Holds last-good values so plug/unplug transients never blank the pill.
- Hides itself on systems without a battery.
- Supports horizontal and vertical DankBar layouts.

## Requirements

- DankMaterialShell `>=1.5.0` (for shared plugin globals).
- A system battery exposed via `/sys/class/power_supply`.

No external runtime command-line tools are required (plain POSIX `sh`).

## Installation

Clone the plugin into the DMS plugin directory:

```sh
mkdir -p ~/.config/DankMaterialShell/plugins
git clone https://github.com/byebyebryan/dms-power-status.git ~/.config/DankMaterialShell/plugins/powerStatus
```

For local development from this checkout:

```sh
mkdir -p ~/.config/DankMaterialShell/plugins
ln -sfnT -- "$(git rev-parse --show-toplevel)" ~/.config/DankMaterialShell/plugins/powerStatus
```

Run that command inside this repository. `git rev-parse --show-toplevel`
resolves the repository itself, so a shell launched from another directory
cannot accidentally link an unrelated `$PWD` into the DMS plugin directory.
GNU `-T` treats `powerStatus` as the link itself, preventing an existing
directory from becoming a nested `powerStatus/dms-power-status` link. It
replaces an existing symlink or file, but deliberately refuses a real
non-empty directory; move an existing clone aside first if you intend to
switch that installation to a symlink.

Then load it in DMS:

```sh
dms ipc plugins reload powerStatus
dms ipc plugins status powerStatus
```

In DMS settings, enable `Power Status` and add `powerStatus` to the DankBar
widget list. If you are replacing the built-in battery widget, remove `battery`
from that same list.

## Development

Useful local validation commands:

```sh
jq empty plugin.json
node tests/PowerStatusLogic.test.js
dms ipc plugins reload powerStatus
dms ipc plugins status powerStatus
dms ipc widget list | rg 'powerStatus|battery'
journalctl --user -u dms.service --since '1 minute ago' --no-pager
```

The regression command compiles the exact `power_status_logic_v2.js` production
source in a Node VM after removing only its QML `.pragma library` directive;
there is intentionally no direct `node --check` command for that QML pragma
file. The `_v2` suffix is an explicit QML resource/cache generation: when
exported APIs or behavior change, bump the suffix and update the QML import,
Node harness, and references so an ordinary DMS hot reload cannot retain an
older shared-library URL.

Standalone `qmllint`/`qmlscene` need the DMS import path and module versions to
be configured; on an unconfigured host they may exit non-zero (or report
`Library import requires a version`) before loading the component. The CI
balance check and production-logic Node tests remain available in that
environment.

## License

MIT
