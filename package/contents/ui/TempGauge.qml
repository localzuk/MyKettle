/*
 * Round temperature dial: arc = current water temperature, tick = target.
 * SPDX-FileCopyrightText: 2026 Tony Ayre <me@tonyayre.net>
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import QtQuick
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

Item {
    id: gauge

    property var value              // current temperature (number or undefined)
    property var target             // target temperature (number or undefined)
    property real minValue: 0
    property real maxValue: 100
    property bool active: false     // heating
    property bool warm: false       // keeping warm
    property string unit: "°C"
    property string caption: ""

    implicitWidth: Kirigami.Units.gridUnit * 10
    implicitHeight: implicitWidth

    readonly property real startAngle: 135      // degrees, clockwise from +x
    readonly property real sweep: 270
    function frac(v) { return Math.max(0, Math.min(1, (Number(v) - minValue) / (maxValue - minValue))) }
    function mix(a, b, t) { return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1) }

    readonly property color cold: "#3daee9"
    readonly property color hot: "#da4453"
    readonly property color arcColor: value === undefined ? Kirigami.Theme.disabledTextColor
                                     : mix(cold, hot, frac(value))

    // animated display value
    property real shown: value === undefined ? minValue : Number(value)
    Behavior on shown { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }

    onShownChanged: canvas.requestPaint()
    onTargetChanged: canvas.requestPaint()
    onArcColorChanged: canvas.requestPaint()

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const w = width, h = height
            const lw = Math.max(6, w * 0.07)
            const r = Math.min(w, h) / 2 - lw
            const cx = w / 2, cy = h / 2
            const a0 = gauge.startAngle * Math.PI / 180
            const a1 = (gauge.startAngle + gauge.sweep) * Math.PI / 180
            ctx.lineCap = "round"
            ctx.lineWidth = lw
            // track
            ctx.strokeStyle = Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
            ctx.beginPath(); ctx.arc(cx, cy, r, a0, a1, false); ctx.stroke()
            // value
            if (gauge.value !== undefined) {
                const av = a0 + gauge.sweep * gauge.frac(gauge.shown) * Math.PI / 180
                ctx.strokeStyle = gauge.arcColor
                ctx.beginPath(); ctx.arc(cx, cy, r, a0, Math.max(a0 + 0.01, av), false); ctx.stroke()
            }
            // target tick
            if (gauge.target !== undefined && gauge.target !== null && !isNaN(Number(gauge.target))) {
                const at = a0 + gauge.sweep * gauge.frac(gauge.target) * Math.PI / 180
                ctx.lineWidth = Math.max(2, lw * 0.35)
                ctx.strokeStyle = Kirigami.Theme.textColor
                ctx.beginPath()
                ctx.moveTo(cx + Math.cos(at) * (r - lw * 0.9), cy + Math.sin(at) * (r - lw * 0.9))
                ctx.lineTo(cx + Math.cos(at) * (r + lw * 0.9), cy + Math.sin(at) * (r + lw * 0.9))
                ctx.stroke()
            }
        }
    }

    Column {
        anchors.centerIn: parent
        spacing: 0
        PlasmaComponents3.Label {
            anchors.horizontalCenter: parent.horizontalCenter
            text: gauge.value === undefined ? "–" : Math.round(gauge.shown) + "°"
            font.pixelSize: gauge.width * 0.24
            font.weight: Font.Light
            font.features: { "tnum": 1 }
        }
        PlasmaComponents3.Label {
            anchors.horizontalCenter: parent.horizontalCenter
            text: gauge.caption
            opacity: 0.8
            width: gauge.width * 0.62
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }
        PlasmaComponents3.Label {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: gauge.target !== undefined && gauge.target !== null
            text: i18n("target %1", Math.round(Number(gauge.target)) + "°")
            opacity: 0.6
            font: Kirigami.Theme.smallFont
        }
    }
}
