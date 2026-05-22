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
            popoutService?.toggleBattery(x, y, width, section, screen);
        });
    }

    Component {
        id: horizontalPill

        Row {
            id: powerRow

            spacing: Theme.spacingXS

            Item {
                id: wattsBox

                readonly property real boxWidth: visible ? Math.max(wattsBaseline.width, wattsCurrent.width) : 0

                visible: root.wattsText.length > 0
                width: boxWidth
                height: wattsLabel.implicitHeight
                implicitWidth: boxWidth
                implicitHeight: wattsLabel.implicitHeight
                anchors.verticalCenter: parent.verticalCenter

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

            Item {
                id: etaBox

                visible: root.etaText.length > 0
                readonly property real boxWidth: visible ? Math.max(etaBaseline.width, etaCurrent.width) : 0

                width: boxWidth
                height: etaLabel.implicitHeight
                implicitWidth: boxWidth
                implicitHeight: etaLabel.implicitHeight
                anchors.verticalCenter: parent.verticalCenter

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

                StyledText {
                    id: etaLabel

                    anchors.fill: parent
                    text: root.etaText
                    font.pixelSize: root.textSize
                    color: Theme.surfaceVariantText
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    wrapMode: Text.NoWrap
                    elide: Text.ElideNone
                }
            }

            Item {
                id: percentBox

                visible: root.percentText.length > 0
                readonly property real boxWidth: visible ? Math.max(percentBaseline.width, percentCurrent.width) : 0

                width: boxWidth
                height: percentLabel.implicitHeight
                implicitWidth: boxWidth
                implicitHeight: percentLabel.implicitHeight
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
                name: BatteryService.getBatteryIcon()
                size: root.iconSize
                color: root.statusColor
                anchors.verticalCenter: parent.verticalCenter
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
