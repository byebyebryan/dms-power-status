import QtQuick
import Quickshell
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

PluginComponent {
    id: root

    layerNamespacePlugin: "power-status"
    visible: hasBattery

    // ── Direct sysfs data source (mirrors the zsh battery prompt) ──
    // We read the battery straight from /sys/class/power_supply instead of
    // going through DMS's BatteryService. Reasons:
    //   - The charge limit lives in firmware/sysfs (charge_control_end_threshold);
    //     DMS's SettingsData.batteryChargeLimit never reconciles to it.
    //   - One source of truth for level, rate, AC state, and limit.
    // Values are held (last-good) so a transient empty/0 read on plug/unplug
    // never blanks the pill — we keep the previous valid value instead.

    readonly property string pid: "powerStatus"
    readonly property int windowSeconds: 24 * 3600
    readonly property int gapS: 1200
    readonly property string _refreshProcId: "powerStatus.refresh." + Math.random().toString(36).slice(2)

    property var samples: []
    property bool _reading: false
    property int _noBatteryStreak: 0

    function loadSamples() {
        if (!pluginService || !pluginId)
            return;
        const saved = pluginService.loadPluginState(pluginId, "samples", []);
        if (Array.isArray(saved) && saved.length > 0) {
            samples = saved;
            pruneSamples();
        }
    }

    function pruneSamples() {
        const t0 = Math.floor(Date.now() / 1000) - windowSeconds - 3600;
        let i = 0;
        while (i < samples.length && samples[i].t < t0)
            i++;
        if (i > 0)
            samples = samples.slice(i);
    }

    function saveSamples() {
        if (!pluginService || !pluginId)
            return;
        pruneSamples();
        pluginService.savePluginState(pluginId, "samples", samples);
    }

    // held (last-good) state
    property bool _heldHasBattery: false
    property int _heldLevel: 0
    property bool _heldCharging: false
    property bool _heldPlugged: false
    property real _heldWatts: 0
    property real _heldEnergyNow: 0
    property real _heldEnergyFull: 0
    property real _heldEnergyFullDesign: 0
    property int _heldLimit: 100

    // state-changed flags so we sample at boundaries
    property bool _prevCharging: false
    property bool _prevPlugged: false

    function parseOutput(out) {
        const kv = {};
        for (const line of (out || "").split("\n")) {
            const eq = line.indexOf("=");
            if (eq < 0)
                continue;
            kv[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
        }

        const found = kv["FOUND"];
        if (found === "0" || found === undefined) {
            _noBatteryStreak++;
            if (_noBatteryStreak >= 3)
                _heldHasBattery = false;
            return;
        }
        _noBatteryStreak = 0;
        _heldHasBattery = true;

        // Only commit a field when this read is valid; otherwise keep last-good.
        const cap = parseInt(kv["CAP"], 10);
        if (!isNaN(cap) && cap >= 0)
            _heldLevel = Math.min(100, Math.max(0, cap));

        const st = kv["STATUS"];
        if (st === "Charging")
            _heldCharging = true;
        else if (st === "Discharging" || st === "Not charging" || st === "Full")
            _heldCharging = false;
        // st empty/Unknown/PendingCharge -> keep last-good

        const ac = kv["AC"];
        if (ac === "1")
            _heldPlugged = true;
        else if (ac === "0")
            _heldPlugged = false;

        // power_now is µW; fall back to current × voltage like the prompt.
        let p = parseInt(kv["POWER"], 10);
        if (isNaN(p) || p < 0) {
            const c = parseInt(kv["CUR"], 10);
            const v = parseInt(kv["VOLT"], 10);
            p = (!isNaN(c) && !isNaN(v)) ? Math.floor(c * v / 1000000) : NaN;
        }
        if (!isNaN(p) && p >= 0)
            _heldWatts = p / 1000000; // W

        // energy_* are µWh.
        const en = parseInt(kv["ENERGY_NOW"], 10);
        if (!isNaN(en) && en >= 0)
            _heldEnergyNow = en / 1000000; // Wh
        const ef = parseInt(kv["ENERGY_FULL"], 10);
        if (!isNaN(ef) && ef > 0)
            _heldEnergyFull = ef / 1000000; // Wh

        const efd = parseInt(kv["ENERGY_FULL_DESIGN"], 10);
        if (!isNaN(efd) && efd > 0)
            _heldEnergyFullDesign = efd / 1000000; // Wh

        const lim = parseInt(kv["LIMIT"], 10);
        if (!isNaN(lim) && lim > 0 && lim <= 100)
            _heldLimit = lim;

        // Sample at plug/charging boundaries so the graph flips immediately,
        // and reset the rate EMA so a transient can't seed it.
        if (_heldCharging !== _prevCharging || _heldPlugged !== _prevPlugged) {
            _prevCharging = _heldCharging;
            _prevPlugged = _heldPlugged;
            root._resetSmoothedRate();
            root.sample();
        }
        root.updateSmoothedRate();
    }

    function refresh() {
        if (_reading)
            return;
        _reading = true;
        const cmd = `
ac=0
found=0
for s in /sys/class/power_supply/*; do
  [ -d "$s" ] || continue
  t=$(cat "$s/type" 2>/dev/null) || continue
  [ "$t" = "Battery" ] || continue
  found=1
  cap=$(cat "$s/capacity" 2>/dev/null)
  st=$(cat "$s/status" 2>/dev/null)
  p=$(cat "$s/power_now" 2>/dev/null)
  c=$(cat "$s/current_now" 2>/dev/null)
  v=$(cat "$s/voltage_now" 2>/dev/null)
  en=$(cat "$s/energy_now" 2>/dev/null)
  ef=$(cat "$s/energy_full" 2>/dev/null)
  efd=$(cat "$s/energy_full_design" 2>/dev/null)
  if [ -z "$efd" ]; then efd=$(cat "$s/charge_full_design" 2>/dev/null); fi
  lim=$(cat "$s/charge_control_end_threshold" 2>/dev/null)
  if [ -z "$lim" ]; then lim=$(cat "$s/charge_control_limit" 2>/dev/null); fi
  if [ -z "$lim" ]; then lim=$(cat "$s/charge_stop_threshold" 2>/dev/null); fi
  echo "CAP=$cap"
  echo "STATUS=$st"
  echo "POWER=$p"
  echo "CUR=$c"
  echo "VOLT=$v"
  echo "ENERGY_NOW=$en"
  echo "ENERGY_FULL=$ef"
  echo "ENERGY_FULL_DESIGN=$efd"
  echo "LIMIT=$lim"
  break
done
for s in /sys/class/power_supply/*; do
  [ -f "$s/online" ] || continue
  o=$(cat "$s/online" 2>/dev/null)
  [ "$o" = "1" ] && ac=1 && break
done
echo "FOUND=$found"
echo "AC=$ac"`;
        Proc.runCommand(_refreshProcId, ["sh", "-c", cmd], (stdout, exit) => {
            _reading = false;
            if (root === null)
                return;
            root.parseOutput(stdout);
        }, 500);
    }

    Timer {
        id: refreshTimer
        // Poll fast while a battery is present; fall back to a slow probe so a
        // hotplugged battery is still detected without burning a sh every 5s on
        // battery-less desktops.
        interval: _heldHasBattery ? 5000 : 60000
        repeat: true
        running: true
        onTriggered: root.refresh()
    }

    function sampleState() {
        // Mirrors DMS batteryStatus: charging requires an actual power draw.
        // A plugged-in battery at its charge limit has changeRate <= 0 and is
        // idle, not charging.
        if (_heldCharging && _heldWatts > 0)
            return 1;
        if (!_heldPlugged)
            return 0;
        return 2;
    }

    function sample() {
        if (!_heldHasBattery)
            return;
        const t = Math.floor(Date.now() / 1000);
        const last = samples.length > 0 ? samples[samples.length - 1] : null;
        if (last && t - last.t < 5)
            return;
        samples = samples.concat([{
            "t": t,
            "v": _heldLevel,
            "c": sampleState(),
            "w": _heldWatts
        }]);
        saveSamples();
    }

    Timer {
        interval: 60000
        repeat: true
        running: _heldHasBattery
        onTriggered: root.sample()
    }

    // Time-weighted EMA of the change rate (30s half-life) so the ETA stays
    // stable but converges quickly after plug/unplug. Applies to both charging
    // and discharging. On a plug or charging-state transition the EMA and seed
    // window reset so a transient low power read can't spike the ETA.
    property real _smoothedRate: 0
    property real _lastRateSampleTime: 0
    property var _rateSeedWindow: []

    function _resetSmoothedRate() {
        _smoothedRate = 0;
        _lastRateSampleTime = 0;
        _rateSeedWindow = [];
    }

    function updateSmoothedRate() {
        const w = _heldWatts;
        if (!_heldHasBattery || w <= 0) {
            _smoothedRate = 0;
            _lastRateSampleTime = 0;
            return;
        }
        // Warm-up: collect the first two readings after a transition. Seed the
        // EMA from the higher of them so a transient dip can't dominate.
        if (_rateSeedWindow.length < 2) {
            _rateSeedWindow = _rateSeedWindow.concat([w]);
            return;
        }
        if (_smoothedRate <= 0 || _lastRateSampleTime <= 0) {
            _smoothedRate = Math.max(_rateSeedWindow[0], _rateSeedWindow[1]);
            _lastRateSampleTime = Date.now();
            return;
        }
        const now = Date.now();
        const dt = (now - _lastRateSampleTime) / 1000;
        _lastRateSampleTime = now;
        if (dt <= 0)
            return;
        const tau = 30 / Math.LN2;
        const alpha = 1 - Math.exp(-dt / tau);
        _smoothedRate += alpha * (w - _smoothedRate);
    }

    function rateIsSettled() {
        return _smoothedRate > 0 && _rateSeedWindow.length >= 2;
    }

    onPluginServiceChanged: root.loadSamples()
    onPluginIdChanged: root.loadSamples()
    Component.onCompleted: {
        root.loadSamples();
        root.refresh();
        root.sample();
    }

    // ── Derived state ──

    readonly property bool hasBattery: _heldHasBattery
    readonly property int batteryPercent: _heldLevel
    readonly property bool isCharging: _heldCharging
    readonly property bool isPluggedIn: _heldPlugged
    readonly property real powerWatts: _heldWatts
    readonly property bool hasUsefulPower: powerWatts >= 0.1
    readonly property bool showDynamicStatus: hasBattery && hasUsefulPower && (isCharging || !isPluggedIn)
    readonly property string wattsText: showDynamicStatus ? formatWatts(powerWatts) : ""
    readonly property string etaText: {
        if (!showDynamicStatus) {
            return "";
        }
        return formatEta();
    }
    readonly property string percentText: hasBattery ? `${batteryPercent}%` : ""
    readonly property color statusColor: {
        if (!hasBattery) {
            return Theme.widgetIconColor;
        }
        if (batteryPercent <= SettingsData.batteryLowThreshold && !isCharging && !isPluggedIn) {
            return Theme.error;
        }
        if (isCharging || isPluggedIn) {
            return Theme.primary;
        }
        return Theme.widgetIconColor;
    }
    readonly property int textSize: Theme.barTextSize(barThickness, barConfig?.fontScale, barConfig?.maximizeWidgetText)

    horizontalBarPill: hasBattery ? horizontalPill : null
    verticalBarPill: hasBattery ? verticalPill : null

    function formatWatts(watts) {
        if (watts === undefined || watts === null || isNaN(watts) || watts < 0.1) {
            return "";
        }
        return watts < 10 ? `${watts.toFixed(1)}W` : `${watts.toFixed(0)}W`;
    }

    // Charge-limit-aware ETA. DMS's formatTimeRemaining() ignores the charge
    // limit and always targets full capacity, so while charging toward a limit
    // (e.g. 80%) it overstates time-to-full. We compute it ourselves: the
    // charge target is min(limit, 100)% of full capacity (from sysfs).
    function formatEta() {
        if (!hasBattery || !showDynamicStatus)
            return "";
        // Wait for the rate to settle after a transition so a transient low
        // reading right after unplug can't show an absurd ETA or blank (>24h).
        if (!rateIsSettled())
            return "";
        const rate = _smoothedRate;
        if (rate <= 0)
            return "";
        const capacity = _heldEnergyFull;
        const energy = _heldEnergyNow;
        if (capacity <= 0 || energy <= 0)
            return "";
        let seconds;
        if (isCharging) {
            const limit = _heldLimit > 0 ? Math.min(100, _heldLimit) : 100;
            const targetEnergy = capacity * limit / 100;
            const remaining = targetEnergy - energy;
            if (remaining <= 0)
                return "";
            seconds = remaining / rate * 3600;
        } else {
            seconds = energy / rate * 3600;
        }
        if (!seconds || seconds <= 0 || seconds > 86400)
            return "";
        const totalMinutes = Math.round(seconds / 60);
        const hours = Math.floor(totalMinutes / 60);
        const minutes = totalMinutes % 60;
        return `${hours}:${minutes.toString().padStart(2, "0")}`;
    }

    // Mirrors DMS getBatteryIcon (level + plugged/charging -> Material symbol).
    function powerIconName() {
        const level = batteryPercent;
        if (isCharging || isPluggedIn) {
            if (level >= 90) return "battery_charging_full";
            if (level >= 80) return "battery_charging_90";
            if (level >= 60) return "battery_charging_80";
            if (level >= 50) return "battery_charging_60";
            if (level >= 30) return "battery_charging_50";
            if (level >= 20) return "battery_charging_30";
            return "battery_charging_20";
        }
        if (level >= 95) return "battery_full";
        if (level >= 85) return "battery_6_bar";
        if (level >= 70) return "battery_5_bar";
        if (level >= 55) return "battery_4_bar";
        if (level >= 40) return "battery_3_bar";
        if (level >= 25) return "battery_2_bar";
        return "battery_1_bar";
    }

    function statusText() {
        if (!hasBattery)
            return "No battery";
        if (isCharging)
            return "Charging";
        if (isPluggedIn)
            return "Plugged In";
        return "Discharging";
    }

    // ── Usage stats ──
    // Session-based, from the last unplug transition to now. Consumption is
    // split at recording gaps (suspend/off):
    //   - Active: measured from regular samples — Wh from the power integral,
    //     % from the battery-level drop across each continuous active run.
    //   - Suspended: estimated, since no draw is logged during gaps — the
    //     level drop across each gap, converted to Wh against design capacity.
    // Since-unplug: starting % is the level at the unplug moment; starting
    // capacity = start% × design capacity; elapsed = time since unplug.
    // Old samples saved without "w" are skipped for the Wh math only. Battery
    // stats (design capacity, charge limit, health) come from held sysfs values.

    readonly property var stats: computeStats()

    function computeStats() {
        const now = Math.floor(Date.now() / 1000);
        const t0 = now - windowSeconds - 3600;
        const pts = [];
        for (let i = 0; i < samples.length; i++) {
            if (samples[i].t >= t0)
                pts.push(samples[i]);
        }

        // Session start = last unplug transition (last time a plugged sample
        // was followed by a discharging one). If we're discharging and no
        // transition is in the window, the unplug predates it — use window start.
        let startIdx = -1;
        for (let i = 1; i < pts.length; i++) {
            if (pts[i - 1].c !== 0 && pts[i].c === 0)
                startIdx = i;
        }
        const last = pts.length > 0 ? pts[pts.length - 1] : null;
        if (startIdx < 0 && last && last.c === 0)
            startIdx = 0;

        const designWh = _heldEnergyFullDesign;

        // Since-unplug values. Starting % is the level at the unplug moment;
        // starting capacity converts it against design capacity.
        const startPct = startIdx >= 0 ? pts[startIdx].v : NaN;
        const startT = startIdx >= 0 ? pts[startIdx].t : NaN;
        const startWh = (designWh > 0 && !isNaN(startPct))
            ? startPct / 100 * designWh : NaN;
        const elapsedS = !isNaN(startT) ? now - startT : NaN;

        // Consumption is split at recording gaps:
        //   - active: measured, regular samples
        //   - suspended: estimated from the level drop across each gap
        let activeS = 0;
        let activeWh = 0;
        let activePct = 0;
        let suspendedS = 0;
        let suspendedPct = 0;
        let suspendedWh = 0;
        let minW = Infinity;
        let maxW = -Infinity;
        let sumWt = 0;
        let sumDt = 0;

        if (startIdx >= 0) {
            let runStart = null;
            let lastActiveV = null;
            for (let i = startIdx + 1; i < pts.length; i++) {
                const a = pts[i - 1];
                const b = pts[i];
                if (b.c !== 0)
                    break;
                const dt = b.t - a.t;
                if (dt <= 0)
                    continue;
                if (dt > gapS) {
                    // suspend gap: close the active run, estimate suspended drain
                    if (runStart !== null) {
                        activePct += Math.max(0, runStart - a.v);
                        runStart = null;
                    }
                    suspendedS += dt;
                    const drop = Math.max(0, a.v - b.v);
                    suspendedPct += drop;
                    if (designWh > 0)
                        suspendedWh += drop / 100 * designWh;
                    continue;
                }
                activeS += dt;
                if (runStart === null)
                    runStart = a.v;
                lastActiveV = b.v;
                const w = b.w;
                if (typeof w === "number" && isFinite(w) && w >= 0) {
                    activeWh += w * dt / 3600;
                    if (w < minW)
                        minW = w;
                    if (w > maxW)
                        maxW = w;
                    sumWt += w * dt;
                    sumDt += dt;
                }
            }
            if (runStart !== null && lastActiveV !== null)
                activePct += Math.max(0, runStart - lastActiveV);
        }

        return {
            "startPct": startPct,
            "startWh": startWh,
            "elapsedSeconds": elapsedS,
            "activeSeconds": activeS,
            "activeWh": activeWh,
            "activePct": activePct,
            "suspendedSeconds": suspendedS,
            "suspendedWh": suspendedWh,
            "suspendedPct": suspendedPct,
            "minWatts": minW === Infinity ? NaN : minW,
            "avgWatts": sumDt > 0 ? sumWt / sumDt : NaN,
            "maxWatts": maxW === -Infinity ? NaN : maxW
        };
    }

    function formatDuration(seconds) {
        if (seconds === undefined || seconds === null || isNaN(seconds) || seconds <= 0)
            return "–";
        const totalMinutes = Math.round(seconds / 60);
        const hours = Math.floor(totalMinutes / 60);
        const minutes = totalMinutes % 60;
        return hours > 0 ? `${hours}h ${minutes}m` : `${minutes}m`;
    }

    function formatEnergyWh(wh) {
        if (wh === undefined || wh === null || isNaN(wh) || wh < 0)
            return "–";
        return wh < 10 ? wh.toFixed(1) + "Wh" : wh.toFixed(0) + "Wh";
    }

    function formatWatt(v) {
        if (v === undefined || v === null || isNaN(v) || v < 0)
            return "–";
        return v < 10 ? v.toFixed(1) + "W" : v.toFixed(0) + "W";
    }

    function formatPct(p) {
        if (p === undefined || p === null || isNaN(p) || p < 0)
            return "–";
        return Math.round(p) + "%";
    }

    function formatHealth() {
        if (_heldEnergyFullDesign <= 0 || _heldEnergyFull <= 0)
            return "–";
        return Math.round(_heldEnergyFull / _heldEnergyFullDesign * 100) + "%";
    }

    // ── Chart ──

    component BatteryChart: Item {
        id: chart

        required property var widget

        readonly property real padL: 8
        readonly property real padR: 14
        readonly property real padT: 22
        readonly property real padB: 26
        readonly property string labelFont: "10px sans-serif"
        readonly property real lineWidth: 3
        readonly property real markerRadius: 4

        readonly property color dischargeCol: Theme.primary
        readonly property color chargeCol: Theme.success
        readonly property color idleCol: Theme.surfaceVariantText
        // Muted discharge: same hue as discharge but desaturated toward the card
        // surface, used as the low-rate end of the discharge tint.
        readonly property color mutedDischargeCol: mixColor(dischargeCol, Theme.nestedSurface, 0.55)

        // Linear blend between two colors (0..1), e.g. mutedDischargeCol ->
        // dischargeCol as the discharge rate rises from the window minimum.
        function mixColor(a, b, t) {
            return Qt.rgba(
                a.r + (b.r - a.r) * t,
                a.g + (b.g - a.g) * t,
                a.b + (b.b - a.b) * t,
                1
            );
        }

        Canvas {
            id: canvas
            anchors.fill: parent
            renderStrategy: Canvas.Threaded

            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                const padL = chart.padL
                const padR = chart.padR
                const padT = chart.padT
                const padB = chart.padB
                const cw = width - padL - padR
                const ch = height - padT - padB
                if (cw <= 0 || ch <= 0)
                    return

                const now = Math.floor(Date.now() / 1000)
                const span = chart.widget.windowSeconds
                const t0 = now - span
                const X = t => padL + (t - t0) / span * cw
                const Y = v => padT + (100 - v) / 100 * ch

                const all = chart.widget.samples
                let pts = []
                for (let i = 0; i < all.length; i++) {
                    if (all[i].t >= t0 - 3600)
                        pts.push(all[i])
                }

                // Range reference for rate-based discharge tinting: min/max of
                // discharge watts in the window, so the tint spans the full
                // observed draw range.
                let dwMin = 0
                let dwMax = 0
                {
                    const dw = []
                    for (const p of pts) {
                        if (p.c === 0 && typeof p.w === "number" && isFinite(p.w) && p.w > 0)
                            dw.push(p.w)
                    }
                    if (dw.length > 0) {
                        let lo = dw[0]
                        let hi = dw[0]
                        for (const v of dw) {
                            if (v < lo) lo = v
                            if (v > hi) hi = v
                        }
                        dwMin = lo
                        dwMax = hi
                    }
                }
                const dischargeTint = w => {
                    if (dwMax <= dwMin)
                        return 1
                    if (typeof w !== "number" || !isFinite(w))
                        return 0
                    return Math.min(1, Math.max(0, (w - dwMin) / (dwMax - dwMin)))
                }

                // soft grid: hairlines with labels
                const gridColor = Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.10)
                const labelColor = Theme.withAlpha(Theme.surfaceVariantText, 0.8)
                ctx.lineWidth = 1
                ctx.strokeStyle = gridColor
                ctx.font = chart.labelFont
                ctx.fillStyle = labelColor
                ctx.textAlign = "left"
                ctx.textBaseline = "bottom"
                for (const v of [0, 50, 100]) {
                    ctx.beginPath()
                    ctx.moveTo(padL, Y(v))
                    ctx.lineTo(padL + cw, Y(v))
                    ctx.stroke()
                    ctx.fillText(v + "%", padL, Y(v) - 2)
                }

                // time ticks on round hours (6h on 24h window, 3h on 12h)
                ctx.textBaseline = "top"
                ctx.textAlign = "center"
                const stepS = chart.widget.windowSeconds >= 24 * 3600 ? 6 * 3600 : 3 * 3600
                const d0 = new Date(t0 * 1000)
                const dayStart = new Date(d0.getFullYear(), d0.getMonth(), d0.getDate()).getTime() / 1000
                for (let tick = dayStart + Math.ceil((t0 - dayStart) / stepS) * stepS; tick <= now; tick += stepS) {
                    const x = X(tick)
                    if (x < padL + 18 || x > padL + cw - 18)
                        continue
                    ctx.strokeStyle = gridColor
                    ctx.beginPath()
                    ctx.moveTo(x, padT)
                    ctx.lineTo(x, padT + ch)
                    ctx.stroke()
                    ctx.fillText(Qt.formatTime(new Date(tick * 1000), "hh:mm"), x, padT + ch + 6)
                }

                if (pts.length < 2)
                    return

                // split into runs at recording gaps
                let runs = []
                let run = [pts[0]]
                for (let i = 1; i < pts.length; i++) {
                    if (pts[i].t - pts[i - 1].t > chart.widget.gapS) {
                        runs.push(run)
                        run = []
                    }
                    run.push(pts[i])
                }
                runs.push(run)

                ctx.save()
                ctx.beginPath()
                ctx.rect(padL, padT, cw, ch)
                ctx.clip()

                const grad = ctx.createLinearGradient(0, padT, 0, padT + ch)
                grad.addColorStop(0, Qt.rgba(chart.dischargeCol.r, chart.dischargeCol.g, chart.dischargeCol.b, 0.20))
                grad.addColorStop(1, Qt.rgba(chart.dischargeCol.r, chart.dischargeCol.g, chart.dischargeCol.b, 0.0))

                function tracePath(rp) {
                    ctx.moveTo(X(rp[0].t), Y(rp[0].v))
                    if (rp.length === 2) {
                        ctx.lineTo(X(rp[1].t), Y(rp[1].v))
                        return
                    }
                    for (let i = 1; i < rp.length - 1; i++) {
                        const xc = (X(rp[i].t) + X(rp[i + 1].t)) / 2
                        const yc = (Y(rp[i].v) + Y(rp[i + 1].v)) / 2
                        ctx.quadraticCurveTo(X(rp[i].t), Y(rp[i].v), xc, yc)
                    }
                    ctx.lineTo(X(rp[rp.length - 1].t), Y(rp[rp.length - 1].v))
                }

                for (let r = 0; r < runs.length; r++) {
                    const rp = runs[r]
                    if (rp.length < 2)
                        continue

                    if (X(rp[rp.length - 1].t) - X(rp[0].t) >= 8) {
                        ctx.beginPath()
                        tracePath(rp)
                        ctx.lineTo(X(rp[rp.length - 1].t), padT + ch)
                        ctx.lineTo(X(rp[0].t), padT + ch)
                        ctx.closePath()
                        ctx.fillStyle = grad
                        ctx.fill()
                    }

                    // stroke in sub-segments so each state gets its own color;
                    // discharge is additionally rate-tinted from idle (low
                    // draw) toward discharge (near the window max draw).
                    ctx.lineWidth = chart.lineWidth
                    ctx.lineJoin = "round"
                    ctx.lineCap = "round"
                    let i = 1
                    while (i < rp.length) {
                        const state = rp[i].c
                        let seg = [rp[i - 1]]
                        while (i < rp.length && rp[i].c === state) {
                            seg.push(rp[i])
                            i++
                        }
                        if (state === 0 && dwMax > 0) {
                            for (let j = 1; j < seg.length; j++) {
                                ctx.beginPath()
                                ctx.moveTo(X(seg[j - 1].t), Y(seg[j - 1].v))
                                ctx.lineTo(X(seg[j].t), Y(seg[j].v))
                                ctx.strokeStyle = chart.mixColor(chart.mutedDischargeCol, chart.dischargeCol, dischargeTint(seg[j].w))
                                ctx.stroke()
                            }
                        } else {
                            ctx.beginPath()
                            tracePath(seg)
                            ctx.strokeStyle = state === 1 ? chart.chargeCol : (state === 0 ? chart.dischargeCol : chart.idleCol)
                            ctx.stroke()
                        }
                    }
                }

                // connectors across recording gaps (suspend), matching the legend swatch
                ctx.setLineDash([3, 3])
                ctx.lineWidth = 2
                ctx.strokeStyle = chart.idleCol
                for (let r = 1; r < runs.length; r++) {
                    const a = runs[r - 1][runs[r - 1].length - 1]
                    const b = runs[r][0]
                    ctx.beginPath()
                    ctx.moveTo(X(a.t), Y(a.v))
                    ctx.lineTo(X(b.t), Y(b.v))
                    ctx.stroke()
                }
                ctx.setLineDash([])

                ctx.restore()

                // newest sample marker with level readout (rate-tinted when discharging)
                const last = pts[pts.length - 1]
                if (now - last.t < chart.widget.gapS) {
                    const mx = Math.min(X(last.t), padL + cw)
                    ctx.beginPath()
                    ctx.arc(mx, Y(last.v), chart.markerRadius, 0, Math.PI * 2)
                    if (last.c === 1) {
                        ctx.fillStyle = chart.chargeCol
                    } else if (last.c === 0 && dwMax > 0) {
                        ctx.fillStyle = chart.mixColor(chart.mutedDischargeCol, chart.dischargeCol, dischargeTint(last.w))
                    } else {
                        ctx.fillStyle = last.c === 0 ? chart.dischargeCol : chart.idleCol
                    }
                    ctx.fill()
                    ctx.font = chart.labelFont
                    ctx.textAlign = mx > padL + cw - 30 ? "right" : "left"
                    ctx.textBaseline = "bottom"
                    ctx.fillStyle = labelColor
                    ctx.fillText(Math.round(last.v) + "%", mx + (mx > padL + cw - 30 ? -7 : 7), Y(last.v) - 5)
                }
            }
        }

        StyledText {
            anchors.centerIn: parent
            visible: chart.widget.samples.length < 2
            text: "No battery history yet"
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
        }

        Connections {
            target: chart.widget
            function onSamplesChanged() { canvas.requestPaint() }
        }

        Connections {
            target: Theme
            function onPrimaryChanged() { canvas.requestPaint() }
            function onSuccessChanged() { canvas.requestPaint() }
            function onIsLightModeChanged() { canvas.requestPaint() }
        }

        // keep the "now" edge fresh while the chart is on screen
        Timer {
            interval: 60000
            repeat: true
            running: canvas.visible
            onTriggered: canvas.requestPaint()
        }

        Component.onCompleted: canvas.requestPaint()
    }

    // ── Stats ──

    // One labeled stats row: a section title on the left and three
    // label/value tiles spread across the remaining width.
    component StatRow: Row {
        id: srow

        required property string title
        required property var items

        readonly property real titleWidth: 92

        width: parent.width
        spacing: Theme.spacingM

        StyledText {
            text: srow.title
            width: srow.titleWidth
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
        }

        Repeater {
            model: srow.items

            delegate: Column {
                spacing: 2
                width: (srow.width - srow.titleWidth - srow.spacing * srow.items.length) / srow.items.length

                StyledText {
                    text: modelData.label
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                }

                StyledText {
                    text: modelData.value
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }
            }
        }
    }

    // ── Popout ──

    popoutContent: Component {
        PopoutComponent {
            headerText: "Power"

            Column {
                width: parent.width
                spacing: Theme.spacingL

                // status header: icon + value pairs
                Row {
                    width: parent.width
                    height: 44
                    spacing: Theme.spacingL

                    Row {
                        spacing: 2
                        anchors.verticalCenter: parent.verticalCenter

                        DankIcon {
                            name: root.powerIconName()
                            size: Theme.iconSizeLarge
                            color: root.statusColor
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: root.percentText
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Bold
                            color: root.statusColor
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Row {
                        spacing: 2
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.showDynamicStatus

                        DankIcon {
                            name: "bolt"
                            size: Theme.iconSizeLarge
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: root.wattsText
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Bold
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Row {
                        spacing: 2
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.etaText.length > 0

                        DankIcon {
                            name: "hourglass"
                            size: Theme.iconSizeLarge
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: root.etaText
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Bold
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    StyledText {
                        text: root.statusText()
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceTextMedium
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !root.showDynamicStatus
                    }
                }

                // graph card
                StyledRect {
                    width: parent.width
                    height: graphColumn.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.nestedSurface
                    border.color: Theme.outlineLight
                    border.width: 1

                    Column {
                        id: graphColumn
                        width: parent.width - Theme.spacingM * 2
                        anchors.centerIn: parent
                        spacing: Theme.spacingS

                        // legend
                        Row {
                            spacing: Theme.spacingM

                            Repeater {
                                model: [
                                    { "label": "Charging", "color": Theme.success, "dashed": false },
                                    { "label": "Discharging", "color": Theme.primary, "dashed": false },
                                    { "label": "Plugged", "color": Theme.surfaceVariantText, "dashed": false },
                                    { "label": "Suspend", "color": Theme.surfaceVariantText, "dashed": true }
                                ]

                                delegate: Row {
                                    spacing: Theme.spacingXS
                                    anchors.verticalCenter: parent.verticalCenter

                                    Item {
                                        width: 14
                                        height: 4
                                        anchors.verticalCenter: parent.verticalCenter

                                        Rectangle {
                                            width: parent.width
                                            height: 4
                                            radius: 2
                                            color: modelData.dashed ? "transparent" : modelData.color
                                        }

                                        Canvas {
                                            anchors.fill: parent
                                            visible: modelData.dashed

                                            onPaint: {
                                                const ctx = getContext("2d")
                                                ctx.reset()
                                                ctx.clearRect(0, 0, width, height)
                                                ctx.setLineDash([3, 3])
                                                ctx.strokeStyle = modelData.color
                                                ctx.lineWidth = 2
                                                ctx.beginPath()
                                                ctx.moveTo(1, height / 2)
                                                ctx.lineTo(width - 1, height / 2)
                                                ctx.stroke()
                                            }
                                        }
                                    }

                                    StyledText {
                                        text: modelData.label
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }
                            }
                        }

                        BatteryChart {
                            width: parent.width
                            height: 240
                            widget: root
                        }

                        Rectangle {
                            width: parent.width
                            height: 1
                            color: Theme.outlineLight
                        }

                        // battery stats
                        StatRow {
                            title: "Battery"
                            items: [
                                { "label": "Design cap", "value": root.formatEnergyWh(root._heldEnergyFullDesign) },
                                { "label": "Limit", "value": root._heldLimit > 0 ? root._heldLimit + "%" : "–" },
                                { "label": "Health", "value": root.formatHealth() }
                            ]
                        }

                        // discharge session (since last unplug)
                        StatRow {
                            title: "Since unplug"
                            items: [
                                { "label": "Start cap", "value": root.formatEnergyWh(root.stats.startWh) },
                                { "label": "Start %", "value": root.formatPct(root.stats.startPct) },
                                { "label": "Elapsed", "value": root.formatDuration(root.stats.elapsedSeconds) }
                            ]
                        }

                        // suspended consumption (estimated)
                        StatRow {
                            title: "Suspended"
                            items: [
                                { "label": "Drained", "value": root.formatEnergyWh(root.stats.suspendedWh) },
                                { "label": "Drop", "value": root.formatPct(root.stats.suspendedPct) },
                                { "label": "Time", "value": root.formatDuration(root.stats.suspendedSeconds) }
                            ]
                        }

                        // active consumption (measured), with rate spread folded in
                        StatRow {
                            title: "Active"
                            items: [
                                { "label": "Drained", "value": root.formatEnergyWh(root.stats.activeWh) },
                                { "label": "Drop", "value": root.formatPct(root.stats.activePct) },
                                { "label": "Time", "value": root.formatDuration(root.stats.activeSeconds) },
                                { "label": "Min", "value": root.formatWatt(root.stats.minWatts) },
                                { "label": "Avg", "value": root.formatWatt(root.stats.avgWatts) },
                                { "label": "Max", "value": root.formatWatt(root.stats.maxWatts) }
                            ]
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 680
    popoutHeight: 570

    Component {
        id: horizontalPill

        Row {
            id: powerRow

            spacing: Theme.spacingXS

            DankIcon {
                name: root.powerIconName()
                size: root.iconSize
                color: root.statusColor
                anchors.verticalCenter: parent.verticalCenter
            }

            Item {
                id: textBox

                readonly property real contentSpacing: Theme.spacingS
                readonly property real pairSpacing: 1
                // hourglass ink is wider than bolt's, so give the eta pair a
                // touch more room for optically consistent spacing.
                readonly property real etaPairSpacing: 3
                readonly property real subIconSize: Math.round(root.iconSize * 0.72)
                readonly property real percentWidth: Math.max(percentBaseline.width, percentCurrent.width)
                readonly property real wattsWidth: Math.max(wattsBaseline.width, wattsCurrent.width)
                readonly property real etaWidth: Math.max(etaBaseline.width, etaCurrent.width)
                readonly property real wattsGroupWidth: subIconSize + pairSpacing + wattsWidth
                readonly property real etaGroupWidth: subIconSize + etaPairSpacing + etaWidth
                // Size to what is actually visible so the pill resizes when the
                // ETA is missing (e.g. while the rate settles after plug/unplug).
                readonly property real boxWidth: percentWidth
                    + (root.wattsText.length > 0 ? wattsGroupWidth + contentSpacing : 0)
                    + (root.etaText.length > 0 ? etaGroupWidth + contentSpacing : 0)

                width: boxWidth
                height: statusRow.implicitHeight
                implicitWidth: boxWidth
                implicitHeight: statusRow.implicitHeight
                anchors.verticalCenter: parent.verticalCenter

                StyledTextMetrics {
                    id: percentBaseline

                    text: "100%"
                    font.pixelSize: root.textSize
                }

                StyledTextMetrics {
                    id: percentCurrent

                    text: root.percentText
                    font.pixelSize: root.textSize
                }

                StyledTextMetrics {
                    id: wattsBaseline

                    text: "88.8W"
                    font.pixelSize: root.textSize
                }

                StyledTextMetrics {
                    id: wattsCurrent

                    text: root.wattsText
                    font.pixelSize: root.textSize
                }

                StyledTextMetrics {
                    id: etaBaseline

                    text: "9:59"
                    font.pixelSize: root.textSize
                }

                StyledTextMetrics {
                    id: etaCurrent

                    text: root.etaText
                    font.pixelSize: root.textSize
                }

                Row {
                    id: statusRow

                    anchors.centerIn: parent
                    spacing: textBox.contentSpacing

                    Item {
                        width: textBox.percentWidth
                        height: percentLabel.implicitHeight
                        anchors.verticalCenter: parent.verticalCenter

                        StyledText {
                            id: percentLabel

                            anchors.fill: parent
                            text: root.percentText
                            font.pixelSize: root.textSize
                            color: Theme.widgetTextColor
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            wrapMode: Text.NoWrap
                            elide: Text.ElideNone
                        }
                    }

                    Row {
                        visible: root.wattsText.length > 0
                        spacing: textBox.pairSpacing
                        anchors.verticalCenter: parent.verticalCenter

                        DankIcon {
                            name: "bolt"
                            size: textBox.subIconSize
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Item {
                            width: textBox.wattsWidth
                            height: wattsLabel.implicitHeight
                            anchors.verticalCenter: parent.verticalCenter

                            StyledText {
                                id: wattsLabel

                                anchors.fill: parent
                                text: root.wattsText
                                font.pixelSize: root.textSize
                                color: Theme.widgetTextColor
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                wrapMode: Text.NoWrap
                                elide: Text.ElideNone
                            }
                        }
                    }

                    Row {
                        visible: root.etaText.length > 0
                        spacing: textBox.etaPairSpacing
                        anchors.verticalCenter: parent.verticalCenter

                        DankIcon {
                            name: "hourglass"
                            size: textBox.subIconSize
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Item {
                            width: textBox.etaWidth
                            height: etaLabel.implicitHeight
                            anchors.verticalCenter: parent.verticalCenter

                            StyledText {
                                id: etaLabel

                                anchors.fill: parent
                                text: root.etaText
                                font.pixelSize: root.textSize
                                color: Theme.widgetTextColor
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                wrapMode: Text.NoWrap
                                elide: Text.ElideNone
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: verticalPill

        Column {
            spacing: 1

            DankIcon {
                name: root.powerIconName()
                size: root.iconSizeLarge
                color: root.statusColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.percentText
                font.pixelSize: root.textSize
                color: Theme.widgetTextColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Row {
                spacing: 2
                visible: root.wattsText.length > 0
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    name: "bolt"
                    size: root.textSize
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: root.wattsText
                    font.pixelSize: root.textSize
                    color: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Row {
                spacing: 2
                visible: root.etaText.length > 0
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    name: "hourglass"
                    size: root.textSize
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: root.etaText
                    font.pixelSize: root.textSize
                    color: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }
}
