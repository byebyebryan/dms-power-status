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
    readonly property string statusText: {
        const parts = [];
        if (percentText.length > 0) {
            parts.push(percentText);
        }
        if (wattsText.length > 0) {
            parts.push(wattsText);
        }
        if (etaText.length > 0) {
            parts.push(etaText);
        }
        return parts.join(" ");
    }
    readonly property string statusBaseline: showDynamicStatus ? "100% 88.8W 9h 59m" : "100%"
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

    pillClickAction: (x, y, width, section, screen) => {
        root.openBatteryPopout(x, y, width, section, screen);
    }

    function formatWatts(watts) {
        if (watts === undefined || watts === null || isNaN(watts) || watts < 0.1) {
            return "";
        }
        return watts < 10 ? `${watts.toFixed(1)}W` : `${watts.toFixed(0)}W`;
    }

    function openBatteryPopout(x, y, width, section, screen) {
        if (popoutService?.batteryPopoutLoader) {
            popoutService.batteryPopoutLoader.active = true;
        }
        Qt.callLater(() => {
            const popout = popoutService?.batteryPopoutLoader?.item ?? popoutService?.batteryPopout;
            if (!popout) {
                return;
            }

            const currentScreen = parentScreen || screen || Screen;
            const effectiveBarConfig = barConfig;
            const barPosition = axis?.edge === "left" ? 2 : (axis?.edge === "right" ? 3 : (axis?.edge === "top" ? 0 : 1));
            const triggerWidth = root.width > 0 ? root.width : width;

            if (popout.setBarContext) {
                popout.setBarContext(barPosition, effectiveBarConfig?.bottomGap ?? 0);
            }
            if (popout.setTriggerPosition) {
                const globalPos = root.mapToItem(null, 0, 0);
                const pos = SettingsData.getPopupTriggerPosition(globalPos, currentScreen, barThickness, triggerWidth, barSpacing, barPosition, effectiveBarConfig);
                popout.setTriggerPosition(pos.x, pos.y, pos.width, section, currentScreen, barPosition, barThickness, barSpacing, effectiveBarConfig);
            }
            PopoutManager.requestPopout(popout, undefined, "battery");
        });
    }

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

                readonly property real boxWidth: Math.max(statusBaselineMetrics.width, statusCurrent.width)

                width: boxWidth
                height: statusLabel.implicitHeight
                implicitWidth: boxWidth
                implicitHeight: statusLabel.implicitHeight
                anchors.verticalCenter: parent.verticalCenter

                StyledTextMetrics {
                    id: statusBaselineMetrics

                    text: root.statusBaseline
                    font.pixelSize: root.textSize
                }

                StyledTextMetrics {
                    id: statusCurrent

                    text: root.statusText
                    font.pixelSize: root.textSize
                }

                StyledText {
                    id: statusLabel

                    anchors.fill: parent
                    text: root.statusText
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

            StyledText {
                visible: root.wattsText.length > 0
                text: root.wattsText
                font.pixelSize: root.textSize
                color: Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }
}
