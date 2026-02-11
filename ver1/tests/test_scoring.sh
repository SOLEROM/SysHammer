#!/usr/bin/env bash
# test_scoring.sh - Status determination unit tests
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER1_DIR="$(dirname "$TESTS_DIR")"
source "$VER1_DIR/lib/common.sh"
source "$VER1_DIR/lib/config.sh"
source "$VER1_DIR/lib/scoring.sh"

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

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Test 1: No failures -> pass
mkdir -p "$TMPDIR/mod1"
: > "$TMPDIR/mod1/result.kv"
: > "$TMPDIR/mod1/fails.kv"
score_module "$TMPDIR/mod1"
assert_eq "no failures -> pass" "pass" "$(kv_read "$TMPDIR/mod1/result.kv" "status")"
assert_eq "no failures: 0 errors" "0" "$(kv_read "$TMPDIR/mod1/result.kv" "errors")"
assert_eq "no failures: 0 warnings" "0" "$(kv_read "$TMPDIR/mod1/result.kv" "warnings")"

# Test 2: Warnings only -> warn
mkdir -p "$TMPDIR/mod2"
: > "$TMPDIR/mod2/result.kv"
cat > "$TMPDIR/mod2/fails.kv" << 'EOF'
ts=1000 code=THERMAL_WARN sev=warn detail=warm
ts=1001 code=THERMAL_WARN sev=warn detail=warm2
ts=1002 code=THROTTLE_DETECTED sev=warn detail=throttle
EOF
score_module "$TMPDIR/mod2"
assert_eq "warnings only -> warn" "warn" "$(kv_read "$TMPDIR/mod2/result.kv" "status")"
assert_eq "warnings count" "3" "$(kv_read "$TMPDIR/mod2/result.kv" "warnings")"
assert_eq "warnings: 0 errors" "0" "$(kv_read "$TMPDIR/mod2/result.kv" "errors")"

# Test 3: Fail events -> fail
mkdir -p "$TMPDIR/mod3"
: > "$TMPDIR/mod3/result.kv"
cat > "$TMPDIR/mod3/fails.kv" << 'EOF'
ts=1000 code=TOOL_ERROR sev=fail detail=error1
ts=1001 code=TOOL_ERROR sev=fail detail=error2
EOF
score_module "$TMPDIR/mod3"
assert_eq "fail events -> fail" "fail" "$(kv_read "$TMPDIR/mod3/result.kv" "status")"
assert_eq "fail events: error count" "2" "$(kv_read "$TMPDIR/mod3/result.kv" "errors")"

# Test 4: Hard-fail code -> fail
mkdir -p "$TMPDIR/mod4"
: > "$TMPDIR/mod4/result.kv"
cat > "$TMPDIR/mod4/fails.kv" << 'EOF'
ts=1000 code=KERNEL_OOPS sev=fail detail=oops
EOF
score_module "$TMPDIR/mod4"
assert_eq "hard-fail -> fail" "fail" "$(kv_read "$TMPDIR/mod4/result.kv" "status")"
assert_eq "hard-fail: fail_codes" "KERNEL_OOPS" "$(kv_read "$TMPDIR/mod4/result.kv" "fail_codes")"

# Test 5: Mixed warn + fail -> fail
mkdir -p "$TMPDIR/mod5"
: > "$TMPDIR/mod5/result.kv"
cat > "$TMPDIR/mod5/fails.kv" << 'EOF'
ts=1000 code=THERMAL_WARN sev=warn detail=warm
ts=1001 code=TOOL_ERROR sev=fail detail=error1
EOF
score_module "$TMPDIR/mod5"
assert_eq "mixed -> fail" "fail" "$(kv_read "$TMPDIR/mod5/result.kv" "status")"
assert_eq "mixed: 1 warning" "1" "$(kv_read "$TMPDIR/mod5/result.kv" "warnings")"
assert_eq "mixed: 1 error" "1" "$(kv_read "$TMPDIR/mod5/result.kv" "errors")"

# Test 6: Skip module not rescored
mkdir -p "$TMPDIR/mod6"
kv_write "$TMPDIR/mod6/result.kv" "status" "skip"
score_module "$TMPDIR/mod6"
assert_eq "skip preserved" "skip" "$(kv_read "$TMPDIR/mod6/result.kv" "status")"

# Test 7: Overall status - all pass
mkdir -p "$TMPDIR/run1/meta" "$TMPDIR/run1/modules/a" "$TMPDIR/run1/modules/b"
: > "$TMPDIR/run1/meta/syshammer.kv"
kv_write "$TMPDIR/run1/modules/a/result.kv" "status" "pass"
kv_write "$TMPDIR/run1/modules/b/result.kv" "status" "pass"
score_overall "$TMPDIR/run1"
assert_eq "overall all pass" "pass" "$(kv_read "$TMPDIR/run1/meta/syshammer.kv" "overall_status")"
assert_eq "overall modules_run" "2" "$(kv_read "$TMPDIR/run1/meta/syshammer.kv" "modules_run")"

# Test 8: Overall status - worst is warn
mkdir -p "$TMPDIR/run2/meta" "$TMPDIR/run2/modules/a" "$TMPDIR/run2/modules/b" "$TMPDIR/run2/modules/c"
: > "$TMPDIR/run2/meta/syshammer.kv"
kv_write "$TMPDIR/run2/modules/a/result.kv" "status" "pass"
kv_write "$TMPDIR/run2/modules/b/result.kv" "status" "warn"
kv_write "$TMPDIR/run2/modules/c/result.kv" "status" "skip"
score_overall "$TMPDIR/run2"
assert_eq "overall worst warn" "warn" "$(kv_read "$TMPDIR/run2/meta/syshammer.kv" "overall_status")"
assert_eq "overall modules_run 2" "2" "$(kv_read "$TMPDIR/run2/meta/syshammer.kv" "modules_run")"
assert_eq "overall modules_skipped" "1" "$(kv_read "$TMPDIR/run2/meta/syshammer.kv" "modules_skipped")"

# Test 9: Overall status - worst is fail
kv_write "$TMPDIR/run2/modules/b/result.kv" "status" "fail"
score_overall "$TMPDIR/run2"
assert_eq "overall worst fail" "fail" "$(kv_read "$TMPDIR/run2/meta/syshammer.kv" "overall_status")"

# Test 10: fail_codes tracked correctly
mkdir -p "$TMPDIR/mod10"
: > "$TMPDIR/mod10/result.kv"
cat > "$TMPDIR/mod10/fails.kv" << 'EOF'
ts=1000 code=IO_ERROR sev=fail detail=io
ts=1001 code=DEVICE_RESET sev=warn detail=reset
EOF
score_module "$TMPDIR/mod10"
assert_eq "multiple codes" "IO_ERROR,DEVICE_RESET" "$(kv_read "$TMPDIR/mod10/result.kv" "fail_codes")"

echo ""
echo "test_scoring: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
