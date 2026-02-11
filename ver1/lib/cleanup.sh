#!/usr/bin/env bash
# cleanup.sh - Trap handler, PID cleanup, module cleanup orchestration

# Registry of started modules: module_name -> out_dir
declare -A _CLEANUP_REGISTRY 2>/dev/null || true
_CLEANUP_DONE=0

# Register a module for cleanup
cleanup_register() {
    local module="$1" out_dir="$2"
    _CLEANUP_REGISTRY[$module]="$out_dir"
}

# Run cleanup for all registered modules
cleanup_all() {
    if [[ $_CLEANUP_DONE -eq 1 ]]; then return; fi
    _CLEANUP_DONE=1

    log_info "Running cleanup for all registered modules..."

    local module mod_dir cfg_file
    for module in "${!_CLEANUP_REGISTRY[@]}"; do
        mod_dir="${_CLEANUP_REGISTRY[$module]}"
        cfg_file="$RUN_DIR/meta/config.kv"

        log_debug "Cleanup: $module"

        # Kill any PIDs listed in pids.kv
        if [[ -f "$mod_dir/pids.kv" ]]; then
            while IFS='=' read -r _key pid; do
                if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                    kill -TERM "$pid" 2>/dev/null
                    log_debug "Killed PID $pid for module $module"
                fi
            done < "$mod_dir/pids.kv"
        fi

        # Call module cleanup if available
        if [[ -n "$MODULE_DIR" && -f "$MODULE_DIR/$module/$module.sh" ]]; then
            bash "$MODULE_DIR/$module/$module.sh" cleanup \
                --out "$mod_dir" --cfg "${cfg_file:-/dev/null}" \
                >> "$mod_dir/cleanup.log" 2>&1 || true
        fi
    done

    # Stop sampler if running
    sampler_stop 2>/dev/null || true

    # Write final metadata
    if [[ -n "$RUN_DIR" && -d "$RUN_DIR/meta" ]]; then
        kv_write "$RUN_DIR/meta/syshammer.kv" "end_ts" "$(date '+%s')"
        kv_write "$RUN_DIR/meta/syshammer.kv" "end_time" "$(date '+%Y-%m-%d %H:%M:%S')"
        kv_write "$RUN_DIR/meta/syshammer.kv" "cleanup" "completed"
    fi

    log_info "Cleanup complete"
}

# Trap handler for INT/TERM/EXIT
trap_handler() {
    local sig="${1:-EXIT}"
    log_warn "Caught signal: $sig"
    cleanup_all
}

# Install traps
install_traps() {
    trap 'trap_handler INT' INT
    trap 'trap_handler TERM' TERM
    trap 'trap_handler EXIT' EXIT
}
