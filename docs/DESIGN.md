# Design and maintenance notes

Status: implemented and stable. Validate against an installed DMS after
deployment because the widget deliberately uses PluginService globals and one
shared sampler across bar instances. `plugin.json` and `CHANGELOG.md` are the
release-version authorities.

## Context

`dms-power-status` is a DankMaterialShell bar widget that shows battery icon,
percentage, live charge/discharge wattage, and estimated time remaining in a
single compact pill. Its core premise is wattage plus time-to-empty/full at a
glance.

Originally it only rendered the pill and opened the built-in DMS battery popout
on click. It now ships its own popout with a 24h charge history chart plus
usage stats.

The product deliberately keeps this scope smaller than a general power-control
panel: it observes battery behavior but does not change power profiles,
firmware settings, or charge limits.

## Goals

- Keep the pill (percentage · watts · ETA) as the differentiator.
- Keep the 24-hour graph and battery facts visible whenever the popout is open.
- Show one automatic session view: current while on battery, latest completed
  while plugged in.
- Split session consumption into measured Awake use and estimated Asleep use,
  with low/average/high awake draw when coverage is complete.
- Stay read-only and minimal. Power-profile controls, voltage controls,
  charge-cycle analytics, and alternate graph/session view modes are not in
  scope.

## Data source: direct sysfs (not DMS BatteryService)

The widget reads the battery straight from `/sys/class/power_supply/*` via a
single `sh -c`, instead of going through DMS's `BatteryService`. Why:

- **Charge limit.** The real limit lives in firmware/sysfs
  (`charge_control_end_threshold`, or `charge_control_limit` /
  `charge_stop_threshold` fallbacks). DMS's `SettingsData.batteryChargeLimit`
  is a write-only setting that defaults to 100 and may not reconcile to the
  hardware value.
- **One source of truth** for level, rate, AC state, and limit, so the pill,
  panel, and graph can't disagree.

Fields read in one `sh -c` (µW/µWh converted to W/Wh):

- `capacity` → level
- `status` → charging state (`Charging` / `Discharging` / `Not charging` /
  `Full`)
- `power_now`, with `current_now × voltage_now` fallback → watts
- `energy_now` / `energy_full` → Wh for ETA and physical-capacity math
- `charge_now` / `charge_full` → converted to µWh with `voltage_now` when the
  ENERGY_* family is absent
- `energy_full_design` / `charge_full_design` → Wh for health only
- `power_now`, or `current_now × voltage_now`, is summed across usable batteries
- online non-battery system sources (`Mains`, `USB`, USB-C, wireless, and
  vendor-specific system supplies) → source presence; battery and
  `scope=Device` entries are ignored
- `charge_control_end_threshold` → charge limit

Every battery must expose a valid `capacity` and is excluded when
`scope=Device`; this prevents HID/peripheral batteries from changing the
laptop's percentage or plugged state. When every usable battery has a given
physical value, full/now/design values are aggregated; if one battery lacks a
physical value, that quantity is unavailable rather than a partial sum.

### Power display contract

The sampler retains each usable system battery's raw `power_now` value, or its
absolute `current_now × voltage_now` fallback, in µW until all batteries have
been summed. The pill shows that instantaneous aggregate to one decimal place
using half-up rounding and hides readings below 0.1W. Session low, average, and
high power use the same one-decimal formatter and may show `0.0W`. Live displayed
power is never smoothed—only the separate ETA calculation uses the rate EMA.

### Transient handling

Values are **held last-good**: a command with a non-zero exit or an expired
callback does not change presence or state. Only a successful scan that
confirms no usable battery advances the three-read hide streak. The command
timeout is 1s, shorter than the 5s stale-read release. The refresh timer polls
every 5s while a battery is present, and falls back to a 60s probe on desktops.
Discharging status is authoritative over a simultaneous online source; the
normalized state is one of `charging`, `plugged`, `discharging`, or `none` and
drives the pill, icon, ETA, and samples together.

## ETA

Computed ourselves (DMS's `formatTimeRemaining()` ignores the charge limit and
always targets 100%):

- Charging: target = `min(limit, 100)%` of `energy_full`; time to that target
  at the smoothed rate.
- Discharging: `energy_now / rate`.
- Rate is a 30s-half-life EMA (reset + 2-read warm-up on plug/charging
  transitions so a transient low read right after unplug can't spike the ETA).
- Rendered as `h:mm`.

## Retention and shared sampling

DMS's `PluginService.savePluginState` / `loadPluginState` persist to a
per-plugin JSON file at
`~/.local/state/DankMaterialShell/plugins/powerStatus_state.json` (atomic,
debounced). The elected leader runs independently of the popout, so history
collection continues while the popout is closed.

- 60s heartbeat sample → `{t, v, c, w}` (`c`: 0 discharging, 1 charging, 2
  plugged-idle) plus immediate samples on plug/charging boundaries.
- 24h window; pruned on load/save. ~1440 entries, trivial size. These samples
  remain the sole source for the chart and the live current-session view.
- A separate `lastSession` state key stores the latest completed session as a
  schema-versioned, JSON-safe snapshot. It is finalized only at a confirmed
  discharge-to-charging/plugged boundary, then retained until a newer valid
  session completes. It is not pruned with the rolling samples.
- Existing installs with only `samples` are migrated conservatively. A
  one-time backfill is allowed only after a confirmed plugged read and an
  unambiguous completed boundary is present in the retained samples; malformed
  snapshots and ambiguous/current discharging histories are not guessed.

Each DMS bar/screen creates a separate widget object. Runtime state is kept in
the DMS `PluginService` global variable `powerStatus.shared`; a lease elects
one leader to run the sysfs sampler, rate smoother, and whole-array state
writer. Followers mirror the same samples, snapshot, and normalized fields, so
two outputs cannot perform competing read-modify-write operations. If the
leader is destroyed, another instance claims the lease after 7s (or immediately
when the old instance releases it). The persisted file contains the rolling
`samples` and durable `lastSession` keys, but only the leader writes them.

`power_status_logic_v3.js` is marked `.pragma library`. QML's shared-library
semantics are required here: every bar/screen imports the same stateless
power-domain functions, and DMS cache-busted hot reloads must not create a
context-bound script that fails when the parent component is reloaded. The
resource suffix is an explicit cache/API generation; any exported API or
behavior change must bump it and update the QML import, Node harness, and
references so an ordinary DMS hot reload cannot retain an older shared-library
URL. The Node regression harness compiles the exact production file in a VM
after removing only that QML pragma, so the same source remains the syntax
gate.

On DMS 1.5.3, `PluginService` has a first-write bug after a plugin reload: it
attempts to connect a signal on a boolean `FileView.loaded` property. The
leader primes the state writer and repeats the current `samples` and
`lastSession` values once after 280ms, beyond the 150ms debounce. This bounded,
idempotent compatibility workaround is kept in the plugin; DMS itself is not
patched.

## Chart

- Canvas line, discharge in `Theme.primary`, charging in `Theme.success`,
  plugged-idle in `Theme.surfaceVariantText`, suspend gaps as dashed
  connectors. A single neutral underfill gradient is drawn beneath the line for
  every state, so it never clashes with the green charging or blue discharge
  lines. Lone samples between gaps render as dots rather than vanishing.
- Discharge line is **rate-tinted**: each segment is blended within the
  discharge hue from a muted discharge color (low draw) to the full discharge
  color (high draw), normalized over the window's observed min→max discharge
  wattage. The newest-sample marker matches.
- Legend (Charging / On battery / Plugged in / Asleep) and a marker on the
  newest sample with its level.
- 6h time ticks, 0/50/100% grid, theme-reactive repaint.
- 24h window only (constant). There is no time-range toggle.

## Popout layout and usage stats

The popout uses one continuous dashboard surface that keeps the fixed 24h
chart, compact legend, and battery facts (design capacity, charge limit, and
health) visible together. Session details follow below a subtle divider in an
internal bounded vertical viewport, so a short or scaled display scrolls only
the longer session-stat area without creating a second visual card.
While on battery, the details always show the current session. When plugged or
charging, they automatically show the persisted latest completed session as
`Last battery session`; there is no session selector or additional view state.

Battery stats come straight from held sysfs values; current-session stats are
computed from rolling samples and durable completed-session stats are copied
from the separate `lastSession` snapshot.

- **Battery** — design capacity (`energy_full_design`, Wh), charge limit
  (`charge_control_end_threshold`, %), health (current capacity vs design, %).
- **Current/last battery session** — starting capacity
  (`start % × current full capacity`, Wh), starting battery % at the unplug
  moment, and elapsed time since unplug.
- **Asleep** — *estimated* consumption, since no draw is logged during
  gaps: for each recording gap the level drop `start% − end%` is recorded and
  summed; Wh is that drop converted against current full capacity. Time is the
  gap duration.
- **Awake** — measured consumption: energy used (power integral `Σ w·dt / 3600`
  Wh), drop (battery-% loss summed across each continuous active run), and
  active time. An aligned, unlabeled follow-on row shows low/average/high draw
  only when watt coverage is complete.

"Awake" means regular discharge samples; "Asleep" means recording
gaps (suspend/off). Session stats **freeze at the plug boundary**: the final
discharge interval ends at the timestamp and level of the first confirmed
plugged/charging sample. If there is no session, values remain unavailable
rather than fabricated zeroes. A gap over 150s is treated as asleep. Physical
Wh and rate stats require watt coverage at both ends of every active interval;
legacy samples without `w` therefore leave measured Wh/rate unavailable while
valid time and battery-drop values remain available.

### Session start edge cases

- **Unplug during suspend** is a normal boundary: the sample after the gap is
  discharging following a plugged one, so the transition scan catches it.
- **Plug during suspend, wake unplugged** (level rose across a gap): treated as
  a fresh unplug at the wake sample — the risen charge sits outside the
  session, so no suspended time/Wh is charged against it.
- **Plug during suspend, wake plugged**: no reset; the long unobserved interval
  is classified as suspended and the session freezes at the first confirmed
  plugged sample.

## Trade-offs accepted

- **No pre-install history.** Self-sampling only accumulates after the plugin
  runs; the plugin does not backfill from UPower history.
- **No voltage**, **no power profiles** — out of scope.
- **No history during suspend** — samples stop while suspended (the stats still
  count suspended time from the recording gaps).
- **Health is derived** from `energy_full / energy_full_design`; some firmwares
  don't expose design capacity, in which case health shows a dash.
- The session-details area is inside a bounded vertical `Flickable` whose
  viewport follows the trigger screen height; it shares the dashboard surface,
  while the chart and battery facts stay outside the scrolling content so DMS's
  content-height binding cannot hide the fixed overview.
- sysfs rather than UPower D-Bus keeps the pill, chart, and session calculations
  on one data source and exposes the firmware charge limit directly.
