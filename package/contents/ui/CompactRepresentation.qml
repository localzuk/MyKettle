/*
 * Panel / tray icon: kettle glyph, live water temperature, colour by state.
 * Left click opens the popup; middle click starts/stops heating.
 * SPDX-FileCopyrightText: 2026 Tony Ayre <me@tonyayre.net>
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

MouseArea {
    id: compact

    readonly property bool horizontal: Plasmoid.formFactor === PlasmaCore.Types.Horizontal
    readonly property bool inPanel: Plasmoid.formFactor === PlasmaCore.Types.Horizontal
                                    || Plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property bool showText: Plasmoid.configuration.showTemperature && root.ready && root.connected
                                     && root.tempNow !== undefined && horizontal
    readonly property color stateColor: !root.ready || (root.daemonUp && !root.connected) ? Kirigami.Theme.disabledTextColor
                                      : root.heating ? Kirigami.Theme.negativeTextColor
                                      : root.keepingWarm ? Kirigami.Theme.neutralTextColor
                                      : Kirigami.Theme.textColor

    Layout.minimumWidth: horizontal ? row.implicitWidth : Kirigami.Units.iconSizes.small
    Layout.minimumHeight: horizontal ? Kirigami.Units.iconSizes.small : width

    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    hoverEnabled: true
    property bool wasExpanded: false
    onPressed: wasExpanded = root.expanded
    onClicked: mouse => {
        if (mouse.button === Qt.MiddleButton && Plasmoid.configuration.middleClickToggles) {
            root.togglePower()
        } else {
            root.expanded = !wasExpanded
        }
    }

    RowLayout {
        id: row
        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing

        Item {
            Layout.fillHeight: true
            Layout.preferredWidth: compact.horizontal ? height : compact.width
            Layout.fillWidth: !compact.horizontal

            Kirigami.Icon {
                id: glyph
                anchors.fill: parent
                source: Qt.resolvedUrl("../icons/kettle-symbolic.svg")
                isMask: true
                color: compact.stateColor
                active: compact.containsMouse

                SequentialAnimation on opacity {
                    running: root.heating
                    loops: Animation.Infinite
                    alwaysRunToEnd: true
                    NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
                }
            }

            // temperature badge for vertical panels / desktop
            Rectangle {
                visible: Plasmoid.configuration.showTemperature && !compact.horizontal
                         && root.ready && root.connected && root.tempNow !== undefined
                anchors { right: parent.right; bottom: parent.bottom }
                width: badgeText.implicitWidth + Kirigami.Units.smallSpacing * 2
                height: badgeText.implicitHeight
                radius: height / 2
                color: root.heating ? Kirigami.Theme.negativeBackgroundColor : Kirigami.Theme.backgroundColor
                opacity: 0.9
                PlasmaComponents3.Label {
                    id: badgeText
                    anchors.centerIn: parent
                    text: root.fmtTemp(root.tempNow)
                    font: Kirigami.Theme.smallFont
                }
            }

            // "needs attention" marker
            Kirigami.Icon {
                visible: root.daemonChecked && (!root.ready || !root.connected)
                anchors { right: parent.right; bottom: parent.bottom }
                width: Math.round(parent.width / 2.2)
                height: width
                source: root.ready ? "network-disconnect" : "dialog-warning"
            }
        }

        PlasmaComponents3.Label {
            visible: compact.showText
            text: root.fmtTemp(root.tempNow)
            color: compact.stateColor
            Layout.fillHeight: true
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: Math.max(Kirigami.Theme.defaultFont.pixelSize, Math.round(compact.height * 0.45))
            font.features: { "tnum": 1 }
        }
    }
}
