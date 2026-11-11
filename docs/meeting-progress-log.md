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

## 2026-11-11 — Step 3C Dual Ingress + Request Alignment

**完成並驗證 PASS**。本次起點 HEAD `782dbddeee15fdbcd19f898a21302f9edddb5dc9`、branch `ahb-lockstep-step3`；未 commit/push。原 Performance Baseline（Original vs Step2 Hello cycle overhead0%）保留，不重跑、不延伸為 Step3C overhead結論。

Architecture：先核對 Step3A/3B文件、原 ingress RTL、現有 unit/controller測試、performance文件與meeting歷史。Step3B實際每側只有1個pending slot；Read進OFFER，Write下一拍CAPTURE_DATA後才OFFER；req/rsp handshake分離、response沒有epoch/tag。可安全用兩個原樣Ingress加原子ready/valid join延伸，不需要修改CPU/EBU/Guard或Ingress。

新增 `ahb_lockstep_dual_ingress.sv`、`ahb_lockstep_pair.sv`。pair_valid表示兩側完整OFFER，pair_ready只表示consumer credit，不是match/allow。兩側同緣dispatch，兩份saved payload/seq原樣交Step3D；本階段不比較payload，不搜尋相同地址，不合併重複地址。沒有Shared Uncore輸出。兩側獨立response接線只供測試stub／未來Step3E，沒有功能性Response Distribution。

Counter：pre-edge A_req_valid XOR B_req_valid 計 peer wait；分A/B。兩側都valid但pair_ready0只計pair_backpressure。Common reset清零，counter不觸發timeout或issue。Read/Read和Write/Write同到都計0；同到Read/Write有1拍data-capture availability差，不是payload mismatch。沿用既有AHB雙相位與Performance ROI定義。

Directed results：125 cycles、244 counter checks、18 pairs；A/B各accept20、complete17、reset_cancel3，無pending／重複／錯序。18中1對dispatch後reset取消，其餘17對完成；各側另2筆dispatch前取消。Simultaneous Read0、Write0、Aearly1→1、Aearly4→4、Bearly3→3、Write skew2→2；both-valid backpressure5時peer wait0；skew3+backpressure4則分別3與4。測試還涵蓋不同payload照樣handoff、3-bit seq wrap、重複相同地址、A先完成並接受n+1但B仍等n時不錯配，以及四種reset與EMPTY stray response/IDLE/BUSY。

舊 Step3B regression：原unit46cycles、accepted9/dispatched8/completed7/cancelled2；single controller2次完成；cache controller8次完成與cache_ack1。全部build/runtime PASS，32-bit lint PASS，零Warning。原Step3B檔案未修改。

實際主命令：

```bash
python3 tests/ahb_lockstep/run_alignment.py artifacts/ahb-lockstep-step3c/run-002
python3 -m py_compile tests/ahb_lockstep/run_alignment.py tests/ahb_lockstep/summarize_alignment.py
git diff --check
```

Verilator5.036，--binary --trace --timing --assert --timescale1ps/1ps，clock10ps。每個build/lint/simulation/regression/verifier的argv/cwd/exitcode保存於run-002的command/result JSON。初次run-001 ccache遇sandbox唯讀，核准相同命令升權後成功；原log保留。完整最終runner用新run-002，不覆蓋舊證據。

Problems & Solutions：以完整req_valid而非pending_valid辨認Write Data尚未完成；採用原slot持有payload避免新增FIFO或半pair消耗。Testbench首次simulation前靜態校閱發現async counter reset先於reference edge flush，改為reset解除時比較pre-edge、reset edge後比較全零；不修改RTL語意。無測試simulation失敗、無warning suppression。未發現需大幅修改既有架構的不相容。

Evidence：`artifacts/ahb-lockstep-step3c/run-002/summary.json`、alignment-build.log、alignment-simulation.log、verification.log；unit/alignment.vcd、alignment-cycles.csv、pairing-cases.csv；step3b-regression/summary.json與原unit/controller logs/VCD。Waveform windows包括Aearly4 125–195ps、Bearly3 205–265ps、backpressure 465–545ps、asymmetric response 895–995ps、reset 1005–1175ps；GTKWave設定 `docs/waveforms/ahb-lockstep-step3c/alignment.gtkw` 已核對VCD header，未產生GUI截圖。

變更：新增兩個RTL、alignment_tb、runner/summarizer、`docs/ahb-dual-core-step3c.md`、waveform設定；本meeting log只追加。6946個原source/tests/docs/backups/evidence先核對全數hash未變；追加後另檢查舊meeting log前綴不變，其餘舊檔維持hash一致。最終Git diff/status與來源snapshot另保存。config.ini原修改、未追蹤guard/backups與所有舊artifacts保留。

Meeting可報告：雙Ingress可在A/B skew與backpressure下形成正確有序pair；peer wait/backpressure已拆開且有directed實測；原Ingress/controller regression無退步。限制：只有synthetic AHB與test completion，無第二Core、Comparator/Gate、Uncore side effect、timeout/fault policy、真正Response Distribution。32-bit只lint；Verilator二態，不宣稱Formal/STA。Response仍需共同reset flush，任意延遲的stale response不在當前能力內。

下一步：Step3D保存並比較pair payload，match前禁止issue；Step3E處理單份Response保存、pair identity、雙側恰好一次消耗與共同reset。詳細技術與介面契約見新Step3C文件。目前請求範圍無未解決測試錯誤。

## 2026-11-11 — Step 3D Saved-Payload Comparator

**完成並驗證PASS**。起點/最終branch `ahb-lockstep-step3`、HEAD `55ed74182345d855fc02c284d0a9ec794e7de91a`。沒有commit/push、CPU/Uncore/Step2Guard/Step3B/C/Performance功能修改。

Step0證據：重播舊Step3C CSV，1145ps兩側接受、1155ps pair handoff；舊VCD顯示1160ps共同reset，1165ps是ledger reset sampling edge。該pair尚未response所以各取消1筆。每側18handoffs=17complete+1posthandoff取消；20accept=17complete+3cancel，另2筆在handoff前取消，最終pending0。分析保存run-001/step3c-accounting.json與run-002/step3c-reset-waveform.json，無交易遺失，不修改Counter定義。

Architecture：新增一筆registered Comparator result slot，從既有pair_valid/ready接收兩份完整saved payload。pair_ready只依EMPTY credit，不依match；接收後registered MATCH或sticky FAULT。MATCH經match_valid&&match_ready正常交付一次；Fault有獨立fault_valid/reason/A/B snapshots，正常valid永遠0，until common reset。原ingress停WAIT_RESPONSE，不假裝Core已收到成功或Error。真正Output Gate/Uncore master/Response Distribution留Step3E。

比較：addr/write/size/burst/prot/trans/lock完整equality；兩側皆Write才比完整data/strobe，strobe0的data仍比較。Read忽略write lanes，HRDATA/HRESP不在request介面。先檢查A/B local_seq=pair_seq與valid beat；不具同ordinal或IDLE/BUSY不進payload比較而fault。11-bit reason mask可同時記錄多項差異。

實際主命令：

```bash
python3 tests/ahb_lockstep/run_compare.py artifacts/ahb-lockstep-step3d/run-002
python3 -m py_compile tests/ahb_lockstep/run_compare.py tests/ahb_lockstep/summarize_compare.py
git diff --check
```

Verilator5.036，--binary --trace --timing --assert --timescale1ps/1ps，clock10ps；ccache需sandbox外寫入，runner核准升權執行。run-001另保存兩個零warning lint與preflight。完整argv/cwd/exitcode、width matrix與source snapshot都在artifacts；沒有異常build/simulation failure或warning suppression。

Unit實測：56/64/8/32有216cases/7MATCH/209fault；34/32/4/32有158/7/151；32/32/4/8有108/7/101。共482cases、21normal dispatch、461fault零normal dispatch。每width另有1個pending MATCH reset取消，總485accept=21dispatch+461fault+3reset-cancel。全address/data/strobe/seq/size/burst/prot bits皆注入；direction/lock/transfer、Read忽略write lanes、重複地址、multiple reasons、backpressure stable、sticky fault拒收新pair/reset recovery皆PASS。Python以完整saved snapshots重新算mask並重播handshake，不只看success字串。

Integration：原雙ingress+join直接接新Comparator，測Aearly3、Bearly2、同到、Write/backpressure4、重複地址、不同順序heads、reset recovery。8handoff/7normal dispatch，兩側各8accept/7complete/1cancel；fault request沒有normal dispatch、response或completion。Response僅由test stub在成功dispatch後產生，不宣稱功能Response Distribution。

原Step3C regression18pairs、每側20accept/17complete/3cancel一致；nested原Step3B unit/controller/cache tests全部PASS。所有build/runtime/離線核對零Warning，git diff --check PASS。

Problems & Solutions：handoff與completion分開計數的reset差異已證實；為防Mismatch握手無診斷卡死，改用fault接收與成功dispatch分流的安全設計，不改舊interface。Read/Write語意分支避免誤報，完整bit sweep排除高位截斷。No drain/refill bypass，fault不自動清除/重試。沒有需重大架構變更的不相容。

Evidence：`artifacts/ahb-lockstep-step3d/run-002/summary.json`、各width build/simulation logs和runtime compare-cases.csv/compare-events.csv/compare.vcd；integration events/cases/VCD；step3c-regression及nested step3b-regression；source-sha256與command/result JSON。技術文件 `docs/ahb-dual-core-step3d.md` 詳列equations、mask、timing。GTKWave comparator/integration設定已對照VCD header，未產生GUI截圖。關鍵窗口：RV64 addr mismatch385–465ps、highest-data-bit12265–12345ps；integration Write255–345ps、fault455–525ps、reset recovery535–575ps。

變更：新增Comparator RTL、兩個TB、runner/summarizer、新技術文件與兩份waveform設定；本meeting log只追加。7010個既有檔案先建立hash，最終允許本log追加且驗舊prefix，其餘7009不變。config.ini既有修改及untracked backups/artifacts保留，沒有Git設定修改或stash/reset/clean。

Meeting可報告：Saved-Payload Comparator與fail-closed fault已完成、461 faults零成功交付、三種width有實際runtime、舊3B/C無退步。限制：只到matched internal request界面，沒有真實MMIO/Uncore Output Gate或AHB Error Distribution、完整Burst policy、四態注入/Formal/STA。下一步Step3E整合唯一downstream transaction FSM與response identity/雙側consumed/error/reset收尾。當前scope無未解決錯誤。
