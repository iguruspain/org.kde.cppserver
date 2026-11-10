/*
 * SPDX-FileCopyrightText: 2026 cppserver contributors
 * SPDX-License-Identifier: MIT
 */

// Ring gauge: percentage inside the ring with its name under the number,
// raw reading under the ring; amber → red past the thresholds.
import QtQuick
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

pragma ComponentBehavior: Bound

Item {
    id: gauge

    required property real frac
    property string name: ""
    property string readout: ""
    // stacked sources for the used arc ({ frac, color, label }); when empty
    // the ring shows a plain frac arc
    property var segments: []
    // optional swatch legend under the ring: [{ label, color }]. The machine
    // ring block has no inner legend: its bands (rings / legend row /
    // sparklines) are laid out by the caller's grid, which is what keeps
    // every row aligned across all columns.
    property var legend: []
    // legend hangs from the ring's right edge instead of centering: used
    // for the card rings, which sit at the card's right edge and would
    // otherwise spill a centered legend past the popup
    property bool legendRight: false
    // tint override; default follows the fill (full/hot rings get louder)
    property color tint: frac > 0.9 ? Kirigami.Theme.negativeTextColor
                       : frac > 0.7 ? Kirigami.Theme.neutralTextColor
                                    : Kirigami.Theme.highlightColor

    readonly property real ringSize: Kirigami.Units.gridUnit * 3.4
    // implicit width reserves only the ring itself: readout and legend are
    // as wide as whatever cell width the grid assigned (Layout.fillWidth
    // stretches the cells to fill the popup) and wrap inside it
    implicitWidth: ringSize
    implicitHeight: ringSize
                      + (gauge.readout !== "" ? subText.height + 2 : 0)
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
                // a real-but-tiny fill (llama: 636 of a 131k context) must
                // not round to a flat "0%" — "<1%" keeps it honest
                text: {
                    var f = Math.max(0, Math.min(1, gauge.frac))
                    if (f > 0 && f < 0.005) return "<1%"
                    return Math.round(f * 100) + "%"
                }
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

    // theme fonts carry pointSize, not pixelSize: measure with FontMetrics
    // so the reserved readout height is never a negative -1-based number
    FontMetrics {
        id: subFont
        font: Kirigami.Theme.smallFont
    }

    PlasmaComponents.Label {
        id: subText
        anchors.top: ring.bottom
        anchors.topMargin: 2
        anchors.horizontalCenter: parent.horizontalCenter
        visible: gauge.readout !== ""
        // the readout stretches across the cell the grid assigned to this
        // ring; when the text is longer than the cell it wraps to two
        // lines and only then elides
        width: gauge.readout !== "" ? Math.max(ring.width, gauge.width) : ring.width
        height: gauge.readout !== "" ? Math.ceil(2 * subFont.height) : 0
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: gauge.readout !== "" ? gauge.readout : " "
        font: Kirigami.Theme.smallFont
        opacity: 0.65
    }

    Flow {
        id: legendRow
        anchors.top: subText.bottom
        anchors.topMargin: 3
        // centered under the ring by default; with legendRight it hangs
        // from the ring's right edge (the card rings sit flush right and a
        // centered legend would spill past the popup)
        x: gauge.legendRight ? gauge.width - implicitWidth
                             : (gauge.width - implicitWidth) / 2
        visible: Array.isArray(gauge.legend) && gauge.legend.length > 0
        spacing: Kirigami.Units.smallSpacing

        Repeater {
            // model = count, not the array: rowsById updates every second
            // and a fresh array each tick would rebuild (flicker) the rows
            model: Array.isArray(gauge.legend) ? gauge.legend.length : 0
            delegate: Row {
                id: legendItem
                required property int modelData
                spacing: 3
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 8
                    height: 8
                    radius: 2
                    color: gauge.legend[legendItem.modelData] ? gauge.legend[legendItem.modelData].color : "transparent"
                }
                PlasmaComponents.Label {
                    text: gauge.legend[legendItem.modelData] ? (gauge.legend[legendItem.modelData].label || "") : ""
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                }
            }
        }
    }
}
