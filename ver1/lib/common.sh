#!/usr/bin/env bash
# common.sh - Shared utilities for syshammer

SYSHAMMER_VERSION="1.0.0"

# Globals set by orchestrator
: "${DEBUG:=0}"
: "${SYSROOT:=}"
: "${LOGREAD_CMD:=dmesg}"
: "${RUN_DIR:=}"

# --- Logging ---

_log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local msg="[$ts] [$level] $*"
    # Always write to core.log if RUN_DIR is set
    if [[ -n "$RUN_DIR" && -d "$RUN_DIR/meta" ]]; then
        printf '%s\n' "$msg" >> "$RUN_DIR/meta/core.log"
    fi
    # Console output based on level and debug flag
    case "$level" in
        DEBUG)
            [[ "$DEBUG" == "1" ]] && printf '%s\n' "$msg" >&2 || true
            ;;
        ERROR)
            printf '%s\n' "$msg" >&2
            ;;
        *)
            printf '%s\n' "$msg" >&2
            ;;
    esac
}

log_info()  { _log INFO  "$@"; }
log_debug() { _log DEBUG "$@"; }
log_error() { _log ERROR "$@"; }
log_warn()  { _log WARN  "$@"; }

# --- Key-Value File Operations ---

# Write key=value to file. If key exists, overwrite it; otherwise append.
kv_write() {
    local file="$1" key="$2" value="$3"
    if [[ ! -f "$file" ]]; then
        printf '%s=%s\n' "$key" "$value" > "$file"
        return
    fi
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        local tmp="${file}.tmp.$$"
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "${key}="* ]]; then
                printf '%s=%s\n' "$key" "$value"
            else
                printf '%s\n' "$line"
            fi
        done < "$file" > "$tmp"
        mv "$tmp" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

# Read value for key from kv file. Returns default if not found.
kv_read() {
    local file="$1" key="$2" default="${3:-}"
    if [[ -f "$file" ]]; then
        local line
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "${key}="* ]]; then
                printf '%s' "${line#"${key}="}"
                return 0
            fi
        done < "$file"
    fi
    printf '%s' "$default"
    return 0
}

# Read all key=value pairs from file into the named associative array.
# Usage: declare -A arr; kv_read_all file arr
kv_read_all() {
    local file="$1" arr_name="$2"
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == "#"* ]] && continue || true
        key="${line%%=*}"
        value="${line#*=}"
        eval "${arr_name}[\"$key\"]=\"\$value\""
    done < "$file"
}

# Append a failure event to fails.kv
# Usage: fail_event <fails_file> <code> <severity> <detail>
fail_event() {
    local file="$1" code="$2" sev="$3" detail="$4"
    local ts
    ts=$(date '+%s%3N' 2>/dev/null || date '+%s000')
    printf 'ts=%s code=%s sev=%s detail=%s\n' "$ts" "$code" "$sev" "$detail" >> "$file"
}

# --- Directory Helpers ---

ensure_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || mkdir -p "$dir"
}

# --- Execution Helpers ---

# Run command with timeout. Uses GNU timeout if available, else internal watchdog.
run_with_timeout() {
    local timeout_s="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_s" "$@"
    else
        # Internal watchdog using background process
        "$@" &
        local cmd_pid=$!
        (
            sleep "$timeout_s"
            kill -TERM "$cmd_pid" 2>/dev/null
            sleep 2
            kill -KILL "$cmd_pid" 2>/dev/null
        ) &
        local wdog_pid=$!
        wait "$cmd_pid" 2>/dev/null
        local rc=$?
        kill "$wdog_pid" 2>/dev/null
        wait "$wdog_pid" 2>/dev/null
        return $rc
    fi
}

# --- Hashing ---

# Portable hash: prefer sha256sum, fall back to md5sum
md5_or_sha() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v md5sum >/dev/null 2>&1; then
        md5sum "$file" | awk '{print $1}'
    else
        echo "nohash"
    fi
}
