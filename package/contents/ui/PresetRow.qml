/*
 * Row of quick-pick temperature buttons bound to a role (temp_set / keep_warm_temp).
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

Flow {
    id: flow
    property string role
    property var presets: []
    spacing: Kirigami.Units.smallSpacing

    function label(p) {
        const m = String(p).match(/\d+/)
        return m ? m[0] + "°" : root.humanize(p)
    }

    Repeater {
        model: flow.presets
        delegate: PlasmaComponents3.Button {
            readonly property bool current: String(root.val(flow.role)) === String(root.tempValueFor(flow.role, modelData))
            width: Math.max(implicitWidth, Kirigami.Units.gridUnit * 3)
            text: flow.label(modelData)
            checkable: true
            checked: current
            enabled: root.connected && !root.busy
            onClicked: {
                checked = Qt.binding(() => current)
                root.setRole(flow.role, root.tempValueFor(flow.role, modelData))
            }
        }
    }
}
