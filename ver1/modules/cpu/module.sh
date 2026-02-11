#!/usr/bin/env bash
# cpu/module.sh - stress-ng cpu workers module
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

: "${SYSROOT:=}"
: "${DEBUG:=0}"

# Parse common arguments
_parse_args() {
    OUT_DIR=""
    DURATION=""
    CFG_FILE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out)      OUT_DIR="$2"; shift 2 ;;
            --duration) DURATION="$2"; shift 2 ;;
            --cfg)      CFG_FILE="$2"; shift 2 ;;
            *)          shift ;;
        esac
    done
}

cmd_probe() {
    _parse_args "$@"
    local probe_file="$OUT_DIR/probe.kv"
    : > "$probe_file"

    if command -v stress-ng >/dev/null 2>&1; then
        kv_write "$probe_file" "supports" "true"
        kv_write "$probe_file" "tool" "stress-ng"
        kv_write "$probe_file" "tool_version" "$(stress-ng --version 2>&1 | head -1)"
        kv_write "$probe_file" "nproc" "$(nproc 2>/dev/null || echo 1)"
    else
        kv_write "$probe_file" "supports" "false"
        kv_write "$probe_file" "reason" "stress-ng not found"
    fi
}

cmd_run() {
    _parse_args "$@"
    local workers
    workers=$(kv_read "$CFG_FILE" "module.cpu.workers" "$(nproc 2>/dev/null || echo 1)")
    local method
    method=$(kv_read "$CFG_FILE" "module.cpu.method" "cpu")

    local cmd=(stress-ng --"$method" "$workers" --timeout "${DURATION}s" --metrics-brief)
    if [[ "$DEBUG" == "1" ]]; then cmd+=(--verbose); fi

    echo "CMD: ${cmd[*]}"
    "${cmd[@]}" 2>&1

    # Record PIDs (stress-ng manages its own, but record for cleanup)
    kv_write "$OUT_DIR/pids.kv" "stress_ng" "$$"
}

cmd_evaluate() {
    _parse_args "$@"
    local result_file="$OUT_DIR/result.kv"
    local fails_file="$OUT_DIR/fails.kv"
    : > "$fails_file"

    # Read config thresholds
    local temp_warn_c temp_fail_c
    temp_warn_c=$(kv_read "$CFG_FILE" "module.cpu.temp_warn_c" "80")
    temp_fail_c=$(kv_read "$CFG_FILE" "module.cpu.temp_fail_c" "95")

    # Check thermal
    local tz_file="${SYSROOT}/sys/class/thermal/thermal_zone0/temp"
    if [[ -f "$tz_file" ]]; then
        local raw_temp temp_c
        raw_temp=$(cat "$tz_file" 2>/dev/null || echo "0")
        temp_c=$((raw_temp / 1000))
        kv_write "$result_file" "temp_c" "$temp_c"

        if [[ $temp_c -ge $temp_fail_c ]]; then
            fail_event "$fails_file" "THERMAL_FAIL" "fail" "CPU temp ${temp_c}C >= ${temp_fail_c}C threshold"
        elif [[ $temp_c -ge $temp_warn_c ]]; then
            fail_event "$fails_file" "THERMAL_WARN" "warn" "CPU temp ${temp_c}C >= ${temp_warn_c}C threshold"
        fi
    fi

    # Check for throttling via cpufreq
    local freq_file="${SYSROOT}/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
    local max_freq_file="${SYSROOT}/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"
    if [[ -f "$freq_file" && -f "$max_freq_file" ]]; then
        local cur_freq max_freq
        cur_freq=$(cat "$freq_file" 2>/dev/null || echo "0")
        max_freq=$(cat "$max_freq_file" 2>/dev/null || echo "0")
        if [[ $max_freq -gt 0 && $cur_freq -gt 0 ]]; then
            local ratio=$((cur_freq * 100 / max_freq))
            if [[ $ratio -lt 80 ]]; then
                fail_event "$fails_file" "THROTTLE_DETECTED" "warn" "CPU freq at ${ratio}% of max (${cur_freq}/${max_freq} kHz)"
            fi
        fi
    fi

    # Scan dmesg/logs for kernel oops/lockups
    local log_output
    log_output=$($LOGREAD_CMD 2>/dev/null | tail -100 || true)
    if echo "$log_output" | grep -qi "oops\|panic\|lockup\|rcu.*stall"; then
        fail_event "$fails_file" "KERNEL_OOPS" "fail" "Kernel oops/panic/lockup detected in logs"
    fi

    # Check stress-ng exit in stdout
    if [[ -f "$OUT_DIR/stdout.log" ]]; then
        if grep -qi "error\|fail" "$OUT_DIR/stdout.log" 2>/dev/null; then
            fail_event "$fails_file" "TOOL_ERROR" "warn" "stress-ng reported errors in output"
        fi
    fi

    # Write duration and weight to result
    kv_write "$result_file" "duration_s" "${DURATION:-0}"
    local weight
    weight=$(kv_read "$CFG_FILE" "module.cpu.weight" "1")
    kv_write "$result_file" "weight" "$weight"
}

cmd_cleanup() {
    _parse_args "$@"
    echo "cpu cleanup: no persistent state"
    # Kill any recorded PIDs
    if [[ -f "$OUT_DIR/pids.kv" ]]; then
        while IFS='=' read -r _k pid; do
            kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null || true
        done < "$OUT_DIR/pids.kv"
    fi
}

# Dispatch
case "${1:-}" in
    probe)    shift; cmd_probe "$@" ;;
    run)      shift; cmd_run "$@" ;;
    evaluate) shift; cmd_evaluate "$@" ;;
    cleanup)  shift; cmd_cleanup "$@" ;;
    *)        echo "Usage: $0 {probe|run|evaluate|cleanup} --out <dir> [--duration <s>] --cfg <kv>" >&2; exit 1 ;;
esac
