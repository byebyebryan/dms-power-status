# Design: Charge history graph for DMS Power Status

Status: implemented for plugin 0.7.0; validate against the installed DMS after
deployment because the widget deliberately uses DMS PluginService globals.

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
- 24h window; pruned on load/save. ~1440 entries, trivial size.

Each DMS bar/screen creates a separate widget object. Runtime state is kept in
the DMS `PluginService` global variable `powerStatus.shared`; a lease elects
one leader to run the sysfs sampler, rate smoother, and whole-array state
writer. Followers mirror the same samples and normalized fields, so two
outputs cannot perform competing read-modify-write operations. If the leader
is destroyed, another instance claims the lease after 7s (or immediately when
the old instance releases it). The persisted file remains the one plugin state
key, but only the leader writes it.

`power_status_logic.js` is marked `.pragma library`. QML's shared-library
semantics are required here: every bar/screen imports the same stateless
power-domain functions, and DMS cache-busted hot reloads must not create a
context-bound script that fails when the parent component is reloaded. The
Node regression harness compiles the exact production file in a VM after
removing only that QML pragma, so the same source remains the syntax gate.

On DMS 1.5.3, `PluginService` has a first-write bug after a plugin reload: it
attempts to connect a signal on a boolean `FileView.loaded` property. The
leader primes the state writer and repeats the identical write once after
280ms, beyond the 150ms debounce. This bounded, idempotent compatibility
workaround is kept in the plugin; DMS itself is not patched.

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
- Legend (Charging / Discharging / Plugged / Suspend) and a marker on the
  newest sample with its level.
- 6h time ticks, 0/50/100% grid, theme-reactive repaint.
- 24h window only (constant). No 12/24h toggle — deliberately skipped.

## Usage stats

Four labeled rows beneath the chart. Battery stats come straight from the held
sysfs values; session stats are computed from the persisted samples since the
last unplug.

- **Battery** — design capacity (`energy_full_design`, Wh), charge limit
  (`charge_control_end_threshold`, %), health (current capacity vs design, %).
- **Since unplug** — starting capacity (`start % × current full capacity`, Wh),
  starting battery % at the unplug moment, and elapsed time since unplug.
- **Suspended** — *estimated* consumption, since no draw is logged during
  gaps: for each recording gap the level drop `start% − end%` is recorded and
  summed; Wh is that drop converted against current full capacity. Time is the
  gap duration.
- **Active** — measured consumption: drained (power integral `Σ w·dt / 3600`
  Wh), drop (battery-% loss summed across each continuous active run), and
  active time. A second unlabeled row beneath shows the min/avg/max discharge
  rate, aligned under the Active values.

"Active" means regular discharge samples; "suspended" means recording gaps
(suspend/off). The session stats **freeze at the plug boundary**: the final
discharge interval ends at the timestamp of the first plugged sample, not at
the previous discharge sample. If there's no unplug in the window, an active
session may use the first discharging sample; if there is no session, all
session values are unavailable rather than fabricated zeroes. A gap over 150s
is suspended. Physical Wh and rate stats require watt coverage at both ends of
every active interval; legacy samples without `w` therefore make measured Wh
and rate values unavailable for that session instead of mixing old and new
data. Percentage/time values remain available when their sample coverage is
valid.

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
  runs; unlike battery-plus we don't backfill from UPower history.
- **No voltage**, **no power profiles** — out of scope.
- **No history during suspend** — samples stop while suspended (the stats still
  count suspended time from the recording gaps).
- **Health is derived** from `energy_full / energy_full_design`; some firmwares
  don't expose design capacity, in which case health shows a dash.
- The graph/stat card is inside a bounded vertical `Flickable` whose viewport
  follows the trigger screen height, so DMS's content-height binding cannot
  place an oversized fixed popout off-screen.
- sysfs rather than UPower D-Bus: matches the zsh prompt, works on machines
  where the UPower service layer might aggregate differently, and is the only
  place the charge limit is reliably exposed.
