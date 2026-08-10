# Changelog

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
