#!/usr/bin/env bash
# test_config.sh - Config parser unit tests
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER1_DIR="$(dirname "$TESTS_DIR")"
source "$VER1_DIR/lib/common.sh"
source "$VER1_DIR/lib/config.sh"

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

# Test 1: Basic INI parsing
cat > "$TMPDIR/test1.cfg" << 'EOF'
[global]
tag = test_run
debug = 0
sample_period_ms = 500

[module_defaults]
duration_s = 30
weight = 1

[plan]
stages = stage1,stage2

[stage.stage1]
mode = sequential
members = cpu,memory

[module.cpu]
duration_s = 60
workers = 4
EOF

config_parse "$TMPDIR/test1.cfg" "$TMPDIR/test1.kv"

assert_eq "global.tag" "test_run" "$(config_get "global.tag")"
assert_eq "global.debug" "0" "$(config_get "global.debug")"
assert_eq "global.sample_period_ms" "500" "$(config_get "global.sample_period_ms")"
assert_eq "module_defaults.duration_s" "30" "$(config_get "module_defaults.duration_s")"
assert_eq "module_defaults.weight" "1" "$(config_get "module_defaults.weight")"
assert_eq "plan.stages" "stage1,stage2" "$(config_get "plan.stages")"
assert_eq "stage.stage1.mode" "sequential" "$(config_get "stage.stage1.mode")"
assert_eq "stage.stage1.members" "cpu,memory" "$(config_get "stage.stage1.members")"
assert_eq "module.cpu.duration_s" "60" "$(config_get "module.cpu.duration_s")"
assert_eq "module.cpu.workers" "4" "$(config_get "module.cpu.workers")"

# Test 2: Default values
assert_eq "missing key default" "fallback" "$(config_get "nonexistent.key" "fallback")"
assert_eq "missing key empty default" "" "$(config_get "nonexistent.key" "")"

# Test 3: Comments and blank lines
cat > "$TMPDIR/test2.cfg" << 'EOF'
# This is a comment
; This is also a comment

[global]
tag = with_comments

# Another comment
debug = 1
EOF

config_parse "$TMPDIR/test2.cfg" "$TMPDIR/test2.kv"
assert_eq "comment handling tag" "with_comments" "$(config_get "global.tag")"
assert_eq "comment handling debug" "1" "$(config_get "global.debug")"

# Test 4: CLI overrides
config_apply_overrides "$TMPDIR/test2.kv" "global.debug=0" "global.tag=overridden"
assert_eq "override debug" "0" "$(config_get "global.debug")"
assert_eq "override tag" "overridden" "$(config_get "global.tag")"

# Test 5: Whitespace handling
cat > "$TMPDIR/test3.cfg" << 'EOF'
[global]
  tag  =  spaced_value
  debug=no_spaces
EOF

config_parse "$TMPDIR/test3.cfg" "$TMPDIR/test3.kv"
assert_eq "whitespace key" "spaced_value" "$(config_get "global.tag")"
assert_eq "no spaces" "no_spaces" "$(config_get "global.debug")"

# Test 6: Module-specific knobs
cat > "$TMPDIR/test4.cfg" << 'EOF'
[module.comm_eth]
iface = eth1
target = 192.168.1.1
max_loss_pct = 3

[module.bus_i2c]
bus = 1
addr = 0x50
reg = 0x00
EOF

config_parse "$TMPDIR/test4.cfg" "$TMPDIR/test4.kv"
assert_eq "eth iface" "eth1" "$(config_get "module.comm_eth.iface")"
assert_eq "eth target" "192.168.1.1" "$(config_get "module.comm_eth.target")"
assert_eq "i2c bus" "1" "$(config_get "module.bus_i2c.bus")"
assert_eq "i2c addr" "0x50" "$(config_get "module.bus_i2c.addr")"

echo ""
echo "test_config: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
