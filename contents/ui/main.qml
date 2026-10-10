// cpp servers Plasmoid – KDE Plasma 6 / Qt 6
//
// Data flow
//   ~/.config/cppserver/servers.json  <-- written by the configuration page
//        |  (re-read when its mtime changes, reported by every status poll)
//        v
//   main.qml (this file)  --run()-->  cppserverctl.sh  (start/stop/status/logs)
//
// Every shell round-trip goes through run(cmd, handler): the Plasma "executable"
// engine is single-flight, so commands are serialized and each one carries its
// own result handler (no string tags to parse).

import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

import "logic.js" as Logic

PlasmoidItem {
    id: root

    switchWidth:  Kirigami.Units.gridUnit * 5
    switchHeight: Kirigami.Units.gridUnit * 5

    Plasmoid.icon: "network-server-symbolic"
    Plasmoid.status: runningCount > 0 ? PlasmaCore.Types.ActiveStatus
                                      : PlasmaCore.Types.PassiveStatus

    // Shown as buttons in the popup header when the widget lives in the system
    // tray (like the stop button of Rclone Mounts), and in the right-click menu
    // anywhere else. Each one only appears when it has something to do.
    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Start all")
            icon.name: "media-playback-start"
            visible: root.startable.length > 0
            onTriggered: root.startAll()
        },
        PlasmaCore.Action {
            text: i18n("Stop all")
            icon.name: "media-playback-stop"
            visible: root.stoppable.length > 0
            onTriggered: root.stopAll()
        }
    ]

    toolTipMainText: i18n("cpp servers")
    toolTipSubText: allServers.length === 0
                    ? i18n("No servers configured")
                    : i18n("%1 / %2 running", runningCount, allServers.length)

    // ── State ──────────────────────────────────────────────────────────────
    property string homeDir: ""
    property string configPath: ""
    property var allServers: []          // everything in servers.json
    property var runningMap: ({})        // id -> { pid, logfile }
    property var pendingStarts: ({})     // id -> true while starting
    property var pendingStops: ({})      // id -> true while stopping
    property var depsMap: ({})           // binary -> bool (true = found)
    property var logTexts: ({})          // id -> raw log tail
    property string cfgMtime: ""
    property int activeTab: 0            // 0 = Servers, 1 = Logs
    property string activeLogId: ""
    property bool loading: true
    property string errorMsg: ""
    property bool logsPaused: false

    // Log view preferences (per-instance KConfig, see contents/config/main.xml).
    // Written by config/ConfigLogs.qml; the defensive coercions make a missing
    // key behave as the main.xml default.
    readonly property int logFontSize: Number(Plasmoid.configuration.logFontSize) || 0
    readonly property bool showStatErrors: Plasmoid.configuration.logShowErrors !== false
    readonly property bool showStatWarnings: Plasmoid.configuration.logShowWarnings !== false
    readonly property bool showStatOom: Plasmoid.configuration.logShowOom !== false
    readonly property bool showStatTps: Plasmoid.configuration.logShowTps !== false

    // Servers shown in the widget: enabled ones, plus any disabled one that is
    // still running (so it can always be stopped).
    readonly property var servers: allServers.filter(function (s) {
        return s.enabled || !!runningMap[s.id]
    })

    readonly property int runningCount: Object.keys(runningMap).length

    // Shown servers that can be started right now (stopped, idle, binary found).
    readonly property var startable: servers.filter(function (s) {
        if (runningMap[s.id] || pendingStarts[s.id] || pendingStops[s.id]) return false
        if (!s.enabled || s.command.trim() === "") return false
        return depsMap[Logic.serverBinary(s.command, homeDir)] !== false
    })
    // Shown servers that are running and not already being stopped.
    readonly property var stoppable: servers.filter(function (s) {
        return !!runningMap[s.id] && !pendingStops[s.id]
    })

    readonly property int missingBinaries: {
        var n = 0
        servers.forEach(function (s) {
            var b = Logic.serverBinary(s.command, homeDir)
            if (b && depsMap[b] === false) n++
        })
        return n
    }

    function serverById(id) {
        for (var i = 0; i < allServers.length; i++)
            if (allServers[i].id === id) return allServers[i]
        return null
    }

    // ── Per-instance UI state (the only thing kept in plasmoid config) ─────
    function loadUiState() {
        var st = Logic.safeJsonParse(Plasmoid.configuration.uiJson, {})
        activeTab = Number(st.activeTab) === 1 ? 1 : 0
        activeLogId = String(st.activeLogId || "")
    }
    function persistUiState() {
        Plasmoid.configuration.uiJson =
            Logic.safeJsonStringify({ activeTab: activeTab, activeLogId: activeLogId }, "{}")
    }

    // ── Serialized shell commands ──────────────────────────────────────────
    property var cmdQueue: []            // [{cmd, handler}]
    property var currentJob: null
    property int jobSerial: 0

    P5Support.DataSource {
        id: exe
        engine: "executable"
        connectedSources: []
        onNewData: function (source, data) {
            disconnectSource(source)
            if (!root.currentJob || root.currentJob.cmd !== source) return
            var job = root.currentJob
            root.currentJob = null
            root.loading = false
            if (job.handler) {
                job.handler(Number(data["exit code"]),
                            String(data["stdout"] || "").trim(),
                            String(data["stderr"] || "").trim())
            }
            root.pump()
        }
    }

    function pump() {
        if (currentJob || cmdQueue.length === 0) return
        var q = cmdQueue.slice()
        currentJob = q.shift()
        currentJob.serial = ++jobSerial
        cmdQueue = q
        exe.connectSource(currentJob.cmd)
    }

    function run(cmd, handler) {
        // Drop duplicates of a command that is already waiting (log/status polls).
        for (var i = 0; i < cmdQueue.length; i++)
            if (cmdQueue[i].cmd === cmd) return
        if (currentJob && currentJob.cmd === cmd) return
        cmdQueue = cmdQueue.concat([{ cmd: cmd, handler: handler }])
        pump()
    }

    // If the engine ever swallows a result, don't stall the queue forever.
    Timer {
        id: watchdog
        interval: 20000
        repeat: true
        running: root.currentJob !== null
        property int lastSerial: -1
        onTriggered: {
            if (root.currentJob && root.currentJob.serial === lastSerial) {
                var job = root.currentJob
                exe.disconnectSource(job.cmd)
                root.currentJob = null
                if (job.handler) job.handler(-1, "", "timeout")
                root.pump()
            }
            lastSerial = root.currentJob ? root.currentJob.serial : -1
        }
    }

    function ctl(args, handler) {
        run(Logic.scriptCmd() + " " + args, handler)
    }

    // ── Config file ────────────────────────────────────────────────────────
    function reloadConfig() {
        ctl("cfgread", function (code, out, err) {
            if (code !== 0) {
                errorMsg = i18n("Could not read %1", configPath) + (err ? ": " + err.split("\n")[0] : "")
                return
            }
            var parsed = Logic.safeJsonParse(out, null)
            if (!Array.isArray(parsed)) {
                errorMsg = i18n("%1 is not valid JSON (expected a list of servers)", configPath)
                return
            }
            allServers = Logic.normalizeServers(parsed)
            if (activeLogId === "" || !serverById(activeLogId))
                activeLogId = servers.length > 0 ? servers[0].id : ""
            refreshDeps()
            checkStatuses()
        })
    }

    // ── Status / deps ──────────────────────────────────────────────────────
    function checkStatuses() {
        var ids = allServers.map(function (s) { return Logic.shQuote(s.id) })
        ctl("statusall " + ids.join(" "), function (code, out) {
            if (code !== 0) return
            var kv = Logic.parseKv(out)
            var st = Logic.parseStatusall(out)
            // Rebuild from the script's answer: drops dead servers and adopts
            // ones started elsewhere (terminal, a previous widget instance...).
            var m = {}
            allServers.forEach(function (s) {
                var e = st[s.id]
                if (e && e.alive) m[s.id] = { pid: e.pid, logfile: e.logfile }
            })
            if (JSON.stringify(m) !== JSON.stringify(runningMap)) runningMap = m
            // servers.json changed on disk (config page, editor, another widget)
            if (kv.cfgmtime !== undefined && kv.cfgmtime !== cfgMtime) {
                var first = (cfgMtime === "")
                cfgMtime = kv.cfgmtime
                if (!first) reloadConfig()
            }
        })
    }

    function refreshDeps() {
        var bins = []
        allServers.forEach(function (s) {
            var b = Logic.serverBinary(s.command, homeDir)
            if (b && bins.indexOf(b) === -1) bins.push(b)
        })
        if (bins.length === 0) { depsMap = {}; return }
        ctl("deps " + bins.map(Logic.shQuote).join(" "), function (code, out) {
            var m = {}
            out.split("\n").forEach(function (l) {
                var i = l.lastIndexOf("=")
                if (i > 0) m[l.slice(0, i)] = l.slice(i + 1) === "OK"
            })
            depsMap = m
        })
    }

    function refreshAll() {
        reloadConfig()
    }

    // ── Actions ────────────────────────────────────────────────────────────
    function startServer(id) {
        if (pendingStarts[id] || runningMap[id]) return
        var s = serverById(id)
        if (!s) return
        var cmd = Logic.buildCommand(s, homeDir)
        if (cmd === "") {
            errorMsg = i18n("Empty command for %1", s.name)
            return
        }
        var p = Object.assign({}, pendingStarts); p[id] = true; pendingStarts = p
        ctl("start " + Logic.shQuote(id) + " " + Logic.shQuote(cmd), function (code, out, err) {
            pendingStarts = Logic.withoutKey(pendingStarts, id)
            var kv = Logic.parseKv(out)
            if (code !== 0 || kv.error || !kv.pid) {
                var detail = kv.logerror || (kv.error && kv.error !== "start_failed" ? kv.error : "")
                             || (err ? err.split("\n")[0] : "")
                errorMsg = i18n("Failed to start %1", s.name) + (detail !== "" ? ": " + detail : "")
                if (kv.error === "already_running") checkStatuses()
                return
            }
            errorMsg = ""
            var m = Object.assign({}, runningMap)
            m[id] = { pid: Number(kv.pid), logfile: String(kv.logfile || "") }
            runningMap = m
        })
    }

    function stopServer(id) {
        if (!runningMap[id] || pendingStops[id]) return
        var p = Object.assign({}, pendingStops); p[id] = true; pendingStops = p
        ctl("stop " + Logic.shQuote(id), function () {
            pendingStops = Logic.withoutKey(pendingStops, id)
            runningMap = Logic.withoutKey(runningMap, id)
            checkStatuses()
        })
    }

    function startAll() {
        startable.forEach(function (s) { startServer(s.id) })
    }

    function stopAll() {
        stoppable.forEach(function (s) { stopServer(s.id) })
    }

    function openConfig() {
        var a = Plasmoid.internalAction("configure")
        if (a) a.trigger()
    }

    function showLogs(id) {
        activeLogId = id
        activeTab = 1
        persistUiState()
        tailLog()
    }

    function tailLog() {
        var id = activeLogId
        var s = serverById(id)
        var e = runningMap[id]
        if (!s) return
        if (!e) {
            // Server stopped: keep whatever the last session printed.
            if (logTexts[id] === undefined) {
                var lt0 = Object.assign({}, logTexts); lt0[id] = ""; logTexts = lt0
            }
            return
        }
        ctl("logread " + Logic.shQuote(e.logfile) + " 400", function (code, out) {
            if (code !== 0) return
            if (logTexts[id] === out) return
            var lt = Object.assign({}, logTexts); lt[id] = out; logTexts = lt
        })
    }

    // ── Timers ─────────────────────────────────────────────────────────────
    Timer {
        interval: root.expanded ? 2000 : 5000
        running: root.homeDir !== ""
        repeat: true
        onTriggered: root.checkStatuses()
    }
    Timer {
        interval: 500
        running: root.expanded && root.activeTab === 1 && !root.logsPaused && root.activeLogId !== ""
        repeat: true
        onTriggered: root.tailLog()
    }
    onExpandedChanged: if (expanded && homeDir !== "") checkStatuses()

    Component.onCompleted: {
        loadUiState()
        ctl("init", function (code, out) {
            var kv = Logic.parseKv(out)
            homeDir = kv.home || ""
            configPath = kv.config || ""
            reloadConfig()
        })
    }

    // ════════════════════════════════════════════════════════════════════════
    //  COMPACT VIEW
    // ════════════════════════════════════════════════════════════════════════
    compactRepresentation: MouseArea {
        id: compactRoot
        property bool wasExpanded: false
        acceptedButtons: Qt.LeftButton
        hoverEnabled: true
        onPressed: wasExpanded = root.expanded
        onClicked: root.expanded = !wasExpanded

        Kirigami.Icon {
            anchors.fill: parent
            active: compactRoot.containsMouse
            source: "network-server-symbolic"
        }

        Rectangle {
            visible: root.runningCount > 0
            anchors { right: parent.right; bottom: parent.bottom; margins: 2 }
            width: Math.max(8, parent.width * 0.28); height: width; radius: width / 2
            color: Kirigami.Theme.positiveTextColor
            border.color: Kirigami.Theme.backgroundColor
            border.width: 1
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  FULL VIEW
    // ════════════════════════════════════════════════════════════════════════
    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth:  Kirigami.Units.gridUnit * 24
        Layout.minimumHeight: Kirigami.Units.gridUnit * 24
        Layout.preferredWidth:  Kirigami.Units.gridUnit * 28
        Layout.preferredHeight: Kirigami.Units.gridUnit * 30
        collapseMarginsHint: true

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            Kirigami.InlineMessage {
                id: errorBanner
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                type: Kirigami.MessageType.Error
                showCloseButton: true
                visible: root.errorMsg !== ""
                text: root.errorMsg
                // Closing the banner breaks the binding above, so re-drive it.
                onVisibleChanged: if (!visible) root.errorMsg = ""
                Connections {
                    target: root
                    function onErrorMsgChanged() { errorBanner.visible = root.errorMsg !== "" }
                }
            }

            MainPage {
                backend: root
                Layout.fillWidth: true
                Layout.fillHeight: true
            }
        }
    }
}
