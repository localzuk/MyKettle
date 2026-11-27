/*
 * Settings page: MyKettle copyright plus every third-party component and its
 * licence text, read from the installed backend (`mykettle about --json`).
 * SPDX-FileCopyrightText: 2026 Tony Ayre <me@tonyayre.net>
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.plasma.plasma5support as P5Support

KCM.SimpleKCM {
    id: page

    // the dialog injects every config key into every page
    property int cfg_port
    property int cfg_pollSeconds
    property bool cfg_showTemperature
    property bool cfg_notifyReady
    property bool cfg_middleClickToggles
    property bool cfg_confirmStart

    property var info: null          // parsed `mykettle about --json`
    property string loadError: ""
    property int selected: -1
    property string licenceText: ""
    property bool loadingText: false

    readonly property string cmd: '"$HOME/.local/bin/mykettle" about'
    readonly property var current: info && selected >= 0 ? info.components[selected] : null

    function shQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        property var callbacks: ({})
        onNewData: (source, data) => {
            const cb = callbacks[source]
            delete callbacks[source]
            disconnectSource(source)
            if (cb) cb(data["exit code"], data.stdout || "", data.stderr || "")
        }
        function run(c, cb) {
            const id = c + " #" + Date.now()
            callbacks[id] = cb
            connectSource(id)
        }
    }

    Component.onCompleted: {
        exec.run(cmd + " --json", function (code, out, err) {
            try {
                page.info = JSON.parse(out)
            } catch (e) {
                page.loadError = i18n("Couldn't read the component list from the MyKettle backend. Is it installed? Run install.sh, then reopen this page.")
            }
        })
    }

    function show(index) {
        selected = index
        licenceText = ""
        const c = info.components[index]
        if (!c.has_text) return
        loadingText = true
        exec.run(cmd + " --license " + shQuote(c.name), function (code, out, err) {
            loadingText = false
            licenceText = code === 0 ? out : (err || i18n("No licence text found."))
        })
    }

    ColumnLayout {
        spacing: Kirigami.Units.largeSpacing

        // ------------------------------------------------ our own notice
        RowLayout {
            spacing: Kirigami.Units.largeSpacing
            Kirigami.Icon {
                source: "mykettle"
                implicitWidth: Kirigami.Units.iconSizes.large
                implicitHeight: implicitWidth
            }
            ColumnLayout {
                spacing: 0
                Kirigami.Heading {
                    level: 2
                    text: page.info ? i18n("MyKettle %1", page.info.version) : i18n("MyKettle")
                }
                QQC2.Label {
                    text: page.info ? page.info.copyright : "Copyright © 2026 Tony Ayre <me@tonyayre.net>"
                }
            }
        }
        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: i18n("MyKettle is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3 or (at your option) any later version. It comes with ABSOLUTELY NO WARRANTY.")
        }
        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Tuya, Smart Life, SETTI+ and GÖTZE & JENSEN are trademarks of their owners; MyKettle is not affiliated with them.")
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: page.loadError !== ""
            type: Kirigami.MessageType.Warning
            text: page.loadError
        }

        // ------------------------------------------------ component list
        Kirigami.Heading {
            level: 3
            visible: page.info !== null
            text: i18n("Components and licences")
        }
        QQC2.Label {
            visible: page.info !== null
            opacity: 0.7
            text: i18n("Click a component to read its licence.")
        }

        QQC2.BusyIndicator {
            Layout.alignment: Qt.AlignHCenter
            visible: page.info === null && page.loadError === ""
            running: visible
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Repeater {
                model: page.info ? page.info.components : []
                delegate: QQC2.ItemDelegate {
                    id: row
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    highlighted: page.selected === index
                    onClicked: page.show(index)
                    contentItem: RowLayout {
                        spacing: Kirigami.Units.largeSpacing
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            QQC2.Label {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: "<b>" + row.modelData.name + "</b>  " + row.modelData.version
                                textFormat: Text.StyledText
                                color: row.highlighted ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                            }
                            QQC2.Label {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: row.modelData.role
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                color: row.highlighted ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                            }
                        }
                        QQC2.Label {
                            text: row.modelData.license
                            color: row.highlighted ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                        }
                    }
                }
            }
        }

        // ------------------------------------------------ licence viewer
        Kirigami.Separator {
            Layout.fillWidth: true
            visible: page.current !== null
        }
        RowLayout {
            Layout.fillWidth: true
            visible: page.current !== null
            Kirigami.Heading {
                Layout.fillWidth: true
                level: 3
                text: page.current ? i18n("%1 – %2", page.current.name, page.current.license) : ""
                elide: Text.ElideRight
            }
            QQC2.Button {
                visible: page.current && page.current.url !== ""
                icon.name: "internet-services"
                text: i18n("Project website")
                onClicked: Qt.openUrlExternally(page.current.url)
            }
        }
        QQC2.Label {
            Layout.fillWidth: true
            visible: page.current !== null && !page.current.has_text
            wrapMode: Text.Wrap
            text: page.current ? i18n("%1 is provided by your system, not bundled with MyKettle. It is licensed under %2; your distribution ships the full licence text (usually under /usr/share/licenses).", page.current.name, page.current.license) : ""
        }
        QQC2.ScrollView {
            Layout.fillWidth: true
            Layout.preferredHeight: Kirigami.Units.gridUnit * 20
            visible: page.current !== null && page.current.has_text
            QQC2.TextArea {
                readOnly: true
                wrapMode: TextEdit.Wrap
                font.family: "monospace"
                text: page.loadingText ? i18n("Loading…") : page.licenceText
            }
        }
    }
}
