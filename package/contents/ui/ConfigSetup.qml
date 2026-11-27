/*
 * Kettle connection page: backend status, wizard, service and port.
 * SPDX-FileCopyrightText: 2026 Tony Ayre <me@tonyayre.net>
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtCore
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.plasma.plasma5support as P5Support

KCM.SimpleKCM {
    id: page
    property alias cfg_port: port.value
    property bool cfg_showTemperature
    property bool cfg_notifyReady
    property bool cfg_middleClickToggles
    property bool cfg_confirmStart
    property int cfg_pollSeconds

    property var st: null
    property bool up: false
    property string doctor: ""

    function refresh() {
        const xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            try { page.st = JSON.parse(xhr.responseText); page.up = xhr.status === 200 }
            catch (e) { page.st = null; page.up = false }
        }
        xhr.open("GET", "http://127.0.0.1:" + port.value + "/api/status")
        xhr.send()
    }
    Component.onCompleted: refresh()
    Timer { interval: 3000; running: true; repeat: true; onTriggered: page.refresh() }

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
            if (source.indexOf("doctor") >= 0) page.doctor = (data.stdout || "") + (data.stderr || "")
            page.refresh()
        }
        function run(cmd) { connectSource(cmd + " #" + Date.now()) }
    }
    readonly property string m: '"$HOME/.local/bin/mykettle"'

    Kirigami.FormLayout {
        Kirigami.Heading {
            Kirigami.FormData.isSection: true
            text: i18n("Status")
            level: 3
        }
        QQC2.Label {
            Kirigami.FormData.label: i18n("Backend service:")
            text: page.up ? i18n("Running (v%1)", page.st.version) : i18n("Not running")
            color: page.up ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor
        }
        QQC2.Label {
            Kirigami.FormData.label: i18n("Kettle:")
            text: !page.up ? "–"
                : !page.st.configured ? i18n("Not set up yet")
                : page.st.connected ? i18n("%1 - connected", page.st.name)
                : i18n("%1 - not reachable (%2)", page.st.name, page.st.error || "?")
            wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
        }
        QQC2.Label {
            Kirigami.FormData.label: i18n("Mapped controls:")
            visible: page.up && page.st.configured
            text: {
                if (!page.st || !page.st.roles) return ""
                return Object.keys(page.st.roles).map(r => r + " → DP " + page.st.roles[r].dp).join("\n")
            }
            font.family: "monospace"
        }

        Kirigami.Heading {
            Kirigami.FormData.isSection: true
            text: i18n("Setup")
            level: 3
        }
        RowLayout {
            Kirigami.FormData.label: i18n("Kettle connection:")
            QQC2.Button {
                icon.name: "tools-wizard"
                text: i18n("Run Setup Wizard…")
                onClicked: exec.run("export MYKETTLE_FROM_WIDGET=1; if command -v konsole >/dev/null; then konsole -e " + page.m +
                                    " setup; else xterm -e " + page.m + " setup; fi")
            }
            QQC2.Button {
                icon.name: "help-contents"
                text: i18n("Setup Guide")
                onClicked: Qt.openUrlExternally(StandardPaths.writableLocation(StandardPaths.GenericDataLocation) + "/mykettle/docs/SETUP.md")
            }
        }
        RowLayout {
            Kirigami.FormData.label: i18n("Service:")
            QQC2.Button {
                icon.name: "view-refresh"
                text: i18n("Restart")
                onClicked: exec.run("systemctl --user enable mykettle.service; systemctl --user restart mykettle.service")
            }
            QQC2.Button {
                icon.name: "checkmark"
                text: i18n("Run Diagnostics")
                onClicked: { page.doctor = i18n("Running…"); exec.run(page.m + " doctor 2>&1; true # doctor") }
            }
        }
        QQC2.TextArea {
            visible: page.doctor !== ""
            Layout.fillWidth: true
            Layout.minimumWidth: Kirigami.Units.gridUnit * 24
            readOnly: true
            text: page.doctor
            font.family: "monospace"
        }

        Kirigami.Heading {
            Kirigami.FormData.isSection: true
            text: i18n("Advanced")
            level: 3
        }
        QQC2.SpinBox {
            id: port
            Kirigami.FormData.label: i18n("Backend port:")
            from: 1024
            to: 65535
            textFromValue: (v) => String(v)
            valueFromText: (t) => parseInt(t)
        }
        QQC2.Label {
            text: i18n("Must match \"port\" in ~/.config/mykettle/config.json (default 8765).")
            opacity: 0.7
            font: Kirigami.Theme.smallFont
        }
    }
}
