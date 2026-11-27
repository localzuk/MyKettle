/*
 * SPDX-FileCopyrightText: 2026 Tony Ayre <me@tonyayre.net>
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("General")
        icon: "configure"
        source: "ConfigGeneral.qml"
    }
    ConfigCategory {
        name: i18n("Kettle Setup")
        icon: "mykettle"
        source: "ConfigSetup.qml"
    }
    ConfigCategory {
        name: i18n("Licences")
        icon: "license"
        source: "ConfigLicences.qml"
    }
}
