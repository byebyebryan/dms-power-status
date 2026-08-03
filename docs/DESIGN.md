# Design: Charge history graph for DMS Power Status

Status: implemented and validated live on laptop (carbon) and desktop
(battery-less) machines.

## Context

`dms-power-status` is a DankMaterialShell bar widget that shows battery icon,
percentage, live charge/discharge wattage, and estimated time remaining in a
single compact pill. The core premise — wattage + time-to-empty/full at a
glance — is not fulfilled by any other plugin.

Originally it only rendered the pill and opened the built-in DMS battery popout
on click. It now ships its own popout with a 12h charge history chart.

`dms-battery-plus` (arcatva) has a similar panel with a chart, stat tiles, and
a power-profile switcher. We deliberately kept our scope smaller (see Goals).

## Goals

- Keep the pill (percentage · watts · eta) as the differentiator.
- Add a charge history chart as the popout content (replacing the reuse of the
  built-in battery popout).
- Stay minimal. NOT in scope: health/capacity/energy stat tiles, power-profile
  switcher, voltage, avg-drain/runtime tiles, "since unplug" summary.

## Data source: direct sysfs (not DMS BatteryService)

The widget reads the battery straight from `/sys/class/power_supply/*` via a
single `sh -c` (mirroring the zsh battery prompt in dotfiles), instead of going
through DMS's `BatteryService`. Why:

- **Charge limit.** The real limit lives in firmware/sysfs
  (`charge_control_end_threshold`, or `charge_control_limit` /
  `charge_stop_threshold` fallbacks). DMS's `SettingsData.batteryChargeLimit`
  is a write-only setting that defaults to 100 and never reconciles to
  hardware — on carbon the hardware was 80 while DMS said 100.
- **One source of truth** for level, rate, AC state, and limit, so the pill,
  panel, and graph can't disagree.

Fields read in one `sh -c` (µW/µWh converted to W/Wh):

- `capacity` → level
- `status` → charging state (`Charging` / `Discharging` / `Not charging` /
  `Full`)
- `power_now`, with `current_now × voltage_now` fallback → watts
- `energy_now` / `energy_full` → Wh for ETA math
- any supply's `online` → AC / plugged-in
- `charge_control_end_threshold` → charge limit

### Transient handling

Values are **held last-good**: a transient empty/0 read on plug/unplug keeps
the previous valid value, so the pill never blanks. Battery presence uses a
`type=Battery` scan with a 3-streak debounce before hiding on a battery-less
desktop. The refresh timer polls every 5s while a battery is present, and falls
back to a 60s probe on desktops (so a hotplugged battery is still detected).

## ETA

Computed ourselves (DMS's `formatTimeRemaining()` ignores the charge limit and
always targets 100%):

- Charging: target = `min(limit, 100)%` of `energy_full`; time to that target
  at the smoothed rate.
- Discharging: `energy_now / rate`.
- Rate is a 30s-half-life EMA (reset + 2-read warm-up on plug/charging
  transitions so a transient low read right after unplug can't spike the ETA).
- Rendered as `h:mm`.

## Retention

DMS's `PluginService.savePluginState` / `loadPluginState` persist to a
per-plugin JSON file at
`~/.local/state/DankMaterialShell/plugins/powerStatus_state.json` (atomic,
debounced). The sampler lives on the plugin root (a persistent instance, alive
while DMS runs), so it collects in the background whether or not the popout is
open.

- 60s heartbeat sample → `{t, level, state}` plus immediate samples on
  plug/charging boundaries.
- 12h window; pruned on load/save. ~720 entries, trivial size.

### Single instance assumption

One instance in the bar. Multiple instances are technically possible but not
realistic for a battery widget; `savePluginState` is whole-value per plugin, so
two writers could lose a sample on read-modify-write — acceptable. A
`setGlobalVar` sampler-claim is the escape hatch if ever needed.

## Chart

- Canvas line, discharge in `Theme.primary`, charging in `Theme.success`,
  plugged-idle in `Theme.surfaceVariantText`, suspend gaps as dashed
  connectors.
- Legend (Charging / Discharging / Plugged / Suspend) and a marker on the
  newest sample with its level.
- 3h time ticks, 0/50/100% grid, theme-reactive repaint.
- 12h window only (constant). No 12/24h toggle — deliberately skipped.

## Trade-offs accepted

- **No pre-install history.** Self-sampling only accumulates after the plugin
  runs; unlike battery-plus we don't backfill from UPower history.
- **No voltage**, **no stat tiles**, **no power profiles** — out of scope.
- **No history during suspend** — samples stop while suspended.
- sysfs rather than UPower D-Bus: matches the zsh prompt, works on machines
  where the UPower service layer might aggregate differently, and is the only
  place the charge limit is reliably exposed.
