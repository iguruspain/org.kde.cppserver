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
// Any line bearing a speed measurement (llama prints tg/tg_3s/at as "N t/s";
// the eval/total block spells it out as "tokens per second" and is excluded).
// Non-global: for .test().
const TPS_LINE_RE = /[0-9]+(?:\.[0-9]+)?\s*t\/s/;
// Ends a generation burst: after it any t/s in the tail is history.
const STOP_PROC_RE = /\bstop processing\b/;
// Lines that mark a (re)load of the model in llama.cpp logs (router/preset
// swaps and classic single-model loads). Cumulative t/s min/max restart after
// the last occurrence in the visible tail.
const MODEL_CHANGE_RE = /llama_server:\s*model loaded|load_model:\s*loading model |spawning server instance with name=|ensure_model:\s*slot available|loaded \d+ model files/i;

function logStats(text) {
    const lines = String(text || "").split("\n");
    let oom = 0, errors = 0, warnings = 0;
    let curTps = 0, minTps = 0, maxTps = 0, lastTpsIdx = -1;
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
            lastTpsIdx = i;
            if (minTps === 0 || value < minTps) minTps = value;
            if (value > maxTps) maxTps = value;
        }
    }
    // Is curTps STILL the live figure? llama emits a t/s line every ~3 s
    // while generating and then falls silent, so position in the tail says
    // nothing — the generation burst is over as soon as "stop processing"
    // lands after the last speed line (a killed server has no stop line,
    // but its caller already gates on the pid being alive).
    let tpsFresh = lastTpsIdx >= 0;
    if (tpsFresh) {
        for (let j = lastTpsIdx + 1; j < lines.length; j++) {
            if (STOP_PROC_RE.test(lines[j])) { tpsFresh = false; break; }
        }
    }
    return { oom: oom, errors: errors, warnings: warnings, curTps: curTps,
             minTps: minTps, maxTps: maxTps, tpsFresh: tpsFresh };
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
// errorColor, warnings in warningColor, speed lines in the optional
// tpsColor) get a colored <span>; when a filter is active (non-empty
// filterText) the matching substrings additionally get
// a matchColor background and matchTextColor text, like the native text
// selection. Escapes & < > and joins lines with <br>, because a bare newline
// is collapsed by the rich-text parser. Empty color args return the text
// unchanged so callers can keep a PlainText fallback.
function highlightLog(text, errorColor, warningColor, filterText, useRegex,
                       matchColor, matchTextColor, tpsColor) {
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
            else if (tpsColor && TPS_LINE_RE.test(l)) color = tpsColor;
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
// exact grouped figure ("95,000", not "95k"): the request table stretches
// its token columns with the popup, so it shows the real count
function fmtTokensFull(v) {
    if (typeof v !== "number" || !isFinite(v) || v < 0) return "–";
    // grouping by hand: Qt.* globals are not available inside .pragma library
    return String(Math.round(v)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
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

// ── audio.cpp ([TIMING ts=…] blocks + request lines, --log) ─────────
// "null" is a real value in this log: transcription with no chunking
// never emits a first-audio marker, and the feed prints it as such.
function fmtFeedMs(ms) {
    if (!(ms >= 0)) return "–";
    return ms >= 10000 ? (ms / 1000).toFixed(1) + "s" : (ms / 1000).toFixed(2) + "s";
}
function fmtFeedTtfb(v) {
    return v === null ? "null" : fmtFeedMs(v);
}
// cap for audioReqs (all families together); mirrors REQ_FEED_MAX
const AUDIO_FEED_MAX = 8;
// cap for one server card's request table
const REQ_FEED_MAX = 8;
// audio.cpp log tail -> the audio fields of a parseStats shape.
// Recognized lines (families change every audio.cpp release, so keys are
// matched structurally, never by family name):
//   [TRACE ts=…] server.model.id/path/family/task/mode/backend/device
//        -> the model the CURRENT request uses (lazy_load loads models
//        on demand); also binds the request to a family namespace, since
//        every <family>.session.* timing key carries it
//   [SERVER_HTTP_DEBUG] http.headers method=POST/PUT path=/v1/audio/…
//        -> request opened (audio.cpp serves one request at a time)
//   [SERVER_HTTP_DEBUG] http.headers method=… path=<other>
//        -> non-audio request (health, ui): marks the active family
//   [TIMING ts=…] session.wall_ms <ms>           -> request closed
//   [TIMING ts=…] <family>.session.generate_ms   -> one generated chunk
//   [TIMING ts=…] <family>.session.first_audio_ms -> time to first audio
//   [SERVER_ERROR] / engine error / exception    -> flags the request
// Feed: one row per request per family (newest first, the open request
// included live), collected in s.audioReqs; the card's own request table
// draws them as rows, family in its own column. No token/context data
// exists for audio (TTS/ASR have neither). Speed is deliberately NOT
// derivable: the server computes the audio duration (minitts::server::audio_duration_ms)
// but only puts it in API responses, never in stdout — any "x real-time"
// figure would be a guess. Old-format logs (no ts= markers) parse to an
// idle card: without stamps there is nothing to measure or attribute.
function audioLogStats(log, s, nowSec) {
    const text = String(log || "");
    const fams = new Map();
    const order = [];
    const famOf = function (name) {
        let f = fams.get(name);
        if (!f) {
            f = { name, model: "", task: "", backend: "", reqs: 0, feed: [] };
            fams.set(name, f);
            order.push(name);
        }
        return f;
    };
    let cur = null;      // the open http request (audio.cpp: one at a time)
    let fam = null;      // family bound to cur
    let fallback = null; // family of the most recent request/chunk block
    // model/task/backend of the CURRENT request, buffered until the
    // family is known: the TRACE block prints before the first timing
    // key reveals the family prefix, and startup prints before any
    // request exists at all
    let pend = { model: "", task: "", backend: "" };
    const applyMeta = function (g) {
        if (!g) return;
        const src = (cur && (cur.meta.model !== "" || cur.meta.task !== "" || cur.meta.backend !== "")) ? cur.meta : pend;
        if (g.model === "" && src.model !== "") g.model = src.model;
        if (g.task === "" && src.task !== "") g.task = src.task;
        if (g.backend === "" && src.backend !== "") g.backend = src.backend;
    };
    const tsRe = /(?:TRACE|TIMING) ts=(\d{8}-\d{6})/;
    const tsOf = function (m) {
        if (!m) return -1;
        const t = m[1]; // "YYYYMMDD-HHMMSS" (one dash, after the date)
        if (t.length !== 15) return -1;
        const d = new Date(Number(t.slice(0, 4)), Number(t.slice(4, 6)) - 1, Number(t.slice(6, 8)),
                           Number(t.slice(9, 11)), Number(t.slice(11, 13)), Number(t.slice(13, 15)));
        const ms = d.getTime();
        return ms > 0 ? Math.floor(ms / 1000) : -1;
    };
    // family a timing key belongs to: the open request's binding for
    // session-level keys (wall_ms prints un-namespaced), else the key prefix
    const famOfKey = function (key) {
        if (key.indexOf("session.") === 0) return fam || fallback;
        const dot = key.indexOf(".");
        return dot > 0 ? famOf(key.slice(0, dot)) : null;
    };
    // a row always gets an `at`: its own stamp, else the nearest stamped
    // line, else an hour ago: unstampable rows sink below the real ones
    // and a 1970 clock would read as garbage in the time column
    const stamp = function (t, fb) {
        if (t > 0) return t;
        if (fb > 0) return fb;
        return (nowSec > 0 ? nowSec : 0) - 3600;
    };
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i].trim();
        if (!line) continue;
        let m = /^\[TRACE ts=(\d{8}-\d{6})\] server\.model\.(\w+) (\S.*)$/.exec(line);
        if (m) {
            const v = m[2];
            if (v === "family") {
                // the one structural gift: the family line names the exact
                // namespace the request's timing keys will use
                const f0 = famOf(m[3].trim());
                if (cur) fam = f0;
                fallback = f0;
                continue;
            }
            const src = (cur && cur.meta) ? cur.meta : pend;
            if (v === "id") src.model = m[3];
            else if (v === "task") src.task = m[3];
            else if (v === "backend") src.backend = m[3];
            const g = fam || fallback;
            if (g) applyMeta(g);
            if (cur && cur.at < 0) cur.at = tsOf(m);
            continue;
        }
        m = /^\[TIMING ts=(\d{8}-\d{6})\] (\S+) (\S+)$/.exec(line);
        if (m) {
            const ts = tsOf(m);
            const key = m[2];
            const val = parseFloat(m[3]);
            if (key === "session.wall_ms") {
                if (cur) {
                    const g = fam || fallback || famOf("audio");
                    if (g) {
                        applyMeta(g);
                        g.reqs++;
                        g.feed.push({
                            at: stamp(cur.at, ts), chunks: cur.chunks,
                            durMs: Number.isFinite(val) ? val : -1,
                            ttfbMs: cur.ttfbMs, err: cur.err
                        });
                    }
                    cur = null;
                    fam = null;
                }
            } else if (cur && key.indexOf(".session.generate_ms") !== -1) {
                cur.chunks++;
                if (cur.at < 0) cur.at = ts;
            } else if (cur && key.indexOf(".session.first_audio_ms") !== -1
                       && Number.isFinite(val)) {
                cur.ttfbMs = val;
            } else if (key.indexOf(".session.") !== -1
                       || key.indexOf(".generator.") !== -1
                       || key.indexOf(".weights.") !== -1) {
                if (cur && cur.at < 0) cur.at = ts;
            }
            if (cur && ts > 0) cur.lastTs = ts;
            if (ts > 0) {
                fallback = famOfKey(key) || fallback;
                if (cur) applyMeta(fam || fallback || famOf("audio"));
            }
            continue;
        }
        m = /^\[SERVER_HTTP_DEBUG\] http\.headers method=(\w+) path=(\S+)/.exec(line);
        if (m) {
            if (cur) continue;      // body_ready pairs the headers line
            if ((m[1] === "POST" || m[1] === "PUT")
                && m[2].indexOf("/v1/audio/") === 0) {
                // inherit the last known model: not every request
                // re-announces its TRACE block (model already loaded)
                cur = { at: -1, lastTs: -1, chunks: 0, ttfbMs: null, err: false,
                        meta: { model: pend.model, task: pend.task, backend: pend.backend } };
                fam = null;
            } else if (fallback) {
                fam = fallback;     // health mid-request keeps the binding
            }
            continue;
        }
        if (line.indexOf("[SERVER_ERROR]") !== -1 || line.indexOf("engine error") !== -1
            || line.indexOf("exception") !== -1) {
            if (cur) cur.err = true;
        }
    }
    // the still-open request is live: its wall grows, its chunks already
    // stream — but only while its own stamps say so. An unstamped (old
    // format) or long-dead POST (log replayed after a restart) must not
    // fake "generating" on an idle server.
    if (cur) {
        const freshTs = cur.lastTs > 0 ? cur.lastTs : cur.at;
        if (freshTs > 0 && nowSec > 0 && nowSec - freshTs <= 3600) {
            const g = fam || fallback || famOf("audio");
            applyMeta(g);
            const at = stamp(cur.at, -1);
            g.feed.push({
                at, chunks: cur.chunks,
                durMs: (at >= 0 && nowSec > 0) ? (nowSec - at) * 1000 : -1,
                ttfbMs: cur.ttfbMs, err: cur.err, running: true
            });
            s.state = "generating";
        }
    }
    // requests happened but none is live: the server is idle, not unknown
    if (s.state === "" && order.length > 0) s.state = "idle";
    // the card's model: the active family first, else the last one that
    // finished a request, else any family that announced a model
    let best = null;
    if (cur && fam) best = fam;
    else order.forEach(function (n) {
        const f = fams.get(n);
        if (f.model && (f.reqs > 0 || !best)) best = f;
    });
    if (best) {
        s.model = best.model;
        s.audioTask = best.task;
        s.audioBackend = best.backend;
    }
    let total = 0;
    order.forEach(function (n) { total += fams.get(n).reqs; });
    if (total > 0) s.events = total;
    // newest first across families, each row tagged with its family (the
    // card's table shows it as the Model column)
    const all = [];
    order.forEach(function (n) { fams.get(n).feed.forEach(function (r) { all.push(Object.assign({ fam: n }, r)); }); });
    all.sort(function (a, b) { return b.at - a.at; });
    s.audioReqs = all.slice(0, AUDIO_FEED_MAX);
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
        procs: {}, vramBy: {},
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
        } else if (k === "vramowner") {
            // "<server id>=<MiB>", already resolved by the script: every
            // VRAM-holding pid traced up to the session that started it
            const c = v.split("=");
            const mib = Number(c[1]);
            if (c[0] && isFinite(mib)) g.vramBy[c[0]] = (g.vramBy[c[0]] || 0) + mib;
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
                  gpu_mem_used: "gpuUsedMib", disk_read_mb: "diskReadMBs",
                  // machine token-speed sample main.qml injects into the gpu
                  // result (max last-known t/s across running servers): the
                  // Speed tile sparkline without any server-side history
                  tok_s: "tokSample" };
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

// llama.cpp has no per-tick report between requests: the tail window keeps
// changing, so scalars would flash to 0/– between polls. For the llama kind
// parseStats keeps a caller-owned per-server cache (extra.stick) and reuses
// the last real value of every field a poll does not report.
const STICKY_FIELDS = ["tps", "meanTps", "ctxUsed", "ctxMax", "promptTok",
                       "outTok", "reusedTok", "events", "ownVramMib",
                       "logVramUsedMib", "logVramSizeMib"];
function stickify(s, stick) {
    STICKY_FIELDS.forEach(function (k) {
        if (typeof s[k] === "number" && s[k] >= 0) stick[k] = s[k];
        else if (typeof stick[k] === "number" && stick[k] >= 0) s[k] = stick[k];
    });
}

// Normalize one polled server into what the Stats tab renders. Unknown
// numbers are -1 so the UI can hide that chip/progress bar.
// entry: { kind: "strata"|"llama"|"json"|"audio"|"none", health: <health body>,
//          body: <metrics body>, log: <llama log tail>, err: "" }
// extra: { stick: per-server last-good cache (see stickify),
//          model: model name recovered from log markers elsewhere }
// strata /metrics:  engine{model,max_context}, live{state,phase,queued,
//                   prompt_total,generated,tok_s,tok_s_mean}, totals{requests,
//                   prompt_tokens,reused,output_tokens,since}, requests[],
//                   hardware{gpu_util,gpu_mem_used/total,gpu_temp,gpu_power,
//                   cpu,ram_used/total,tok_s_mean}.
// llama.cpp /metrics (needs --metrics): llm:prompt_tokens_total,
//   llm:generated_tokens_total, llm:decode_seconds_sum_total, llm:n_ctx,
//   llm:urange, llm:predictions_active (+ old llm:prom_total/gen_total names).
function parseStats(entry, seen, extra) {
    const e = entry || {};
    const x = extra || {};
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
        // audio.cpp owns its OWN request feed (audioReqs) drawn by the
        // card: audio has no tokens/context, so it never joins the shared
        // table. One entry per recent request, newest first, family name
        // on each so the card can group by model. audio task/backend
        // label the model line.
        audioReqs: [], audioTask: "", audioBackend: "",
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
            const ls = { reqs: [], meanTps: -1, tps: -1, reusedTok: -1,
                         genNow: -1, promptRead: -1, promptTotal: 0,
                         prefillTps: -1 };
            llamaLogStats(e.log, ls, seen, Math.floor(Date.now() / 1000));
            if (!s.model && ls.model) s.model = ls.model;
            // the load marker usually sits far above any tail window; the
            // caller scans the whole log once and passes it here
            if (!s.model && x.model) s.model = String(x.model);
            if (s.ctxMax < 0 && ls.ctxMax > 0) s.ctxMax = ls.ctxMax;
            if (s.ctxUsed < 0 && ls.ctxUsed >= 0) s.ctxUsed = ls.ctxUsed;
            if (s.events < 0 && ls.events >= 0) s.events = ls.events;
            if (s.promptTok < 0 && ls.promptTok >= 0) s.promptTok = ls.promptTok;
            if (s.outTok < 0 && ls.outTok >= 0) s.outTok = ls.outTok;
            if (s.tps < 0 && ls.tps >= 0) s.tps = ls.tps;
            if (s.meanTps < 0 && ls.meanTps >= 0) s.meanTps = ls.meanTps;
            if (s.reusedTok < 0 && ls.reusedTok >= 0) s.reusedTok = ls.reusedTok;
            if (s.reqs.length === 0 && ls.reqs.length) s.reqs = ls.reqs;
            // live request state from the print_timing stream: generation
            // count, prefill progress (the "prompt processing, progress =
            // 0.10" lines) and prefill speed fill the same card slots a
            // strata server fills from its /metrics live section
            if (s.genNow < 0 && ls.genNow >= 0) s.genNow = ls.genNow;
            if (s.promptTotal <= 0 && ls.promptTotal > 0) {
                s.promptTotal = ls.promptTotal;
                if (s.promptRead < 0 && ls.promptRead >= 0) s.promptRead = ls.promptRead;
            }
            if (s.prefillTps < 0 && ls.prefillTps > 0) s.prefillTps = ls.prefillTps;
            if (s.state === "idle" && ls.active) s.state = "generating";
            s.active = s.active || ls.active;
            if (ls.logVramUsedMib >= 0) s.logVramUsedMib = ls.logVramUsedMib;
            if (ls.logVramSizeMib >= 0) s.logVramSizeMib = ls.logVramSizeMib;
        }
        // idle llama windows report nothing: hold the last real values so
        // the card and the speed tile never flicker 0/– between ticks
        if (x.stick) stickify(s, x.stick);
    } else if (e.kind === "audio") {
        // audio.cpp (audiocpp_server, with --log): the /health probe only
        // tells us it answers — the real state lives in the log tail
        // (request lines + [TIMING] blocks; see audioLogStats). No tokens,
        // no context: the card gets state + model, its OWN info grid, and
        // its OWN per-request table (audioReqs); it never contributes to
        // the Speed tile.
        if (e.log) {
            const nowSec = (typeof x.now === "number" && x.now > 0)
                ? x.now : Math.floor(Date.now() / 1000);
            audioLogStats(e.log, s, nowSec);
        }
        if (!s.model && x.model) s.model = String(x.model);
        s.active = s.state !== "" && s.state !== "idle";
        if (x.stick) stickify(s, x.stick);
    } else if (e.kind === "json") {
        s.state = "idle";
    }
    return s;
}

// One row of a card's request table: a parsed request -> the final display
// string per column key (numbers included). The server column is gone — the
// row lives inside its own server's card. i18n headers are added by the UI;
// the values here need no localization. tokens === false blanks the token
// columns (the Stats "show tokens" toggle).
function fmtReqRow(r, tokens) {
    const show = tokens !== false;
    return {
        time: r.at > 0 ? fmtClock(r.at) : "–",
        status: r.finish || "",
        inTok: r.inTok > 0 ? fmtTokensFull(r.inTok) : "–",
        reused: show && r.reused > 0 ? fmtTokensFull(r.reused) : "–",
        outTok: show && r.outTok > 0 ? fmtTokensFull(r.outTok) : "–",
        // exact measurement, no rounding tricks in the table
        tps: r.tps > 0 ? r.tps.toFixed(2) : "-",
        dur: r.durS > 0 ? r.durS.toFixed(1) + "s" : "–"
    };
}
// local HH:mm:ss without Qt.* (not reliably available in .pragma library)
function fmtClock(epochS) {
    const d = new Date(epochS * 1000);
    const p = function (n) { return (n < 10 ? "0" : "") + n; };
    return p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());
}

// One card's request table: that server's parsed requests, newest first
// (rows without a real timestamp sink to the bottom), capped, already
// formatted per column. audio never comes through here: its card builds
// its own rows from st.audioReqs (the state labels are i18n, main.qml).
function serverReqFeed(reqs, tokens) {
    const all = [];
    (Array.isArray(reqs) ? reqs : []).forEach(function (r) {
        if (r) all.push(r);
    });
    all.sort(function (a, b) { return (b.at || 0) - (a.at || 0); });
    return all.slice(0, REQ_FEED_MAX > 0 ? REQ_FEED_MAX : 8)
        .map(function (r) { return fmtReqRow(r, tokens); });
}

// llama.cpp without --metrics: derive the same fields from its log tail.
// One ordered pass merged per task id: requests are BORN at launch and
// updated live, not only when they finish (what the old scanner saw).
// Recognized lines (several llama.cpp generations):
//   llama_context: n_ctx  =  8192                       -> ctxMax
//   loading model ['/from'] '/x/y.gguf'                 -> model (marker may
//                                                        sit above the tail:
//                                                        see logread markers)
//   slot ... task N | processing task                   -> request opened
//   slot ... task N | new prompt, ... task.n_tokens = P -> prompt tokens
//   slot ... task N | prompt processing, n_tokens = R, progress = F,
//                  t = ... s / X tokens per second      -> live prefill
//                                                        progress + rate
//   slot ... task N | n_gen = G, tg = A t/s, tg_3s = B t/s
//                                                        -> live decode: G
//                                                        accepted tokens,
//                                                        avg A, last-3s B
//                                                        (what the webui
//                                                        charts)
//   slot ... task N | n_decoded = G , at = A t/s        -> same, older builds
//   slot ... task N | prompt eval time = T ms / K tokens (... , X t/s)
//                                                        -> K processed: the
//                                                        P-K rest came from
//                                                        the prompt cache
//   slot ... task N |        eval time = T ms / K tokens (... , X t/s)
//   slot ... task N |       total time = T ms           -> finished
//   slot ... task N | stop processing: n_tokens = C, truncated = X
//                                                        -> slot released
//   ... cur speed = 45.2 | avg speed = 43.2             -> legacy rates
//   slot print_timing: ... cur_n = 14681                -> legacy live ctx
// With speculative decoding the "... tokens per second" the eval line
// prints counts DRAFT tokens too (it says 53 t/s for ~44 real): the
// n_gen/tg series counts accepted tokens only — those win when present.
function llamaLogStats(text, s, seen, now) {
    const t = String(text || "");
    let m;
    m = /n_ctx\s*=\s*(\d+)/.exec(t);
    if (m) s.ctxMax = Number(m[1]);
    // "load_model: loading model '/x.gguf'" (current builds) and the older
    // "loading model from '/x.gguf'"
    m = /loading model(?: from)? '([^']*)'/.exec(t);
    if (m) s.model = String(m[1]).split("/").pop();

    // per-task records in first-seen order — tail order is the only
    // ordering llama.cpp gives (its timestamps are boot-relative)
    const tasks = {};
    const order = [];
    function rec(id) {
        let r = tasks[id];
        if (!r) {
            r = tasks[id] = {
                open: false, done: false, inTok: -1, procTok: -1, gen: -1,
                tg: -1, tg3: -1, pRead: -1, pTot: 0, pRate: -1, promptMs: -1,
                evalMs: -1, evalTok: -1, evalRate: -1, totalMs: -1,
                relTok: -1, trunc: -1
            };
            order.push(id);
        }
        return r;
    }

    const lines = t.split("\n");
    for (let i = 0; i < lines.length; i++) {
        const tm = /\btask (\d+)\b/.exec(lines[i]);
        if (!tm) continue;                  // "task -1" chatter carries no data
        const l = lines[i];
        const r = rec(tm[1]);
        let g;
        if ((g = /\bnew prompt,.*\btask\.n_tokens =\s*(\d+)/.exec(l))) {
            r.inTok = Number(g[1]);
        } else if ((g = /\binit sampler\b.*\btotal =\s*(\d+)/.exec(l))) {
            if (r.inTok < 0) r.inTok = Number(g[1]);
        } else if ((g = /\bprocessing task\b/.exec(l))) {
            r.open = true;
        } else if ((g = /\bprompt processing, n_tokens =\s*(\d+),\s*progress =\s*([0-9.]+)/.exec(l))) {
            r.pRead = Number(g[1]);
            const fr = Number(g[2]);
            if (fr > 0) r.pTot = Math.round(r.pRead / fr);
            const rate = /([0-9.]+) tokens per second/.exec(l.slice(g.index + g[0].length));
            if (rate) r.pRate = Number(rate[1]);
        } else if ((g = /\bn_gen =\s*(\d+)(?:\s*,\s*tg =\s*([0-9.]+)\s*(?:t\/s)?)?(?:\s*,\s*tg_3s =\s*([0-9.]+))?/.exec(l))) {
            r.gen = Number(g[1]);
            if (g[2] !== undefined) r.tg = Number(g[2]);
            if (g[3] !== undefined) r.tg3 = Number(g[3]);
        } else if ((g = /\bn_decoded =\s*(\d+)\s*,\s*at =\s*([0-9.]+)/.exec(l))) {
            r.gen = Number(g[1]);
            r.tg = Number(g[2]);
        } else if ((g = /\bprompt eval time =\s*([0-9.]+) ms \/ \s*(\d+) tokens(?:[^\n]*?,\s*([0-9.]+) tokens per second)?/.exec(l))) {
            r.promptMs = Number(g[1]);
            r.procTok = Number(g[2]);
            if (g[3] !== undefined) r.pRate = Number(g[3]);
        } else if ((g = /\beval time =\s*([0-9.]+) ms \/ \s*(\d+) tokens(?:[^\n]*?,\s*([0-9.]+) tokens per second)?/.exec(l))) {
            r.evalMs = Number(g[1]);
            r.evalTok = Number(g[2]);
            if (g[3] !== undefined) r.evalRate = Number(g[3]);
            r.done = true;
        } else if ((g = /\btotal time =\s*([0-9.]+) ms/.exec(l))) {
            r.totalMs = Number(g[1]);
            r.done = true;
        } else if ((g = /\bstop processing: n_tokens =\s*(\d+)(?:,\s*truncated =\s*(\d+))?/.exec(l))) {
            r.relTok = Number(g[1]);
            r.trunc = g[2] !== undefined ? Number(g[2]) : 0;
            r.done = true;
        }
    }

    // legacy whole-tail fallbacks: cur_n context readings and old speed lines
    let legacyCur = -1;
    const reCur = /cur_n\s*=\s*(\d+)/g;
    while ((m = reCur.exec(t)) !== null) legacyCur = Math.max(legacyCur, Number(m[1]));
    let legacyCurSpeed = -1, legacyAvgSpeed = -1;
    const reCurSp = /cur speed =\s*([0-9.]+)/g;
    while ((m = reCurSp.exec(t)) !== null) legacyCurSpeed = Number(m[1]);
    const reAvgSp = /avg speed =\s*([0-9.]+)/g;
    while ((m = reAvgSp.exec(t)) !== null) legacyAvgSpeed = Number(m[1]);
    // one row per request: live rows are born at "processing task" and
    // refresh with every n_gen / prefill-progress line, so the stream and
    // the cards move DURING generation, not only at release.
    let anyActive = false, count = 0;
    let sumIn = 0, sumOut = 0, sumReused = 0, doneOut = 0, doneDecMs = 0;
    let used = -1, relLast = -1, liveMax = -1;
    let liveTg = -1, liveTg3 = -1, pRead = -1, pTot = 0, pRate = -1, genNow = -1;
    order.forEach(function (id) {
        const r = tasks[id];
        if (!r.open && !r.done && r.inTok < 0 && r.gen < 0 && r.relTok < 0 && r.pRead < 0) return;
        count++;
        const running = !r.done;
        if (running) anyActive = true;
        const inTok = r.inTok > 0 ? r.inTok : 0;
        // accepted tokens win over the eval-line count: with speculative
        // decoding the latter also counts rejected drafts
        const outTok = r.gen >= 0 ? r.gen : (r.evalTok > 0 ? r.evalTok : 0);
        const reused = (r.inTok > 0 && r.procTok >= 0 && r.inTok > r.procTok)
                       ? r.inTok - r.procTok : 0;
        sumIn += inTok;
        sumOut += outTok;
        sumReused += reused;
        if (!running && outTok > 0 && r.evalMs > 0) { doneOut += outTok; doneDecMs += r.evalMs; }
        // live context: while running the slot holds its prompt plus
        // everything accepted so far; once idle, the LATEST release
        // reading is the truth — an older release may predate a cache
        // wipe ("forcing full prompt re-processing" erases the rest)
        if (running) {
            let hold = -1;
            if (r.inTok >= 0 && r.gen >= 0) hold = r.inTok + r.gen;
            else if (r.pRead >= 0) hold = r.pRead;
            else if (r.open && r.inTok >= 0) hold = r.inTok;
            if (hold >= 0) liveMax = Math.max(liveMax, hold);
        } else if (r.relTok >= 0) {
            relLast = r.relTok;
        }
        // freshest decode speed in tail order: 3 s window first, average after
        if (r.tg3 > 0) liveTg3 = r.tg3;
        if (r.tg > 0) liveTg = r.tg;
        if (running && r.pRead >= 0) pRead = r.pRead;
        if (running && r.pTot > 0) pTot = r.pTot;
        if (r.pRate > 0) pRate = r.pRate;
        if (running && r.gen >= 0) genNow = r.gen;

        // llama timestamps are relative to boot, not wall-clock: stamp each
        // task the first time it is seen (the per-server map persists in
        // main.qml) so the shared table sorts llama rows correctly.
        let stamp = 0;
        if (seen) {
            if (seen[id] === undefined) seen[id] = now || 0;
            stamp = seen[id];
        }
        const dur = (r.totalMs > 0 ? r.totalMs
                   : Math.max(0, r.promptMs) + Math.max(0, r.evalMs)) / 1000;
        let tps;
        if (running) tps = r.tg3 > 0 ? r.tg3 : (r.tg > 0 ? r.tg : (r.pRate > 0 ? r.pRate : 0));
        else if (r.tg > 0) tps = r.tg;
        else if (r.evalRate > 0) tps = r.evalRate;
        else if (outTok > 0 && r.evalMs > 0) tps = outTok / (r.evalMs / 1000);
        else tps = dur > 0 ? outTok / dur : 0;
        s.reqs.push({
            at: stamp, durS: running ? 0 : dur, tps: tps,
            inTok: inTok, reused: reused, outTok: outTok,
            finish: running ? "…" : (r.trunc === 1 ? "length" : "stop")
        });
    });
    if (count > 0) {
        s.events = count;
        s.promptTok = sumIn;
        s.outTok = sumOut;
        s.reusedTok = sumReused;
        s.genNow = genNow;
        s.active = anyActive;
        used = liveMax >= 0 ? liveMax : relLast;
        s.ctxUsed = used;
        if (pRead >= 0 && pTot > 0) { s.promptRead = pRead; s.promptTotal = pTot; }
        if (pRate > 0) s.prefillTps = pRate;
        s.reqs = s.reqs.slice(-6).reverse();
    }

    // no per-task data in this window: legacy cur_n, then the last
    // n_tokens mention (cached prefix, checkpoint, "stop processing"),
    // then the older total-time estimate — same fallbacks as before
    if (used < 0) {
        if (legacyCur >= 0) used = legacyCur;
        else {
            const reNtok = /\bn_tokens\s*=\s*(\d+)/g;
            while ((m = reNtok.exec(t)) !== null) used = Number(m[1]);
        }
    }
    if (used < 0) {
        let lastTot = null;
        const reTot = /\|\s*total time =\s+([0-9.]+) ms \/ \s*(\d+) tokens/g;
        while ((m = reTot.exec(t)) !== null) lastTot = Number(m[2]);
        if (lastTot !== null) used = lastTot;
    }
    s.ctxUsed = used;
    // no task ids in this window (very old builds): a generation is live
    // between "processing task" (launch) and the matching "stop
    // processing" (release): whichever comes last wins
    if (count === 0) {
        const reProc = /\b(?:stop processing|processing task)\b/g;
        let lastOpen = -1, lastClose = -1;
        while ((m = reProc.exec(t)) !== null) {
            if (m[0] === "stop processing") lastClose = m.index;
            else lastOpen = m.index;
        }
        s.active = lastOpen > lastClose;
    }

    // speed: live n_gen tg_3s/tg (the webui's own series) beat the legacy
    // "cur speed"; with nothing live the last finished request's accepted
    // average holds. The eval line's "tokens per second" stays a last
    // resort: speculative decoding inflates it with draft tokens.
    // speed figure: while generating, tg_3s (llama's own last-3 s rate,
    // what the webui prints live); once released, the request's final tg
    // — the SAME number the shared table shows in Decode t/s, so the
    // card and the table can never disagree
    if (anyActive && liveTg3 > 0) s.tps = liveTg3;
    else if (liveTg > 0) s.tps = liveTg;
    else if (liveTg3 > 0) s.tps = liveTg3;
    else if (legacyCurSpeed > 0) s.tps = legacyCurSpeed;
    else {
        for (let i = order.length - 1; i >= 0; i = i - 1) {
            const r = tasks[order[i]];
            const t0 = r.tg > 0 ? r.tg : r.evalRate;
            if (t0 > 0) { s.tps = t0; break; }
        }
    }
    if (legacyAvgSpeed > 0) s.meanTps = legacyAvgSpeed;
    if (s.meanTps < 0 && doneOut > 0 && doneDecMs > 0) s.meanTps = doneOut / (doneDecMs / 1000);
    // CUDA/Metal backends print device memory at load ("used = X, free = Y,
    // size = S MiB"): the last reading labels the llama ring segment.
    const reVram = /used\s*=\s*([\d,]+),\s*free\s*=\s*[\d,]+,\s*size\s*=\s*([\d,]+)/g;
    while ((m = reVram.exec(t)) !== null) {
        s.logVramUsedMib = Number(m[1].replace(/,/g, ""));
        s.logVramSizeMib = Number(m[2].replace(/,/g, ""));
    }
}
