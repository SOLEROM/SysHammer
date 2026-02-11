#!/usr/bin/env bash
# test_memory.sh - Memory module tests
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

MODULE="$VER1_DIR/modules/memory/module.sh"

cat > "$TMPDIR/config.kv" << 'EOF'
module.memory.workers=1
module.memory.vm_bytes=80%
module.memory.weight=2
EOF

# Test 1: Probe
mkdir -p "$TMPDIR/probe1"
bash "$MODULE" probe --out "$TMPDIR/probe1" --cfg "$TMPDIR/config.kv"
assert_eq "probe supports" "true" "$(kv_read "$TMPDIR/probe1/probe.kv" "supports")"
assert_eq "probe mem" "2048000" "$(kv_read "$TMPDIR/probe1/probe.kv" "mem_total_kb")"

# Test 2: Run produces output
mkdir -p "$TMPDIR/run1"
bash "$MODULE" run --out "$TMPDIR/run1" --duration 1 --cfg "$TMPDIR/config.kv" > "$TMPDIR/run1/stdout.log" 2>&1
grep -q "stress-ng" "$TMPDIR/run1/stdout.log"
assert_eq "run output" "0" "$?"

# Test 3: Evaluate clean run
mkdir -p "$TMPDIR/eval1"
echo "stress-ng: info: successful run completed" > "$TMPDIR/eval1/stdout.log"
DURATION=10 bash "$MODULE" evaluate --out "$TMPDIR/eval1" --cfg "$TMPDIR/config.kv"
local_fails=$(wc -l < "$TMPDIR/eval1/fails.kv" 2>/dev/null || echo "0")
assert_eq "clean eval no fails" "0" "$local_fails"

# Test 4: Evaluate with OOM in dmesg
mkdir -p "$TMPDIR/eval2"
echo "done" > "$TMPDIR/eval2/stdout.log"
export FAKE_DMESG_OUTPUT="[  50.000] Out of memory: Killed process 1234 (stress-ng)"
DURATION=10 bash "$MODULE" evaluate --out "$TMPDIR/eval2" --cfg "$TMPDIR/config.kv"
unset FAKE_DMESG_OUTPUT
grep -q "OOM_KILL" "$TMPDIR/eval2/fails.kv"
assert_eq "OOM detected" "0" "$?"

echo ""
echo "test_memory: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
