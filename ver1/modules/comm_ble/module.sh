#!/usr/bin/env bash
# comm_ble/module.sh - hcitool/bluetoothctl probe, scan stress
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

    local has_hcitool has_bluetoothctl
    has_hcitool=$(command -v hcitool >/dev/null 2>&1 && echo true || echo false)
    has_bluetoothctl=$(command -v bluetoothctl >/dev/null 2>&1 && echo true || echo false)

    if [[ "$has_hcitool" == "false" && "$has_bluetoothctl" == "false" ]]; then
        kv_write "$probe_file" "supports" "false"
        kv_write "$probe_file" "reason" "Neither hcitool nor bluetoothctl found"
        return
    fi

    kv_write "$probe_file" "supports" "true"
    kv_write "$probe_file" "has_hcitool" "$has_hcitool"
    kv_write "$probe_file" "has_bluetoothctl" "$has_bluetoothctl"

    # Check BT adapter
    if [[ "$has_hcitool" == "true" ]]; then
        local dev_info
        dev_info=$(hcitool dev 2>/dev/null || true)
        kv_write "$probe_file" "devices" "$dev_info"
        if ! echo "$dev_info" | grep -q "hci"; then
            kv_write "$probe_file" "supports" "false"
            kv_write "$probe_file" "reason" "No BLE adapter detected"
        fi
    fi
}

cmd_run() {
    _parse_args "$@"
    local scan_cycles
    scan_cycles=$(kv_read "$CFG_FILE" "module.comm_ble.scan_cycles" "5")

    echo "--- BLE Scan Stress ---"
    local i=0
    while [[ $i -lt $scan_cycles ]]; do
        if command -v hcitool >/dev/null 2>&1; then
            echo "Scan cycle $((i+1))/$scan_cycles"
            echo "CMD: hcitool lescan --duplicates"
            timeout 5 hcitool lescan --duplicates 2>&1 || true
        elif command -v bluetoothctl >/dev/null 2>&1; then
            echo "Scan cycle $((i+1))/$scan_cycles"
            echo "CMD: bluetoothctl scan on"
            timeout 5 bash -c 'echo "scan on" | bluetoothctl' 2>&1 || true
        fi
        i=$((i + 1))
    done

    kv_write "$OUT_DIR/pids.kv" "comm_ble" "$$"
}

cmd_evaluate() {
    _parse_args "$@"
    local result_file="$OUT_DIR/result.kv"
    local fails_file="$OUT_DIR/fails.kv"
    : > "$fails_file"

    # Check for BLE errors in logs
    local log_output
    log_output=$($LOGREAD_CMD 2>/dev/null | tail -100 || true)
    if echo "$log_output" | grep -qi "bluetooth.*error\|hci.*reset\|bt.*firmware"; then
        fail_event "$fails_file" "DEVICE_RESET" "warn" "BLE controller error/reset in logs"
    fi

    # Check stdout for scan errors
    if [[ -f "$OUT_DIR/stdout.log" ]]; then
        if grep -qi "error\|device not available\|connection refused" "$OUT_DIR/stdout.log" 2>/dev/null; then
            fail_event "$fails_file" "BUS_XFER_FAIL" "warn" "BLE scan errors in output"
        fi
    fi

    kv_write "$result_file" "duration_s" "${DURATION:-0}"
}

cmd_cleanup() {
    _parse_args "$@"
    echo "comm_ble cleanup: no persistent state"
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
