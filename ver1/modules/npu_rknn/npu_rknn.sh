#!/usr/bin/env bash
# npu_rknn/npu_rknn.sh - Placeholder (always skip unless explicitly enabled)
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
            --help|-h)  cmd_help; exit 0 ;;
            *)          shift ;;
        esac
    done
}

cmd_help() {
    cat <<'EOF'
npu_rknn/npu_rknn.sh - Rockchip NPU RKNN stress testing (placeholder)

This module is a placeholder and is not implemented in v1.
It always reports as unsupported during probe.

Usage: npu_rknn.sh <command> [options]

Commands:
  probe       Always reports unsupported
  run         No-op
  evaluate    No-op
  cleanup     No-op
  help        Show this help

Options:
  --out <dir>       Output directory for results (default: auto temp dir)
  --duration <sec>  Test duration in seconds (default: 30)
  --cfg <file>      Config file in key=value format (default: built-in defaults)
  --help, -h        Show this help
EOF
}

cmd_probe() {
    _parse_args "$@"
    _standalone_defaults 30
    local probe_file="$OUT_DIR/probe.kv"
    : > "$probe_file"
    kv_write "$probe_file" "supports" "false"
    kv_write "$probe_file" "reason" "NPU RKNN module is a placeholder - not implemented in v1"
}

cmd_run()      { _parse_args "$@"; _standalone_defaults 30; echo "npu_rknn: placeholder, nothing to run"; }
cmd_evaluate() { _parse_args "$@"; _standalone_defaults 30; echo "npu_rknn: placeholder, nothing to evaluate"; }
cmd_cleanup()  { _parse_args "$@"; _standalone_defaults 30; echo "npu_rknn: placeholder, nothing to cleanup"; }

case "${1:-}" in
    probe)    shift; cmd_probe "$@" ;;
    run)      shift; cmd_run "$@" ;;
    evaluate) shift; cmd_evaluate "$@" ;;
    cleanup)  shift; cmd_cleanup "$@" ;;
    help|--help|-h) cmd_help ;;
    *)        cmd_help; exit 1 ;;
esac
