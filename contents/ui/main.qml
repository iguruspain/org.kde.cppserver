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
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

import "logic.js" as Logic

// Bound component behavior: no implicit capture of outer scope in nested
// components (delegates, representations).
pragma ComponentBehavior: Bound
// The two categories qmllint can never see here: the runtime-injected i18n()
// global, and the kcfg schema (contents/config/main.xml) behind
// Plasmoid.configuration (this qmllint has no --project/kcfg support).
// Everything else stays checked.
// qmllint disable unqualified
// qmllint disable missing-property

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
                    : i18n("%1 / %2 running", runningCount, servers.length)

    // ── State ──────────────────────────────────────────────────────────────
    property string homeDir: ""
    property string configPath: ""
    property var allServers: []          // everything in servers.json
    // strata engines already running when the plasmoid did not start them
    // (terminal, another session): read-only synthetic entries built from
    // statusall's external-<slug> lines, never written to servers.json
    property var externalServers: []
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
    property var statsMap: ({})          // id -> { ep, kind, err, health, body, at }
    property var statsTally: ({})        // id -> "model (vX)" (generic /health servers)
    property var statsStickMaps: ({})    // id -> last-good scalars (llama anti-flicker)
    property var statsLiveMaps: ({})     // id -> {active, tps}: CURRENT speed, generating only (tokSample gate)
    property var statsModels: ({})       // id -> model name recovered from the log
    property var statsScanAt: ({})       // id -> last whole-log marker scan (hot-swap re-scan)
    property var gpuInfo: ({})           // parseGpu(): per-pid VRAM + machine totals
    property var gpuHist: ({})           // pushHist(): rolling ~60-sample machine history

    // Log view preferences (per-instance KConfig, see contents/config/main.xml).
    // Written by config/ConfigLogs.qml; the defensive coercions make a missing
    // key behave as the main.xml default.
    readonly property int logFontSize: Number(Plasmoid.configuration.logFontSize) || 0
    readonly property bool logFontAuto: Plasmoid.configuration.logFontAuto !== false
    // When auto is on the SpinBox value is ignored and the log follows the
    // desktop theme. Falls back to the theme font if auto is off but no value
    // was stored yet (older config).
    readonly property real logFontPointSize: logFontAuto
        ? Kirigami.Theme.smallFont.pointSize
        : (Number(Plasmoid.configuration.logFontSize) > 0
            ? Number(Plasmoid.configuration.logFontSize)
            : Kirigami.Theme.smallFont.pointSize)
    readonly property bool showStatErrors: Plasmoid.configuration.logShowErrors !== false
    readonly property bool showStatWarnings: Plasmoid.configuration.logShowWarnings !== false
    readonly property bool showStatOom: Plasmoid.configuration.logShowOom !== false
    readonly property bool showStatTps: Plasmoid.configuration.logShowTps !== false

    // Stats-tab monitor switches (config/ConfigStats.qml): the probe cadence
    // plus the block switches (machine rings / extra-info tiles / card
    // totals and tables). VRAM is part of the machine block now — there is
    // no separate VRAM toggle anymore.
    // The kcfg SpinBox already offers 250..10000 ms; the clamp is the net
    // for hand-edited config files (NaN/0/negative → the 1000 ms default).
    readonly property int statSampleMs: {
        var v = Math.round(Number(Plasmoid.configuration.statSampleMs))
        if (!(v > 0)) return 1000
        return Math.max(250, Math.min(10000, v))
    }
    readonly property bool statShowHardware: Plasmoid.configuration.statShowHardware !== false
    readonly property bool statShowVramLegend: Plasmoid.configuration.statShowVramLegend !== false
    readonly property bool statShowSparklines: Plasmoid.configuration.statShowSparklines !== false
    readonly property bool statShowExtra: Plasmoid.configuration.statShowExtra !== false
    readonly property bool statShowTps: Plasmoid.configuration.statShowTps !== false
    readonly property bool statShowGpuTemp: Plasmoid.configuration.statShowGpuTemp !== false
    readonly property bool statShowGpuPower: Plasmoid.configuration.statShowGpuPower !== false
    readonly property bool statShowDisk: Plasmoid.configuration.statShowDisk !== false
    readonly property bool statShowTokens: Plasmoid.configuration.statShowTokens !== false
    readonly property bool statShowEvents: Plasmoid.configuration.statShowEvents !== false

    // Servers shown in the widget: enabled ones, plus any disabled one that is
    // still running (so it can always be stopped), plus external strata
    // engines (always running, read-only: no config entry, no Start).
    readonly property var servers: allServers.filter(function (s) {
        return s.enabled || !!runningMap[s.id]
    }).concat(externalServers)

    readonly property int runningCount: Object.keys(runningMap).length

    // Shown servers that can be started right now (stopped, idle, binary found).
    readonly property var startable: servers.filter(function (s) {
        if (s.external) return false     // external engines: stop only, never start
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
        for (let i = 0; i < allServers.length; i++)
            if (allServers[i].id === id) return allServers[i]
        for (let j = 0; j < externalServers.length; j++)
            if (externalServers[j].id === id) return externalServers[j]
        return null
    }

    // ── Per-instance UI state (the only thing kept in plasmoid config) ─────
    function loadUiState() {
        var st = Logic.safeJsonParse(Plasmoid.configuration.uiJson, {})
        activeTab = [1, 2].indexOf(Number(st.activeTab)) !== -1 ? Number(st.activeTab) : 0
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
        for (let i = 0; i < cmdQueue.length; i++)
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
                const job = root.currentJob
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
            // strata engines started OUTSIDE the widget: read-only external
            // cards under their own id. They never own a pidfile/marker, so
            // the plasmoid's pid guard and an external engine can never
            // shadow each other.
            var exts = []
            Object.keys(st).forEach(function (k) {
                var slugPart = k.slice(9)   // "external-" prefix length
                if (k.indexOf("external-") !== 0 || !st[k].alive) return
                exts.push({ id: k, external: true,
                            name: i18n("strata (external %1)", slugPart),
                            command: "strata", host: "127.0.0.1",
                            port: parseInt(kv["extport-" + slugPart] || "", 10) || 18888,
                            configFile: "", preset: "", enabled: true })
                m[k] = { pid: st[k].pid, logfile: st[k].logfile }
            })
            if (JSON.stringify(exts) !== JSON.stringify(externalServers)) externalServers = exts
            if (JSON.stringify(m) !== JSON.stringify(runningMap)) runningMap = m
            // servers.json changed on disk (config page, editor, another widget)
            if (kv.cfgmtime !== undefined && kv.cfgmtime !== cfgMtime) {
                const first = (cfgMtime === "")
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
        if (!s || s.external) return
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
                const detail = kv.logerror || (kv.error && kv.error !== "start_failed" ? kv.error : "")
                             || (err ? err.split("\n")[0] : "")
                errorMsg = i18n("Failed to start %1", s.name) + (detail !== "" ? ": " + detail : "")
                if (kv.error === "already_running") checkStatuses()
                return
            }
            errorMsg = ""
            var m = Object.assign({}, runningMap)
            m[id] = { pid: String(kv.pid || ""), logfile: String(kv.logfile || "") }
            runningMap = m
            // a started server shows up in the Stats tab right away
            if (expanded && activeTab === 2) pollStats()
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
                const lt0 = Object.assign({}, logTexts); lt0[id] = ""; logTexts = lt0
            }
            return
        }
        ctl("logread " + Logic.shQuote(e.logfile) + " 400", function (code, out) {
            if (code !== 0) return
            if (logTexts[id] === out) return
            var lt = Object.assign({}, logTexts); lt[id] = out; logTexts = lt
        })
    }

    // ── Live stats (Stats tab) ─────────────────────────────────────────────
    // One HTTP probe per running server per tick, through the same
    // single-flight queue. Endpoint chain: /health first (tiny, identifies
    // the server — strata answers {"service":"strata"}), then /metrics every
    // later tick for strata and for llama-server (--metrics) — those two are
    // probed at /metrics right away. Everything else stays on /health.
    function pollStats() {
        var m = {}
        Object.keys(runningMap).forEach(function (id) {
            var s = serverById(id)
            if (!s) return
            var url = Logic.browserUrl(s)
            if (url === "") {
                m[id] = { ep: "", kind: "none", err: "no_port", health: "", body: "", at: Date.now() }
                return
            }
            var cur = statsMap[id]
            // log-fed servers: llama (with or without --metrics) and
            // audio.cpp — both stream their state from their own log tail
            var bin = Logic.serverBinary(s.command, homeDir).split("/").pop().toLowerCase()
            var isLlama = bin === "llama-server" || bin === "llama-serve"
            var isAudio = bin.indexOf("audiocpp") === 0
            var ep = "health"
            if ((cur && cur.ep === "metrics") || (cur && cur.kind === "strata")) ep = "metrics"
            else if (!cur && isLlama) ep = "metrics"
            var target = url + ep
            run(Logic.scriptCmd() + " probe " + Logic.shQuote(target), function (code, out) {
                applyProbe(id, ep, code, out, isLlama, isAudio)
            })
        })
        // one machine snapshot per tick: nvidia-smi (per-pid VRAM, GPU totals,
        // names) + /proc + /sys (RAM, CPU%, cores/threads, disk) — the whole
        // machine block works with no server reporting anything
        run(Logic.scriptCmd() + " gpu", function (code, out) {
            var g = code === 0 ? Logic.parseGpu(out) : {}
            // machine token-speed sample for the Speed tile sparkline:
            // the live t/s across running servers — but a server only
            // contributes WHILE generating (its log/metrics speed is a
            // current figure then); an idle server contributes 0, so the
            // series falls back to zero like strata's tok_s history
            var samp = -1
            Object.keys(runningMap).forEach(function (sid) {
                // runningMap only EVER contains live servers (rebuilt from
                // statusall's alive entries as { pid, logfile }) - there is
                // no ".alive" field to consult
                if (!runningMap[sid]) return
                var lv = statsLiveMaps[sid]
                var v = (lv && lv.active && lv.tps > 0) ? lv.tps : 0
                if (v > samp) samp = v
            })
            if (samp >= 0) g.tokSample = samp
            gpuInfo = g
            if (code === 0) gpuHist = Logic.pushHist(gpuHist, g, 60)
        })
        // merge, never wipe: a slow probe replies after this tick, and wiping
        // here loses its "metrics" state → the endpoint chain would restart
        // from /health every tick and starve the dashboard
        statsMap = Object.assign({}, statsMap, m)
    }

    // The per-card request feeds: every parsed request — strata's /metrics
    // requests and llama.cpp print_timing log rows — is formatted per
    // column and kept SEPARATE per server id; each Stats card draws its
    // own table from statsFeedMaps[id] (audio cards from their audioReqs:
    // TTS/ASR have no token/context columns, so their rows carry family,
    // chunks, wall time and an i18n state label instead).
    property var statsFeedMaps: ({})
    // format one server's request rows into final table strings
    function feedRowsOf(st) {
        if (st.kind === "audio") {
            return st.audioReqs.map(function (r) {
                return {
                    time: r.at > 0 ? Logic.fmtClock(r.at) : "–",
                    model: r.fam || "",
                    status: r.err ? i18n("error")
                          : r.running ? i18n("generating") : i18n("done"),
                    chunks: root.statShowTokens ? String(r.chunks) : "–",
                    wall: Logic.fmtFeedMs(r.durMs),
                    first: root.statShowTokens ? Logic.fmtFeedTtfb(r.ttfbMs) : "–",
                    // not a column: the State column's errKey paints these
                    // rows negativeTextColor
                    err: !!r.err
                }
            })
        }
        return Logic.serverReqFeed(st.reqs, root.statShowTokens)
    }
    function refreshReqStream() {
        var next = {}
        servers.forEach(function (s) {
            var e = statsMap[s.id]
            if (!e) return
            var st = Logic.parseStats(e, reqSeenOf(s.id), statsExtraOf(s.id))
            var rows = feedRowsOf(st)
            // idle servers produce an identical feed every tick: keep the
            // same array reference so that card's ReqTable never
            // re-measures/rebinds for nothing
            var old = statsFeedMaps[s.id]
            if (old && JSON.stringify(old) === JSON.stringify(rows))
                rows = old
            next[s.id] = rows
            // live speed feed for the Speed tile: t/s is only a CURRENT
            // figure while the server is actually generating — an idle
            // llama server holds its last tg in the sticky cache forever,
            // which is exactly what made the tile plateau instead of
            // falling to 0 like strata's tok_s does
            var lv = statsLiveMaps[s.id]
            if (!lv) {
                lv = {}
                statsLiveMaps[s.id] = lv
            }
            lv.active = !!st.active
            lv.tps = (typeof st.tps === "number" && st.tps > 0) ? st.tps : 0
        })
        // only touch the property when some feed actually changed: the
        // stable array references ride along, so cards rebind only for
        // the servers whose stream moved
        var ids = Object.keys(next)
        var dirty = ids.length !== Object.keys(statsFeedMaps).length
        ids.forEach(function (k) {
            if (statsFeedMaps[k] !== next[k]) dirty = true
        })
        if (dirty) statsFeedMaps = next
    }
    // the token columns of both the feeds and the cards react to the
    // Stats toggle without waiting for a probe to move
    onStatShowTokensChanged: refreshReqStream()

    // llama.cpp logs carry no wall-clock: remember when each task id was
    // first observed (per server) so the card's request table can sort.
    property var reqSeenMaps: ({})
    function reqSeenOf(id) {
        var m = reqSeenMaps[id]
        if (!m) {
            m = {}
            reqSeenMaps[id] = m
        }
        return m
    }

    // parseStats extras for one server: a persistent last-good value cache
    // (llama.cpp reports nothing between requests — without it the card
    // and the speed tile flicker 0/– between ticks) plus the model name
    // recovered from the log. Mutated in place: no property reassignment
    // inside a binding (parseStats runs from the rows binding).
    function statsExtraOf(id) {
        if (!statsStickMaps[id]) statsStickMaps[id] = {}
        return { stick: statsStickMaps[id], model: statsModels[id] || "" }
    }

    // llama.cpp prints the model it loads ("loading model '/x.gguf'",
    // older builds "loading model from '...'"): harvest the marker from a
    // log tail. The model name is what the Stats card shows.
    function noteModelMarkers(id, text) {
        var rx = /loading model(?: from)? '([^']*)'/g
        var m, last = ""
        while ((m = rx.exec(String(text || ""))) !== null) last = m[1]
        var name = String(last).split("/").pop()
        if (name !== "" && statsModels[id] !== name) {
            statsModels[id] = name
            // A model swap resets llama's task ids: the stamps held for
            // them belong to a dead epoch (a finished row can even show a
            // future clock). Drop them; this run re-stamps with real time.
            delete reqSeenMaps[id]
        }
    }
    // The load marker sits in the startup lines and ages out of every tail
    // window: ask the script for the marker lines of the WHOLE log — right
    // away, then every 30 s while the server runs, so a model hot-swapped
    // without a restart shows up. The scan is change-driven: identical
    // markers never touch statsModels (nothing to re-render).
    function scanModelMarkers(id) {
        statsScanAt[id] = Date.now()
        var r = runningMap[id]
        if (!r || !r.logfile) return
        ctl("logread " + Logic.shQuote(r.logfile) + " markers", function (code, out) {
            if (code !== 0) return
            noteModelMarkers(id, out)
        })
    }

    // A server that stopped (button, crash, another instance) leaves
    // nothing behind in the Stats tab: its card, its request rows, its
    // sticky values, recovered model and seen-task stamps are all dropped,
    // so a restart re-probes from zero instead of showing stale ghosts.
    function forgetServerStats(id) {
        statsMap = Logic.withoutKey(statsMap, id)
        statsTally = Logic.withoutKey(statsTally, id)
        delete statsStickMaps[id]
        delete statsLiveMaps[id]
        delete statsModels[id]
        delete statsScanAt[id]
        delete reqSeenMaps[id]
    }
    onRunningMapChanged: {
        var gone = []
        Object.keys(statsMap).forEach(function (id) {
            if (!runningMap[id]) gone.push(id)
        })
        if (gone.length === 0) return
        gone.forEach(function (id) { forgetServerStats(id) })
        refreshReqStream()
    }

    function applyProbe(id, ep, code, out, isLlama, isAudio) {
        var body = String(out || "")
        var prev = statsMap[id]
        var entry = { ep: ep, kind: "none", err: "", health: "", body: "", log: "", at: Date.now() }

        // A log-fed server (llama.cpp, audio.cpp) streams its real state
        // from its own log, so the tail read is issued on EVERY probe tick
        // no matter how this tick classifies: the transparent/dedup paths
        // below must never be able to stop its only pump. An empty or
        // failed read during bootstrap (fresh router log, callback race)
        // is retried next tick; without that retry a stuck empty entry
        // would stay dead forever. (For llama this pairs with the
        // /metrics probe; audio has no metrics endpoint at all — the
        // /health probe just proves it answers, the log carries data.)
        if (isLlama || isAudio) tailStatsLog(id, isAudio ? "audio" : "llama")
        if (code !== 0) {
            entry.err = body.indexOf("error=") === 0 ? body.slice(6) : "unreachable"
        } else if (body.charAt(0) === "{") {
            const j = Logic.safeJsonParse(body, null)
            // strata answers /health with service=strata, but /metrics does
            // not carry that key: its engine+history sections label it
            entry.kind = (j && (j.service === "strata" || (j.engine && j.history)))
                         ? "strata" : "json"
            if (isAudio) entry.kind = "audio"  // /health JSON, real state in the log
            if (ep === "health") entry.health = body
            else entry.body = body
        } else if (body.indexOf("llm:") !== -1 || body.indexOf("llamacpp:") !== -1 || body.charAt(0) === "#") {
            entry.kind = "llama"
            entry.body = body
        } else if (isAudio) {
            entry.kind = "audio"              // health answered without JSON
        } else {
            entry.err = "no_metrics"      // HTML error page, plain-text 404…
        }

        // A log-fed server's probe can carry no new data (llama 404s
        // /metrics without --metrics; audio's /health body never changes):
        // the probe must not touch anything. The logread command is the
        // ONLY thing that moves their stats forward — an empty probe tick
        // leaves card, ring and request table exactly as they are (no
        // downgrade to "none", no blank half-second, no re-render).
        if (prev && (prev.kind === "llama" || prev.kind === "audio" || prev.log) && entry.kind === "none")
            return
        // The probe lands every tick, but the log tail it pairs with
        // arrives ~200 ms later on its own command: carry last tail +
        // classification through that gap (the rebuild below only happens
        // when the probe really reports something new).
        if (prev && prev.log) {
            entry.log = prev.log
            if ((isLlama && prev.kind === "llama") || (isAudio && prev.kind === "audio"))
                entry.kind = prev.kind
        }
        if (ep === "metrics" && entry.kind !== "llama" && entry.kind !== "strata"
            && entry.err === "")
            entry.err = "no_metrics"     // probe answered but not Prometheus
        // Nothing changed since the last tick → keep the entry object as
        // it is: no reassignment, no re-parse, no table/card churn. Only
        // content counts; `at` alone is not news.
        if (prev && prev.ep === entry.ep && prev.kind === entry.kind &&
            prev.err === entry.err && prev.body === entry.body &&
            prev.log === entry.log && prev.health === entry.health)
            return
        var sm = Object.assign({}, statsMap)
        sm[id] = entry
        statsMap = sm

        // (The llama tail pump was already issued at the top of applyProbe.)

        // A generic JSON /health server has no model of its own in the stats
        // parser; the version tally from its /health body labels the card.
        var tal = Object.assign({}, statsTally)
        if (entry.kind === "json" && entry.health) tal[id] = Logic.healthTally(entry.health)
        else tal[id] = ""
        statsTally = tal
        refreshReqStream()
    }

    // The log tail probe for the log-fed servers (llama.cpp / audio.cpp):
    // an identical tail means nothing happened — the entry stays
    // byte-for-byte intact and the UI never sees the tick. Only a changed
    // tail rebuilds the entry, re-parses and refreshes the request stream
    // (grid, table, ring, the audio card's own feed — sources aside).
    function tailStatsLog(id, kind) {
        var r = runningMap[id]
        if (!r || !r.logfile) return
        // 400 lines: one prefill burst (checkpoint/cache chatter) or a
        // burst of health chatter can blow through a small window between
        // two ticks, and losing the "processing task" line mid-request
        // would drop that request's live row for a beat
        ctl("logread " + Logic.shQuote(r.logfile) + " 400", function (code2, out2) {
            if (code2 !== 0) return
            var cur = statsMap[id]
            if (!cur || cur.log === out2) return
            cur = Object.assign({}, cur, { log: out2, at: Date.now() })
            // no metrics endpoint but a readable log: the tail is a valid
            // stats source; a stale no_metrics hint stays on the chip
            if (cur.kind !== "llama" && cur.kind !== "audio") cur.kind = kind
            var sm2 = Object.assign({}, statsMap)
            sm2[id] = cur
            statsMap = sm2
            if (kind === "audio") {
                // the audio model is per request (lazy_load): keep it warm
                // in the cross-restart cache so an idle window whose lines
                // aged out of the tail still labels the card
                const st = Logic.parseStats(cur, {}, {})
                if (st.model && statsModels[id] !== st.model) statsModels[id] = st.model
            } else {
                // the loaded model is a log fact: harvest markers from the
                // tail, and re-scan the whole log every 30 s (hot-swaps age
                // out of the tail window; identical markers change nothing)
                noteModelMarkers(id, out2)
                if (!statsModels[id] || Date.now() - (statsScanAt[id] || 0) > 30000)
                    scanModelMarkers(id)
            }
            refreshReqStream()
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
    Timer {
        // the Stats config's sampling frequency (statSampleMs, default 1 s):
        // one HTTP probe per running server + one machine snapshot per tick
        interval: root.statSampleMs
        running: root.expanded && root.activeTab === 2
        repeat: true
        onTriggered: root.pollStats()
    }
    onExpandedChanged: if (root.expanded && root.homeDir !== "") root.checkStatuses()

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
            id: compactIcon
            anchors.fill: parent
            active: compactRoot.containsMouse
            source: "network-server-symbolic"
        }

        // Power LED: a small circle over the glyph's lower-right slot, like a
        // server front-panel indicator light. Breeze network-server-symbolic is a
        // 22x22 canvas with the face at x/y 3..19 and a lower-right slot at
        // x 14..18 / y 16..17 (SVG at
        // /usr/share/icons/breeze/places/22/network-server-symbolic.svg).
        Rectangle {
            id: statusLed
            visible: root.runningCount > 0 && compactIcon.paintedWidth > 0
            width: compactIcon.paintedWidth * 0.28
            height: width
            radius: width / 2
            color: Kirigami.Theme.positiveTextColor
            border.color: Kirigami.Theme.backgroundColor
            border.width: 1
            x: compactIcon.x + (compactIcon.width - compactIcon.paintedWidth) / 2
                + compactIcon.paintedWidth * (6 / 22) - width / 2
            y: compactIcon.y + (compactIcon.height - compactIcon.paintedHeight) / 2
                + compactIcon.paintedHeight * (18 / 22) - height / 2
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
