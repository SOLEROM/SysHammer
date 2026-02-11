


Syshammer is a config-driven, root-run stress and validation orchestrator for Buildroot-based embedded Linux. It executes a user-defined plan composed of sequential and parallel stages, runs hardware-focused stress modules using mostly existing CLI tools (stress-ng allowed), records deterministic artifacts in a run directory, evaluates outcomes with a score-based model that logs every failure event, and generates a 100% offline HTML report. The system is designed for test-driven development so that each new module/tool can be validated on a host/CI environment before deployment to an embedded target.

1. Scope and module set (v1)
   Syshammer v1 focuses on: cpu, memory, ddr, flash, communications (outgoing stack: eth, wifi, ble), and communications (lower layers: spi, i2c). GPU/NPU is included only as an optional module placeholder. Each specific NPU family is implemented as a dedicated module (e.g., npu_rknn, npu_hailo) and is disabled/absent by default unless explicitly provided and enabled in config. All modules must support capability probing and “skip” outcomes when prerequisites are not met.

2. Runtime assumptions

* Target environment: Buildroot embedded Linux.
* Execution as root is assumed and required for some operations.
* Shell is “pinned from the right shell” (the project may assume a chosen shell via explicit shebangs); scripts must be explicit and consistent.
* External dependencies must be minimal; prefer standard utilities present in embedded images. Stress-ng is permitted. The system must degrade gracefully when optional tools are missing.

3. CLI interface
   syshammer --config <path> [--out <path>] [--tag <str>] [--debug] [--no-report] [--keep]

* --config: required input config file (INI-like).
* --out: optional output location. If omitted, output defaults to the current working directory under ./runs/<run_id>/. If provided and is an existing directory or ends with a slash, syshammer creates <out>/<run_id>/. Otherwise it uses exactly <out>/ as the run directory.
* --tag: optional string included in run id naming and stored in metadata.
* --debug: enables global debug mode (verbose logging, verbose tool flags when supported, live console streaming of tool output with module prefixes, preserve full logs, include additional metadata in report). Debug mode does not change scoring or pass/fail logic.
* --no-report: skip HTML generation but still produce all artifacts and results.
* --keep: retain any intermediate/raw artifacts (if later a “compact mode” is introduced).

4. Run directory layout and artifact model
   Each run produces a self-contained directory:
   runs/<run_id>/
   meta/
   syshammer.kv        version, build id, git hash (if), config path, config hash, debug flag, start/end timestamps
   platform.kv         uname, kernel cmdline, cpu model, nproc, mem size, mount info summary, key device inventory
   tools.kv            detected tools and versions (best-effort), plus missing optional tools list
   plan.kv             expanded execution plan with resolved durations, weights, stage membership, stage modes
   core.log            full orchestrator logs (always full, regardless of console verbosity)
   samples/
   system.csv          generic system sampler CSV across the run or across stages (timestamped)
   modules/<module_name>/
   probe.kv            probe results and inventory for the module
   stdout.log          module run stdout (full)
   stderr.log          module run stderr (full)
   module.csv          optional module-specific samples (timestamped)
   pids.kv             background PIDs started by the module (for cleanup)
   cleanup.log         cleanup actions
   result.kv           normalized module result (required keys)
   fails.kv            list of failure events (timestamped), each event recorded even if not fatal
   report/
   report.html         offline self-contained HTML report (inline css; no external resources)
   Syshammer must always write artifacts even on failures or interrupts. Orchestrator must trap INT/TERM/EXIT and run cleanup for any started modules.

5. Config file format (INI-like)
   Config is an INI-like file with these sections:
   [global]
   tag, sample_period_ms, stop_on_fail, report_embed_logs, report_log_tail_lines, out_dir (optional), debug (optional; CLI overrides)
   [module_defaults]
   duration_s (default), weight (default)
   [plan]
   stages=stage1,stage2,...
   [stage.<stage_name>]
   mode=parallel|sequential
   members=cpu,memory,ddr,flash,comm_eth,comm_wifi,comm_ble,bus_spi,bus_i2c,gpu,npu_rknn,...
   duration_s (optional default for members)
   timeout_s (optional hard timeout for the stage)
   [module.<name>]
   enable=true|false
   duration_s override (optional)
   weight override (optional)
   module-specific knobs (thresholds, targets, interface names, server IPs, etc.)
   Modules that require targets (e.g., i2c device addr, spi loopback, wifi iface) must support probe-time “supports=false” with reason when not configured.

6. Execution plan semantics (sequential + parallel)
   Syshammer resolves an execution plan from config:

* Stages execute in the order listed in [plan].stages.
* Each stage executes in either sequential or parallel mode.
  Sequential stage:
* For each module: probe (once per run), run, evaluate, cleanup, then next module.
  Parallel stage:
* Probe for all members (once per run), start runs for all supported+enabled members, monitor all, then evaluate all, then cleanup all.
* Console output in debug mode must be prefixed with module names to reduce interleaving confusion.
  Durations and timeouts:
* Each module has an intended duration_s (from module section, else stage default, else module_defaults).
* Each module run is also protected by a hard timeout (module-specific if introduced later, else stage timeout_s, else duration_s + safety margin). If the target system lacks GNU timeout, syshammer uses an internal watchdog loop to enforce timeouts and kill process groups.
  Interruptions:
* Any interruption triggers cleanup for all started modules and writes final metadata.

7. Module plugin contract (hard interface)
   Each module is implemented as modules/<name>/module.sh with subcommands:

* probe --out <dir> --cfg <flat_kv>
  Output: <out>/probe.kv with supports=true|false and reason if false. Must also include inventory keys relevant to the module (iface detected, device nodes present, etc.).
* run --out <dir> --duration <s> --cfg <flat_kv>
  Output: stdout.log, stderr.log, optional module.csv, pids.kv. Run should not decide pass/fail; it only executes stress and gathers raw measurements/logs.
* evaluate --out <dir> --cfg <flat_kv>
  Reads artifacts, applies thresholds, writes result.kv and fails.kv. Must be deterministic from files.
* cleanup --out <dir> --cfg <flat_kv>
  Uses pids.kv to stop background load, restores any tunables, writes cleanup.log.
  Orchestrator calls only these module subcommands. No direct tool calls in orchestrator beyond shared platform sampling and metadata.

8. Normalized results and failure logging
   result.kv required keys:
   status=pass|warn|fail|skip
   score=0..100
   weight=<int>
   errors=<int>
   warnings=<int>
   duration_s=<int>
   fail_codes=<csv_list>
   notes=<text>
   fails.kv format: one event per line, key=value pairs:
   ts=<unix_ms> code=<ID> sev=<warn|fail> detail=<text>
   Every detected failure condition must be recorded in fails.kv even if the module still “passes” overall. This enables score-based outcomes and forensic reporting. Modules must also record key computed metrics as key=value entries either in result.kv or in an additional metrics.kv (optional) that the report can include.

9. Scoring model
   Per-module scoring:

* Start at 100.
* For each fails.kv event with sev=warn deduct warn_penalty (default 5) up to a warn cap (default 30).
* For each fails.kv event with sev=fail deduct fail_penalty (default 20) up to 100.
* Certain fail codes are “hard fail” and force status=fail regardless of numeric score (default list includes: KERNEL_OOPS, OOM_KILL, IO_ERROR, DEVICE_RESET, LINK_DOWN_PERSIST, TIMEOUT).
* Status mapping defaults: hard-fail => fail; else score < 40 => fail; score < 70 => warn; else pass. These thresholds can be configurable later.
  Overall scoring:
* Weighted average over non-skip modules: sum(score * weight)/sum(weight).
* Overall status is the worst among modules (fail>warn>pass), ignoring skip.

10. Debug mode requirements
    --debug enables:

* Core debug logs to console plus always full logs to meta/core.log.
* Module and tool debug verbosity: modules must enable verbose flags for invoked tools where supported and print executed command lines.
* Live streaming of module run output to console, prefixed by module name; logs are still stored in module stdout/stderr logs.
* Additional metadata dumped into plan.kv and core.log (resolved durations, tool detection details, environment details). Debug mode never changes scoring, thresholds, or timeouts.

11. Generic system sampler
    Syshammer includes a generic sampler that periodically records:

* CPU usage from /proc/stat
* Memory usage from /proc/meminfo
* Thermal temps from /sys/class/thermal
* CPU frequency (best-effort) from cpufreq sysfs if present
  Sampler writes samples/system.csv with timestamps. Modules may add module.csv with their own samples. Sampling interval is global.sample_period_ms. In debug mode, the sampler may optionally print periodic summaries (configurable); regardless, it must record to CSV.

12. Module responsibilities for top areas
    cpu module:

* Stress via stress-ng cpu workers with load control and duration.
* Validation: temperature thresholds, throttle detection (frequency drops), dmesg/logread scan for lockups/thermal events.
  memory module:
* Stress via stress-ng vm workers with memory percentage allocation.
* Validation: OOM kill detection, memory error logs where available.
  ddr module:
* Stress via stress-ng memory/stream-like workloads (best-effort based on available stress-ng features).
* Validation: bandwidth/latency proxy checks if available; otherwise rely on stability and error log scanning.
  flash module:
* Prefer fio if available; otherwise dd + sync + optional verify.
* Validation: throughput floors, I/O errors, dmesg/logread scanning for storage errors.
  comm_eth/comm_wifi/comm_ble modules:
* Stress: ping/iperf3 where available; for wifi include RSSI and reconnect checks; for eth include link up and error counters.
* Validation: link stability, loss thresholds, tx/rx error deltas, driver resets in logs.
  bus_i2c/bus_spi modules:
* Probe: ensure configured target addresses/devices exist.
* Stress/validate: repeated transactions to configured devices or loopback; if not configured, skip with reason.

13. Report generation (offline HTML)
    HTML report is generated from meta/*.kv, samples/system.csv, and modules/*/result.kv + fails.kv. It is self-contained: inline CSS, no external resources, no JS required.
    Report content:

* Header summary: run id, tag, debug flag, platform summary, overall score/status, start/end times.
* Summary table per module: status, score, weight, warnings/errors, key metrics, fail codes, links to module sections.
* Per-module section: probe info, computed metrics, failures list, embedded log tail (normal mode) or full logs (debug mode), and links to raw log files in the run directory (relative paths).
  Log embedding rules:
* Normal mode: embed last global.report_log_tail_lines lines.
* Debug mode: embed full logs unless size becomes prohibitive; if size is too large, embed a larger tail and keep full logs as files.

14. TDD strategy and testing methodology
    Testing must validate correctness of: config parsing, plan expansion, stage runner semantics (parallel/sequential), timeout behavior, cleanup behavior, deterministic evaluation logic, scoring, and report generation.
    Test layering:
    A) Unit tests for core libraries

* Config parser tests: INI parsing into flat kv, correct precedence (CLI overrides config), correct defaults.
* Plan expander tests: stage ordering, resolved module durations/weights, correct handling of enable/supports/skip.
* Scoring tests: expected score deductions, hard-fail enforcement, overall weighted scoring.
* HTML generator tests: verify report contains expected fields and sections based on synthetic results.
  B) Module unit tests (host/CI)
  Each module must have tests that do not require real hardware:
* Use tests/fakebin/ to stub external commands (stress-ng, iperf3, iw, fio, dd, dmesg/logread, ip, ethtool). Stubs output deterministic text matching real tool patterns.
* Use tests/fakesys/ to provide a fake sysfs/proc tree (thermal zones, cpufreq, net stats). Module code must access sysfs/proc via helper functions that honor an injected SYSROOT or similar prefix so tests can redirect reads.
* Tests cover:

  1. probe parsing: supports true/false and reasons for skip
  2. run command composition: generated command lines (captured in logs) match expected flags, especially debug mode flags
  3. evaluate determinism: given canned logs/csv, result.kv and fails.kv match expected thresholds and failure codes
  4. cleanup correctness: kills listed PIDs (in tests, PIDs can be dummy and kill can be stubbed)
     C) Orchestrator integration tests (host/CI)
* Use a set of “fake modules” under tests/modules/ that implement the same contract but complete quickly and produce known artifacts.
* Validate:

  * run directory created correctly and contains required files
  * stage parallelism spawns multiple modules and waits correctly
  * stop_on_fail behavior works and still runs cleanup
  * interruption simulation triggers cleanup paths
  * report generation consumes produced results correctly
    Test execution environment
* Tests run with PATH prefixed by tests/fakebin so real system tools aren’t required.
* Tests run with SYSROOT pointing to tests/fakesys.
* Tests must not require root; any privileged operations are stubbed/mocked.
  Coverage goals
* Every module must ship with: at least one probe test, one evaluate test, one debug-mode run composition test.
* Core must ship with: config/plan/scoring/html unit tests and at least one integration test per stage mode.

15. Failure code taxonomy
    Define a shared namespace of failure codes to keep scoring/reporting consistent across modules:

* TIMEOUT
* TOOL_MISSING
* PERMISSION_DENIED
* KERNEL_OOPS
* OOM_KILL
* DEVICE_RESET
* IO_ERROR
* THERMAL_WARN
* THERMAL_FAIL
* THROTTLE_DETECTED
* LINK_DOWN_PERSIST
* PACKET_LOSS_HIGH
* RSSI_LOW
* RECONNECTS_HIGH
* BUS_XFER_FAIL
  Modules may add module-specific codes but must document them in module README and ensure evaluate emits them consistently.

16. Graceful degradation rules
    If a module cannot run due to missing tools or missing configuration targets, it must:

* set supports=false in probe.kv with a clear reason
* produce result.kv with status=skip and score omitted or score=0 with weight excluded from overall by orchestrator
  Overall scoring must ignore skip modules by default.

17. Versioning and reproducibility

* Syshammer writes its version and build id into meta/syshammer.kv.
* It computes and stores a config hash and stores expanded plan in meta/plan.kv so a run can be reproduced.
* In debug mode, syshammer records executed command lines for each module in core.log and/or module logs.

This specification is the contract the code bot should implement: a shell-based orchestrator with strict module interfaces, deterministic artifacts, score-based evaluation with explicit failure event logging, robust cleanup and timeouts, parallel/sequential stage plan execution, and a comprehensive test strategy using stubbed tools and fake sysfs/proc trees to allow CI-level validation before deployment to embedded targets.

