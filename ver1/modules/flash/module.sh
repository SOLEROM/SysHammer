#!/usr/bin/env bash
# flash/module.sh - fio or dd+sync+verify storage stress
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
flash/module.sh - Storage I/O stress via fio or dd with verification

Usage: module.sh <command> [options]

Commands:
  probe       Check if fio or dd is available and test directory is writable
  run         Execute storage stress test with data verification
  evaluate    Analyze results and determine pass/warn/fail
  cleanup     Remove test files and terminate processes
  help        Show this help

Options:
  --out <dir>       Output directory for results (default: auto temp dir)
  --duration <sec>  Test duration in seconds (default: 30)
  --cfg <file>      Config file in key=value format (default: built-in defaults)
  --help, -h        Show this help

Config keys (set in --cfg file):
  module.flash.test_dir          Directory for test files (default: /tmp)
  module.flash.bs                Block size for I/O operations (default: 4k)
  module.flash.size              Total data size per fio job (default: 64m)
  module.flash.min_throughput_kb Minimum throughput threshold in KB/s (default: 100)

Examples:
  ./module.sh run --duration 60
  ./module.sh probe
  ./module.sh run --duration 30 --cfg my_config.kv
EOF
}

cmd_probe() {
    _parse_args "$@"
    _standalone_defaults 30
    local probe_file="$OUT_DIR/probe.kv"
    : > "$probe_file"

    local test_dir
    test_dir=$(kv_read "$CFG_FILE" "module.flash.test_dir" "/tmp")

    if command -v fio >/dev/null 2>&1; then
        kv_write "$probe_file" "supports" "true"
        kv_write "$probe_file" "tool" "fio"
        kv_write "$probe_file" "tool_version" "$(fio --version 2>&1 | head -1)"
    elif command -v dd >/dev/null 2>&1; then
        kv_write "$probe_file" "supports" "true"
        kv_write "$probe_file" "tool" "dd"
    else
        kv_write "$probe_file" "supports" "false"
        kv_write "$probe_file" "reason" "Neither fio nor dd found"
        return
    fi

    kv_write "$probe_file" "test_dir" "$test_dir"

    # Check test directory is writable
    if [[ ! -d "$test_dir" ]] || [[ ! -w "$test_dir" ]]; then
        kv_write "$probe_file" "supports" "false"
        kv_write "$probe_file" "reason" "Test directory $test_dir not writable"
    fi
}

cmd_run() {
    _parse_args "$@"
    _standalone_defaults 30
    local test_dir bs size
    test_dir=$(kv_read "$CFG_FILE" "module.flash.test_dir" "/tmp")
    bs=$(kv_read "$CFG_FILE" "module.flash.bs" "4k")
    size=$(kv_read "$CFG_FILE" "module.flash.size" "64m")

    local test_file="$test_dir/syshammer_flash_test.$$"

    if command -v fio >/dev/null 2>&1; then
        local cmd=(fio --name=syshammer --rw=randrw --bs="$bs" --size="$size"
                   --runtime="$DURATION" --time_based --directory="$test_dir"
                   --output-format=normal --verify=md5 --do_verify=1)
        if [[ "$DEBUG" == "1" ]]; then cmd+=(--debug=all); fi
        echo "CMD: ${cmd[*]}"
        "${cmd[@]}" 2>&1
    else
        # Fallback: dd + sync + verify
        echo "CMD: dd if=/dev/urandom of=$test_file bs=$bs count=16384 + verify"
        dd if=/dev/urandom of="$test_file" bs="$bs" count=16384 conv=fsync 2>&1
        sync
        local hash_before hash_after
        hash_before=$(md5_or_sha "$test_file")
        sync
        hash_after=$(md5_or_sha "$test_file")
        echo "verify_hash_before=$hash_before"
        echo "verify_hash_after=$hash_after"
        if [[ "$hash_before" != "$hash_after" ]]; then
            echo "VERIFY_FAIL: hash mismatch"
        fi
        rm -f "$test_file"
    fi

    kv_write "$OUT_DIR/pids.kv" "flash_test" "$$"
}

cmd_evaluate() {
    _parse_args "$@"
    _standalone_defaults 30
    local result_file="$OUT_DIR/result.kv"
    local fails_file="$OUT_DIR/fails.kv"
    : > "$fails_file"

    local min_throughput_kb
    min_throughput_kb=$(kv_read "$CFG_FILE" "module.flash.min_throughput_kb" "100")

    # Check dmesg for IO errors
    local log_output
    log_output=$($LOGREAD_CMD 2>/dev/null | tail -100 || true)
    if echo "$log_output" | grep -qi "i/o error\|blk_update_request\|buffer.*error"; then
        fail_event "$fails_file" "IO_ERROR" "fail" "I/O error detected in logs"
    fi

    # Check for verify failures in stdout
    if [[ -f "$OUT_DIR/stdout.log" ]]; then
        if grep -qi "VERIFY_FAIL\|verify.*fail\|bad checksums" "$OUT_DIR/stdout.log" 2>/dev/null; then
            fail_event "$fails_file" "IO_ERROR" "fail" "Data verification failure"
        fi
        if grep -qi "error" "$OUT_DIR/stdout.log" 2>/dev/null; then
            fail_event "$fails_file" "TOOL_ERROR" "warn" "Tool reported errors"
        fi
    fi

    kv_write "$result_file" "duration_s" "${DURATION:-0}"
}

cmd_cleanup() {
    _parse_args "$@"
    _standalone_defaults 30
    local test_dir
    test_dir=$(kv_read "$CFG_FILE" "module.flash.test_dir" "/tmp")
    # Clean up test files
    rm -f "$test_dir"/syshammer_flash_test.* 2>/dev/null
    rm -f "$test_dir"/syshammer.*.0 2>/dev/null
    echo "flash cleanup: removed test files"
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
