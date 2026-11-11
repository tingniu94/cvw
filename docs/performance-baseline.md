# CV-Wally Performance Baseline

## Result and scope

**PASS**: Phase1 Normal / CPU Reset Abort / Pending-at-normal-end directed tests; Original vs Step2 Hello baseline; independent VCD replay; input/source/instrumentation checks; zero build warnings; `git diff --check`.

Original `be4b5af64c7ad1bb361636ade49bdfeb43bd847d` and combinational A-only Step2 Guard `8ff5bf2471d51e45a3317768e04aac4bb97d3ee0` have identical measured metrics under this Hello/rv64gc simulation: **0 cycles / 0% overhead**. No test conditions or functional RTL changed to force equality.

Active branch remains `ahb-lockstep-step3`, HEAD `0837d6a98cb6fbc038c5dad3f18f09d59101eac0`. No commit/push, Git configuration changes, checkout, stash, reset or clean. Existing config edits and untracked artifacts preserved. Main baseline artifacts: `artifacts/performance-baseline/run-005/`; new unit evidence: `run-004/`. Earlier runs remain historical evidence.

## Architecture / instrumentation design

`testbench/common/performance_monitor.sv` is a passive observer instantiated in `testbench/testbench.sv`. CPU/EBU/Guard functional RTL are untouched. Integration currently supports RV64 configurations with Zicsr and at least three counters. CSR ports are 64-bit; the stored address is zero-extended from the unsigned PA_BITS bus into the monitor's XLEN-width address storage, without loss. No new warning suppression added; pre-existing repository lint directives/compiler flags remain inherited.

ROI ID: `reset_release_to_tb_complete_v1`. All counters sample rising-edge **pre-NBA** values. After observing CPU reset asserted, S is the first edge with reset=0, included. E is the first edge with `CurrState == STATE_RUN_TEST && TestComplete`, excluded. Counter interval is S <= edge < E; `$finish` is outside ROI. Dynamic signals determine boundaries; no historical timestamp is hard-coded in the monitor.

CPU cycles increment once per included edge. Retirement uses the RTL's `dut.core.priv.priv.csr.InstrValidNotFlushedM = InstrValidM & ~StallW & ~FlushW`. Stage stalls are `dut.core.StallF/D/E/M/W`; any-stall is their OR counted once per edge, not their sum. CPI=cycles/retired. Exported ratios use zero for a zero denominator; consumers must treat that case as undefined.

AHB observation uses SoC downstream bus signals and `dut.HRESP`, identical observation point in both baselines. Acceptance is HRESETn && HREADY && HTRANS[1]. Store accepted address/control, process old pending data completion before accepting the next address on the same edge. Pending && !HREADY counts a wait. Completion requires pending && HREADY and uses saved read/write control. Error is counted only at completion. IDLE/BUSY do not accept; each NONSEQ/SEQ burst beat is measured separately. Completed latency is completion edge index minus acceptance edge index, with assertion latency=1+waits (minimum1). Completed min/max/mean exclude unfinished/cancelled beats.

Bus reset cancels pending. CPU reset during active ROI aborts the measurement, cancels pending and freezes partial evidence; aborted=1 must disqualify it from performance comparison. Normal E preserves pending_at_end, does not complete/cancel it and does not count that edge's stalls/address. Conservation: accepted = completed + cancelled + pending_at_end. Report emits once and remains frozen.

CSR cross-validation snapshots mcycle/minstret at S and E, records inhibit/write edges, and checks each prior included edge's expected increment at the following edge. A prior CSR software write disables that update comparison. Raw delta is valid only with no writes/inhibition; independent edge/retirement counters remain primary. Abort reports are partial invalid data and emitted before reset NBA updates, not post-reset CSR values.

## Phase2 preflight / isolation / provenance

The two commits have byte-identical uninstrumented testbenches (SHA256 `e409c87f1bbc46e9826d8d8b3be40c7a9e8cb6431281dea3c9d9a711a54e9705`), matching reset FSM/clock and common retirement/stall/CSR hierarchy. Step2 routes core A through `ahb_shared_guard` and adds the older passive AHB logger; no hierarchy adapter needed for the performance monitor. Its older logger remains part of the Step2 source; console logging is not a CPU cycle metric.

`tests/performance/run_baseline.py` uses `git archive` to materialize independent source directories under run-005/original/source and step2/source. This is the worktree-equivalent isolation method: no `.git` writes. The exact recorded Ethernet submodule `c180b22ed5f4112d0ef35b2c5ac1acc45f9ebb5d` is also archived locally, without network or submodule updates. Other submodules are not used by this Hello build.

Uncommitted instrumentation is safely snapshotted as the common monitor, exact integration block (including trailing blank line), and tested unit bench. Aggregate instrumentation hash is SHA256 of sorted JSON mapping snapshot filenames to SHA256:

`527ba6cae304931cb87746e12c6cae8be20f956f0daf57f8e789111eb926f6b7`

Monitor SHA256 remains `ede43fd4d71d208229694880726c46e2921a6380b5121d508cd1fc712501219a`. Both baselines receive the exact same block and monitor bytes. Each manifest records source commit, archives, configuration and all materialized source hashes. Post-simulation validation rechecks sources, snapshots and inputs. `config/rv64gc` and `config/shared` hashes agree.

Both simulations use the same absolute `run-005/inputs/hello` prefix. Files copied with original mtimes from existing `examples/C/hello/`; ELF not rebuilt. ELF is the testbench's filename anchor, memfile supplies RAM contents, addr/lab supply labels; objdump is also retained as generation provenance. Existing testbench make checks remain enabled; before/after hashes prove no input regeneration changed content. rv64gc BOOTROM_PRELOAD/UNCORE_RAM_PRELOAD are disabled; no additional external boot data loaded on this path.

| Input | SHA256 |
|---|---|
| hello ELF | `74198d087f8899de0c96f205cba1c12f270da7265508e17038a6ad1000e276e8` |
| hello.memfile | `4928503ce15d41c9d793dd802eb8c53f738c98f27af51ad85fe05496e603084a` |
| hello.objdump | `78195e669c3712c6918281b4224b440fdfb556739302dbf29051ece57e8de6be` |
| hello.objdump.addr | `f20379f23e47ea2e180a64a0341c13c4310217e016129ed3c6cd881c188ed893` |
| hello.objdump.lab | `53a987ed3713d6eca84fbd2667068388b13d680e57271b0e12ab9a7061b49e2d` |

## Environment and actual commands

Verilator `5.036 2025-04-27 rev v5.036`; exact C++/make/Python versions saved in run-005/toolchain.json. rv64gc, clock high/low5ps, period10ps, explicit timing/assert, timescale1ps/1ps, VCD enabled in both. Run commands from repository root unless annotated.

```bash
mkdir -p artifacts/performance-baseline/run-004/unit-normal artifacts/performance-baseline/run-004/unit-abort artifacts/performance-baseline/run-004/unit-pending
verilator --binary --trace --timing --assert --timescale 1ps/1ps --top-module performance_monitor_tb --Mdir artifacts/performance-baseline/run-004/work-unit testbench/common/performance_monitor.sv tests/performance/performance_monitor_tb.sv > artifacts/performance-baseline/run-004/unit-build.log 2>&1
# Same build rerun outside sandbox after ccache read-only failure;
# successful output: run-004/unit-build-escalated.log.
# Each command below executes in its respective run-004/unit-* directory:
../work-unit/Vperformance_monitor_tb +PERFORMANCE_JSON=performance.json > simulation.log 2>&1
../work-unit/Vperformance_monitor_tb +PERFORMANCE_JSON=performance.json +ABORT > simulation.log 2>&1
../work-unit/Vperformance_monitor_tb +PERFORMANCE_JSON=performance.json +PENDING_END > simulation.log 2>&1

mkdir -p artifacts/performance-baseline/run-005
python3 tests/performance/run_baseline.py artifacts/performance-baseline/run-005 prepare
python3 tests/performance/run_baseline.py artifacts/performance-baseline/run-005 build --version original
python3 tests/performance/run_baseline.py artifacts/performance-baseline/run-005 build --version step2
python3 tests/performance/run_baseline.py artifacts/performance-baseline/run-005 simulate --version original
python3 tests/performance/run_baseline.py artifacts/performance-baseline/run-005 simulate --version step2
python3 tests/performance/verify_waveform.py artifacts/performance-baseline/run-005/original/runtime > artifacts/performance-baseline/run-005/original/waveform-check.log 2>&1
python3 tests/performance/verify_waveform.py artifacts/performance-baseline/run-005/step2/runtime > artifacts/performance-baseline/run-005/step2/waveform-check.log 2>&1
python3 tests/performance/summarize_performance.py artifacts/performance-baseline/run-005 > artifacts/performance-baseline/run-005/comparison-check.log 2>&1
python3 -m py_compile tests/performance/run_baseline.py tests/performance/summarize_performance.py

git diff --check
```

Each baseline build script invokes make with identical parameters:

```text
make -C VERSION/source/sim/verilator WALLYCONF=rv64gc TESTBENCH=testbench PARAM_ARGS=MAKE_VCD=1 'VERILATOR_FLAGS=--assert --no-trace-top --stats --timing --timescale 1ps/1ps' WORKDIR=VERSION/work-hello
```

Each runtime uses WALLY=VERSION/source, RISCV=/opt/riscv and:

```text
VERSION/work-hello/Vtestbench +TEST=hello_hello +ElfFile=RUN/inputs/hello +AHB_MONITOR_LIMIT=0 +UART_LOG=1 +UART_LOG_FILE=logs/uart.out +PERFORMANCE_JSON=VERSION/runtime/performance.json
```

VERSION/RUN stand for absolute run-005 paths. Exact argv, cwd, WALLY/RISCV and exit codes are preserved in each `*-command.json` / `*-result.json`; build logs retain expanded Verilator/compiler invocations. Both baseline builds were run with escalation due to the established ccache sandbox restriction. All final build/simulation commands exit0.

## Directed unit verification

run-004 build PASS zero warnings; Normal, Abort and Pending End each print PERFORMANCE_MONITOR_TEST_PASS. Zero-wait read/write, stalls, same-edge completion/acceptance, INCR8, error, IDLE/BUSY, bus reset cancellation, CPU reset, CSR write/inhibit and pre-NBA ROI boundaries covered. Independent JSON post-checks PASS.

| Unit result | Normal | Abort | Pending End |
|---|---:|---:|---:|
| S / E or abort edge (ps) | 25 / 255 | 25 / 255 | 25 / 255 |
| Cycles / retired | 23 / 20 | 23 / 20 | 23 / 20 |
| Accepted / completed / cancelled | 13 / 12 / 1 | 14 / 12 / 2 | 13 / 11 / 1 |
| pending_at_end / aborted | 0 / 0 | 0 / 1 | 1 / 0 |
| AHB stall cycles | 4 | 4 | 5 |
| Completed latency sum | 16 | 16 | 15 |
| Completed latency mean | 1.333333333 | 1.333333333 | 1.363636364 |

Pending End keeps last data phase waiting while TestComplete rises in NBA at245ps, then presents HREADY=1/new valid address at E255ps. Neither completion nor acceptance occurs at excluded E. After E it checks frozen status/counts over further activity. JSON proves pending=1, aborted=0, mean=15/11 excluding pending. This closes the prior known coverage gap without monitor or semantic changes.

## Original vs Step2 measured comparison

| Metric | Original | Step2 | Difference | Overhead |
|---|---:|---:|---:|---:|
| CPU cycles | 11589 | 11589 | 0 | 0% |
| Retired instructions | 5762 | 5762 | 0 | 0% |
| CPI | 2.011280805 | 2.011280805 | 0 | 0% |
| Pipeline any stall | 5500 | 5500 | 0 | 0% |
| StallF | 5500 | 5500 | 0 | 0% |
| StallD | 5500 | 5500 | 0 | 0% |
| StallE | 4191 | 4191 | 0 | 0% |
| StallM | 4179 | 4179 | 0 | 0% |
| StallW | 4179 | 4179 | 0 | 0% |
| AHB accepted / completed | 1541 / 1541 | 1541 / 1541 | 0 / 0 | 0% |
| AHB reads / writes | 1504 / 37 | 1504 / 37 | 0 / 0 | 0% |
| AHB stall cycles | 1253 | 1253 | 0 | 0% |
| AHB latency sum | 2794 | 2794 | 0 | 0% |
| AHB latency min / mean / max | 1 / 1.813108371 / 2 | 1 / 1.813108371 / 2 | 0 / 0 / 0 | 0% |
| AHB error / cancelled / pending | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 | 0% |
| mcycle / minstret delta | 11589 / 5762 | 11589 / 5762 | 0 / 0 | 0% |

Difference=Step2−Original; overhead=difference/Original×100. For two zeros, output0%; a nonzero result over zero baseline is undefined/null. JSON/CSV contain every numeric exported field. No differences require analysis.

Both UART byte streams match exactly and contain Hello Wally! and0–9. Both simulations reach normal `$finish`; no fatal/timeout. Existing testbench reports "Single Elf file tests are not signatured verified." This is functional output/termination validation, not an ISA signature proof.

VCD independent replay PASS for both: TestBenchReset falls100ps, reset_ext falls200ps, CPU reset falls220ps after NBA, S230ps. TestComplete first rises116110ps after NBA; E116120ps. Finish at116160ps. Replay uses prior time-slot values for rising-edge samples and matches all CPU/retirement/stall/AHB counts. ROI transactions and reset/completion transitions are identical across versions. Latency histogram:288 beats at1cycle,1253 at2cycles; sum2794. CSR inhibit/write counts0 and incremental mismatches0, so raw mcycle/minstret deltas are valid and match independent counts.

## Problems & Solutions / history

- run-001: 3 WIDTHTRUNC from integer conditions; fixed using full-width comparisons, no truncation. 2 INITIALDLY from NBA in initial; moved drives to posedge process with negedge requests. No suppression.
- run-002: normal PASS; abort checked at250ps before reset-high sampling255ps, failed. run-003 moved checking after monitor sampling and verified cancellation/frozen counts across reset release. Monitor unchanged. Original failure logs retained.
- ccache writes outside sandbox caused read-only build failures. Identical builds with approval/escalation passed; no RTL workaround or changed simulation parameters.
- run-002 also preserves a wrong-relative-path launch failure; corrected launch passed.
- run-004: all three unit tests PASS. Initial baseline prepare incorrectly omitted the insertion's trailing blank line and stopped an exact original-testbench check. A diff confirmed only one extra blank line. Corrected snapshot block boundary in runner, then prepared new run-005. No ROI/counter/RTL changes and no overwritten failure evidence.

## Artifacts / review / limits / meeting summary

- `run-004/unit-{normal,abort,pending}/`: simulation.log, performance.json, performance_monitor.vcd; unit-verification.json and build logs at run root.
- `run-005/preflight.json`, `inputs-manifest.json`, `toolchain.json`, `instrumentation/manifest.json`: provenance and immutable measurement snapshot.
- `run-005/{original,step2}/`: source.tar, ethernet.tar, isolated source, manifest.json, build/simulate command/result JSON and logs, waveform-check.log.
- `run-005/{original,step2}/runtime/`: performance.json, testbench.vcd, logs/uart.out, waveform-verification.json, roi-transactions.json.
- `run-005/performance.json`, `performance.csv`, `comparison.md`, `comparison-check.log`, `waveform-comparison.json`: validated comparison and independent replay agreement.
- `run-005/instrumentation-working.diff`, saved driver/analyzer scripts, final Git status/diff check and hashes: review/reproduction evidence. Diff includes untracked instrumentation; no artificial Git commit created.

Modified tracked testbench; added monitor, unit test, run_baseline.py, summarize_performance.py, verify_waveform.py and two docs. Existing `tests/riscof/config.ini` modification is user state, unchanged SHA256 `865a6f85b2dc335a82bbc2e306bebd3e2050f04d757cbe5f86f2694f3e45a777`.

Limits: one existing Hello ELF, one rv64gc simulation per source; no physical timing/area/power or clock-frequency conclusion. No Step3 dual-core overhead claim. HADDR/control are saved in monitor but this is not a complete AHB protocol checker. Unit tests exercise cancellation, errors and pending termination beyond the successful Hello path. Results do not establish other workloads/configurations. No unresolved failure for requested scope; broader benchmarks and dual-core integration are future work.

Meeting summary: passive monitor validated across normal, reset-abort and pending-end boundaries; source/input/instrumentation parity is proven; cycle/retirement/CPI/stall/beat/latency match between Original and combinational A-only Guard. Measured overhead is0% for this workload. All supporting logs, waveforms, JSON/CSV and commands are saved without altering the active branch or existing work.
