# Step 3G-3：Real CPU No-Fault Performance Measurement

基準：`ahb-lockstep-step3` / `605adc4e6`。使用原 `wallypipelinedsoc` 與已驗證的 `wallylockstepsoc`，後者為真正的 `core`、`core_b`、唯一 Guard 與唯一 Shared Uncore。本輪不修改功能 RTL、CPU、Cache、EBU、Uncore、Configuration 或 Hello；`rv64gc BURST_EN=1` 保留。

Single-Core Top 仍包含既有 Step 2 `ahb_shared_guard`，它是原始 AHB 的 Combinational Pass-through，不是 Dual Guard，也不是新建立的歷史 Commit Checkout。因此本輪比較精確定義為目前正式 Single-Core Top 相對目前 Dual-Core Top；先前 Original Commit 的 Baseline 證據沒有改寫。

## 量測架構與 ROI

新增 `CVW_CPU_PERFORMANCE` Compile-Time 選項，只選擇 TB 的共同終止條件及被動 Trace；既有 Single/Dual Flow 預設不變。`cpu_performance.svh` 在 Rising Edge 前取樣，不驅動 DUT；只透過 NBA 將 TB Completion Flag 設為 1。Python 對 Raw CPU/AHB/Guard CSV 獨立重播，不以 UART Text 或舊 Log 推估 Cycle。

- 舊 ROI **`reset_release_to_tb_complete_v1`** 保留原 Monitor、定義及獨立 `legacy-performance.json`。S 為觀察過 CPU Reset 後第一個 Reset=0 的 Rising Edge，包含 S；E 為第一個 Rising Edge 前 `CurrState==STATE_RUN_TEST && TestComplete`，不包含 E。
- 新共同 ROI **`reset_release_to_retired_tohost_and_drained_v1`** 使用相同 S。每個實體 Core 必須透過 `InstrValidNotFlushedM` 退休 Store Opcode，Address 等於凍結 ELF 的 64-bit `tohost`，Write Data=1。Single 需一側成功、Dual 需雙側成功；所有觀察中的 AHB Data Owner 排空後，以 NBA 設定 Completion。第一次 Edge 前 Completion=1 為 E，不計入。成功 Store 所在 Edge 計入。若有後續新 Address，也必須先完成才能建立終點。
- Clock 原高低各 `#5`，本輪固定 Timescale `1ps/1ps`，Period=10ps。以 Cycle 比較，不把此 TB Clock 宣稱為實體可達頻率。
- Raw Cycle Index 從 S=0 開始。Total Cycles=E-S，不把 A/B Cycles 相加；CPI 分母為各自 Retirement，不能使用 A+B。
- 250,000 Cycles Watchdog；共同 Reset 中斷量測視為失敗，本輪只測 No-Fault。

兩個 Top 都使用共同 TB 終止政策。舊 ROI 仍觀察其原本的 `TestComplete` 條件，但本輪 `TestComplete` 由共同政策產生；所以不能把舊 ROI 名稱相同直接解讀為與所有歷史 Run 的 E 完全相同。Raw Samples 保存新 E 與舊 E，各自統計並與舊 Monitor 交叉核對。

## Counter 來源與定義

| 指標 | 實際來源／定義 |
|---|---|
| Retirement | 各 Core `.priv.priv.csr.InstrValidNotFlushedM`，ROI 內每 Edge 最多一次 |
| Pipeline Stall | 各 Core `StallF/D/E/M/W` 各自 Cycle Count；`pipeline_any` 為 OR Union |
| Cache/Memory Stall | `ICacheStallF`、`DCacheStallM`、`IFUStallF`、`LSUStallM`，分開計數，不相加 |
| CSR Crosscheck | `HPMCOUNTER_REGW[0/2]`、`MCOUNTINHIBIT_REGW[0/2]`、`WriteHPMCOUNTERM[0/2]`，逐 Edge 驗證增量；Inhibit/Write 出現時不能直接使用 CSR Delta 當效能 |
| AHB Address Acceptance | `HRESETn && HREADY && HTRANS[1]`，保存新 Owner、Address/Control |
| AHB Data Completion | 前一筆 Owner Pending 且 `HREADY=1`；同 Edge 先完成舊 Data，再接受新 Address |
| Beat Latency | Completion Index − Acceptance Index；Zero Wait=1，Assertion `latency=1+wait_cycles` |
| INCR8 Latency | 第一筆 NONSEQ Acceptance 到第八筆對應 Data Completion；BUSY 不算 Beat |
| Pairing Wait | A/B 完整 OFFER XOR，與正式 Pair Counter Delta 交叉核對 |
| Ingress No Credit | `pending_valid && !complete`；是各側已接受 Owner 等待期間，包括多個後續階段 |
| Core-facing Response Wait | 使用上述 Pending 且 HREADY=0 的期間；不是純 Response Register Delay，與 Ingress No Credit 為同一組 Cycle |
| Pair Consumer Backpressure | `pair_valid && !pair_ready`，與正式 Counter Delta 核對 |
| Comparator Result Backpressure | `match_valid && !match_ready` |
| Comparator/Authorization Delay | Pair Handoff → 第一次 Registered MATCH；另記 Pair → Authorization |
| Output Busy Gap | Output `.busy_gap`，同時報實際下游 `HTRANS==BUSY` |
| Downstream Address Wait | 有效 Address (`HTRANS[1]`) 且 `HREADY=0` |
| Downstream Data Wait | 已接受 Owner 尚在 Data Phase，`HREADY=0` |
| Response Distribution Latency | 下游 Data Completion → A/B Core-facing Data Completion |

Guard Wait 類別允許重疊；JSON 保存 Pairwise Intersection 與完整類別 Union。不能把 BUSY、Ingress Wait、Downstream Wait 等直接相加當 CPU Overhead。AHB JSON 分 Core A/B 與 Downstream，另分 Read/Write，平均 Latency 只納入已完成 Owner。此 No-Fault Run 要求結尾無 Pending；一般不完整交易不可混入平均值。

## 重現與證據

```bash
python3 tests/ahb_lockstep/run_3g3.py artifacts/ahb-lockstep-step3g/3g3-run-NEW
python3 tests/ahb_lockstep/summarize_3g3.py artifacts/ahb-lockstep-step3g/3g3-run-NEW --output artifacts/ahb-lockstep-step3g/3g3-run-NEW/analysis-001
```

`NEW` 必須替換為不存在的目錄；Analysis 也禁止覆寫。Runner 保存凍結 ELF/Memfile/Labels/Address Data、Source Manifest/Snapshot/SHA256、Clock/Reset 設定來源、工具版本與完整 Build/Simulation 命令。相同 Frozen Inputs 共用於兩個 Top；未追蹤舊 Guard 不在正式 Manifest。rv64gc 的 RAM/BOOTROM PRELOAD 均為 0，Hello RAM 使用凍結 Memfile，沒有另外隱含載入 FPGA Boot Image。

Verilator 使用 Assertions、Timing、FST 與相同時序選項；兩個 Build 的必要差異為 `CVW_DUAL_CORE`。舊 Monitor 只透過各自 Runtime 的 `PERFORMANCE_JSON=legacy-performance.json` 啟用，不會覆寫其他 Core 或 Run 的檔案。

實驗失敗紀錄：`3g3-run-001` 的 Single Lint PASS，但 Build 的 ccache 受到 sandbox Read-only 限制。保留原 Log，在取得執行授權後用相同命令於 `3g3-run-002` 重跑，沒有使用 Warning Suppression。

## 實際結果

本輪正式量測目錄：`artifacts/ahb-lockstep-step3g/3g3-run-002/`。最終獨立重播為 `analysis-003/`；前兩次分析保留，主要數值一致。Root CSV/JSON 為最終結果的保存副本。

所有八項驗收：**SINGLE_HELLO_PASS、DUAL_HELLO_PASS、RETIREMENT_COUNTER_PASS、CYCLE_COUNTER_PASS、CPI_CALCULATION_PASS、STALL_COUNTER_PASS、AHB_LATENCY_PASS、PERFORMANCE_COMPARISON_PASS**。

| 共同 ROI 指標 | Single | Dual Core A | Dual Core B |
|---|---:|---:|---:|
| S 時間 (ps) | 230 | 230 | 230 |
| E 時間 (ps，不包含) | 116110 | 127910 | 127910 |
| S Cycle Index | 0 | 0 | 0 |
| E Cycle Index（不包含） | 11588 | 12768 | 12768 |
| Total Cycles | 11588 | 12768 | 12768 |
| 成功 tohost Store Index（0-based） | 11587 | 12767 | 12767 |
| Retired Instructions | 5761 | 4117 | 4117 |
| CPI | 2.011456344 | 3.101287345 | 3.101287345 |

Dual System Total 為 **12768**，不是兩側相加；A/B Completion Skew=0。CSR 全部沒有 Inhibit/Write，逐 Edge Mismatch=0，mcycle/minstret Delta 與新 Counter 完全一致。

舊 ROI 統計也通過獨立交叉檢查：Single E=11589（116120ps）、Cycles=11589、Retirement=5762；Dual E=12769（127920ps）、Cycles=12769、每側 Retirement=4118。多出一個終止觀察 Edge 與 Self-Loop Retirement；主要比較不使用這些數值。

### Retirement 差異不是遺失指令

兩側 Dual Retirement Stream 完全相同，並與 3G-2 的 4117 一致。Single 相較 Dual 多 1644 次 Retirement；唯一有差異的 PC 為 UART `uartSend` 輪詢的 `0x80000230`（LBU）、`0x80000234`（ANDI）、`0x80000238`（Branch）。每個 PC 都多 548 次，與實際 UART LSR `0x10000005` Read Count 1216→668 的差異完全一致。其他 PC 的退休次數相同。證據為 `polling-analysis.json`、`retirement-difference.csv`、凍結 `hello.objdump` 與 `examples/C/common/syscalls.c`。

### Pipeline Stall

各格為 Cycles（占共同 ROI 比例），Dual A/B 相同。各 Signal 允許重疊。

| Signal | Single | Dual 每側 |
|---|---:|---:|
| StallF | 5500 (47.463%) | 8310 (65.085%) |
| StallD | 5500 (47.463%) | 8310 (65.085%) |
| StallE | 4191 (36.167%) | 7549 (59.124%) |
| StallM | 4179 (36.063%) | 7537 (59.030%) |
| StallW | 4179 (36.063%) | 7537 (59.030%) |
| pipeline_any | 5500 (47.463%) | 8310 (65.085%) |
| ICacheStallF | 252 (2.175%) | 1252 (9.806%) |
| DCacheStallM | 110 (0.949%) | 550 (4.308%) |
| IFUStallF | 377 (3.253%) | 1381 (10.816%) |
| LSUStallM | 3869 (33.388%) | 6227 (48.770%) |

### Guard Wait / Latency

| 指標 | Cycles |
|---|---:|
| A Peer / B Peer Wait | 0 / 0 |
| Pair Consumer / Comparator Result Backpressure | 0 / 0 |
| A / B Ingress No Credit（也為 Core-facing Pending Response Wait） | 5707 / 5707 |
| Output Busy Gap / 實際 Downstream BUSY | 1260 / 1260 |
| Downstream Address Wait | 0 |
| Downstream Data Wait | 705 |
| Response Barrier Pending | 993 |
| 上述 Wait Category Union | 5959 |

A/B No Credit 的 Intersection=5707；A No Credit 與 BUSY 的 Intersection=1008；與 Downstream Data Wait 的 Intersection=705。5959/12768=46.671%，這仍不是可直接加到 CPU Cycles 的 Overhead。

993 個 Owner 的 Stage Latency：Pair→Registered MATCH=1、Pair→Authorization=1、Authorization→Downstream Acceptance=1、Downstream Completion→A/B Completion=2，所有 Min/Avg/Max 相同。細節與 Overlap Matrix 保存在 `dual-performance.json`、`guard-wait-counters.csv`、`guard-stage-latency.csv`。

### AHB Latency

| 觀察位置 | 完成數 | Avg | Min | Max | Read / Write 數 |
|---|---:|---:|---:|---:|---:|
| Single | 1541 | 1.813108371 | 1 | 2 | 1504 / 37 |
| Dual A | 993 | 6.747230614 | 6 | 8 | 956 / 37 |
| Dual B | 993 | 6.747230614 | 6 | 8 | 956 / 37 |
| Dual Downstream | 993 | 1.709969789 | 1 | 2 | 956 / 37 |

Single Read Avg=1.808510638、Write Avg=2；Dual A/B Read Avg=6.698744770、Write Avg=8；Dual Downstream Read Avg=1.698744770、Write Avg=2。各條流結尾 Pending=0，所有 Beat 都符合 Latency=1+Wait，地址/資料在 Stall 期間穩定。逐 Owner 比對 Address、Write Payload/Strobe、Read Response 與 A/B Response Completion，沒有錯配。

三個觀察位置都包含 36 個完整 Read INCR8：Single Burst Latency=8，Dual A/B=48，Dual Downstream=43（Min/Avg/Max 均相同）。本 Hello 沒有對外 Write INCR8，因此其真實 CPU Write Burst Performance 為 **Pending**，不能以既有 Synthetic 測試替代此數據。

Single 同拍 Completion/Acceptance=252；Dual A/B 上游各252，但 Downstream=0。F2b NOT_MET 保留。

### Overhead 與瓶頸分析

- System Cycles：+1180，**+10.182947877%**。
- CPI：+1.089831001，**+54.181190848%**；動態 UART Polling 次數減少，所以 CPI 百分比不能當作固定指令工作量下的 Comparator 成本。
- Pipeline Stall Union 比例：47.462893%→65.084586%，**+17.621694 percentage points**。
- Core-facing AHB Avg：+272.136090789%；Downstream Avg 則 −5.688495200%。後者來自交易組成變化（UART LSR 輪詢少548筆、Cache Read Beats相同），不是 Uncore 變快。

最明確的額外等待出現在序列化的 Memory/IO 路徑：完整 Refill 的 Core-facing Burst Latency 8→48，ICache Stall 252→1252、DCache Stall 110→550，LSU Stall 3869→6227；反而 Peer Wait 與 Result Backpressure 均為0。這支持目前 Owner/Dispatch/Response 階段與序列化 Burst 是觀察到的延遲來源，但不能將重疊的 Wait 加總或把1180 Cycles全歸因Comparator。UART輸出硬體時序也影響輪詢工作量；本輪不進行效能最佳化。

UART 兩組均為同一份36 Byte字元串流（另有1次LCR Write），Dual的37筆Write均有唯一Owner；沒有Mismatch、未授權Write或Timeout。

### Regression / 工具

`artifacts/ahb-lockstep-step3g/3g3-regression-run-001/results.json`：11組重跑Exit Code皆為0。包含3G-2 Dual Hello、原Single Hello、Real Uncore、3B～3E、F1 103、F2三組各37、F3a 1008 Mismatch/21 Reset、F3b 432 ERROR/18 Reset、F3c 248、Controller 25 cases/148 transactions、EBU 27 cases/236 transactions。舊測試Summary內的歷史階段Pending不等於本輪整體狀態；本輪狀態見Root Summary。

兩個Performance Build/Lint皆0 Verilator Warning/Error，Assertions PASS。Python最初發現unused import與py313的RUF007；刪除unused import，改用Python3.9可用的Index Traversal而非3.10才有的pairwise，沒有Suppression。最終py39/py313皆PASS；修改遍歷方式後重新分析，Summary與初次分析逐Byte相同。Runner的unused-import清理不影響實際Build RTL；Run Source Snapshot保留真正執行的版本，Final Audit另存最終Python Source。

### 檔案定位

Root：`summary.json`、`performance-comparison.csv`、`single-performance.json`、`dual-performance.json`、`single-retirement.csv`、`dual-retirement.csv`、`ahb-latency.csv`、`burst-latency.csv`、`stall-counters.csv`、Guard CSV、Polling Analysis。Raw Trace/FST在`single/`與`dual/`；舊Monitor各自為`legacy-performance.json`。完整Lint/Build/Simulation命令與Logs、Input/Source Manifest在Root；Final Review另存Git Diff、Source SHA、Ruff與Regression結果。


## 保留限制

F2b **NOT_MET**，`full_F2_acceptance_complete=false`。沒有進行 Pipeline 重構或 Fault Injection。原始 EBU 忽略 HRESP，不能宣稱 CPU Bus Error Trap／Recovery。Hello 包含 MMIO UART Polling，屬單一工作負載；Cycle Overhead 代表完整 Dual-Core + Guard 相對正式 Single-Core Top 的變化，不能全歸因 Comparator，也不能推論其他程式的 Overhead。
