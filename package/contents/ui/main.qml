/*
 * MyKettle - KDE Plasma 6 widget for Tuya / SETTI+ smart kettles.
 * Talks to the local "mykettle" backend service on 127.0.0.1.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
import QtQuick
import QtQuick.Layouts
import QtCore
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5Support

PlasmoidItem {
    id: root

    // ---------------------------------------------------------------- state
    property bool daemonUp: false
    property bool daemonChecked: false
    property bool backendInstalled: true
    property var st: null                    // last /api/status reply
    property string lastError: ""
    property bool busy: false
    property real userStoppedAt: 0

    readonly property bool configured: !!(st && st.configured)
    readonly property bool connected: !!(st && st.connected)
    readonly property var roles: st && st.roles ? st.roles : ({})
    readonly property string kettleName: st && st.name ? st.name : i18n("Kettle")
    readonly property bool heating: val("power") === true
    readonly property bool keepingWarm: val("keep_warm") === true
    readonly property var tempNow: val("temp_current")
    readonly property var tempTarget: val("temp_set")
    readonly property string unit: (has("temp_current") && roles.temp_current.unit) ? roles.temp_current.unit
                                 : (has("temp_set") && roles.temp_set.unit) ? roles.temp_set.unit : "°C"
    readonly property bool ready: daemonUp && configured
    readonly property string scriptPath: '"$HOME/.local/bin/mykettle"'
    readonly property string baseUrl: "http://127.0.0.1:" + Plasmoid.configuration.port

    function has(role) { return !!(roles && roles[role]) }
    function val(role) { return has(role) ? roles[role].value : undefined }
    function fmtTemp(t) {
        if (t === undefined || t === null || t === "") return "–"
        const n = Number(t)
        return isNaN(n) ? String(t) : (Math.round(n) + "°")
    }
    function humanize(s) {
        if (s === undefined || s === null) return ""
        s = String(s).replace(/_/g, " ")
        return s.charAt(0).toUpperCase() + s.slice(1)
    }

    readonly property string statusText: {
        if (!daemonChecked) return i18n("Connecting…")
        if (!backendInstalled) return i18n("Backend not installed")
        if (!daemonUp) return i18n("Background service is not running")
        if (!configured) return i18n("Setup required")
        if (!connected) return i18n("Can't reach the kettle")
        if (heating) {
            return has("temp_set") && tempTarget !== undefined
                ? i18n("Heating to %1", fmtTemp(tempTarget) + unit.replace("°", ""))
                : i18n("Heating")
        }
        if (keepingWarm) {
            return has("keep_warm_temp") ? i18n("Keeping warm at %1", fmtTemp(val("keep_warm_temp")) + unit.replace("°", ""))
                                         : i18n("Keeping warm")
        }
        if (has("status") && val("status") !== undefined) return humanize(val("status"))
        return i18n("Idle")
    }

    // ------------------------------------------------------- plasmoid setup
    Plasmoid.icon: "mykettle"
    Plasmoid.title: kettleName
    Plasmoid.status: (heating || keepingWarm || !ready) ? PlasmaCore.Types.ActiveStatus : PlasmaCore.Types.PassiveStatus
    toolTipMainText: kettleName
    toolTipSubText: {
        let s = statusText
        if (ready && connected && tempNow !== undefined) s = i18n("Water: %1", fmtTemp(tempNow) + unit.replace("°", "")) + "\n" + s
        if (ready && connected && Plasmoid.configuration.middleClickToggles)
            s += "\n" + (heating ? i18n("Middle-click to stop") : i18n("Middle-click to start"))
        return s
    }
    switchWidth: Kirigami.Units.gridUnit * 12
    switchHeight: Kirigami.Units.gridUnit * 12

    compactRepresentation: CompactRepresentation {}
    fullRepresentation: FullRepresentation {}

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: root.heating ? i18n("Stop heating") : i18n("Start heating")
            icon.name: root.heating ? "media-playback-stop" : "media-playback-start"
            enabled: root.ready && root.connected
            onTriggered: root.togglePower()
        },
        PlasmaCore.Action {
            text: i18n("Run Setup Wizard…")
            icon.name: "tools-wizard"
            onTriggered: root.runSetup()
        },
        PlasmaCore.Action {
            text: i18n("Restart Backend Service")
            icon.name: "view-refresh"
            onTriggered: root.restartService()
        },
        PlasmaCore.Action {
            text: i18n("Open Setup Guide")
            icon.name: "help-contents"
            onTriggered: root.openGuide()
        }
    ]

    // ------------------------------------------------------------ backend API
    function api(method, path, body, cb) {
        const xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            let data = null
            try { data = JSON.parse(xhr.responseText) } catch (e) { }
            if (cb) cb(xhr.status, data)
        }
        xhr.open(method, baseUrl + path)
        if (method === "POST") {
            xhr.setRequestHeader("X-MyKettle", "1")
            xhr.setRequestHeader("Content-Type", "application/json")
        }
        xhr.send(body ? JSON.stringify(body) : null)
    }

    function refresh() {
        api("GET", "/api/status", null, function (code, data) {
            daemonChecked = true
            if (code === 200 && data) {
                daemonUp = true
                backendInstalled = true
                const wasHeating = heating
                st = data
                checkReady(wasHeating)
            } else {
                daemonUp = false
                checkBackend()
            }
        })
    }

    function setValues(values) {
        busy = true
        lastError = ""
        api("POST", "/api/set", { values: values }, function (code, data) {
            busy = false
            if (code !== 200 || !data || !data.ok) {
                lastError = data && data.error ? data.error : i18n("Backend did not answer")
            }
            quickRefresh.restart()
        })
    }

    function setRole(role, value) {
        const v = {}
        v[role] = value
        setValues(v)
    }

    // value suitable for an Integer or Enum temperature role
    function tempValueFor(role, t) {
        const r = roles[role]
        if (!r || r.type !== "Enum") return Number(t)
        const range = r.range || []
        const s = String(t)
        if (range.indexOf(s) >= 0) return s
        for (let i = 0; i < range.length; ++i) {
            if (String(range[i]).match(/\d+/) && String(range[i]).match(/\d+/)[0] === s) return range[i]
        }
        return s
    }

    function startHeating(t) {
        const v = {}
        if (t !== undefined && t !== null && has("temp_set")) v.temp_set = tempValueFor("temp_set", t)
        v.power = true
        setValues(v)
    }
    function stopHeating() {
        userStoppedAt = Date.now()
        setValues({ power: false })
    }
    function togglePower() {
        if (!ready || !connected) return
        if (heating) stopHeating()
        else startHeating(tempTarget)
    }

    // "water is ready" notification
    function checkReady(wasHeating) {
        if (!Plasmoid.configuration.notifyReady || !connected) return
        if (wasHeating && !heating && Date.now() - userStoppedAt > 15000) {
            const t = tempNow !== undefined ? fmtTemp(tempNow) + unit.replace("°", "") : ""
            notify(i18n("Your water is ready"), t ? i18n("%1 is at %2", kettleName, t) : kettleName)
        }
    }

    // ------------------------------------------------------ shell commands
    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        property var callbacks: ({})
        onNewData: (sourceName, data) => {
            const cb = callbacks[sourceName]
            delete callbacks[sourceName]
            disconnectSource(sourceName)
            if (cb) cb(data["exit code"], data["stdout"] || "", data["stderr"] || "")
        }
        function run(cmd, cb) {
            // a unique suffix lets the same command run again while one is still open
            const id = cmd + " #" + Date.now() + Math.random()
            callbacks[id] = cb
            connectSource(id)
        }
    }

    function shQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    function checkBackend() {
        exec.run("test -x " + scriptPath + " && echo yes || echo no", function (code, out) {
            backendInstalled = out.trim() === "yes"
        })
    }
    function runSetup() {
        const m = scriptPath
        exec.run("export MYKETTLE_FROM_WIDGET=1; " +
                 "if command -v konsole >/dev/null; then konsole --hide-menubar -p tabtitle=MyKettle -e " + m + " setup; " +
                 "elif command -v kgx >/dev/null; then kgx -- " + m + " setup; " +
                 "elif command -v gnome-terminal >/dev/null; then gnome-terminal -- " + m + " setup; " +
                 "else xterm -e " + m + " setup; fi", function () { refresh() })
    }
    function startService() {
        exec.run("systemctl --user enable --now mykettle.service", function () { quickRefresh.restart() })
    }
    function restartService() {
        exec.run("systemctl --user restart mykettle.service", function () { quickRefresh.restart() })
    }
    function openGuide() {
        Qt.openUrlExternally(StandardPaths.writableLocation(StandardPaths.GenericDataLocation) + "/mykettle/docs/SETUP.md")
    }
    function notify(title, body) {
        const t = shQuote(title), b = shQuote(body)
        exec.run("notify-send -a MyKettle -i mykettle " + t + " " + b + " || " +
                 "gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications " +
                 "--method org.freedesktop.Notifications.Notify MyKettle 0 mykettle " + t + " " + b + " '[]' '{}' 8000", null)
    }

    // --------------------------------------------------------------- timers
    Timer {
        id: poll
        interval: root.expanded || root.heating ? 1500 : Math.max(2, Plasmoid.configuration.pollSeconds) * 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
    Timer {
        id: quickRefresh
        interval: 400
        onTriggered: root.refresh()
    }
    onExpandedChanged: if (expanded) refresh()
}
