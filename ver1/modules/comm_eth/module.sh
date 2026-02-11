#!/usr/bin/env bash
# comm_eth/module.sh - ping/iperf3, link stats, error counters
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

    local iface target
    iface=$(kv_read "$CFG_FILE" "module.comm_eth.iface" "eth0")
    target=$(kv_read "$CFG_FILE" "module.comm_eth.target" "")

    # Check interface exists
    local iface_dir="${SYSROOT}/sys/class/net/${iface}"
    if [[ ! -d "$iface_dir" ]]; then
        kv_write "$probe_file" "supports" "false"
        kv_write "$probe_file" "reason" "Interface $iface not found"
        return
    fi

    if ! command -v ping >/dev/null 2>&1; then
        kv_write "$probe_file" "supports" "false"
        kv_write "$probe_file" "reason" "ping not found"
        return
    fi

    kv_write "$probe_file" "supports" "true"
    kv_write "$probe_file" "iface" "$iface"
    kv_write "$probe_file" "target" "$target"
    kv_write "$probe_file" "has_iperf3" "$(command -v iperf3 >/dev/null 2>&1 && echo true || echo false)"
    kv_write "$probe_file" "has_ethtool" "$(command -v ethtool >/dev/null 2>&1 && echo true || echo false)"

    # Record initial error counters
    local stats_dir="${SYSROOT}/sys/class/net/${iface}/statistics"
    if [[ -d "$stats_dir" ]]; then
        for stat in tx_errors rx_errors tx_dropped rx_dropped; do
            if [[ -f "$stats_dir/$stat" ]]; then kv_write "$probe_file" "pre_${stat}" "$(cat "$stats_dir/$stat" 2>/dev/null || echo 0)"; fi
        done
    fi
}

cmd_run() {
    _parse_args "$@"
    local iface target iperf_server
    iface=$(kv_read "$CFG_FILE" "module.comm_eth.iface" "eth0")
    target=$(kv_read "$CFG_FILE" "module.comm_eth.target" "8.8.8.8")
    iperf_server=$(kv_read "$CFG_FILE" "module.comm_eth.iperf_server" "")

    # Ping test
    local ping_count=$((DURATION * 2))
    if [[ $ping_count -lt 5 ]]; then ping_count=5; fi
    echo "--- Ping Test ---"
    echo "CMD: ping -c $ping_count -W 2 -I $iface $target"
    ping -c "$ping_count" -W 2 -I "$iface" "$target" 2>&1 || true

    # Iperf3 test if server configured and tool available
    if [[ -n "$iperf_server" ]] && command -v iperf3 >/dev/null 2>&1; then
        echo "--- Iperf3 Test ---"
        local cmd=(iperf3 -c "$iperf_server" -t "$DURATION" -J)
        echo "CMD: ${cmd[*]}"
        "${cmd[@]}" 2>&1 || true
    fi

    # Link status check
    if command -v ip >/dev/null 2>&1; then
        echo "--- Link Status ---"
        ip link show "$iface" 2>&1 || true
    fi

    kv_write "$OUT_DIR/pids.kv" "comm_eth" "$$"
}

cmd_evaluate() {
    _parse_args "$@"
    local result_file="$OUT_DIR/result.kv"
    local fails_file="$OUT_DIR/fails.kv"
    : > "$fails_file"

    local iface max_loss_pct
    iface=$(kv_read "$CFG_FILE" "module.comm_eth.iface" "eth0")
    max_loss_pct=$(kv_read "$CFG_FILE" "module.comm_eth.max_loss_pct" "5")

    # Parse ping results from stdout
    if [[ -f "$OUT_DIR/stdout.log" ]]; then
        local loss_line
        loss_line=$(grep "packet loss" "$OUT_DIR/stdout.log" 2>/dev/null | tail -1 || true)
        if [[ -n "$loss_line" ]]; then
            local loss_pct
            loss_pct=$(echo "$loss_line" | grep -oP '\d+(?=% packet loss)' 2>/dev/null || echo "0")
            kv_write "$result_file" "packet_loss_pct" "$loss_pct"
            if [[ "${loss_pct:-0}" -gt "$max_loss_pct" ]]; then
                fail_event "$fails_file" "PACKET_LOSS_HIGH" "warn" "Packet loss ${loss_pct}% exceeds ${max_loss_pct}% threshold"
            fi
            if [[ "${loss_pct:-0}" -ge 100 ]]; then
                fail_event "$fails_file" "LINK_DOWN_PERSIST" "fail" "100% packet loss - link down"
            fi
        fi
    fi

    # Check error counter deltas
    local stats_dir="${SYSROOT}/sys/class/net/${iface}/statistics"
    local probe_file="$OUT_DIR/probe.kv"
    if [[ -d "$stats_dir" && -f "$probe_file" ]]; then
        for stat in tx_errors rx_errors; do
            local pre_val post_val delta
            pre_val=$(kv_read "$probe_file" "pre_${stat}" "0")
            post_val=$(cat "$stats_dir/$stat" 2>/dev/null || echo "0")
            delta=$((post_val - pre_val))
            kv_write "$result_file" "${stat}_delta" "$delta"
            if [[ $delta -gt 0 ]]; then
                fail_event "$fails_file" "IO_ERROR" "warn" "Interface $iface: $stat increased by $delta"
            fi
        done
    fi

    # Check logs for driver resets
    local log_output
    log_output=$($LOGREAD_CMD 2>/dev/null | tail -100 || true)
    if echo "$log_output" | grep -qi "link.*down\|carrier.*lost"; then
        fail_event "$fails_file" "LINK_DOWN_PERSIST" "fail" "Link down event in logs"
    fi
    if echo "$log_output" | grep -qi "reset\|watchdog"; then
        fail_event "$fails_file" "DEVICE_RESET" "warn" "Device reset detected in logs"
    fi

    kv_write "$result_file" "duration_s" "${DURATION:-0}"
    local weight
    weight=$(kv_read "$CFG_FILE" "module.comm_eth.weight" "1")
    kv_write "$result_file" "weight" "$weight"
}

cmd_cleanup() {
    _parse_args "$@"
    echo "comm_eth cleanup: no persistent state"
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
