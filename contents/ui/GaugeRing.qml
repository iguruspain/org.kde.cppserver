/*
 * SPDX-FileCopyrightText: 2026 cppserver contributors
 * SPDX-License-Identifier: MIT
 */

// Ring gauge: percentage inside the ring with its name under the number,
// raw reading under the ring; amber → red past the thresholds.
import QtQuick
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

Item {
    id: gauge

    required property real frac
    property string name: ""
    property string readout: ""
    // optional history strip under the reading (strata's series)
    property var spark: []
    property color sparkColor: Kirigami.Theme.highlightColor
    // stacked sources for the used arc ({ frac, color, label }); when empty
    // the ring shows a plain frac arc
    property var segments: []
    // optional swatch legend under the ring: [{ label, color }]
    property var legend: []
    // tint override; default follows the fill (full/hot rings get louder)
    property color tint: frac > 0.9 ? Kirigami.Theme.negativeTextColor
                       : frac > 0.7 ? Kirigami.Theme.neutralTextColor
                                    : Kirigami.Theme.highlightColor

    readonly property real ringSize: Kirigami.Units.gridUnit * 3.4
    implicitWidth: Math.max(ringSize, subText.width, sparkStrip.width, legendRow.width)
    implicitHeight: ringSize
                      + (gauge.readout !== "" ? subText.height + 2 : 0)
                      + (Array.isArray(gauge.spark) && gauge.spark.length > 1 ? sparkStrip.height + 3 : 0)
                      + (Array.isArray(gauge.legend) && gauge.legend.length > 0 ? legendRow.height + 3 : 0)

    Item {
        id: ring
        anchors.horizontalCenter: parent.horizontalCenter
        width: gauge.ringSize
        height: gauge.ringSize

        Donut {
            anchors.fill: parent
            frac: gauge.frac
            segments: gauge.segments
            ringColor: gauge.tint
        }

        // number + name live inside the ring, ringside-style
        Column {
            anchors.centerIn: parent
            spacing: 0
            PlasmaComponents.Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Math.round(Math.max(0, Math.min(1, gauge.frac)) * 100) + "%"
                color: gauge.tint
                font {
                    pixelSize: Math.round(gauge.ringSize * 0.24)
                    bold: true
                }
            }
            PlasmaComponents.Label {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: gauge.name !== ""
                text: gauge.name
                width: Math.min(implicitWidth, gauge.ringSize * 0.88)
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
                opacity: 0.75
                font {
                    pixelSize: Math.round(gauge.ringSize * 0.15)
                }
            }
        }
    }

    PlasmaComponents.Label {
        id: subText
        anchors.top: ring.bottom
        anchors.topMargin: 2
        anchors.horizontalCenter: parent.horizontalCenter
        visible: gauge.readout !== ""
        width: Math.min(implicitWidth, gauge.ringSize + Kirigami.Units.gridUnit)
        elide: Text.ElideMiddle
        horizontalAlignment: Text.AlignHCenter
        text: gauge.readout !== "" ? gauge.readout : " "
        font: Kirigami.Theme.smallFont
        opacity: 0.65
    }

    Sparkline {
        id: sparkStrip
        anchors.top: subText.bottom
        anchors.topMargin: 3
        anchors.horizontalCenter: parent.horizontalCenter
        visible: Array.isArray(gauge.spark) && gauge.spark.length > 1
        width: Math.max(gauge.ringSize * 0.8, subText.width)
        implicitHeight: 18
        series: gauge.spark
        lineColor: gauge.sparkColor
    }

    Flow {
        id: legendRow
        anchors.top: sparkStrip.bottom
        anchors.topMargin: 3
        anchors.horizontalCenter: parent.horizontalCenter
        visible: Array.isArray(gauge.legend) && gauge.legend.length > 0
        spacing: Kirigami.Units.smallSpacing

        Repeater {
            // model = count, not the array: rowsById updates every second
            // and a fresh array each tick would rebuild (flicker) the rows
            model: Array.isArray(gauge.legend) ? gauge.legend.length : 0
            delegate: Row {
                required property int modelData
                spacing: 3
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 8
                    height: 8
                    radius: 2
                    color: gauge.legend[modelData] ? gauge.legend[modelData].color : "transparent"
                }
                PlasmaComponents.Label {
                    text: gauge.legend[modelData] ? (gauge.legend[modelData].label || "") : ""
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                }
            }
        }
    }
}
