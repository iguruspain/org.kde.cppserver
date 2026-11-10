#!/usr/bin/env bash
# Helper for the org.kde.cppserver plasmoid.
#
# Subcommands (all print key=value lines):
#   init                      home=, config=, logroot=
#   cfgread                   print the servers.json content ([] when missing)
#   cfgwrite <json>           atomically replace servers.json
#   start <id> <command>      launch detached  -> pid= logfile=   (or error=)
#   stop <id>                 SIGTERM the process group, SIGKILL after 5 s;
#                             external-<slug> -> strata launch --stop instead
#   rename <old> <new>        migrate <old>.{log,pid} to <new>.{log,pid}; a
#                             running server keeps running (no restart)
#   statusall <id>...         cfgmtime=N, then "<id> alive=1 pid= logfile=" / "<id> alive=0";
#                             live strata engines no pidfile claims are also
#                             emitted as "external-<slug> alive=1 ..." (+ extport-=)
#   logread <path> [lines]    tail a log inside the log root (path-validated)
#   deps <binary>...          <binary>=OK|MISSING
#   probe <url>               GET a local http(s) endpoint, print the raw
#                             body (stats tab); error=unreachable|bad_url|
#                             curl_missing|empty_body
#   presets                   strata launch presets -> presets=<json>
#                             (or error=strata_missing|presets_failed)
#   gpu                       host counters: proc=<pid>:<mib> (per-process
#                             VRAM via nvidia-smi), vramowner=<id>=<mib> (each
#                             holder walked up to its owning session — pidfile,
#                             or external strata engine via its ready.json pid),
#                             gpuused/gputotal/gpuutil/gputemp/gpupow,
#                             ramused/ramtotal, cpu
#
# Config : ${XDG_CONFIG_HOME:-~/.config}/cppserver/servers.json
# Runtime: ${XDG_CACHE_HOME:-~/.cache}/cppserver/logs/<id>.{log,pid}
#          <id>.strata holds the preset NAME of a `strata launch --preset`
#          server: the launcher exits while its engine keeps serving, so the
#          pidfile is re-pointed at the engine found in strata's runtime state,
#          and the Logs tab tails strata's own <slug>.engine.log. An engine
#          started OUTSIDE the widget has no pidfile/marker and is reported
#          as external-<slug> under its own id — never adopted into a card.
set -uo pipefail

cmd="${1:-}"
shift || true

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cppserver"
CONFIG_FILE="$CONFIG_DIR/servers.json"
LOG_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/cppserver/logs"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}"
# Resolve bare binary names (llama-server, ...) like a login shell would:
export PATH="$HOME/.local/bin:$PATH"

ensure_log_root() {
    if mkdir -p "$LOG_ROOT" 2>/dev/null; then
        return
    fi
    LOG_ROOT="/tmp/cppserver-logs-${UID}"
    mkdir -p "$LOG_ROOT"
}

# Must match slugify() in logic.js (ids are already slugs; this is a safety net).
slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g'
}

# ── strata launch ───────────────────────────────────────────────────────────
# `strata launch --preset NAME --no-tui` is a short-lived launcher: it exits
# once the engine answers, leaving the engine detached. To keep tracking the
# real engine, start() records the raw preset name in "<id>.strata" when the
# command looks like that, and statusall re-points the pidfile at the engine.

# Raw preset name used by the command (single- or double-quoted or bare),
# "" when it does not use one. strata's own slug is slug(name).
strata_preset_of() {
    local name
    name="$(printf '%s' "$1" | sed -nE 's/.*--preset[[:space:]]+"([^"]*)".*/\1/p')"
    if [[ -z "$name" ]]; then
        name="$(printf '%s' "$1" | sed -nE "s/.*--preset[[:space:]]+'([^']*)'.*/\1/p")"
    fi
    if [[ -z "$name" ]]; then
        name="$(printf '%s' "$1" | sed -nE 's/.*--preset[[:space:]]+([^"'"'"'[:space:]][^[:space:]]*).*/\1/p')"
    fi
    if [[ -n "$name" ]]; then printf '%s\n' "$name"; fi
}

# Every live strata engine in strata's runtime state, one "pid<TAB>slug<TAB>port"
# line each (port empty when the ready file has none) — shared by the statusall
# external scan and the gpu VRAM attribution (an engine launched outside the
# widget has no pidfile, so its ready.json pid is the anchor to walk up from).
strata_external_engines() {
    local f ep eslug eport
    for f in "$STATE_DIR"/strata/runtime/launch-*-*.ready.json; do
        [[ -r "$f" ]] || continue
        ep="$(grep -oE '"pid"[[:space:]]*:[[:space:]]*[0-9]+' "$f" | grep -oE '[0-9]+' | head -n 1)"
        [[ -n "$ep" && -d "/proc/$ep" ]] || continue
        tr '\0' ' ' < "/proc/$ep/cmdline" 2>/dev/null | grep -qi strata || continue
        eslug="$(basename "$f" .ready.json)"
        eslug="${eslug#launch-}"
        eslug="${eslug%-*}"          # drop the trailing -<hash>
        [[ -n "$eslug" ]] || continue
        eport="$(grep -oE '"bound_port"[[:space:]]*:[[:space:]]*[0-9]+' "$f" | grep -oE '[0-9]+' | head -n 1)"
        printf '%s\t%s\t%s\n' "$ep" "$eslug" "$eport"
    done
}

# Live engine pid strata recorded for the launch profile, "" when none.
strata_engine_pid() {
    local slug="$1" f pid
    if [[ -z "$slug" ]]; then return; fi
    for f in "$STATE_DIR"/strata/runtime/launch-"$slug"-*.ready.json; do
        [[ -r "$f" ]] || continue
        pid="$(grep -oE '"pid"[[:space:]]*:[[:space:]]*[0-9]+' "$f" | grep -oE '[0-9]+' | head -n 1)"
        if [[ -n "$pid" && -d "/proc/$pid" ]] &&
           tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qi strata; then
            echo "$pid"
            return
        fi
    done
}

# ── Config file ─────────────────────────────────────────────────────────────
init() {
    ensure_log_root
    echo "home=$HOME"
    echo "config=$CONFIG_FILE"
    echo "logroot=$LOG_ROOT"
}

cfgread() {
    if [[ -r "$CONFIG_FILE" ]]; then
        cat "$CONFIG_FILE"
    else
        echo "[]"
    fi
}

cfgwrite() {
    local json="${1:-}"
    if [[ -z "$json" ]]; then
        echo "error=missing_json"
        exit 2
    fi
    if ! mkdir -p "$CONFIG_DIR" 2>/dev/null; then
        echo "error=cannot_create_config_dir"
        exit 3
    fi
    local tmp
    tmp="$(mktemp "$CONFIG_DIR/.servers.XXXXXX")" || { echo "error=mktemp_failed"; exit 3; }
    if printf '%s\n' "$json" > "$tmp" && mv -f "$tmp" "$CONFIG_FILE"; then
        echo "ok=1"
    else
        rm -f "$tmp"
        echo "error=write_failed"
        exit 3
    fi
}

cfgmtime() {
    stat -c %Y "$CONFIG_FILE" 2>/dev/null || echo 0
}

# ── Process helpers ─────────────────────────────────────────────────────────
# Field 22 of /proc/PID/stat (start time) – guards against recycled PIDs.
proc_start() {
    local stat rest
    stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    rest="${stat##*) }"
    set -- $rest
    echo "${20:-}"
}

# Print the live pid for a pidfile ("pid starttime"), or "" if dead/stale.
read_pid() {
    local pidfile="$1" pid="" st="" cur=""
    if [[ -r "$pidfile" ]]; then
        read -r pid st < "$pidfile" 2>/dev/null || true
    fi
    if [[ -n "$pid" && -d "/proc/$pid" ]]; then
        cur="$(proc_start "$pid")"
        if [[ -z "$st" || "$cur" == "$st" ]]; then
            echo "$pid"
            return
        fi
    fi
    [[ -f "$pidfile" ]] && rm -f "$pidfile" 2>/dev/null
    echo ""
}

start() {
    local id command
    id="$(slug "${1:-}")"
    command="${2:-}"
    if [[ -z "$id" || -z "$command" ]]; then
        echo "error=missing_args"
        exit 2
    fi
    if [[ "$id" == external-* ]]; then
        echo "error=external_server"   # external engines are adopted, never (re)started
        exit 2
    fi
    ensure_log_root
    local logfile="$LOG_ROOT/$id.log" pidfile="$LOG_ROOT/$id.pid" marker="$LOG_ROOT/$id.strata"
    local preset_name=""
    if [[ "$command" == *"strata launch"* && "$command" == *"--preset"* ]]; then
        preset_name="$(strata_preset_of "$command")"
    fi

    if [[ -n "$(read_pid "$pidfile")" ]] ||
       { [[ -n "$preset_name" ]] && [[ -n "$(strata_engine_pid "$(slug "$preset_name")")" ]]; }; then
        echo "error=already_running"
        exit 4
    fi
    : > "$logfile"   # fresh log per start (the Logs tab shows the current session)

    # setsid: the server gets its own session/process group, so it survives a
    # plasmashell restart and can be stopped as a group. Backgrounded from a
    # non-interactive shell, setsid execs in place, so $! is the session leader.
    if command -v setsid >/dev/null 2>&1; then
        setsid bash -c "$command" >> "$logfile" 2>&1 < /dev/null &
    else
        bash -c "$command" >> "$logfile" 2>&1 < /dev/null &
    fi
    local pid=$!
    disown "$pid" 2>/dev/null || true

    sleep 0.4   # give the process a moment to fail fast (e.g. binary missing)
    if [[ ! -d "/proc/$pid" ]]; then
        echo "error=start_failed"
        echo "logfile=$logfile"
        echo "logerror=$(tail -n 3 "$logfile" | tr '\n' ' ')"
        exit 3
    fi

    printf '%s %s\n' "$pid" "$(proc_start "$pid")" > "$pidfile"
    if [[ -n "$preset_name" ]]; then
        printf '%s\n' "$preset_name" > "$marker"
    else
        rm -f "$marker" 2>/dev/null
    fi
    echo "pid=$pid"
    echo "logfile=$logfile"
}

stop() {
    local id
    id="$(slug "${1:-}")"
    if [[ -z "$id" ]]; then
        echo "error=missing_id"
        exit 2
    fi
    ensure_log_root
    local pidfile="$LOG_ROOT/$id.pid" marker="$LOG_ROOT/$id.strata" pid eslug
    # external engine (external-<slug>): no pidfile/marker exists — ask strata
    # to stop the profile gracefully, hard-kill only what survives.
    if [[ "$id" == external-* ]]; then
        eslug="${id#external-}"
        if command -v strata >/dev/null 2>&1; then
            timeout 12 strata launch --stop --preset "$eslug" >/dev/null 2>&1 || true
        fi
        pid="$(strata_engine_pid "$eslug")"
        if [[ -n "$pid" ]]; then
            kill -TERM "$pid" 2>/dev/null || true
            local _
            for _ in $(seq 1 50); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
            kill -KILL "$pid" 2>/dev/null || true
        fi
        echo "ok=1"
        return
    fi
    # strata launch engine: ask strata itself to stop the profile first
    # (cap it: strata waits for a graceful drain); the pid kill below is the
    # fallback for anything left.
    if [[ -r "$marker" ]] && command -v strata >/dev/null 2>&1; then
        eslug="$(head -n 1 "$marker" 2>/dev/null)"
        if [[ -n "$eslug" ]]; then
            timeout 12 strata launch --stop --preset "$eslug" >/dev/null 2>&1 || true
        fi
    fi
    pid="$(read_pid "$pidfile")"
    if [[ -n "$pid" ]]; then
        local children=""
        # Whole process group first (server + any wrapper stages); if the pid is
        # not a group leader fall back to children + pid.
        if ! kill -TERM -- "-$pid" 2>/dev/null; then
            children="$(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ' || true)"
            local c
            for c in $children; do kill -TERM "$c" 2>/dev/null || true; done
            kill -TERM "$pid" 2>/dev/null || true
        fi
        local _
        for _ in $(seq 1 50); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL -- "-$pid" 2>/dev/null || true
            local c
            for c in $children; do kill -KILL "$c" 2>/dev/null || true; done
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    rm -f "$pidfile" 2>/dev/null
    rm -f "$marker" 2>/dev/null
    echo "ok=1"
}

rename() {
    local old new
    old="$(slug "${1:-}")"
    new="$(slug "${2:-}")"
    if [[ -z "$old" || -z "$new" || "$old" == "$new" ]]; then
        echo "error=missing_args"
        exit 2
    fi
    if [[ "$old" == external-* || "$new" == external-* ]]; then
        echo "error=external_server"   # external entries are not real servers
        exit 2
    fi
    ensure_log_root
    local old_pidfile="$LOG_ROOT/$old.pid" new_pidfile="$LOG_ROOT/$new.pid"
    local old_logfile="$LOG_ROOT/$old.log" new_logfile="$LOG_ROOT/$new.log"
    local old_marker="$LOG_ROOT/$old.strata" new_marker="$LOG_ROOT/$new.strata"
    # Never clobber an existing <new>.* (a different server may own that id).
    if [[ -e "$new_pidfile" || -e "$new_logfile" || -e "$new_marker" ]]; then
        echo "error=id_taken"
        exit 6
    fi
    # A running server is unaffected: its stdout fd follows the inode across
    # the mv, and the pidfile is just a record, so it keeps running under the
    # new id without a restart.
    [[ -f "$old_pidfile" ]] && mv -f "$old_pidfile" "$new_pidfile"
    [[ -f "$old_logfile" ]] && mv -f "$old_logfile" "$new_logfile"
    [[ -f "$old_marker" ]] && mv -f "$old_marker" "$new_marker"
    echo "ok=1"
}

statusall() {
    if [[ $# -eq 0 ]]; then
        echo "cfgmtime=$(cfgmtime)"
        return
    fi
    ensure_log_root
    echo "cfgmtime=$(cfgmtime)"
    local name id pid ename eslug epid logpath eeng claimed=""
    for name in "$@"; do
        id="$(slug "$name")"
        pid="$(read_pid "$LOG_ROOT/$id.pid")"
        [[ -n "$pid" ]] && claimed="$claimed $pid"
        ename=""
        if [[ -r "$LOG_ROOT/$id.strata" ]]; then
            ename="$(head -n 1 "$LOG_ROOT/$id.strata" 2>/dev/null)"
        fi
        if [[ -z "$pid" && -n "$ename" ]]; then
            # strata launch server: the launcher exits while the engine keeps
            # serving. Re-point the pidfile at the engine strata recorded.
            eslug="$(slug "$ename")"
            epid="$(strata_engine_pid "$eslug")"
            if [[ -z "$epid" ]]; then
                epid="$(strata_engine_pid "$ename")"   # legacy: marker held a slug
            fi
            if [[ -n "$epid" ]]; then
                printf '%s %s\n' "$epid" "$(proc_start "$epid")" > "$LOG_ROOT/$id.pid"
                pid="$epid"
                claimed="$claimed $pid"   # adopted: must not also surface as external
            fi
        fi
        logpath="$LOG_ROOT/$id.log"
        if [[ -n "$ename" ]]; then
            # strata writes the engine's own output; tail it when present.
            eeng="$STATE_DIR"/strata/launch/"$(slug "$ename")".engine.log
            if [[ ! -r "$eeng" ]]; then eeng="$STATE_DIR"/strata/launch/"$ename".engine.log; fi
            [[ -r "$eeng" ]] && logpath="$eeng"
        fi
        if [[ -n "$pid" ]]; then
            printf '%s alive=1 pid=%s logfile=%s\n' "$id" "$pid" "$logpath"
        else
            printf '%s alive=0\n' "$id"
        fi
    done
    # ── strata engines launched OUTSIDE the widget (terminal, other session) ──
    # every live engine in strata's runtime state that no configured server
    # claims surfaces as "external-<slug>": its stats/logs appear under their
    # own id, and the plasmoid-managed pidfiles/markers stay untouched.
    local ep eport
    while IFS=$'\t' read -r ep eslug eport; do
        [[ " $claimed " == *" $ep "* ]] && continue
        eeng="$STATE_DIR"/strata/launch/"$eslug".engine.log
        [[ -r "$eeng" ]] || eeng=""
        printf 'external-%s alive=1 pid=%s%s\n' "$eslug" "$ep" "${eeng:+ logfile=$eeng}"
        [[ -n "$eport" ]] && printf 'extport-%s=%s\n' "$eslug" "$eport"
    done < <(strata_external_engines)
}

logread() {
    local path="${1:-}" lines="${2:-400}"
    if [[ -z "$path" ]]; then
        echo "error=missing_log_path"
        exit 2
    fi
    if [[ "$lines" != "markers" ]] && ! [[ "$lines" =~ ^[0-9]+$ ]]; then
        echo "error=invalid_lines"
        exit 2
    fi
    ensure_log_root
    local real_root real_path real_launch
    real_root="$(realpath "$LOG_ROOT")"
    real_path="$(realpath "$path" 2>/dev/null || true)"
    real_launch="$(realpath "$STATE_DIR/strata/launch" 2>/dev/null || true)"
    local in_logs=0 in_engine=0
    [[ -n "$real_path" && "${real_path#"$real_root"/}" != "$real_path" ]] && in_logs=1
    [[ -n "$real_path" && -n "$real_launch" && "${real_path#"$real_launch"/}" != "$real_path"
       && "$real_path" == *.engine.log ]] && in_engine=1
    if [[ $in_logs -eq 0 && $in_engine -eq 0 ]]; then
        echo "error=invalid_log_path"
        exit 2
    fi
    if [[ ! -r "$real_path" ]]; then
        echo "error=log_not_readable"
        exit 2
    fi
    if [[ "$lines" == "markers" ]]; then
        # llama.cpp model-load markers, whole file: the load lines age out
        # of every tail window, but the last match says which model the
        # server loaded. No match is not an error: empty output, exit 0.
        grep -a -E "loading model( from)? '" "$real_path" 2>/dev/null || true
        exit 0
    fi
    tail -n "$lines" "$real_path"
}

deps() {
    local b
    for b in "$@"; do
        if command -v "$b" >/dev/null 2>&1; then
            echo "$b=OK"
        else
            echo "$b=MISSING"
        fi
    done
}

# Read-only HTTP GET used by the Stats tab (strata /health|/metrics,
# llama-server /metrics...). Only the fetched body goes to stdout; every
# failure is a single error= line with a nonzero exit, so the caller can
# tell body and failure apart. curl has no default timeout: cap both.
probe() {
    local url="${1:-}"
    if [[ -z "$url" ]]; then
        echo "error=missing_url"
        exit 2
    fi
    if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
        echo "error=bad_url"
        exit 2
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "error=curl_missing"
        exit 3
    fi
    local body rc
    body="$(curl -s -m 3 --connect-timeout 1 "$url" 2>/dev/null)"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "error=unreachable"
        exit 4
    fi
    if [[ -z "$body" ]]; then
        echo "error=empty_body"
        exit 4
    fi
    printf '%s\n' "$body"
}

# List strata's launch presets for the settings page ({PRESET} combobox).
# The whole JSON answer rides on one key=value line; the UI parses it.
presets() {
    if ! command -v strata >/dev/null 2>&1; then
        echo "error=strata_missing"
        exit 3
    fi
    local out rc
    out="$(timeout 10 strata launch --list-presets --output json 2>/dev/null)"
    rc=$?
    if [[ $rc -ne 0 || -z "$out" ]]; then
        echo "error=presets_failed"
        exit 4
    fi
    printf 'presets=%s\n' "$out"
}

# gpu: host + per-process counters for the live dashboard.
# nvidia-smi supplies GPU totals and per-process VRAM (the pid from the
# pidfile attributes each segment of the VRAM ring to its server); RAM
# and CPU% come from /proc so the rings work without any NVIDIA driver.
gpu() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        # Attribute each VRAM-holding pid to the server session that owns
        # it: nvidia-smi reports the process that allocated the memory,
        # often a descendant (strata's engine, a wrapper) of the setsid
        # session recorded in <id>.pid. Walk each app pid up the parent
        # chain until it hits a live pidfile (read_pid: pid + start time,
        # recycled pids never match) and emit vramowner=<id>=<MiB>.
        declare -A vram_pid_owner=()
        local sp
        for pf in "$LOG_ROOT"/*.pid; do
            sp="$(read_pid "$pf")"
            [[ -n "$sp" ]] && vram_pid_owner["$sp"]="${pf##*/}"
        done
        # External strata engines never own a pidfile — anchor their VRAM
        # workers on the ready.json engine pid instead, keyed as the widget's
        # external id. Pidfile entries are inserted first and never overwritten:
        # a configured server always keeps the attribution of an engine it claims.
        local eep eslug _eport
        while IFS=$'\t' read -r eep eslug _eport; do
            [[ -n "${vram_pid_owner[$eep]:-}" ]] || vram_pid_owner["$eep"]="external-$eslug"
        done < <(strata_external_engines)
        nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null |
        while IFS=, read -r p m; do
            p="${p// /}"; m="${m// /}"
            [[ "$p" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ ]] || continue
            printf 'proc=%s:%s\n' "$p" "$m"
            local cur="$p" id="" _hop
            for _hop in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
                id="${vram_pid_owner[$cur]:-}"
                [[ -n "$id" ]] && { printf 'vramowner=%s=%s\n' "${id%.pid}" "$m"; break; }
                [[ -r "/proc/$cur/stat" ]] || break
                # PPID = 2nd field after the "(comm) " prefix (comm has spaces)
                cur=$(awk -F') ' '{split($2, a, " "); print a[2]}' "/proc/$cur/stat" 2>/dev/null)
                [[ "$cur" =~ ^[0-9]+$ && "$cur" -gt 1 ]] || break
            done
        done
        gn=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        [[ -n "$gn" ]] && echo "gpuname=$gn"
        nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw,power.limit \
                   --format=csv,noheader,nounits 2>/dev/null | head -1 |
        awk -F, '{gsub(/ /, "")
                 if ($1+0 > 0)      print "gpuused=" $1+0
                 if ($2+0 > 0)      print "gputotal=" $2+0
                 if ($3 ~ /^[0-9]+(\.[0-9]+)?$/)  print "gpuutil=" $3
                 if ($4 ~ /^[0-9]+(\.[0-9]+)?$/)  print "gputemp=" $4
                 if ($5 ~ /^[0-9]+(\.[0-9]+)?$/)  print "gpupow=" $5
                 if ($6 ~ /^[0-9]+(\.[0-9]+)?$/)  print "gpulimit=" $6}'
    fi
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
         END{if (t) {print "ramtotal=" int(t/1024); print "ramused=" int((t-a)/1024)}}' /proc/meminfo
    cn=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)
    [[ -n "$cn" ]] && echo "cpuname=$cn"
    # static CPU geometry so the CPU ring readout works even without strata:
    # one entry per physical core in thread_siblings_list (identical across a
    # core's SMT siblings); fall back to nproc when topology is absent
    local thr cor
    thr=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
    cor=$(cat /sys/devices/system/cpu/cpu*/topology/thread_siblings_list 2>/dev/null | sort -u | wc -l)
    [[ "$cor" =~ ^[0-9]+$ && "$cor" -gt 0 ]] || cor="$thr"
    [[ "$thr" =~ ^[0-9]+$ && "$thr" -gt 0 ]] && echo "threads=$thr"
    [[ "$cor" =~ ^[0-9]+$ && "$cor" -gt 0 ]] && echo "cores=$cor"
    c() { awk '/^cpu /{n=0; for(i=2;i<=NF;i++)n+=$i; print n" "$5}' /proc/stat; }
    # $6/$10 in diskstats are sectors read/written (512 B); skip loop/ram disks
    d() { awk '$3 !~ /^(loop|ram|zram)/ {r+=$6; w+=$10} END{print r+0" "w+0}' /proc/diskstats; }
    local t1 i1 t2 i2 r1 w1 r2 w2
    read -r r1 w1 <<<"$(d)"
    read -r t1 i1 <<<"$(c)"
    sleep 0.15
    read -r t2 i2 <<<"$(c)"
    read -r r2 w2 <<<"$(d)"
    if (( t2 > t1 )); then
        echo "cpu=$(( 100 * (t2 - t1 - (i2 - i1)) / (t2 - t1) ))"
    fi
    awk -v dr="$(( r2 - r1 ))" -v dw="$(( w2 - w1 ))" \
        'BEGIN{printf "diskread=%.1f\ndiskwrite=%.1f\n", dr*512/1000000/0.15, dw*512/1000000/0.15}'
}

case "$cmd" in
    init)      init ;;
    cfgread)   cfgread ;;
    cfgwrite)  cfgwrite "$@" ;;
    start)     start "$@" ;;
    stop)      stop "$@" ;;
    rename)    rename "$@" ;;
    statusall) statusall "$@" ;;
    logread)   logread "$@" ;;
    deps)      deps "$@" ;;
    probe)     probe "$@" ;;
    presets)   presets "$@" ;;
    gpu)       gpu ;;
    *)
        echo "error=unknown_command"
        exit 1
        ;;
esac
