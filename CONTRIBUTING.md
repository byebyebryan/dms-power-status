# Contributing

Power Status is stable and maintenance-first. Changes should preserve the
small, read-only battery-monitoring scope and favor compatibility, correctness,
accessibility, or documentation over new controls and modes.

## Product boundaries

- Keep the 24-hour graph and battery facts visible in the popout.
- Show the current session while on battery and the latest completed session
  while plugged in; do not add a view selector for those states.
- Read power data from Linux sysfs without changing firmware or power-profile
  settings.
- Keep persisted history local to DMS plugin state.
- Treat power profiles, voltage controls, and long-term analytics as out of
  scope unless the product direction is explicitly reopened.

## Validate a change

Run the repository gate from the project root:

```sh
./scripts/check
```

The gate validates the manifest and changelog, checks QML structure, runs the
production-logic regression suite, and uses `qmllint`/`qmlformat` when they are
available locally. Set `DMS_QML_IMPORT_PATH` if DMS is installed somewhere
other than `/usr/share/quickshell/dms`.

For UI or lifecycle changes, also reload the live plugin and inspect its state:

```sh
dms ipc plugins reload powerStatus
dms ipc plugins status powerStatus
dms ipc widget list | rg powerStatus
journalctl --user -u dms.service --since '1 minute ago' --no-pager
```

Do not delete the persisted state file merely to test a new build. Inspect its
schema and exercise compatibility paths first.

## Versioning notes

- User-visible or behavioral releases update both `plugin.json` and
  `CHANGELOG.md`.
- If the exported QML library API or behavior changes, bump the
  `power_status_logic_v3.js` resource suffix and update its QML import, test
  harness, and documentation references together. This avoids stale shared
  library code across DMS hot reloads.
