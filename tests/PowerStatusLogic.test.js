const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// Keep this path synchronized with the versioned filename imported by QML.
// Bump that resource generation when exported APIs or behavior change so a
// DMS hot reload cannot retain an older shared-library URL. Compile the exact
// QML production resource. Node does not understand
// `.pragma library`, so remove only that one directive in the VM copy; all
// production code remains byte-for-byte identical and is still syntax-checked.
const logicPath = path.join(__dirname, "..", "power_status_logic_v3.js");
const productionSource = fs.readFileSync(logicPath, "utf8");
const sourceLines = productionSource.split(/\r?\n/);
const pragmaLine = sourceLines.findIndex(line => line === ".pragma library");
assert.notEqual(pragmaLine, -1, "production module must declare .pragma library");
assert.equal(
    sourceLines.filter(line => line === ".pragma library").length,
    1,
    "production module must contain exactly one library pragma"
);
const nodeSource = sourceLines.slice(0, pragmaLine)
    .concat(sourceLines.slice(pragmaLine + 1)).join("\n");
const productionModule = { exports: {} };
vm.runInNewContext(nodeSource, {
    module: productionModule,
    exports: productionModule.exports,
    console
}, { filename: logicPath });
const logic = productionModule.exports;

function approx(actual, expected, epsilon = 1e-9) {
    assert.ok(Math.abs(actual - expected) <= epsilon,
        `expected ${actual} to be within ${epsilon} of ${expected}`);
}

const fixture = JSON.parse(fs.readFileSync(
    path.join(__dirname, "fixtures", "sysfs-records.json"), "utf8"));

// Power displays use one decimal at every draw level and round half-up in
// tenths. Only the pill hides valid readings below 0.1W.
{
    assert.equal(logic.formatPowerWatts(undefined, false), "");
    assert.equal(logic.formatPowerWatts(null, false), "");
    assert.equal(logic.formatPowerWatts(NaN, false), "");
    assert.equal(logic.formatPowerWatts(0, false), "0.0W");
    assert.equal(logic.formatPowerWatts(0.099999, true), "");
    assert.equal(logic.formatPowerWatts(0.1, true), "0.1W");
    assert.equal(logic.formatPowerWatts(1.04, true), "1.0W");
    assert.equal(logic.formatPowerWatts(1.05, true), "1.1W");
    assert.equal(logic.formatPowerWatts(9.95, true), "10.0W");
    assert.equal(logic.formatPowerWatts(11.14, true), "11.1W");
    assert.equal(logic.formatPowerWatts(11.15, true), "11.2W");
}

// ENERGY_* and CHARGE_* are both accepted, with charge values converted using
// voltage_now. The Device-scope HID battery is excluded from every aggregate.
{
    const result = logic.aggregateBatteryRecords(fixture.batteries, fixture.sources);
    assert.equal(result.hasBattery, true);
    assert.equal(result.batteryCount, 1);
    approx(result.energyNowWh, 3978000 * 11739000 / 1000000 / 1000000);
    approx(result.energyFullWh, 5095000 * 11739000 / 1000000 / 1000000);
    approx(result.energyFullDesignWh, 7393000 * 11739000 / 1000000 / 1000000);
    assert.equal(result.level, 78);
    assert.equal(result.limit, 80);
    assert.equal(result.state, "plugged");
    assert.equal(result.sampleCode, 2);
    assert.ok(result.watts > 0);
}

// Multiple system batteries are weighted by their physical full capacities,
// not averaged as percentages, and their draw is summed in watts.
{
    const result = logic.aggregateBatteryRecords([
        { scope: "System", capacity: 50, status: "Discharging",
            energyNowUwh: 500000, energyFullUwh: 1000000, powerUw: 100000 },
        { scope: "System", capacity: 75, status: "Discharging",
            energyNowUwh: 1500000, energyFullUwh: 2000000, powerUw: 200000 }
    ], []);
    assert.equal(result.batteryCount, 2);
    assert.equal(result.level, 67);
    approx(result.energyFullWh, 3);
    approx(result.watts, 0.3);
    assert.equal(result.state, "discharging");
}

// A source Battery record, including an online peripheral record, never makes
// the system plugged in. Valid online USB/Mains-style sources do.
{
    const battery = {
        scope: "System", capacity: 50, status: "Discharging",
        energyNowUwh: 500000, energyFullUwh: 1000000, powerUw: 200000
    };
    assert.equal(logic.aggregateBatteryRecords([battery], [
        { type: "Battery", scope: "Device", online: true }
    ]).plugged, false);
    const plugged = logic.aggregateBatteryRecords([battery], [
        { type: "Mains", scope: "System", online: true }
    ]);
    // Battery status wins over source state: an active discharge remains c=0.
    assert.equal(plugged.state, "discharging");
    assert.equal(plugged.sampleCode, 0);
    assert.equal(plugged.plugged, false);
}

// Charging with no positive draw is normalized to plugged-idle; actual draw
// is charging. This keeps icon, status, ETA, and sample state aligned.
{
    const base = { scope: "System", capacity: 80, energyNowUwh: 800000,
        energyFullUwh: 1000000, powerUw: 0 };
    assert.equal(logic.aggregateBatteryRecords([
        { ...base, status: "Charging" }
    ], [{ type: "Mains", scope: "System", online: true }]).state, "plugged");
    assert.equal(logic.aggregateBatteryRecords([
        { ...base, status: "Charging", powerUw: 500000 }
    ], [{ type: "Mains", scope: "System", online: true }]).state, "charging");
}

// Delimited output is the exact production command format, including an
// ENERGY_* battery and a filtered Device battery.
{
    const output = [
        "B\tSystem\t80\tNot charging\t\t1000\t10000000\t800000\t1000000\t1200000\t\t\t\t80",
        "B\tDevice\t100\tDischarging\t100000\t\t3000000\t\t\t\t\t\t\t",
        "S\tBattery\tDevice\t1",
        "S\tUSB\tSystem\t1"
    ].join("\n");
    const result = logic.aggregateDelimitedOutput(output);
    assert.equal(result.batteryCount, 1);
    assert.equal(result.state, "plugged");
    approx(result.energyNowWh, 0.8);
}

// A plugged boundary includes the final discharge interval through the actual
// boundary timestamp, rather than freezing at the previous sample.
{
    const samples = [
        { t: 0, v: 80, c: 2, w: 0 },
        { t: 60, v: 79, c: 0, w: 10 },
        { t: 120, v: 78, c: 0, w: 8 },
        { t: 180, v: 78, c: 2, w: 0 }
    ];
    const stats = logic.computeStats(samples, 180, 86400, 150, 50);
    assert.equal(stats.sessionAvailable, true);
    assert.equal(stats.elapsedSeconds, 120);
    assert.equal(stats.activeSeconds, 120);
    assert.equal(stats.startT, 60);
    assert.equal(stats.endT, 180);
    assert.equal(stats.endPct, 78);
    assert.equal(stats.completedBoundary, true);
    approx(stats.activeWh, (10 * 60 + 8 * 60) / 3600);
    assert.equal(stats.activePct, 1);
}

// A one-interval discharge must include the drop visible only at plug-in.
{
    const stats = logic.computeStats([
        { t: 0, v: 80, c: 2, w: 0 },
        { t: 60, v: 79, c: 0, w: 10 },
        { t: 120, v: 78, c: 2, w: 0 }
    ], 120, 86400, 150, 50);
    assert.equal(stats.activeSeconds, 60);
    assert.equal(stats.activePct, 1);
    approx(stats.activeWh, 10 / 60);
}

// A live discharge session exposes reliable timestamps and end level but is
// not eligible for a durable snapshot until a plugged/charging boundary.
{
    const stats = logic.computeStats([
        { t: 0, v: 80, c: 0, w: 10 },
        { t: 60, v: 79, c: 0, w: 10 },
        { t: 120, v: 78, c: 0, w: 10 }
    ], 120, 86400, 150, 50);
    assert.equal(stats.startT, 0);
    assert.equal(stats.endT, 120);
    assert.equal(stats.endPct, 78);
    assert.equal(stats.completedBoundary, false);
    assert.equal(logic.snapshotFromStats(stats), null);
}

// Multiple active intervals are accumulated once per continuous run, not
// double-counted at each intermediate sample.
{
    const stats = logic.computeStats([
        { t: 0, v: 80, c: 2, w: 0 },
        { t: 60, v: 79, c: 0, w: 10 },
        { t: 120, v: 78, c: 0, w: 10 },
        { t: 180, v: 77, c: 0, w: 10 }
    ], 180, 86400, 150, 50);
    assert.equal(stats.activePct, 2);
}

// A gap over 150 seconds is suspended, and suspended Wh uses current full
// capacity (design capacity is reserved for health only).
{
    const samples = [
        { t: 0, v: 80, c: 2, w: 0 },
        { t: 60, v: 79, c: 0, w: 10 },
        { t: 240, v: 77, c: 0, w: 10 },
        { t: 300, v: 76, c: 0, w: 10 }
    ];
    const stats = logic.computeStats(samples, 300, 86400, 150, 50);
    assert.equal(stats.suspendedSeconds, 180);
    assert.equal(stats.suspendedPct, 2);
    approx(stats.suspendedWh, 1);
}

// If the first observed plugged sample follows a long gap, classify the
// unobserved interval as suspended and freeze at that confirmed boundary.
{
    const stats = logic.computeStats([
        { t: 0, v: 80, c: 2, w: 0 },
        { t: 60, v: 79, c: 0, w: 10 },
        { t: 240, v: 77, c: 2, w: 0 }
    ], 240, 86400, 150, 50);
    assert.equal(stats.elapsedSeconds, 180);
    assert.equal(stats.suspendedSeconds, 180);
    assert.equal(stats.suspendedPct, 2);
}

// Completed sessions can be persisted and restored without NaN values. The
// snapshot keeps level/time data even when watt coverage is partial.
{
    const stats = logic.computeStats([
        { t: 0, v: 80, c: 2 },
        { t: 60, v: 79, c: 0 },
        { t: 240, v: 77, c: 2 }
    ], 240, 86400, 150, 50);
    const snapshot = logic.snapshotFromStats(stats);
    assert.equal(snapshot.completedBoundary, true);
    assert.equal(snapshot.startT, 60);
    assert.equal(snapshot.endT, 240);
    assert.equal(snapshot.endPct, 77);
    assert.equal(snapshot.wattCoverageComplete, false);
    assert.equal(snapshot.activeWh, null);
    assert.equal(snapshot.suspendedWh, 1);
    assert.doesNotThrow(() => JSON.stringify(snapshot));
    const restored = logic.normalizeLastSession(JSON.parse(JSON.stringify(snapshot)));
    assert.deepEqual(restored, snapshot);
}

// A completed direct boundary with legacy/missing watt samples still retains
// level/time/drop data, while all measured energy/rate fields stay null.
{
    const stats = logic.computeStats([
        { t: 0, v: 80, c: 2 },
        { t: 60, v: 79, c: 0 },
        { t: 120, v: 78, c: 2, w: 0 }
    ], 120, 86400, 150, 50);
    const snapshot = logic.snapshotFromStats(stats);
    assert.equal(snapshot.activeSeconds, 60);
    assert.equal(snapshot.activePct, 1);
    assert.equal(snapshot.activeWh, null);
    assert.equal(snapshot.minWatts, null);
    assert.equal(snapshot.wattCoverageComplete, false);
}

// Malformed snapshots are rejected; a newer completed session replaces an
// older one, while duplicate/older boundaries retain the existing snapshot.
{
    const stats = logic.computeStats([
        { t: 100, v: 90, c: 2, w: 0 },
        { t: 160, v: 89, c: 0, w: 10 },
        { t: 220, v: 88, c: 2, w: 0 }
    ], 220, 86400, 150, 50);
    const snapshot = logic.snapshotFromStats(stats);
    assert.equal(snapshot.wattCoverageComplete, true);
    assert.deepEqual(logic.normalizeLastSession(snapshot), snapshot);
    assert.equal(
        logic.normalizeLastSession({ ...snapshot, elapsedSeconds: snapshot.elapsedSeconds + 1 })
            .elapsedSeconds,
        snapshot.elapsedSeconds + 1
    );
    assert.equal(logic.normalizeLastSession({
        ...snapshot, elapsedSeconds: snapshot.elapsedSeconds + 2
    }), null);
    assert.equal(logic.normalizeLastSession({ ...snapshot, activeWh: null }), null);
    assert.equal(logic.normalizeLastSession({ ...snapshot, minWatts: 20, avgWatts: 10 }), null);
    assert.equal(logic.normalizeLastSession({ ...snapshot, avgWatts: 20, maxWatts: 10 }), null);
    assert.equal(logic.normalizeLastSession({ ...snapshot, endT: "bad" }), null);
    assert.equal(logic.shouldReplaceLastSession(null, snapshot), true);
    assert.equal(logic.shouldReplaceLastSession(snapshot, logic.snapshotFromStats({
        sessionAvailable: true,
        hasIntervals: false,
        completedBoundary: false
    })), false);
    assert.equal(logic.shouldReplaceLastSession(snapshot, snapshot), false);
    assert.equal(logic.shouldReplaceLastSession({ ...snapshot, endT: snapshot.endT + 1 }, snapshot), false);
    assert.equal(logic.shouldReplaceLastSession(snapshot, { ...snapshot, endT: snapshot.endT + 1 }), true);
}

// Legacy samples without `w` cannot be integrated across. The conservative
// policy reports measured Wh/rate unavailable rather than mixing old/new data.
{
    const stats = logic.computeStats([
        { t: 0, v: 80, c: 2 },
        { t: 60, v: 79, c: 0 },
        { t: 120, v: 78, c: 0, w: 10 }
    ], 120, 86400, 150, 50);
    assert.equal(stats.sessionAvailable, true);
    assert.equal(stats.activeSeconds, 60);
    assert.ok(Number.isNaN(stats.activeWh));
    assert.ok(Number.isNaN(stats.avgWatts));
}

// No discharge session is unavailable, never a fabricated all-zero session.
{
    const stats = logic.computeStats([
        { t: 0, v: 80, c: 2, w: 0 },
        { t: 60, v: 80, c: 2, w: 0 }
    ], 60, 86400, 150, 50);
    assert.equal(stats.sessionAvailable, false);
    assert.ok(Number.isNaN(stats.activeWh));
    assert.ok(Number.isNaN(stats.activePct));
    assert.ok(Number.isNaN(stats.elapsedSeconds));
}

console.log("PowerStatusLogic regression tests passed");
