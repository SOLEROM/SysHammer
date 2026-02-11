#!/usr/bin/env bash
# tools.sh - Tool detection and version probing

# List of tools to detect
_TOOLS_LIST="stress-ng fio iperf3 iw iwconfig hcitool bluetoothctl i2cget i2cset spidev_test ping dd sync ethtool ip dmesg logread"

# Detect tools and write meta/tools.kv
tools_detect() {
    local out_dir="$1"
    local tf="$out_dir/meta/tools.kv"
    : > "$tf"

    local tool version
    for tool in $_TOOLS_LIST; do
        if command -v "$tool" >/dev/null 2>&1; then
            version=$(_tool_version "$tool")
            kv_write "$tf" "$tool" "$version"
            log_debug "Tool found: $tool ($version)"
        else
            kv_write "$tf" "$tool" "missing"
            log_debug "Tool missing: $tool"
        fi
    done

    # Detect logread vs dmesg for log scanning
    if command -v logread >/dev/null 2>&1; then
        kv_write "$tf" "log_cmd" "logread"
    elif command -v dmesg >/dev/null 2>&1; then
        kv_write "$tf" "log_cmd" "dmesg"
    else
        kv_write "$tf" "log_cmd" "none"
    fi

    # Detect timeout command
    if command -v timeout >/dev/null 2>&1; then
        kv_write "$tf" "timeout" "available"
    else
        kv_write "$tf" "timeout" "missing"
    fi

    log_info "Tool detection complete"
}

# Get version string for a tool (best effort)
_tool_version() {
    local tool="$1"
    case "$tool" in
        stress-ng)
            stress-ng --version 2>&1 | head -1 | awk '{print $NF}' || echo "unknown"
            ;;
        fio)
            fio --version 2>&1 | head -1 || echo "unknown"
            ;;
        iperf3)
            iperf3 --version 2>&1 | head -1 | awk '{print $2}' || echo "unknown"
            ;;
        iw)
            iw --version 2>&1 | awk '{print $NF}' || echo "unknown"
            ;;
        ping)
            ping -V 2>&1 | head -1 || echo "unknown"
            ;;
        ethtool)
            ethtool --version 2>&1 | awk '{print $NF}' || echo "unknown"
            ;;
        i2cget|i2cset)
            "$tool" -V 2>&1 | head -1 || echo "unknown"
            ;;
        *)
            echo "present"
            ;;
    esac
}

# Check if a specific tool is available (not missing)
tool_available() {
    local out_dir="$1" tool="$2"
    local tf="$out_dir/meta/tools.kv"
    local val
    val=$(kv_read "$tf" "$tool" "missing")
    [[ "$val" != "missing" ]]
}
