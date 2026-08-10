# Changelog

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
