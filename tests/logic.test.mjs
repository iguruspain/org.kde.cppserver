// Regression suite for contents/ui/logic.js — the pure half of the Stats
// tab. Fixtures mirror the line shapes of a live llama.cpp (print_timing
// with right-aligned numeric columns, speculative decoding included: the
// eval line counts 616 draft tokens while n_gen accepted only 366) and a
// strata /metrics reply. Run: node --test tests/
//
// These encode the invariants the UI consumes and where real regressions
// bit: rows born at "processing task" (live stream), tg_3s live vs final
// tg (card == table), accepted-tokens-only counts, the sticky cache never
// resurrecting active/state, tok_s sparkline samples surviving zeros,
// parseStatusall's entry shape, and request-stream ordering.
import test from "node:test";
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
        "weird alive=1 pid=7 logfile=/x/my server.log\n");
    assert.equal(m["llama-cpp"].alive, true);
    assert.equal(m["llama-cpp"].pid, "60561");
    assert.equal(m["llama-cpp"].logfile, "/home/u/.cache/cppserver/logs/llama-cpp.log");
    assert.equal(m["audio-cpp"].alive, false);
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

test("mergeReqs: newest first, unstamped rows sink, cap applies", () => {
    const rows = L.mergeReqs([
        { name: "a", reqs: [{ at: 100, tps: 1 }, { at: 0, tps: 2 }] },
        { name: "b", reqs: [{ at: 300, tps: 3 }] }
    ], 2);
    assert.deepEqual(rows.map(r => r.at), [300, 100]);
    assert.equal(rows[0].name, "b");
    assert.equal(L.mergeReqs([{ name: "a", reqs: [{ at: 1 }, { at: 2 }, { at: 3 }] }], 2).length, 2);
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
