#!/usr/bin/env bash
# test_runner.sh - Orchestrator integration tests with fake modules
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER1_DIR="$(dirname "$TESTS_DIR")"

# Source all libs
source "$VER1_DIR/lib/common.sh"
source "$VER1_DIR/lib/config.sh"
source "$VER1_DIR/lib/plan.sh"
source "$VER1_DIR/lib/platform.sh"
source "$VER1_DIR/lib/tools.sh"
source "$VER1_DIR/lib/runner.sh"
source "$VER1_DIR/lib/sampler.sh"
source "$VER1_DIR/lib/scoring.sh"
source "$VER1_DIR/lib/report.sh"
source "$VER1_DIR/lib/cleanup.sh"

export PATH="$TESTS_DIR/fakebin:$PATH"
export SYSROOT="$TESTS_DIR/fakesys"
export LOGREAD_CMD="dmesg"

PASS=0; FAIL=0; TOTAL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        [[ "${VERBOSE:-0}" == "1" ]] && echo "  PASS: $desc" || true
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc (expected='$expected', actual='$actual')"
    fi
}

assert_file_exists() {
    local desc="$1" file="$2"
    TOTAL=$((TOTAL + 1))
    if [[ -f "$file" ]]; then
        PASS=$((PASS + 1))
        [[ "${VERBOSE:-0}" == "1" ]] && echo "  PASS: $desc" || true
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc (file not found: $file)"
    fi
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Use fake modules
MODULE_DIR="$TESTS_DIR/modules"

# Test 1: Sequential stage with pass + skip modules
cat > "$TMPDIR/test1.cfg" << 'EOF'
[module_defaults]
duration_s = 1
weight = 1

[plan]
stages = s1

[stage.s1]
mode = sequential
members = fast_pass,fast_skip
EOF

RUN_DIR="$TMPDIR/run1"
mkdir -p "$RUN_DIR/meta" "$RUN_DIR/samples" "$RUN_DIR/modules" "$RUN_DIR/report"
: > "$RUN_DIR/meta/core.log"
config_parse "$TMPDIR/test1.cfg" "$RUN_DIR/meta/config.kv"
plan_expand "$RUN_DIR"

# Reset probed modules
declare -A _PROBED_MODULES=()
_CLEANUP_DONE=0
declare -A _CLEANUP_REGISTRY=()

run_plan "$RUN_DIR"

assert_file_exists "pass result.kv" "$RUN_DIR/modules/fast_pass/result.kv"
assert_file_exists "skip result.kv" "$RUN_DIR/modules/fast_skip/result.kv"
assert_eq "pass status" "pass" "$(kv_read "$RUN_DIR/modules/fast_pass/result.kv" "status")"
assert_eq "skip status" "skip" "$(kv_read "$RUN_DIR/modules/fast_skip/result.kv" "status")"

# Test 2: Parallel stage
cat > "$TMPDIR/test2.cfg" << 'EOF'
[module_defaults]
duration_s = 1
weight = 1

[plan]
stages = p1

[stage.p1]
mode = parallel
members = fast_pass,fast_fail
EOF

RUN_DIR="$TMPDIR/run2"
mkdir -p "$RUN_DIR/meta" "$RUN_DIR/samples" "$RUN_DIR/modules" "$RUN_DIR/report"
: > "$RUN_DIR/meta/core.log"
config_parse "$TMPDIR/test2.cfg" "$RUN_DIR/meta/config.kv"
plan_expand "$RUN_DIR"

declare -A _PROBED_MODULES=()
_CLEANUP_DONE=0
declare -A _CLEANUP_REGISTRY=()

run_plan "$RUN_DIR" || true

assert_file_exists "parallel pass result" "$RUN_DIR/modules/fast_pass/result.kv"
assert_file_exists "parallel fail result" "$RUN_DIR/modules/fast_fail/result.kv"
assert_eq "parallel pass status" "pass" "$(kv_read "$RUN_DIR/modules/fast_pass/result.kv" "status")"
assert_eq "parallel fail status" "fail" "$(kv_read "$RUN_DIR/modules/fast_fail/result.kv" "status")"

# Verify stdout.log and stderr.log created for parallel modules
assert_file_exists "parallel stdout.log" "$RUN_DIR/modules/fast_pass/stdout.log"
assert_file_exists "parallel stderr.log" "$RUN_DIR/modules/fast_pass/stderr.log"

# Test 3: stop_on_fail behavior
cat > "$TMPDIR/test3.cfg" << 'EOF'
[global]
stop_on_fail = true

[module_defaults]
duration_s = 1
weight = 1

[plan]
stages = s1,s2

[stage.s1]
mode = sequential
members = fast_fail

[stage.s2]
mode = sequential
members = fast_pass
EOF

RUN_DIR="$TMPDIR/run3"
mkdir -p "$RUN_DIR/meta" "$RUN_DIR/samples" "$RUN_DIR/modules" "$RUN_DIR/report"
: > "$RUN_DIR/meta/core.log"
config_parse "$TMPDIR/test3.cfg" "$RUN_DIR/meta/config.kv"
plan_expand "$RUN_DIR"

declare -A _PROBED_MODULES=()
_CLEANUP_DONE=0
declare -A _CLEANUP_REGISTRY=()

run_plan "$RUN_DIR" || true

# fast_fail should have run and failed
assert_file_exists "stop_on_fail: fail ran" "$RUN_DIR/modules/fast_fail/result.kv"
# fast_pass should NOT have run (s2 never reached)
assert_eq "stop_on_fail: pass not ran" "" "$(kv_read "$RUN_DIR/modules/fast_pass/result.kv" "status" "" 2>/dev/null || echo "")"

# Test 4: Disabled module
cat > "$TMPDIR/test4.cfg" << 'EOF'
[module_defaults]
duration_s = 1

[plan]
stages = s1

[stage.s1]
mode = sequential
members = fast_pass,fast_fail

[module.fast_fail]
enable = false
EOF

RUN_DIR="$TMPDIR/run4"
mkdir -p "$RUN_DIR/meta" "$RUN_DIR/samples" "$RUN_DIR/modules" "$RUN_DIR/report"
: > "$RUN_DIR/meta/core.log"
config_parse "$TMPDIR/test4.cfg" "$RUN_DIR/meta/config.kv"
plan_expand "$RUN_DIR"

declare -A _PROBED_MODULES=()
_CLEANUP_DONE=0
declare -A _CLEANUP_REGISTRY=()

run_plan "$RUN_DIR"

assert_eq "disabled: pass ran" "pass" "$(kv_read "$RUN_DIR/modules/fast_pass/result.kv" "status")"
# fast_fail should not have a result (disabled)
ff_status=$(kv_read "$RUN_DIR/modules/fast_fail/result.kv" "status" "" 2>/dev/null || echo "")
assert_eq "disabled: fail not ran" "" "$ff_status"

# Test 5: Overall scoring integration
RUN_DIR="$TMPDIR/run2"
kv_write "$RUN_DIR/meta/syshammer.kv" "version" "1.0.0"
score_overall "$RUN_DIR"
assert_eq "overall has status" "fail" "$(kv_read "$RUN_DIR/meta/syshammer.kv" "overall_status")"

echo ""
echo "test_runner: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
