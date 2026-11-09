# Repository Guidelines

## Project Overview

`cpp servers` is a KDE Plasma 6 plasmoid (package id `org.kde.cppserver`, v1.7.7, MIT) that configures, starts/stops, and live-tails local C++ inference servers (llama.cpp, strata — via `strata launch --preset` —, audio.cpp, stable-diffusion.cpp, or any custom command) and shows a live per-server/machine stats dashboard. Pure QML + one bash backend script — **no C++ in this repo** despite the name. Form factors: desktop, mediacenter, handset, plus system tray (`X-Plasma-NotificationArea`).

## Architecture & Data Flow

- **QML entry**: `contents/ui/main.qml` — `PlasmoidItem` with all state, the serialized command queue, and polling timers.
- **Backend**: `contents/scripts/cppserverctl.sh` — single bash script, subcommands `init | cfgread | cfgwrite | start | stop | rename | statusall | logread | deps | probe | presets | gpu`. Protocol: stdout is `key=value` lines; errors are `error=<code>` + nonzero exit. Servers run in `setsid` sessions and survive plasmashell restarts. Liveness is derived from `<id>.pid` files (pid + start time, so recycled PIDs are not mistaken for live servers). `rename <old> <new>` migrates `<old>.{log,pid,strata}` to `<new>.{log,pid,strata}`; a running server keeps running (no restart). `deps <binary>...` reports `OK|MISSING` per binary — the UI uses it to flag servers whose executable is not on PATH. `probe <url>` does a short-timeout curl GET of a local http(s) endpoint and prints the raw body (used by the Stats tab). `presets` prints `presets=<json>` from `strata launch --list-presets --output json` (`error=strata_missing|presets_failed`).
- **strata launch semantics**: the template is `strata launch --preset {PRESET} --no-tui` (`{PRESET}` is shell-quoted by `subToken`; preset names may contain spaces — strata slugs them as lowercase non-alnum→`-`). Such cards hide the **Host/Port/Config file** rows (`card.strataLaunch`); the port field stays at 18888 (strata's default) so the monitor can poll it. `strata launch` is a short-lived launcher: `start` extracts the raw preset name (`strata_preset_of`, handles single/double-quoted and bare values) and writes it to a `<id>.strata` marker in `LOG_ROOT`; the already-running guard fires when the pidfile is live **or** strata has a live engine for that slug (`strata_engine_pid`: reads `$XDG_STATE_HOME/strata/runtime/launch-<slug>-*.ready.json`, validates `/proc/<pid>` + cmdline contains "strata"). `statusall` re-points the pidfile at that engine pid and emits `logfile=` pointing at strata's own `$XDG_STATE_HOME/strata/launch/<slug>.engine.log` (a read-only probe dir, so no symlinks out; `logread` whitelists `*.engine.log` under that directory); `stop` runs `strata launch --stop --preset <raw name>` first (marker content, 12 s cap) and only then falls back to SIGTERM-on-process-group; both delete the marker.
- **UI ↔ script**: no ScriptEngine, no owned processes. All shell traffic goes through `P5Support.DataSource { engine: "executable" }` (import `org.kde.plasma.plasma5support`), which is **single-flight**: `run(cmd, handler)` enqueues; `pump()` fires one at a time; a 20 s watchdog timer unblocks stuck jobs. Duplicate in-flight commands (status/log polls) are dropped. Script is always invoked as `bash <shQuotedAbsolutePath> <subcmd> ...`; absolute path comes from `Qt.resolvedUrl("../scripts/cppserverctl.sh")` in `logic.js`.
- **Config — two distinct systems, do not conflate**:
  1. KConfig (`contents/config/main.xml`): per-widget-instance state in the `General` group — `uiJson` (String, default `{}`, UI state `{activeTab, activeLogId}`) plus log-view settings `logFontAuto` (Bool, default `true`, when on the log follows `Kirigami.Theme.smallFont.pointSize`), `logFontSize` (Int, explicit point-size override used only when `logFontAuto` is off; SpinBox min is 1 so no magic `0`) and `logShowErrors`/`logShowWarnings`/`logShowOom`/`logShowTps` (Bool, default `true`), plus Stats-tab toggles `statShowEvents`/`statShowTps`/`statShowTokens`/`statShowVram`/`statShowHardware` (Bool, default `true`, mirrored as `statShow*` properties in `main.qml` and consumed in the Stats tab of `MainPage.qml`). All applied live; read via `Plasmoid.configuration.*`. The effective size is computed in `main.qml` as the `logFontPointSize` property and consumed in `MainPage.qml` via `page.backend.logFontPointSize`.
  2. Shared server list: `~/.config/cppserver/servers.json` — JSON array of `{ id, name, command, host, port, configFile, preset, enabled }`. Deliberately **not** in KConfig: shared across all widget instances and editable outside Plasma. Written atomically (mktemp + `mv`) with 450 ms debounce (`ConfigServers.qml`), hot-reloaded by the widget: every `statusall` reply carries `cfgmtime=`; on change the widget re-runs `cfgread`.
- **Data flow**: `ConfigServers.qml` edits a `ListModel` → debounced `cfgwrite` → `servers.json` on disk → widget `statusall` → mtime change → `cfgread` → refreshed `ListView`. Command templates use `{HOST}` / `{PORT}` / `{CONFIG_FILE}` / `{PRESET}` placeholders (port `0` drops the port flag; an empty `{PRESET}` drops the `--preset` flag and its value; `~`/`$HOME` expanded). The Preset row (visible only for strata-launch commands, which also hide the Host/Port/Config file rows) is an editable `PlasmaComponents.ComboBox` fed by the `presets` subcommand on load + Reload button. The `id` (Log ID field) is stable by default but explicitly editable: on change the value is slugified, checked for uniqueness, then `rename <old> <new>` migrates the log/pid files — a running server is not restarted.
- **Logs**: `$XDG_CACHE_HOME/cppserver/logs/<id>.log`, tailed 500 ms while the Logs tab is open (last 400 lines); UI supports substring/regex filter, pause, follow, and stat chips (error / warning / OOM counts, max t/s) toggleable via the Logs config page. Stats are computed from the visible log text in `logic.js` (`logStats`); t/s is only printed by llama.cpp. Counted lines are highlighted in the log view (`highlightLog`, same classification as `logStats`): OOM/error lines in `Kirigami.Theme.negativeTextColor`, warnings in `Kirigami.Theme.neutralTextColor`; the log `TextArea` switches to `TextEdit.RichText` with an HTML span per matched line (lines joined with `<br>`), plain text for placeholders.
- **Stats (Live monitor tab)**: while the tab is open, `pollStats()` in `main.qml` runs `probe <url>` once per second per running server. Endpoint chain: `/health` first (tiny, identifies the server — strata answers `{"service":"strata"}`), then `/metrics` for strata and llama (strata keeps `/metrics` on every later tick; binaries named `llama-server`/`llama-serve` start at `/metrics`). `applyProbe` classifies the reply into `statsMap[id] = { ep, kind, err, health, body, log, at }` with `kind` in `strata` (on `/metrics` there is no `service` key — strata metrics are recognized by `engine`+`history` sections; generic JSON metrics get `json` + `no_metrics`) / `json` / `llama` (Prometheus text; prefix `llamacpp:` upstream, `llm:` legacy) / `none`; llama servers additionally get a `logread` tail attached (works without `--metrics`: log-derived n_ctx/context/tps). `logic.js` renders everything: `parseStats` (per-kind: live state/progress, ctx, vram, counters, `hist` series, `reqs` per-request list, `hardware` incl. `hardware_static`), `parsePrometheus`, `llamaLogStats`, `healthTally`, `mergeReqs` (cross-server recent-request table rows, newest first, no-`at` last, capped). `MainPage.qml` draws the unified dashboard: per-server cards (state + phase progress, queue, t/s; on the right a context **GaugeRing** whose `segments` come from `ctxSegs` — prompt/out/otros — and below the name a fixed 5-column token **grid** — petic/req, tok in, tok out, reused, context — with values in `Kirigami.Theme.readOnlyTextFont` so changing numbers never reflow the card), machine KPI tiles (t/s, GPU temp, GPU power, disk, …) that appear only once their source reports data and go stale-blank after 1 s without it (`tileStale`/`tileIds`), plus machine **GaugeRings first** (untitled headline block): CPU (readout `%1 cores / %2 threads`, sparkline from strata's `history`), GPU load (name from `hardware_static`), VRAM (segmented per server process, `fmtMibPair` readout) and RAM, and the shared **request stream**: `main.qml` merges every parsed request (`refreshReqStream` → `mergeReqs` + `fmtReqRow`, llama log rows stamped on first sight via `reqSeenOf`) into `statsReqRows`, deduped by content so idle servers never re-render it; `ReqTable.qml` renders it verbatim (i18n header added there, `statShowTokens` blanks the token columns). The `gpu` subcommand + `parseGpu` in `logic.js` (result cached as `gpuInfo` in `main.qml`, polled on stats ticks) runs `nvidia-smi --query-compute-apps` for per-pid VRAM attribution, `/proc/meminfo` + `/proc/stat` for RAM/CPU% and `/sys/.../topology/thread_siblings_list` + `nproc` for core/thread counts; `MainPage.qml`'s `hw` getter merges it with strata's metrics (`pick()`: system value first, strata fallback/complement for name/cores/threads/`hist`). `Donut.qml` (used inside `GaugeRing.qml`) and `Sparkline.qml` are the reusable Canvas widgets (animated `frac`/scales — never jump). GaugeRing needs an explicit `implicitHeight` next to its `ringSize`: inside a RowLayout an unset height makes `implicitWidth` collapse to the 8 px minimum. Repeaters are keyed by stable ids (`rowIds`/`tileIds`) so 1 s updates never recreate delegates. Cards respect the `statShow*` kcfg toggles.
- **Polling cadence**: status every 2 s expanded / 5 s collapsed; logs 500 ms; stats 1 s but only while the Stats tab is open.

## Key Directories

  - `contents/ui/` — QML: `main.qml` (plasmoid root), `MainPage.qml` (popup: Servers + Logs + Stats tabs, binary-availability indicators, log stat chips, Stats dashboard cards/tiles/rings), `GaugeRing.qml` (segmented ring, wraps `Donut.qml`) + `Donut.qml` + `Sparkline.qml` + `ReqTable.qml` (reusable components: the request grid measures its columns from the actual strings — `TextMetrics.advanceWidth` is a PROPERTY fed by `text`, and measurement must run from change handlers, not a binding, or QML reports a binding loop — then stretches all columns proportionally to the card width), `logic.js` (`.pragma library` of pure helpers: `shQuote`, `safeJsonParse`/`safeJsonStringify`, `homeExpand`, `slugify`, `buildCommand`, `serverBinary`, `filterLines`, `logStats`, `highlightLog`, `parseKv`, `parseStatusall`, `parseStats`/`parsePrometheus`/`llamaLogStats`/`healthTally`/`mergeReqs`/`parseGpu`/`ctxSegs`, …; no Qt.* calls beyond what libraries allow — format numbers/clocks by hand), `config/ConfigServers.qml` (KCM.SimpleKCM settings page; preset combobox via `presets`) + `config/ConfigLogs.qml` (log-view settings page) + `config/ConfigStats.qml` (Stats-tab toggles).
- `contents/scripts/cppserverctl.sh` — entire backend.
- `contents/config/` — `main.xml` (kcfg schema) + `config.qml` (dialog model with three categories, Servers + Logs + Stats; their `source: "config/…"` paths resolve to `contents/ui/config/…`).
- `po/` + `translate/` — gettext sources and tooling (domain `plasma_applet_org.kde.cppserver`).
- `contents/locale/` — **generated** compiled translations; regenerated by `translate/build.sh`, do not edit by hand.

## Development Commands

Run from repo root. No sudo, ever (scripts refuse root).

```bash
bash install.sh [--no-restart]        # user-level install: translation build + clean reinstall via kpackagetool6 + qmlcache wipe + plasmashell restart
bash uninstall.sh [--no-restart]      # removes applet; deliberately leaves running servers, logs, ~/.config/cppserver/ untouched
bash make-plasmoid.sh [out.plasmoid]  # zip-based packaging → org.kde.cppserver.plasmoid (requires zip; no plasmoidpackage)
plasmoidviewer -a .                   # dev: preview without install or restart
LANGUAGE=es plasmoidviewer -a .       # test translations
```

## i18n Pipeline

All user-visible QML text uses `i18n()`/`i18np()` (never concatenate fragments; `--add-comments=i18n` is used, so a `// i18n` comment marks extractable strings):

```bash
bash translate/merge.sh               # after changing user-visible strings: xgettext → po/template.pot, msgmerge all po/*.po
bash translate/new-language.sh <lang>  # scaffolds po/<lang>.po from the .pot (fails if it exists)
bash translate/build.sh               # msgfmt → contents/locale/... + rewrites metadata.json Name[lang]/Description[lang]
```

`merge.sh` and `build.sh` need gettext (`xgettext`, `msgmerge`, `msginit`, `msgfmt`) + `python3`; `build.sh` soft-skips (exit 0) when `msgfmt` is missing. Workflow: new language → `new-language.sh <lang>` → edit `po/<lang>.po` (Lokalize/Poedit) → `bash install.sh`.

## Code Conventions & Common Patterns

- **Never spawn a process from QML directly** — go through the `P5Support` queue (`run(cmd, handler)`) so calls serialize and watchdog-protected.
- **Script stdout is the API**: emit `key=value` lines only; parsers live in `logic.js` (`parseKv`, `parseStatusall`). New subcommands must be parseable there and handled in `main.qml`/`ConfigServers.qml`.
- **Shell injection**: always `shQuote` (from `logic.js`) for any value passed to the script; the script itself is called with an absolute path.
- **Config page saves are debounced** and also flushed on `Component.onDestruction` — keep that invariant when editing `ConfigServers.qml`.
- **JSON is never trusted**: parse via `Logic.safeJsonParse`; normalize via `Logic.normalizeServers` (unique-slug ids, port clamp 0–65535, `enabled !== false`).
- `metadata.json` localized keys (`Name[…]`/`Description[…]`) are **generated** — hand-edit only the base English `Name`/`Description`; `build.sh` rewrites the rest.
- `KPlugin.Version` in `metadata.json` is set by the release workflow from its `version` input (see below); bump it locally before triggering a release. `install.sh` verifies the installed version after install.

## Testing & QA

**No test suite and no lint configs exist** (no `tests/`, `meson.build`, `pyproject.toml`, qmllint config). The only workflow is `.github/workflows/release.yml` (release automation, not CI checks). Verification is manual:

- `plasmoidviewer -a .` for UI iteration (no restart); `bash install.sh` for real-environment checks.
- Shell backend can be exercised directly: `bash contents/scripts/cppserverctl.sh <subcommand> [args]` — output is `key=value`, so it's grep/diff-able.
- Translation sanity: `msgfmt --statistics po/<lang>.po` (printed by `merge.sh`); check for fuzzy/untranslated.
- `install.sh` prints installed version and warns if stale-file markers (e.g. `logFilter`) remain in the installed copy.

## Runtime/Tooling Preferences

- Plasma 6 environment (API min 6.0); tooling is `kpackagetool6`, `systemctl --user` (`plasma-plasmashell.service`) or `kquitapp6`/`kstart` for restarts.
- Packaging = plain `zip` of `metadata.json` + `contents/`; install target `~/.local/share/plasma/plasmoids/org.kde.cppserver`.
- No `plasmoidpackage`, no l10n-sqlite, no build system, no package manager.

## Important Files

- `metadata.json` — plasmoid identity/version/localization.
- `contents/ui/main.qml` — state, command queue, polling, actions.
- `contents/ui/logic.js` — shared pure helpers (keep it dependency-free).
- `contents/ui/config/ConfigServers.qml` — settings page + debounced `cfgwrite`; `contents/ui/config/ConfigLogs.qml` — log-view settings (font size, stat toggles); `contents/ui/config/ConfigStats.qml` — Stats-tab display toggles.
- `.github/workflows/release.yml` — manual release: `workflow_dispatch` with a `version` input → rewrites `KPlugin.Version` in `metadata.json`, runs `make-plasmoid.sh org.kde.cppserver-v<version>.plasmoid`, publishes it as GitHub Release `v<version>` (`softprops/action-gh-release`).
- `contents/config/main.xml` + `contents/config/config.qml` — kcfg schema and dialog wiring.
- `README.md` — build/run docs (keep in sync with scripts).
