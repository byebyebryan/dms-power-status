# DMS Power Status

Compact adaptive battery and power usage widget for DankMaterialShell.

It replaces the built-in `battery` bar widget when you want battery percentage
plus live charge/discharge power and estimated time remaining in the same small
bar pill — and adds a 24h charge history chart with usage stats as its popout.

## Features

- Battery icon + percentage in a compact pill.
- Live charge/discharge wattage and time remaining (charge-limit aware).
- 24h charge history popout: themed canvas chart with charge / discharge /
  plugged-idle coloring, suspend gaps, legend, and a newest-sample marker.
  The discharge line is rate-tinted — it fades from a muted discharge hue at
  low draw to the full discharge color at the window's max observed draw.
- Battery stats in the popout: design capacity, charge limit, and health.
- Session stats since last unplug: starting capacity/%, elapsed time, plus
  estimated suspended consumption (Wh, %, time) and measured active
  consumption (drained Wh, battery drop, time) with a min/avg/max rate row.
- Charge limit read from firmware via sysfs, so the ETA and graph respect it.
- Reads battery data directly from sysfs (like the zsh battery prompt); no DMS
  `BatteryService` dependency.
- Holds last-good values so plug/unplug transients never blank the pill.
- Hides itself on systems without a battery.
- Supports horizontal and vertical DankBar layouts.

## Requirements

- DankMaterialShell `>=1.4.6`.
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
ln -sfn "$PWD" ~/.config/DankMaterialShell/plugins/powerStatus
```

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
dms ipc plugins reload powerStatus
dms ipc plugins status powerStatus
dms ipc widget list | rg 'powerStatus|battery'
journalctl --user -u dms.service --since '1 minute ago' --no-pager
```

Note: `qmllint` returns a non-zero exit on this file due to `?.` optional
chaining syntax it doesn't understand (pre-existing, also affects the original
DMS widget); the parse is otherwise clean.

## License

MIT
