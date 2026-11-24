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

## 2026-11-11 — Step 3E SINGLE Output Gate + Response Distribution

**SINGLE/NONSEQ版本完成並驗證PASS**，不是完整Burst/SEQ支援。起點/最終Branch `ahb-lockstep-step3`、HEAD `effe1a897de3c6e13dc10fd84c8a00c915f4951f`。沒有commit/push或雙Core/SoC整合，原3B/C/D與Performance定義不改。

Preflight核對實際Ingress one-slot/OFFER/WAIT_RESPONSE、pair原子handoff、Comparator registered MATCH/fault、原AHB/APB bridge的Data phase資料需求。metadata在單一outstanding、共同reset flush下足夠，不需修改原介面。Burst只有metadata無context，故matched Burst/SEQ/Lock不降級、不發有效地址，以sticky policy fault拒絕。未宣稱INCR8執行PASS。

Architecture：新ahb_lockstep_guard.sv串接原3B/C/D與新ahb_lockstep_output.sv。Backend保存owner payload/seq，EMPTY→ADDRESS→DATA→RESPONSE→RELEASE；fault後HALTED。Registered MATCH＋supported才authorized；HREADY接受Address一次後轉DATA，下一Address為IDLE，saved Write Data/Strobe保持，不用live A/B。合法MATCH在bus原先HREADY0時保持Comparator backpressure，避免在stalled IDLE改輸出；unsupported可以不碰bus而fault-receive。

Response：只在自己Data phase完成保存HRDATA/HRESP。Atomic ready barrier等兩側Ingress WAIT_RESPONSE都ready才同拍capture一次，buffer到兩側AHB completion前仍有owner。Normal internal capture後下一edge完成；Error由原Ingress重建兩周期ready0/resp1、ready1/resp1。Downstream error sticky fault不阻擋該筆error replay，只禁止之後normal dispatch。Error release同緣next Address保存為quarantine，等待reset。

Fault/reset：mismatch或unsupported沒有downstream acceptance、side effect或假response；兩側停等共同reset。Downstream Error正常回兩側error後HALT；原EBU忽略HRESP，不宣稱trap或恢復。Reset flush全路徑；若slave已完成寫入，prefix效果保留，不rollback。測試在down完成後reset response buffer再讀RAM，驗證prefix仍在。無tag介面仍要求slave共同reset，任意晚到舊response未支援。

實際命令：

```bash
python3 tests/ahb_lockstep/run_guard.py artifacts/ahb-lockstep-step3e/run-002
python3 -m py_compile tests/ahb_lockstep/run_guard.py tests/ahb_lockstep/summarize_guard.py
git diff --check
```

run-001保存preflight hash及零Warning lint。Verilator5.036、--binary --trace --timing --assert --timescale1ps/1ps、clock10ps。Runner用新不存在目錄，所有argv/cwd/exitcode/source snapshot/hash保存；ccache需sandbox外寫入，核准升權後執行。沒有build、simulation、assertion或離線verification失敗，沒有warning suppression。

Unit runtime實測：56/64/8有36pairs、27authorized、26down accept/25complete、A/B各23complete、A/B cancel16/15，Read/Write effects10/13，Error2。34/32/4與32/32/4各32pairs、23authorized、22down accept/21complete、A/B各19complete、cancel16/15、effects10/9、Error2。每width有3個mismatch和5個unsupported rejects，全部零downstream交易／假成功。

Counter差異都有reset證據：RV64 36pairs=23完整+8拒絕+5reset；27authorized在ADDRESS取消1→26accept，DATA取消1→25downcomplete，response/release取消2→23upcomplete。24次internal fork中1次fork後、AHB release前被reset，不誤算成功。A39accept=23complete+16cancel、B38=23+15，多1筆A是在pairing時reset僅A已接受。

Latency從pre-edge事件與edge index計算，不修改Performance ROI。Pair首次完整available→authorized、handoff→authorized分別記錄；同edge先舊completion再新accept，reset/reject不混入完整latency平均。Zero-wait Read兩側6cycles、Write7；normal downcomplete→upcomplete2，Error3。Aearly3/datawait2的A/B totals11/8；Bearly2/addresswait2/datawait1為9/11；Write addresswait3/datawait4為14/14。

RV64 23完整pairs的min/mean/max：pair→authorized1/1.130435/4，authorized→downaccept1/1.217391/4，downaccept→complete1/2/5，downcomplete→A/B2/2.086957/3。A端total6/8.130435/14，B端6/8.086957/14。全epochs peer wait8、consumer backpressure3、address stall7、data wait24；其中address2/data1是reset前取消的等待。整合response backpressure0，獨立fork test把單側ready拉低3cycles，兩側均不提前消耗，恢復後各一次。所有數據是Guard Unit latency，**不是CPU overhead**；原Hello Step2 overhead0%不被重寫或延伸。

驗證涵蓋simultaneous/Aearly/Bearly、zero/multiwait、完整data width及所有byte lanes/halfword、readback、高Address bit、upstream oldWrite completion與nextRead Address同edge、IDLE/BUSY、Error replay/quarantine、各種mismatch/policy reject、pairing/MATCH/address/data/response/release reset。Slave byte RAM與獨立shadow ledger比對data/status/effect count；Python獨立重播事件與latencies。原Step3D482cases/461faults、原3C18pairs、原3B unit/controller/cache regression全部PASS，零Warning，git diff --check PASS。

Evidence：`artifacts/ahb-lockstep-step3e/run-002/summary.json`；各width build/simulation logs和runtime guard.vcd、guard-events.csv、transactions/cancelled-upstream JSON、latency.json/latency.csv；fork logs/VCD；step3d-regression與nested3C/3B證據。GTKWave guard/fork設定已核對VCD header，未啟動GUI或截圖。重要窗口35–95ps zero-wait Read，605–745ps Write stalls，1625–1775ps release/next Address，1785–1855ps mismatch，2495–2635ps Error，3045–3115ps已完成prefix後reset。

新增兩個RTL、兩個TB、runner/summarizer、新Step3E文件與兩份waveform設定；既有meeting log只追加。7129個舊檔hash先保存，最終驗7128原檔不變與本log舊prefix完整。tests/riscof/config.ini、未追蹤備份、舊artifacts保留，未修改Git設定或stash/reset/clean。

Problems & Solutions：單owner＋明確Address/Data/RSP/release狀態避免把同個HREADY當兩種完成；預存Write Data避免當前HWRITE0丟資料；response buffer/barrier避免A先消耗或B拿錯response；HREADY0之前的IDLE保持用consumer credit安全延後；Error replay不被sticky fault一起擋掉。無重大interface不相容或非預期驗證錯誤。

Meeting可報告：SINGLE Output Gate與真正A/B response路徑完成、match前零下游交易、所有byte lanes/寬度及fault/error/reset有證據、unit latency與backpressure分類清楚、舊3B/C/D無退步。限制：尚無burst/BUSY scheduler、有效downstream多筆pipeline重疊、實際Uncore/雙Core、四態/Formal/STA；不宣稱rollback或CPU recovery。下一步先補burst context與實際Uncore wrapper驗證，再考慮受控SoC整合。

## Step 3F F1 — Burst Context / Validator（2026-11-23）

沿用HEAD 8b4c9a1ef，依確認方向保留原始INCR8；只新增獨立Validator，不改Output Gate、CPU、Cache、EBU、BURST_EN及既有Performance ROI。實作ahb_lockstep_burst_context.sv；新增burst_context_tb.sv、burst_context_compare_tb.sv、run_burst_context.py及docs/ahb-dual-core-step3f.md。

Architecture：Registered MATCH Saved Payload＋consumer credit→Validation→authorized/rejected；READY→ADDRESS→DATA→READY，Burst Context跨8筆保存。NONSEQ建立、SEQ逐筆地址/HSIZE/HWRITE/HBURST/HPROT驗證，Alignment、1KB及Address Overflow檢查，Lock/未支援Burst保留拒絕。ENABLE_INCR8預設0。down_accept與down_complete獨立，不能用裸HREADY；第8筆Address後仍active、accepted8/completed7/index7，最後Data完成才清active。BUSY/IDLE不建立有效命令、不推進Index；end_burst是未來Scheduler明確事件，不把無Request當過早結束。既有Ingress沒有idle/busy token，F2須建立Adapter，本輪不偷偷擴充Ingress。

Fault為Sticky，compare_fault阻止新授權；已授權的舊Data仍可完成記帳。無Rollback／Recovery／真實Error Distribution。未接入Guard，不宣稱F2或真實雙Core完成。

命令：`python3 tests/ahb_lockstep/run_burst_context.py artifacts/ahb-lockstep-step3f/run-007`；`python3 tests/ahb_lockstep/run_guard.py artifacts/ahb-lockstep-step3f/regression-001`；`git diff --check`。完整argv/cwd/toolchain/hash均保存在各執行目錄。Verilator5.036、--binary --timing --trace-fst --assert --timescale1ps/1ps，Clock10ps，Falling Edge驅動/Rising Edge後#1檢查，無NBA Race。

結果：F1 AW56/DW64 32cases、AW34/DW32 30cases、AW32/DW32 30cases、舊模式10cases、真實Comparator接入1case全部PASS，共103。Read/Write所有合法HSIZE、合法1KB尾端、非法地址/Control/Sequence/Alignment/Burst/Lock、提前結束、Reset、credit、最終Data Pending、錯誤Event Ownership均有Assertions。每個完整Burst Epoch授權/接受/完成各8次。Console accepts/completes為raw刺激含刻意孤立錯誤事件，不拿它當合法transaction總數。真實Comparator將相同非法A/B判MATCH後，Validator仍阻止Boundary違規。Step3E及巢狀3D/3C/3B全部PASS，最終所有Build零Warning。

Problems & Solutions：run-001位寬Warning以正確寬度literal/運算修正；run-002 ccache sandbox寫入失敗以獲准外部Build處理；run-003初版PASS後補強全HSIZE及final beat index。run-004 VCD SIGSEGV，debug-001排除單純Stack上限，debug-002 ASAN定位VerilatedVcd::printStr/emitTimeChange null寫入及Timestamp Flush指標問題；run-005註解被解析為directive；run-006 dumpflush未生成有效呼叫，仍crash；改FST完整Waveform後run-007全PASS，未減少測試／Assertions，未改RTL語意或工具安裝。失敗Log、VCD、ASAN資料完整保留。

Evidence：artifacts/ahb-lockstep-step3f/run-007/summary.json、final-verification.json、各組*-build.log/*-simulation.log、source-snapshot/hash、rv64/rv32/explicit32/legacy的burst-context.fst與compare/compare-validator.fst；regression-001/summary.json及巢狀Regression Logs。技術文件包含State/Timing Table、介面責任、限制、命令及Debug過程。最終Git狀態／新增檔案統計另存final-verification.json；既有config.ini修改與backups/artifacts保留，未Commit/Push。

Meeting可報告：F1合法性與Address/Data分離完成，最終Data Pending不可誤認Burst完成，相同非法雙側資料不能繞過檢查；舊3B～3E無退步。下一步待確認後F2串接保守單Outstanding的INCR8/BUSY Backend，再做完整Controller/Uncore測試；本輪停止，不直接實作F2。

## Step 3F F2 — INCR8 Output Gate / BUSY Scheduler（2026-11-23）

Preflight依序執行git branch --show-current、git status --short、git log --oneline -6，確認ahb-lockstep-step3/8b4c9a1ef。既有F1與Meeting Log未提交、config.ini既有修改、未追蹤Artifacts/Backups保留；原始檔與Hash存f2-preflight-001。

F2最小修改Output/Guard加入ENABLE_INCR8預設0；Burst模式把Registered MATCH交原F1驗證，Backend同拍保存Owner Payload。首NONSEQ、後七SEQ、HBURST5，前七筆後以BUSY/下一Expected Address等Peer/Response/Consumer；第八Address後IDLE但保留Pending Data/Response。HWDATA/HWSTRB來自Owner，不依live A/B；M_HREADY沒有直接廣播上游。SINGLE原路徑保留，F1/Ingress/Pair/Comparator/CPU/Cache/EBU/BURST_EN/ROI不變。

Interface限制在實作前已說明：F1單Outstanding，不支援下游Address Acceptance與舊Data Completion同Edge；以BUSY排程避免重疊，不能把0次下游Overlap報PASS。上游Ingress真實同Edge Completion/Acceptance已測2次，包含最後Burst→SINGLE。end_burst接0，由Scheduler確保僅八Address後IDLE，沒有捏造live IDLE/BUSY Token。

實際命令：run_burst_output.py artifacts/ahb-lockstep-step3f/f2-run-004；summarize_burst_output.py同目錄；run_burst_context.py artifacts/ahb-lockstep-step3f/f2-f1-regression-001；run_guard.py artifacts/ahb-lockstep-step3f/f2-regression-001；git diff --check。完整argv、工具版本、cwd、Exit Code、Source Snapshot/Hash保存。Verilator5.036、F2 FST/Timing/Assert、Clock10ps。

結果：AW/DW/SW56/64/8、34/32/4、32/32/4全部PASS。每組4個完整Burst32beats、4個SINGLE、1筆後續Fault前綴，共37次Auth/Down Accept/Down Complete/A Complete/B Complete；Policy Reject2（Boundary/中途地址），另有Comparator Mismatch及無Peer停等。Zero-wait Read/Write與逐Beat Wait Read/Write、Peer Skew±0～3、BUSY/Byte Lane/Strobe/Readback/Response/最後Pending/Data Owner Stability均有Scoreboard與Assertions。Python獨立按Epoch/Owner重播37個唯一Owner。每組BUSY276、Address Stall31、Data Stall51、Upstream Overlap2、Downstream Overlap0、Beat Latency1～5；BUSY包含Fault等待，非CPU Overhead。

Regression：F1 103案例全部PASS；Step3E/3D/3C/3B全部PASS；最終所有Build Warning0。舊Unsupported政策仍在，沒有刪除檢查或將INCR8變SINGLE。

Problems & Solutions：f2-run-001 ccache sandbox寫入失敗，以獲准外部Build重跑；f2-run-002 RV64 Assertions PASS但Python誤將十進位HBURST當二進位字串，修正解析；f2-run-003三組PASS後補強BUSY Credit及最後Burst Completion/下一SINGLE同Edge測試，最終f2-run-004全部PASS。完整失敗Log保留。沿用FST，不停用Assertions，不使用Warning Suppression。

Evidence：f2-run-004/summary.json、replay-summary.json、final-verification.json，各寬度Build/Simulation Logs及runtime guard-events.csv/events.json/transactions.json/beat-ledger.json/burst-output.fst；f2-f1-regression-001/summary.json、f2-regression-001/summary.json與巢狀Regression。完整架構/FSM/限制記於docs/ahb-dual-core-step3f-f2.md，完整本輪最終Codex回覆與進度訊息另存f2-run-004/codex-response.md及codex-progress.md。

Meeting可報告：受控Synthetic INCR8正常路徑接通、保留NONSEQ/SEQ/HBURST、MATCH+Validation前零有效下游交易、逐Beat守恆與A/B Response一致，既有Regression無退步。限制：下游Pipeline不支援；F3完整Mismatch/Error/Reset/Fault Drain/Recovery待做；沒有Rollback、真實Uncore/雙Core或CPU效能驗證。只完成序列化F2範圍，停止等待確認，不進入F3/3G/Fault Injection。無Commit/Push。

## Step 3F F2b — 架構阻礙確認，停止RTL擴充（2026-11-23）

依序核對branch/status/log，HEAD仍8b4c9a1ef，所有既有未提交/未追蹤資料保留。閱讀F1/Output/Guard/Ingress/Pair/Compare、F1/F2文件及f2-run-004 Owner Ledger後，確認阻礙不只Backend互斥FSM：Ingress單Pending Slot，必須在舊Data Complete→Saved Response→Ingress Capture→上游Complete後才能接受下一Address，之後才有Pair/MATCH。下一合法Saved MATCH不能在舊Data完成前取得。F1放寬事件或Backend加FIFO不會改變這條因果鏈；Writes還受下一Data Phase資料可用性與完整MATCH約束。

依使用者補充的「需大改Ingress/Response契約就停止」條件，本輪沒有改RTL或TB，沒有改F1、沒有製造內部同拍pulse或Backend-only正向測試冒充完整Guard。full_F2_acceptance_complete仍false，F2b實際Downstream Overlap仍0，驗收NOT_MET。

重新執行F1 103cases、F2三組各37完整Owners、Step3B～3E全部PASS，Build/Simulation returncode0，Warning/Error0。Python檢查三組各35條同Epoch相鄰Owner依賴，最短下一Pair比舊Data晚3cycles；FSM各state/HREADY組合互斥。RV64實際115ps Owner0 Data Complete、125ps Rsp Capture、135ps上游Complete、145/165ps下一B/A Address、185ps下一Pair、195ps授權、205ps下一DownAccept，不能稱為同Edge重疊。

BUSY序列化主要影響吞吐量，不因無Overlap就必然破壞AHB；原Controller有HREADY等待支援。但真雙Core/實際Uncore Hello未驗證，不能保證SoC完成。保留現狀風險較小；全路徑Overlap需重新審查Ingress Request取得、Write Data MATCH時點、Response Queue/Owner與跨Burst Context，不保證加Buffer可解決，更不能提前假成功。

Evidence：artifacts/ahb-lockstep-step3f/f2b-run-001/，含Source Snapshot/SHA256、原始preflight/commands、f1/f2/step3e新Regression與巢狀Logs/JSON/FST、architecture-analysis.json、三組causal-ledger、FST匯出VCD及兩張真實波形PNG（非GUI截圖）、Script、summary/final verification、RTL Diff、完整Codex回覆與Evidence ZIP。F2技術文件只追加F2b結果，舊Meeting內容保留。每組Unit數據BUSY276/Address Stall31/Data Stall51/Upstream Overlap2/Downstream Overlap0/Beat Latency1～5，不推論CPU CPI。

Problems & Solutions：無RTL Build/Assertion Failure；本輪失敗的是F2b驗收條件，原因為架構依賴，不以PASS隱藏。無matplotlib，使用現有libcairo將真實FST匯出渲染，不更動環境。Meeting應報告功能回歸穩定、Performance與Protocol正確性區分、完整Payload先MATCH與單Pending架構的因果限制。未進入F3/3G/Fault Injection，未Commit/Push。

## Step 3F — Controller Compatibility Gate（2026-11-23）

目標：以兩個原始ahbcacheinterface/buscachefsm實際生成AHB INCR8，驗證既有序列化Guard，而非人工AHB資料或真Core。Preflight Branch/HEAD仍ahb-lockstep-step3/8b4c9a1ef，保留所有F1/F2未提交內容、config.ini修改及Artifacts/Backups。直接include原rv64gc建立完整P，512-bit Line/64-bit AHB/BURST_EN1，兩組READ_ONLY_CACHE=0/1都測。

新增controller_gate_tb.sv、run_controller_gate.py、summarize_controller_gate.py、render_controller_gate.py及docs/ahb-dual-core-step3f-controller-gate.md。沒有修改任何Guard/CPU/Cache/EBU/Controller功能RTL。Cache端激勵只提供CacheBusRW/Adr/ReadDataWord與Uncached BusRW/WriteDataM；AHB Address/HTRANS/HBURST/HWDATA/HWSTRB全由原RTL輸出。

最終controller-gate-run-004：DCache19cases、106個Pair/Auth/DownAccept/DownComplete/A/B Complete；ICache6cases、42個完整Owner，全部PASS。DCache7個Refill＋5個Writeback，A/B各12 Ack；ICache5個Refill，A/B各5 Ack。獨立Python CSV/FST重播確認24份完整Fetch Buffer快照順序，Writeback40個Cache Word/Strobe正確，另8個SINGLE Byte Store覆蓋全部Lane及最後Readback。同步Zero-wait、A/Bearly、每Beat Address/Data Wait、連續R/R、W/R、R/W、Burst後SINGLE皆PASS，無False Mismatch/Unexpected ERROR/Deadlock。

Data/Address分離：Write在Address接受後原wdreg NBA更新，下一Edge由Ingress保存，即使上游Ready0；Scoreboard驗證資料所屬舊Address。CacheAck必須對應Beat7與A/B最後Completion，下游8筆皆已完成；Ack當拍Fetch Buffer用NBA後FST值核對，避免off-by-one。原Controller生成的連續Burst上游同Edge Completion/新NONSEQ接受：DCache3次、ICache1次；下游Overlap0，不修改F2b full_F2_acceptance_complete=false。

Unit數據：DCache Controller總Edge距離1160、Address Stall180、Data Stall223、BUSY615、PeerWait11、最後DataPending Wait40、Latency1～5；ICache429/69/83/239/5/16/1～5。Pair/Consumer Backpressure本測試0，不假稱非零已覆蓋。ZeroWait單Burst Refill49、Writeback57cycles；Aearly Read89、Bearly Write96、連續R/R168、W/R177、R/W178。非CPU CPI，不修改既有ROI。

本輪重新執行F1 103cases、F2三組37Owners、Step3B～3E全部PASS，保存在controller-gate-regression-001；Final兩組Lint/Build/Simulation全部PASS、Warning/Error0，git diff --check PASS。完整命令argv/cwd/version/exitcode/source hash保留。

Problems & Solutions：run-001 mux路徑錯誤修正為generic/mux.sv；run-002兩個TB fd邏輯AND引發WIDTHTRUNC，改fd!=0，未截斷計數；run-003 ccache sandbox Read-only，獲准外部Build，新run-004兩組首次Simulation即PASS。沒有Guard功能修正。PNG Renderer初版縮排SyntaxError僅修正離線Renderer，無重跑或修改測試結果；使用真FST匯出波形、非GUI截圖。

Evidence：controller-gate-run-004的summary/verification/metrics/beat-ledger/ack-fetch-ledger/events/cases/burst-metrics JSON/CSV、完整Logs、Source Snapshot/SHA256、FST、controller-gate.gtkw、三張PNG、Git Diff、完整Codex回覆與Evidence ZIP。Read末筆495/505/525ps為Address/Data/Ack；Stalled Write末筆2905/2955/2975ps，同樣Ack晚2cycles。

Meeting結論：現有方案A在原始Controller層No-Fault可前進，Read/Write均有完整證據，可以安排下一個EBU Compatibility Gate或F3，但未實作下一階段。限制：尚無原Cache SRAM/FSM/EBU/實際Uncore/雙Core/中途Fault/Error/Reset/Flush；不宣稱Step3G PASS。無Commit/Push，原檔/未追蹤資料保留。

Controller Gate最終補強：run-004通過後，TB僅新增4096 Byte Slave Memory/Shadow逐Byte Assertion及Actual/Expected Dump；最終交付改用controller-gate-run-005，兩組重新Lint/Build/Simulation及獨立FST Replay全部PASS、4096 Byte Dump均一致，原交易數與Latency/Wait統計不變。原run-004保留。原Guard/Controller未修改；Regression仍使用相同未改動的F1/F2/3B～3E來源，結果不變。本輪最終完整Codex回覆、Source Hash、Diff與Evidence ZIP位於run-005。

## Step 3F — EBU Compatibility Gate（2026-11-23）

本輪先核對branch/status/log，仍ahb-lockstep-step3/8b4c9a1ef；保留既有未提交/未追蹤資料與config.ini修改。以兩側各原始ebu/ebufsmarb/controllerinput，搭配四個原ahbcacheinterface/buscachefsm（各側IFU readonly、LSU read/write），接現有Guard與Controlled Slave；只從Cache/Uncached上層輸入激勵，未人工覆寫AHB輸出，未改功能RTL或BURST_EN。

仲裁依Source：同時請求LSU優先，IFUSave保存IFU第一地址，Controller live地址可先進；Restore/Disable直到LSU最後Data的對應HREADY/FinalBeatD條件，才將Saved IFU Address對外接受。Scoreboard分開local Controller與EBU外部accept，按HPROT/Sequence保存Owner；資料始終用舊Data Owner，不用live Select誤判。每側7 Save、527 Restore cycles，所有527 cycles Saved/Live IFU地址不同而保存正確；14個Saved Request各只Forward一次。獨立5312列仲裁樣本核對State/NextState、Select、Disable、Ready gating。

最終ebu-gate-run-005：27cases、236 Pair/Auth/DownAccept/DownComplete/A/B Completion全部PASS，Read171/Write65；IFU12 Refill96beats、LSU9 Refill72beats、7 Writeback56beats、Uncached Read3/Write9。A/B各28 Ack（IFU12/LSU16），42份完整Fetch Buffer快照均MATCH，所有Ack晚於最後Down Data2cycles。同Writeback Line8words讀回、八個Byte Lane同Word讀回0x1032547696b8dcfe、全4096 Byte Dump一致。無False Mismatch/Unexpected Error/Watchdog Timeout。

Cases含同步/近同步IFU/LSU、IFU先/LSU先、Replica A/B偏移、Zero/各Beat Wait、IFU/LSU連續Burst、W→R/R→W、Burst→SINGLE。Skew保留兩側相同上層交易順序；不宣稱任意重排都合法MATCH。Response Barrier同步Capture/Completion236次，非零Consumer BP本Gate沒有發生。

Unit數據：總Edge距離2655、Address Stall423、Data Stall530、BUSY1470、PeerWait8、最後DataPending Wait59、Latency1～5；Pair/Consumer BP0/0、下游Overlap0。保留F2b NOT_MET/full_F2_acceptance_complete=false；不是CPU CPI或整合雙Core Overhead。實際both_read Save2595ps、LSU最後DownData3575ps、Saved IFU Address Forward3595ps，PNG/FST有完整FSM切換。

重新執行ebu-gate-regression-001：F1 103、F2三寬度各37、Step3B～3E及Controller Gate19/6cases、106/42Owners全部PASS。最終Lint/Build/Simulation零Warning/Error，git diff --check PASS。命令、工具版本、cwd、returncode、Source Snapshot/Hash保留。Verilator5.036/Timing/Assert/FST、Clock10ps。

Problems & Solutions：run-001新TB IFUReqDelay階層誤寫，修正為ebufsmarb層；run-002一個WIDTHEXPAND以Operand擴寬修正；run-003 ccache sandbox Read-only改獲准外部Build。run-004 26cases/228首次Sim PASS後補明確Memory Readback，run-005 27cases/236全部PASS；未以改條件掩蓋功能失敗、無Guard/原EBU修正。所有舊Run保留，無Warning Suppression。

新增ebu_gate_tb/run_ebu_gate/summarize_ebu_gate/analyze_ebu_arbitration/render_ebu_gate及docs/ahb-dual-core-step3f-ebu-gate.md；沒有修改Controller Gate原測試。Evidence在ebu-gate-run-005，含Logs/Commands、Events/Arbitration/Owner/Ack/Fetch Ledgers、Memory Dumps、FST、GTKWave、三張真實FST PNG（非GUI截圖）、Hash/Diff、Codex完整回覆與ZIP。Meeting可報告：原EBU仲裁與已測No-Fault序列化Guard相容，可安排F3，仍無真Cache/CPU/Uncore/雙Core/中途Fault/Reset驗證。本輪停止，不進F3/3G/Fault Injection；未Commit/Push。


## Step 3F F3a：Mismatch／Fail-Closed／共同 Reset（2026-11-24）

- 基準：`ahb-lockstep-step3`／`0a6d7cbf0`；未修改 Guard 或原始 CPU／Cache／EBU／Controller／BURST_EN，未 Commit／Push。
- 新增 `f3a_mismatch_tb.sv`、`f3a_output_tb.sv`、`run_f3a.py`；技術說明見 `docs/ahb-dual-core-step3f-f3a.md`。
- Full Guard：三寬度各 336 Mismatch（8 個 Beat 位置、Read／Write 有效欄位、A Early／B Early／同步），合計 1008 PASS；正常 Read 不比對 Write Data／Strobe，三組各一完整 Burst PASS。
- 每寬度 7 個共同 Reset PASS；RAM 不清空，Reset 後以新 Sequence 執行合法 INCR8 Read／Write。每寬度 Auth 1317、Accepted 1316、Data Completed 1313、A/B Completed 各 1311；差異明確對應 1 Address／3 Data／2 Response Reset Cancellation，非交易遺失。
- 每寬度 745 個合法 Write Effects；Mismatch 後新增 Write Effects／RAM Byte Changes／Authorization／Acceptance／假成功 Response 皆 0。第 5 Beat 植錯共 72 個 Write 案例，各保留前四筆合法 Write，後續沒有 Side Effect；沒有 Rollback 宣稱。
- Module-Level：6 種公開 inhibit 測試 PASS，共 12 個舊授權 Owner 完成。單 Slot 限制使完整 Guard 的「舊交易 In-Flight 時下一筆 Comparator Mismatch」為 NOT_REACHABLE_IN_CURRENT_ARCHITECTURE，沒有偽造 Full Guard PASS。
- Problems & Solutions：run-001 ccache 沙箱唯讀失敗；run-002 TB 太早要求兩級 Fault 同時鎖存，改以第一拍 Validator、後續 Output Fault 檢查，RTL 不變；run-003 為迭代資料、不作最終 Source Provenance；run-004 加入 Source Snapshot 結束時一致性檢查；run-005 補齊實際 Stall 後 Reset，作為最終證據。原始 Log 全部保留。
- Regression：F1 103 PASS；F2 三寬度各 37 transactions PASS；3B～3E PASS；Controller Gate 25 cases／148 transactions PASS；EBU Gate 27 cases／236 transactions PASS。最終 Lint／Build 及 Regression 0 Warning／0 Error；Ruff py39／py313、Whitespace Check PASS。
- 重現：`python3 tests/ahb_lockstep/run_f3a.py NEW_OUTPUT_DIRECTORY`；完整 Build／Lint／Simulation argv 與 cwd 存於各 `*-command.json`。Regression 指令見技術文件及各 Root Command JSON。
- 證據：`artifacts/ahb-lockstep-step3f/f3a-run-005/`，含 Fault CSV／JSON、逐 Owner Ledger、Memory Before／After、FST、Source SHA256／Snapshot、Summary／Git Diff；Regression 在 `f3a-regression-run-001/`。
- Meeting 重點：現有序列化架構無須 RTL 修補即可通過本輪 Mismatch／Fail-Closed／共同 Reset 測試；測試已分開驗證授權前新交易與已接受舊 Owner 的責任。
- 限制與待辦：F2b 維持 NOT_MET／full_F2_acceptance_complete=false；F3b ERROR／Fault Drain、真實 SoC Reset Coordinator、真雙核心／Shared Uncore、CPU Performance 都 Pending。本輪完成後停止。

## Step 3F F3b：AHB HRESP ERROR Handling（2026-11-24）

- 基準 `ahb-lockstep-step3`／`0a6d7cbf0`；保留未提交 F3a 與全部舊證據。新增 F3b TB／Runner／技術文件，僅局部修改 `ahb_lockstep_output.sv` 的 M_HTRANS 選擇。
- Bug／Root Cause：原始 `busy_gap` 未考慮 error_seen，中途 ERROR 後仍 BUSY，與取消並 HALTED 的政策不一致。run-002 原始 Log／FST 重現；修正為第一 ERROR Edge 鎖存 error_seen 後，在第二 ERROR Cycle 起輸出 IDLE，Owner／Address／Data／Response 不變。
- Verilator run-001 Internal Fault 已定位階層式 Enum 參照，僅改 TB 的 HALTED 狀態觀察，未停用 Assertion；原始診斷完整保留。Ruff RUF002 改 ASCII 冒號，無 Suppression。
- F3b Full Guard：三寬度各 144 ERROR cases／6 Reset cases PASS，合計 432／18。涵蓋 INCR8 Beat 1～8、Read／Write、A/B 三種 Skew、零 Wait／多 Wait／Address Stall、A/B 兩 Cycle ERROR 與 HALTED。
- 每寬度 Authorized=Accepted=768、Data Completed=766、A/B Completed 各 763；差額為兩個未完成 Data、三個未釋放 Response 被共同 Reset 取消，逐 Owner 可追蹤。
- 每寬度合法 Write Effects=441，其中 OKAY=393、已授權 ERROR Commit=48；Fault 後新 Write Side Effect／Authorization／Acceptance／假成功 Response=0。不提交 ERROR 模型 RAM 不變，已完成 Prefix Writes 保留。不是 Rollback。
- Reset 涵蓋 ERROR1 取樣前／後、下游完成後 RESPONSE、上游 ERROR_1／ERROR_2、HALTED；同時清 Guard／Source／Slave Protocol，RAM 保留，Reset 後合法 INCR8 Read／Write PASS。
- Regression：F1 103、F2 三寬度各 37、F3a 1008 Mismatch／21 Reset／6 Module-Level、3B～3E、Controller 25 cases／148 transactions、EBU 27 cases／236 transactions 全 PASS；最終 0 Warning／0 Error，Ruff py39／py313 與 Whitespace Check PASS。
- 實際重現命令：`python3 tests/ahb_lockstep/run_f3b.py NEW_OUTPUT_DIRECTORY`；完整 argv／cwd 在各 Command JSON。證據 Root `artifacts/ahb-lockstep-step3f/f3b-run-003/`；Regression `f3b-regression-run-001/`；設計／時序／Memory 契約見 `docs/ahb-dual-core-step3f-f3b.md`。
- Meeting 重點：Guard 能辨識並保存 ERROR Owner，延後且同步回送 A/B 兩 Cycle ERROR；中途 Burst 合法取消後 Fail-Closed，沒有將 ERROR Write 誤當必然零 Side Effect。
- 限制：EBU HRESP 仍 Presently ignored，CPU Trap／Recovery／真雙核心／Shared Uncore／SoC Reset Coordinator／CPU Performance Pending。F2b NOT_MET／full_F2_acceptance_complete=false 不變；In-Flight 新 Mismatch 的完整 Guard 情境仍不可達。未 Commit／Push，完成後停止，不進入 F3c。


## Step 3F F3c：Manual Fault Injection Tool（2026-11-24）

- 基準 `ahb-lockstep-step3`／`430ef960d`。新增完整英文註解 INI、F3c TB／Runner／驗收 Driver、繁體中文操作文件；未修改 Guard／CPU／Cache／EBU／Configuration。未 Commit／Push。
- 使用者修改 `tests/ahb_lockstep/fault_config.ini`，執行 `python3 tests/ahb_lockstep/run_f3c.py --config tests/ahb_lockstep/fault_config.ini`；標準函式庫 configparser 嚴格驗證，不用 eval 或額外設定檔套件。
- 支援 A/B Data Bit Flip／Replace／XOR、Address 三種模式、七個 Control Signal、Delay。Transaction 共用 1-based 邏輯序號；Cycle 為 Reset Release 後 0-based 的安全 Address 提出時機；Actual Data Capture Cycle 另記錄。未命中不延後套用。
- 明確分開 Requested／Applied／Detected／Fail-Closed；同值／零 XOR 為 NO_EFFECT；Delay=0 為零 Delay 參考，不假稱 Applied；Read Write-Lane Fault 拒絕；HTRANS=IDLE／首筆 BUSY 不支援，中途 BUSY 不建立 Request，回報 NOT_INJECTED。
- 最終矩陣 248/248 符合預期：208 正向執行成功、40 負向維持預期非零 Exit Code。標準 Data 54、Address 54、Control 42、Delay 24、No Fault 29；另有有效 Cycle Trigger／忽略欄位檢查。26 Invalid Config、6 NO_EFFECT、6 NOT_INJECTED、1 動態 Trigger Conflict、1 Watchdog FAIL 均未冒充工具 PASS。
- 額外最高位元／完整寬度 Replace 8/8 PASS，涵蓋 Data 63/31、Address 55/33/31、64/32-bit。所有已偵測 Mismatch 的 Reason 正確、Fail-Closed、未授權 Write Side Effect=0；上／下游 Stall Stability Assertions 與 A/B Response Assertions 保持啟用。
- Problems & Solutions：首次三個 WIDTHEXPAND 用有界 32-bit 中間運算修正；Reset Deassert 同一 Delta 讀 HREADY 過早，加入收斂等待；Runner 初版誤把 Validator reason[7] 的 Comparator Fault 傳遞視為 Policy Reject，修正分類。原始 f3c-run-001～003 與失敗 Build Logs 保留，沒有改 Guard 或壓 Warning。
- Regression 全 PASS：F1 103、F2 三寬度各 37、F3a 1008 Mismatch／21 Reset、F3b 432 ERROR／18 Reset、3B～3E、Controller 25 cases／148 transactions、EBU 27 cases／236 transactions。最終 Lint／Build 無 Warning，Ruff py39／py313、Assertions／Diff Check PASS；刻意 Watchdog 的 Fatal 獨立標為預期負向。
- 證據：`artifacts/ahb-lockstep-step3f/f3c-validation-run-002/`、`f3c-boundary-validation-run-001/`、`f3c-regression-run-001/`；各案例包含 INI、Parsed Config、Injection／Owner／Source／Memory Ledgers、Summary／Log／FST，Binary Cache 以 Source／Tool／Width Hash 驗證。
- 操作與範例見 `docs/ahb-dual-core-step3f-f3c.md`，包含 VS Code、No Fault、B 第五筆 Data Replace、A Delay 3、GTKWave。F2b NOT_MET／full_F2_acceptance_complete=false 保留；既有 In-Flight 不可達情境不改標。真 CoreRTL 植錯、雙核心／Uncore、CPU Performance／Recovery Pending。本輪完成後停止，不進入 F3d。

## Step 3G-1：Real Uncore Gate 與 Dual-Core Wrapper（2026-11-25）

- 基準 `ahb-lockstep-step3`／`be73f8e8d`；保留個人 config.ini、手動 fault_config.ini、未追蹤舊 RTL／備份及所有歷史 Artifacts，未 Commit／Push。
- 新增 `wallylockstepsoc.sv`：真正 core／core_b、原完整 Guard、唯一原始 uncoregen.uncore。同 P／Clock／Reset／Interrupt／MTIME／ExternalStall；A/B HREADY／Response 分開，Clock Outputs 沒有短接。原始 Pipeline／Cache／EBU／Controller／Uncore／rv64gc／BURST_EN 均未修改。
- UNCORE_GATE_PASS：Synthetic A/B 驅動真正 Guard＋真正 Uncore，61 Pair／MATCH／Auth／Accept／DataComplete／AComplete／BComplete，2 Epoch；6個INCR8／48 Beats＋13 SINGLE，RAM Read／Write／Byte Lane／Reset保留資料與APB UART均PASS。
- 物理 RAM Write Effects=33、UART THR接收0x47恰一次、未授權或重複Write=0；BUSY297 Cycles、實際APB Data Stall1、Address Stall0。非零Address Stall與更廣WaitPattern未覆蓋，不製造假HREADY。UART是APB／THR接收驗證，不假稱Serial Frame解碼。
- WRAPPER_BUILD_PASS：Lint／JSON Elaboration／逐Port Check／原Makefile完整Build PASS；AST證明兩顆原始Core同參數、A/B各自接Guard、Guard接唯一Uncore。Wrapper Binary沒有執行，REAL_DUAL_CORE_HELLO_PENDING。
- Single-Core Baseline：原 testbench／wallypipelinedsoc Build與Hello Simulation PASS，使用相同Frozen ELF與載入檔，UART內容正確；沒有更動原wsim行為。
- 新增 Gate／Build Harness／DPI Helper／Runner／FST Replay；Source Manifest只列正式追蹤RTL加新Wrapper，排除未追蹤ahb_guard.sv與舊SoC備份，不刪除舊資料。
- Problems & Solutions：補原Memory getenvval DPI Link；處理UART字元黏接Marker；修正新Wrapper Port宣告筆誤；用JSON取代Deprecated XML，無Warning Suppression。F3c驗收原先依賴使用者目前Delay設定而把Data Case跑成Delay，改驗收Driver明確設定完整基準，保持248案例標準與手動INI不變；原失敗證據全保留。
- Regression：F1 103、F2三寬度各37、F3a 1008 Mismatch／21 Reset、F3b 432 ERROR／18 Reset、3B～3E、Controller25 cases／148、EBU27 cases／236均PASS；F3c修正後248/248符合預期。最終零新增Build Warning／Error，Ruff py39／py313與Diff Check PASS。
- 證據Root `artifacts/ahb-lockstep-step3g/3g1-run-006/`；Gate FST／原始CSV與Memory、verification-002逐A/B／Owner／RAM／UART Replay、Connection Check／Wrapper Build、Single UART／Logs／Inputs SHA256完整保留。Regression見同層regression-run-001與002。命令與限制見 `docs/ahb-dual-core-step3g-1.md`。
- 下一步才做3G-2 DUT選擇、B Retirement／Termination／Cache觀察與真正雙Core Hello。F2b NOT_MET／full_F2_acceptance_complete=false不變；真CPU Performance／Bus Error Trap／Recovery Pending。本輪完成後停止。
