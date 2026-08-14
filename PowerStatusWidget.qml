import QtQuick
import Quickshell
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets
import "power_status_logic.js" as Logic

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

    readonly property int windowSeconds: 24 * 3600
    // 2.5 slow-poll periods: a 60s heartbeat plus a conservative margin.
    readonly property int gapS: Logic.GAP_SECONDS
    // Proc keeps a persistent debouncer per id. A plugin-wide id lets leader
    // handoff/reload reuse that entry instead of leaking one random id per
    // destroyed widget instance; generation and leader checks reject stale
    // callbacks from an earlier command.
    readonly property string _refreshProcId: "powerStatus.refresh"
    readonly property string _globalName: "powerStatus.shared"
    readonly property string _instanceToken: Math.random().toString(36).slice(2) + Date.now().toString(36)
    readonly property int _leaderLeaseMs: 7000

    property var samples: []
    property bool _reading: false
    property int _readingStartedAt: 0
    property int _readGeneration: 0
    property bool _leader: false
    property var _shared: null
    property bool _stateRetryUsed: false

    function newSharedState() {
        return {
            initialized: false,
            leaderToken: "",
            leaderBeat: 0,
            samples: [],
            hasBattery: false,
            level: 0,
            state: "none",
            watts: NaN,
            energyNowWh: NaN,
            energyFullWh: NaN,
            energyFullDesignWh: NaN,
            limit: 100,
            noBatteryStreak: 0,
            smoothedRate: 0,
            lastRateSampleTime: 0,
            rateSeedWindow: []
        };
    }

    function sharedState() {
        if (!pluginService || !pluginId)
            return null;
        const current = pluginService.getGlobalVar(pluginId, _globalName, null);
        return current && typeof current === "object" ? current : newSharedState();
    }

    function pruneSamples() {
        const t0 = Math.floor(Date.now() / 1000) - windowSeconds - 3600;
        const source = _shared && Array.isArray(_shared.samples) ? _shared.samples : samples;
        const kept = [];
        for (let i = 0; i < source.length; i++) {
            if (source[i] && Number(source[i].t) >= t0)
                kept.push(source[i]);
        }
        kept.sort((a, b) => Number(a.t) - Number(b.t));
        samples = kept;
        if (_shared)
            _shared.samples = kept;
    }

    function saveSamples() {
        if (!_leader || !pluginService || !pluginId || !_shared)
            return;
        pruneSamples();
        pluginService.savePluginState(pluginId, "samples", _shared.samples);
        publishShared();
        scheduleStateRetry();
    }

    // DMS 1.5.3 attempts `FileView.loaded.connect(...)` on the first write
    // after a plugin reload even though `loaded` is a bool. The writer exists
    // on the debounced follow-up, so repeat this exact write once after the
    // 150ms PluginService debounce. This is bounded and idempotent per leader
    // epoch; newer DMS versions simply replace the same state value twice.
    Timer {
        id: stateRetryTimer
        interval: 280
        repeat: false
        onTriggered: {
            if (root._leader && root.pluginService && root.pluginId && root._shared)
                root.pluginService.savePluginState(root.pluginId, "samples", root._shared.samples)
        }
    }

    function scheduleStateRetry() {
        if (_stateRetryUsed)
            return;
        _stateRetryUsed = true;
        stateRetryTimer.restart();
    }

    // held (last-good) state
    property bool _heldHasBattery: false
    property int _heldLevel: 0
    property bool _heldCharging: false
    property bool _heldPlugged: false
    property real _heldWatts: NaN
    property real _heldEnergyNow: NaN
    property real _heldEnergyFull: NaN
    property real _heldEnergyFullDesign: NaN
    property int _heldLimit: 100

    function syncShared() {
        const state = sharedState();
        if (!state)
            return;
        _shared = state;
        samples = Array.isArray(state.samples) ? state.samples : [];
        _heldHasBattery = state.hasBattery === true;
        _heldLevel = isFinite(Number(state.level)) ? Number(state.level) : 0;
        _heldCharging = state.state === "charging";
        _heldPlugged = state.state === "plugged" || state.state === "charging";
        _heldWatts = Number(state.watts);
        _heldEnergyNow = Number(state.energyNowWh);
        _heldEnergyFull = Number(state.energyFullWh);
        _heldEnergyFullDesign = Number(state.energyFullDesignWh);
        _heldLimit = isFinite(Number(state.limit)) && Number(state.limit) > 0
            ? Number(state.limit) : 100;
        _smoothedRate = Number(state.smoothedRate);
        _lastRateSampleTime = Number(state.lastRateSampleTime);
        _rateSeedWindow = Array.isArray(state.rateSeedWindow) ? state.rateSeedWindow : [];
    }

    function publishShared() {
        if (!_leader || !pluginService || !pluginId || !_shared)
            return;
        _shared.smoothedRate = _smoothedRate;
        _shared.lastRateSampleTime = _lastRateSampleTime;
        _shared.rateSeedWindow = _rateSeedWindow;
        pluginService.setGlobalVar(pluginId, _globalName, _shared);
        syncShared();
    }

    function initializeShared(state) {
        if (state.initialized !== true) {
            const saved = pluginService.loadPluginState(pluginId, "samples", []);
            state.samples = Array.isArray(saved) ? saved : [];
            state.initialized = true;
            state.noBatteryStreak = 0;
            pruneSamples();
        }
    }

    function tryClaimLeader() {
        if (!pluginService || !pluginId)
            return;
        const now = Date.now();
        let state = sharedState();
        const currentToken = state.leaderToken || "";
        const currentBeat = Number(state.leaderBeat) || 0;
        if (_leader && currentToken === _instanceToken) {
            state.leaderBeat = now;
            _shared = state;
            publishShared();
            return;
        }
        if (currentToken && now - currentBeat <= _leaderLeaseMs) {
            _leader = false;
            syncShared();
            return;
        }

        state.leaderToken = _instanceToken;
        state.leaderBeat = now;
        pluginService.setGlobalVar(pluginId, _globalName, state);
        const confirmed = sharedState();
        if (confirmed && confirmed.leaderToken === _instanceToken) {
            _leader = true;
            _shared = confirmed;
            initializeShared(_shared);
            _shared.leaderBeat = now;
            _stateRetryUsed = false;
            // Prime the debounced state writer for this leader epoch. On DMS
            // 1.5.3 the first call may emit the known FileView warning; the
            // bounded retry in saveSamples() follows after that debounce.
            saveSamples();
            publishShared();
            refreshTimer.restart();
            root.refresh();
        } else {
            _leader = false;
            syncShared();
        }
    }

    function releaseLeader() {
        if (!_leader || !pluginService || !pluginId)
            return;
        const state = sharedState();
        if (state && state.leaderToken === _instanceToken) {
            state.leaderToken = "";
            state.leaderBeat = 0;
            pluginService.setGlobalVar(pluginId, _globalName, state);
        }
    }

    function parseOutput(out) {
        if (!_leader || !_shared)
            return;
        const aggregate = Logic.aggregateDelimitedOutput(out);
        if (!aggregate.hasBattery) {
            _shared.noBatteryStreak = (Number(_shared.noBatteryStreak) || 0) + 1;
            // Only successful, structurally valid empty scans reach here. A
            // command failure returns before this function and keeps last-good
            // presence/state intact.
            if (_shared.noBatteryStreak >= 3) {
                _shared.hasBattery = false;
                _shared.state = "none";
            }
            publishShared();
            return;
        }

        _shared.noBatteryStreak = 0;
        const previousCode = Logic.sampleCodeForState(_shared.state);
        _shared.hasBattery = true;
        _shared.level = aggregate.level;
        _shared.state = aggregate.state;
        _shared.watts = aggregate.watts;
        _shared.energyNowWh = aggregate.energyNowWh;
        _shared.energyFullWh = aggregate.energyFullWh;
        _shared.energyFullDesignWh = aggregate.energyFullDesignWh;
        _shared.limit = aggregate.limit;
        syncShared();

        const nextCode = aggregate.sampleCode;
        if (nextCode !== previousCode) {
            root._resetSmoothedRate();
            root.sample(true);
        } else if (samples.length === 0) {
            root.sample(false);
        }
        root.updateSmoothedRate();
        publishShared();
    }

    function refresh() {
        if (!_leader)
            return;
        // Proc's fourth argument is debounce, not timeout. Keep the explicit
        // 1s command timeout below shorter than this 5s stale-read release.
        if (_reading) {
            if (Date.now() - _readingStartedAt < 5000)
                return;
            _reading = false;
            ++_readGeneration;
        }
        _reading = true;
        _readingStartedAt = Date.now();
        const generation = ++_readGeneration;
        const cmd = `
for s in /sys/class/power_supply/*; do
  [ -d "$s" ] || continue
  t=$(cat "$s/type" 2>/dev/null) || continue
  [ "$t" = "Battery" ] || continue
  scope=$(cat "$s/scope" 2>/dev/null)
  [ "$scope" = "Device" ] && continue
  cap=$(cat "$s/capacity" 2>/dev/null)
  [ -n "$cap" ] || continue
  st=$(cat "$s/status" 2>/dev/null)
  p=$(cat "$s/power_now" 2>/dev/null)
  c=$(cat "$s/current_now" 2>/dev/null)
  v=$(cat "$s/voltage_now" 2>/dev/null)
  en=$(cat "$s/energy_now" 2>/dev/null)
  ef=$(cat "$s/energy_full" 2>/dev/null)
  efd=$(cat "$s/energy_full_design" 2>/dev/null)
  cn=$(cat "$s/charge_now" 2>/dev/null)
  cf=$(cat "$s/charge_full" 2>/dev/null)
  cfd=$(cat "$s/charge_full_design" 2>/dev/null)
  lim=$(cat "$s/charge_control_end_threshold" 2>/dev/null)
  if [ -z "$lim" ]; then lim=$(cat "$s/charge_control_limit" 2>/dev/null); fi
  if [ -z "$lim" ]; then lim=$(cat "$s/charge_stop_threshold" 2>/dev/null); fi
  printf 'B\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$scope" "$cap" "$st" "$p" "$c" "$v" "$en" "$ef" "$efd" "$cn" "$cf" "$cfd" "$lim"
done
for s in /sys/class/power_supply/*; do
  [ -f "$s/online" ] || continue
  t=$(cat "$s/type" 2>/dev/null) || continue
  scope=$(cat "$s/scope" 2>/dev/null)
  o=$(cat "$s/online" 2>/dev/null)
  printf 'S\\t%s\\t%s\\t%s\\n' "$t" "$scope" "$o"
done`;
        Proc.runCommand(_refreshProcId, ["sh", "-c", cmd], (stdout, exitCode) => {
            if (generation !== _readGeneration)
                return;
            _reading = false;
            if (root === null || exitCode !== 0)
                return;
            root.parseOutput(stdout);
        }, 0, 1000);
    }

    Timer {
        id: refreshTimer
        // Poll fast while a battery is present; fall back to a slow probe so a
        // hotplugged battery is still detected without burning a sh every 5s on
        // battery-less desktops.
        interval: _heldHasBattery ? 5000 : 60000
        repeat: true
        running: _leader
        onTriggered: root.refresh()
    }

    Timer {
        id: leaderHeartbeatTimer
        interval: 2000
        repeat: true
        running: root._leader
        onTriggered: root.tryClaimLeader()
    }

    Timer {
        id: leaderElectionTimer
        interval: 1000
        repeat: true
        running: !root._leader
        onTriggered: root.tryClaimLeader()
    }

    function sampleState() {
        return _shared ? Logic.sampleCodeForState(_shared.state) : 2;
    }

    function sample(force) {
        if (!_leader || !_heldHasBattery || !_shared)
            return;
        const t = Math.floor(Date.now() / 1000);
        const last = _shared.samples.length > 0 ? _shared.samples[_shared.samples.length - 1] : null;
        // The 5s floor prevents heartbeat/boundary double-sampling, but a
        // boundary sample must land immediately so the graph flips at once.
        if (last && t - last.t < 5 && !force)
            return;
        _shared.samples = _shared.samples.concat([{
            "t": t,
            "v": _heldLevel,
            "c": sampleState(),
            // Keep the key on every new sample. A null value is explicitly
            // unavailable and is never integrated by the conservative stats
            // coverage policy.
            "w": isFinite(_heldWatts) && _heldWatts >= 0 ? _heldWatts : null
        }]);
        samples = _shared.samples;
        saveSamples();
    }

    Timer {
        interval: 60000
        repeat: true
        running: _leader && _heldHasBattery
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
        if (!_leader)
            return;
        _smoothedRate = 0;
        _lastRateSampleTime = 0;
        _rateSeedWindow = [];
    }

    function updateSmoothedRate() {
        const w = _heldWatts;
        if (!_leader || !_heldHasBattery || !isFinite(w) || w <= 0) {
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

    onPluginServiceChanged: root.tryClaimLeader()
    onPluginIdChanged: root.tryClaimLeader()
    Component.onCompleted: root.tryClaimLeader()
    Component.onDestruction: root.releaseLeader()

    Connections {
        target: root.pluginService
        function onGlobalVarChanged(changedPluginId, varName) {
            if (changedPluginId === root.pluginId && varName === root._globalName && !root._leader)
                root.syncShared();
        }
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
    readonly property bool isOnBattery: hasBattery && !isPluggedIn
    readonly property color statusColor: {
        if (!hasBattery) {
            return Theme.widgetIconColor;
        }
        if (isCharging) {
            return Theme.success;
        }
        if (isOnBattery) {
            return batteryPercent <= SettingsData.batteryLowThreshold ? Theme.error : Theme.primary;
        }
        // Keep plugged-idle neutral, matching the chart's Plugged in series.
        return Theme.surfaceVariantText;
    }
    readonly property string pillTooltip: {
        if (!hasBattery)
            return "No battery detected";
        const state = isCharging ? "charging" : (isPluggedIn ? "plugged in" : "on battery");
        const limit = _heldLimit > 0 && _heldLimit < 100 ? `, charge limit ${_heldLimit}%` : "";
        return `Battery ${batteryPercent}%, ${state}${limit}`;
    }
    readonly property string pillAccessibleName: pillTooltip
    readonly property int textSize: Theme.barTextSize(barThickness,
        barConfig ? barConfig.fontScale : undefined,
        barConfig ? barConfig.maximizeWidgetText : undefined)

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
        if (!isFinite(capacity) || !isFinite(energy) || capacity <= 0 || energy <= 0)
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

    // Use charging glyphs only while current is flowing into the battery;
    // plugged-idle remains a normal battery glyph with neutral status color.
    function powerIconName() {
        const level = batteryPercent;
        if (isCharging) {
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
            return "Plugged in";
        return "On battery";
    }

    // ── Usage stats ──
    // Session-based, from the last unplug transition to now. Consumption is
    // split at recording gaps (suspend/off):
    //   - While awake: measured from regular samples — Wh from the power integral,
    //     % from the battery-level drop across each continuous active run.
    //   - While asleep: estimated, since no draw is logged during gaps — the
    //     level drop across each gap, converted to Wh against current full
    //     capacity. Design capacity is used only for health.
    // Since-unplug: starting % is the level at the unplug moment; starting
    // capacity = start% × current full capacity; elapsed = time since unplug.
    // A session without watt coverage is unavailable. Legacy samples saved
    // without "w" are never integrated across newer samples.

    readonly property var stats: computeStats()
    readonly property bool sessionAvailable: stats && stats.sessionAvailable === true
    readonly property string sessionTitle: isOnBattery ? "Current battery session" : "Last battery session"
    readonly property string sessionEmptyTitle: isOnBattery
        ? "Collecting battery-session data…" : "No recent on-battery session."
    readonly property string sessionEmptyDetail: isOnBattery
        ? "Usage details will appear as this session is recorded."
        : "Usage details will appear after you unplug."

    function computeStats() {
        return Logic.computeStats(samples, Math.floor(Date.now() / 1000),
            windowSeconds, gapS, _heldEnergyFull);
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
        if (!isFinite(_heldEnergyFullDesign) || !isFinite(_heldEnergyFull)
                || _heldEnergyFullDesign <= 0 || _heldEnergyFull <= 0)
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

                // Neutral underfill: one color for every state so it never
                // clashes with the green charging line or blue discharge line.
                const grad = ctx.createLinearGradient(0, padT, 0, padT + ch)
                grad.addColorStop(0, Qt.rgba(Theme.surfaceVariantText.r, Theme.surfaceVariantText.g, Theme.surfaceVariantText.b, 0.18))
                grad.addColorStop(1, Qt.rgba(Theme.surfaceVariantText.r, Theme.surfaceVariantText.g, Theme.surfaceVariantText.b, 0.0))

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
                    if (rp.length < 2) {
                        // lone sample between gaps: draw a dot so a brief blip
                        // stays visible instead of vanishing
                        const p = rp[0]
                        ctx.beginPath()
                        ctx.arc(X(p.t), Y(p.v), chart.markerRadius * 0.8, 0, Math.PI * 2)
                        ctx.fillStyle = p.c === 1 ? chart.chargeCol : (p.c === 0 && dwMax > 0
                            ? chart.mixColor(chart.mutedDischargeCol, chart.dischargeCol, dischargeTint(p.w))
                            : (p.c === 0 ? chart.dischargeCol : chart.idleCol))
                        ctx.fill()
                        continue
                    }

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
            function onNestedSurfaceChanged() { canvas.requestPaint() }
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

        // Give section titles room to remain readable on normal popouts;
        // child labels still elide gracefully at the compact minimum width.
        readonly property real titleWidth: 112

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
            headerText: "Battery"

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
                            color: root.statusColor
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
                            color: root.statusColor
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
                        color: root.statusColor
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !root.showDynamicStatus
                    }
                }

                // The graph/stat card is intentionally scrollable. DMS binds
                // PluginPopout's outer height to implicitHeight, so a fixed
                // popoutHeight cannot protect short or scaled displays.
                DankFlickable {
                    id: statsViewport
                    width: parent.width
                    readonly property real availableScreenHeight: root.parentScreen && root.parentScreen.height > 0
                        ? root.parentScreen.height : 800
                    readonly property real viewportLimit: Math.max(180,
                        Math.min(640, availableScreenHeight * 0.72))
                    height: Math.min(graphCard.implicitHeight, viewportLimit)
                    implicitHeight: height
                    contentWidth: width
                    contentHeight: graphCard.implicitHeight
                    clip: true
                    interactive: contentHeight > height

                    StyledRect {
                        id: graphCard
                        width: statsViewport.width
                        implicitHeight: graphColumn.implicitHeight + Theme.spacingM * 2
                        height: implicitHeight
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
                                    { "label": "On battery", "color": Theme.primary, "dashed": false },
                                    { "label": "Plugged in", "color": Theme.surfaceVariantText, "dashed": false },
                                    { "label": "Sleep gap", "color": Theme.surfaceVariantText, "dashed": true }
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

                        StyledText {
                            text: "Last 24 hours"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
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
                                { "label": "Design capacity", "value": root._heldEnergyFullDesign > 0 ? root.formatEnergyWh(root._heldEnergyFullDesign) : "–" },
                                { "label": "Charge limit", "value": root._heldLimit > 0 ? root._heldLimit + "%" : "–" },
                                { "label": "Health", "value": root.formatHealth() }
                            ]
                        }

                        // Session rows only appear when the history has a
                        // conservative watt-coverage path. This keeps a
                        // plugged-in fresh install from rendering a grid of
                        // unavailable values.
                        Column {
                            id: sessionStats
                            width: parent.width
                            visible: root.sessionAvailable
                            height: visible ? implicitHeight : 0
                            spacing: Theme.spacingS

                            StyledText {
                                text: root.sessionTitle
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                            }

                            StatRow {
                                title: ""
                                items: [
                                    { "label": "Starting energy", "value": root.formatEnergyWh(root.stats.startWh) },
                                    { "label": "Starting charge", "value": root.formatPct(root.stats.startPct) },
                                    { "label": "Duration", "value": root.formatDuration(root.stats.elapsedSeconds) }
                                ]
                            }

                            StatRow {
                                title: "While asleep"
                                items: [
                                    { "label": "Estimated use", "value": root.formatEnergyWh(root.stats.suspendedWh) },
                                    { "label": "Battery drop", "value": root.formatPct(root.stats.suspendedPct) },
                                    { "label": "Duration", "value": root.formatDuration(root.stats.suspendedSeconds) }
                                ]
                            }

                            StatRow {
                                title: "While awake"
                                items: [
                                    { "label": "Energy used", "value": root.formatEnergyWh(root.stats.activeWh) },
                                    { "label": "Battery drop", "value": root.formatPct(root.stats.activePct) },
                                    { "label": "Duration", "value": root.formatDuration(root.stats.activeSeconds) }
                                ]
                            }

                            StatRow {
                                title: "Power draw"
                                items: [
                                    { "label": "Low", "value": root.formatWatt(root.stats.minWatts) },
                                    { "label": "Average", "value": root.formatWatt(root.stats.avgWatts) },
                                    { "label": "High", "value": root.formatWatt(root.stats.maxWatts) }
                                ]
                            }
                        }

                        Column {
                            id: sessionEmpty
                            width: parent.width
                            visible: !root.sessionAvailable
                            height: visible ? implicitHeight : 0
                            spacing: Theme.spacingXS

                            StyledText {
                                text: root.sessionEmptyTitle
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                                wrapMode: Text.WordWrap
                                width: parent.width
                            }

                            StyledText {
                                text: root.sessionEmptyDetail
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                                width: parent.width
                            }
                        }
                        }
                    }
                }
            }
        }
    }

    popoutWidth: root.parentScreen && root.parentScreen.width > 0
        ? Math.min(680, Math.max(280, root.parentScreen.width * 0.9)) : 680

    Component {
        id: horizontalPill

        Row {
            id: powerRow

            spacing: Theme.spacingXS
            Accessible.name: root.pillAccessibleName
            Accessible.description: root.pillTooltip
            Accessible.role: Accessible.StaticText

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
                            color: root.statusColor
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
                            color: root.statusColor
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
                            color: root.statusColor
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

            // BasePill owns the click handler. HoverHandler keeps the
            // standard delayed tooltip independent of that click path.
            HoverHandler {
                id: horizontalPillHover
                onHoveredChanged: {
                    if (hovered)
                        horizontalPillTooltipDelay.restart();
                    else {
                        horizontalPillTooltipDelay.stop();
                        horizontalPillTooltip.hide();
                    }
                }
            }

            Timer {
                id: horizontalPillTooltipDelay
                interval: 400
                repeat: false
                onTriggered: horizontalPillTooltip.show(root.pillTooltip, powerRow, 0, 0, "bottom")
            }

            DankTooltipV2 {
                id: horizontalPillTooltip
            }
        }
    }

    Component {
        id: verticalPill

        Column {
            id: verticalContent
            spacing: 1
            Accessible.name: root.pillAccessibleName
            Accessible.description: root.pillTooltip
            Accessible.role: Accessible.StaticText

            DankIcon {
                name: root.powerIconName()
                size: root.iconSizeLarge
                color: root.statusColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.percentText
                font.pixelSize: root.textSize
                color: root.statusColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Row {
                spacing: 2
                visible: root.wattsText.length > 0
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    name: "bolt"
                    size: root.textSize
                    color: root.statusColor
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
                    color: root.statusColor
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: root.etaText
                    font.pixelSize: root.textSize
                    color: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            HoverHandler {
                id: verticalPillHover
                onHoveredChanged: {
                    if (hovered)
                        verticalPillTooltipDelay.restart();
                    else {
                        verticalPillTooltipDelay.stop();
                        verticalPillTooltip.hide();
                    }
                }
            }

            Timer {
                id: verticalPillTooltipDelay
                interval: 400
                repeat: false
                onTriggered: verticalPillTooltip.show(root.pillTooltip, verticalContent, 0, 0, "right")
            }

            DankTooltipV2 {
                id: verticalPillTooltip
            }
        }
    }
}
