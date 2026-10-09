#!/usr/bin/env bash
# Helper for the org.kde.cppserver plasmoid.
#
# Subcommands (all print key=value lines):
#   init                      home=, config=, logroot=
#   cfgread                   print the servers.json content ([] when missing)
#   cfgwrite <json>           atomically replace servers.json
#   start <id> <command>      launch detached  -> pid= logfile=   (or error=)
#   stop <id>                 SIGTERM the process group, SIGKILL after 5 s
#   statusall <id>...         cfgmtime=N, then "<id> alive=1 pid= logfile=" / "<id> alive=0"
#   logread <path> [lines]    tail a log inside the log root (path-validated)
#   deps <binary>...          <binary>=OK|MISSING
#
# Config : ${XDG_CONFIG_HOME:-~/.config}/cppserver/servers.json
# Runtime: ${XDG_CACHE_HOME:-~/.cache}/cppserver/logs/<id>.{log,pid}
set -uo pipefail

cmd="${1:-}"
shift || true

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cppserver"
CONFIG_FILE="$CONFIG_DIR/servers.json"
LOG_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/cppserver/logs"
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
    ensure_log_root
    local logfile="$LOG_ROOT/$id.log" pidfile="$LOG_ROOT/$id.pid"

    if [[ -n "$(read_pid "$pidfile")" ]]; then
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
    local pidfile="$LOG_ROOT/$id.pid" pid
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
    echo "ok=1"
}

statusall() {
    if [[ $# -eq 0 ]]; then
        echo "cfgmtime=$(cfgmtime)"
        return
    fi
    ensure_log_root
    echo "cfgmtime=$(cfgmtime)"
    local name id pid
    for name in "$@"; do
        id="$(slug "$name")"
        pid="$(read_pid "$LOG_ROOT/$id.pid")"
        if [[ -n "$pid" ]]; then
            printf '%s alive=1 pid=%s logfile=%s\n' "$id" "$pid" "$LOG_ROOT/$id.log"
        else
            printf '%s alive=0\n' "$id"
        fi
    done
}

logread() {
    local path="${1:-}" lines="${2:-400}"
    if [[ -z "$path" ]]; then
        echo "error=missing_log_path"
        exit 2
    fi
    if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
        echo "error=invalid_lines"
        exit 2
    fi
    ensure_log_root
    local real_root real_path
    real_root="$(realpath "$LOG_ROOT")"
    real_path="$(realpath "$path" 2>/dev/null || true)"
    if [[ -z "$real_path" || "${real_path#"$real_root"/}" == "$real_path" ]]; then
        echo "error=invalid_log_path"
        exit 2
    fi
    if [[ ! -r "$real_path" ]]; then
        echo "error=log_not_readable"
        exit 2
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

case "$cmd" in
    init)      init ;;
    cfgread)   cfgread ;;
    cfgwrite)  cfgwrite "$@" ;;
    start)     start "$@" ;;
    stop)      stop "$@" ;;
    statusall) statusall "$@" ;;
    logread)   logread "$@" ;;
    deps)      deps "$@" ;;
    *)
        echo "error=unknown_command"
        exit 1
        ;;
esac
