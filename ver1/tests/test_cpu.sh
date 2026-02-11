#!/usr/bin/env bash
# test_cpu.sh - CPU module tests
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER1_DIR="$(dirname "$TESTS_DIR")"

export PATH="$TESTS_DIR/fakebin:$PATH"
export SYSROOT="$TESTS_DIR/fakesys"
export LOGREAD_CMD="dmesg"
export DEBUG=0

source "$VER1_DIR/lib/common.sh"

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

MODULE="$VER1_DIR/modules/cpu/module.sh"

# Create config kv
cat > "$TMPDIR/config.kv" << 'EOF'
module.cpu.workers=2
module.cpu.temp_warn_c=80
module.cpu.temp_fail_c=95
EOF

# Test 1: Probe with stress-ng available
mkdir -p "$TMPDIR/probe1"
bash "$MODULE" probe --out "$TMPDIR/probe1" --cfg "$TMPDIR/config.kv"
assert_eq "probe supports" "true" "$(kv_read "$TMPDIR/probe1/probe.kv" "supports")"
assert_eq "probe tool" "stress-ng" "$(kv_read "$TMPDIR/probe1/probe.kv" "tool")"

# Test 2: Run generates output
mkdir -p "$TMPDIR/run1"
bash "$MODULE" run --out "$TMPDIR/run1" --duration 1 --cfg "$TMPDIR/config.kv" > "$TMPDIR/run1/stdout.log" 2>&1
assert_eq "run has output" "true" "$([ -s "$TMPDIR/run1/stdout.log" ] && echo true || echo false)"
# Verify command line contains workers
grep -q "stress-ng" "$TMPDIR/run1/stdout.log"
assert_eq "run mentions stress-ng" "0" "$?"

# Test 3: Debug mode run
mkdir -p "$TMPDIR/run_debug"
DEBUG=1 bash "$MODULE" run --out "$TMPDIR/run_debug" --duration 1 --cfg "$TMPDIR/config.kv" > "$TMPDIR/run_debug/stdout.log" 2>&1
grep -q "\-\-verbose" "$TMPDIR/run_debug/stdout.log"
assert_eq "debug mode verbose flag" "0" "$?"
DEBUG=0

# Test 4: Evaluate with normal temps (45C from fakesys)
mkdir -p "$TMPDIR/eval1"
echo "stress-ng: info: successful run completed" > "$TMPDIR/eval1/stdout.log"
DURATION=30 bash "$MODULE" evaluate --out "$TMPDIR/eval1" --cfg "$TMPDIR/config.kv"
# 45C is well below 80C warn threshold
local_fails=$(wc -l < "$TMPDIR/eval1/fails.kv" 2>/dev/null || echo "0")
assert_eq "normal temp no fails" "0" "$local_fails"

# Test 5: Evaluate with high temp
mkdir -p "$TMPDIR/eval2"
echo "stress-ng: info: done" > "$TMPDIR/eval2/stdout.log"
# Override thermal zone
orig_temp=$(cat "$SYSROOT/sys/class/thermal/thermal_zone0/temp")
echo "85000" > "$SYSROOT/sys/class/thermal/thermal_zone0/temp"
DURATION=30 bash "$MODULE" evaluate --out "$TMPDIR/eval2" --cfg "$TMPDIR/config.kv"
echo "$orig_temp" > "$SYSROOT/sys/class/thermal/thermal_zone0/temp"
grep -q "THERMAL_WARN" "$TMPDIR/eval2/fails.kv"
assert_eq "high temp warning" "0" "$?"

# Test 6: Evaluate with kernel oops in dmesg
mkdir -p "$TMPDIR/eval3"
echo "stress-ng: info: done" > "$TMPDIR/eval3/stdout.log"
export FAKE_DMESG_OUTPUT="[  100.000] Oops: kernel BUG at mm/page_alloc.c:1234"
DURATION=30 bash "$MODULE" evaluate --out "$TMPDIR/eval3" --cfg "$TMPDIR/config.kv"
unset FAKE_DMESG_OUTPUT
grep -q "KERNEL_OOPS" "$TMPDIR/eval3/fails.kv"
assert_eq "kernel oops detected" "0" "$?"

# Test 7: Cleanup runs without error
mkdir -p "$TMPDIR/clean1"
echo "stress_ng=99999" > "$TMPDIR/clean1/pids.kv"
bash "$MODULE" cleanup --out "$TMPDIR/clean1" --cfg "$TMPDIR/config.kv" > /dev/null 2>&1
assert_eq "cleanup succeeds" "0" "$?"

echo ""
echo "test_cpu: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
