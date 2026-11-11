# Meeting progress log

## 2026-11-11 — Performance Baseline Phase 1

Source HEAD `0837d6a98`, branch `ahb-lockstep-step3`. Prior Step 3B remains unchanged. Current uncommitted implementation diff can be reviewed with `git diff -- testbench/testbench.sv`; newly added monitor/test/docs are untracked. No commit or push.

Read-only inspection used `git status --short`, `git branch --show-current`, `git rev-parse HEAD`, `git cat-file -t`, `rg`, `sed`, `cat`, `ls`, `which verilator`. Inspected testbench reset/completion FSM, CSR retirement/counter logic, core stalls, SoC AHB signals, Verilator Makefile, previous Step2 command documentation, and Hello input paths.

Design: passive pre-NBA observer; dynamic S-inclusive/E-exclusive ROI; old AHB data completion before new address acceptance; latency accounting only for complete beats; independent retirement plus CSR diagnostic checks. Full design is in `performance-baseline.md`.

Added draft monitor, directed unit test, and testbench integration. Actual build command is recorded in the design document. Build failed with three WIDTHTRUNC and two INITIALDLY warnings. Log: `artifacts/performance-baseline/run-001/unit-build.log`. Root causes: integer conditions need explicit comparisons; NBA boundary stimuli must be driven from a clocked process rather than an initial block. These fixes have NOT been applied because the user requested stopping on unexpected errors.

Unit tests: not run. Functional verification: Pending. Waveform: Pending. Original/Step2 comparison: Pending. No performance data inferred from historical artifacts.

Preserved pre-existing modified `tests/riscof/config.ini`, artifacts/backups, waveform directory, and untracked Guard/source backup files. Read-only config SHA256 at stop: `865a6f85b2dc335a82bbc2e306bebd3e2050f04d757cbe5f86f2694f3e45a777`.

Next steps: resolve the reported Phase1 warnings, verify directed expectations and missing corner cases (including pending at E and CSR mismatch detection), then run Phase1 tests successfully before creating isolated baselines. Record exact source/instrumentation/config/input hashes and commands; validate loaded-file paths, UART and normal termination; produce JSON/CSV and automatic comparison without changing test conditions to force equality.

Meeting summary: instrumentation design and draft are available for review; no measured performance conclusions yet. The first verification gate exposed simulator timing semantics in the directed test, so Phase2 was intentionally not started.


## 2026-11-11 — Problems & Solutions: warning repair

Read original run-001 failure log. Fixed 3 integer-condition width warnings with full-width comparisons; no narrowing casts. Moved reset/ROI end NBA stimulus from initial into a posedge process with requests prepared at negedge. ROI and counter definitions unchanged. Modified this turn: monitor, unit test, performance-baseline.md, this log. No functional RTL/config changes.

Verilator 5.036, timing/assert enabled, 1ps/1ps. New run-002 preserves all prior artifacts. First build blocked by ccache sandbox write; same build succeeded after escalation, zero warnings. Initial normal launch had wrong relative path (exit127), corrected launch PASS. Exact commands and all problem locations documented in performance-baseline.md.

Normal test: 23 cycles / 20 retired, CPI 1.15, S25/E255ps; all normal scenario/cycle/latency assertions PASS. AHB accepted13/completed12/cancelled1, waits4, latency sum16/min1/max3. Bus-reset cancellation PASS. CSR per-edge cross-check mismatches0 despite injected inhibit/write. Evidence: run-002/unit-normal/performance.json, simulation-run.log, performance_monitor.vcd.

CPU-reset abort branch FAIL at line79 (250ps): assertion still checks the NBA assertion edge instead of waiting for the next pre-edge reset sample. No abort result JSON emitted. Stopped as requested; did not adjust expectation or continue Phase2. Evidence: run-002/unit-abort/simulation.log and performance_monitor.vcd. Next step: review/fix abort assertion timing, then verify complete Phase1 before baselines. Pending-at-E coverage remains an additional outstanding test from prior meeting notes.

Diff whitespace check PASS; config hash unchanged; no commit/push. Original-vs-Step2 performance table remains Pending. Meeting conclusion: build warnings solved; normal directed test validated; Phase1 not fully complete due to abort-test timing failure.


## 2026-11-11 — Problems & Solutions: CPU reset abort repair

Root cause: test checked at250ps, before monitor could sample reset high at255ps. Reset asserted by NBA at245ps, so245ps correctly remains part of the partial ROI. Monitor reset logic requires no change.

Changed only unit test code: assert pre-reset edge behavior, wait until after reset sampling, then check aborted/done, pending cancellation, exact partial counters and beat conservation/latency. Recheck frozen counters across held reset and subsequent release with active stimuli. Updates also made to these two documentation files. Full event schedule and actual commands in performance-baseline.md.

New artifacts run-003. Sandbox build encountered ccache read-only filesystem; identical escalated build PASS zero warnings. Normal PASS, abort PASS, cycle/latency assertions PASS, git diff --check PASS. Normal JSON identical to run-002. Both S25/E255ps,23cycles/20retired. Abort accepted14/completed12/cancelled2/pending0, aborted1, frozen through315ps. Aborted ROI remains invalid for baseline. CSR reset model cleared, monitor partial evidence preserved.

Evidence: unit-build-escalated.log, unit-normal/simulation.log, unit-abort/simulation.log, both performance.json and performance_monitor.vcd under run-003; verification-summary.json records post-checks. No prior artifacts overwritten; config and monitor hashes unchanged. No commit/push, no functional RTL change.

Meeting summary: all existing Phase1 normal/abort tests PASS; NBA reset timing problem solved with testbench synchronization only. Stopped at Phase1 as requested. Phase2 Original/Step2 comparison Pending; dedicated pending-at-normal-E case remains an explicitly documented coverage limitation.

## 2026-11-11 — Pending-end closure and fair Original/Step2 baseline

Requested scope completed. Branch still ahb-lockstep-step3, HEAD0837d6a98; all existing working-tree state preserved. No commit/push, config edits or functional RTL changes.

Step0: added PENDING_END branch to existing directed unit bench. Last beat waits while TestComplete rises in NBA245ps; excluded E255ps presents ready/valid but neither completes nor accepts. Verifies done1/aborted0/pending1, accepted13=completed11+cancelled1+pending1, latency sum15/mean15÷11, and frozen state after E. Normal/Abort/Pending all PASS, zero unit build warnings. New evidence run-004. This resolves the prior coverage limitation.

Preflight: Original be4b5af64c7ad1bb361636ade49bdfeb43bd847d and Step2 8ff5bf2471d51e45a3317768e04aac4bb97d3ee0 have identical testbenches and rv64gc/shared configuration. Common retirement/stall/CSR hierarchy and downstream bus observation point need no adapter. Existing Hello files copied from examples/C/hello, no ELF rebuild. All five files hashed before/after each operation, RAM memfile/addr/lab point at identical shared absolute paths.

Isolation: git archive exports including exact Ethernet submodule into independent run-005 sources, no checkout/Git metadata mutation. Snapshot exact uncommitted monitor/integration/test with hash527ba6cae304931cb87746e12c6cae8be20f956f0daf57f8e789111eb926f6b7. Version manifests record complete source/config/archive hashes. SHA256 checks after runtime PASS. Source commits unmodified except identical testbench instrumentation.

Problems & Solutions: first preparation in run-004 stopped because snapshot boundary omitted one trailing blank line, making strict original-testbench check fail. Inspected unified diff: blank line only. Included insertion trailing blank in extraction; new run-005 prepare PASS. No semantic difference ignored. Unit build had ccache sandbox read-only failure; exact escalated rerun PASS. Baseline builds used approved escalation for same known ccache requirement. No warning suppression or RTL workaround.

Actual driver commands: run_baseline.py RUN prepare, then build --version original/step2 and simulate --version original/step2; verifier verify_waveform.py per runtime and summarize_performance.py RUN. Full shell commands and expanded build/runtime argv/cwd/env are in performance-baseline.md and each version's command JSON. Tools: Verilator5.036, explicit --timing --assert --timescale1ps/1ps, rv64gc, MAKE_VCD1, clock10ps. Unit and baseline build logs have zero warnings/errors.

Measured table:

| Metric | Original | Step2 | Difference / overhead |
|---|---:|---:|---:|
| Cycles | 11589 | 11589 | 0 / 0% |
| Retired | 5762 | 5762 | 0 / 0% |
| CPI | 2.011280805 | 2.011280805 | 0 / 0% |
| Any pipeline stall | 5500 | 5500 | 0 / 0% |
| AHB accepted/completed | 1541/1541 | 1541/1541 | 0 / 0% |
| AHB stall | 1253 | 1253 | 0 / 0% |
| AHB mean/max latency | 1.813108371/2 | 1.813108371/2 | 0 / 0% |

Both UART files byte-identical (Hello Wally and0–9), normal finish, no fatal/timeout. Independent VCD replay confirms S230ps/E116120ps, historical reset/TestComplete timing, all counter metrics, identical ROI transactions and reset/completion transitions. AHB histogram288×1cycle+1253×2cycles=2794 total. Both CSR inhibit/write0 and update mismatches0; mcycle/minstret deltas11589/5762 agree with independent counters. No unexplained performance differences.

Key evidence: run-004 unit logs/JSON/VCD; run-005/{original,step2}/build.log, simulate.log, runtime/testbench.vcd, runtime/logs/uart.out, runtime/performance.json, runtime/waveform-verification.json, runtime/roi-transactions.json; root performance.json, performance.csv, comparison.md, waveform-comparison.json, manifests and instrumentation-working.diff. Scripts saved with artifacts. Full metrics and SHA256 values in performance-baseline.md.

Git review: changed testbench integration; added monitor/unit/three Python tools/two docs. instrumentation-working.diff includes new untracked code so review does not require a commit. Config hash remains865a6f85b2dc335a82bbc2e306bebd3e2050f04d757cbe5f86f2694f3e45a777. git diff --check PASS.

Meeting summary: Phase1 boundary coverage closed, Phase2 fair baseline complete, zero measured overhead for A-only combinational Guard on Hello/rv64gc. Results do not imply physical frequency/area/power or Step3 dual-core performance. No remaining failure in requested scope. Future work: additional workloads/configurations and eventual dual-core integration; these are not claimed complete or required for this baseline.
