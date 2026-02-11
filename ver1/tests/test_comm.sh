#!/usr/bin/env bash
# test_comm.sh - Comm modules tests (eth, wifi, ble)
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

# --- comm_eth tests ---
ETH_MODULE="$VER1_DIR/modules/comm_eth/comm_eth.sh"

cat > "$TMPDIR/eth_config.kv" << 'EOF'
module.comm_eth.iface=eth0
module.comm_eth.target=8.8.8.8
module.comm_eth.max_loss_pct=5
EOF

# Test 1: eth probe with interface present
mkdir -p "$TMPDIR/eth_probe1"
bash "$ETH_MODULE" probe --out "$TMPDIR/eth_probe1" --cfg "$TMPDIR/eth_config.kv"
assert_eq "eth probe supports" "true" "$(kv_read "$TMPDIR/eth_probe1/probe.kv" "supports")"

# Test 2: eth probe with missing interface
cat > "$TMPDIR/eth_config2.kv" << 'EOF'
module.comm_eth.iface=eth99
module.comm_eth.target=8.8.8.8
EOF
mkdir -p "$TMPDIR/eth_probe2"
bash "$ETH_MODULE" probe --out "$TMPDIR/eth_probe2" --cfg "$TMPDIR/eth_config2.kv"
assert_eq "eth probe missing iface" "false" "$(kv_read "$TMPDIR/eth_probe2/probe.kv" "supports")"

# Test 3: eth run
mkdir -p "$TMPDIR/eth_run1"
bash "$ETH_MODULE" run --out "$TMPDIR/eth_run1" --duration 2 --cfg "$TMPDIR/eth_config.kv" > "$TMPDIR/eth_run1/stdout.log" 2>&1
grep -q "Ping Test\|ping" "$TMPDIR/eth_run1/stdout.log"
assert_eq "eth run output" "0" "$?"

# Test 4: eth evaluate with packet loss
mkdir -p "$TMPDIR/eth_eval1"
cat > "$TMPDIR/eth_eval1/stdout.log" << 'EOF'
PING 8.8.8.8 56(84) bytes of data
--- 8.8.8.8 ping statistics ---
10 packets transmitted, 8 received, 20% packet loss, time 10000ms
EOF
: > "$TMPDIR/eth_eval1/probe.kv"
DURATION=10 bash "$ETH_MODULE" evaluate --out "$TMPDIR/eth_eval1" --cfg "$TMPDIR/eth_config.kv"
grep -q "PACKET_LOSS_HIGH" "$TMPDIR/eth_eval1/fails.kv"
assert_eq "eth high loss detected" "0" "$?"

# --- comm_wifi tests ---
WIFI_MODULE="$VER1_DIR/modules/comm_wifi/comm_wifi.sh"

cat > "$TMPDIR/wifi_config.kv" << 'EOF'
module.comm_wifi.iface=wlan0
module.comm_wifi.target=8.8.8.8
module.comm_wifi.max_loss_pct=10
module.comm_wifi.rssi_warn_dbm=-75
EOF

# Test 5: wifi probe with interface
mkdir -p "$TMPDIR/wifi_probe1"
bash "$WIFI_MODULE" probe --out "$TMPDIR/wifi_probe1" --cfg "$TMPDIR/wifi_config.kv"
assert_eq "wifi probe supports" "true" "$(kv_read "$TMPDIR/wifi_probe1/probe.kv" "supports")"

# Test 6: wifi probe missing interface
cat > "$TMPDIR/wifi_config2.kv" << 'EOF'
module.comm_wifi.iface=wlan99
EOF
mkdir -p "$TMPDIR/wifi_probe2"
bash "$WIFI_MODULE" probe --out "$TMPDIR/wifi_probe2" --cfg "$TMPDIR/wifi_config2.kv"
assert_eq "wifi probe missing" "false" "$(kv_read "$TMPDIR/wifi_probe2/probe.kv" "supports")"

# --- comm_ble tests ---
BLE_MODULE="$VER1_DIR/modules/comm_ble/comm_ble.sh"

cat > "$TMPDIR/ble_config.kv" << 'EOF'
module.comm_ble.scan_cycles=2
EOF

# Test 7: ble probe
mkdir -p "$TMPDIR/ble_probe1"
bash "$BLE_MODULE" probe --out "$TMPDIR/ble_probe1" --cfg "$TMPDIR/ble_config.kv"
assert_eq "ble probe supports" "true" "$(kv_read "$TMPDIR/ble_probe1/probe.kv" "supports")"

# Test 8: ble evaluate clean
mkdir -p "$TMPDIR/ble_eval1"
echo "LE Scan done" > "$TMPDIR/ble_eval1/stdout.log"
DURATION=5 bash "$BLE_MODULE" evaluate --out "$TMPDIR/ble_eval1" --cfg "$TMPDIR/ble_config.kv"
local_fails=$(wc -l < "$TMPDIR/ble_eval1/fails.kv" 2>/dev/null || echo "0")
assert_eq "ble clean eval" "0" "$local_fails"

echo ""
echo "test_comm: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
