# Changelog

## 0.8.1

- Remove the pill hover tooltip because its popup fought the bar's hover/reveal
  lifecycle and flickered; retain the descriptive accessibility metadata.

## 0.8.0

- Reframe the popout around battery state with clearer charging, on-battery,
  plugged-in, sleep-gap, capacity, and session terminology.
- Replace unavailable session grids with state-aware collecting and empty
  messages, while distinguishing current sessions from completed sessions.
- Align pill, status, and chart color/icon semantics for charging, on-battery,
  plugged-idle, and low-battery states.
- Add 24-hour chart context, an integrated short-screen scrollbar, dynamic pill
  tooltips, and descriptive accessibility metadata.

## 0.7.0

- Aggregate usable system batteries, support both ENERGY_* and CHARGE_* sysfs
  units, and ignore peripheral/device-scope batteries and battery sources.
- Normalize charging, plugged-idle, and active-discharge state so an online
  source cannot hide a battery that is still discharging.
- Share one sampler and debounced state writer across all bar/screen instances,
  with leader handoff and a bounded DMS 1.5.3 first-write compatibility retry.
- Make session statistics conservative around suspend gaps and legacy samples,
  use current full capacity for physical Wh, and include the final plug-boundary
  discharge interval.
- Make the popout content-driven with a bounded scrollable history/statistics
  viewport for short and scaled displays.
- Add executable power-domain/session regression fixtures and run them in CI.

## 0.6.3

- Raise popout height to 600px so the five stat rows don't clip on the graph
  card.

## 0.6.2

- Neutral chart underfill: a single muted gradient beneath the line for all
  states (previously discharge-blue even under charging segments).
- Boundary samples now bypass the 5s rate-limit so plug/unplug flips the graph
  immediately instead of waiting up to a minute.
- Seed a sample on the first confirmed battery read so the chart isn't empty
  until the first 60s heartbeat.
- Lone samples between gaps draw as dots instead of vanishing.

## 0.6.1

- Suspended drained / design capacity show `–` instead of `0.0Wh` when the
  firmware exposes no design capacity (can't convert % drop to Wh).
- Risen-level gap detection now requires a >1% rise so `capacity` rounding
  noise doesn't restart the session.
- Refresh can't stall permanently if a read callback never fires (5s expiry).
- Chart repaints on `nestedSurface` theme changes; removed dead `pid` property.
- CI now sanity-checks QML brace/paren balance.

## 0.6.0

- Freeze the since-unplug stats at the plug moment so a finished discharge run
  survives plugging back in (elapsed no longer keeps growing while charging).
- Handle plug-during-suspend: waking unplugged with a risen battery level is
  treated as a fresh unplug at the wake sample; waking plugged keeps the frozen
  pre-suspend session.

## 0.5.2

- Restore the Active rate as a second, unlabeled row beneath Active (min/avg/
  max) instead of folding six tiles into one row.

## 0.5.1

- Reorganize stats: swap Limit/Health in Battery, move Suspended above Active,
  and fold min/avg/max rate into the Active row (dropping the separate
  "Active rate" header).

## 0.5.0

- Expand stats into five labeled rows: Battery (design capacity, health,
  limit), Since unplug (start capacity/%, elapsed), Active (drained Wh, drop %,
  time), Active rate (min/avg/max), and Suspended (estimated drained Wh, drop
  %, time).
- Active consumption is measured: Wh from the power integral, % from the
  battery-level drop summed across continuous active runs.
- Suspended consumption is estimated: the level drop across each recording
  gap, converted to Wh against design capacity.
- Session start captures starting capacity/percentage at the unplug moment.

## 0.4.3

- Rework discharge rate tint: blend within the discharge hue (muted → full
  discharge color) instead of across to the idle color, and normalize over the
  window's observed min→max discharge wattage.

## 0.4.2

- Rate-tint the discharge line in the chart: it blends from the idle color at
  low draw toward the discharge color at the window max (90th percentile
  reference), so drain intensity is visible at a glance.

## 0.4.1

- Reorganize the stats into three labeled rows: Battery (capacity, health,
  limit), Since unplug (drained, discharge time, suspended time), and
  Discharge rate (min/avg/max). "Discharge" now consistently means active
  discharge only.

## 0.4.0

- Add battery stats row: full capacity, charge limit, and health (capacity vs
  design, from `energy_full_design`).
- Discharge stats now count from the last unplug (session-based) instead of the
  whole 24h window, split into active discharge and suspended/idle discharge
  time. Energy and min/avg/max wattage apply to active discharge only.

## 0.3.0

- Widen the chart popout to 680px and extend the history window to 24h (6h
  time ticks instead of 3h).
- Add usage stats below the graph: discharge duration, energy drained, and
  min/avg/max discharge wattage over the 24h window.
- Samples now carry wattage; stats skip older samples saved without it.

## 0.2.0

- Add a 12h charge history chart as the popout, replacing the click-through to
  the built-in DMS battery popout.
- Read battery data directly from sysfs instead of DMS `BatteryService`, so the
  charge limit (firmware `charge_control_end_threshold`) is honored by the ETA
  and the graph.
- Charge-limit-aware time remaining (own math + 30s EMA rate smoothing).
- Graph distinguishes charging / discharging / plugged-idle states; legend and
  newest-sample marker.
- Hold last-good values so plug/unplug transients never blank the pill.
- Reduce refresh cadence to a 60s probe on battery-less desktops.

## 0.1.0

- Initial power status widget for DankMaterialShell.
- Display battery percentage, charge or discharge power, and time remaining.
- Open the built-in DMS battery popout from the widget.
