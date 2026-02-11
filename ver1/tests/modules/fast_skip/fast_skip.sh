#!/usr/bin/env bash
# Fake module: always skips (probe returns supports=false)
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
        kv_write "$OUT_DIR/probe.kv" "supports" "false"
        kv_write "$OUT_DIR/probe.kv" "reason" "Not supported in test env"
        ;;
    run)      shift; echo "fast_skip: should not run" ;;
    evaluate) shift; echo "fast_skip: should not evaluate" ;;
    cleanup)  shift; _parse_args "$@"; echo "fast_skip: cleanup" ;;
    *) echo "Usage: $0 {probe|run|evaluate|cleanup}" >&2; exit 1 ;;
esac
