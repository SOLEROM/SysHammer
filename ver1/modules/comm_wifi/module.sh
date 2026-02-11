#!/usr/bin/env bash
# comm_wifi/module.sh - ping/iperf3, RSSI, reconnect checks
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
    iface=$(kv_read "$CFG_FILE" "module.comm_wifi.iface" "wlan0")
    target=$(kv_read "$CFG_FILE" "module.comm_wifi.target" "")

    # Check interface
    local iface_dir="${SYSROOT}/sys/class/net/${iface}"
    if [[ ! -d "$iface_dir" ]]; then
        kv_write "$probe_file" "supports" "false"
        kv_write "$probe_file" "reason" "Interface $iface not found"
        return
    fi

    # Need either iw or iwconfig
    if ! command -v iw >/dev/null 2>&1 && ! command -v iwconfig >/dev/null 2>&1; then
        kv_write "$probe_file" "supports" "false"
        kv_write "$probe_file" "reason" "Neither iw nor iwconfig found"
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
    kv_write "$probe_file" "has_iw" "$(command -v iw >/dev/null 2>&1 && echo true || echo false)"
    kv_write "$probe_file" "has_iperf3" "$(command -v iperf3 >/dev/null 2>&1 && echo true || echo false)"

    # Get initial RSSI
    if command -v iw >/dev/null 2>&1; then
        local rssi
        rssi=$(iw dev "$iface" link 2>/dev/null | grep -oP '(?<=signal: )-?\d+' || true)
        if [[ -n "$rssi" ]]; then kv_write "$probe_file" "initial_rssi" "$rssi"; fi
    fi
}

cmd_run() {
    _parse_args "$@"
    local iface target iperf_server
    iface=$(kv_read "$CFG_FILE" "module.comm_wifi.iface" "wlan0")
    target=$(kv_read "$CFG_FILE" "module.comm_wifi.target" "8.8.8.8")
    iperf_server=$(kv_read "$CFG_FILE" "module.comm_wifi.iperf_server" "")

    # Ping test
    local ping_count=$((DURATION * 2))
    if [[ $ping_count -lt 5 ]]; then ping_count=5; fi
    echo "--- Ping Test ---"
    echo "CMD: ping -c $ping_count -W 2 -I $iface $target"
    ping -c "$ping_count" -W 2 -I "$iface" "$target" 2>&1 || true

    # RSSI checks during run
    if command -v iw >/dev/null 2>&1; then
        echo "--- RSSI Check ---"
        iw dev "$iface" link 2>&1 || true
    fi

    # Iperf3 if available
    if [[ -n "$iperf_server" ]] && command -v iperf3 >/dev/null 2>&1; then
        echo "--- Iperf3 Test ---"
        iperf3 -c "$iperf_server" -t "$DURATION" 2>&1 || true
    fi

    kv_write "$OUT_DIR/pids.kv" "comm_wifi" "$$"
}

cmd_evaluate() {
    _parse_args "$@"
    local result_file="$OUT_DIR/result.kv"
    local fails_file="$OUT_DIR/fails.kv"
    : > "$fails_file"

    local max_loss_pct rssi_warn_dbm
    max_loss_pct=$(kv_read "$CFG_FILE" "module.comm_wifi.max_loss_pct" "10")
    rssi_warn_dbm=$(kv_read "$CFG_FILE" "module.comm_wifi.rssi_warn_dbm" "-75")

    # Parse ping loss
    if [[ -f "$OUT_DIR/stdout.log" ]]; then
        local loss_pct
        loss_pct=$(grep "packet loss" "$OUT_DIR/stdout.log" 2>/dev/null | tail -1 | grep -oP '\d+(?=% packet loss)' 2>/dev/null || echo "0")
        kv_write "$result_file" "packet_loss_pct" "${loss_pct:-0}"
        if [[ "${loss_pct:-0}" -gt "$max_loss_pct" ]]; then
            fail_event "$fails_file" "PACKET_LOSS_HIGH" "warn" "Packet loss ${loss_pct}% exceeds ${max_loss_pct}%"
        fi
        if [[ "${loss_pct:-0}" -ge 100 ]]; then
            fail_event "$fails_file" "LINK_DOWN_PERSIST" "fail" "100% packet loss"
        fi

        # Parse RSSI
        local rssi
        rssi=$(grep -oP '(?<=signal: )-?\d+' "$OUT_DIR/stdout.log" 2>/dev/null | tail -1 || echo "")
        if [[ -n "$rssi" ]]; then
            kv_write "$result_file" "rssi_dbm" "$rssi"
            if [[ "$rssi" -lt "$rssi_warn_dbm" ]]; then
                fail_event "$fails_file" "RSSI_LOW" "warn" "RSSI ${rssi} dBm below ${rssi_warn_dbm} threshold"
            fi
        fi
    fi

    # Check logs for reconnects
    local log_output
    log_output=$($LOGREAD_CMD 2>/dev/null | tail -100 || true)
    local reconnect_count
    reconnect_count=$(echo "$log_output" | grep -ci "reassoc\|reconnect\|deauth\|disassoc" 2>/dev/null || echo "0")
    if [[ $reconnect_count -gt 3 ]]; then
        fail_event "$fails_file" "RECONNECTS_HIGH" "warn" "$reconnect_count wifi reconnect events"
    fi

    kv_write "$result_file" "duration_s" "${DURATION:-0}"
}

cmd_cleanup() {
    _parse_args "$@"
    echo "comm_wifi cleanup: no persistent state"
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
