#!/usr/bin/env bash
# scoring.sh - Per-module and overall scoring

# Hard-fail codes that force status=fail regardless of score
_HARD_FAIL_CODES="KERNEL_OOPS OOM_KILL IO_ERROR DEVICE_RESET LINK_DOWN_PERSIST TIMEOUT"

# Score a single module from its fails.kv
# Reads fails.kv, computes deductions, writes score fields to result.kv
score_module() {
    local mod_dir="$1"
    local fails_file="$mod_dir/fails.kv"
    local result_file="$mod_dir/result.kv"

    # If result already has status=skip, don't re-score
    local existing_status
    existing_status=$(kv_read "$result_file" "status" "")
    if [[ "$existing_status" == "skip" ]]; then return 0; fi

    local score=100
    local warn_deductions=0
    local fail_deductions=0
    local warn_count=0
    local error_count=0
    local has_hard_fail=0
    local fail_codes=""

    local warn_penalty=5
    local warn_cap=30
    local fail_penalty=20

    if [[ -f "$fails_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ -z "$line" ]]; then continue; fi

            # Parse fields from the event line
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

                # Check hard-fail
                for hf in $_HARD_FAIL_CODES; do
                    if [[ "$code" == "$hf" ]]; then
                        has_hard_fail=1
                        break
                    fi
                done
            fi

            case "$sev" in
                warn)
                    warn_count=$((warn_count + 1))
                    local wd=$((warn_deductions + warn_penalty))
                    if [[ $wd -gt $warn_cap ]]; then wd=$warn_cap; fi
                    warn_deductions=$wd
                    ;;
                fail)
                    error_count=$((error_count + 1))
                    local fd=$((fail_deductions + fail_penalty))
                    if [[ $fd -gt 100 ]]; then fd=100; fi
                    fail_deductions=$fd
                    ;;
            esac
        done < "$fails_file"
    fi

    score=$((100 - warn_deductions - fail_deductions))
    if [[ $score -lt 0 ]]; then score=0; fi

    # Determine status
    local status
    if [[ $has_hard_fail -eq 1 ]]; then
        status="fail"
    elif [[ $score -lt 40 ]]; then
        status="fail"
    elif [[ $score -lt 70 ]]; then
        status="warn"
    else
        status="pass"
    fi

    # Write/update result.kv (preserve existing fields like weight, duration_s)
    kv_write "$result_file" "score" "$score"
    kv_write "$result_file" "status" "$status"
    kv_write "$result_file" "errors" "$error_count"
    kv_write "$result_file" "warnings" "$warn_count"
    kv_write "$result_file" "fail_codes" "$fail_codes"

    # Ensure required fields exist
    local _w; _w=$(kv_read "$result_file" "weight" "")
    if [[ -z "$_w" ]]; then kv_write "$result_file" "weight" "1"; fi
    local _d; _d=$(kv_read "$result_file" "duration_s" "")
    if [[ -z "$_d" ]]; then kv_write "$result_file" "duration_s" "0"; fi
    local _n; _n=$(kv_read "$result_file" "notes" "")
    if [[ -z "$_n" ]]; then kv_write "$result_file" "notes" ""; fi
}

# Compute overall score: weighted average over non-skip modules
score_overall() {
    local run_dir="$1"
    local overall_file="$run_dir/meta/syshammer.kv"

    local total_weighted_score=0
    local total_weight=0
    local worst_status="pass"
    local module_count=0
    local skip_count=0

    for mod_dir in "$run_dir"/modules/*/; do
        [[ -d "$mod_dir" ]] || continue
        local result_file="$mod_dir/result.kv"
        [[ -f "$result_file" ]] || continue

        local status score weight
        status=$(kv_read "$result_file" "status" "skip")

        if [[ "$status" == "skip" ]]; then
            skip_count=$((skip_count + 1))
            continue
        fi

        score=$(kv_read "$result_file" "score" "0")
        weight=$(kv_read "$result_file" "weight" "1")

        total_weighted_score=$((total_weighted_score + score * weight))
        total_weight=$((total_weight + weight))
        module_count=$((module_count + 1))

        # Track worst status: fail > warn > pass
        case "$status" in
            fail) worst_status="fail" ;;
            warn) if [[ "$worst_status" != "fail" ]]; then worst_status="warn"; fi ;;
        esac
    done

    local overall_score=0
    if [[ $total_weight -gt 0 ]]; then
        overall_score=$((total_weighted_score / total_weight))
    fi

    kv_write "$overall_file" "overall_score" "$overall_score"
    kv_write "$overall_file" "overall_status" "$worst_status"
    kv_write "$overall_file" "modules_run" "$module_count"
    kv_write "$overall_file" "modules_skipped" "$skip_count"

    log_info "Overall: score=$overall_score status=$worst_status (${module_count} modules, ${skip_count} skipped)"
}
