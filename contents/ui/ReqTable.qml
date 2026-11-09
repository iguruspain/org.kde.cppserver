// ReqTable.qml – the shared recent-requests grid of the Stats tab.
// Rows arrive already formatted from the stream (Logic.fmtReqRow in
// main.qml); this component owns the i18n header, the per-column text
// measurement, and the stretch that keeps the table filled at any width
// — exactly like GaugeRing/Sparkline own their drawing.
import QtQuick
import Qt.labs.qmlmodels
import org.kde.kirigami as Kirigami

TableView {
    id: reqGrid

    // stream rows: { time, server, status, inTok, reused, outTok, tps, dur }
    required property var streamRows
    // token columns (reused/out) blank out when the tokens toggle is off
    property bool showTokens: true

    interactive: false
    rowSpacing: 1
    columnSpacing: Kirigami.Units.largeSpacing

    // header + masking happen here so the model and the measurement
    // are always built from the same strings, in one pass. NOT bindings:
    // measuring mutates TextMetrics.text, and a binding that mutates
    // properties it also reads (advanceWidth) trips QML's binding-loop
    // detector. recalc() runs from change handlers instead.
    property var modelRows: []
    property var cols: []
    function recalc() {
        modelRows = buildRows()
        cols = measureCols(modelRows)
    }
    onStreamRowsChanged: recalc()
    onShowTokensChanged: recalc()
    Component.onCompleted: recalc()
    function buildRows() {
        var out = [{
            time: i18n("Time"), server: i18n("Server"),
            status: i18n("State"), inTok: i18n("In"),
            reused: i18n("Reused"), outTok: i18n("Out"),
            tps: "t/s", dur: i18n("Dur")
        }]
        streamRows.forEach(function (r) {
            if (!showTokens) {
                r = Object.assign({}, r)
                r.reused = "–"
                r.outTok = ""
            }
            out.push(r)
        })
        return out
    }

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
    // TextMetrics has no line metrics: FontMetrics gives the true line
    // advance for the row height.
    FontMetrics {
        id: fmRow
        font: Kirigami.Theme.smallFont
    }
    readonly property int rowH: Math.ceil(fmRow.lineSpacing) + 4
    // the exact height the grid needs: MainPage assigns it as
    // Layout.preferredHeight so the card never jumps
    readonly property int preferredH: modelRows.length > 0
                                      ? modelRows.length * rowH + modelRows.length - 1
                                      : 0

    // a column is as wide as the widest string actually painted in it
    // (header or any value), measured with its real font. advanceWidth is
    // a TextMetrics PROPERTY fed by `text` — not a callable method.
    function measureCols(mrows) {
        const keys = ["time", "server", "status", "inTok", "reused",
                      "outTok", "tps", "dur"]
        const ws = []
        for (let c = 0; c < keys.length; c = c + 1) {
            const k = keys[c]
            const head = c === 0 ? tmMono : tmHead
            head.text = mrows[0][k]
            let w = head.advanceWidth
            const tm = c === 0 ? tmMono : tmRow
            for (let i = 1; i < mrows.length; i = i + 1) {
                tm.text = mrows[i][k]
                w = Math.max(w, tm.advanceWidth)
            }
            ws.push(Math.ceil(w) + 4)
        }
        return ws
    }

    // final column widths: measured content is the MINIMUM; any width the
    // card has left over is shared proportionally across every column, so
    // the table fills the popup at any size (left text hugs the left,
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

    rowHeightProvider: function () { return reqGrid.rowH }
    columnWidthProvider: function (c) {
        return c < reqGrid.colW.length ? reqGrid.colW[c] : -1
    }

    model: TableModel {
        TableModelColumn { display: "time" }
        TableModelColumn { display: "server" }
        TableModelColumn { display: "status" }
        TableModelColumn { display: "inTok" }
        TableModelColumn { display: "reused" }
        TableModelColumn { display: "outTok" }
        TableModelColumn { display: "tps" }
        TableModelColumn { display: "dur" }
        rows: reqGrid.modelRows
    }

    delegate: Text {
        required property int row
        required property int column
        required property var model
        text: model ? model.display : ""
        font {
            pointSize: Kirigami.Theme.smallFont.pointSize
            family: column === 0 ? "monospace" : Kirigami.Theme.smallFont.family
            bold: row === 0
        }
        // Qt.Align* (not Text.Align*): same values, but the linter cannot
        // confuse the enum with the component's own type name
        horizontalAlignment: column <= 2 ? Qt.AlignLeft : Qt.AlignRight
        opacity: row === 0 ? 0.75 : 1
    }
}
