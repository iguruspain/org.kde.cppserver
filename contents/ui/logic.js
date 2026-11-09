// SPDX-License-Identifier: MIT
// Pure helpers for the org.kde.cppserver plasmoid (no QML state in here).
.pragma library

function safeJsonParse(text, fallback) {
    if (typeof text !== "string" || text === "") return fallback;
    try {
        const v = JSON.parse(text);
        return (v !== null && typeof v === "object") ? v : fallback;
    } catch (e) {
        return fallback;
    }
}

function safeJsonStringify(value, fallback) {
    try {
        return JSON.stringify(value === undefined ? null : value);
    } catch (e) {
        return fallback;
    }
}

// ── Shell helpers ───────────────────────────────────────────────────────────
function shQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'";
}

function scriptPath() {
    const url = Qt.resolvedUrl("../scripts/cppserverctl.sh").toString();
    return decodeURIComponent(url.startsWith("file://") ? url.slice(7) : url);
}

function scriptCmd() {
    return "bash " + shQuote(scriptPath());
}

// Expand $HOME, ${HOME} and a leading ~ (start of a word, after = or a quote).
function homeExpand(text, homeDir) {
    let t = String(text || "");
    if (!homeDir) return t;
    t = t.split("${HOME}").join(homeDir).split("$HOME").join(homeDir);
    return t.replace(/(^|[\s='"])~(?=\/|$|\s|['"])/g, "$1" + homeDir);
}

// ── Server records ──────────────────────────────────────────────────────────
// Same character mapping as slug() in cppserverctl.sh.
function slugify(name) {
    return String(name || "").toLowerCase().replace(/[^a-z0-9_-]/g, "-")
        .replace(/-{2,}/g, "-").replace(/^-+|-+$/g, "");
}

// Turn whatever is in servers.json into a clean, id-unique array.
function normalizeServers(raw) {
    const list = Array.isArray(raw) ? raw : [];
    const used = {};
    const out = [];
    list.forEach(function (s) {
        if (!s || typeof s !== "object") return;
        const base = slugify(s.id || s.name) || "server";
        let id = base, n = 2;
        while (used[id]) id = base + "-" + (n++);
        used[id] = true;
        out.push({
            id: id,
            name: String(s.name || ""),
            command: String(s.command || ""),
            host: String(s.host || ""),
            port: Math.max(0, Math.min(65535, Math.floor(Number(s.port)) || 0)),
            configFile: String(s.configFile || ""),
            preset: String(s.preset || "").trim(),
            enabled: s.enabled !== false
        });
    });
    return out;
}

// First "real" word of the command (skips FOO=bar assignments and env).
function serverBinary(command, homeDir) {
    const words = String(command || "").trim().split(/\s+/);
    for (let i = 0; i < words.length; i++) {
        const w = words[i];
        if (w === "" || w === "env" || /^[A-Za-z_][A-Za-z0-9_]*=/.test(w)) continue;
        return homeExpand(w.replace(/^["']|["']$/g, ""), homeDir);
    }
    return "";
}

function endpointText(s) {
    const host = String(s.host || "");
    const port = Number(s.port) || 0;
    if (host && port > 0) return host + ":" + port;
    if (host) return host;
    if (port > 0) return ":" + port;
    return "";
}

// URL to open in a browser, or "" when the server has no port.
function browserUrl(s) {
    const port = Number(s.port) || 0;
    if (port <= 0) return "";
    let host = String(s.host || "");
    if (host === "" || host === "0.0.0.0" || host === "::") host = "127.0.0.1";
    return "http://" + host + ":" + port + "/";
}

// ── Command building ────────────────────────────────────────────────────────
const SAFE_VALUE = /^[A-Za-z0-9_@%+=:,.\/-]+$/;

// Replace {TOKEN} (optionally wrapped in quotes) with a shell-safe value.
// When the value is empty, the flag in front of it is dropped as well:
//   "--port {PORT}" with port 0  ->  ""
function subToken(cmd, token, value) {
    if (value === "") {
        const flagRe = new RegExp("\\s+-{1,2}[\\w-]+(?:\\s+|=)([\"'])?\\{" + token + "\\}\\1", "g");
        return cmd.replace(flagRe, "").replace(new RegExp("([\"'])?\\{" + token + "\\}\\1", "g"), "");
    }
    const q = SAFE_VALUE.test(value) ? value : shQuote(value);
    return cmd.replace(new RegExp("([\"'])?\\{" + token + "\\}\\1", "g"), function () { return q; });
}

function buildCommand(server, homeDir) {
    let cmd = homeExpand(server.command, homeDir);
    const host = homeExpand(server.host, homeDir);
    const port = (Number(server.port) > 0) ? String(Math.floor(Number(server.port))) : "";
    const cfg = homeExpand(server.configFile, homeDir);
    const preset = homeExpand(server.preset, homeDir);
    cmd = subToken(cmd, "CONFIG_FILE", cfg);
    cmd = subToken(cmd, "PRESET", preset);
    cmd = subToken(cmd, "PORT", port);
    cmd = subToken(cmd, "HOST", host);
    return cmd.trim();
}

// ── Logs ────────────────────────────────────────────────────────────────────
// Keep only the lines matching `filter` (case-insensitive). Plain substring by
// default; with useRegex the filter is a regular expression. An empty filter
// returns the text unchanged; an invalid regex matches nothing and sets ok=false.
// Returns { text, ok, matched, total }.
function filterLines(text, filter, useRegex) {
    const t = String(text || "");
    const f = String(filter || "");
    if (f === "") return { text: t, ok: true, matched: 0, total: 0 };
    const lines = t.split("\n");
    let test;
    if (useRegex) {
        let rx;
        try { rx = new RegExp(f, "i"); } catch (e) {
            return { text: t, ok: false, matched: lines.length, total: lines.length };
        }
        test = function (l) { return rx.test(l); };
    } else {
        const needle = f.toLowerCase();
        test = function (l) { return l.toLowerCase().indexOf(needle) !== -1; };
    }
    const kept = lines.filter(test);
    return { text: kept.join("\n"), ok: true, matched: kept.length, total: lines.length };
}

// ── Log statistics ────────────────────────────────────────────────────────
// One pass over the tail: each line is counted at most once, most specific
// category wins (OOM > error > warning). glog-style level prefixes
// ("12.34.56.789 E " / " W ", optionally with a "[pid] " in front) catch
// llama.cpp lines that don't name the level word. Lines matching EXCEPT_RE
// (benign lines with error-like words, e.g. llama.cpp "failed to read tensor
// info", "tensor name 4 is too long") are skipped entirely.
// t/s: curTps is the last rate seen (the last "N t/s" on the line — tg_3s in
// current llama.cpp output; 0 when none). minTps/maxTps accumulate since the
// last MODEL_CHANGE_RE match (reset on each marker), so with no marker in
// the tail they span the whole tail.
const EXCEPT_RE = /failed to read tensor info|tensor name \d+ is too long/i;
const OOM_RE   = /out of (video |host )?memory|cannot allocate|memory allocation (failed|error)|no space left on device|not enough (video |host )?memory|cudaerrormemoryallocation/i;
const ERROR_RE = /\b(errors?|failed?|failure|fatal|aborted?|panic|exception|segfault|segmentation fault|core dumped|critical|backtrace)\b|^\s*(?:\[\d+\] )?\d+\.\d+\.\d+\.\d+ E /i;
const WARN_RE  = /warn(ing|s|ed)?\b|deprecat|^\s*(?:\[\d+\] )?\d+\.\d+\.\d+\.\d+ W /i;
const TPS_RE   = /([0-9]+(?:\.[0-9]+)?)\s*t\/s\b/g;
// Lines that mark a (re)load of the model in llama.cpp logs (router/preset
// swaps and classic single-model loads). Cumulative t/s min/max restart after
// the last occurrence in the visible tail.
const MODEL_CHANGE_RE = /llama_server:\s*model loaded|load_model:\s*loading model |spawning server instance with name=|ensure_model:\s*slot available|loaded \d+ model files/i;

function logStats(text) {
    const lines = String(text || "").split("\n");
    let oom = 0, errors = 0, warnings = 0;
    let curTps = 0, minTps = 0, maxTps = 0;
    for (let i = 0; i < lines.length; i++) {
        const l = lines[i];
        if (l === "") continue;
        if (MODEL_CHANGE_RE.test(l)) { minTps = 0; maxTps = 0; }
        if (EXCEPT_RE.test(l)) continue;
        if (OOM_RE.test(l)) oom++;
        else if (ERROR_RE.test(l)) errors++;
        else if (WARN_RE.test(l)) warnings++;
        // Last "N t/s" on the line (tg_3s in current llama.cpp output).
        let value = 0;
        TPS_RE.lastIndex = 0;
        let m;
        while ((m = TPS_RE.exec(l)) !== null) value = Number(m[1]);
        if (value > 0) {
            curTps = value;
            if (minTps === 0 || value < minTps) minTps = value;
            if (value > maxTps) maxTps = value;
        }
    }
    return { oom: oom, errors: errors, warnings: warnings, curTps: curTps, minTps: minTps, maxTps: maxTps };
}

// ── Log line highlighting ────────────────────────────────────────────────
// All [start, end) ranges where `filter` matches `line` — same semantics as
// filterLines: case-insensitive substring by default, regular expression
// when useRegex. Empty filter or invalid regex -> []. Zero-length matches
// are skipped.
function matchRanges(line, filter, useRegex) {
    const ranges = [];
    const f = String(filter || "");
    if (f === "") return ranges;
    if (useRegex) {
        let rx;
        try { rx = new RegExp(f, "gi"); } catch (e) { return ranges; }
        let m;
        while ((m = rx.exec(line)) !== null) {
            if (m[0] !== "") ranges.push([m.index, m.index + m[0].length]);
            else rx.lastIndex++;
        }
        return ranges;
    }
    const lower = line.toLowerCase();
    const needle = f.toLowerCase();
    let i = lower.indexOf(needle);
    while (i !== -1) {
        ranges.push([i, i + needle.length]);
        i = lower.indexOf(needle, i + needle.length);
    }
    return ranges;
}

// CSS-safe color for rich-text spans: QML stringifies semi-transparent
// colors as "#aarrggbb", which the CSS parser may not accept — convert to
// rgba(); "#rrggbb" and "rgba(…)" pass through unchanged.
function colorToCss(color) {
    const m = /^#?([0-9a-f]{8})$/i.exec(String(color || "").trim());
    if (m) {
        const v = Number("0x" + m[1]);
        return "rgba(" + ((v >> 16) & 0xff) + "," + ((v >> 8) & 0xff) + "," + (v & 0xff) + ","
            + (((v >>> 24) & 0xff) / 255).toFixed(2) + ")";
    }
    return String(color || "");
}

// HTML for a RichText TextArea: the lines logStats() counts (OOM/error in
// errorColor, warnings in warningColor) get a colored <span>; when a filter
// is active (non-empty filterText) the matching substrings additionally get
// a matchColor background and matchTextColor text, like the native text
// selection. Escapes & < > and joins lines with <br>, because a bare newline
// is collapsed by the rich-text parser. Empty color args return the text
// unchanged so callers can keep a PlainText fallback.
function highlightLog(text, errorColor, warningColor, filterText, useRegex,
                       matchColor, matchTextColor) {
    const t = String(text || "");
    if (!errorColor || !warningColor) return t;
    const esc = function (s) {
        return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    };
    const f = String(filterText || "");
    const matchStyle = (f !== "" && matchColor !== "")
        ? "background-color:" + colorToCss(matchColor)
          + (matchTextColor !== "" ? ";color:" + colorToCss(matchTextColor) : "")
        : "";
    const lines = t.split("\n");
    const out = [];
    for (let i = 0; i < lines.length; i++) {
        const l = lines[i];
        let html = esc(l);
        if (matchStyle !== "") {
            const ranges = matchRanges(l, f, !!useRegex);
            if (ranges.length > 0) {
                html = "";
                let pos = 0;
                for (let j = 0; j < ranges.length; j++) {
                    html += esc(l.slice(pos, ranges[j][0]));
                    html += '<span style="' + matchStyle + ';">'
                        + esc(l.slice(ranges[j][0], ranges[j][1])) + "</span>";
                    pos = ranges[j][1];
                }
                html += esc(l.slice(pos));
            }
        }
        let color = "";
        if (l !== "" && !EXCEPT_RE.test(l)) {
            if (OOM_RE.test(l) || ERROR_RE.test(l)) color = errorColor;
            else if (WARN_RE.test(l)) color = warningColor;
        }
        out.push(color === "" ? html
                               : '<span style="color:' + colorToCss(color) + ';">' + html + "</span>");
    }
    return out.join("<br>");
}

// ── Script output parsing ───────────────────────────────────────────────────
// `key=value` lines.
function parseKv(stdout) {
    const out = {};
    String(stdout || "").split("\n").forEach(function (line) {
        const i = line.indexOf("=");
        if (i > 0 && line.slice(0, i).indexOf(" ") === -1) out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
    });
    return out;
}

// statusall lines: "<id> alive=1 pid=N logfile=L" or "<id> alive=0".
function parseStatusall(stdout) {
    const m = {};
    String(stdout || "").split("\n").forEach(function (line) {
        const parts = line.trim().split(/\s+/).filter(function (p) { return p !== ""; });
        if (parts.length < 2) return;
        if (parts[1] !== "alive=1" && parts[1] !== "alive=0") return;
        const entry = { alive: parts[1] === "alive=1", pid: "", logfile: "" };
        for (let i = 2; i < parts.length; i++) {
            if (parts[i].indexOf("pid=") === 0) {
                entry.pid = parts[i].slice(4) || "0";
            } else if (parts[i].indexOf("logfile=") === 0) {
                entry.logfile = parts.slice(i).join(" ").slice("logfile=".length);
                break;
            }
        }
        m[parts[0]] = entry;
    });
    return m;
}

function withoutKey(obj, key) {
    const m = Object.assign({}, obj || {});
    delete m[key];
    return m;
}

// ── Stats monitor ─────────────────────────────────────────────────────────
// Number formatters shared by the Stats tab ("–" for unknown values).
function fmtMib(v) {
    if (typeof v !== "number" || !isFinite(v) || v < 0) return "–";
    return v >= 1024 ? (v / 1024).toFixed(1) + " GiB" : Math.round(v) + " MiB";
}
// "21.7 / 25.6 GiB": one unit instead of two, so gauge readouts never elide
function fmtMibPair(used, total) {
    if (typeof used !== "number" || !isFinite(used) || used < 0 ||
        typeof total !== "number" || !isFinite(total) || total < 0) return "–";
    if (total >= 1024 || used >= 1024)
        return (used / 1024).toFixed(1) + " / " + (total / 1024).toFixed(1) + " GiB";
    return Math.round(used) + " / " + Math.round(total) + " MiB";
}
function fmtTokens(v) {
    if (typeof v !== "number" || !isFinite(v) || v < 0) return "–";
    if (v >= 1e6) return (v / 1e6).toFixed(1) + "M";
    if (v >= 1e4) return Math.round(v / 1e3) + "k";
    return String(Math.round(v));
}
function fmtDur(s) {
    if (typeof s !== "number" || !isFinite(s) || s < 0) return "–";
    if (s >= 3600) return Math.floor(s / 3600) + " h " + Math.floor((s % 3600) / 60) + " m";
    if (s >= 60) return Math.floor(s / 60) + " m " + Math.round(s % 60) + " s";
    return s.toFixed(1) + " s";
}
function fmtAge(s) {
    if (typeof s !== "number" || !isFinite(s) || s < 0) return "–";
    if (s < 60) return Math.round(s) + " s";
    if (s < 3600) return Math.round(s / 60) + " min";
    return (s / 3600).toFixed(1) + " h";
}

// /health JSON -> "model (vX)" display string, "" when nothing useful.
// Covers strata (model, version) and llama-server (model, build_info).
function healthTally(body) {
    const d = safeJsonParse(body, null);
    if (!d || typeof d !== "object") return "";
    const m = String(d.model || "");
    let v = d.version ? String(d.version) : "";
    if (!v && d.build_info && d.build_info.build_commit) v = String(d.build_info.build_commit).slice(0, 8);
    if (m === "" && v === "") return "";
    return m + (v ? " (v" + v + ")" : "");
}

// Prometheus exposition text -> { name: [values] } (every sample of a metric
// name, labels dropped). Comments and unparsable lines are ignored.
function parsePrometheus(text) {
    const out = {};
    String(text || "").split("\n").forEach(function (line) {
        const l = line.trim();
        if (l === "" || l.charAt(0) === "#") return;
        const m = /^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{[^}]*\})?\s+(-?[0-9eE+.\-]+)(?:\s+\d+)?$/.exec(l);
        if (!m) return;
        const v = Number(m[2]);
        if (!isFinite(v)) return;
        (out[m[1]] = out[m[1]] || []).push(v);
    });
    return out;
}

// cppserverctl.sh `gpu` output -> machine counters + per-process VRAM.
// procs maps pid(string) -> MiB; missing numbers stay -1 so the UI hides
// that ring/tile.
function parseGpu(text) {
    const g = {
        procs: {},
        gpuUsedMib: -1, gpuTotalMib: -1, gpuUtil: -1, gpuTemp: -1, gpuPower: -1,
        gpuPowerLimit: -1,
        ramUsedMib: -1, ramTotalMib: -1, cpuPct: -1,
        cpuCores: -1, cpuThreads: -1,
        diskReadMBs: -1, diskWriteMBs: -1,
        gpuName: "", cpuName: ""
    };
    const keys = {
        gpuused: "gpuUsedMib", gputotal: "gpuTotalMib", gpuutil: "gpuUtil",
        gputemp: "gpuTemp", gpupow: "gpuPower", gpulimit: "gpuPowerLimit",
        ramused: "ramUsedMib", ramtotal: "ramTotalMib", cpu: "cpuPct",
        cores: "cpuCores", threads: "cpuThreads",
        diskread: "diskReadMBs", diskwrite: "diskWriteMBs"
    };
    const strs = { gpuname: "gpuName", cpuname: "cpuName" };
    String(text || "").split("\n").forEach(function (line) {
        const eq = line.indexOf("=");
        if (eq < 0) return;
        const k = line.slice(0, eq).trim();
        const v = line.slice(eq + 1).trim();
        if (k === "proc") {
            const c = v.split(":");
            const pid = c[0], mib = Number(c[1]);
            if (pid && isFinite(mib)) g.procs[pid] = mib;
        } else if (strs[k] !== undefined) {
            if (v) g[strs[k]] = v;
        } else if (keys[k] !== undefined) {
            const n = Number(v);
            if (isFinite(n)) g[keys[k]] = n;
        }
    });
    return g;
}

// Ring readout is narrow: drop the vendor prefix nvidia-smi puts on nearly
// every card — the tail ("RTX 3090", "RX 7900 XTX", "TITAN RTX") is what
// actually identifies it. Unknown vendors pass through untouched.
function gpuReadout(name) {
    const n = String(name || "").trim();
    const m = n.replace(/^(NVIDIA|AMD)\s+/i, "");
    return m.replace(/^Geforce\s+/i, "").replace(/^Radeon\s+(HD\s+)?/i, "") || n;
}

// Rolling machine history for the ring/tile sparklines: one sample per gpu
// poll (the plasmoid keeps its own ~1-minute window; no server is asked for
// history). Output keys match what the UI consumed before so they are
// swappable; series that a poll cannot supply keep their previous array.
function pushHist(prev, g, cap) {
    const map = { cpu: "cpuPct", gpu_util: "gpuUtil", gpu_temp: "gpuTemp",
                  gpu_power: "gpuPower", ram_used: "ramUsedMib",
                  gpu_mem_used: "gpuUsedMib", disk_read_mb: "diskReadMBs" };
    const out = {};
    Object.keys(map).forEach(function (k) {
        const old = (prev && Array.isArray(prev[k])) ? prev[k] : [];
        const v = g ? g[map[k]] : undefined;
        if (typeof v === "number" && v >= 0) {
            old.push(v);
            out[k] = old.length > cap ? old.slice(old.length - cap) : old;
        } else {
            out[k] = old;
        }
    });
    return out;
}

// Normalize one polled server into what the Stats tab renders. Unknown
// numbers are -1 so the UI can hide that chip/progress bar.
// entry: { kind: "strata"|"llama"|"json"|"none", health: <health body>,
//          body: <metrics body>, err: "" }
// strata /metrics:  engine{model,max_context}, live{state,phase,queued,
//                   prompt_total,generated,tok_s,tok_s_mean}, totals{requests,
//                   prompt_tokens,reused,output_tokens,since}, requests[],
//                   hardware{gpu_util,gpu_mem_used/total,gpu_temp,gpu_power,
//                   cpu,ram_used/total,tok_s_mean}.
// llama.cpp /metrics (needs --metrics): llm:prompt_tokens_total,
//   llm:generated_tokens_total, llm:decode_seconds_sum_total, llm:n_ctx,
//   llm:urange, llm:predictions_active (+ old llm:prom_total/gen_total names).
function parseStats(entry) {
    const e = entry || {};
    const s = {
        kind: e.kind || "none", err: e.err || "",
        model: "", state: "", active: false, queued: 0,
        tps: -1, meanTps: -1, ctxUsed: -1, ctxMax: 0,
        vramUsedMib: -1, vramTotalMib: -1,
        // this server's own VRAM footprint (source of the ring segment)
        ownVramMib: -1,
        // llama.cpp: device-wide usage from its startup log lines
        logVramUsedMib: -1, logVramSizeMib: -1,
        gpuUtil: -1, gpuTemp: -1, gpuPower: -1, cpuPct: -1,
        ramUsedMib: -1, ramTotalMib: -1,
        promptTok: -1, outTok: -1, reusedTok: -1, events: -1,
        reqs: [],
        // dashboard extras (strata): names, limits, sparkline series, live progress
        gpuName: "", cpuName: "", cores: 0, threads: 0,
        powerLimit: -1, pcie: "", diskRead: -1, prefillTps: -1,
        hist: {}, phase: "", genNow: -1, genMax: 0,
        promptRead: -1, promptTotal: 0
    };
    if (e.kind === "strata" && e.body) {
        const d = safeJsonParse(e.body, null);
        if (!d) { s.err = "bad_json"; return s; }
        const en = d.engine || {}, lv = d.live || {}, tt = d.totals || {}, hw = d.hardware || {};
        s.model = String(en.model || "");
        s.state = String(lv.state || "");
        s.queued = Number(lv.queued) || 0;
        s.active = s.state !== "" && s.state !== "idle";
        s.tps = (typeof lv.tok_s === "number" && lv.tok_s > 0) ? lv.tok_s : -1;
        s.meanTps = (typeof lv.tok_s_mean === "number" && lv.tok_s_mean > 0) ? lv.tok_s_mean
                  : (typeof hw.tok_s_mean === "number" ? hw.tok_s_mean : -1);
        s.ctxMax = Number(en.max_context) || 0;
        if (typeof lv.prompt_total === "number" && lv.prompt_total > 0) {
            s.ctxUsed = lv.prompt_total + (Number(lv.generated) || 0);
        } else {
            const rq = Array.isArray(d.requests) ? d.requests : [];
            let last = null;
            rq.forEach(function (r) { if (r && (!last || (Number(r.time) || 0) > (Number(last.time) || 0))) last = r; });
            if (last) s.ctxUsed = (Number(last.prompt_total) || 0) + (Number(last.output_tokens) || 0);
        }
        if (typeof hw.gpu_mem_total === "number") s.vramTotalMib = hw.gpu_mem_total / 1048576;
        if (typeof hw.gpu_mem_used === "number") s.vramUsedMib = hw.gpu_mem_used / 1048576;
        // strata's arena is its own VRAM allocation (weights + KV + buffers)
        if (typeof en.arena_mib === "number" && en.arena_mib > 0) s.ownVramMib = en.arena_mib;
        ["gpu_util", "gpu_temp", "gpu_power", "cpu"].forEach(function (k) {
            if (typeof hw[k] === "number") s[k === "gpu_util" ? "gpuUtil" : k === "gpu_temp" ? "gpuTemp" : k === "gpu_power" ? "gpuPower" : "cpuPct"] = hw[k];
        });
        if (typeof hw.ram_total === "number") s.ramTotalMib = hw.ram_total / 1048576;
        if (typeof hw.ram_used === "number") s.ramUsedMib = hw.ram_used / 1048576;
        if (typeof hw.gpu_power_limit === "number") s.powerLimit = hw.gpu_power_limit;
        if (typeof hw.disk_read_mb === "number") s.diskRead = hw.disk_read_mb;
        if (typeof hw.prefill_tok_s_mean === "number" && hw.prefill_tok_s_mean > 0) s.prefillTps = hw.prefill_tok_s_mean;
        if (typeof hw.gpu_pcie_gen === "number" && hw.gpu_pcie_gen > 0) {
            s.pcie = "Gen" + hw.gpu_pcie_gen + (hw.gpu_pcie_width ? " x" + hw.gpu_pcie_width : "");
        }
        const hs = d.hardware_static || {};
        if (hs.gpu_name) s.gpuName = String(hs.gpu_name);
        if (hs.cpu_name) s.cpuName = String(hs.cpu_name);
        if (typeof hs.cores === "number") s.cores = hs.cores;
        if (typeof hs.threads === "number") s.threads = hs.threads;
        // Sparkline series strata keeps server-side; the UI just draws them.
        const hi = d.history || {};
        ["gpu_util", "gpu_temp", "gpu_power", "cpu", "ram_used", "gpu_mem_used", "tok_s", "disk_read_mb"]
            .forEach(function (k) { if (Array.isArray(hi[k])) s.hist[k] = hi[k]; });
        s.phase = lv.phase ? String(lv.phase) : "";
        if (typeof lv.generated === "number" && lv.generated >= 0) s.genNow = lv.generated;
        if (typeof lv.max_tokens === "number") s.genMax = lv.max_tokens;
        if (typeof lv.prompt_read === "number" && lv.prompt_read >= 0) s.promptRead = lv.prompt_read;
        if (typeof lv.prompt_total === "number") s.promptTotal = lv.prompt_total;
        if (typeof tt.requests === "number") s.events = tt.requests;
        if (typeof tt.prompt_tokens === "number") s.promptTok = tt.prompt_tokens;
        if (typeof tt.output_tokens === "number") s.outTok = tt.output_tokens;
        if (typeof tt.reused === "number") s.reusedTok = tt.reused;
        (Array.isArray(d.requests) ? d.requests : []).forEach(function (r) {
            if (!r) return;
            const pTok = Number(r.prompt_tokens) || 0;
            const pMs = Number(r.prompt_ms) || 0;
            s.reqs.push({
                at: Number(r.time) || 0, durS: Number(r.duration_s) || 0,
                tps: Number(r.decode_tok_s) || 0, inTok: pTok,
                outTok: Number(r.output_tokens) || 0, finish: String(r.finish || ""),
                reused: Number(r.reused) || 0,
                hitRate: (typeof r.hit_rate === "number") ? r.hit_rate : -1,
                prefillTps: (pMs > 0 && pTok > 0) ? pTok / (pMs / 1000) : -1
            });
        });
        s.reqs.sort(function (a, b) { return b.at - a.at; });
        s.reqs = s.reqs.slice(0, 10);
    } else if (e.kind === "llama") {
        const prom = parsePrometheus(e.body);
        // Upstream llama-server registers the llamacpp: prefix; older forks used
        // llm:. Both are accepted.
        const first = function (names) {
            for (let i = 0; i < names.length; i++)
                if (prom[names[i]] && prom[names[i]].length)
                    return prom[names[i]][0];
            return -1;
        };
        const mm = /(?:llamacpp|llm):model_info\{[^}]*model="([^"]*)"/.exec(String(e.body || ""));
        if (mm) s.model = mm[1];
        s.promptTok = first(["llamacpp:prompt_tokens_total", "llm:prompt_tokens_total"]);
        s.outTok = first(["llamacpp:tokens_predicted_total", "llm:predicted_tokens_total"]);
        const dec = first(["llamacpp:tokens_predicted_seconds_total", "llm:predicted_tokens_seconds_total"]);
        if (s.outTok > 0 && dec > 0) s.meanTps = s.outTok / dec;
        s.ctxMax = first(["llamacpp:n_ctx", "llm:n_ctx"]);
        const range = prom["llm:urange"] || prom["llamacpp:urange"] || [];
        if (range.length) s.ctxUsed = range.reduce(function (a, b) { return Math.max(a, b); }, 0);
        s.active = first(["llamacpp:requests_processing", "llm:requests_processing"]) > 0;
        s.state = s.active ? "generating" : "idle";
        // The counters say nothing about n_ctx/urange or per-request detail, and
        // without --metrics there are no counters at all: fill every still-empty
        // field from the log tail (print_timing lines).
        if (e.log) {
            const ls = { reqs: [], meanTps: -1 };
            llamaLogStats(e.log, ls);
            if (!s.model && ls.model) s.model = ls.model;
            if (s.ctxMax < 0 && ls.ctxMax > 0) s.ctxMax = ls.ctxMax;
            if (s.ctxUsed < 0 && ls.ctxUsed >= 0) s.ctxUsed = ls.ctxUsed;
            if (s.events < 0 && ls.events >= 0) s.events = ls.events;
            if (s.promptTok < 0 && ls.promptTok >= 0) s.promptTok = ls.promptTok;
            if (s.outTok < 0 && ls.outTok >= 0) s.outTok = ls.outTok;
            if (s.tps < 0 && ls.tps >= 0) s.tps = ls.tps;
            if (s.meanTps < 0 && ls.meanTps >= 0) s.meanTps = ls.meanTps;
            if (s.reqs.length === 0 && ls.reqs.length) s.reqs = ls.reqs;
            if (s.state === "idle" && ls.active) s.state = "generating";
            s.active = s.active || ls.active;
            if (ls.logVramUsedMib >= 0) s.logVramUsedMib = ls.logVramUsedMib;
            if (ls.logVramSizeMib >= 0) s.logVramSizeMib = ls.logVramSizeMib;
        }
    } else if (e.kind === "json") {
        s.state = "idle";
    }
    return s;
}

// Recent requests across all servers, newest first (rows without a real
// timestamp sink to the bottom). entries: [{ name, reqs }].
function mergeReqs(entries, max) {
    const all = [];
    (entries || []).forEach(function (e) {
        if (!e || !Array.isArray(e.reqs)) return;
        e.reqs.forEach(function (r) {
            if (r) all.push(Object.assign({ name: e.name }, r));
        });
    });
    all.sort(function (a, b) { return (b.at || 0) - (a.at || 0); });
    return all.slice(0, max > 0 ? max : 8);
}

// llama.cpp without --metrics: derive the same fields from its log tail.
// Recognized lines (several llama.cpp generations):
//   llama_context: n_ctx  =  8192                       -> ctxMax
//   loading model from '/x/y.gguf'                      -> model
//   slot print_timing: ... cur_n = 14681                -> live ctxUsed
//   slot print_timing: ... | total time = N ms / M tokens (per task id)
//                                                        -> finished requests
//   slot print_timing: ... prompt eval time = T ms / P tokens
//   slot print_timing: ...        eval time = T ms / O tokens
//   ... cur speed = 45.2 | avg speed = 43.2 (newer builds)
//   ... avg speed = 43.2 t/s
function llamaLogStats(text, s) {
    const t = String(text || "");
    let m;
    m = /n_ctx\s*=\s*(\d+)/.exec(t);
    if (m) s.ctxMax = Number(m[1]);
    m = /loading model from '([^']*)'/.exec(t);
    if (m) s.model = String(m[1]).split("/").pop();

    const reCur = /cur_n\s*=\s*(\d+)/g;
    let used = -1;
    while ((m = reCur.exec(t)) !== null) used = Math.max(used, Number(m[1]));
    const reTot = /\|\s*total time =\s+([0-9.]+) ms \/ \s*(\d+) tokens/g;
    const perTask = {};
    const order = [];
    let lastTot = null;
    while ((m = reTot.exec(t)) !== null) {
        lastTot = { ms: Number(m[1]), tok: Number(m[2]) };
    }
    if (used < 0 && lastTot) used = lastTot.tok;
    s.ctxUsed = used;

    const rePrompt = /task (\d+) \|\s*prompt eval time =\s+([0-9.]+) ms \/ \s*(\d+) tokens/g;
    while ((m = rePrompt.exec(t)) !== null) {
        const id = m[1];
        if (!perTask[id]) { perTask[id] = {}; order.push(id); }
        perTask[id].inTok = Number(m[3]);
        perTask[id].promptMs = Number(m[2]);
    }
    const reEval = /task (\d+) \|\s+eval time =\s+([0-9.]+) ms \/ \s*(\d+) tokens/g;
    while ((m = reEval.exec(t)) !== null) {
        const id = m[1];
        if (!perTask[id]) { perTask[id] = {}; order.push(id); }
        perTask[id].outTok = Number(m[3]);
        perTask[id].evalMs = Number(m[2]);
    }
    // total time lines carry the task id only in some builds ("task N | total").
    const reTotTask = /task (\d+) \|\s*total time =\s+([0-9.]+) ms/g;
    while ((m = reTotTask.exec(t)) !== null) {
        const id = m[1];
        if (!perTask[id]) { perTask[id] = {}; order.push(id); }
        perTask[id].totalMs = Number(m[2]);
    }
    let sumPrompt = 0, sumOut = 0, count = 0;
    order.forEach(function (id) {
        const r = perTask[id];
        if (r.inTok === undefined && r.outTok === undefined) return;
        count++;
        sumPrompt += r.inTok || 0;
        sumOut += r.outTok || 0;
        const dur = (r.totalMs || ((r.promptMs || 0) + (r.evalMs || 0))) / 1000;
        const outT = r.outTok || 0;
        s.reqs.push({
            at: 0, durS: dur, tps: dur > 0 ? outT / dur : 0,
            inTok: r.inTok || 0, outTok: outT, finish: "stop"
        });
    });
    if (count > 0) {
        s.events = count;
        s.promptTok = sumPrompt;
        s.outTok = sumOut;
        s.reqs = s.reqs.slice(-6).reverse();
    }

    const reAvg = /avg speed =\s*([0-9.]+)/g;
    while ((m = reAvg.exec(t)) !== null) s.meanTps = Number(m[1]);
    const reCur2 = /cur speed =\s*([0-9.]+)/g;
    while ((m = reCur2.exec(t)) !== null) s.tps = Number(m[1]);
    if (s.meanTps < 0 && s.outTok > 0) {
        let decMs = 0;
        order.forEach(function (id) { decMs += perTask[id].evalMs || 0; });
        if (decMs > 0) s.meanTps = s.outTok / (decMs / 1000);
    }
    // CUDA/Metal backends print device memory at load ("used = X, free = Y,
    // size = S MiB"): the last reading labels the llama ring segment.
    const reVram = /used\s*=\s*([\d,]+),\s*free\s*=\s*[\d,]+,\s*size\s*=\s*([\d,]+)/g;
    while ((m = reVram.exec(t)) !== null) {
        s.logVramUsedMib = Number(m[1].replace(/,/g, ""));
        s.logVramSizeMib = Number(m[2].replace(/,/g, ""));
    }
}
