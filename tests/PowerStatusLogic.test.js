const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// Compile the exact QML production resource. Node does not understand
// `.pragma library`, so remove only that one directive in the VM copy; all
// production code remains byte-for-byte identical and is still syntax-checked.
const logicPath = path.join(__dirname, "..", "power_status_logic.js");
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
