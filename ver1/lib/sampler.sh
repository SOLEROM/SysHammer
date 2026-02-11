#!/usr/bin/env bash
# sampler.sh - Background system sampler (CPU, mem, thermal, freq)

_SAMPLER_PID=""
_SAMPLER_RUNNING=0

# Start background sampling loop
# Usage: sampler_start <out_dir> <interval_ms>
sampler_start() {
    local out_dir="$1" interval_ms="${2:-1000}"
    local csv_file="$out_dir/samples/system.csv"

    ensure_dir "$out_dir/samples"

    # Write CSV header
    printf 'timestamp,cpu_pct,mem_used_kb,mem_total_kb,temp_c,cpu_freq_khz\n' > "$csv_file"

    local interval_s
    interval_s=$(awk "BEGIN {printf \"%.1f\", $interval_ms / 1000}")

    # Launch sampler in background
    (
        local prev_idle=0 prev_total=0

        while true; do
            local ts cpu_pct mem_used mem_total temp freq

            ts=$(date '+%s')

            # CPU usage from /proc/stat
            cpu_pct=$(_sample_cpu prev_idle prev_total)

            # Memory from /proc/meminfo
            if [[ -f "${SYSROOT}/proc/meminfo" ]]; then
                mem_total=$(awk '/^MemTotal:/{print $2}' "${SYSROOT}/proc/meminfo" 2>/dev/null)
                local mem_avail
                mem_avail=$(awk '/^MemAvailable:/{print $2}' "${SYSROOT}/proc/meminfo" 2>/dev/null)
                if [[ -z "$mem_avail" ]]; then
                    local mem_free mem_buffers mem_cached
                    mem_free=$(awk '/^MemFree:/{print $2}' "${SYSROOT}/proc/meminfo" 2>/dev/null)
                    mem_buffers=$(awk '/^Buffers:/{print $2}' "${SYSROOT}/proc/meminfo" 2>/dev/null)
                    mem_cached=$(awk '/^Cached:/{print $2}' "${SYSROOT}/proc/meminfo" 2>/dev/null)
                    mem_avail=$(( ${mem_free:-0} + ${mem_buffers:-0} + ${mem_cached:-0} ))
                fi
                mem_used=$(( ${mem_total:-0} - ${mem_avail:-0} ))
            else
                mem_total=0
                mem_used=0
            fi

            # Thermal
            local tz_file="${SYSROOT}/sys/class/thermal/thermal_zone0/temp"
            if [[ -f "$tz_file" ]]; then
                local raw_temp
                raw_temp=$(cat "$tz_file" 2>/dev/null)
                temp=$(awk "BEGIN {printf \"%.1f\", ${raw_temp:-0} / 1000}")
            else
                temp=0
            fi

            # CPU frequency
            local freq_file="${SYSROOT}/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
            if [[ -f "$freq_file" ]]; then
                freq=$(cat "$freq_file" 2>/dev/null)
            else
                freq=0
            fi

            printf '%s,%s,%s,%s,%s,%s\n' \
                "$ts" "${cpu_pct:-0}" "${mem_used:-0}" "${mem_total:-0}" "${temp:-0}" "${freq:-0}" \
                >> "$csv_file"

            sleep "$interval_s"
        done
    ) &
    _SAMPLER_PID=$!
    _SAMPLER_RUNNING=1
    log_debug "Sampler started (PID=$_SAMPLER_PID, interval=${interval_ms}ms)"
}

# Stop the sampler
sampler_stop() {
    if [[ $_SAMPLER_RUNNING -eq 1 && -n "$_SAMPLER_PID" ]]; then
        kill "$_SAMPLER_PID" 2>/dev/null
        wait "$_SAMPLER_PID" 2>/dev/null
        _SAMPLER_RUNNING=0
        log_debug "Sampler stopped"
    fi
}

# Internal: compute CPU usage from /proc/stat delta
_sample_cpu() {
    local -n _prev_idle=$1 _prev_total=$2

    if [[ ! -f "${SYSROOT}/proc/stat" ]]; then
        echo "0"
        return
    fi

    local cpu_line
    cpu_line=$(head -1 "${SYSROOT}/proc/stat" 2>/dev/null)
    # cpu user nice system idle iowait irq softirq steal
    local -a fields
    read -ra fields <<< "$cpu_line"

    local idle=${fields[4]:-0}
    local total=0
    local i
    for i in "${fields[@]:1}"; do
        total=$((total + i))
    done

    local diff_idle=$((idle - _prev_idle))
    local diff_total=$((total - _prev_total))

    _prev_idle=$idle
    _prev_total=$total

    if [[ $diff_total -gt 0 ]]; then
        awk "BEGIN {printf \"%.1f\", (1 - $diff_idle / $diff_total) * 100}"
    else
        echo "0"
    fi
}
