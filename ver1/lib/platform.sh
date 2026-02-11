#!/usr/bin/env bash
# platform.sh - Platform detection and inventory

# Collect platform information and write to meta/platform.kv
platform_collect() {
    local out_dir="$1"
    local pf="$out_dir/meta/platform.kv"
    : > "$pf"

    kv_write "$pf" "uname" "$(uname -a 2>/dev/null || echo 'unknown')"
    kv_write "$pf" "kernel" "$(uname -r 2>/dev/null || echo 'unknown')"
    kv_write "$pf" "arch" "$(uname -m 2>/dev/null || echo 'unknown')"
    kv_write "$pf" "hostname" "$(hostname 2>/dev/null || echo 'unknown')"

    # Kernel cmdline
    if [[ -f "${SYSROOT}/proc/cmdline" ]]; then
        kv_write "$pf" "cmdline" "$(cat "${SYSROOT}/proc/cmdline" 2>/dev/null)"
    fi

    # CPU info
    if [[ -f "${SYSROOT}/proc/cpuinfo" ]]; then
        local cpu_model
        cpu_model=$(grep -m1 'model name' "${SYSROOT}/proc/cpuinfo" 2>/dev/null | cut -d: -f2 | sed 's/^ //' || true)
        if [[ -z "$cpu_model" ]]; then
            cpu_model=$(grep -m1 'Hardware' "${SYSROOT}/proc/cpuinfo" 2>/dev/null | cut -d: -f2 | sed 's/^ //' || true)
        fi
        if [[ -n "$cpu_model" ]]; then
            kv_write "$pf" "cpu_model" "$cpu_model"
        fi
    fi
    kv_write "$pf" "nproc" "$(nproc 2>/dev/null || echo '1')"

    # Memory info
    if [[ -f "${SYSROOT}/proc/meminfo" ]]; then
        local mem_total
        mem_total=$(grep 'MemTotal' "${SYSROOT}/proc/meminfo" 2>/dev/null | awk '{print $2}')
        if [[ -n "$mem_total" ]]; then
            kv_write "$pf" "mem_total_kb" "$mem_total"
        fi
    fi

    # Mounts summary
    if command -v mount >/dev/null 2>&1; then
        kv_write "$pf" "mounts" "$(mount 2>/dev/null | head -20 | tr '\n' '|')"
    fi

    # Thermal zones
    local tz_dir="${SYSROOT}/sys/class/thermal"
    if [[ -d "$tz_dir" ]]; then
        local tz_count=0
        for tz in "$tz_dir"/thermal_zone*; do
            if [[ -d "$tz" ]]; then tz_count=$((tz_count + 1)); fi
        done
        kv_write "$pf" "thermal_zones" "$tz_count"
    fi

    # Network interfaces
    local net_dir="${SYSROOT}/sys/class/net"
    if [[ -d "$net_dir" ]]; then
        local ifaces=""
        for iface in "$net_dir"/*/; do
            local name
            name=$(basename "$iface")
            if [[ "$name" == "lo" ]]; then continue; fi
            if [[ -n "$ifaces" ]]; then ifaces="${ifaces},"; fi
            ifaces="${ifaces}${name}"
        done
        if [[ -n "$ifaces" ]]; then
            kv_write "$pf" "net_interfaces" "$ifaces"
        fi
    fi

    log_info "Platform info collected"
}
