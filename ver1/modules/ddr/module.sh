#!/usr/bin/env bash
# ddr/module.sh - stress-ng memory/stream workloads
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

: "${SYSROOT:=}"
: "${DEBUG:=0}"

_parse_args() {
    OUT_DIR=""; DURATION=""; CFG_FILE=""
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
        kv_write "$probe_file" "method" "stream/memcpy"
    else
        kv_write "$probe_file" "supports" "false"
        kv_write "$probe_file" "reason" "stress-ng not found"
    fi
}

cmd_run() {
    _parse_args "$@"
    local workers method
    workers=$(kv_read "$CFG_FILE" "module.ddr.workers" "$(nproc 2>/dev/null || echo 1)")
    method=$(kv_read "$CFG_FILE" "module.ddr.method" "stream")

    local cmd=(stress-ng --"$method" "$workers" --timeout "${DURATION}s" --metrics-brief)
    if [[ "$DEBUG" == "1" ]]; then cmd+=(--verbose); fi

    echo "CMD: ${cmd[*]}"
    "${cmd[@]}" 2>&1

    kv_write "$OUT_DIR/pids.kv" "stress_ng" "$$"
}

cmd_evaluate() {
    _parse_args "$@"
    local result_file="$OUT_DIR/result.kv"
    local fails_file="$OUT_DIR/fails.kv"
    : > "$fails_file"

    # Scan logs for memory errors
    local log_output
    log_output=$($LOGREAD_CMD 2>/dev/null | tail -100 || true)
    if echo "$log_output" | grep -qi "memory.*error\|ecc\|mce\|hardware.*error"; then
        fail_event "$fails_file" "IO_ERROR" "fail" "Memory/hardware error detected in logs"
    fi
    if echo "$log_output" | grep -qi "oops\|panic"; then
        fail_event "$fails_file" "KERNEL_OOPS" "fail" "Kernel oops/panic detected in logs"
    fi
    if echo "$log_output" | grep -qi "oom.*kill\|out of memory"; then
        fail_event "$fails_file" "OOM_KILL" "fail" "OOM kill detected"
    fi

    if [[ -f "$OUT_DIR/stdout.log" ]]; then
        if grep -qi "error\|fail" "$OUT_DIR/stdout.log" 2>/dev/null; then
            fail_event "$fails_file" "TOOL_ERROR" "warn" "stress-ng reported errors"
        fi
    fi

    kv_write "$result_file" "duration_s" "${DURATION:-0}"
    local weight
    weight=$(kv_read "$CFG_FILE" "module.ddr.weight" "1")
    kv_write "$result_file" "weight" "$weight"
}

cmd_cleanup() {
    _parse_args "$@"
    echo "ddr cleanup: no persistent state"
    if [[ -f "$OUT_DIR/pids.kv" ]]; then
        while IFS='=' read -r _k pid; do
            kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null || true
        done < "$OUT_DIR/pids.kv"
    fi
}

case "${1:-}" in
    probe)    shift; cmd_probe "$@" ;;
    run)      shift; cmd_run "$@" ;;
    evaluate) shift; cmd_evaluate "$@" ;;
    cleanup)  shift; cmd_cleanup "$@" ;;
    *)        echo "Usage: $0 {probe|run|evaluate|cleanup} --out <dir> [--duration <s>] --cfg <kv>" >&2; exit 1 ;;
esac
