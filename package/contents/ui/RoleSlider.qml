/*
 * Fine-grained slider for an Integer temperature role.
 * SPDX-FileCopyrightText: 2026 Tony Ayre <me@tonyayre.net>
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

RowLayout {
    id: rs
    property string role
    readonly property var spec: root.has(role) ? root.roles[role] : ({})

    PlasmaComponents3.Slider {
        id: slider
        Layout.fillWidth: true
        from: rs.spec.min !== undefined ? rs.spec.min : 40
        to: rs.spec.max !== undefined ? rs.spec.max : 100
        stepSize: rs.spec.step || 1
        snapMode: PlasmaComponents3.Slider.SnapAlways
        enabled: root.connected && !root.busy
        readonly property real deviceValue: Number(root.val(rs.role)) || from
        value: deviceValue
        onMoved: sendDelay.restart()
        Timer {
            id: sendDelay
            interval: 500
            onTriggered: {
                root.setRole(rs.role, slider.value)
                slider.value = Qt.binding(() => slider.deviceValue)
            }
        }
    }
    PlasmaComponents3.Label {
        text: Math.round(slider.value) + "°"
        Layout.preferredWidth: Kirigami.Units.gridUnit * 2
        horizontalAlignment: Text.AlignRight
        font.features: { "tnum": 1 }
    }
}
