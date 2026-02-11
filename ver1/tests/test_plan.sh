#!/usr/bin/env bash
# test_plan.sh - Plan expander unit tests
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER1_DIR="$(dirname "$TESTS_DIR")"
source "$VER1_DIR/lib/common.sh"
source "$VER1_DIR/lib/config.sh"
source "$VER1_DIR/lib/plan.sh"

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

# Test 1: Basic plan expansion
cat > "$TMPDIR/test.cfg" << 'EOF'
[module_defaults]
duration_s = 30
weight = 1

[plan]
stages = stress,comms

[stage.stress]
mode = parallel
members = cpu,memory

[stage.comms]
mode = sequential
members = comm_eth
duration_s = 20

[module.cpu]
duration_s = 60
weight = 3

[module.memory]
weight = 2
EOF

mkdir -p "$TMPDIR/run/meta"
config_parse "$TMPDIR/test.cfg" "$TMPDIR/run/meta/config.kv"
RUN_DIR="$TMPDIR/run"
plan_expand "$TMPDIR/run"

local_plan="$TMPDIR/run/meta/plan.kv"

assert_eq "stages" "stress,comms" "$(kv_read "$local_plan" "stages")"
assert_eq "stage_count" "2" "$(kv_read "$local_plan" "stage_count")"
assert_eq "stress mode" "parallel" "$(kv_read "$local_plan" "stage.stress.mode")"
assert_eq "comms mode" "sequential" "$(kv_read "$local_plan" "stage.comms.mode")"

# CPU: duration from module (60), weight from module (3)
assert_eq "cpu duration" "60" "$(kv_read "$local_plan" "stage.stress.module.cpu.duration_s")"
assert_eq "cpu weight" "3" "$(kv_read "$local_plan" "stage.stress.module.cpu.weight")"

# Memory: duration from default (30), weight from module (2)
assert_eq "memory duration" "30" "$(kv_read "$local_plan" "stage.stress.module.memory.duration_s")"
assert_eq "memory weight" "2" "$(kv_read "$local_plan" "stage.stress.module.memory.weight")"

# comm_eth: duration from stage (20), weight from default (1)
assert_eq "eth duration" "20" "$(kv_read "$local_plan" "stage.comms.module.comm_eth.duration_s")"
assert_eq "eth weight" "1" "$(kv_read "$local_plan" "stage.comms.module.comm_eth.weight")"

# Timeout: cpu should be 60+30=90
assert_eq "cpu timeout" "90" "$(kv_read "$local_plan" "stage.stress.module.cpu.timeout_s")"

# Test 2: Disabled module
cat > "$TMPDIR/test2.cfg" << 'EOF'
[module_defaults]
duration_s = 10

[plan]
stages = s1

[stage.s1]
mode = sequential
members = cpu,gpu

[module.gpu]
enable = false
EOF

mkdir -p "$TMPDIR/run2/meta"
config_parse "$TMPDIR/test2.cfg" "$TMPDIR/run2/meta/config.kv"
RUN_DIR="$TMPDIR/run2"
plan_expand "$TMPDIR/run2"

local_plan2="$TMPDIR/run2/meta/plan.kv"
assert_eq "gpu disabled" "disabled" "$(kv_read "$local_plan2" "stage.s1.module.gpu.status")"
assert_eq "cpu pending" "pending" "$(kv_read "$local_plan2" "stage.s1.module.cpu.status")"

# Test 3: Stage timeout propagation
cat > "$TMPDIR/test3.cfg" << 'EOF'
[module_defaults]
duration_s = 10

[plan]
stages = s1

[stage.s1]
mode = parallel
members = cpu,memory
timeout_s = 120
EOF

mkdir -p "$TMPDIR/run3/meta"
config_parse "$TMPDIR/test3.cfg" "$TMPDIR/run3/meta/config.kv"
RUN_DIR="$TMPDIR/run3"
plan_expand "$TMPDIR/run3"

local_plan3="$TMPDIR/run3/meta/plan.kv"
assert_eq "cpu timeout from stage" "120" "$(kv_read "$local_plan3" "stage.s1.module.cpu.timeout_s")"
assert_eq "memory timeout from stage" "120" "$(kv_read "$local_plan3" "stage.s1.module.memory.timeout_s")"

echo ""
echo "test_plan: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
