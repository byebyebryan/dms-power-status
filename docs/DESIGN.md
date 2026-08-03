# Design: Charge history graph for DMS Power Status

Status: implemented as a working sketch (see `PowerStatusWidget.qml`); not yet
validated live in DMS.

## Context

`dms-power-status` is a DankMaterialShell bar widget that shows battery icon,
percentage, live charge/discharge wattage, and estimated time remaining in a
single compact pill. The core premise — wattage + time-to-empty/full at a
glance — is not fulfilled by any other plugin.

Its current shortcoming: it only renders the pill, and on click it opens the
built-in DMS battery popout. There is no panel of our own.

`dms-battery-plus` (arcatva) solves the panel side: a phone-style charge
history chart (12/24h), stat tiles, and a power-profile switcher. Its bar pill
is strictly worse than ours (it only mirrors the built-in icon + percent). So
the plugins are complementary, not competing.

## Goals

- Keep the existing pill (percentage · watts · eta) as-is. This is the
  differentiator.
- Add a charge history chart as the popout content (replacing the reuse of the
  built-in battery popout).
- Stay minimal. A quick-glance widget. We are not chasing everything
  dms-battery-plus shows. Specifically NOT in scope: health/capacity/energy
  stat tiles, power-profile switcher, voltage, avg-drain/runtime stat tiles,
  "since unplug" summary. The graph by itself is the improvement.

## Data path

Today the plugin does zero data gathering of its own. It reads DMS's
`BatteryService` singleton (`/usr/share/quickshell/dms/Services/BatteryService.qml`),
a thin wrapper over Quickshell's `Quickshell.Services.UPower` (system D-Bus to
`org.freedesktop.UPower`).

Values available from `BatteryService`:

- `batteryLevel` — aggregated int %, rounded
- `isCharging` / `isPluggedIn` / `isLowBattery` / `isCriticalBattery`
- `changeRate` — live W
- `formatTimeRemaining()` — smoothed ETA string ("Xh Ym" or "Unknown")
- `batteryHealth`, `batteryEnergy`, `batteryCapacity` (Wh), `batteryStatus`,
  `getBatteryIcon()`

Confirmed the underlying `UPowerDevice` (local qmltypes) exposes `changeRate`,
`energy`, `energyCapacity`, `timeToEmpty/Full`, `percentage`,
`healthPercentage`, `state`, `nativePath`, etc. — but **no voltage**. DMS's
`batteryLevel` is derived from energy/capacity, so it also carries the
already-smoothed state.

### Graph data

All the chart needs is `{time, level, charging}`:

- `level` — `BatteryService.batteryLevel`
- `charging` — derived from `BatteryService.isCharging` / `isPluggedIn`
- `time` — epoch seconds at sample time

No shell-outs, no `/sys`, no new runtime deps.

## Retention

DMS ships the file cache we need: `PluginService.savePluginState(pluginId, key, value)`
/ `loadPluginState(pluginId, key, default)` (see `PluginService.qml`). Persists
to a per-plugin JSON file at `~/.local/state/DankMaterialShell/plugins/<pluginId>_state.json`,
with atomic writes and a 150 ms debounced flush. This is the documented Tier-2
use case ("history, cache, counters").

Design:

- `Timer` on the **plugin root** (not the popout content) samples every 60 s
  → `{t, level, charging}`. The root is a persistent instance created by the
  bar's `WidgetHost` and stays alive while DMS runs, so the sampler collects in
  the background whether or not the popout is open. (The popout content is a
  separate lazy-loaded tree — `PluginPopout.qml` — that only exists when open.)
- Also sample immediately on `isCharging` / `isPluggedIn` change so the
  charge/discharge segment boundary is exact instead of up-to-60 s off.
- Append unconditionally (no dedupe) — consecutive identical values are real
  flat-line data that keep the time axis honest; file size is trivial.
- Persist via `savePluginState("powerStatus", "samples", samples)`.
- Load on `Component.onCompleted`, prune samples older than the window.

Window of 12 h at 60 s ≈ 720 entries — trivial size.

**Granularity rationale.** `batteryLevel` is an integer % that moves slowly —
typical drain is ~5–15 W against a 40–80 Wh pack, so 1% takes ~2–5 min. At 60 s
we get 2–5 samples per percentage step: smooth line, no aliasing, and at-most
60 s staleness at the "now" edge. The event-triggered boundary samples are what
keep transition colors exact.

### Single instance assumption

We assume one instance of the widget in the bar. Multiple instances are
technically possible (each bar entry creates its own `WidgetHost` →
`PluginComponent`), but not a realistic configuration for a battery widget.
`savePluginState` is per-plugin, whole-value set, so two writers could lose a
sample on read-modify-write — acceptable, not worth guarding now. A one-line
`setGlobalVar` sampler-claim is the escape hatch if ever needed.

## Trade-offs accepted

- **No pre-install history.** Self-sampling only accumulates after the plugin
  runs. Unlike dms-battery-plus, which backfills from UPower's retained
  history via `GetHistory` (but at the cost of shelling out to `upower` +
  `gdbus` every 5 min). We deliberately choose no-backfill + zero deps.
- **No voltage.** DMS/Quickshell does not expose it; dms-battery-plus reads
  `/sys/class/power_supply/BAT*/voltage_now`. Out of scope.
- **No history during suspend.** Samples stop while suspended (no polling
  wakes the system).

## Popout

- Replace the current click-through to the built-in battery popout with our
  own `popoutContent` (the chart).
- Chart: `Canvas` (as dms-battery-plus does), themed, discharge in
  `Theme.primary`, charging in `Theme.success`, suspend gaps as dashed
  connectors. Legend (green = charging, primary = discharging, dashed =
  suspend) and a marker on the newest sample with its level.
- Reuse the existing `openBatteryPopout`-style positioning logic in the click
  handler so the popout respects bar edge, spacing, and bottom gap.
- 12 h window only (constant). No 12/24 h toggle — that settings surface is the
  kind of thing we're deliberately skipping. 24 h can be added later as a
  three-line change if wanted.

## Open questions / next steps

- [x] Sampling interval: 60 s heartbeat + event-triggered boundary samples.
- [x] Span toggle: 12 h only, no toggle.
- [x] Hover tooltip: skip in v1; legend + newest-sample marker instead. Hover
      is the obvious v1.1 addition if the chart feels opaque.
- [x] Sketch the merged widget (existing pill + chart popout) in a working
      tree.
- [ ] Validate live in DMS (reload plugin, confirm pill + popout + sampling).
- [ ] No-battery path verified by inspection only so far.
