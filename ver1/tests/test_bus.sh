#!/usr/bin/env bash
# test_bus.sh - Bus modules tests (spi, i2c)
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

# --- bus_spi tests ---
SPI_MODULE="$VER1_DIR/modules/bus_spi/module.sh"

# Test 1: SPI probe without config -> skip
cat > "$TMPDIR/spi_config1.kv" << 'EOF'
module.bus_spi.weight=1
EOF
mkdir -p "$TMPDIR/spi_probe1"
bash "$SPI_MODULE" probe --out "$TMPDIR/spi_probe1" --cfg "$TMPDIR/spi_config1.kv"
assert_eq "spi probe no device" "false" "$(kv_read "$TMPDIR/spi_probe1/probe.kv" "supports")"

# Test 2: SPI probe with configured device (create a fake device file)
cat > "$TMPDIR/spi_config2.kv" << 'EOF'
module.bus_spi.device=/tmp/test_spidev
module.bus_spi.speed=1000000
module.bus_spi.iterations=3
module.bus_spi.weight=1
EOF
touch /tmp/test_spidev
mkdir -p "$TMPDIR/spi_probe2"
bash "$SPI_MODULE" probe --out "$TMPDIR/spi_probe2" --cfg "$TMPDIR/spi_config2.kv"
assert_eq "spi probe with device" "true" "$(kv_read "$TMPDIR/spi_probe2/probe.kv" "supports")"
rm -f /tmp/test_spidev

# Test 3: SPI evaluate clean
mkdir -p "$TMPDIR/spi_eval1"
echo "TX: 55 AA" > "$TMPDIR/spi_eval1/stdout.log"
echo "RX: 55 AA" >> "$TMPDIR/spi_eval1/stdout.log"
DURATION=5 bash "$SPI_MODULE" evaluate --out "$TMPDIR/spi_eval1" --cfg "$TMPDIR/spi_config2.kv"
local_fails=$(wc -l < "$TMPDIR/spi_eval1/fails.kv" 2>/dev/null || echo "0")
assert_eq "spi clean eval" "0" "$local_fails"

# Test 4: SPI evaluate with errors
mkdir -p "$TMPDIR/spi_eval2"
printf 'TX: 55 AA\nerror: SPI transfer failed\ntimeout on SPI\n' > "$TMPDIR/spi_eval2/stdout.log"
DURATION=5 bash "$SPI_MODULE" evaluate --out "$TMPDIR/spi_eval2" --cfg "$TMPDIR/spi_config2.kv"
grep -q "BUS_XFER_FAIL" "$TMPDIR/spi_eval2/fails.kv"
assert_eq "spi xfer fail detected" "0" "$?"

# --- bus_i2c tests ---
I2C_MODULE="$VER1_DIR/modules/bus_i2c/module.sh"

# Test 5: I2C probe without config -> skip
cat > "$TMPDIR/i2c_config1.kv" << 'EOF'
module.bus_i2c.weight=1
EOF
mkdir -p "$TMPDIR/i2c_probe1"
bash "$I2C_MODULE" probe --out "$TMPDIR/i2c_probe1" --cfg "$TMPDIR/i2c_config1.kv"
assert_eq "i2c probe no config" "false" "$(kv_read "$TMPDIR/i2c_probe1/probe.kv" "supports")"

# Test 6: I2C probe with config
cat > "$TMPDIR/i2c_config2.kv" << 'EOF'
module.bus_i2c.bus=0
module.bus_i2c.addr=0x50
module.bus_i2c.reg=0x00
module.bus_i2c.iterations=5
module.bus_i2c.weight=1
EOF
mkdir -p "$TMPDIR/i2c_probe2"
bash "$I2C_MODULE" probe --out "$TMPDIR/i2c_probe2" --cfg "$TMPDIR/i2c_config2.kv"
assert_eq "i2c probe with config" "true" "$(kv_read "$TMPDIR/i2c_probe2/probe.kv" "supports")"

# Test 7: I2C evaluate clean
mkdir -p "$TMPDIR/i2c_eval1"
echo "0x42" > "$TMPDIR/i2c_eval1/stdout.log"
echo "Completed 5 transactions, errors=0" >> "$TMPDIR/i2c_eval1/stdout.log"
DURATION=5 bash "$I2C_MODULE" evaluate --out "$TMPDIR/i2c_eval1" --cfg "$TMPDIR/i2c_config2.kv"
local_fails=$(wc -l < "$TMPDIR/i2c_eval1/fails.kv" 2>/dev/null || echo "0")
assert_eq "i2c clean eval" "0" "$local_fails"

echo ""
echo "test_bus: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
