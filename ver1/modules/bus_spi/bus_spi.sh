#!/usr/bin/env bash
# bus_spi/bus_spi.sh - spidev loopback or skip
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
bus_spi/bus_spi.sh - SPI loopback transaction testing via spidev_test

Usage: bus_spi.sh <command> [options]

Commands:
  probe       Check if SPI device is configured and spidev_test exists
  run         Execute SPI loopback transactions
  evaluate    Analyze transfer results for errors
  cleanup     No persistent state to clean
  help        Show this help

Options:
  --out <dir>       Output directory for results (default: auto temp dir)
  --duration <sec>  Test duration in seconds (default: 30)
  --cfg <file>      Config file in key=value format (default: built-in defaults)
  --help, -h        Show this help

Config keys (set in --cfg file):
  module.bus_spi.device       SPI device path, required (default: "")
  module.bus_spi.speed        SPI clock speed in Hz (default: 1000000)
  module.bus_spi.iterations   Number of transfer iterations (default: 100)

Examples:
  ./bus_spi.sh probe --cfg my_config.kv
  ./bus_spi.sh run --duration 10 --cfg my_config.kv
EOF
}

cmd_probe() {
    _parse_args "$@"
    _standalone_defaults 30
    local probe_file="$OUT_DIR/probe.kv"
    : > "$probe_file"

    local device
    device=$(kv_read "$CFG_FILE" "module.bus_spi.device" "")

    if [[ -z "$device" ]]; then
        kv_write "$probe_file" "supports" "false"
        kv_write "$probe_file" "reason" "No SPI device configured (module.bus_spi.device)"
        return
    fi

    if ! command -v spidev_test >/dev/null 2>&1; then
        kv_write "$probe_file" "supports" "false"
        kv_write "$probe_file" "reason" "spidev_test not found"
        return
    fi

    if [[ ! -c "$device" && ! -e "$device" ]]; then
        kv_write "$probe_file" "supports" "false"
        kv_write "$probe_file" "reason" "Device $device not found"
        return
    fi

    kv_write "$probe_file" "supports" "true"
    kv_write "$probe_file" "device" "$device"
}

cmd_run() {
    _parse_args "$@"
    _standalone_defaults 30
    local device speed iterations
    device=$(kv_read "$CFG_FILE" "module.bus_spi.device" "/dev/spidev0.0")
    speed=$(kv_read "$CFG_FILE" "module.bus_spi.speed" "1000000")
    iterations=$(kv_read "$CFG_FILE" "module.bus_spi.iterations" "100")

    echo "--- SPI Loopback Test ---"
    local i=0
    while [[ $i -lt $iterations ]]; do
        echo "CMD: spidev_test -D $device -s $speed -p \\x55\\xAA"
        spidev_test -D "$device" -s "$speed" -p '\x55\xAA' 2>&1 || true
        i=$((i + 1))
    done

    kv_write "$OUT_DIR/pids.kv" "bus_spi" "$$"
}

cmd_evaluate() {
    _parse_args "$@"
    _standalone_defaults 30
    local result_file="$OUT_DIR/result.kv"
    local fails_file="$OUT_DIR/fails.kv"
    : > "$fails_file"

    if [[ -f "$OUT_DIR/stdout.log" ]]; then
        local error_count
        error_count=$(grep -ci "error\|fail\|timeout" "$OUT_DIR/stdout.log" 2>/dev/null) || error_count=0
        if [[ $error_count -gt 0 ]]; then
            fail_event "$fails_file" "BUS_XFER_FAIL" "warn" "SPI transfer errors: $error_count"
        fi
    fi

    local log_output
    log_output=$($LOGREAD_CMD 2>/dev/null | tail -100 || true)
    if echo "$log_output" | grep -qi "spi.*error\|spi.*timeout"; then
        fail_event "$fails_file" "BUS_XFER_FAIL" "fail" "SPI errors in kernel logs"
    fi

    kv_write "$result_file" "duration_s" "${DURATION:-0}"
}

cmd_cleanup() {
    _parse_args "$@"
    _standalone_defaults 30
    echo "bus_spi cleanup: no persistent state"
}

case "${1:-}" in
    probe)    shift; cmd_probe "$@" ;;
    run)      shift; cmd_run "$@" ;;
    evaluate) shift; cmd_evaluate "$@" ;;
    cleanup)  shift; cmd_cleanup "$@" ;;
    help|--help|-h) cmd_help ;;
    *)        cmd_help; exit 1 ;;
esac
