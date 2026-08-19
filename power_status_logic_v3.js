// Pure data and statistics helpers shared by the widget and the Node fixtures.
// The QML component owns the sysfs command and timers; this module keeps the
// unit conversion, state normalization, and session math deterministic.
//
// This is resource/cache generation v3. If an exported API or behavior changes,
// bump the filename generation and update every QML, test, and documentation
// reference so DMS hot reload cannot retain an older shared-library URL.

.pragma library

var GAP_SECONDS = 150;
var SESSION_SNAPSHOT_SCHEMA = 1;

function finiteNumber(value) {
    var number = typeof value === "number" ? value : Number(value);
    return isFinite(number) ? number : NaN;
}

function nonNegative(value) {
    var number = finiteNumber(value);
    return isFinite(number) && number >= 0 ? number : NaN;
}

function positive(value) {
    var number = finiteNumber(value);
    return isFinite(number) && number > 0 ? number : NaN;
}

function clamp(value, low, high) {
    return Math.max(low, Math.min(high, value));
}

function text(value) {
    return value === undefined || value === null ? "" : String(value).trim();
}

function lower(value) {
    return text(value).toLowerCase();
}

function convertChargeToEnergy(chargeUah, voltageUv) {
    var charge = nonNegative(chargeUah);
    var voltage = positive(voltageUv);
    if (!isFinite(charge) || !isFinite(voltage))
        return NaN;
    // µAh × µV / 1,000,000 = µWh.
    return charge * voltage / 1000000;
}

function convertCurrentToPower(currentUa, voltageUv) {
    var current = nonNegative(Math.abs(finiteNumber(currentUa)));
    var voltage = positive(voltageUv);
    if (!isFinite(current) || !isFinite(voltage))
        return NaN;
    // µA × µV / 1,000,000 = µW.
    return current * voltage / 1000000;
}

function formatPowerWatts(watts, hideBelowTenth) {
    if (watts === undefined || watts === null)
        return "";
    var value = nonNegative(watts);
    if (!isFinite(value) || (hideBelowTenth === true && value < 0.1))
        return "";
    // Round half-up in tenths instead of relying on toFixed's binary-float
    // edge behavior. The zsh prompt applies the same contract in integer µW.
    var tenths = Math.floor(value * 10 + 0.5);
    return Math.floor(tenths / 10) + "." + (tenths % 10) + "W";
}

function parseNumber(value) {
    var s = text(value);
    return s.length === 0 ? NaN : finiteNumber(s);
}

function parseDelimitedOutput(output) {
    var batteries = [];
    var sources = [];
    var lines = text(output).split("\n");
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].replace(/\r$/, "");
        if (!line)
            continue;
        var fields = line.split("\t");
        if (fields[0] === "B") {
            batteries.push({
                scope: fields[1],
                capacity: parseNumber(fields[2]),
                status: fields[3],
                powerUw: parseNumber(fields[4]),
                currentUa: parseNumber(fields[5]),
                voltageUv: parseNumber(fields[6]),
                energyNowUwh: parseNumber(fields[7]),
                energyFullUwh: parseNumber(fields[8]),
                energyDesignUwh: parseNumber(fields[9]),
                chargeNowUah: parseNumber(fields[10]),
                chargeFullUah: parseNumber(fields[11]),
                chargeDesignUah: parseNumber(fields[12]),
                limit: parseNumber(fields[13])
            });
        } else if (fields[0] === "S") {
            sources.push({
                type: fields[1],
                scope: fields[2],
                online: fields[3] === "1" || lower(fields[3]) === "true"
            });
        }
    }
    return { batteries: batteries, sources: sources };
}

function isUsableSource(source) {
    if (!source || lower(source.scope) === "device")
        return false;
    var type = lower(source.type);
    if (type === "battery" || !source.online)
        return false;
    // Linux exposes AC, USB-C, wireless, and vendor-specific mains supplies.
    // Any non-battery system-scope source with an online attribute is useful;
    // scope=Device remains excluded above so HID/peripheral sources cannot make
    // the laptop appear plugged in.
    return true;
}

function normalizeBattery(record) {
    if (!record || lower(record.scope) === "device")
        return null;

    var capacity = finiteNumber(record.capacity);
    if (!isFinite(capacity) || capacity < 0 || capacity > 100)
        return null;

    var voltageUv = positive(record.voltageUv !== undefined ? record.voltageUv : record.voltage);
    var now = nonNegative(record.energyNowUwh !== undefined ? record.energyNowUwh : record.energyNow);
    var full = positive(record.energyFullUwh !== undefined ? record.energyFullUwh : record.energyFull);
    var design = positive(record.energyDesignUwh !== undefined ? record.energyDesignUwh : record.energyDesign);

    if (!isFinite(now)) {
        var chargeNow = record.chargeNowUah !== undefined ? record.chargeNowUah : record.chargeNow;
        now = convertChargeToEnergy(chargeNow, voltageUv);
    }
    if (!isFinite(full)) {
        var chargeFull = record.chargeFullUah !== undefined ? record.chargeFullUah : record.chargeFull;
        full = convertChargeToEnergy(chargeFull, voltageUv);
    }
    if (!isFinite(design)) {
        var chargeDesign = record.chargeDesignUah !== undefined ? record.chargeDesignUah : record.chargeDesign;
        design = convertChargeToEnergy(chargeDesign, voltageUv);
    }

    var power = nonNegative(record.powerUw !== undefined ? record.powerUw : record.power);
    if (!isFinite(power)) {
        var current = record.currentUa !== undefined ? record.currentUa : record.current;
        power = convertCurrentToPower(current, voltageUv);
    }

    var status = text(record.status);
    var limit = finiteNumber(record.limit);
    if (!isFinite(limit) || limit <= 0 || limit > 100)
        limit = NaN;

    return {
        capacity: clamp(capacity, 0, 100),
        status: status,
        chargingReported: status === "Charging",
        dischargingReported: status === "Discharging",
        powerUw: power,
        energyNowUwh: now,
        energyFullUwh: full,
        energyDesignUwh: design,
        limit: limit
    };
}

function aggregateBatteryRecords(records, sources) {
    var batteries = [];
    var input = Array.isArray(records) ? records : [];
    for (var i = 0; i < input.length; i++) {
        var battery = normalizeBattery(input[i]);
        if (battery)
            batteries.push(battery);
    }

    var sourceOnline = false;
    var sourceList = Array.isArray(sources) ? sources : [];
    for (var j = 0; j < sourceList.length; j++) {
        if (isUsableSource(sourceList[j])) {
            sourceOnline = true;
            break;
        }
    }

    if (batteries.length === 0) {
        return {
            hasBattery: false,
            level: 0,
            charging: false,
            discharging: false,
            plugged: false,
            sourceOnline: sourceOnline,
            state: "none",
            sampleCode: 2,
            watts: NaN,
            energyNowWh: NaN,
            energyFullWh: NaN,
            energyFullDesignWh: NaN,
            limit: 100,
            batteryCount: 0
        };
    }

    var sumNow = 0;
    var sumFull = 0;
    var sumDesign = 0;
    var allNow = true;
    var allFull = true;
    var allDesign = true;
    var sumCapacity = 0;
    var sumPower = 0;
    var allPower = true;
    var anyCharging = false;
    var anyDischarging = false;
    var minLimit = 100;
    for (var k = 0; k < batteries.length; k++) {
        var b = batteries[k];
        if (isFinite(b.energyNowUwh))
            sumNow += b.energyNowUwh;
        else
            allNow = false;
        if (isFinite(b.energyFullUwh))
            sumFull += b.energyFullUwh;
        else
            allFull = false;
        if (isFinite(b.energyDesignUwh))
            sumDesign += b.energyDesignUwh;
        else
            allDesign = false;
        sumCapacity += b.capacity;
        if (isFinite(b.powerUw))
            sumPower += b.powerUw;
        else
            allPower = false;
        anyCharging = anyCharging || b.chargingReported;
        anyDischarging = anyDischarging || b.dischargingReported;
        if (isFinite(b.limit) && b.limit < minLimit)
            minLimit = b.limit;
    }

    var level;
    if (allNow && allFull && sumFull > 0)
        level = Math.round(clamp(sumNow / sumFull * 100, 0, 100));
    else
        level = Math.round(sumCapacity / batteries.length);

    var watts = allPower ? sumPower / 1000000 : NaN;
    // Discharging is authoritative: an online source can coexist with a
    // battery that is actively discharging (source handoff or firmware quirks).
    var charging = anyCharging && (!isFinite(watts) || watts > 0);
    var state;
    if (anyDischarging)
        state = "discharging";
    else if (charging)
        state = "charging";
    else if (sourceOnline)
        state = "plugged";
    else
        state = "discharging";

    return {
        hasBattery: true,
        level: clamp(level, 0, 100),
        charging: state === "charging",
        discharging: state === "discharging",
        // This is the effective UI state, not merely source presence. Keep an
        // online source visible separately so Discharging remains active when
        // firmware/source handoff reports both facts at once.
        plugged: state === "plugged" || state === "charging",
        sourceOnline: sourceOnline,
        state: state,
        sampleCode: state === "charging" ? 1 : (state === "discharging" ? 0 : 2),
        watts: watts,
        energyNowWh: allNow ? sumNow / 1000000 : NaN,
        energyFullWh: allFull ? sumFull / 1000000 : NaN,
        energyFullDesignWh: allDesign ? sumDesign / 1000000 : NaN,
        limit: minLimit,
        batteryCount: batteries.length
    };
}

function aggregateDelimitedOutput(output) {
    var parsed = parseDelimitedOutput(output);
    return aggregateBatteryRecords(parsed.batteries, parsed.sources);
}

function validSample(sample) {
    if (!sample)
        return false;
    var t = finiteNumber(sample.t);
    var v = finiteNumber(sample.v);
    var c = finiteNumber(sample.c);
    return isFinite(t) && isFinite(v) && v >= 0 && v <= 100
        && isFinite(c) && c >= 0 && c <= 2 && Math.floor(c) === c;
}

function validWatt(value) {
    var w = finiteNumber(value);
    return isFinite(w) && w >= 0;
}

function sortedSamples(samples, t0) {
    var result = [];
    var input = Array.isArray(samples) ? samples : [];
    for (var i = 0; i < input.length; i++) {
        if (!validSample(input[i]))
            continue;
        if (input[i].t >= t0)
            result.push({
                t: Number(input[i].t),
                v: Number(input[i].v),
                c: Number(input[i].c),
                w: validWatt(input[i].w) ? Number(input[i].w) : NaN
            });
    }
    result.sort(function(a, b) { return a.t - b.t; });
    return result;
}

function unavailableStats() {
    return {
        sessionAvailable: false,
        hasIntervals: false,
        wattCoverageComplete: false,
        completedBoundary: false,
        startT: NaN,
        endT: NaN,
        startPct: NaN,
        endPct: NaN,
        startWh: NaN,
        elapsedSeconds: NaN,
        activeSeconds: NaN,
        activeWh: NaN,
        activePct: NaN,
        suspendedSeconds: NaN,
        suspendedWh: NaN,
        suspendedPct: NaN,
        minWatts: NaN,
        avgWatts: NaN,
        maxWatts: NaN
    };
}

function computeStats(samples, now, windowSeconds, gapSeconds, currentFullWh) {
    var currentNow = finiteNumber(now);
    if (!isFinite(currentNow))
        currentNow = Math.floor(Date.now() / 1000);
    var span = finiteNumber(windowSeconds);
    if (!isFinite(span) || span <= 0)
        span = 86400;
    var gap = finiteNumber(gapSeconds);
    if (!isFinite(gap) || gap <= 0)
        gap = GAP_SECONDS;
    var fullWh = positive(currentFullWh);
    var pts = sortedSamples(samples, currentNow - span - 3600);

    var startIdx = -1;
    for (var i = 1; i < pts.length; i++) {
        var p = pts[i - 1];
        var c = pts[i];
        if (p.c !== 0 && c.c === 0)
            startIdx = i;
        else if (p.c === 0 && c.c === 0 && c.t - p.t > gap && c.v > p.v + 1)
            startIdx = i;
    }
    var last = pts.length > 0 ? pts[pts.length - 1] : null;
    if (startIdx < 0 && last && last.c === 0)
        startIdx = 0;
    if (startIdx < 0)
        return unavailableStats();

    var start = pts[startIdx];
    var result = unavailableStats();
    result.sessionAvailable = true;
    result.startT = start.t;
    result.startPct = start.v;
    result.endPct = start.v;
    result.startWh = isFinite(fullWh) ? start.v / 100 * fullWh : NaN;

    var activeS = 0;
    var suspendedS = 0;
    var activePct = 0;
    var suspendedPct = 0;
    var suspendedWh = 0;
    var activeIntervals = 0;
    var suspendedIntervals = 0;
    var wattComplete = true;
    var wattIntervals = 0;
    var sumWt = 0;
    var sumDt = 0;
    var minW = Infinity;
    var maxW = -Infinity;
    var runStartV = start.v;
    var runLastV = start.v;
    var runHasInterval = false;
    var endT = NaN;

    function closeActiveRun(endV) {
        if (runHasInterval)
            activePct += Math.max(0, runStartV - runLastV);
        runStartV = endV;
        runLastV = endV;
        runHasInterval = false;
    }

    for (var j = startIdx + 1; j < pts.length; j++) {
        var a = pts[j - 1];
        var b = pts[j];
        var dt = b.t - a.t;
        if (!isFinite(dt) || dt <= 0)
            continue;

        if (b.c !== 0) {
            // A direct state transition gives us the actual plug boundary.
            // Count the last discharge interval up to b.t, but only with the
            // last confirmed discharge watt sample; b is already plugged.
            if (a.c === 0 && dt <= gap) {
                activeS += dt;
                activeIntervals++;
                endT = b.t;
                result.completedBoundary = true;
                result.endPct = b.v;
                if (validWatt(a.w)) {
                    wattIntervals++;
                    sumWt += a.w * dt;
                    sumDt += dt;
                    minW = Math.min(minW, a.w);
                    maxW = Math.max(maxW, a.w);
                } else {
                    wattComplete = false;
                }
                // Include the level observed at the plugged boundary. The
                // first discharge sample may have no preceding active run, so
                // mark this direct interval before closing it.
                if (!runHasInterval) {
                    runStartV = a.v;
                    runHasInterval = true;
                }
                runLastV = b.v;
                closeActiveRun(b.v);
            } else if (a.c === 0 && dt > gap) {
                // The first plugged sample follows a recording gap. We cannot
                // know when inside the gap the plug happened, so classify the
                // whole unobserved interval as suspended and freeze at b.t,
                // the first confirmed boundary timestamp.
                closeActiveRun(a.v);
                suspendedS += dt;
                suspendedIntervals++;
                endT = b.t;
                result.completedBoundary = true;
                result.endPct = b.v;
                var boundaryDrop = Math.max(0, a.v - b.v);
                suspendedPct += boundaryDrop;
                if (isFinite(fullWh))
                    suspendedWh += boundaryDrop / 100 * fullWh;
            } else {
                closeActiveRun(a.v);
                endT = a.t;
            }
            break;
        }

        if (dt > gap) {
            closeActiveRun(a.v);
            suspendedS += dt;
            suspendedIntervals++;
            endT = b.t;
            result.endPct = b.v;
            var drop = Math.max(0, a.v - b.v);
            suspendedPct += drop;
            if (isFinite(fullWh))
                suspendedWh += drop / 100 * fullWh;
            runStartV = b.v;
            continue;
        }

        activeS += dt;
        activeIntervals++;
        endT = b.t;
        result.endPct = b.v;
        if (!runHasInterval) {
            runStartV = a.v;
            runHasInterval = true;
        }
        runLastV = b.v;

        // Conservative coverage policy: both endpoints must carry watt data.
        // This prevents a legacy sample without `w` from being integrated with
        // a newer sample merely because the newer side has a reading.
        if (validWatt(a.w) && validWatt(b.w)) {
            wattIntervals++;
            // The reading at a is the confirmed draw for the interval ending
            // at b. The b endpoint is required only to prove continuous
            // coverage; using a avoids assigning the plugged boundary's
            // (usually zero) rate to the preceding discharge interval.
            sumWt += a.w * dt;
            sumDt += dt;
            minW = Math.min(minW, a.w);
            maxW = Math.max(maxW, a.w);
        } else {
            wattComplete = false;
        }
    }

    if (runHasInterval && pts.length > startIdx + 1) {
        var finalPoint = pts[pts.length - 1];
        if (finalPoint.c === 0) {
            closeActiveRun(finalPoint.v);
            result.endPct = finalPoint.v;
        }
    }

    result.hasIntervals = activeIntervals > 0 || suspendedIntervals > 0;
    result.wattCoverageComplete = wattComplete && wattIntervals > 0;
    result.elapsedSeconds = result.hasIntervals && isFinite(endT) ? Math.max(0, endT - start.t) : NaN;
    result.endT = isFinite(endT) ? endT : NaN;
    result.activeSeconds = activeIntervals > 0 ? activeS : NaN;
    result.activePct = activeIntervals > 0 ? activePct : NaN;
    result.suspendedSeconds = suspendedIntervals > 0 ? suspendedS : NaN;
    result.suspendedPct = suspendedIntervals > 0 ? suspendedPct : NaN;
    result.suspendedWh = suspendedIntervals > 0 && isFinite(fullWh) ? suspendedWh : NaN;
    if (result.wattCoverageComplete) {
        result.activeWh = activeS > 0 ? sumWt / 3600 : NaN;
        result.minWatts = minW;
        result.avgWatts = sumDt > 0 ? sumWt / sumDt : NaN;
        result.maxWatts = maxW;
    }
    return result;
}

function jsonNumber(value) {
    var number = finiteNumber(value);
    return isFinite(number) ? number : null;
}

function snapshotFromStats(stats) {
    if (!stats || stats.sessionAvailable !== true || stats.hasIntervals !== true
            || stats.completedBoundary !== true)
        return null;

    var startT = finiteNumber(stats.startT);
    var endT = finiteNumber(stats.endT);
    var startPct = finiteNumber(stats.startPct);
    var endPct = finiteNumber(stats.endPct);
    var elapsed = finiteNumber(stats.elapsedSeconds);
    if (!isFinite(startT) || !isFinite(endT) || endT < startT
            || !isFinite(startPct) || startPct < 0 || startPct > 100
            || !isFinite(endPct) || endPct < 0 || endPct > 100
            || !isFinite(elapsed) || elapsed < 0)
        return null;

    return {
        schema: SESSION_SNAPSHOT_SCHEMA,
        sessionAvailable: true,
        hasIntervals: true,
        completedBoundary: true,
        wattCoverageComplete: stats.wattCoverageComplete === true,
        startT: startT,
        endT: endT,
        startPct: startPct,
        endPct: endPct,
        startWh: jsonNumber(stats.startWh),
        elapsedSeconds: elapsed,
        activeSeconds: jsonNumber(stats.activeSeconds),
        activeWh: jsonNumber(stats.activeWh),
        activePct: jsonNumber(stats.activePct),
        suspendedSeconds: jsonNumber(stats.suspendedSeconds),
        suspendedWh: jsonNumber(stats.suspendedWh),
        suspendedPct: jsonNumber(stats.suspendedPct),
        minWatts: jsonNumber(stats.minWatts),
        avgWatts: jsonNumber(stats.avgWatts),
        maxWatts: jsonNumber(stats.maxWatts)
    };
}

function optionalSnapshotNumber(value, low, high) {
    if (value === null || value === undefined)
        return null;
    var number = finiteNumber(value);
    if (!isFinite(number) || (low !== undefined && number < low)
            || (high !== undefined && number > high))
        return NaN;
    return number;
}

function normalizeLastSession(value) {
    if (!value || typeof value !== "object"
            || Number(value.schema) !== SESSION_SNAPSHOT_SCHEMA
            || value.sessionAvailable !== true
            || value.hasIntervals !== true
            || value.completedBoundary !== true
            || typeof value.wattCoverageComplete !== "boolean")
        return null;

    var startT = optionalSnapshotNumber(value.startT, 0);
    var endT = optionalSnapshotNumber(value.endT, 0);
    var startPct = optionalSnapshotNumber(value.startPct, 0, 100);
    var endPct = optionalSnapshotNumber(value.endPct, 0, 100);
    var elapsed = optionalSnapshotNumber(value.elapsedSeconds, 0);
    if (startT === null || endT === null || startPct === null || endPct === null
            || elapsed === null || !isFinite(startT) || !isFinite(endT) || endT < startT
            || !isFinite(startPct) || !isFinite(endPct) || !isFinite(elapsed))
        return null;
    if (Math.abs(elapsed - (endT - startT)) > 1)
        return null;

    var fields = [
        "startWh", "activeSeconds", "activeWh", "activePct",
        "suspendedSeconds", "suspendedWh", "suspendedPct",
        "minWatts", "avgWatts", "maxWatts"
    ];
    var normalized = {
        schema: SESSION_SNAPSHOT_SCHEMA,
        sessionAvailable: true,
        hasIntervals: true,
        completedBoundary: true,
        wattCoverageComplete: value.wattCoverageComplete === true,
        startT: startT,
        endT: endT,
        startPct: startPct,
        endPct: endPct,
        elapsedSeconds: elapsed
    };
    for (var i = 0; i < fields.length; i++) {
        var field = fields[i];
        var number = optionalSnapshotNumber(value[field], 0);
        if (!isFinite(number) && number !== null)
            return null;
        if ((field === "activePct" || field === "suspendedPct")
                && number !== null && number > 100)
            return null;
        normalized[field] = number;
    }
    if (normalized.wattCoverageComplete) {
        if (normalized.activeWh === null || normalized.minWatts === null
                || normalized.avgWatts === null || normalized.maxWatts === null
                || !isFinite(normalized.activeWh)
                || !isFinite(normalized.minWatts)
                || !isFinite(normalized.avgWatts)
                || !isFinite(normalized.maxWatts)
                || normalized.minWatts > normalized.avgWatts
                || normalized.avgWatts > normalized.maxWatts)
            return null;
    }
    return normalized;
}

function shouldReplaceLastSession(existing, candidate) {
    var next = normalizeLastSession(candidate);
    if (!next)
        return false;
    var prior = normalizeLastSession(existing);
    return !prior || next.endT > prior.endT;
}

function sampleCodeForState(state) {
    if (state === "charging" || state === 1)
        return 1;
    if (state === "discharging" || state === 0)
        return 0;
    return 2;
}

var api = {
    GAP_SECONDS: GAP_SECONDS,
    SESSION_SNAPSHOT_SCHEMA: SESSION_SNAPSHOT_SCHEMA,
    convertChargeToEnergy: convertChargeToEnergy,
    convertCurrentToPower: convertCurrentToPower,
    formatPowerWatts: formatPowerWatts,
    parseDelimitedOutput: parseDelimitedOutput,
    aggregateBatteryRecords: aggregateBatteryRecords,
    aggregateDelimitedOutput: aggregateDelimitedOutput,
    normalizeBattery: normalizeBattery,
    isUsableSource: isUsableSource,
    computeStats: computeStats,
    snapshotFromStats: snapshotFromStats,
    normalizeLastSession: normalizeLastSession,
    shouldReplaceLastSession: shouldReplaceLastSession,
    sampleCodeForState: sampleCodeForState,
    validSample: validSample
};

// QML imports function declarations directly. Node uses the same production
// module through CommonJS for regression tests.
if (typeof module !== "undefined")
    module.exports = api;
