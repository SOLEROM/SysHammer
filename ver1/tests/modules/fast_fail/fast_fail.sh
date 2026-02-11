#!/usr/bin/env bash
# Fake module: always fails quickly
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../../lib/common.sh"

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

case "${1:-}" in
    probe)
        shift; _parse_args "$@"
        kv_write "$OUT_DIR/probe.kv" "supports" "true"
        kv_write "$OUT_DIR/probe.kv" "tool" "fake"
        ;;
    run)
        shift; _parse_args "$@"
        echo "fast_fail: running"
        sleep 0.1
        echo "fast_fail: simulated error occurred"
        ;;
    evaluate)
        shift; _parse_args "$@"
        fail_event "$OUT_DIR/fails.kv" "IO_ERROR" "fail" "Simulated hard failure"
        fail_event "$OUT_DIR/fails.kv" "THERMAL_WARN" "warn" "Simulated warning"
        kv_write "$OUT_DIR/result.kv" "duration_s" "${DURATION:-0}"
        ;;
    cleanup)
        shift; _parse_args "$@"
        echo "fast_fail: cleanup done"
        ;;
    *) echo "Usage: $0 {probe|run|evaluate|cleanup}" >&2; exit 1 ;;
esac
