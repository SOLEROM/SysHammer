# sysHammer

Config-driven stress-testing and hardware validation orchestrator for embedded Linux systems. Pure bash, no Python/Perl dependencies.

sysHammer runs a configurable sequence of hardware stress tests (CPU, memory, storage, networking, buses), monitors system health throughout, scores each subsystem, and produces a self-contained HTML report.

## Quick Start

```bash
# Make the CLI executable
chmod +x ver1/syshammer

# Run with the example config
ver1/syshammer --config ver1/examples/basic.cfg

# Run with a custom output directory and tag
ver1/syshammer --config my_board.cfg --out /tmp/results --tag rk3588_dvt --debug
```

## CLI Usage

```
syshammer --config <path> [--out <path>] [--tag <str>] [--debug] [--no-report] [--keep]

Options:
  --config <path>   Config file (required)
  --out <path>      Output directory (default: ./runs/<run_id>/)
  --tag <str>       Tag included in run ID and metadata
  --debug           Verbose logging, full log embedding in report
  --no-report       Skip HTML report generation
  --keep            Retain intermediate artifacts
```

Exit code: `0` for pass/warn, `1` for fail.

## Configuration

sysHammer uses an INI-style config file. See `ver1/examples/basic.cfg` for a complete example.

### Sections

**`[global]`** - Top-level settings:
| Key | Default | Description |
|-----|---------|-------------|
| `tag` | | Run identifier tag |
| `sample_period_ms` | `1000` | System sampling interval |
| `stop_on_fail` | `false` | Halt on first stage failure |
| `report_embed_logs` | `true` | Embed log tails in HTML report |
| `report_log_tail_lines` | `50` | Lines of log to embed per module |

**`[module_defaults]`** - Defaults applied to all modules:
| Key | Default | Description |
|-----|---------|-------------|
| `duration_s` | `30` | Test duration in seconds |
| `weight` | `1` | Scoring weight |

**`[plan]`** - Test plan:
```ini
[plan]
stages = stress_seq,io_parallel,comms
```

**`[stage.<name>]`** - Stage definition:
```ini
[stage.stress_seq]
mode = sequential        # sequential or parallel
members = cpu,memory,ddr
timeout_s = 120          # optional hard timeout per module
```

**`[module.<name>]`** - Per-module overrides (see Modules below for keys).

### Example

```ini
[global]
tag = dvt_board_01
stop_on_fail = false

[module_defaults]
duration_s = 30

[plan]
stages = stress,io

[stage.stress]
mode = parallel
members = cpu,memory

[stage.io]
mode = sequential
members = flash,comm_eth

[module.cpu]
duration_s = 60
weight = 3
workers = 0
temp_warn_c = 80

[module.flash]
test_dir = /tmp
bs = 4k
size = 64m
```

## Modules

Each module implements four subcommands: `probe` (detect hardware), `run` (execute stress), `evaluate` (check results), and `cleanup`.

| Module | Tool(s) | What it tests | Key config |
|--------|---------|---------------|------------|
| **cpu** | stress-ng | CPU compute stress, thermal, throttle | `workers`, `temp_warn_c`, `temp_fail_c` |
| **memory** | stress-ng | VM pressure, OOM detection | `workers`, `vm_bytes` |
| **ddr** | stress-ng | Memory bandwidth (stream/memcpy) | `workers`, `method` |
| **flash** | fio / dd | Storage I/O, data verification | `test_dir`, `bs`, `size` |
| **comm_eth** | ping, iperf3 | Ethernet connectivity, throughput, link errors | `iface`, `target`, `iperf_server`, `max_loss_pct` |
| **comm_wifi** | iw, ping, iperf3 | Wi-Fi connectivity, RSSI, reconnects | `iface`, `target`, `iperf_server`, `rssi_warn_dbm` |
| **comm_ble** | hcitool / bluetoothctl | BLE adapter scan stress | `hci_dev`, `scan_cycles` |
| **bus_spi** | spidev_test | SPI loopback transactions | `device`, `speed`, `iterations` |
| **bus_i2c** | i2cget | I2C read transactions | `bus`, `addr`, `reg`, `iterations` |
| **gpu** | *(placeholder)* | Skipped unless explicitly enabled | `enable` |
| **npu_rknn** | *(placeholder)* | Skipped unless explicitly enabled | `enable` |

Modules gracefully skip when their required tools or hardware are not present.

## Scoring

Each module starts at 100 points. Deductions are applied based on failure events detected during evaluation:

| Severity | Deduction | Cap |
|----------|-----------|-----|
| `warn` | -5 | -30 total |
| `fail` | -20 | -100 total |

Hard-fail codes (automatic score = 0): `KERNEL_OOPS`, `OOM_KILL`, `IO_ERROR`, `DEVICE_RESET`, `LINK_DOWN_PERSIST`, `TIMEOUT`.

Overall score is a weighted average across all non-skipped modules. Final status:
- **pass**: score >= 70, no hard-fail
- **warn**: score >= 40, no hard-fail
- **fail**: score < 40 or any hard-fail

## Output Artifacts

Each run produces a timestamped directory:

```
runs/syshammer_<tag>_<timestamp>_<rand>/
  meta/
    syshammer.kv          # Run metadata (version, timestamps, overall score)
    config.kv             # Flattened config
    platform.kv           # Platform info (CPU, memory, kernel, mounts)
    tools.kv              # Detected tools and versions
    plan.kv               # Expanded test plan
    core.log              # Orchestrator log
  samples/
    system.csv            # Time-series: CPU%, memory, temperature, frequency
  modules/
    <name>/
      probe.kv            # Probe results
      stdout.log          # Module stdout/stderr
      result.kv           # Score, status, duration, weight
      fails.kv            # Failure events (if any)
      pids.kv             # PIDs tracked during run
  report/
    report.html           # Self-contained HTML report (inline CSS, no JS)
```

## Background Sampling

sysHammer runs a background sampler during test execution that captures system metrics at a configurable interval:

- CPU utilization (from `/proc/stat`)
- Memory usage (from `/proc/meminfo`)
- Thermal zone temperature (from `/sys/class/thermal/`)
- CPU frequency (from `/sys/devices/system/cpu/`)

Data is written to `samples/system.csv` and included in the HTML report.

## Running Tests

```bash
bash ver1/tests/run_tests.sh
```

The test suite uses fake binaries (`tests/fakebin/`) and a fake sysfs/proc tree (`tests/fakesys/`) so tests run on any machine without real hardware or stress tools.

## Requirements

- **bash** >= 4.0 (for associative arrays)
- **coreutils**: date, mktemp, md5sum/sha256sum, od, wc, sort, head, tail
- **Optional tools** (modules skip gracefully if missing):
  - `stress-ng` - CPU, memory, DDR modules
  - `fio` - flash module (falls back to `dd` if missing)
  - `ping` - ethernet and Wi-Fi modules
  - `iperf3` - throughput testing (optional for comm modules)
  - `iw` / `iwconfig` - Wi-Fi module
  - `hcitool` / `bluetoothctl` - BLE module
  - `i2cget` - I2C bus module
  - `spidev_test` - SPI bus module
  - `ethtool` - extended ethernet diagnostics

## Project Layout

```
ver1/
  syshammer              # Main CLI entry point
  lib/                   # Core libraries
    common.sh            # Logging, kv operations, utilities
    config.sh            # INI config parser
    plan.sh              # Plan expansion
    platform.sh          # Platform detection
    tools.sh             # Tool detection
    runner.sh            # Stage executor (sequential + parallel)
    sampler.sh           # Background system sampler
    scoring.sh           # Score calculation
    report.sh            # HTML report generator
    cleanup.sh           # Trap handling, cleanup orchestration
  modules/               # Hardware test modules
    cpu/  memory/  ddr/  flash/
    comm_eth/  comm_wifi/  comm_ble/
    bus_spi/  bus_i2c/
    gpu/  npu_rknn/
  tests/                 # Test suite
    run_tests.sh         # Test runner
    fakebin/             # Stubbed CLI tools
    fakesys/             # Fake /proc and /sys trees
  examples/
    basic.cfg            # Full example config
```
