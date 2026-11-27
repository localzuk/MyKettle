/*
 * First-run guide shown in the popup until the backend is installed,
 * running and configured.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

PlasmaComponents3.ScrollView {
    id: view
    contentWidth: availableWidth
    QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

    // 1 = install backend, 2 = start service, 3 = run wizard
    readonly property int stage: !root.backendInstalled ? 1 : !root.daemonUp ? 2 : 3

    component Step: RowLayout {
        id: step
        property int number
        property string title
        property string body
        property bool done: view.stage > number
        property bool current: view.stage === number
        default property alias extra: extraCol.data
        Layout.fillWidth: true
        spacing: Kirigami.Units.largeSpacing
        opacity: done || current ? 1 : 0.55

        Rectangle {
            Layout.alignment: Qt.AlignTop
            width: Kirigami.Units.gridUnit * 1.6
            height: width
            radius: width / 2
            color: step.done ? Kirigami.Theme.positiveBackgroundColor
                 : step.current ? Kirigami.Theme.highlightColor : "transparent"
            border.color: step.done ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.highlightColor
            border.width: 1
            PlasmaComponents3.Label {
                anchors.centerIn: parent
                text: step.done ? "✓" : step.number
                color: step.current ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                font.bold: true
            }
        }
        ColumnLayout {
            id: extraCol
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: step.title
                font.bold: true
                wrapMode: Text.Wrap
            }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: step.body
                wrapMode: Text.Wrap
                textFormat: Text.StyledText
                opacity: 0.85
                onLinkActivated: link => Qt.openUrlExternally(link)
            }
        }
    }

    ColumnLayout {
        x: Kirigami.Units.largeSpacing
        width: view.availableWidth - Kirigami.Units.largeSpacing * 2
        spacing: Kirigami.Units.largeSpacing * 1.5

        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing
            Kirigami.Icon {
                Layout.alignment: Qt.AlignHCenter
                source: "mykettle"
                implicitWidth: Kirigami.Units.iconSizes.huge
                implicitHeight: implicitWidth
            }
            Kirigami.Heading {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                level: 2
                text: root.daemonChecked ? i18n("Let's connect your kettle") : i18n("Looking for the MyKettle service…")
                wrapMode: Text.Wrap
            }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                opacity: 0.8
                text: i18n("MyKettle controls Tuya-based kettles such as the GÖTZE & JENSEN KT975K (SETTI+ app) directly over your home network.")
            }
        }

        Step {
            number: 1
            title: i18n("Install the backend")
            body: done ? i18n("Installed.")
                       : i18n("Open a terminal in the MyKettle folder you downloaded and run <b>./install.sh</b>. It sets up a small background service (Python + tinytuya) in your home folder - no root needed.")
        }

        Step {
            number: 2
            title: i18n("Start the background service")
            body: done ? i18n("Running.")
                       : i18n("The service <b>mykettle.service</b> is not running.")
            PlasmaComponents3.Button {
                visible: view.stage === 2
                icon.name: "media-playback-start"
                text: i18n("Start service")
                onClicked: root.startService()
            }
        }

        Step {
            number: 3
            title: i18n("Run the setup wizard")
            body: i18n("The wizard opens in a terminal and walks you through everything (about 10 minutes, once):") + "<br/>" +
                  i18n("• get the kettle's <b>Local Key</b> using a free <a href=\"https://platform.tuya.com\">Tuya developer account</a> (the SETTI+ app doesn't show it)") + "<br/>" +
                  i18n("• find the kettle on your Wi-Fi") + "<br/>" +
                  i18n("• match the kettle's data points to the widget's buttons")
            PlasmaComponents3.Button {
                visible: view.stage === 3
                icon.name: "tools-wizard"
                text: i18n("Run setup wizard…")
                onClicked: root.runSetup()
            }
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: true
            type: Kirigami.MessageType.Information
            text: i18n("Tip: keep the phone app closed while the wizard runs - the kettle only accepts a few local connections. When the wizard finishes, this widget connects by itself.")
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            PlasmaComponents3.Button {
                icon.name: "help-contents"
                text: i18n("Full setup guide")
                onClicked: root.openGuide()
            }
            PlasmaComponents3.Button {
                icon.name: "view-refresh"
                text: i18n("Check again")
                onClicked: root.refresh()
            }
        }
        Item { Layout.fillHeight: true }
    }
}
