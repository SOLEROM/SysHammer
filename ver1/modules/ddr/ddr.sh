#!/usr/bin/env bash
# ddr/ddr.sh - stress-ng memory/stream workloads
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
            --help|-h)  cmd_help; exit 0 ;;
            *)          shift ;;
        esac
    done
}

cmd_help() {
    cat <<'EOF'
ddr/ddr.sh - DDR memory bandwidth stress via stress-ng stream/memcpy

Usage: ddr.sh <command> [options]

Commands:
  probe       Check if stress-ng is available
  run         Execute DDR bandwidth stress test
  evaluate    Analyze results and determine pass/warn/fail
  cleanup     Terminate any leftover processes
  help        Show this help

Options:
  --out <dir>       Output directory for results (default: auto temp dir)
  --duration <sec>  Test duration in seconds (default: 30)
  --cfg <file>      Config file in key=value format (default: built-in defaults)
  --help, -h        Show this help

Config keys (set in --cfg file):
  module.ddr.workers    Number of stress workers, 0 = nproc (default: nproc)
  module.ddr.method     Stressor method: stream or memcpy (default: stream)

Examples:
  ./ddr.sh run --duration 60
  ./ddr.sh probe
  ./ddr.sh run --duration 30 --cfg my_config.kv
EOF
}

cmd_probe() {
    _parse_args "$@"
    _standalone_defaults 30
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
    _standalone_defaults 30
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
    _standalone_defaults 30
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
}

cmd_cleanup() {
    _parse_args "$@"
    _standalone_defaults 30
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
    help|--help|-h) cmd_help ;;
    *)        cmd_help; exit 1 ;;
esac
