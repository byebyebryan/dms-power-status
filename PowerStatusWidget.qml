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

                readonly property real contentSpacing: Theme.spacingS
                readonly property real percentWidth: Math.max(percentBaseline.width, percentCurrent.width)
                readonly property real wattsWidth: Math.max(wattsBaseline.width, wattsCurrent.width)
                readonly property real etaWidth: Math.max(etaBaseline.width, etaCurrent.width)
                readonly property real separatorWidth: separatorMetrics.width
                readonly property real dynamicWidth: percentWidth + wattsWidth + etaWidth + separatorWidth * 2 + contentSpacing * 4
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

                StyledTextMetrics {
                    id: separatorMetrics

                    text: "•"
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

                    StyledText {
                        visible: root.wattsText.length > 0
                        text: "•"
                        font.pixelSize: root.textSize
                        color: Theme.outlineButton
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

                    StyledText {
                        visible: root.etaText.length > 0
                        text: "•"
                        font.pixelSize: root.textSize
                        color: Theme.outlineButton
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
