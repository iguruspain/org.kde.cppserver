/*
 * SPDX-FileCopyrightText: 2026 cppserver contributors
 * SPDX-License-Identifier: MIT
 */

// Progress ring for the stats dashboard (context fill per server).
import QtQuick
import org.kde.kirigami as Kirigami

Canvas {
    id: donut

    property real frac: 0
    property color ringColor: Kirigami.Theme.highlightColor
    property color trackColor: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                       Kirigami.Theme.textColor.b, 0.15)
    // optional stacked arcs: [{ frac, color }]; when set they replace the
    // single frac arc and show WHERE the used part comes from (per server).
    property var segments: []

    implicitWidth: 64
    implicitHeight: 64
    antialiasing: true

    // fill changes land every second; ease so the ring drifts instead of
    // snapping between probes
    Behavior on frac { NumberAnimation { duration: 350; easing.type: Easing.OutQuad } }

    onFracChanged: requestPaint()
    onSegmentsChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        const lw = Math.max(4, Math.min(width, height) / 9)
        const r = Math.min(width, height) / 2 - lw / 2 - 1
        const cx = width / 2, cy = height / 2
        if (r <= 0) {
            return
        }

        ctx.lineWidth = lw
        ctx.lineCap = "round"
        ctx.strokeStyle = trackColor
        ctx.beginPath()
        ctx.arc(cx, cy, r, 0, 2 * Math.PI)
        ctx.stroke()

        const segs = Array.isArray(segments) ? segments.filter(function (s) {
            return s && Number(s.frac) > 0.003
        }) : []
        if (segs.length > 0) {
            // stacked arcs, tiny gaps between sources, all starting at 12 o'clock
            const gap = segs.length > 1 ? 0.045 : 0
            let a = -Math.PI / 2
            segs.forEach(function (s) {
                const span = Math.min(1, Math.max(0, Number(s.frac))) * 2 * Math.PI
                if (span > gap) {
                    ctx.strokeStyle = s.color
                    ctx.beginPath()
                    ctx.arc(cx, cy, r, a + gap / 2, a + span - gap / 2)
                    ctx.stroke()
                }
                a += span
            })
        } else {
            const f = Math.max(0, Math.min(1, frac))
            if (f > 0.003) {
                ctx.strokeStyle = ringColor
                ctx.beginPath()
                ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + f * 2 * Math.PI)
                ctx.stroke()
            }
        }
    }
}
