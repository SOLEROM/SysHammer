#!/usr/bin/env bash
# test_scoring.sh - Scoring model unit tests
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

# Test 1: Perfect score (no failures)
mkdir -p "$TMPDIR/mod1"
: > "$TMPDIR/mod1/result.kv"
: > "$TMPDIR/mod1/fails.kv"
score_module "$TMPDIR/mod1"
assert_eq "perfect score" "100" "$(kv_read "$TMPDIR/mod1/result.kv" "score")"
assert_eq "perfect status" "pass" "$(kv_read "$TMPDIR/mod1/result.kv" "status")"

# Test 2: Warnings only (each -5, capped at 30)
mkdir -p "$TMPDIR/mod2"
: > "$TMPDIR/mod2/result.kv"
cat > "$TMPDIR/mod2/fails.kv" << 'EOF'
ts=1000 code=THERMAL_WARN sev=warn detail=warm
ts=1001 code=THERMAL_WARN sev=warn detail=warm2
ts=1002 code=THROTTLE_DETECTED sev=warn detail=throttle
EOF
score_module "$TMPDIR/mod2"
# 3 warnings * 5 = 15 deduction -> score=85
assert_eq "3 warnings score" "85" "$(kv_read "$TMPDIR/mod2/result.kv" "score")"
assert_eq "3 warnings status" "pass" "$(kv_read "$TMPDIR/mod2/result.kv" "status")"
assert_eq "3 warnings count" "3" "$(kv_read "$TMPDIR/mod2/result.kv" "warnings")"

# Test 3: Warning cap at 30
mkdir -p "$TMPDIR/mod3"
: > "$TMPDIR/mod3/result.kv"
: > "$TMPDIR/mod3/fails.kv"
for i in $(seq 1 10); do
    echo "ts=${i}000 code=THERMAL_WARN sev=warn detail=warm${i}" >> "$TMPDIR/mod3/fails.kv"
done
score_module "$TMPDIR/mod3"
# 10 warnings * 5 = 50, but capped at 30 -> score=70
assert_eq "warn cap score" "70" "$(kv_read "$TMPDIR/mod3/result.kv" "score")"
assert_eq "warn cap status" "pass" "$(kv_read "$TMPDIR/mod3/result.kv" "status")"

# Test 4: Fail events (-20 each)
mkdir -p "$TMPDIR/mod4"
: > "$TMPDIR/mod4/result.kv"
cat > "$TMPDIR/mod4/fails.kv" << 'EOF'
ts=1000 code=TOOL_ERROR sev=fail detail=error1
ts=1001 code=TOOL_ERROR sev=fail detail=error2
EOF
score_module "$TMPDIR/mod4"
# 2 fails * 20 = 40 deduction -> score=60
assert_eq "2 fails score" "60" "$(kv_read "$TMPDIR/mod4/result.kv" "score")"
assert_eq "2 fails status" "warn" "$(kv_read "$TMPDIR/mod4/result.kv" "status")"

# Test 5: Hard-fail code forces status=fail
mkdir -p "$TMPDIR/mod5"
: > "$TMPDIR/mod5/result.kv"
cat > "$TMPDIR/mod5/fails.kv" << 'EOF'
ts=1000 code=KERNEL_OOPS sev=fail detail=oops
EOF
score_module "$TMPDIR/mod5"
assert_eq "hard-fail status" "fail" "$(kv_read "$TMPDIR/mod5/result.kv" "status")"

# Test 6: Score below 40 -> fail
mkdir -p "$TMPDIR/mod6"
: > "$TMPDIR/mod6/result.kv"
: > "$TMPDIR/mod6/fails.kv"
for i in $(seq 1 4); do
    echo "ts=${i}000 code=TOOL_ERROR sev=fail detail=err${i}" >> "$TMPDIR/mod6/fails.kv"
done
score_module "$TMPDIR/mod6"
# 4 * 20 = 80 deduction -> score=20
assert_eq "low score" "20" "$(kv_read "$TMPDIR/mod6/result.kv" "score")"
assert_eq "low score status" "fail" "$(kv_read "$TMPDIR/mod6/result.kv" "status")"

# Test 7: Score between 40-69 -> warn
mkdir -p "$TMPDIR/mod7"
: > "$TMPDIR/mod7/result.kv"
cat > "$TMPDIR/mod7/fails.kv" << 'EOF'
ts=1000 code=TOOL_ERROR sev=fail detail=err1
ts=1001 code=TOOL_ERROR sev=fail detail=err2
ts=1002 code=THERMAL_WARN sev=warn detail=warm
EOF
score_module "$TMPDIR/mod7"
# 2*20 + 1*5 = 45 -> score=55
assert_eq "warn range score" "55" "$(kv_read "$TMPDIR/mod7/result.kv" "score")"
assert_eq "warn range status" "warn" "$(kv_read "$TMPDIR/mod7/result.kv" "status")"

# Test 8: Skip module not rescored
mkdir -p "$TMPDIR/mod8"
kv_write "$TMPDIR/mod8/result.kv" "status" "skip"
score_module "$TMPDIR/mod8"
assert_eq "skip preserved" "skip" "$(kv_read "$TMPDIR/mod8/result.kv" "status")"

# Test 9: Overall scoring
mkdir -p "$TMPDIR/run/meta" "$TMPDIR/run/modules/a" "$TMPDIR/run/modules/b" "$TMPDIR/run/modules/c"
: > "$TMPDIR/run/meta/syshammer.kv"

# Module a: pass, score=100, weight=2
kv_write "$TMPDIR/run/modules/a/result.kv" "status" "pass"
kv_write "$TMPDIR/run/modules/a/result.kv" "score" "100"
kv_write "$TMPDIR/run/modules/a/result.kv" "weight" "2"

# Module b: warn, score=60, weight=1
kv_write "$TMPDIR/run/modules/b/result.kv" "status" "warn"
kv_write "$TMPDIR/run/modules/b/result.kv" "score" "60"
kv_write "$TMPDIR/run/modules/b/result.kv" "weight" "1"

# Module c: skip (should be excluded)
kv_write "$TMPDIR/run/modules/c/result.kv" "status" "skip"
kv_write "$TMPDIR/run/modules/c/result.kv" "score" "0"
kv_write "$TMPDIR/run/modules/c/result.kv" "weight" "0"

score_overall "$TMPDIR/run"
# weighted avg = (100*2 + 60*1) / (2+1) = 260/3 = 86 (integer division)
assert_eq "overall score" "86" "$(kv_read "$TMPDIR/run/meta/syshammer.kv" "overall_score")"
assert_eq "overall status" "warn" "$(kv_read "$TMPDIR/run/meta/syshammer.kv" "overall_status")"
assert_eq "modules run" "2" "$(kv_read "$TMPDIR/run/meta/syshammer.kv" "modules_run")"
assert_eq "modules skipped" "1" "$(kv_read "$TMPDIR/run/meta/syshammer.kv" "modules_skipped")"

# Test 10: Overall with fail -> worst status is fail
kv_write "$TMPDIR/run/modules/b/result.kv" "status" "fail"
score_overall "$TMPDIR/run"
assert_eq "overall worst fail" "fail" "$(kv_read "$TMPDIR/run/meta/syshammer.kv" "overall_status")"

echo ""
echo "test_scoring: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
