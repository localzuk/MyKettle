/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_showTemperature: showTemp.checked
    property alias cfg_notifyReady: notify.checked
    property alias cfg_middleClickToggles: middle.checked
    property alias cfg_confirmStart: confirm.checked
    property alias cfg_pollSeconds: poll.value
    property int cfg_port

    Kirigami.FormLayout {
        QQC2.CheckBox {
            id: showTemp
            Kirigami.FormData.label: i18n("Panel:")
            text: i18n("Show water temperature next to the icon")
        }
        QQC2.CheckBox {
            id: middle
            text: i18n("Middle-click starts / stops heating")
        }
        QQC2.CheckBox {
            id: notify
            Kirigami.FormData.label: i18n("Notifications:")
            text: i18n("Notify me when the water is ready")
        }
        QQC2.CheckBox {
            id: confirm
            Kirigami.FormData.label: i18n("Safety:")
            text: i18n("Ask \"Is there water in the kettle?\" before starting")
        }
        QQC2.SpinBox {
            id: poll
            Kirigami.FormData.label: i18n("Refresh every:")
            from: 2
            to: 120
            textFromValue: (v) => i18np("%1 second", "%1 seconds", v)
            valueFromText: (t) => parseInt(t)
        }
        QQC2.Label {
            text: i18n("While the popup is open or the kettle is heating it refreshes every 1.5 s.")
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            wrapMode: Text.Wrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
        }
    }
}
