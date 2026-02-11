#!/usr/bin/env bash
# plan.sh - Plan expansion: resolve stages, durations, weights from config

# Expand the execution plan from parsed config.
# Resolves stages, members, durations, weights with precedence:
#   module.<name>.X > stage.<stage>.X > module_defaults.X
# Writes expanded plan to meta/plan.kv
plan_expand() {
    local out_dir="$1"
    local plan_file="$out_dir/meta/plan.kv"
    : > "$plan_file"

    # Get stage list
    local stages_csv
    stages_csv=$(config_get "plan.stages" "")
    if [[ -z "$stages_csv" ]]; then
        log_error "No stages defined in config [plan].stages"
        return 1
    fi

    kv_write "$plan_file" "stages" "$stages_csv"

    # Defaults
    local default_duration default_weight
    default_duration=$(config_get "module_defaults.duration_s" "30")
    default_weight=$(config_get "module_defaults.weight" "1")

    kv_write "$plan_file" "default_duration_s" "$default_duration"
    kv_write "$plan_file" "default_weight" "$default_weight"

    # Track all modules that appear in any stage
    local all_modules=""

    # Process each stage
    local IFS=','
    local stage_list=($stages_csv)
    unset IFS

    local stage_idx=0
    for stage in "${stage_list[@]}"; do
        stage="${stage#"${stage%%[![:space:]]*}"}"
        stage="${stage%"${stage##*[![:space:]]}"}"

        local mode members_csv stage_duration stage_timeout
        mode=$(config_get "stage.${stage}.mode" "sequential")
        members_csv=$(config_get "stage.${stage}.members" "")
        stage_duration=$(config_get "stage.${stage}.duration_s" "")
        stage_timeout=$(config_get "stage.${stage}.timeout_s" "")

        kv_write "$plan_file" "stage.${stage}.order" "$stage_idx"
        kv_write "$plan_file" "stage.${stage}.mode" "$mode"
        kv_write "$plan_file" "stage.${stage}.members" "$members_csv"
        if [[ -n "$stage_timeout" ]]; then
            kv_write "$plan_file" "stage.${stage}.timeout_s" "$stage_timeout"
        fi

        if [[ -z "$members_csv" ]]; then
            log_warn "Stage '$stage' has no members"
            stage_idx=$((stage_idx + 1))
            continue
        fi

        IFS=','
        local member_list=($members_csv)
        unset IFS

        for member in "${member_list[@]}"; do
            member="${member#"${member%%[![:space:]]*}"}"
            member="${member%"${member##*[![:space:]]}"}"

            # Check if module is enabled
            local enabled
            enabled=$(config_get "module.${member}.enable" "true")
            if [[ "$enabled" == "false" ]]; then
                kv_write "$plan_file" "stage.${stage}.module.${member}.status" "disabled"
                log_debug "Module '$member' disabled by config"
                continue
            fi

            # Resolve duration: module > stage > default
            local dur
            dur=$(config_get "module.${member}.duration_s" "")
            if [[ -z "$dur" ]]; then dur="$stage_duration"; fi
            if [[ -z "$dur" ]]; then dur="$default_duration"; fi

            # Resolve weight: module > default
            local wgt
            wgt=$(config_get "module.${member}.weight" "$default_weight")

            # Resolve timeout: module > stage > duration + 30s safety margin
            local tmo
            tmo=$(config_get "module.${member}.timeout_s" "")
            if [[ -z "$tmo" && -n "$stage_timeout" ]]; then tmo="$stage_timeout"; fi
            if [[ -z "$tmo" ]]; then tmo=$((dur + 30)); fi

            kv_write "$plan_file" "stage.${stage}.module.${member}.duration_s" "$dur"
            kv_write "$plan_file" "stage.${stage}.module.${member}.weight" "$wgt"
            kv_write "$plan_file" "stage.${stage}.module.${member}.timeout_s" "$tmo"
            kv_write "$plan_file" "stage.${stage}.module.${member}.status" "pending"

            # Track unique modules
            if [[ "$all_modules" != *"$member"* ]]; then
                if [[ -n "$all_modules" ]]; then all_modules="${all_modules},"; fi
                all_modules="${all_modules}${member}"
            fi
        done

        stage_idx=$((stage_idx + 1))
    done

    kv_write "$plan_file" "all_modules" "$all_modules"
    kv_write "$plan_file" "stage_count" "$stage_idx"

    log_info "Plan expanded: $stage_idx stages, modules: $all_modules"
}

# Write plan to file (already done during expand, this is for re-export)
plan_write() {
    local out_dir="$1"
    # plan_expand already writes to meta/plan.kv
    log_debug "Plan written to $out_dir/meta/plan.kv"
}
