#!/usr/bin/env bash
# report.sh - Offline HTML report generator

# Generate self-contained HTML report
report_generate() {
    local run_dir="$1"
    local report_dir="$run_dir/report"
    local report_file="$report_dir/report.html"

    ensure_dir "$report_dir"

    local meta="$run_dir/meta/syshammer.kv"
    local platform="$run_dir/meta/platform.kv"
    local plan="$run_dir/meta/plan.kv"
    local tools="$run_dir/meta/tools.kv"

    # Read metadata
    local version run_id tag debug_flag
    local start_time end_time overall_score overall_status
    local modules_run modules_skipped

    version=$(kv_read "$meta" "version" "unknown")
    run_id=$(kv_read "$meta" "run_id" "unknown")
    tag=$(kv_read "$meta" "tag" "")
    debug_flag=$(kv_read "$meta" "debug" "0")
    start_time=$(kv_read "$meta" "start_time" "unknown")
    end_time=$(kv_read "$meta" "end_time" "unknown")
    overall_score=$(kv_read "$meta" "overall_score" "0")
    overall_status=$(kv_read "$meta" "overall_status" "unknown")
    modules_run=$(kv_read "$meta" "modules_run" "0")
    modules_skipped=$(kv_read "$meta" "modules_skipped" "0")

    # Platform info
    local uname_str cpu_model nproc_val mem_total
    uname_str=$(kv_read "$platform" "uname" "unknown")
    cpu_model=$(kv_read "$platform" "cpu_model" "unknown")
    nproc_val=$(kv_read "$platform" "nproc" "unknown")
    mem_total=$(kv_read "$platform" "mem_total_kb" "unknown")

    # Log tail config
    local log_tail_lines embed_logs
    log_tail_lines=$(config_get "global.report_log_tail_lines" "50")
    embed_logs=$(config_get "global.report_embed_logs" "true")

    # Status color helper
    local status_color
    case "$overall_status" in
        pass) status_color="#2d7d2d" ;;
        warn) status_color="#b8860b" ;;
        fail) status_color="#cc3333" ;;
        *)    status_color="#666666" ;;
    esac

    # Build HTML
    cat > "$report_file" << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Syshammer Report</title>
<style>
body{font-family:'Courier New',monospace;margin:0;padding:20px;background:#1a1a2e;color:#e0e0e0;font-size:14px}
h1{color:#e94560;border-bottom:2px solid #e94560;padding-bottom:8px}
h2{color:#0f3460;background:#16213e;padding:8px 12px;border-left:4px solid #e94560;margin-top:30px}
h3{color:#e94560;margin-top:20px}
.summary{background:#16213e;border:1px solid #0f3460;padding:15px;border-radius:4px;margin:10px 0}
.summary td{padding:4px 12px}
.summary .label{color:#888;text-align:right}
table.modules{width:100%;border-collapse:collapse;margin:10px 0}
table.modules th{background:#0f3460;color:#e0e0e0;padding:8px;text-align:left;border:1px solid #333}
table.modules td{padding:6px 8px;border:1px solid #333}
table.modules tr:nth-child(even){background:#16213e}
.status-pass{color:#2d7d2d;font-weight:bold}
.status-warn{color:#b8860b;font-weight:bold}
.status-fail{color:#cc3333;font-weight:bold}
.status-skip{color:#666;font-style:italic}
.score-bar{display:inline-block;height:14px;border-radius:2px}
.log-box{background:#0d1117;border:1px solid #333;padding:10px;overflow-x:auto;white-space:pre;font-size:12px;max-height:400px;overflow-y:auto;margin:8px 0}
.fail-event{color:#cc3333;margin:2px 0}
.warn-event{color:#b8860b;margin:2px 0}
.badge{display:inline-block;padding:4px 12px;border-radius:3px;font-weight:bold;font-size:16px}
</style>
</head>
<body>
HTMLHEAD

    # Header summary
    cat >> "$report_file" << EOF
<h1>Syshammer Report</h1>
<div class="summary">
<table>
<tr><td class="label">Run ID:</td><td><strong>${run_id}</strong></td></tr>
<tr><td class="label">Tag:</td><td>${tag:-none}</td></tr>
<tr><td class="label">Version:</td><td>${version}</td></tr>
<tr><td class="label">Debug:</td><td>${debug_flag}</td></tr>
<tr><td class="label">Start:</td><td>${start_time}</td></tr>
<tr><td class="label">End:</td><td>${end_time}</td></tr>
<tr><td class="label">Platform:</td><td>${cpu_model} (${nproc_val} cores, $(( ${mem_total:-0} / 1024 )) MB)</td></tr>
<tr><td class="label">Kernel:</td><td>${uname_str}</td></tr>
<tr><td class="label">Modules:</td><td>${modules_run} run, ${modules_skipped} skipped</td></tr>
<tr><td class="label">Overall:</td><td><span class="badge" style="background:${status_color};color:white">${overall_status^^} ${overall_score}/100</span></td></tr>
</table>
</div>
EOF

    # Module summary table
    cat >> "$report_file" << 'EOF'
<h2>Module Summary</h2>
<table class="modules">
<tr><th>Module</th><th>Status</th><th>Score</th><th>Weight</th><th>Errors</th><th>Warnings</th><th>Duration</th><th>Fail Codes</th></tr>
EOF

    for mod_dir in "$run_dir"/modules/*/; do
        [[ -d "$mod_dir" ]] || continue
        local mod_name result_file
        mod_name=$(basename "$mod_dir")
        result_file="$mod_dir/result.kv"
        [[ -f "$result_file" ]] || continue

        local m_status m_score m_weight m_errors m_warnings m_duration m_fail_codes
        m_status=$(kv_read "$result_file" "status" "skip")
        m_score=$(kv_read "$result_file" "score" "0")
        m_weight=$(kv_read "$result_file" "weight" "0")
        m_errors=$(kv_read "$result_file" "errors" "0")
        m_warnings=$(kv_read "$result_file" "warnings" "0")
        m_duration=$(kv_read "$result_file" "duration_s" "0")
        m_fail_codes=$(kv_read "$result_file" "fail_codes" "")

        local sc="status-${m_status}"
        local bar_color
        case "$m_status" in
            pass) bar_color="#2d7d2d" ;;
            warn) bar_color="#b8860b" ;;
            fail) bar_color="#cc3333" ;;
            *)    bar_color="#666" ;;
        esac

        cat >> "$report_file" << EOF
<tr>
<td><a href="#mod-${mod_name}">${mod_name}</a></td>
<td class="${sc}">${m_status}</td>
<td><span class="score-bar" style="width:${m_score}px;background:${bar_color}">&nbsp;</span> ${m_score}</td>
<td>${m_weight}</td>
<td>${m_errors}</td>
<td>${m_warnings}</td>
<td>${m_duration}s</td>
<td>${m_fail_codes:-none}</td>
</tr>
EOF
    done

    echo '</table>' >> "$report_file"

    # Per-module detail sections
    for mod_dir in "$run_dir"/modules/*/; do
        [[ -d "$mod_dir" ]] || continue
        local mod_name
        mod_name=$(basename "$mod_dir")
        local result_file="$mod_dir/result.kv"
        [[ -f "$result_file" ]] || continue

        local m_status m_notes
        m_status=$(kv_read "$result_file" "status" "skip")
        m_notes=$(kv_read "$result_file" "notes" "")

        cat >> "$report_file" << EOF
<h2 id="mod-${mod_name}">Module: ${mod_name}</h2>
<div class="summary">
EOF

        # Probe info
        if [[ -f "$mod_dir/probe.kv" ]]; then
            echo '<h3>Probe</h3><div class="log-box">' >> "$report_file"
            _html_escape_file "$mod_dir/probe.kv" >> "$report_file"
            echo '</div>' >> "$report_file"
        fi

        # Result
        echo '<h3>Result</h3><div class="log-box">' >> "$report_file"
        _html_escape_file "$result_file" >> "$report_file"
        echo '</div>' >> "$report_file"

        # Failure events
        if [[ -f "$mod_dir/fails.kv" && -s "$mod_dir/fails.kv" ]]; then
            echo '<h3>Failure Events</h3>' >> "$report_file"
            while IFS= read -r fline || [[ -n "$fline" ]]; do
                if [[ -z "$fline" ]]; then continue; fi
                local fsev=""
                local field
                for field in $fline; do
                    case "$field" in sev=*) fsev="${field#sev=}" ;; esac
                done
                local fcls="fail-event"
                if [[ "$fsev" == "warn" ]]; then fcls="warn-event"; fi
                printf '<div class="%s">%s</div>\n' "$fcls" "$(_html_escape "$fline")" >> "$report_file"
            done < "$mod_dir/fails.kv"
        fi

        # Notes
        if [[ -n "$m_notes" ]]; then
            printf '<p><strong>Notes:</strong> %s</p>\n' "$(_html_escape "$m_notes")" >> "$report_file"
        fi

        # Embedded logs
        if [[ "$embed_logs" == "true" && "$m_status" != "skip" ]]; then
            for logfile in stdout.log stderr.log; do
                if [[ -f "$mod_dir/$logfile" && -s "$mod_dir/$logfile" ]]; then
                    printf '<h3>%s</h3>\n<div class="log-box">' "$logfile" >> "$report_file"
                    if [[ "$debug_flag" == "1" ]]; then
                        _html_escape_file "$mod_dir/$logfile" >> "$report_file"
                    else
                        tail -n "$log_tail_lines" "$mod_dir/$logfile" | _html_escape_stdin >> "$report_file"
                    fi
                    echo '</div>' >> "$report_file"
                fi
            done
        fi

        echo '</div>' >> "$report_file"
    done

    # Footer
    cat >> "$report_file" << 'EOF'
<hr>
<p style="color:#666;font-size:12px">Generated by Syshammer. All data inline, no external resources.</p>
</body>
</html>
EOF

    log_info "Report generated: $report_file"
}

# HTML escape helpers
_html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

_html_escape_file() {
    local file="$1"
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g' "$file"
}

_html_escape_stdin() {
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}
