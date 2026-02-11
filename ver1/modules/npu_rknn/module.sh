#!/usr/bin/env bash
# npu_rknn/module.sh - Placeholder (always skip unless explicitly enabled)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

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
    kv_write "$probe_file" "supports" "false"
    kv_write "$probe_file" "reason" "NPU RKNN module is a placeholder - not implemented in v1"
}

cmd_run()      { _parse_args "$@"; echo "npu_rknn: placeholder, nothing to run"; }
cmd_evaluate() { _parse_args "$@"; echo "npu_rknn: placeholder, nothing to evaluate"; }
cmd_cleanup()  { _parse_args "$@"; echo "npu_rknn: placeholder, nothing to cleanup"; }

case "${1:-}" in
    probe)    shift; cmd_probe "$@" ;;
    run)      shift; cmd_run "$@" ;;
    evaluate) shift; cmd_evaluate "$@" ;;
    cleanup)  shift; cmd_cleanup "$@" ;;
    *)        echo "Usage: $0 {probe|run|evaluate|cleanup} --out <dir> [--duration <s>] --cfg <kv>" >&2; exit 1 ;;
esac
