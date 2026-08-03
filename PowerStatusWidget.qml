import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

PluginComponent {
    id: root

    layerNamespacePlugin: "power-status"
    visible: hasBattery

    property var popoutService: null

    // ── Sampler / retention ──

    readonly property string pid: "powerStatus"
    readonly property int windowSeconds: 12 * 3600
    readonly property int gapS: 1200

    property var samples: []

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

    function sample() {
        if (!BatteryService.batteryAvailable)
            return;
        const t = Math.floor(Date.now() / 1000);
        const last = samples.length > 0 ? samples[samples.length - 1] : null;
        if (last && t - last.t < 5)
            return;
        samples = samples.concat([{
            "t": t,
            "v": batteryPercent,
            "c": (BatteryService.isCharging || BatteryService.isPluggedIn) ? 1 : 0
        }]);
        saveSamples();
    }

    Timer {
        interval: 60000
        repeat: true
        running: BatteryService.batteryAvailable
        onTriggered: root.sample()
    }

    Connections {
        target: BatteryService
        function onIsChargingChanged() { root.sample() }
        function onIsPluggedInChanged() { root.sample() }
    }

    onPluginServiceChanged: root.loadSamples()
    onPluginIdChanged: root.loadSamples()
    Component.onCompleted: {
        root.loadSamples();
        root.sample();
    }

    // ── Derived state (unchanged from existing pill) ──

    readonly property bool hasBattery: BatteryService.batteryAvailable
    readonly property int batteryPercent: Math.max(0, Math.min(100, Math.round(BatteryService.batteryLevel)))
    readonly property real powerWatts: Math.abs(BatteryService.changeRate || 0)
    readonly property bool hasUsefulPower: powerWatts >= 0.1
    readonly property bool showDynamicStatus: hasBattery && hasUsefulPower && (BatteryService.isCharging || !BatteryService.isPluggedIn)
    readonly property string wattsText: showDynamicStatus ? formatWatts(powerWatts) : ""
    readonly property string etaText: {
        if (!showDynamicStatus) {
            return "";
        }
        const eta = BatteryService.formatTimeRemaining();
        return eta === "Unknown" ? "" : eta;
    }
    readonly property string percentText: hasBattery ? `${batteryPercent}%` : ""
    readonly property color statusColor: {
        if (!hasBattery) {
            return Theme.widgetIconColor;
        }
        if (BatteryService.isLowBattery && !BatteryService.isCharging && !BatteryService.isPluggedIn) {
            return Theme.error;
        }
        if (BatteryService.isCharging || BatteryService.isPluggedIn) {
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

    // ── Chart ──

    component BatteryChart: Item {
        id: chart

        required property var widget

        readonly property real padL: 6
        readonly property real padR: 12
        readonly property real padT: 18
        readonly property real padB: 22

        readonly property color dischargeCol: Theme.primary
        readonly property color chargeCol: Theme.success

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

                // soft grid: hairlines with labels
                const gridColor = Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.10)
                const labelColor = Theme.withAlpha(Theme.surfaceVariantText, 0.8)
                ctx.lineWidth = 1
                ctx.strokeStyle = gridColor
                ctx.font = "9px sans-serif"
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

                // time ticks on round hours
                ctx.textBaseline = "top"
                ctx.textAlign = "center"
                const stepS = 3 * 3600
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

                    // stroke in sub-segments so charging spans get their own color
                    ctx.lineWidth = 2.5
                    ctx.lineJoin = "round"
                    ctx.lineCap = "round"
                    let i = 1
                    while (i < rp.length) {
                        const charging = rp[i].c === 1
                        let seg = [rp[i - 1]]
                        while (i < rp.length && (rp[i].c === 1) === charging) {
                            seg.push(rp[i])
                            i++
                        }
                        ctx.beginPath()
                        tracePath(seg)
                        ctx.strokeStyle = charging ? chart.chargeCol : chart.dischargeCol
                        ctx.stroke()
                    }
                }

                // faint connectors across recording gaps (suspend)
                ctx.setLineDash([2, 5])
                ctx.lineWidth = 1
                ctx.strokeStyle = Qt.rgba(Theme.outline.r, Theme.outline.g, Theme.outline.b, 0.35)
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

                // newest sample marker with level readout
                const last = pts[pts.length - 1]
                if (now - last.t < chart.widget.gapS) {
                    const mx = Math.min(X(last.t), padL + cw)
                    ctx.beginPath()
                    ctx.arc(mx, Y(last.v), 3.5, 0, Math.PI * 2)
                    ctx.fillStyle = last.c === 1 ? chart.chargeCol : chart.dischargeCol
                    ctx.fill()
                    ctx.font = "9px sans-serif"
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

    // ── Popout ──

    popoutContent: Component {
        PopoutComponent {
            headerText: "Power"

            Column {
                width: parent.width
                spacing: Theme.spacingL

                // status header
                Row {
                    width: parent.width
                    height: 40
                    spacing: Theme.spacingM

                    DankIcon {
                        name: BatteryService.getBatteryIcon()
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

                    StyledText {
                        text: root.showDynamicStatus ? `${root.wattsText} · ${root.etaText}` : BatteryService.batteryStatus
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceTextMedium
                        elide: Text.ElideRight
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // graph card
                StyledRect {
                    width: parent.width
                    height: graphColumn.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceLight
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
                                    { "label": "Charging", "color": Theme.success },
                                    { "label": "Discharging", "color": Theme.primary },
                                    { "label": "Suspend", "color": Theme.surfaceVariantText }
                                ]

                                delegate: Row {
                                    spacing: Theme.spacingXS
                                    anchors.verticalCenter: parent.verticalCenter

                                    Rectangle {
                                        width: 14
                                        height: 4
                                        radius: 2
                                        color: modelData.color
                                        anchors.verticalCenter: parent.verticalCenter
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
                            height: 170
                            widget: root
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 480
    popoutHeight: 340

    Component {
        id: horizontalPill

        Row {
            id: powerRow

            spacing: Theme.spacingXS

            DankIcon {
                name: BatteryService.getBatteryIcon()
                size: root.iconSize
                color: root.statusColor
                anchors.verticalCenter: parent.verticalCenter
            }

            Item {
                id: textBox

                readonly property real contentSpacing: Theme.spacingS
                readonly property real subIconSize: Math.round(root.iconSize * 0.72)
                readonly property real percentWidth: Math.max(percentBaseline.width, percentCurrent.width)
                readonly property real wattsWidth: Math.max(wattsBaseline.width, wattsCurrent.width)
                readonly property real etaWidth: Math.max(etaBaseline.width, etaCurrent.width)
                readonly property real dynamicWidth: percentWidth + wattsWidth + etaWidth + subIconSize * 2 + contentSpacing * 4
                readonly property real boxWidth: root.showDynamicStatus ? dynamicWidth : percentWidth

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

                    text: "9h 59m"
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

                    DankIcon {
                        visible: root.wattsText.length > 0
                        name: "bolt"
                        size: textBox.subIconSize
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Item {
                        visible: root.wattsText.length > 0
                        width: visible ? textBox.wattsWidth : 0
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

                    DankIcon {
                        visible: root.etaText.length > 0
                        name: "schedule"
                        size: textBox.subIconSize
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Item {
                        visible: root.etaText.length > 0
                        width: visible ? textBox.etaWidth : 0
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

    Component {
        id: verticalPill

        Column {
            spacing: 1

            DankIcon {
                name: BatteryService.getBatteryIcon()
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
                    color: Theme.surfaceVariantText
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
                    name: "schedule"
                    size: root.textSize
                    color: Theme.surfaceVariantText
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
