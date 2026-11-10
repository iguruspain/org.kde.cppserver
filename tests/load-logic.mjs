// Load contents/ui/logic.js (a QML `.pragma library`) into plain node.
// The file is dependency-free JS: only function/const declarations at top
// level, and Qt.* appears solely inside scriptPath()/scriptCmd() bodies that
// never run here. We drop the pragma and evaluate the source inside a
// function scope, then hand back the API surface the UI consumes.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const SRC = join(dirname(fileURLToPath(import.meta.url)),
    "..", "contents", "ui", "logic.js");

const API = [
    "homeExpand", "slugify", "normalizeServers", "serverBinary",
    "buildCommand", "subToken", "parseKv", "parseStatusall",
    "healthTally", "parseGpu", "gpuReadout", "pushHist", "stickify",
    "parseStats", "fmtReqRow", "mergeReqs", "llamaLogStats",
    "fmtTokens", "fmtTokensFull", "fmtMibPair", "fmtDur", "fmtAge",
    "fmtFeedMs", "fmtFeedTtfb", "AUDIO_FEED_MAX"
];

export function loadLogic() {
    let src = readFileSync(SRC, "utf8");
    if (!/^\.pragma library/m.test(src))
        throw new Error("logic.js lost its .pragma library marker - " +
            "the loader contract (declarations only) must be re-verified");
    src = src.replace(/^\.pragma library$/m, "");
    const fn = new Function(src + "\nreturn {" + API.join(",") + "};");
    const L = fn();
    for (const k of API)
        if (L[k] === undefined)
            throw new Error("logic.js no longer exports " + k);
    return L;
}
