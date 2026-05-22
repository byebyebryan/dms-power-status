# DMS Power Status

Compact adaptive battery and power usage widget for DankMaterialShell.

It is meant to replace the built-in `battery` bar widget when you want battery
percentage plus live charge/discharge power and estimated time remaining in the
same small bar pill.

## Features

- Shows the current battery icon and percentage.
- Shows charge or discharge power when the reading is useful.
- Shows DMS' estimated time remaining when available.
- Uses DMS theme colors for normal, charging, plugged-in, and low-battery
  states.
- Clicks through to the built-in DMS battery popout.
- Hides itself on systems without a battery.
- Supports horizontal and vertical DankBar layouts.

## Requirements

- DankMaterialShell `>=1.4.6`.
- A system battery exposed through DMS' `BatteryService`.

No external runtime command-line tools are required.

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

The widget intentionally uses DMS' built-in battery popout instead of shipping a
separate popout. The click handler mirrors the built-in battery widget's popup
positioning path so the popout respects bar edge, spacing, and bottom gap.

## License

MIT
