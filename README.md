# DMS Power Status

[![Validate](https://github.com/byebyebryan/dms-power-status/actions/workflows/validate.yml/badge.svg)](https://github.com/byebyebryan/dms-power-status/actions/workflows/validate.yml)

A compact, adaptive battery and power-usage widget for
[DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell).

Power Status adds live charge or discharge power and a charge-limit-aware ETA
to the DankBar pill. Its popout keeps the 24-hour battery graph visible while
showing battery facts and the current or most recently completed battery
session.

**Project status:** stable. The current scope is intentionally read-only and
maintenance-first; compatibility, correctness, accessibility, and documentation
take priority over new controls or view modes.

## What it shows

| Surface | Contents |
| --- | --- |
| DankBar pill | Battery icon, percentage, instantaneous watts, and estimated time remaining |
| Popout overview | Current power state, always-visible 24-hour graph, legend, and battery facts |
| Session details | Current session while on battery; latest completed session while plugged in |

Session details include starting energy and charge, duration, estimated use
while asleep, measured use while awake, battery drop, and low/average/high
awake draw when power coverage is complete. Sub-0.1W discharge reads are
treated as unavailable for awake measurements, so they cannot create a
misleading 0.0W low or dilute energy. A completed session is frozen at the
confirmed plug boundary and persists independently of the rolling graph
history.

## Highlights

- Themed 24-hour chart for charging, on-battery, plugged-in, and asleep
  periods, with six-hour ticks and a newest-sample marker.
- Rate-tinted on-battery segments, normalized from the window's observed
  minimum to maximum draw, plus a neutral underfill that works across states.
- Battery design capacity, charge limit, and health remain visible with the
  graph; only session details scroll on short or scaled displays.
- Automatic current/last-session presentation with concise collecting and
  empty states—no selector or extra view state.
- Direct Linux sysfs reads for percentage, state, watts, capacity, source
  presence, and firmware charge limit; no DMS `BatteryService` dependency.
- Instantaneous aggregate power rounded half-up to the nearest 0.1W at every
  draw level; smoothing is used only for ETA.
- Support for both `energy_*` and `charge_*` battery data, including aggregated
  system batteries and filtering for peripheral/device-scope batteries.
- One shared sampler and state writer across multi-monitor bar instances, with
  last-good values held through transient reads and reloads.
- Horizontal and vertical DankBar layouts, descriptive accessibility metadata,
  and automatic hiding on systems without a battery.

History stays in the local DMS plugin state file. The widget makes no network
requests, does not write sysfs, and does not change power profiles or firmware
settings.

## Requirements

- DankMaterialShell `>=1.5.0`.
- Linux power-supply data under `/sys/class/power_supply`.
- POSIX `sh` and standard system utilities.

## Installation

Clone the plugin into the DMS plugin directory:

```sh
mkdir -p ~/.config/DankMaterialShell/plugins
git clone https://github.com/byebyebryan/dms-power-status.git \
  ~/.config/DankMaterialShell/plugins/powerStatus
```

Then load it:

```sh
dms ipc plugins reload powerStatus
dms ipc plugins status powerStatus
```

In DMS settings, enable **Power Status** and add `powerStatus` to the DankBar
widget list. Remove the built-in `battery` widget from that list if Power Status
is replacing it.

To update a clone without merging local changes:

```sh
git -C ~/.config/DankMaterialShell/plugins/powerStatus pull --ff-only
dms ipc plugins reload powerStatus
```

### Local development install

From this repository, link the checkout into DMS:

```sh
mkdir -p ~/.config/DankMaterialShell/plugins
ln -sfnT -- "$(git rev-parse --show-toplevel)" \
  ~/.config/DankMaterialShell/plugins/powerStatus
```

GNU `-T` treats `powerStatus` as the link itself. The command replaces an
existing symlink or file but deliberately refuses a real non-empty directory;
move an existing clone aside before switching it to a development symlink.

## Development

Run the canonical repository gate:

```sh
./scripts/check
```

It validates the manifest/changelog contract and QML structure, runs the exact
production-logic regression suite, invokes `qmllint` and `qmlformat` when
available, and checks the diff for whitespace errors. The default DMS QML
import path is `/usr/share/quickshell/dms`; override it with
`DMS_QML_IMPORT_PATH` when needed.

`power_status_logic_v4.js` is a shared QML library and an explicit cache/API
generation. When its exported behavior changes, bump the suffix and update the
QML import, Node harness, and references together so DMS hot reloads cannot
retain an older library URL.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the stable product boundaries and
runtime checks, [docs/DESIGN.md](docs/DESIGN.md) for implementation details,
and [CHANGELOG.md](CHANGELOG.md) for release history.

## License

MIT
