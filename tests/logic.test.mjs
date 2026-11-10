// Regression suite for contents/ui/logic.js — the pure half of the Stats
// tab. Fixtures mirror the line shapes of a live llama.cpp (print_timing
// with right-aligned numeric columns, speculative decoding included: the
// eval line counts 616 draft tokens while n_gen accepted only 366) and a
// strata /metrics reply. Run: node --test tests/logic.test.mjs
//
// These encode the invariants the UI consumes and where real regressions
// bit: rows born at "processing task" (live stream), tg_3s live vs final
// tg (card == table), accepted-tokens-only counts, the sticky cache never
// resurrecting active/state, tok_s sparkline samples surviving zeros,
// parseStatusall's entry shape, and request-stream ordering.
import test, { describe } from "node:test";
import assert from "node:assert/strict";
import { loadLogic } from "./load-logic.mjs";

const L = loadLogic();

const LOAD = "[59483] 0.00.164.467 I srv    load_model: loading model '/home/u/models/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf'";
const CTXLINE = "[59483] 0.01.865.700 I llama_context: n_ctx                 = 65536";
const T0_LINES = [
    "[59483] 0.02.511.355 I slot launch_slot_: id  0 | task 0 | processing task, is_child = 0",
    "[59483] 0.02.511.365 I slot   operator(): id  0 | task 0 | new prompt, n_ctx_slot = 65536, n_keep = 0, task.n_tokens = 3551",
    "[59483] 0.07.045.631 I slot print_timing: id  0 | task 0 | n_gen =    375, tg = 124.21 t/s, tg_3s = 124.54 t/s",
    "[59483] 0.08.250.537 I slot print_timing: id  0 | task 0 | prompt eval time =    1523.14 ms /  3551 tokens (    0.43 ms per token,  2331.36 tokens per second)",
    "[59483] 0.08.250.540 I slot print_timing: id  0 | task 0 |        eval time =    4215.96 ms /   490 tokens (    8.62 ms per token,   115.99 tokens per second)",
    "[59483] 0.08.250.540 I slot print_timing: id  0 | task 0 |       total time =    5739.10 ms /  4041 tokens",
    "[59483] 0.08.250.827 I slot      release: id  0 | task 0 | stop processing: n_tokens = 4040, truncated = 0"
].join("\n");
const T173_OPEN = [
    "[59483] 0.08.366.867 I slot launch_slot_: id  0 | task 173 | processing task, is_child = 0",
    "[59483] 0.08.366.876 I slot   operator(): id  0 | task 173 | new prompt, n_ctx_slot = 65536, n_keep = 0, task.n_tokens = 152",
    "[59483] 0.11.496.875 I slot print_timing: id  0 | task 173 | n_gen =    247, tg =  81.71 t/s, tg_3s =  82.04 t/s",
    "[59483] 0.14.594.319 I slot print_timing: id  0 | task 173 | n_gen =    366, tg =  59.76 t/s, tg_3s =  38.42 t/s"
].join("\n");
const T173_CLOSE = [
    "[59483] 0.16.900.000 I slot print_timing: id  0 | task 173 | prompt eval time =     119.11 ms /   152 tokens (    0.78 ms per token,  1276.16 tokens per second)",
    "[59483] 0.16.900.001 I slot print_timing: id  0 | task 173 |        eval time =    5210.77 ms /   616 tokens (    8.46 ms per token,   118.22 tokens per second)",
    "[59483] 0.16.900.001 I slot print_timing: id  0 | task 173 |       total time =    5329.88 ms /   768 tokens",
    "[59483] 0.16.900.067 I slot      release: id  0 | task 173 | stop processing: n_tokens = 918, truncated = 0"
].join("\n");

// one llama /metrics poll: empty body (no --metrics is the norm here)
function llamaTick(log, seen, extra) {
    return L.parseStats({ kind: "llama", ep: "", err: "", health: "", body: "", log: log, at: 0 },
        seen || {}, extra || {});
}

test("llama mid-decode: request row is BORN at processing task, live figures", () => {
    const s = llamaTick(CTXLINE + "\n" + LOAD + "\n" + T0_LINES + "\n" + T173_OPEN);
    assert.equal(s.state, "generating");
    assert.equal(s.active, true);
    assert.equal(s.model, "gemma-4-12B-it-qat-UD-Q4_K_XL.gguf");
    assert.equal(s.ctxMax, 65536);
    // live counters come from the n_gen series (accepted tokens)
    assert.equal(s.genNow, 366);
    // live speed = the LAST tg_3s in tail order (what the webui charts)
    assert.equal(s.tps, 38.42);
    // live context = prompt + accepted of the running slot
    assert.equal(s.ctxUsed, 152 + 366);
    // the running task ALREADY has a row, marked unfinished
    const live = s.reqs.find(r => r.finish === "…");
    assert.ok(live, "running task must have a live row");
    assert.equal(live.inTok, 152);
    assert.equal(live.outTok, 366);
    assert.equal(live.tps, 38.42); // row and card read the SAME live figure
});

test("llama released: final tg on card == Decode t/s in the table", () => {
    const seen = {};
    const s = llamaTick(CTXLINE + "\n" + LOAD + "\n" + T0_LINES + "\n" + T173_OPEN + "\n" + T173_CLOSE, seen);
    assert.equal(s.state, "idle");
    assert.equal(s.active, false);
    assert.equal(s.ctxUsed, 918); // LATEST release reading, not a max
    assert.equal(s.genNow, -1);   // nothing running: no stale count
    // speculative decoding: the eval line's 616 counts REJECTED drafts;
    // the accepted n_gen (366) is what the UI must show
    const row = s.reqs.find(r => r.finish === "stop");
    assert.ok(row);
    assert.equal(row.outTok, 366);
    // after release the card holds the request's final tg - the very
    // number the table shows (they can never disagree)
    assert.equal(s.tps, 59.76);
    assert.equal(row.tps, 59.76);
    // task 0: prompt fully reprocessed -> 0 reused; mean over finished tasks
    assert.equal(s.reqs.length, 2);
});

test("llama rows keep first-sight wall-clock stamps across ticks", () => {
    const seen = {};
    const s1 = llamaTick(T173_OPEN, seen);
    const s2 = llamaTick(T173_OPEN, seen);
    assert.equal(s1.reqs[0].at, s2.reqs[0].at);
    assert.ok(s1.reqs[0].at > 0); // stamped with wall-clock, not boot time
});

test("llama truncated request finishes as 'length'", () => {
    const log = [
        "[59483] 0.20.000.000 I slot launch_slot_: id  0 | task 9 | processing task, is_child = 0",
        "[59483] 0.20.500.000 I slot      release: id  0 | task 9 | stop processing: n_tokens = 512, truncated = 1"
    ].join("\n");
    const s = llamaTick(log);
    assert.equal(s.reqs[0].finish, "length");
});

test("llama prefill: prompt-processing lines feed the card progress", () => {
    const log = [
        "[59483] 0.30.000.000 I slot launch_slot_: id  0 | task 21 | processing task, is_child = 0",
        "[59483] 0.30.100.000 I slot   operator(): id  0 | task 21 | new prompt, n_ctx_slot = 65536, n_keep = 0, task.n_tokens = 3551",
        "[59483] 0.30.450.000 I slot print_timing: id  0 | task 21 | prompt processing, n_tokens =  1124, progress = 0.32, t =  0.45 s /  2498.15 tokens per second"
    ].join("\n");
    const s = llamaTick(log);
    assert.equal(s.promptRead, 1124);
    assert.equal(s.promptTotal, 3513); // 1124 / 0.32
    assert.equal(s.prefillTps, 2498.15);
});

test("llama legacy builds: n_decoded , at lines are accepted", () => {
    const log = [
        "slot launch_slot_: id 0 | task 4 | processing task",
        "slot print_timing: id 0 | task 4 | n_decoded =  128 , at =  34.50 t/s"
    ].join("\n");
    const s = llamaTick(log);
    assert.equal(s.genNow, 128);
    assert.equal(s.tps, 34.5);
});

test("llama transparent tick: sticky cache holds scalars but NEVER active/state", () => {
    // the class of bug that plateaued the speed tile: a poll with no new
    // data must keep numbers alive yet report the honest idle state
    const seen = {};
    const stick = {};
    const full = llamaTick(CTXLINE + "\n" + LOAD + "\n" + T0_LINES + "\n" + T173_OPEN + "\n" + T173_CLOSE, seen, { stick });
    assert.equal(full.tps, 59.76);
    const empty = llamaTick("", seen, { stick });
    assert.equal(empty.state, "idle");
    assert.equal(empty.active, false);          // booleans are not sticky
    assert.equal(empty.reqs.length, 0);         // stream comes from real data only
    assert.equal(empty.tps, 59.76);             // scalars hold their last real value
    assert.equal(empty.ctxUsed, 918);
});

const STRATA = JSON.stringify({
    engine: { model: "qwen3-next", max_context: 131072, arena_mib: 7021 },
    live: { state: "generating", phase: "decode", queued: 1, prompt_total: 3551,
        generated: 162, max_tokens: 4096, prompt_read: 1664, tok_s: 133.2, tok_s_mean: 118.4 },
    totals: { requests: 9, prompt_tokens: 12800, output_tokens: 4200, reused: 8192 },
    requests: [
        { time: 200, duration_s: 4.2, decode_tok_s: 111.1, prompt_tokens: 900,
            output_tokens: 400, finish: "stop", reused: 256, hit_rate: 0.28 },
        { time: 100, duration_s: 1.1, decode_tok_s: 99.9, prompt_tokens: 100,
            output_tokens: 30, finish: "length", reused: 0, hit_rate: 0 }
    ],
    hardware: { gpu_util: 97, gpu_temp: 68, gpu_power: 280, gpu_power_limit: 285,
        gpu_mem_used: 25263505408, gpu_mem_total: 25769803776, cpu: 41,
        ram_used: 12000000000, ram_total: 34000000000, tok_s_mean: 118.4 },
    hardware_static: { gpu_name: "NVIDIA GeForce RTX 3090", cores: 8, threads: 16 },
    history: { tok_s: [120.85, 102.65, 0], cpu: [40, 41, 42] }
});

test("strata: live progress, ctx, VRAM and history pass through", () => {
    const s = L.parseStats({ kind: "strata", body: STRATA, log: "", err: "" }, {}, {});
    assert.equal(s.state, "generating");
    assert.equal(s.active, true);
    assert.equal(s.queued, 1);
    assert.equal(s.tps, 133.2);
    assert.equal(s.genNow, 162);
    assert.equal(s.genMax, 4096);       // strata HAS a token target
    assert.equal(s.promptRead, 1664);
    assert.equal(s.promptTotal, 3551);
    assert.equal(s.ctxUsed, 3551 + 162);
    assert.equal(s.ownVramMib, 7021);   // arena is strata's own footprint
    assert.equal(s.vramTotalMib, 24576); // bytes -> MiB
    assert.deepEqual(s.hist.tok_s, [120.85, 102.65, 0]);
    assert.equal(s.reqs[0].at, 200);     // newest first
    assert.equal(s.reqs[1].finish, "length");
    assert.equal(s.events, 9);
    assert.equal(s.reusedTok, 8192);
});

test("pushHist: zero tok samples are RECORDED, cap rolls, missing keeps", () => {
    // the tok_s series plateaued at "forever last speed" exactly once a
    // zero sample was dropped - zeros MUST survive
    let h = L.pushHist({}, { cpuPct: 50, tokSample: 0 }, 100);
    assert.deepEqual(h.cpu, [50]);
    assert.deepEqual(h.tok_s, [0]);
    h = L.pushHist(h, { tokSample: 1 }, 3);
    h = L.pushHist(h, { tokSample: 2 }, 3);
    assert.deepEqual(h.tok_s, [0, 1, 2]);
    h = L.pushHist(h, { tokSample: 3 }, 3);
    assert.deepEqual(h.tok_s, [1, 2, 3]); // cap trims the oldest per push
    h = L.pushHist(h, { tokSample: 4 }, 3);
    assert.deepEqual(h.tok_s, [2, 3, 4]);
    assert.deepEqual(h.tok_s, [2, 3, 4]);
    h = L.pushHist(h, { cpuPct: 7 }, 3);     // missing sample: series intact
    assert.deepEqual(h.tok_s, [2, 3, 4]);
    assert.deepEqual(h.cpu, [50, 7]);
});

test("parseStatusall: entries carry the alive boolean the UI relies on", () => {
    // main.qml consults entry.alive when rebuilding runningMap; a shape
    // change silently starves the tok_s sampler
    const m = L.parseStatusall(
        "llama-cpp alive=1 pid=60561 logfile=/home/u/.cache/cppserver/logs/llama-cpp.log\n" +
        "strata alive=1 pid=44 pid=/weird\n" +
        "audio-cpp alive=0\n" +
        "external-iq3_s-128k alive=1 pid=77 logfile=/s/strata/launch/iq3_s-128k.engine.log\n" +
        "extport-iq3_s-128k=18888\n" +
        "weird alive=1 pid=7 logfile=/x/my server.log\n");
    assert.equal(m["llama-cpp"].alive, true);
    assert.equal(m["llama-cpp"].pid, "60561");
    assert.equal(m["llama-cpp"].logfile, "/home/u/.cache/cppserver/logs/llama-cpp.log");
    assert.equal(m["audio-cpp"].alive, false);
    // external engines ride the same entry shape; the extport key=value
    // line is NOT an entry (no alive token) and must not pollute
    assert.equal(m["external-iq3_s-128k"].alive, true);
    assert.equal(m["external-iq3_s-128k"].pid, "77");
    assert.equal(m["extport-iq3_s-128k"], undefined);
    // logfile is the raw tail of the line: spaces allowed, only pid= before it
    assert.equal(m["weird"].logfile, "/x/my server.log");
});

test("parseGpu: vramowner lines attribute VRAM to server sessions", () => {
    const g = L.parseGpu([
        "proc=123:24111", "proc=456:1024", "proc=789:512",
        "vramowner=llama-cpp=24111",
        "vramowner=strata=1024", "vramowner=strata=512",
        "gpuname=NVIDIA GeForce RTX 3090", "gputemp=68", "gpupow=120.5",
        "cores=8", "threads=16"
    ].join("\n"));
    assert.equal(g.vramBy["llama-cpp"], 24111);
    assert.equal(g.vramBy["strata"], 1536); // engine children sum into the session
    assert.equal(g.procs["456"], 1024);
    assert.equal(g.gpuTemp, 68);
    assert.equal(g.gpuPower, 120.5);
    assert.equal(g.cpuCores, 8);
    assert.equal(g.gpuName, "NVIDIA GeForce RTX 3090");
    assert.equal(L.gpuReadout(g.gpuName), "RTX 3090"); // vendor AND Geforce prefix go
});

test("serverReqFeed: per-card table rows, newest first, unstamped sink, cap applies", () => {
    const rows = L.serverReqFeed([{ at: 100, tps: 1 }, { at: 0, tps: 2 }, { at: 300, tps: 3 }], true);
    assert.equal(rows.length, 3);
    // formatted strings, and the server column is gone (the card IS the server)
    assert.deepEqual(Object.keys(rows[0]), ["time", "status", "inTok", "reused", "outTok", "tps", "dur"]);
    assert.equal(rows[0].tps, "3.00"); // at=300 first
    assert.equal(rows[1].tps, "1.00");
    assert.equal(rows[2].tps, "2.00"); // unstamped rows sink to the bottom
    const many = [];
    for (let i = 1; i <= L.REQ_FEED_MAX + 3; i++) many.push({ at: i });
    assert.equal(L.serverReqFeed(many, true).length, L.REQ_FEED_MAX);
    // the tokens toggle blanks the token columns (reused/out only)
    const off = L.serverReqFeed([{ at: 5, inTok: 40, reused: 12, outTok: 33, tps: 7 }], false)[0];
    assert.equal(off.inTok, "40"); // prompt count is a request row, it stays
    assert.equal(off.reused, "–");
    assert.equal(off.outTok, "–");
});

test("fmtReqRow: t/s prints exactly, empty slots are dashes", () => {
    const r = L.fmtReqRow({ at: 0, finish: "", inTok: 0, reused: 0, outTok: 0, tps: 64.7, durS: 0, name: "x" });
    assert.equal(r.tps, "64.70");
    assert.equal(r.time, "–");
    assert.equal(r.status, ""); // live rows: "…" straight through
    assert.equal(r.inTok, "–");
    const d = L.fmtReqRow({ at: 100, finish: "stop", inTok: 152, reused: 20, outTok: 366, tps: 0, durS: 5.34 });
    assert.equal(d.dur, "5.3s");
    assert.equal(d.tps, "-");
    assert.equal(d.reused, "20");
});

test("buildCommand: port 0 and empty preset drop their flags; ~ expands", () => {
    const s = {
        command: "llama-server -m ~/m.gguf --host {HOST} --port {PORT} --config {CONFIG_FILE} --preset {PRESET}",
        host: "127.0.0.1", port: 0, configFile: "", preset: "", id: "x", name: "x"
    };
    let cmd = L.buildCommand(s, "/home/u");
    assert.ok(cmd.includes("-m /home/u/m.gguf"));
    assert.ok(cmd.includes("--host 127.0.0.1"));
    assert.ok(!cmd.includes("--port"));
    assert.ok(!cmd.includes("--preset"));
    assert.ok(!cmd.includes("--config"));
    assert.ok(!cmd.includes("{"));
    cmd = L.buildCommand(Object.assign({}, s, { port: 8080, preset: "My Preset" }), "/home/u");
    assert.ok(cmd.includes("--port 8080"));
    assert.ok(cmd.includes("--preset 'My Preset'")); // spaces -> shell-quoted
});

test("normalizeServers: ids slugified-unique, port clamped, enabled defaults true", () => {
    const out = L.normalizeServers([
        { id: "My Server!", name: "My Server!" },
        { id: "my-server", port: 99999 },
        { name: "other", port: -5, enabled: false }
    ]);
    assert.deepEqual(out.map(s => s.id), ["my-server", "my-server-2", "other"]);
    assert.equal(out[1].port, 65535);
    assert.equal(out[2].port, 0);
    assert.equal(out[0].enabled, true);
    assert.equal(out[2].enabled, false);
});

// ── audio.cpp log tail → parseStats audio shape (real captured lines) ──
describe("audioLogStats (parseStats kind:audio)", () => {
    // verbatim lines from a live audio-cpp run with --log (the TRACE
    // server.model.* block, the CUDA block, the request lifecycle and
    // two complete chunk cycles; omnivoice family)
    const A = [
        "[TRACE ts=20261110-092059] server.model.id omnivoice",
        "[TRACE ts=20261110-092059] server.model.family omnivoice",
        "[TRACE ts=20261110-092059] server.model.task tts",
        "[TRACE ts=20261110-092059] server.model.backend cuda",
        "[SERVER_HTTP_DEBUG] http.headers method=POST path=/v1/audio/speech content_length=1338 transfer_encoding=<none> incremental=false prefetched_body_bytes=1338",
        "[SERVER_HTTP_DEBUG] http.body_ready path=/v1/audio/speech body_bytes=1338",
        "[TIMING ts=20261110-092102] omnivoice.session.generate_ms 1641.754412",
        "[TIMING ts=20261110-092102] omnivoice.generator.compute_ms 1491.8351340000004",
        "[TIMING ts=20261110-092102] omnivoice.session.decode_ms 70.121722",
        "[TIMING ts=20261110-092102] omnivoice.session.first_audio_ms 1716.901662",
        "[TIMING ts=20261110-092104] omnivoice.session.generate_ms 1808.531676",
        "[TIMING ts=20261110-092104] omnivoice.session.decode_ms 79.617604",
        "[TIMING ts=20261110-092112] session.wall_ms 11799.27377",
        "[SERVER_HTTP_DEBUG] http.headers method=GET path=/health content_length=<none> transfer_encoding=<none> incremental=false prefetched_body_bytes=0",
        "[SERVER_HTTP_DEBUG] http.body_ready path=/health body_bytes=0"
    ].join("\n");
    // verbatim from a live audio-cpp transcription: ASR never emits a
    // first-audio marker — the feed prints that cell as the literal "null"
    const ASR = [
        "[SERVER_HTTP_DEBUG] http.headers method=POST path=/v1/audio/transcriptions content_length=309559 transfer_encoding=<none> incremental=false prefetched_body_bytes=131072",
        "[TRACE ts=20261110-124506] server.model.id parakeet-tdt",
        "[TRACE ts=20261110-124506] server.model.task asr",
        "[TIMING ts=20261110-124506] parakeet_tdt.transcribe.window_count 26",
        "[TIMING ts=20261110-124507] parakeet_tdt.session.generate_ms 253.032492",
        "[TIMING ts=20261110-124507] parakeet_tdt.encoders.encode_ms 45.318809",
        "[TIMING ts=20261110-124518] parakeet_tdt.session.generate_ms 68.967095",
        "[TIMING ts=20261110-124518] session.wall_ms 11924.959091",
        "[SERVER_HTTP_DEBUG] http.headers method=GET path=/health content_length=<none> transfer_encoding=<none> incremental=false prefetched_body_bytes=0"
    ].join("\n");
    // fixed clock: the live request must read fresh regardless of when
    // the suite runs (the freshness window is what stops old replayed
    // logs from faking "generating")
    const NOW = function (h, m, s) { return new Date(2026, 10, 10, h, m, s).getTime() / 1000; };
    const st = () => L.parseStats({ kind: "audio", log: A, err: "" }, {}, {});
    test("model/task/backend from the TRACE block", () => {
        const s = st();
        assert.equal(s.model, "omnivoice");
        assert.equal(s.audioTask, "tts");
        assert.equal(s.audioBackend, "cuda");
    });
    test("closed request -> feed row; health noise does not open one", () => {
        const s = st();
        assert.equal(s.state, "idle");
        assert.equal(s.active, false);
        assert.equal(s.events, 1);
        assert.equal(s.audioReqs.length, 1);
        const r = s.audioReqs[0];
        assert.equal(r.fam, "omnivoice");
        assert.equal(r.chunks, 2);
        assert.equal(Math.round(r.durMs), 11799);
        assert.equal(Math.round(r.ttfbMs), 1717);
        assert.equal(r.err, false);
        assert.equal(r.running, undefined);
        // request start stamped from its own generated chunks (ts lines)
        const d = new Date(r.at * 1000);
        assert.equal(`${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`, "2026-11-10");
    });
    test("open request is live: generating, running feed row, no tokens", () => {
        const open = A.replace("[TIMING ts=20261110-092112] session.wall_ms 11799.27377", "") +
                     "\n[SERVER_HTTP_DEBUG] http.headers method=POST path=/v1/audio/speech content_length=200";
        const s = L.parseStats({ kind: "audio", log: open, err: "" }, {}, { now: NOW(9, 21, 15) });
        assert.equal(s.state, "generating");
        assert.equal(s.active, true);
        assert.equal(s.tps, -1); // audio never contributes tokens
        assert.equal(s.ctxMax, 0);
        assert.equal(s.reqs.length, 0); // audio NEVER joins the shared table
        const live = s.audioReqs[0]; // newest row is the live one
        assert.ok(live.running);
        assert.ok(live.durMs >= 0);
    });
    test("ASR request: no first-audio marker prints as literal null", () => {
        const s = L.parseStats({ kind: "audio", log: ASR, err: "" }, {}, {});
        assert.equal(s.model, "parakeet-tdt");
        assert.equal(s.audioTask, "asr");
        assert.equal(s.audioReqs.length, 1);
        assert.equal(s.audioReqs[0].fam, "parakeet_tdt");
        assert.equal(s.audioReqs[0].ttfbMs, null);
        assert.equal(L.fmtFeedTtfb(s.audioReqs[0].ttfbMs), "null");
        assert.equal(s.audioReqs[0].chunks, 2);
    });
    test("multi-family tail: per-family blocks newest-first, family-tagged", () => {
        const both = [
            "[SERVER_HTTP_DEBUG] http.headers method=POST path=/v1/audio/speech content_length=100",
            "[TRACE ts=20261110-100000] server.model.id omnivoice",
            "[TRACE ts=20261110-100000] server.model.family omnivoice",
            "[TIMING ts=20261110-100002] omnivoice.session.generate_ms 1500",
            "[TIMING ts=20261110-100010] session.wall_ms 10000.5",
            "[SERVER_HTTP_DEBUG] http.headers method=POST path=/v1/audio/transcriptions content_length=300000",
            "[TRACE ts=20261110-101000] server.model.id parakeet-tdt",
            "[TRACE ts=20261110-101000] server.model.family parakeet_tdt",
            "[TIMING ts=20261110-101005] parakeet_tdt.session.generate_ms 300",
            "[TIMING ts=20261110-101006] session.wall_ms 6000",
            // third omnivoice request, newer than the parakeet one, and it
            // only prints the un-namespaced wall_ms close: the family TRACE
            // line is what keeps it in its own block
            "[SERVER_HTTP_DEBUG] http.headers method=POST path=/v1/audio/speech content_length=100",
            "[TRACE ts=20261110-102000] server.model.id omnivoice",
            "[TRACE ts=20261110-102000] server.model.family omnivoice",
            "[TIMING ts=20261110-102003] session.wall_ms 3000"
        ].join("\n");
        const s = L.parseStats({ kind: "audio", log: both, err: "" }, {}, {});
        assert.equal(s.audioReqs.length, 3);
        assert.equal(s.audioReqs[0].fam, "omnivoice");
        assert.equal(s.audioReqs[1].fam, "parakeet_tdt");
        assert.equal(s.audioReqs[2].fam, "omnivoice");
        assert.ok(s.audioReqs[0].at > s.audioReqs[1].at); // newest first
        assert.equal(s.events, 3);
    });
    test("stale open POST (log replayed after restart) does not fake generating", () => {
        // A ends idle; append an un-closed POST whose stamps are from the
        // morning, probe "at night": the freshness window must gate it
        const replay = A + "\n[SERVER_HTTP_DEBUG] http.headers method=POST path=/v1/audio/speech content_length=100";
        const s = L.parseStats({ kind: "audio", log: replay, err: "" }, {}, { now: NOW(23, 0, 0) });
        assert.equal(s.state, "idle");
        assert.equal(s.active, false);
        assert.equal(s.audioReqs.filter(r => r.running).length, 0);
    });
    test("health request mid-request keeps the family binding, no false row", () => {
        const mid = [
            "[SERVER_HTTP_DEBUG] http.headers method=POST path=/v1/audio/speech content_length=100",
            "[TRACE ts=20261110-110000] server.model.id omnivoice",
            "[SERVER_HTTP_DEBUG] http.headers method=GET path=/health content_length=<none>",
            "[SERVER_HTTP_DEBUG] http.body_ready path=/health body_bytes=0",
            "[TIMING ts=20261110-110002] omnivoice.session.generate_ms 1500"
        ].join("\n");
        const s = L.parseStats({ kind: "audio", log: mid, err: "" }, {}, { now: NOW(11, 0, 10) });
        assert.equal(s.audioReqs.length, 1); // only the live audio request
        assert.equal(s.audioReqs[0].fam, "omnivoice");
        assert.equal(s.audioReqs[0].running, true);
        assert.equal(s.state, "generating");
    });
    test("error lines flag the open request; feed caps at AUDIO_FEED_MAX", () => {
        let errlog = "";
        for (let i = 0; i < 9; i++)
            errlog += `[SERVER_HTTP_DEBUG] http.headers method=POST path=/v1/audio/speech\n[TIMING ts=20261110-0800${String(i).padStart(2, "0")}] session.wall_ms 1000\n`;
        // then one request that died with an error and never closed: it
        // stays open (live) and must be flagged
        errlog += "[SERVER_HTTP_DEBUG] http.headers method=POST path=/v1/audio/speech\n" +
                  "[TRACE ts=20261110-100459] server.model.id omnivoice\n" +
                  "[SERVER_ERROR] engine error while synthesizing\n";
        const s = L.parseStats({ kind: "audio", log: errlog, err: "" }, {}, { now: NOW(10, 5, 0) });
        assert.equal(s.audioReqs.length, L.AUDIO_FEED_MAX);
        const flagged = s.audioReqs.filter(r => r.err);
        assert.ok(flagged.length >= 1);
    });
    test("feed formatters", () => {
        assert.equal(L.fmtFeedMs(-1), "–");
        assert.equal(L.fmtFeedMs(1641.75), "1.64s");
        assert.equal(L.fmtFeedMs(11799.27), "11.8s");
        assert.equal(L.fmtFeedMs(500), "0.50s");
        assert.equal(L.fmtFeedTtfb(null), "null");
        assert.equal(L.fmtFeedTtfb(1716.9), "1.72s");
    });
    test("idle window keeps values via the sticky cache", () => {
        const stick = {};
        const s1 = L.parseStats({ kind: "audio", log: A, err: "" }, {}, { stick });
        const s2 = L.parseStats({ kind: "audio", log: "audiocpp_server listening on http://127.0.0.1:18081", err: "" }, {}, { stick });
        assert.equal(s2.events, 1);
        assert.equal(s2.model, "");
        assert.equal(s2.state, "");
    });
    test("model carried across restarts by the extra.model hook", () => {
        const s = L.parseStats({ kind: "audio", log: "audiocpp_server listening on http://127.0.0.1:18081", err: "" }, {}, { model: "omnivoice" });
        assert.equal(s.model, "omnivoice");
    });
    test("old-format log (no ts=): idle card, no rows, no state", () => {
        const old = [
            "[TIMING] session.generate_ms 1641.754412",
            "[SERVER_HTTP_DEBUG] http.headers method=POST path=/v1/audio/speech content_length=1338"
        ].join("\n");
        const s = L.parseStats({ kind: "audio", log: old, err: "" }, {}, {});
        assert.equal(s.audioReqs.length, 0);
        assert.equal(s.state, "");
        assert.equal(s.model, "");
    });
});
