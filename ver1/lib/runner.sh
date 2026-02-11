#!/usr/bin/env bash
# runner.sh - Stage executor: sequential + parallel modes

# Module base directory (set by orchestrator)
: "${MODULE_DIR:=}"

# Track which modules have been probed (probe runs once per run)
declare -A _PROBED_MODULES 2>/dev/null || true

# Run the full plan: iterate stages in order
run_plan() {
    local run_dir="$1"
    local plan_file="$run_dir/meta/plan.kv"

    local stages_csv
    stages_csv=$(kv_read "$plan_file" "stages" "")
    if [[ -z "$stages_csv" ]]; then
        log_error "No stages in plan"
        return 1
    fi

    local stop_on_fail
    stop_on_fail=$(config_get "global.stop_on_fail" "false")

    IFS=',' read -ra stage_list <<< "$stages_csv"
    for stage in "${stage_list[@]}"; do
        stage="${stage#"${stage%%[![:space:]]*}"}"
        stage="${stage%"${stage##*[![:space:]]}"}"

        local mode
        mode=$(kv_read "$plan_file" "stage.${stage}.mode" "sequential")

        log_info "=== Stage: $stage (mode=$mode) ==="

        if [[ "$mode" == "parallel" ]]; then
            run_stage_parallel "$run_dir" "$stage"
        else
            run_stage_sequential "$run_dir" "$stage"
        fi
        local rc=$?

        if [[ "$stop_on_fail" == "true" && $rc -ne 0 ]]; then
            log_warn "Stage '$stage' had failures and stop_on_fail=true, halting plan"
            return 1
        fi
    done
}

# Sequential stage: for each member: probe, run, evaluate, cleanup
run_stage_sequential() {
    local run_dir="$1" stage="$2"
    local plan_file="$run_dir/meta/plan.kv"
    local had_failure=0

    local members_csv
    members_csv=$(kv_read "$plan_file" "stage.${stage}.members" "")
    if [[ -z "$members_csv" ]]; then return 0; fi

    IFS=',' read -ra members <<< "$members_csv"
    for member in "${members[@]}"; do
        member="${member#"${member%%[![:space:]]*}"}"
        member="${member%"${member##*[![:space:]]}"}"

        local status
        status=$(kv_read "$plan_file" "stage.${stage}.module.${member}.status" "pending")
        if [[ "$status" == "disabled" ]]; then
            log_info "[$member] Disabled, skipping"
            continue
        fi

        _run_module "$run_dir" "$stage" "$member" || had_failure=1
    done

    return $had_failure
}

# Parallel stage: probe all, start all, wait all, evaluate all, cleanup all
run_stage_parallel() {
    local run_dir="$1" stage="$2"
    local plan_file="$run_dir/meta/plan.kv"
    local had_failure=0

    local members_csv
    members_csv=$(kv_read "$plan_file" "stage.${stage}.members" "")
    if [[ -z "$members_csv" ]]; then return 0; fi

    IFS=',' read -ra members <<< "$members_csv"

    # Phase 1: Probe all
    local supported_members=()
    for member in "${members[@]}"; do
        member="${member#"${member%%[![:space:]]*}"}"
        member="${member%"${member##*[![:space:]]}"}"

        local status
        status=$(kv_read "$plan_file" "stage.${stage}.module.${member}.status" "pending")
        if [[ "$status" == "disabled" ]]; then
            log_info "[$member] Disabled, skipping"
            continue
        fi

        _probe_module "$run_dir" "$member"
        local mod_dir="$run_dir/modules/$member"
        local supports
        supports=$(kv_read "$mod_dir/probe.kv" "supports" "false")
        if [[ "$supports" == "true" ]]; then
            supported_members+=("$member")
        else
            local reason
            reason=$(kv_read "$mod_dir/probe.kv" "reason" "not supported")
            log_info "[$member] Skipped: $reason"
            _write_skip_result "$mod_dir" "$reason"
        fi
    done

    # Phase 2: Start all runs in background
    declare -A run_pids
    for member in "${supported_members[@]}"; do
        local mod_dir="$run_dir/modules/$member"
        local dur tmo cfg_file
        dur=$(kv_read "$plan_file" "stage.${stage}.module.${member}.duration_s" "30")
        tmo=$(kv_read "$plan_file" "stage.${stage}.module.${member}.timeout_s" "$((dur + 30))")
        cfg_file="$run_dir/meta/config.kv"

        log_info "[$member] Starting run (duration=${dur}s, timeout=${tmo}s)"
        cleanup_register "$member" "$mod_dir"

        (
            run_with_timeout "$tmo" \
                bash "$MODULE_DIR/$member/module.sh" run \
                    --out "$mod_dir" --duration "$dur" --cfg "$cfg_file" \
                > "$mod_dir/stdout.log" 2> "$mod_dir/stderr.log"
        ) &
        run_pids[$member]=$!

        if [[ "$DEBUG" == "1" ]]; then
            log_debug "[$member] PID=${run_pids[$member]}"
        fi
    done

    # Phase 3: Wait for all
    for member in "${supported_members[@]}"; do
        local pid=${run_pids[$member]}
        wait "$pid" 2>/dev/null
        local rc=$?
        if [[ $rc -eq 124 ]]; then
            log_warn "[$member] Timed out"
            local mod_dir="$run_dir/modules/$member"
            fail_event "$mod_dir/fails.kv" "TIMEOUT" "fail" "Module run timed out"
        elif [[ $rc -ne 0 ]]; then
            log_warn "[$member] Run exited with code $rc"
        fi
    done

    # Phase 4: Evaluate all
    for member in "${supported_members[@]}"; do
        local mod_dir="$run_dir/modules/$member"
        local cfg_file="$run_dir/meta/config.kv"
        log_info "[$member] Evaluating"
        bash "$MODULE_DIR/$member/module.sh" evaluate \
            --out "$mod_dir" --cfg "$cfg_file" 2>>"$mod_dir/stderr.log" || true

        score_module "$mod_dir"
        local mod_status
        mod_status=$(kv_read "$mod_dir/result.kv" "status" "pass")
        if [[ "$mod_status" == "fail" ]]; then had_failure=1; fi
    done

    # Phase 5: Cleanup all
    for member in "${supported_members[@]}"; do
        local mod_dir="$run_dir/modules/$member"
        local cfg_file="$run_dir/meta/config.kv"
        log_debug "[$member] Cleaning up"
        bash "$MODULE_DIR/$member/module.sh" cleanup \
            --out "$mod_dir" --cfg "$cfg_file" > "$mod_dir/cleanup.log" 2>&1 || true
    done

    return $had_failure
}

# Internal: run a single module through full lifecycle (probe, run, evaluate, cleanup)
_run_module() {
    local run_dir="$1" stage="$2" member="$3"
    local plan_file="$run_dir/meta/plan.kv"
    local mod_dir="$run_dir/modules/$member"
    local cfg_file="$run_dir/meta/config.kv"

    ensure_dir "$mod_dir"

    # Probe (once per run)
    _probe_module "$run_dir" "$member"
    local supports
    supports=$(kv_read "$mod_dir/probe.kv" "supports" "false")
    if [[ "$supports" != "true" ]]; then
        local reason
        reason=$(kv_read "$mod_dir/probe.kv" "reason" "not supported")
        log_info "[$member] Skipped: $reason"
        _write_skip_result "$mod_dir" "$reason"
        return 0
    fi

    # Run
    local dur tmo
    dur=$(kv_read "$plan_file" "stage.${stage}.module.${member}.duration_s" "30")
    tmo=$(kv_read "$plan_file" "stage.${stage}.module.${member}.timeout_s" "$((dur + 30))")

    log_info "[$member] Running (duration=${dur}s, timeout=${tmo}s)"
    cleanup_register "$member" "$mod_dir"

    local run_rc=0
    if [[ "$DEBUG" == "1" ]]; then
        run_with_timeout "$tmo" \
            bash "$MODULE_DIR/$member/module.sh" run \
                --out "$mod_dir" --duration "$dur" --cfg "$cfg_file" \
            > >(tee "$mod_dir/stdout.log" | sed "s/^/[$member] /" >&2) \
            2> >(tee "$mod_dir/stderr.log" | sed "s/^/[$member] /" >&2) || run_rc=$?
    else
        run_with_timeout "$tmo" \
            bash "$MODULE_DIR/$member/module.sh" run \
                --out "$mod_dir" --duration "$dur" --cfg "$cfg_file" \
            > "$mod_dir/stdout.log" 2> "$mod_dir/stderr.log" || run_rc=$?
    fi

    if [[ $run_rc -eq 124 ]]; then
        log_warn "[$member] Timed out"
        fail_event "$mod_dir/fails.kv" "TIMEOUT" "fail" "Module run timed out"
    elif [[ $run_rc -ne 0 ]]; then
        log_warn "[$member] Run exited with code $run_rc"
    fi

    # Evaluate
    log_info "[$member] Evaluating"
    bash "$MODULE_DIR/$member/module.sh" evaluate \
        --out "$mod_dir" --cfg "$cfg_file" 2>>"$mod_dir/stderr.log" || true

    # Score
    score_module "$mod_dir"

    # Cleanup
    log_debug "[$member] Cleaning up"
    bash "$MODULE_DIR/$member/module.sh" cleanup \
        --out "$mod_dir" --cfg "$cfg_file" > "$mod_dir/cleanup.log" 2>&1 || true

    local mod_status
    mod_status=$(kv_read "$mod_dir/result.kv" "status" "pass")
    if [[ "$mod_status" == "fail" ]]; then
        return 1
    fi
    return 0
}

# Internal: probe a module (only once per run)
_probe_module() {
    local run_dir="$1" member="$2"
    local mod_dir="$run_dir/modules/$member"
    local cfg_file="$run_dir/meta/config.kv"

    ensure_dir "$mod_dir"

    # Skip if already probed
    if [[ "${_PROBED_MODULES[$member]:-}" == "1" ]]; then
        return
    fi

    if [[ ! -f "$MODULE_DIR/$member/module.sh" ]]; then
        log_warn "[$member] Module file not found: $MODULE_DIR/$member/module.sh"
        kv_write "$mod_dir/probe.kv" "supports" "false"
        kv_write "$mod_dir/probe.kv" "reason" "module not found"
        _PROBED_MODULES[$member]=1
        return
    fi

    log_info "[$member] Probing"
    bash "$MODULE_DIR/$member/module.sh" probe \
        --out "$mod_dir" --cfg "$cfg_file" 2>>"$mod_dir/stderr.log" || true

    _PROBED_MODULES[$member]=1
}

# Write a skip result for a module
_write_skip_result() {
    local mod_dir="$1" reason="$2"
    kv_write "$mod_dir/result.kv" "status" "skip"
    kv_write "$mod_dir/result.kv" "errors" "0"
    kv_write "$mod_dir/result.kv" "warnings" "0"
    kv_write "$mod_dir/result.kv" "duration_s" "0"
    kv_write "$mod_dir/result.kv" "fail_codes" ""
    kv_write "$mod_dir/result.kv" "notes" "Skipped: $reason"
}
