#!/usr/bin/env bash
# test_ddr.sh - DDR module tests
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

MODULE="$VER1_DIR/modules/ddr/ddr.sh"

cat > "$TMPDIR/config.kv" << 'EOF'
module.ddr.workers=2
module.ddr.method=stream
EOF

# Test 1: Probe
mkdir -p "$TMPDIR/probe1"
bash "$MODULE" probe --out "$TMPDIR/probe1" --cfg "$TMPDIR/config.kv"
assert_eq "probe supports" "true" "$(kv_read "$TMPDIR/probe1/probe.kv" "supports")"

# Test 2: Run
mkdir -p "$TMPDIR/run1"
bash "$MODULE" run --out "$TMPDIR/run1" --duration 1 --cfg "$TMPDIR/config.kv" > "$TMPDIR/run1/stdout.log" 2>&1
grep -q "stream" "$TMPDIR/run1/stdout.log"
assert_eq "run uses stream method" "0" "$?"

# Test 3: Evaluate clean
mkdir -p "$TMPDIR/eval1"
echo "done" > "$TMPDIR/eval1/stdout.log"
DURATION=10 bash "$MODULE" evaluate --out "$TMPDIR/eval1" --cfg "$TMPDIR/config.kv"
local_fails=$(wc -l < "$TMPDIR/eval1/fails.kv" 2>/dev/null || echo "0")
assert_eq "clean eval" "0" "$local_fails"

# Test 4: Evaluate with hardware error
mkdir -p "$TMPDIR/eval2"
echo "done" > "$TMPDIR/eval2/stdout.log"
export FAKE_DMESG_OUTPUT="[  10.000] mce: Hardware Error detected"
DURATION=10 bash "$MODULE" evaluate --out "$TMPDIR/eval2" --cfg "$TMPDIR/config.kv"
unset FAKE_DMESG_OUTPUT
grep -q "IO_ERROR" "$TMPDIR/eval2/fails.kv"
assert_eq "hardware error detected" "0" "$?"

echo ""
echo "test_ddr: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
