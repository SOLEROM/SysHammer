#!/usr/bin/env bash
# scoring.sh - Per-module and overall status determination

# Hard-fail codes that force status=fail
_HARD_FAIL_CODES="KERNEL_OOPS OOM_KILL IO_ERROR DEVICE_RESET LINK_DOWN_PERSIST TIMEOUT"

# Determine status for a single module from its fails.kv
# Reads fails.kv, determines pass/warn/fail, writes to result.kv
score_module() {
    local mod_dir="$1"
    local fails_file="$mod_dir/fails.kv"
    local result_file="$mod_dir/result.kv"

    # If result already has status=skip, don't re-evaluate
    local existing_status
    existing_status=$(kv_read "$result_file" "status" "")
    if [[ "$existing_status" == "skip" ]]; then return 0; fi

    local warn_count=0
    local error_count=0
    local has_hard_fail=0
    local fail_codes=""

    if [[ -f "$fails_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ -z "$line" ]]; then continue; fi

            local sev="" code=""
            local field
            for field in $line; do
                case "$field" in
                    sev=*)   sev="${field#sev=}" ;;
                    code=*)  code="${field#code=}" ;;
                esac
            done

            # Track fail codes
            if [[ -n "$code" ]]; then
                if [[ -n "$fail_codes" ]]; then fail_codes="${fail_codes},"; fi
                fail_codes="${fail_codes}${code}"

                for hf in $_HARD_FAIL_CODES; do
                    if [[ "$code" == "$hf" ]]; then
                        has_hard_fail=1
                        break
                    fi
                done
            fi

            case "$sev" in
                warn) warn_count=$((warn_count + 1)) ;;
                fail) error_count=$((error_count + 1)) ;;
            esac
        done < "$fails_file"
    fi

    # Determine status: fail > warn > pass
    local status
    if [[ $has_hard_fail -eq 1 || $error_count -gt 0 ]]; then
        status="fail"
    elif [[ $warn_count -gt 0 ]]; then
        status="warn"
    else
        status="pass"
    fi

    kv_write "$result_file" "status" "$status"
    kv_write "$result_file" "errors" "$error_count"
    kv_write "$result_file" "warnings" "$warn_count"
    kv_write "$result_file" "fail_codes" "$fail_codes"

    # Ensure required fields exist
    local _d; _d=$(kv_read "$result_file" "duration_s" "")
    if [[ -z "$_d" ]]; then kv_write "$result_file" "duration_s" "0"; fi
    local _n; _n=$(kv_read "$result_file" "notes" "")
    if [[ -z "$_n" ]]; then kv_write "$result_file" "notes" ""; fi
}

# Determine overall status: worst status across all non-skip modules
score_overall() {
    local run_dir="$1"
    local overall_file="$run_dir/meta/syshammer.kv"

    local worst_status="pass"
    local module_count=0
    local skip_count=0

    for mod_dir in "$run_dir"/modules/*/; do
        [[ -d "$mod_dir" ]] || continue
        local result_file="$mod_dir/result.kv"
        [[ -f "$result_file" ]] || continue

        local status
        status=$(kv_read "$result_file" "status" "skip")

        if [[ "$status" == "skip" ]]; then
            skip_count=$((skip_count + 1))
            continue
        fi

        module_count=$((module_count + 1))

        case "$status" in
            fail) worst_status="fail" ;;
            warn) if [[ "$worst_status" != "fail" ]]; then worst_status="warn"; fi ;;
        esac
    done

    kv_write "$overall_file" "overall_status" "$worst_status"
    kv_write "$overall_file" "modules_run" "$module_count"
    kv_write "$overall_file" "modules_skipped" "$skip_count"

    log_info "Overall: status=$worst_status (${module_count} modules, ${skip_count} skipped)"
}
