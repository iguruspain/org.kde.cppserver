// ReqTable.qml – the measured request grid embedded in each Stats card.
// Generic on purpose: the caller declares the columns — { key, title,
// mono, right, errKey } — and feeds rows already formatted per key
// (Logic.serverReqFeed for the text servers, the backend's audio feed for
// audio.cpp). This component owns the per-column text measurement and the
// stretch that keeps the grid filled at any width — exactly like
// GaugeRing/Sparkline own their drawing. The header is part of the grid:
// measurement and painting walk the same strings, so they never disagree.
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

pragma ComponentBehavior: Bound

Item {
    id: reqGrid

    // [{ key, title, mono, right, errKey }] — titles arrive already i18n'd;
    // a column whose rows carry a truthy row[errKey] flag paints negative
    required property var columns
    // data rows: objects keyed by column key, values already formatted
    // strings (masking included) by whoever built the feed
    required property var rows

    property int columnSpacing: Kirigami.Units.largeSpacing
    property int rowSpacing: 1

    // TextMetrics has no line metrics: FontMetrics gives the true line
    // advance for the row height.
    FontMetrics {
        id: fmRow
        font: Kirigami.Theme.smallFont
    }
    readonly property int rowH: Math.ceil(fmRow.lineSpacing) + 4
    // the exact height the grid needs (header + rows): MainPage assigns
    // it as Layout.preferredHeight so the card never jumps
    readonly property int preferredH: allRows.length > 0
                                      ? allRows.length * rowH + (allRows.length - 1) * rowSpacing
                                      : 0
    implicitHeight: preferredH

    // header + data in ONE array (header first). NOT bindings: measuring
    // mutates TextMetrics.text, and a binding that mutates properties it
    // also reads (advanceWidth) trips QML's binding-loop detector.
    // recalc() runs from change handlers instead.
    property var allRows: []
    property var cols: []
    function recalc() {
        if (!Array.isArray(columns)) {
            allRows = []
            cols = []
            return
        }
        var head = {}
        columns.forEach(function (c) { head[c.key] = c.title })
        allRows = [head].concat(Array.isArray(rows) ? rows : [])
        cols = measureCols(allRows)
    }
    onColumnsChanged: recalc()
    onRowsChanged: recalc()
    Component.onCompleted: recalc()

    TextMetrics {
        id: tmRow
        font: Kirigami.Theme.smallFont
    }
    TextMetrics {
        id: tmHead
        font {
            family: Kirigami.Theme.smallFont.family
            pointSize: Kirigami.Theme.smallFont.pointSize
            bold: true
        }
    }
    TextMetrics {
        id: tmMono
        font {
            family: "monospace"
            pointSize: Kirigami.Theme.smallFont.pointSize
        }
    }

    // a column is as wide as the widest string actually painted in it
    // (header or any value), measured with its real font. advanceWidth is
    // a TextMetrics PROPERTY fed by `text` — not a callable method.
    function measureCols(mrows) {
        const ws = []
        for (let c = 0; c < columns.length; c = c + 1) {
            const def = columns[c]
            const head = def.mono ? tmMono : tmHead
            head.text = mrows[0][def.key]
            let w = head.advanceWidth
            const tm = def.mono ? tmMono : tmRow
            for (let i = 1; i < mrows.length; i = i + 1) {
                tm.text = mrows[i][def.key]
                w = Math.max(w, tm.advanceWidth)
            }
            ws.push(Math.ceil(w) + 4)
        }
        return ws
    }

    // final column widths: measured content is the MINIMUM; any width the
    // card has left over is shared proportionally across every column, so
    // the grid fills the card at any size (left text hugs the left,
    // right-aligned numbers hug each column's right edge) and reflows on
    // every resize
    readonly property var colW: {
        if (!cols || cols.length === 0) return []
        if (width <= 0) return cols
        const sum = cols.reduce(function (a, w) { return a + w }, 0)
        const gap = width - sum - columnSpacing * (cols.length - 1)
        if (gap <= 0) return cols
        const out = []
        let left = gap
        for (let i = 0; i < cols.length - 1; i = i + 1) {
            const add = Math.round(gap * cols[i] / sum)
            out.push(cols[i] + add)
            left = left - add
        }
        out.push(cols[cols.length - 1] + left) // absorb rounding
        return out
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: reqGrid.rowSpacing

        Repeater {
            model: reqGrid.allRows
            delegate: RowLayout {
                id: rowItem
                required property var modelData
                required property int index
                Layout.fillWidth: true
                Layout.preferredHeight: reqGrid.rowH
                spacing: reqGrid.columnSpacing

                Repeater {
                    model: reqGrid.columns
                    delegate: Text {
                        required property var modelData // column definition
                        required property int index
                        text: rowItem.modelData[modelData.key] !== undefined
                              ? rowItem.modelData[modelData.key] : ""
                        // plain Text items do not inherit the Plasma palette:
                        // without this the grid paints black-on-dark
                        color: modelData.errKey && rowItem.modelData[modelData.errKey]
                               ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                        font {
                            pointSize: Kirigami.Theme.smallFont.pointSize
                            family: modelData.mono ? "monospace" : Kirigami.Theme.smallFont.family
                            bold: rowItem.index === 0
                        }
                        // Qt.Align* (not Text.Align*): same values, but the
                        // linter cannot confuse the enum with the component's
                        // own type name
                        horizontalAlignment: modelData.right ? Qt.AlignRight : Qt.AlignLeft
                        opacity: rowItem.index === 0 ? 0.75 : 1
                        Layout.preferredWidth: index < reqGrid.colW.length ? reqGrid.colW[index] : 0
                    }
                }
            }
        }
    }
}
