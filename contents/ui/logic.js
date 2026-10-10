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
    cmd = subToken(cmd, "CONFIG_FILE", cfg);
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
// (benign messages with error-like words) are skipped entirely. maxTps is the highest
// "N t/s" value seen (llama.cpp generation rate); 0 when none.
// Benign lines that contain error-like words but are not real errors
// (e.g. llama.cpp "failed to read tensor info", "tensor name 4 is too long").
const EXCEPT_RE = /failed to read tensor info|tensor name \d+ is too long/i;
const OOM_RE   = /out of (video |host )?memory|cannot allocate|memory allocation (failed|error)|no space left on device|not enough (video |host )?memory|cudaerrormemoryallocation/i;
const ERROR_RE = /\b(errors?|failed?|failure|fatal|aborted?|panic|exception|segfault|segmentation fault|core dumped|critical|backtrace)\b|^\s*(?:\[\d+\] )?\d+\.\d+\.\d+\.\d+ E /i;
const WARN_RE  = /warn(ing|s|ed)?\b|deprecat|^\s*(?:\[\d+\] )?\d+\.\d+\.\d+\.\d+ W /i;
const TPS_RE   = /([0-9]+(?:\.[0-9]+)?)\s*t\/s\b/g;

function logStats(text) {
    const lines = String(text || "").split("\n");
    let oom = 0, errors = 0, warnings = 0, maxTps = 0;
    for (let i = 0; i < lines.length; i++) {
        const l = lines[i];
        if (l === "") continue;
        if (EXCEPT_RE.test(l)) continue;
        if (OOM_RE.test(l)) oom++;
        else if (ERROR_RE.test(l)) errors++;
        else if (WARN_RE.test(l)) warnings++;
        TPS_RE.lastIndex = 0;
        let m;
        while ((m = TPS_RE.exec(l)) !== null) {
            const v = Number(m[1]);
            if (v > maxTps) maxTps = v;
        }
    }
    return { oom: oom, errors: errors, warnings: warnings, maxTps: maxTps };
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
