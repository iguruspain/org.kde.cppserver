/*
 * SPDX-FileCopyrightText: 2026 cppserver contributors
 * SPDX-License-Identifier: MIT
 */

// Tiny filled line chart for the stats dashboard (strata's history series).
import QtQuick
import org.kde.kirigami as Kirigami

Canvas {
    id: spark

    property var series: []
    property color lineColor: Kirigami.Theme.highlightColor
    readonly property int maxPoints: 90

    implicitHeight: 26
    antialiasing: true

    // The data window slides every second; easing the axis keeps the drawn
    // line from snapping when a spike enters or leaves the series.
    property real viewLo: 0
    property real viewHi: 1
    Behavior on viewLo { NumberAnimation { duration: 350; easing.type: Easing.OutQuad } }
    Behavior on viewHi { NumberAnimation { duration: 350; easing.type: Easing.OutQuad } }

    onSeriesChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onViewLoChanged: requestPaint()
    onViewHiChanged: requestPaint()

    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var src = Array.isArray(series) ? series : []
        if (src.length > maxPoints) {
            src = src.slice(src.length - maxPoints)
        }
        let pts = []
        for (let i = 0; i < src.length; i++) {
            const v = Number(src[i])
            if (isFinite(v)) {
                pts.push({ x: i, v: v })
            }
        }
        if (pts.length < 2) {
            return
        }
        let lo = pts[0].v, hi = pts[0].v
        pts.forEach(function (p) {
            if (p.v < lo) lo = p.v
            if (p.v > hi) hi = p.v
        })
        if (hi <= lo) {
            hi = lo + 1          // flat series: center the line
        }
        // draw with the eased axis: retarget, paint uses the current values
        spark.viewLo = lo
        spark.viewHi = hi
        const n = src.length
        const px = function (idx) { return idx * (width - 2) / Math.max(1, n - 1) + 1 }
        const py = function (v) {
            return height - 2 - (v - spark.viewLo) * (height - 4) / Math.max(1e-6, spark.viewHi - spark.viewLo)
        }

        // soft fill under the line
        ctx.beginPath()
        ctx.moveTo(px(pts[0].x), height)
        pts.forEach(function (p) { ctx.lineTo(px(p.x), py(p.v)) })
        ctx.lineTo(px(pts[pts.length - 1].x), height)
        ctx.closePath()
        ctx.fillStyle = Qt.rgba(lineColor.r, lineColor.g, lineColor.b, 0.13)
        ctx.fill()

        ctx.beginPath()
        pts.forEach(function (p, k) {
            if (k === 0) {
                ctx.moveTo(px(p.x), py(p.v))
            } else {
                ctx.lineTo(px(p.x), py(p.v))
            }
        })
        ctx.strokeStyle = lineColor
        ctx.lineWidth = 1.5
        ctx.stroke()
    }
}
