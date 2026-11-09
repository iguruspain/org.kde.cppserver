// MainPage.qml – Servers / Logs tabs of the widget popup.
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras

import "logic.js" as Logic

ColumnLayout {
    id: page
    spacing: 0

    // The PlasmoidItem from main.qml (passed explicitly, no implicit `root`).
    required property var backend

    PlasmaComponents.TabBar {
        id: tabBar
        Layout.fillWidth: true
        currentIndex: page.backend.activeTab
        onCurrentIndexChanged: {
            page.backend.activeTab = currentIndex
            page.backend.persistUiState()
            if (currentIndex === 1) page.backend.tailLog()
            if (currentIndex === 2) page.backend.pollStats()
        }
        PlasmaComponents.TabButton { icon.name: "system-run";    text: i18n("Servers") }
        PlasmaComponents.TabButton { icon.name: "view-history";  text: i18n("Logs") }
        PlasmaComponents.TabButton { icon.name: "speedometer-symbolic"; text: i18n("Stats") }
    }

    StackLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        currentIndex: tabBar.currentIndex

        // ═════════════════════ TAB 0 – Servers ═════════════════════
        ColumnLayout {
            id: serversTab
            spacing: 0
            property string filterText: ""

            RowLayout {
                Layout.fillWidth: true
                spacing: 0
                PlasmaExtras.SearchField {
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                    visible: page.backend.servers.length > 4
                    placeholderText: i18n("Search server...")
                    onTextChanged: serversTab.filterText = text.toLowerCase()
                }
                Item { Layout.fillWidth: true; visible: page.backend.servers.length <= 4 }
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    display: QQC2.AbstractButton.IconOnly
                    onClicked: page.backend.refreshAll()
                    PlasmaComponents.ToolTip { text: i18n("Reload configuration and status") }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "configure"
                    display: QQC2.AbstractButton.IconOnly
                    onClicked: page.backend.openConfig()
                    PlasmaComponents.ToolTip { text: i18n("Configure servers…") }
                }
            }

            PlasmaComponents.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    id: serverList
                    clip: true
                    model: page.backend.servers.filter(function (s) {
                        return serversTab.filterText === ""
                            || s.name.toLowerCase().indexOf(serversTab.filterText) !== -1
                    })

                    delegate: PlasmaComponents.ItemDelegate {
                        id: del
                        required property var modelData
                        width: ListView.view.width
                        height: Kirigami.Units.gridUnit * 3.6
                        hoverEnabled: true
                        onClicked: if (running) page.backend.showLogs(sid)

                        readonly property string sid: modelData.id
                        readonly property bool running: !!page.backend.runningMap[sid]
                        readonly property bool starting: !!page.backend.pendingStarts[sid]
                        readonly property bool stopping: !!page.backend.pendingStops[sid]
                        readonly property bool busy: starting || stopping
                        readonly property string binary: Logic.serverBinary(modelData.command, page.backend.homeDir)
                        readonly property bool binaryOk: page.backend.depsMap[binary] !== false
                        readonly property string url: Logic.browserUrl(modelData)

                        contentItem: RowLayout {
                            spacing: Kirigami.Units.largeSpacing

                            // status dot
                            Rectangle {
                                Layout.alignment: Qt.AlignVCenter
                                implicitWidth: Kirigami.Units.gridUnit * 0.7
                                implicitHeight: implicitWidth
                                radius: width / 2
                                color: del.busy ? Kirigami.Theme.neutralTextColor
                                     : del.running ? Kirigami.Theme.positiveTextColor
                                     : !del.binaryOk ? Kirigami.Theme.negativeTextColor
                                     : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                               Kirigami.Theme.textColor.b, 0.3)
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    text: del.modelData.name || i18n("(unnamed)")
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    font: Kirigami.Theme.smallFont
                                    opacity: 0.7
                                    color: !del.binaryOk ? Kirigami.Theme.negativeTextColor
                                                         : Kirigami.Theme.textColor
                                    text: {
                                        if (!del.binaryOk) return i18n("Not found in PATH: %1", del.binary)
                                        var parts = []
                                        var ep = Logic.endpointText(del.modelData)
                                        if (ep) parts.push(ep)
                                        if (del.binary) parts.push(del.binary.split("/").pop())
                                        //if (del.running) parts.push(i18n("pid %1", page.backend.runningMap[del.sid].pid))
                                        return parts.join("  •  ")
                                    }
                                }
                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    text: {
                                        var parts = []
                                        if (del.running) parts.push(i18n("pid %1", page.backend.runningMap[del.sid].pid))
                                        return parts.join("  •  ")
                                    }
                                    font: Kirigami.Theme.smallFont
                                    opacity: 0.7
                                    elide: Text.ElideRight
                                }
                            }

                            PlasmaComponents.ToolButton {
                                visible: del.running && del.url !== ""
                                icon.name: "internet-web-browser-symbolic"
                                display: QQC2.AbstractButton.IconOnly
                                onClicked: Qt.openUrlExternally(del.url)
                                PlasmaComponents.ToolTip { text: i18n("Open %1", del.url) }
                            }
                            PlasmaComponents.ToolButton {
                                icon.name: "view-history"
                                display: QQC2.AbstractButton.IconOnly
                                onClicked: page.backend.showLogs(del.sid)
                                PlasmaComponents.ToolTip { text: i18n("Show logs") }
                            }
                            PlasmaComponents.Button {
                                Layout.minimumWidth: Kirigami.Units.gridUnit * 6
                                icon.name: del.running ? "media-playback-stop" : "media-playback-start"
                                text: del.stopping ? i18n("Stopping…")
                                    : del.starting ? i18n("Starting…")
                                    : del.running ? i18n("Stop") : i18n("Start")
                                highlighted: del.running
                                enabled: !del.busy && (del.running || del.binaryOk)
                                onClicked: del.running ? page.backend.stopServer(del.sid)
                                                       : page.backend.startServer(del.sid)
                            }
                        }
                    }

                    Kirigami.PlaceholderMessage {
                        anchors.centerIn: parent
                        width: parent.width - Kirigami.Units.gridUnit * 2
                        visible: serverList.count === 0 && !page.backend.loading
                        icon.name: serversTab.filterText !== "" ? "edit-find" : "network-server"
                        text: serversTab.filterText !== "" ? i18n("No servers match")
                                                           : i18n("No servers configured")
                        explanation: serversTab.filterText !== ""
                                     ? "" : i18n("Add llama.cpp / audio.cpp / … servers in the widget settings.")
                        helpfulAction: QQC2.Action {
                            enabled: serversTab.filterText === ""
                            icon.name: "configure"
                            text: i18n("Configure…")
                            onTriggered: page.backend.openConfig()
                        }
                    }
                }
            }

            PlasmaExtras.PlasmoidHeading {
                Layout.fillWidth: true
                position: PlasmaExtras.PlasmoidHeading.Footer
                contentItem: RowLayout {
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        //font: Kirigami.Theme.smallFont
                        font.bold: true
                        opacity: 0.7
                        text: i18n("%1 / %2 running", page.backend.runningCount, page.backend.servers.length)
                    }
                    PlasmaComponents.BusyIndicator {
                        visible: page.backend.loading
                        running: visible
                        implicitWidth: Kirigami.Units.iconSizes.small
                        implicitHeight: implicitWidth
                    }
                    PlasmaComponents.Label {
                        visible: page.backend.missingBinaries > 0
                        font: Kirigami.Theme.smallFont
                        color: Kirigami.Theme.negativeTextColor
                        text: i18np("%1 binary not in PATH", "%1 binaries not in PATH", page.backend.missingBinaries)
                    }
                }
            }
        }

        // ═════════════════════ TAB 1 – Logs ═════════════════════
        ColumnLayout {
            id: logsTab
            spacing: 0

            readonly property var entry: page.backend.serverById(page.backend.activeLogId)
            readonly property var running: entry ? page.backend.runningMap[entry.id] : undefined
            readonly property string rawText: page.backend.logTexts[page.backend.activeLogId] || ""
            readonly property var filtered: Logic.filterLines(rawText, filterField.text, regexBtn.checked)
            readonly property string logText: filtered.text
            readonly property bool filtering: filterField.text !== ""
            readonly property var stats: Logic.logStats(rawText)
            readonly property string statsTooltip: {
                var st = logsTab.stats
                var parts = []
                // Rich text (textFormat on the ToolTip): each stat line is bold
                // and keeps the color of its old inline chip.
                if (page.backend.showStatWarnings) parts.push('<span style="color: ' + Kirigami.Theme.neutralTextColor + '; font-weight: bold;">' + i18n("Warnings: %1", st.warnings) + '</span>')
                if (page.backend.showStatErrors) parts.push('<span style="color: ' + Kirigami.Theme.negativeTextColor + '; font-weight: bold;">' + i18n("Errors: %1", st.errors) + '</span>')
                if (page.backend.showStatOom) parts.push('<span style="color: ' + Kirigami.Theme.negativeTextColor + '; font-weight: bold;">' + i18n("Out of memory: %1", st.oom) + '</span>')
                if (page.backend.showStatTps && st.maxTps > 0) {
                    parts.push('<b>' + i18n("Max speed: %1 t/s", st.maxTps.toFixed(2)) + '</b>')
                    parts.push('<b>' + i18n("Min speed: %1 t/s", st.minTps.toFixed(2)) + '</b>')
                }
                return parts.join("<br>")
            }
            readonly property string logHtml: logsTab.logText !== ""
                ? Logic.highlightLog(logsTab.logText, Kirigami.Theme.negativeTextColor,
                                     Kirigami.Theme.neutralTextColor,
                                     filterField.text, regexBtn.checked,
                                     Kirigami.Theme.highlightColor,
                                     Kirigami.Theme.highlightedTextColor)
                : ""

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                visible: page.backend.servers.length > 0

                // Hidden measurer: sizes the combo to the longest server name.
                // TextMetrics (not a layout Item) so it cannot feed back into
                // the combo's implicitWidth and trip a binding loop.
                TextMetrics {
                    id: longestLabel
                    font {
                        pointSize: Kirigami.Theme.smallFont.pointSize
                        family: Kirigami.Theme.smallFont.family
                    }
                    text: page.backend.servers.map(function (s) { return s.name || s.id })
                        .reduce(function (a, b) { return a.length >= b.length ? a : b }, "")
                }
                PlasmaComponents.ComboBox {
                    id: logCombo
                    Layout.fillWidth: false
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                    // The Plasma ComboBox wrapper binds implicitWidth to its
                    // content and loops; override with a plain value so the
                    // layout sizes us via preferredWidth instead.
                    implicitWidth: Layout.preferredWidth
                    implicitHeight: Kirigami.Theme.defaultFont.pixelSize
                                    + Math.round(Kirigami.Units.gridUnit * 0.9)
                    // The Plasma ComboBox wrapper loops when a layout binding
                    // feeds implicitWidth back, so size it imperatively from
                    // the measurer's text instead.
                    function resizeToContent() {
                        Layout.preferredWidth = Math.min(
                            Kirigami.Units.gridUnit * 12,
                            Math.max(Kirigami.Units.gridUnit * 6,
                                     longestLabel.width + Kirigami.Units.gridUnit * 10))
                    }
                    onDisplayTextChanged: resizeToContent()
                    Component.onCompleted: resizeToContent()
                    model: page.backend.servers.map(function (s) { return s.name || s.id })
                    currentIndex: {
                        for (var i = 0; i < page.backend.servers.length; i++)
                            if (page.backend.servers[i].id === page.backend.activeLogId) return i
                        return -1
                    }
                    onActivated: function (i) {
                        page.backend.activeLogId = page.backend.servers[i].id
                        page.backend.persistUiState()
                        page.backend.tailLog()
                    }
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents.ToolButton {
                    id: pauseBtn
                    checkable: true
                    checked: page.backend.logsPaused
                    onToggled: page.backend.logsPaused = checked
                    icon.name: "media-playback-pause"
                    display: QQC2.AbstractButton.IconOnly
                    PlasmaComponents.ToolTip { text: i18n("Pause live updates (to select text)") }
                }
                PlasmaComponents.ToolButton {
                    id: followBtn
                    checkable: true
                    checked: true
                    icon.name: "go-bottom"
                    display: QQC2.AbstractButton.IconOnly
                    PlasmaComponents.ToolTip { text: i18n("Follow the end of the log") }
                }
                PlasmaComponents.ToolButton {
                    icon.name: "edit-copy"
                    display: QQC2.AbstractButton.IconOnly
                    enabled: logsTab.logText !== ""
                    onClicked: { logArea.selectAll(); logArea.copy(); logArea.deselect() }
                    PlasmaComponents.ToolTip { text: i18n("Copy log") }
                }
            }


            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.bottomMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                visible: page.backend.servers.length > 0

                PlasmaExtras.SearchField {
                    id: filterField
                    objectName: "filterField"
                    Layout.fillWidth: true
                    placeholderText: i18n("Filter log lines…")
                }
                PlasmaComponents.ToolButton {
                    id: regexBtn
                    checkable: true
                    text: ".*"
                    PlasmaComponents.ToolTip { text: i18n("Interpret the filter as a regular expression") }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.bottomMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                //visible: logsTab.logText !== ""

                Item { Layout.fillWidth: true }
                PlasmaComponents.Label {
                    id: logFileLabel
                    Layout.fillWidth: true
                    font: Kirigami.Theme.smallFont
                    elide: Text.ElideLeft
                    opacity: logsTab.logText !== "" ? 0.7 : 0
                    text: logsTab.running && logsTab.running.logfile ? i18n("Log file: %1", logsTab.running.logfile) : ""
                    MouseArea {
                        anchors.fill: parent
                        enabled: logFileLabel.text !== ""
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Qt.openUrlExternally("file://" + logsTab.running.logfile)
                    }
                }
                Item { Layout.fillWidth: true }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                visible: page.backend.servers.length > 0
                color: Kirigami.Theme.highlightColor
                opacity: 0.5
            }

            QQC2.ScrollView {
                id: logScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: page.backend.servers.length > 0

                QQC2.TextArea {
                    id: logArea
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    textFormat: logsTab.logHtml !== "" ? TextEdit.RichText : TextEdit.PlainText
                    font.family: "monospace"
                    font.pointSize: page.backend.logFontPointSize
                    background: null
                    text: logsTab.logHtml !== "" ? logsTab.logHtml
                        : (logsTab.filtering && logsTab.rawText !== "") ? i18n("(no lines match the filter)")
                        : logsTab.running ? i18n("(waiting for output…)")
                        : i18n("Server not running – start it from the Servers tab.")
                    onTextChanged: if (followBtn.checked) Qt.callLater(function () {
                        var f = logScroll.contentItem
                        f.contentY = Math.max(0, f.contentHeight - f.height)
                    })
                }
            }

            Kirigami.PlaceholderMessage {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: page.backend.servers.length === 0
                icon.name: "view-history"
                text: i18n("No servers configured")
                explanation: i18n("Add servers in the widget settings.")
            }

            // ═════════════════════ TAB 1 FOOTER – log stats, errors, warnings, etc. ═════════════════════
            PlasmaExtras.PlasmoidHeading {
                Layout.fillWidth: true
                position: PlasmaExtras.PlasmoidHeading.Footer
                contentItem: RowLayout {
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        Layout.fillWidth: true
                        elide: Text.ElideLeft
                        font.bold: true
                        opacity: 0.7
                        text: !logsTab.entry ? i18n("No server selected")
                            : logsTab.running ? i18n("pid %1", logsTab.running.pid)
                            : i18n("Stopped")
                    }
                    PlasmaComponents.Label {
                        visible: page.backend.showStatTps && logsTab.stats.curTps > 0
                        font.bold: true
                        opacity: 0.7
                        text: i18n("%1 t/s", logsTab.stats.curTps.toFixed(2))
                    }
                    PlasmaComponents.Label {
                        visible: logsTab.filtering && logsTab.filtered.ok
                        font.bold: true
                        opacity: 0.7
                        text: i18n("%1 / %2 lines", logsTab.filtered.matched, logsTab.filtered.total)
                    }
                    PlasmaComponents.Label {
                        visible: logsTab.filtering && !logsTab.filtered.ok
                        font.bold: true
                        color: Kirigami.Theme.negativeTextColor
                        text: i18n("invalid regex")
                    }
                    PlasmaComponents.ToolButton {
                        visible: logsTab.statsTooltip !== ""
                        icon.name: "documentinfo"
                        display: QQC2.AbstractButton.IconOnly
                        PlasmaComponents.ToolTip {
                            text: logsTab.statsTooltip
                            textFormat: Text.RichText
                        }
                    }
                }
            }
        }

            // ═════════════════════ TAB 2 – Stats ═════════════════════
            ColumnLayout {
                id: statsTab
                spacing: 0
                // older Kirigami has no Theme.readOnlyTextFont: keep the
                // monospace digits (no reflow on changing numbers) without
                // breaking on it
                readonly property string monoFontFamily: Kirigami.Theme.readOnlyTextFont
                                                         ? Kirigami.Theme.readOnlyTextFont.family
                                                         : "monospace"

                // ── dashboard model ───────────────────────────────────────
                // One card per server that is running or has been probed.
                // Probes land every second and rebuild these arrays, so the
                // Repeaters NEVER bind to them directly: they bind to the
                // stable id caches below (reassigned only when membership
                // changes) and look values up in rowsById/tilesById — which
                // are reassigned every tick. Delegates then stay alive and
                // only their bindings re-evaluate: no flicker, no jumps.
                readonly property var rows: {
                    var out = []
                    page.backend.servers.forEach(function (s) {
                        var e = page.backend.statsMap[s.id]
                        if (!e && !page.backend.runningMap[s.id]) return
                        out.push({
                            id: s.id, name: s.name || s.id, s: s,
                            running: !!page.backend.runningMap[s.id],
                            st: e ? Logic.parseStats(e) : null
                        })
                    })
                    return out
                }
                // Machine block (rings + hardware tiles): every value comes
                // from the system — the `gpu` subcommand (nvidia-smi names +
                // totals, /proc RAM/CPU%/disk, /sys cores/threads) — and the
                // sparkline history is the plasmoid's own rolling samples
                // (gpuHist). No server is consulted for this block; procs
                // maps pid->MiB so the VRAM ring attributes each slice.
                readonly property var hw: {
                    var g = page.backend.gpuInfo || {}
                    var procs = g.procs || {}
                    if (!(g.ramTotalMib > 0) && !(g.gpuTotalMib > 0) && Object.keys(procs).length === 0)
                        return null
                    var d = function (v) { return v !== undefined ? v : -1 }
                    return {
                        vramUsedMib: d(g.gpuUsedMib),
                        vramTotalMib: d(g.gpuTotalMib),
                        gpuUtil: d(g.gpuUtil),
                        gpuTemp: d(g.gpuTemp),
                        gpuPower: d(g.gpuPower),
                        powerLimit: d(g.gpuPowerLimit),
                        ramUsedMib: d(g.ramUsedMib),
                        ramTotalMib: d(g.ramTotalMib),
                        cpuPct: d(g.cpuPct),
                        diskRead: d(g.diskReadMBs),
                        procs: procs,
                        gpuName: g.gpuName || "",
                        cpuName: g.cpuName || "",
                        cores: g.cpuCores > 0 ? g.cpuCores : 0,
                        threads: g.cpuThreads > 0 ? g.cpuThreads : 0,
                        hist: page.backend.gpuHist || {}
                    }
                }

                // Ring source colors: every running server keeps a stable
                // hue by position in the list.
                function srcColor(i) {
                    var h = [0.58, 0.10, 0.34, 0.80, 0.46, 0.02, 0.88, 0.21]
                    return Qt.hsla(h[i % h.length], 0.45, 0.55, 1)
                }

                // VRAM ring segments — who holds each slice, best source per
                // server: 1) nvidia-smi per-pid (exact, any server type),
                // 2) strata's arena_mib (its own allocation), 3) llama.cpp's
                // device reading from its load log minus what earlier
                // segments already claimed, 4) leftover used → "other".
                readonly property var vramSegs: {
                    var m = statsTab.hw
                    if (!m || !(m.vramTotalMib > 0) || !(m.vramUsedMib >= 0)) return []
                    var out = [], known = 0, idx = 0
                    statsTab.rows.forEach(function (r) {
                        if (!r.running || !r.st) return
                        var own = -1
                        var run = page.backend.runningMap[r.id]
                        var pid = run && run.pid !== undefined ? String(run.pid) : ""
                        if (pid !== "" && m.procs[pid] !== undefined) own = m.procs[pid]
                        else if (r.st.kind === "strata" && r.st.ownVramMib >= 0) own = r.st.ownVramMib
                        else if (r.st.kind === "llama" && r.st.logVramUsedMib >= 0) own = r.st.logVramUsedMib - known
                        if (!(own > 0)) return
                        own = Math.min(own, m.vramTotalMib - known)
                        if (!(own > 0)) return
                        known += own
                        out.push({ frac: own / m.vramTotalMib,
                                   color: statsTab.srcColor(idx), label: r.name || r.id })
                        idx++
                    })
                    var rest = m.vramUsedMib - known
                    if (rest > 128) {
                        out.push({ frac: Math.min(1, rest / m.vramTotalMib),
                                   color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                                  Kirigami.Theme.textColor.b, 0.25),
                                   label: i18n("other") })
                    }
                    return out
                }

                // strata context rings split resident tokens into prompt vs
                // generated; other server kinds stay single-tone.
                function ctxSegs(row) {
                    if (!row || !row.st || row.st.kind !== "strata") return []
                    var st = row.st
                    if (!(st.ctxMax > 0) || !(st.promptTotal > 0)) return []
                    var segs = [{ frac: Math.min(1, st.promptTotal / st.ctxMax),
                                  color: Kirigami.Theme.highlightColor, label: i18n("prompt") }]
                    if (st.genNow > 0) {
                        segs.push({ frac: Math.min(1, st.genNow / st.ctxMax),
                                    color: Kirigami.Theme.positiveTextColor, label: i18n("out") })
                    }
                    return segs
                }
                // One Recent-requests table for ALL servers, newest first.
                readonly property var reqRows: Logic.mergeReqs(
                    statsTab.rows.map(function (r) {
                        return { name: r.name, reqs: r.st ? r.st.reqs : [] }
                    }), 8)

                // Stable Repeater inputs + live lookup maps (see above).
                property var rowsById: ({})
                property var rowIds: []
                property var tilesById: ({})
                property var tileIds: []
                property var tileStale: ({})
                property var reqTable: []
                property string reqSig: ""
                // Tiles depend on the Stats config toggles too.
                readonly property var tileGate: [page.backend.statShowTps,
                                                page.backend.statShowHardware,
                                                page.backend.statShowVram]

                onRowsChanged: statsTab.restructure()
                onTileGateChanged: statsTab.restructure()
                Component.onCompleted: statsTab.restructure()

                function restructure() {
                    var rs = statsTab.rows
                    var byId = {}, ids = []
                    rs.forEach(function (r) {
                        byId[r.id] = r
                        ids.push(r.id)
                    })
                    statsTab.rowsById = byId
                    if (ids.join("|") !== statsTab.rowIds.join("|")) statsTab.rowIds = ids

                    var tiles = statsTab.buildTiles()
                    var tById = {}, tIds = []
                    tiles.forEach(function (t) {
                        tById[t.label] = t
                        tIds.push(t.label)
                        statsTab.tileStale[t.label] = 0
                    })
                    // Hysteresis: one poll failing to report an optional
                    // counter (e.g. strata history missing the disk line)
                    // must not make a tile blink out and back every second.
                    // A gone tile is kept as-is for up to 3 ticks.
                    Object.keys(statsTab.tilesById).forEach(function (k) {
                        if (tById[k] !== undefined) return
                        var age = (statsTab.tileStale[k] || 0) + 1
                        statsTab.tileStale[k] = age
                        if (age <= 3) {
                            tById[k] = statsTab.tilesById[k]
                            tIds.push(k)
                        }
                    })
                    statsTab.tilesById = tById
                    if (tIds.join("|") !== statsTab.tileIds.join("|")) statsTab.tileIds = tIds

                    // Rebuild the request table only when a row actually
                    // appears/changes — idle servers then keep it untouched.
                    var sig = statsTab.reqRows.map(function (r) {
                        return [r.name, r.at, r.inTok, r.outTok, r.durS, r.tps,
                                r.finish, r.reused].join(",")
                    }).join("|")
                    if (sig !== statsTab.reqSig) {
                        statsTab.reqSig = sig
                        statsTab.reqTable = statsTab.reqRows
                    }
                }

                readonly property color cardColor: Qt.rgba(Kirigami.Theme.textColor.r,
                                                           Kirigami.Theme.textColor.g,
                                                           Kirigami.Theme.textColor.b, 0.04)
                readonly property color cardBorder: Qt.rgba(Kirigami.Theme.textColor.r,
                                                            Kirigami.Theme.textColor.g,
                                                            Kirigami.Theme.textColor.b, 0.15)

                function fmt1(v) { return (Math.round(v * 10) / 10).toFixed(1) }

                // KPI tiles: Speed comes from the server rows (strata
                // metrics / llama log); the hardware tiles and all
                // sparklines come from the system gpu poll (hw.hist).
                function buildTiles() {
                    var out = []
                    var cfg = page.backend
                    var hw = statsTab.hw
                    if (cfg.statShowTps && statsTab.rows.length > 0) {
                        var cur = -1, mean = -1, tokSpark = []
                        statsTab.rows.forEach(function (r) {
                            if (!r.st) return
                            if (r.st.active && r.st.tps > cur) cur = r.st.tps
                            if (r.st.meanTps > mean) mean = r.st.meanTps
                            if (!tokSpark.length && r.st.kind === "strata" && r.st.hist)
                                tokSpark = r.st.hist.tok_s || []
                        })
                        if (cur >= 0 || mean >= 0) {
                            out.push({ label: i18n("Speed"),
                                       value: statsTab.fmt1(cur >= 0 ? cur : Math.max(0, mean)),
                                       unit: " tok/s",
                                       sub: mean >= 0 ? i18n("mean %1 tok/s", statsTab.fmt1(mean)) : "",
                                       spark: tokSpark,
                                       tint: Kirigami.Theme.positiveTextColor })
                        }
                    }
                    if (cfg.statShowHardware && hw) {
                        if (hw.gpuTemp >= 0)
                            out.push({ label: i18n("GPU temp"), value: String(Math.round(hw.gpuTemp)),
                                       unit: " °C",
                                       sub: hw.gpuPower >= 0 ? Math.round(hw.gpuPower) + " W" : "",
                                       spark: hw.hist.gpu_temp || [], tint: Kirigami.Theme.neutralTextColor })
                        if (hw.gpuPower >= 0)
                            out.push({ label: i18n("GPU power"), value: String(Math.round(hw.gpuPower)),
                                       unit: " W",
                                       sub: hw.powerLimit > 0 ? i18n("limit %1 W", Math.round(hw.powerLimit)) : "",
                                       spark: hw.hist.gpu_power || [], tint: Kirigami.Theme.neutralTextColor })
                        if (hw.diskRead >= 0)
                            out.push({ label: i18n("Disk"), value: hw.diskRead.toFixed(0), unit: " MB/s",
                                       sub: "", spark: hw.hist.disk_read_mb || [],
                                       tint: Kirigami.Theme.neutralTextColor })
                    }
                    return out
                }

                // err code → human hint
                function errText(st, command) {
                    if (!st || st.err === "") return ""
                    if (st.err === "no_port") return i18n("no HTTP port (set host + port to monitor)")
                    if (st.err === "unreachable" || st.err === "empty_body" || st.err === "no_metrics") {
                        var b = Logic.serverBinary(command, page.backend.homeDir)
                        return i18n("no metrics from its HTTP API%1",
                                    b === "llama-server" ? " (add --metrics to its command)" : "")
                    }
                    return st.err
                }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing
                    PlasmaComponents.Label {
                        text: i18n("Live monitor")
                        font.bold: true
                        opacity: 0.85
                    }
                    PlasmaComponents.Label {
                        font: Kirigami.Theme.smallFont
                        opacity: 0.6
                        text: i18n("HTTP probes every second while this tab is open")
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.ToolButton {
                        icon.name: "configure"
                        display: QQC2.AbstractButton.IconOnly
                        onClicked: page.backend.openConfig()
                        PlasmaComponents.ToolTip { text: i18n("Configure what the monitor shows…") }
                    }
                }

                QQC2.ScrollView {
                    id: dashScroll
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    ColumnLayout {
                        id: dash
                        width: dashScroll.availableWidth
                        spacing: Kirigami.Units.smallSpacing

                        // ── machine rings (the headline block: no title) ──
                        // machine-wide counters from the `gpu` poll (nvidia-smi
                        // + /proc + /sys) plus the plasmoid's own rolling
                        // history for the sparklines. Each server's context
                        // ring lives inside its card. Amber → red past the
                        // thresholds. Column count adapts to the popup width;
                        // fillWidth stretches the rings to occupy it fully,
                        // and the readouts wrap inside their cell.
                        GridLayout {
                            Layout.fillWidth: true
                            columns: Math.max(1, Math.min(4, Math.floor(
                                (statsTab.width - 24) /
                                (Kirigami.Units.gridUnit * 3.4 + Kirigami.Units.largeSpacing))))
                            columnSpacing: Kirigami.Units.largeSpacing
                            rowSpacing: Kirigami.Units.smallSpacing
                            visible: statsTab.hw !== null

                            // machine-wide rings (system counters)
                            GaugeRing {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignTop
                                visible: page.backend.statShowHardware && statsTab.hw !== null
                                         && statsTab.hw.cpuPct >= 0
                                name: i18n("CPU")
                                frac: statsTab.hw ? Math.max(0, statsTab.hw.cpuPct) / 100 : 0
                                readout: statsTab.hw && statsTab.hw.cores > 0
                                         ? (statsTab.hw.threads > statsTab.hw.cores
                                            ? i18n("%1 cores / %2 threads", statsTab.hw.cores,
                                                   statsTab.hw.threads)
                                            : i18n("%1 cores", statsTab.hw.cores)) : ""
                                spark: statsTab.hw ? (statsTab.hw.hist.cpu || []) : []
                            }
                            GaugeRing {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignTop
                                visible: page.backend.statShowHardware && statsTab.hw !== null
                                         && statsTab.hw.gpuUtil >= 0
                                name: i18n("GPU")
                                frac: statsTab.hw ? Math.max(0, statsTab.hw.gpuUtil) / 100 : 0
                                readout: statsTab.hw ? Logic.gpuReadout(statsTab.hw.gpuName) : ""
                                spark: statsTab.hw ? (statsTab.hw.hist.gpu_util || []) : []
                            }
                            GaugeRing {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignTop
                                visible: page.backend.statShowVram && statsTab.hw !== null
                                         && statsTab.hw.vramTotalMib > 0 && statsTab.hw.vramUsedMib >= 0
                                name: i18n("VRAM")
                                frac: statsTab.hw ? Math.min(1, statsTab.hw.vramUsedMib / Math.max(1, statsTab.hw.vramTotalMib)) : 0
                                readout: statsTab.hw ? Logic.fmtMibPair(statsTab.hw.vramUsedMib,
                                                                       statsTab.hw.vramTotalMib) : ""
                                segments: statsTab.vramSegs
                                // which server owns each arc, under the ring
                                legend: statsTab.vramSegs.length > 1 ? statsTab.vramSegs : []
                                spark: statsTab.hw ? (statsTab.hw.hist.gpu_mem_used || []) : []
                            }
                            GaugeRing {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignTop
                                visible: page.backend.statShowHardware && statsTab.hw !== null
                                         && statsTab.hw.ramTotalMib > 0 && statsTab.hw.ramUsedMib >= 0
                                name: i18n("RAM")
                                frac: statsTab.hw ? Math.min(1, statsTab.hw.ramUsedMib / Math.max(1, statsTab.hw.ramTotalMib)) : 0
                                readout: statsTab.hw ? Logic.fmtMibPair(statsTab.hw.ramUsedMib,
                                                                       statsTab.hw.ramTotalMib) : ""
                                spark: statsTab.hw ? (statsTab.hw.hist.ram_used || []) : []
                            }
                        }

                        // ── KPI tiles with sparklines ──
                        GridLayout {
                            Layout.fillWidth: true
                            columns: Math.max(2, Math.min(4, Math.floor(statsTab.width / 170)))
                            columnSpacing: Kirigami.Units.smallSpacing
                            rowSpacing: Kirigami.Units.smallSpacing
                            visible: statsTab.tileIds.length > 0

                            Repeater {
                                model: statsTab.tileIds
                                delegate: Rectangle {
                                    required property string modelData
                                    readonly property var tile: statsTab.tilesById[modelData] || {}
                                    Layout.fillWidth: true
                                    radius: Kirigami.Units.cornerRadius
                                    color: statsTab.cardColor
                                    border.width: 1
                                    border.color: statsTab.cardBorder
                                    implicitHeight: tileCol.implicitHeight + Kirigami.Units.largeSpacing

                                    ColumnLayout {
                                        id: tileCol
                                        anchors.fill: parent
                                        anchors.margins: Kirigami.Units.smallSpacing
                                        spacing: 1
                                        PlasmaComponents.Label {
                                            Layout.fillWidth: true
                                            font: Kirigami.Theme.smallFont
                                            opacity: 0.65
                                            elide: Text.ElideRight
                                            text: tile.label !== undefined ? tile.label : " "
                                        }
                                        RowLayout {
                                            spacing: 3
                                            PlasmaComponents.Label {
                                                text: tile.value !== undefined ? tile.value : " "
                                                color: tile.tint !== undefined ? tile.tint : "transparent"
                                                font {
                                                    pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.5
                                                    bold: true
                                                    // monospace digits: changing
                                                    // values never reflow
                                                    family: statsTab.monoFontFamily
                                                }
                                            }
                                            PlasmaComponents.Label {
                                                Layout.alignment: Qt.AlignBottom
                                                font: Kirigami.Theme.smallFont
                                                opacity: 0.7
                                                text: tile.unit !== undefined ? tile.unit : ""
                                            }
                                        }
                                        PlasmaComponents.Label {
                                            Layout.fillWidth: true
                                            font: Kirigami.Theme.smallFont
                                            opacity: 0.6
                                            elide: Text.ElideRight
                                            // blank placeholder keeps tile height constant
                                            text: (tile.sub !== undefined && tile.sub !== "") ? tile.sub : " "
                                        }
                                        Sparkline {
                                            Layout.fillWidth: true
                                            visible: Array.isArray(tile.spark) && tile.spark.length > 1
                                            series: Array.isArray(tile.spark) ? tile.spark : []
                                            lineColor: tile.tint !== undefined ? tile.tint : "transparent"
                                        }
                                    }
                                }
                            }
                        }

                        // ── per-server live state ──
                        Repeater {
                            model: statsTab.rowIds
                            delegate: Rectangle {
                                id: srv
                                required property string modelData
                                Layout.fillWidth: true
                                radius: Kirigami.Units.cornerRadius
                                color: statsTab.cardColor
                                border.width: 1
                                border.color: statsTab.cardBorder
                                implicitHeight: srvCol.implicitHeight + Kirigami.Units.largeSpacing * 2

                                // rowsById is reassigned every probe: the
                                // whole card re-renders its text in place,
                                // it is never destroyed.
                                readonly property var row: statsTab.rowsById[modelData] || null
                                readonly property var st: srv.row ? srv.row.st : null
                                // generation progress first, prefill while reading
                                readonly property double progress: {
                                    var st = srv.st
                                    if (!st) return 0
                                    if (st.genMax > 0 && st.genNow >= 0) return st.genNow / st.genMax
                                    if (st.promptTotal > 0 && st.promptRead >= 0)
                                        return st.promptRead / st.promptTotal
                                    return 0
                                }
                                readonly property string progressText: {
                                    var st = srv.st
                                    if (!st) return ""
                                    if (st.genMax > 0 && st.genNow >= 0)
                                        return i18n("generating %1 / %2 tok",
                                                    Logic.fmtTokens(st.genNow), Logic.fmtTokens(st.genMax))
                                    if (st.promptTotal > 0 && st.promptRead >= 0)
                                        return i18n("reading prompt %1 / %2 tok",
                                                    Logic.fmtTokens(st.promptRead), Logic.fmtTokens(st.promptTotal))
                                    return ""
                                }

                                ColumnLayout {
                                    id: srvCol
                                    anchors.fill: parent
                                    anchors.margins: Kirigami.Units.largeSpacing
                                    spacing: 3

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Kirigami.Units.smallSpacing

                                        Rectangle {
                                            Layout.alignment: Qt.AlignVCenter
                                            implicitWidth: Kirigami.Units.gridUnit * 0.7
                                            implicitHeight: implicitWidth
                                            radius: width / 2
                                            color: srv.st && srv.st.state === "generating" ? Kirigami.Theme.positiveTextColor
                                                   : srv.st && srv.st.state === "reading" ? Kirigami.Theme.highlightColor
                                                   : srv.row && srv.row.running ? Kirigami.Theme.positiveTextColor
                                                   : Kirigami.Theme.neutralTextColor
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0
                                            PlasmaComponents.Label {
                                                Layout.fillWidth: true
                                                text: srv.row ? srv.row.name : ""
                                                font.bold: true
                                                elide: Text.ElideRight
                                            }
                                            PlasmaComponents.Label {
                                                Layout.fillWidth: true
                                                font: Kirigami.Theme.smallFont
                                                opacity: 0.7
                                                elide: Text.ElideRight
                                                text: {
                                                    var parts = []
                                                    if (srv.st && srv.st.model) parts.push(srv.st.model)
                                                    if (!srv.row) return ""
                                                    var ep = Logic.endpointText(srv.row.s)
                                                    if (ep !== "") parts.push(ep)
                                                    var errHint = statsTab.errText(srv.st, srv.row.s.command)
                                                    if (errHint !== "") parts.push(errHint)
                                                    return parts.join("  •  ")
                                                }
                                            }
                                        }
                                        PlasmaComponents.Label {
                                            visible: srv.st !== null && srv.st.state !== ""
                                                     && srv.st.state !== "idle"
                                            text: (srv.st ? srv.st.state : "")
                                                  + (srv.st && srv.st.queued > 0 ? " +" + srv.st.queued : "")
                                            color: srv.st && srv.st.state === "generating"
                                                   ? Kirigami.Theme.positiveTextColor
                                                   : Kirigami.Theme.highlightColor
                                            font {
                                                pointSize: Kirigami.Theme.smallFont.pointSize
                                                bold: true
                                            }
                                        }
                                        PlasmaComponents.Label {
                                            visible: page.backend.statShowTps && srv.st !== null
                                                     && srv.st.tps > 0
                                            text: statsTab.fmt1(srv.st ? srv.st.tps : 0) + " tok/s"
                                            font {
                                                pointSize: Kirigami.Theme.smallFont.pointSize
                                                bold: true
                                                family: statsTab.monoFontFamily
                                            }
                                        }
                                        // the server's own context fill lives
                                        // with the server, not in the machine row
                                        GaugeRing {
                                            visible: srv.st !== null && srv.st.ctxMax > 0
                                                     && srv.st.ctxUsed >= 0
                                            frac: srv.st ? srv.st.ctxUsed / srv.st.ctxMax : 0
                                            segments: statsTab.ctxSegs(srv.row)
                                            legend: statsTab.ctxSegs(srv.row)
                                            legendRight: true
                                        }
                                    }

                                    // live generation / prefill bar (strata):
                                    // the track stays in place while running
                                    // so the card height never jumps. Custom
                                    // (no QQC2.ProgressBar: its Breeze style
                                    // breaks outside a Plasma shell).
                                    Rectangle {
                                        id: genBar
                                        Layout.fillWidth: true
                                        Layout.topMargin: 2
                                        Layout.bottomMargin: 2
                                        height: 5
                                        radius: height / 2
                                        visible: srv.row !== null && srv.row.running
                                        color: statsTab.cardBorder
                                        Rectangle {
                                            width: genBar.width * Math.min(1, srv.progress)
                                            height: genBar.height
                                            radius: genBar.radius
                                            color: srv.st && srv.st.state === "generating"
                                                   ? Kirigami.Theme.positiveTextColor
                                                   : Kirigami.Theme.highlightColor
                                            Behavior on width { NumberAnimation { duration: 350; easing.type: Easing.OutQuad } }
                                        }
                                    }
                                    PlasmaComponents.Label {
                                        font: Kirigami.Theme.smallFont
                                        opacity: 0.7
                                        // blank placeholder keeps the row height
                                        text: srv.progressText !== "" ? srv.progressText : " "
                                    }

                                    // token totals (any server kind): a fixed
                                    // 5-column grid — constant header labels
                                    // and tabular digits keep every column in
                                    // place, so growing totals never reflow
                                    // the card (the per-second flicker text
                                    // flows used to cause).
                                    GridLayout {
                                        Layout.fillWidth: true
                                        columns: 5
                                        columnSpacing: Kirigami.Units.largeSpacing
                                        rowSpacing: 0
                                        visible: page.backend.statShowTokens && srv.st !== null

                                        PlasmaComponents.Label { Layout.fillWidth: true; font: Kirigami.Theme.smallFont; opacity: 0.55; text: i18n("req") }
                                        PlasmaComponents.Label { Layout.fillWidth: true; font: Kirigami.Theme.smallFont; opacity: 0.55; text: i18n("tok in") }
                                        PlasmaComponents.Label { Layout.fillWidth: true; font: Kirigami.Theme.smallFont; opacity: 0.55; text: i18n("tok out") }
                                        PlasmaComponents.Label { Layout.fillWidth: true; font: Kirigami.Theme.smallFont; opacity: 0.55; text: i18n("reused") }
                                        PlasmaComponents.Label { Layout.fillWidth: true; font: Kirigami.Theme.smallFont; opacity: 0.55; text: i18n("context") }

                                        PlasmaComponents.Label {
                                            Layout.fillWidth: true
                                            color: Kirigami.Theme.textColor
                                            opacity: 0.9
                                            font { pointSize: Kirigami.Theme.smallFont.pointSize; bold: true; family: statsTab.monoFontFamily }
                                            text: srv.st && srv.st.events >= 0 ? Logic.fmtTokens(srv.st.events) : "—"
                                        }
                                        PlasmaComponents.Label {
                                            Layout.fillWidth: true
                                            color: Kirigami.Theme.textColor
                                            opacity: 0.9
                                            font { pointSize: Kirigami.Theme.smallFont.pointSize; bold: true; family: statsTab.monoFontFamily }
                                            text: srv.st && srv.st.promptTok >= 0 ? Logic.fmtTokens(srv.st.promptTok) : "—"
                                        }
                                        PlasmaComponents.Label {
                                            Layout.fillWidth: true
                                            color: Kirigami.Theme.textColor
                                            opacity: 0.9
                                            font { pointSize: Kirigami.Theme.smallFont.pointSize; bold: true; family: statsTab.monoFontFamily }
                                            text: srv.st && srv.st.outTok >= 0 ? Logic.fmtTokens(srv.st.outTok) : "—"
                                        }
                                        PlasmaComponents.Label {
                                            Layout.fillWidth: true
                                            color: Kirigami.Theme.textColor
                                            opacity: 0.9
                                            font { pointSize: Kirigami.Theme.smallFont.pointSize; bold: true; family: statsTab.monoFontFamily }
                                            text: srv.st && srv.st.reusedTok > 0 ? Logic.fmtTokens(srv.st.reusedTok) : "—"
                                        }
                                        PlasmaComponents.Label {
                                            Layout.fillWidth: true
                                            color: Kirigami.Theme.textColor
                                            opacity: 0.9
                                            font { pointSize: Kirigami.Theme.smallFont.pointSize; bold: true; family: statsTab.monoFontFamily }
                                            text: srv.st && srv.st.ctxMax > 0 && srv.st.ctxUsed >= 0
                                                  ? Logic.fmtTokens(srv.st.ctxUsed) + " / " + Logic.fmtTokens(srv.st.ctxMax)
                                                  : "—"
                                        }
                                    }
                                }
                            }
                        }

                        // ── recent requests, all servers, newest first ──
                        Rectangle {
                            id: reqCard
                            Layout.fillWidth: true
                            visible: page.backend.statShowEvents && statsTab.reqRows.length > 0
                            radius: Kirigami.Units.cornerRadius
                            color: statsTab.cardColor
                            border.width: 1
                            border.color: statsTab.cardBorder
                            implicitHeight: reqCol.implicitHeight + Kirigami.Units.largeSpacing

                            readonly property var tot: {
                                var t = { reqs: 0, tin: 0, tout: 0, reused: 0 }
                                statsTab.rows.forEach(function (r) {
                                    if (!r.st) return
                                    if (r.st.events >= 0) t.reqs += r.st.events
                                    if (r.st.promptTok >= 0) t.tin += r.st.promptTok
                                    if (r.st.outTok >= 0) t.tout += r.st.outTok
                                    if (r.st.reusedTok >= 0) t.reused += r.st.reusedTok
                                })
                                return t
                            }

                            ColumnLayout {
                                id: reqCol
                                anchors.fill: parent
                                anchors.margins: Kirigami.Units.smallSpacing
                                spacing: 1

                                component ReqRow: RowLayout {
                                    required property string time
                                    required property string server
                                    required property string status
                                    required property string tIn
                                    required property string tReuse
                                    required property string tOut
                                    required property string tps
                                    required property string dur
                                    required property bool header
                                    spacing: Kirigami.Units.largeSpacing
                                    PlasmaComponents.Label {
                                        Layout.preferredWidth: 66
                                        Layout.minimumWidth: Layout.preferredWidth
                                        font {
                                            pointSize: Kirigami.Theme.smallFont.pointSize
                                            bold: header
                                            family: "monospace"
                                        }
                                        opacity: header ? 0.75 : 0.9
                                        text: time
                                    }
                                    PlasmaComponents.Label {
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 60
                                        elide: Text.ElideRight
                                        font {
                                            pointSize: Kirigami.Theme.smallFont.pointSize
                                            bold: header
                                        }
                                        opacity: header ? 0.75 : 1
                                        text: server
                                    }
                                    PlasmaComponents.Label {
                                        Layout.preferredWidth: 56
                                        Layout.minimumWidth: Layout.preferredWidth
                                        font {
                                            pointSize: Kirigami.Theme.smallFont.pointSize
                                            bold: header
                                        }
                                        opacity: header ? 0.75 : 1
                                        text: status
                                    }
                                    PlasmaComponents.Label {
                                        Layout.preferredWidth: 44
                                        Layout.minimumWidth: Layout.preferredWidth
                                        horizontalAlignment: Text.AlignRight
                                        font {
                                            pointSize: Kirigami.Theme.smallFont.pointSize
                                            bold: header
                                        }
                                        opacity: header ? 0.75 : 0.9
                                        text: tIn
                                    }
                                    PlasmaComponents.Label {
                                        Layout.preferredWidth: 44
                                        Layout.minimumWidth: Layout.preferredWidth
                                        horizontalAlignment: Text.AlignRight
                                        font {
                                            pointSize: Kirigami.Theme.smallFont.pointSize
                                            bold: header
                                        }
                                        opacity: header ? 0.75 : 0.9
                                        text: tReuse
                                    }
                                    PlasmaComponents.Label {
                                        Layout.preferredWidth: 44
                                        Layout.minimumWidth: Layout.preferredWidth
                                        horizontalAlignment: Text.AlignRight
                                        font {
                                            pointSize: Kirigami.Theme.smallFont.pointSize
                                            bold: header
                                        }
                                        opacity: header ? 0.75 : 0.9
                                        text: tOut
                                    }
                                    PlasmaComponents.Label {
                                        Layout.preferredWidth: 42
                                        Layout.minimumWidth: Layout.preferredWidth
                                        horizontalAlignment: Text.AlignRight
                                        font {
                                            pointSize: Kirigami.Theme.smallFont.pointSize
                                            bold: header
                                        }
                                        opacity: header ? 0.75 : 0.9
                                        text: tps
                                    }
                                    PlasmaComponents.Label {
                                        Layout.preferredWidth: 40
                                        Layout.minimumWidth: Layout.preferredWidth
                                        horizontalAlignment: Text.AlignRight
                                        font {
                                            pointSize: Kirigami.Theme.smallFont.pointSize
                                            bold: header
                                        }
                                        opacity: header ? 0.75 : 0.9
                                        text: dur
                                    }
                                }

                                ReqRow {
                                    header: true
                                    time: i18n("Time")
                                    server: i18n("Server")
                                    status: i18n("State")
                                    tIn: i18n("In")
                                    tReuse: i18n("Reused")
                                    tOut: i18n("Out")
                                    tps: "t/s"
                                    dur: i18n("Dur")
                                }

                                Repeater {
                                    model: statsTab.reqTable
                                    delegate: ReqRow {
                                        required property var modelData
                                        time: modelData.at > 0
                                              ? Qt.formatDateTime(new Date(modelData.at * 1000), "HH:mm:ss")
                                              : "–"
                                        server: modelData.name || ""
                                        status: modelData.finish || ""
                                        tIn: modelData.inTok > 0 ? Logic.fmtTokens(modelData.inTok) : "–"
                                        tReuse: page.backend.statShowTokens
                                                && modelData.reused > 0
                                                ? Logic.fmtTokens(modelData.reused) : "–"
                                        tOut: page.backend.statShowTokens
                                              ? (modelData.outTok > 0 ? Logic.fmtTokens(modelData.outTok) : "–") : ""
                                        tps: modelData.tps > 0 ? modelData.tps.toFixed(0) : "–"
                                        dur: modelData.durS > 0 ? modelData.durS.toFixed(1) + "s" : "–"
                                        header: false
                                    }
                                }

                                PlasmaComponents.Label {
                                    Layout.fillWidth: true
                                    font: Kirigami.Theme.smallFont
                                    opacity: 0.65
                                    elide: Text.ElideRight
                                    text: {
                                        var t = reqCard.tot
                                        var parts = [i18n("%1 req total", Logic.fmtTokens(t.reqs))]
                                        if (page.backend.statShowTokens) {
                                            parts.push(i18n("%1 tok in", Logic.fmtTokens(t.tin)))
                                            parts.push(i18n("%1 tok out", Logic.fmtTokens(t.tout)))
                                            if (t.reused > 0) {
                                                var pct = t.tin > 0 ? Math.round(100 * t.reused / t.tin) : 0
                                                parts.push(i18n("%1 reused (%2%)", Logic.fmtTokens(t.reused), pct))
                                            }
                                        }
                                        return parts.join("  •  ")
                                    }
                                }
                            }
                        }

                        Kirigami.PlaceholderMessage {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.topMargin: Kirigami.Units.gridUnit * 2
                            Layout.preferredWidth: Math.min(parent.width - Kirigami.Units.gridUnit * 2,
                                                            Kirigami.Units.gridUnit * 14)
                            visible: statsTab.rows.length === 0
                            icon.name: "speedometer-symbolic"
                            text: page.backend.servers.length === 0
                                  ? i18n("No servers configured") : i18n("No servers running")
                            explanation: page.backend.servers.length === 0
                                  ? i18n("Add servers in the widget settings.")
                                  : i18n("Start a server to see its live stats here.")
                        }
                    }
                }
            }
    }
}
