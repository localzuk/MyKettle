/*
 * Popup: setup guide when not configured, otherwise the kettle controls.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

PlasmaExtras.Representation {
    id: full

    Layout.minimumWidth: Kirigami.Units.gridUnit * 18
    Layout.minimumHeight: Kirigami.Units.gridUnit * 20
    Layout.preferredWidth: Kirigami.Units.gridUnit * 21
    Layout.preferredHeight: Kirigami.Units.gridUnit * 30
    collapseMarginsHint: true

    function num(v) {
        if (v === undefined || v === null) return undefined
        const n = Number(v)
        if (!isNaN(n)) return n
        const m = String(v).match(/\d+/)
        return m ? Number(m[0]) : undefined
    }

    header: PlasmaExtras.PlasmoidHeading {
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Heading {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                level: 3
                text: root.kettleName
                elide: Text.ElideRight
            }
            Rectangle {
                visible: root.ready
                width: Kirigami.Units.smallSpacing * 2
                height: width
                radius: width / 2
                color: root.connected ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor
            }
            PlasmaComponents3.Label {
                visible: root.ready
                text: root.connected ? i18n("Connected") : i18n("Offline")
                opacity: 0.7
            }
            PlasmaComponents3.ToolButton {
                icon.name: "configure"
                display: PlasmaComponents3.AbstractButton.IconOnly
                text: i18n("Configure…")
                onClicked: Plasmoid.internalAction("configure").trigger()
                PlasmaComponents3.ToolTip.text: text
                PlasmaComponents3.ToolTip.visible: hovered
            }
        }
    }

    contentItem: Loader {
        sourceComponent: root.ready ? controls : setup
    }

    // ------------------------------------------------------------- setup
    Component {
        id: setup
        SetupView {}
    }

    // ---------------------------------------------------------- controls
    Component {
        id: controls

        PlasmaComponents3.ScrollView {
            id: scroll
            contentWidth: availableWidth
            QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

            ColumnLayout {
                x: Kirigami.Units.largeSpacing
                width: scroll.availableWidth - Kirigami.Units.largeSpacing * 2
                spacing: Kirigami.Units.largeSpacing

                Kirigami.InlineMessage {
                    Layout.fillWidth: true
                    visible: !root.connected
                    type: Kirigami.MessageType.Warning
                    text: i18n("Can't reach the kettle: %1. The service keeps retrying.", root.st && root.st.error ? root.st.error : i18n("unknown error"))
                    actions: [
                        Kirigami.Action { text: i18n("Restart service"); icon.name: "view-refresh"; onTriggered: root.restartService() },
                        Kirigami.Action { text: i18n("Run setup"); icon.name: "tools-wizard"; onTriggered: root.runSetup() }
                    ]
                }
                Kirigami.InlineMessage {
                    Layout.fillWidth: true
                    visible: root.lastError !== ""
                    type: Kirigami.MessageType.Error
                    text: root.lastError
                    showCloseButton: true
                    onVisibleChanged: if (!visible) root.lastError = ""
                }
                Kirigami.InlineMessage {
                    readonly property var f: root.val("fault")
                    Layout.fillWidth: true
                    visible: root.has("fault") && f !== undefined && f !== 0 && f !== "0" && f !== "" && f !== false && f !== "normal"
                    type: Kirigami.MessageType.Error
                    icon.name: "dialog-warning"
                    text: i18n("The kettle reports a fault (%1). Check that it has water and sits on its base.", String(f))
                }

                TempGauge {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: Kirigami.Units.largeSpacing
                    implicitWidth: Math.min(Kirigami.Units.gridUnit * 11, full.width * 0.6)
                    value: root.has("temp_current") ? full.num(root.tempNow) : undefined
                    target: root.has("temp_set") ? full.num(root.tempTarget) : undefined
                    active: root.heating
                    warm: root.keepingWarm
                    unit: root.unit
                    caption: root.statusText
                }

                PlasmaComponents3.Label {
                    Layout.alignment: Qt.AlignHCenter
                    visible: root.has("remaining") && root.val("remaining") > 0
                    text: i18n("%1 min remaining", root.val("remaining"))
                    opacity: 0.8
                }

                // ---------------------------------------- start / stop
                PlasmaComponents3.Button {
                    id: mainButton
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 13
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 2.4
                    enabled: root.connected && !root.busy
                    icon.name: root.heating ? "media-playback-stop" : "media-playback-start"
                    text: root.heating ? i18n("Stop")
                        : root.has("temp_set") && root.tempTarget !== undefined
                            ? i18n("Heat to %1", root.fmtTemp(full.num(root.tempTarget)) + root.unit.replace("°", ""))
                            : i18n("Boil")
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.2
                    onClicked: {
                        if (root.heating) {
                            root.stopHeating()
                        } else if (Plasmoid.configuration.confirmStart) {
                            confirm.visible = true
                        } else {
                            root.startHeating(root.tempTarget)
                        }
                    }
                }
                Kirigami.InlineMessage {
                    id: confirm
                    Layout.fillWidth: true
                    visible: false
                    type: Kirigami.MessageType.Information
                    text: i18n("Is there water in the kettle?")
                    actions: [
                        Kirigami.Action { text: i18n("Yes, start"); icon.name: "dialog-ok"; onTriggered: { confirm.visible = false; root.startHeating(root.tempTarget) } },
                        Kirigami.Action { text: i18n("Cancel"); icon.name: "dialog-cancel"; onTriggered: confirm.visible = false }
                    ]
                }

                // ---------------------------------------- target temperature
                Kirigami.Separator { Layout.fillWidth: true; visible: root.has("temp_set") }
                Kirigami.Heading {
                    visible: root.has("temp_set")
                    level: 5
                    text: i18n("Temperature")
                    opacity: 0.8
                }
                PresetRow {
                    Layout.fillWidth: true
                    visible: root.has("temp_set")
                    role: "temp_set"
                    presets: root.has("temp_set") && root.roles.temp_set.type === "Enum"
                             ? root.roles.temp_set.range : (root.st ? root.st.boil_presets : [])
                }
                RoleSlider {
                    Layout.fillWidth: true
                    role: "temp_set"
                    visible: root.has("temp_set") && root.roles.temp_set.type === "Integer"
                }

                // ---------------------------------------- keep warm
                Kirigami.Separator {
                    Layout.fillWidth: true
                    visible: root.has("keep_warm") || root.has("keep_warm_temp")
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.has("keep_warm")
                    Kirigami.Icon { source: "temperature-warm"; implicitWidth: Kirigami.Units.iconSizes.smallMedium; implicitHeight: implicitWidth }
                    PlasmaComponents3.Label { text: i18n("Keep warm"); Layout.fillWidth: true }
                    PlasmaComponents3.Switch {
                        checked: root.keepingWarm
                        enabled: root.connected && !root.busy
                        onToggled: root.setRole("keep_warm", checked)
                    }
                }
                PlasmaComponents3.Label {
                    visible: root.has("keep_warm_temp")
                    text: i18n("Keep-warm temperature")
                    opacity: 0.8
                }
                PresetRow {
                    Layout.fillWidth: true
                    visible: root.has("keep_warm_temp")
                    role: "keep_warm_temp"
                    presets: root.has("keep_warm_temp") && root.roles.keep_warm_temp.type === "Enum"
                             ? root.roles.keep_warm_temp.range : (root.st ? root.st.warm_presets : [])
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.has("warm_time")
                    PlasmaComponents3.Label { text: i18n("Keep warm for"); Layout.fillWidth: true }
                    PlasmaComponents3.ComboBox {
                        visible: root.has("warm_time") && root.roles.warm_time.type === "Enum"
                        model: visible ? root.roles.warm_time.range : []
                        currentIndex: visible ? model.indexOf(String(root.val("warm_time"))) : -1
                        onActivated: index => root.setRole("warm_time", model[index])
                    }
                    PlasmaComponents3.SpinBox {
                        visible: root.has("warm_time") && root.roles.warm_time.type === "Integer"
                        from: visible ? (root.roles.warm_time.min || 0) : 0
                        to: visible ? (root.roles.warm_time.max || 720) : 720
                        stepSize: visible ? (root.roles.warm_time.step || 1) : 1
                        value: visible ? (root.val("warm_time") || 0) : 0
                        textFromValue: (v) => v + " " + (root.has("warm_time") && root.roles.warm_time.unit ? root.roles.warm_time.unit : i18n("min"))
                        valueFromText: (t) => parseInt(t)
                        onValueModified: warmDelay.restart()
                        Timer { id: warmDelay; interval: 700; onTriggered: root.setRole("warm_time", parent.value) }
                    }
                }

                // ---------------------------------------- mode
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.has("mode")
                    PlasmaComponents3.Label { text: i18n("Mode"); Layout.fillWidth: true }
                    PlasmaComponents3.ComboBox {
                        id: modeBox
                        model: root.has("mode") ? root.roles.mode.range : []
                        displayText: root.humanize(currentText)
                        currentIndex: root.has("mode") ? model.indexOf(String(root.val("mode"))) : -1
                        onActivated: index => root.setRole("mode", model[index])
                        delegate: PlasmaComponents3.ItemDelegate {
                            width: modeBox.width
                            text: root.humanize(modelData)
                            highlighted: modeBox.highlightedIndex === index
                        }
                    }
                }

                // ---------------------------------------- raw data points
                PlasmaComponents3.ToolButton {
                    id: detailsBtn
                    Layout.alignment: Qt.AlignLeft
                    checkable: true
                    icon.name: checked ? "arrow-down" : "arrow-right"
                    text: i18n("All data points")
                    opacity: 0.8
                }
                ColumnLayout {
                    visible: detailsBtn.checked
                    Layout.fillWidth: true
                    spacing: 0
                    Repeater {
                        model: {
                            if (!root.st || !root.st.dps) return []
                            const byDp = {}
                            for (const r in root.roles) byDp[root.roles[r].dp] = r
                            return Object.keys(root.st.dps).sort((a, b) => Number(a) - Number(b)).map(k => ({
                                dp: k, role: byDp[k] || "", value: JSON.stringify(root.st.dps[k])
                            }))
                        }
                        delegate: Item {
                            Layout.fillWidth: true
                            implicitHeight: dpRow.implicitHeight
                            RowLayout {
                                id: dpRow
                                anchors.fill: parent
                                PlasmaComponents3.Label { text: "DP " + modelData.dp; Layout.preferredWidth: Kirigami.Units.gridUnit * 3; font: Kirigami.Theme.smallFont }
                                PlasmaComponents3.Label { text: modelData.value; Layout.fillWidth: true; elide: Text.ElideRight; font.family: "monospace"; font.pointSize: Kirigami.Theme.smallFont.pointSize }
                                PlasmaComponents3.Label { text: modelData.role; opacity: 0.6; font: Kirigami.Theme.smallFont }
                            }
                        }
                    }
                }
                Item { Layout.fillHeight: true }
            }
        }
    }
}
