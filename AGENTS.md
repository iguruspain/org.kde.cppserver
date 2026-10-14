# Repository Guidelines

## Project Overview

`cpp servers` is a KDE Plasma 6 plasmoid (package id `org.kde.cppserver`, v1.7.5, MIT) that configures, starts/stops, and live-tails local C++ inference servers (llama.cpp, audio.cpp, stable-diffusion.cpp, or any custom command). Pure QML + one bash backend script — **no C++ in this repo** despite the name. Form factors: desktop, mediacenter, handset, plus system tray (`X-Plasma-NotificationArea`).

## Architecture & Data Flow

- **QML entry**: `contents/ui/main.qml` — `PlasmoidItem` with all state, the serialized command queue, and polling timers.
- **Backend**: `contents/scripts/cppserverctl.sh` — single bash script, subcommands `init | cfgread | cfgwrite | start | stop | rename | statusall | logread | deps`. Protocol: stdout is `key=value` lines; errors are `error=<code>` + nonzero exit. Servers run in `setsid` sessions and survive plasmashell restarts. Liveness is derived from `<id>.pid` files (pid + start time, so recycled PIDs are not mistaken for live servers). `rename <old> <new>` migrates `<old>.{log,pid}` to `<new>.{log,pid}`; a running server keeps running (no restart). `deps <binary>...` reports `OK|MISSING` per binary — the UI uses it to flag servers whose executable is not on PATH.
- **UI ↔ script**: no ScriptEngine, no owned processes. All shell traffic goes through `P5Support.DataSource { engine: "executable" }` (import `org.kde.plasma.plasma5support`), which is **single-flight**: `run(cmd, handler)` enqueues; `pump()` fires one at a time; a 20 s watchdog timer unblocks stuck jobs. Duplicate in-flight commands (status/log polls) are dropped. Script is always invoked as `bash <shQuotedAbsolutePath> <subcmd> ...`; absolute path comes from `Qt.resolvedUrl("../scripts/cppserverctl.sh")` in `logic.js`.
- **Config — two distinct systems, do not conflate**:
  1. KConfig (`contents/config/main.xml`): per-widget-instance state in the `General` group — `uiJson` (String, default `{}`, UI state `{activeTab, activeLogId}`) plus log-view settings `logFontAuto` (Bool, default `true`, when on the log follows `Kirigami.Theme.smallFont.pointSize`), `logFontSize` (Int, explicit point-size override used only when `logFontAuto` is off; SpinBox min is 1 so no magic `0`) and `logShowErrors`/`logShowWarnings`/`logShowOom`/`logShowTps` (Bool, default `true`). All applied live; read via `Plasmoid.configuration.*`. The effective size is computed in `main.qml` as the `logFontPointSize` property and consumed in `MainPage.qml` via `page.backend.logFontPointSize`.
  2. Shared server list: `~/.config/cppserver/servers.json` — JSON array of `{ id, name, command, host, port, configFile, enabled }`. Deliberately **not** in KConfig: shared across all widget instances and editable outside Plasma. Written atomically (mktemp + `mv`) with 450 ms debounce (`ConfigServers.qml`), hot-reloaded by the widget: every `statusall` reply carries `cfgmtime=`; on change the widget re-runs `cfgread`.
- **Data flow**: `ConfigServers.qml` edits a `ListModel` → debounced `cfgwrite` → `servers.json` on disk → widget `statusall` → mtime change → `cfgread` → refreshed `ListView`. Command templates use `{HOST}` / `{PORT}` / `{CONFIG_FILE}` placeholders (port `0` drops the port flag; `~`/`$HOME` expanded). The `id` (Log ID field) is stable by default but explicitly editable: on change the value is slugified, checked for uniqueness, then `rename <old> <new>` migrates the log/pid files — a running server is not restarted.
- **Logs**: `$XDG_CACHE_HOME/cppserver/logs/<id>.log`, tailed 500 ms while the Logs tab is open (last 400 lines); UI supports substring/regex filter, pause, follow, and stat chips (error / warning / OOM counts, max t/s) toggleable via the Logs config page. Stats are computed from the visible log text in `logic.js` (`logStats`); t/s is only printed by llama.cpp. Counted lines are highlighted in the log view (`highlightLog`, same classification as `logStats`): OOM/error lines in `Kirigami.Theme.negativeTextColor`, warnings in `Kirigami.Theme.neutralTextColor`; the log `TextArea` switches to `TextEdit.RichText` with an HTML span per matched line (lines joined with `<br>`), plain text for placeholders.
- **Polling cadence**: status every 2 s expanded / 5 s collapsed; logs 500 ms.

## Key Directories

  - `contents/ui/` — QML: `main.qml` (plasmoid root), `MainPage.qml` (popup: Servers + Logs tabs, binary-availability indicators, log stat chips), `logic.js` (`.pragma library` of pure helpers: `shQuote`, `safeJsonParse`/`safeJsonStringify`, `homeExpand`, `slugify`, `buildCommand`, `serverBinary`, `filterLines`, `logStats`, `highlightLog`, `parseKv`, `parseStatusall`, …), `config/ConfigServers.qml` (KCM.SimpleKCM settings page) + `config/ConfigLogs.qml` (log-view settings page).
- `contents/scripts/cppserverctl.sh` — entire backend.
- `contents/config/` — `main.xml` (kcfg schema) + `config.qml` (dialog model with two categories, Servers + Logs; their `source: "config/…"` paths resolve to `contents/ui/config/…`).
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
- `contents/ui/config/ConfigServers.qml` — settings page + debounced `cfgwrite`; `contents/ui/config/ConfigLogs.qml` — log-view settings (font size, stat toggles).
- `.github/workflows/release.yml` — manual release: `workflow_dispatch` with a `version` input → rewrites `KPlugin.Version` in `metadata.json`, runs `make-plasmoid.sh org.kde.cppserver-v<version>.plasmoid`, publishes it as GitHub Release `v<version>` (`softprops/action-gh-release`).
- `contents/config/main.xml` + `contents/config/config.qml` — kcfg schema and dialog wiring.
- `README.md` — build/run docs (keep in sync with scripts).
