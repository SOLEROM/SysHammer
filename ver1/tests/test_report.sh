#!/usr/bin/env bash
# test_report.sh - HTML report unit tests
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER1_DIR="$(dirname "$TESTS_DIR")"
source "$VER1_DIR/lib/common.sh"
source "$VER1_DIR/lib/config.sh"
source "$VER1_DIR/lib/scoring.sh"
source "$VER1_DIR/lib/report.sh"

PASS=0; FAIL=0; TOTAL=0

assert_contains() {
    local desc="$1" file="$2" pattern="$3"
    TOTAL=$((TOTAL + 1))
    if grep -q "$pattern" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
        [[ "${VERBOSE:-0}" == "1" ]] && echo "  PASS: $desc" || true
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc (pattern='$pattern' not found in $file)"
    fi
}

assert_not_contains() {
    local desc="$1" file="$2" pattern="$3"
    TOTAL=$((TOTAL + 1))
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
        [[ "${VERBOSE:-0}" == "1" ]] && echo "  PASS: $desc" || true
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc (pattern='$pattern' unexpectedly found in $file)"
    fi
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Set up a synthetic run directory
RUN="$TMPDIR/run"
mkdir -p "$RUN/meta" "$RUN/samples" "$RUN/modules/cpu" "$RUN/modules/gpu" "$RUN/report"

# Config kv (minimal)
cat > "$RUN/meta/config.kv" << 'EOF'
global.report_log_tail_lines=10
global.report_embed_logs=true
EOF
_CONFIG_KV_FILE="$RUN/meta/config.kv"

# Meta
kv_write "$RUN/meta/syshammer.kv" "version" "1.0.0"
kv_write "$RUN/meta/syshammer.kv" "run_id" "syshammer_test_20240101_120000_abcd"
kv_write "$RUN/meta/syshammer.kv" "tag" "unit_test"
kv_write "$RUN/meta/syshammer.kv" "debug" "0"
kv_write "$RUN/meta/syshammer.kv" "start_time" "2024-01-01 12:00:00"
kv_write "$RUN/meta/syshammer.kv" "end_time" "2024-01-01 12:05:00"
kv_write "$RUN/meta/syshammer.kv" "overall_score" "85"
kv_write "$RUN/meta/syshammer.kv" "overall_status" "pass"
kv_write "$RUN/meta/syshammer.kv" "modules_run" "1"
kv_write "$RUN/meta/syshammer.kv" "modules_skipped" "1"

# Platform
kv_write "$RUN/meta/platform.kv" "uname" "Linux test 5.15.0 armv7l"
kv_write "$RUN/meta/platform.kv" "cpu_model" "Test CPU"
kv_write "$RUN/meta/platform.kv" "nproc" "4"
kv_write "$RUN/meta/platform.kv" "mem_total_kb" "2048000"

# CPU module result
kv_write "$RUN/modules/cpu/result.kv" "status" "pass"
kv_write "$RUN/modules/cpu/result.kv" "score" "95"
kv_write "$RUN/modules/cpu/result.kv" "weight" "3"
kv_write "$RUN/modules/cpu/result.kv" "errors" "0"
kv_write "$RUN/modules/cpu/result.kv" "warnings" "1"
kv_write "$RUN/modules/cpu/result.kv" "duration_s" "60"
kv_write "$RUN/modules/cpu/result.kv" "fail_codes" "THERMAL_WARN"
kv_write "$RUN/modules/cpu/result.kv" "notes" "Temperature warning observed"

kv_write "$RUN/modules/cpu/probe.kv" "supports" "true"
kv_write "$RUN/modules/cpu/probe.kv" "tool" "stress-ng"
echo "ts=1000 code=THERMAL_WARN sev=warn detail=CPU temp 82C" > "$RUN/modules/cpu/fails.kv"
echo "stress-ng: info: [123] successful run completed" > "$RUN/modules/cpu/stdout.log"
echo "some stderr output" > "$RUN/modules/cpu/stderr.log"

# GPU module result (skip)
kv_write "$RUN/modules/gpu/result.kv" "status" "skip"
kv_write "$RUN/modules/gpu/result.kv" "score" "0"
kv_write "$RUN/modules/gpu/result.kv" "weight" "0"
kv_write "$RUN/modules/gpu/result.kv" "errors" "0"
kv_write "$RUN/modules/gpu/result.kv" "warnings" "0"
kv_write "$RUN/modules/gpu/result.kv" "duration_s" "0"
kv_write "$RUN/modules/gpu/result.kv" "fail_codes" ""
kv_write "$RUN/modules/gpu/result.kv" "notes" "Skipped: placeholder"
kv_write "$RUN/modules/gpu/probe.kv" "supports" "false"
kv_write "$RUN/modules/gpu/probe.kv" "reason" "placeholder"

# Generate report
report_generate "$RUN"
REPORT="$RUN/report/report.html"

# Verify report structure
assert_contains "html doctype" "$REPORT" "<!DOCTYPE html>"
assert_contains "title" "$REPORT" "Syshammer Report"
assert_contains "run id" "$REPORT" "syshammer_test_20240101_120000_abcd"
assert_contains "tag" "$REPORT" "unit_test"
assert_contains "version" "$REPORT" "1.0.0"
assert_contains "start time" "$REPORT" "2024-01-01 12:00:00"
assert_contains "end time" "$REPORT" "2024-01-01 12:05:00"
assert_contains "overall score" "$REPORT" "PASS 85/100"
assert_contains "platform cpu" "$REPORT" "Test CPU"
assert_contains "cpu module row" "$REPORT" "cpu"
assert_contains "gpu module row" "$REPORT" "gpu"
assert_contains "cpu score" "$REPORT" "95"
assert_contains "cpu status pass" "$REPORT" "status-pass"
assert_contains "gpu status skip" "$REPORT" "status-skip"
assert_contains "fail event" "$REPORT" "THERMAL_WARN"
assert_contains "embedded log" "$REPORT" "successful run completed"
assert_contains "inline css" "$REPORT" "<style>"
assert_not_contains "no external js" "$REPORT" "<script src="
assert_contains "self-contained footer" "$REPORT" "no external resources"

echo ""
echo "test_report: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
