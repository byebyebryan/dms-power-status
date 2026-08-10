# Design: Charge history graph for DMS Power Status

Status: implemented and validated live on laptop (carbon) and desktop
(battery-less) machines.

## Context

`dms-power-status` is a DankMaterialShell bar widget that shows battery icon,
percentage, live charge/discharge wattage, and estimated time remaining in a
single compact pill. The core premise — wattage + time-to-empty/full at a
glance — is not fulfilled by any other plugin.

Originally it only rendered the pill and opened the built-in DMS battery popout
on click. It now ships its own popout with a 24h charge history chart plus
usage stats.

`dms-battery-plus` (arcatva) has a similar panel with a chart, stat tiles, and
a power-profile switcher. We deliberately kept our scope smaller (see Goals).

## Goals

- Keep the pill (percentage · watts · eta) as the differentiator.
- Add a charge history chart as the popout content (replacing the reuse of the
  built-in battery popout).
- Add a compact usage-stats section: battery stats (design capacity, charge
  limit, health), a since-unplug session summary, and measured active vs
  estimated suspended consumption with a min/avg/max rate row.
- Stay minimal. NOT in scope: power-profile switcher, voltage, charge-cycle
  history tiles.

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
- `energy_full_design` (`charge_full_design` fallback) → Wh for health
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

- 60s heartbeat sample → `{t, level, state, watts}` plus immediate samples on
  plug/charging boundaries.
- 24h window; pruned on load/save. ~1440 entries, trivial size.

### Single instance assumption

One instance in the bar. Multiple instances are technically possible but not
realistic for a battery widget; `savePluginState` is whole-value per plugin, so
two writers could lose a sample on read-modify-write — acceptable. A
`setGlobalVar` sampler-claim is the escape hatch if ever needed.

## Chart

- Canvas line, discharge in `Theme.primary`, charging in `Theme.success`,
  plugged-idle in `Theme.surfaceVariantText`, suspend gaps as dashed
  connectors.
- Discharge line is **rate-tinted**: each segment is blended within the
  discharge hue from a muted discharge color (low draw) to the full discharge
  color (high draw), normalized over the window's observed min→max discharge
  wattage. The newest-sample marker matches.
- Legend (Charging / Discharging / Plugged / Suspend) and a marker on the
  newest sample with its level.
- 6h time ticks, 0/50/100% grid, theme-reactive repaint.
- 24h window only (constant). No 12/24h toggle — deliberately skipped.

## Usage stats

Five labeled rows beneath the chart. Battery stats come straight from the held
sysfs values; session stats are computed from the persisted samples since the
last unplug.

- **Battery** — design capacity (`energy_full_design`, Wh), health (current
  capacity vs design, %), charge limit (`charge_control_end_threshold`, %).
- **Since unplug** — starting capacity (`start % × design capacity`, Wh),
  starting battery % at the unplug moment, and elapsed time since unplug.
- **Active** — measured consumption: drained (power integral `Σ w·dt / 3600`
  Wh), drop (battery-% loss summed across each continuous active run), and
  active time. Min/avg/max rate in its own row.
- **Suspended** — *estimated* consumption, since no draw is logged during
  gaps: for each recording gap the level drop `start% − end%` is recorded and
  summed; Wh is that drop converted against design capacity. Time is the gap
  duration.

"Active" means regular discharge samples; "suspended" means recording gaps
(suspend/off). If there's no unplug in the window (was already discharging, or
never), the session falls back to the window start or shows all dashes. Samples
recorded before the `w` field existed are skipped for the Wh math only (% and
time still count), so upgrading never misreports.

## Trade-offs accepted

- **No pre-install history.** Self-sampling only accumulates after the plugin
  runs; unlike battery-plus we don't backfill from UPower history.
- **No voltage**, **no power profiles** — out of scope.
- **No history during suspend** — samples stop while suspended (the stats still
  count suspended time from the recording gaps).
- **Health is derived** from `energy_full / energy_full_design`; some firmwares
  don't expose design capacity, in which case health shows a dash.
- sysfs rather than UPower D-Bus: matches the zsh prompt, works on machines
  where the UPower service layer might aggregate differently, and is the only
  place the charge limit is reliably exposed.
