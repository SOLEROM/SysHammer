#!/usr/bin/env bash
# bus_i2c/module.sh - i2cget/i2cset transactions or skip
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

    local bus addr
    bus=$(kv_read "$CFG_FILE" "module.bus_i2c.bus" "")
    addr=$(kv_read "$CFG_FILE" "module.bus_i2c.addr" "")

    if [[ -z "$bus" || -z "$addr" ]]; then
        kv_write "$probe_file" "supports" "false"
        kv_write "$probe_file" "reason" "No I2C bus/addr configured (module.bus_i2c.bus, module.bus_i2c.addr)"
        return
    fi

    if ! command -v i2cget >/dev/null 2>&1; then
        kv_write "$probe_file" "supports" "false"
        kv_write "$probe_file" "reason" "i2cget not found"
        return
    fi

    kv_write "$probe_file" "supports" "true"
    kv_write "$probe_file" "bus" "$bus"
    kv_write "$probe_file" "addr" "$addr"
}

cmd_run() {
    _parse_args "$@"
    local bus addr reg iterations
    bus=$(kv_read "$CFG_FILE" "module.bus_i2c.bus" "0")
    addr=$(kv_read "$CFG_FILE" "module.bus_i2c.addr" "0x50")
    reg=$(kv_read "$CFG_FILE" "module.bus_i2c.reg" "0x00")
    iterations=$(kv_read "$CFG_FILE" "module.bus_i2c.iterations" "100")

    echo "--- I2C Transaction Test ---"
    local i=0
    local errors=0
    while [[ $i -lt $iterations ]]; do
        echo "CMD: i2cget -y $bus $addr $reg"
        if ! i2cget -y "$bus" "$addr" "$reg" 2>&1; then
            errors=$((errors + 1))
        fi
        i=$((i + 1))
    done
    echo "Completed $iterations transactions, errors=$errors"

    kv_write "$OUT_DIR/pids.kv" "bus_i2c" "$$"
}

cmd_evaluate() {
    _parse_args "$@"
    local result_file="$OUT_DIR/result.kv"
    local fails_file="$OUT_DIR/fails.kv"
    : > "$fails_file"

    if [[ -f "$OUT_DIR/stdout.log" ]]; then
        local error_count
        error_count=$(grep -vi "errors=0" "$OUT_DIR/stdout.log" 2>/dev/null | grep -ci "error\|fail\|timeout" 2>/dev/null) || error_count=0
        if [[ $error_count -gt 0 ]]; then
            fail_event "$fails_file" "BUS_XFER_FAIL" "warn" "I2C transaction errors: $error_count"
        fi
    fi

    local log_output
    log_output=$($LOGREAD_CMD 2>/dev/null | tail -100 || true)
    if echo "$log_output" | grep -qi "i2c.*error\|i2c.*timeout"; then
        fail_event "$fails_file" "BUS_XFER_FAIL" "fail" "I2C errors in kernel logs"
    fi

    kv_write "$result_file" "duration_s" "${DURATION:-0}"
    local weight
    weight=$(kv_read "$CFG_FILE" "module.bus_i2c.weight" "1")
    kv_write "$result_file" "weight" "$weight"
}

cmd_cleanup() {
    _parse_args "$@"
    echo "bus_i2c cleanup: no persistent state"
}

case "${1:-}" in
    probe)    shift; cmd_probe "$@" ;;
    run)      shift; cmd_run "$@" ;;
    evaluate) shift; cmd_evaluate "$@" ;;
    cleanup)  shift; cmd_cleanup "$@" ;;
    *)        echo "Usage: $0 {probe|run|evaluate|cleanup} --out <dir> [--duration <s>] --cfg <kv>" >&2; exit 1 ;;
esac
