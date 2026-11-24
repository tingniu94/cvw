# Step 3F F3c：Manual Fault Injection Tool

## 用途與範圍

使用者只需修改 INI，Python 會驗證設定並執行真正的 Guard RTL。路徑為 TB Source → 注入 → A/B Ingress → Pair → Comparator → Burst Validator → 序列化 Output → Memory Model。沒有 `force fault_valid`，沒有修改任何 Guard／CPU／Cache／EBU／Configuration。

這是 Synthetic Source 的手動植錯工具，不是真正雙 Core、CoreRTL Fault Injection 或 Shared Uncore 整合，也不是 CPU Recovery／Rollback。

## 第一次操作

在 WSL Terminal 執行：

```bash
cd ~/cvw
code .
```

在 VS Code Explorer 開啟 `tests/ahb_lockstep/fault_config.ini`。若使用 `code .`，需已有可用的 VS Code WSL 連線。檔案中 26 個參數各有英文 Purpose、Data Type、Valid Values／Range、Unit、Bit Width、Example 與 Applicable／Optional／Ignored 說明。

保留全部 Section／Key，只修改值。Boolean 使用 `true/false`；Integer 為十進位；Hex 必須以 `0x` 開頭；不適用的可選值可填 `none`。未知 Section／Key、重複 Key、錯誤格式會拒絕執行。未使用欄位仍須有合法格式，但其值不參與注入；位元寬度限制只套用於啟用的修改欄位。

執行：

```bash
python3 tests/ahb_lockstep/run_f3c.py --config tests/ahb_lockstep/fault_config.ini
```

Runner 會自動建立新的 `artifacts/ahb-lockstep-step3f/f3c-run-XXX/`，不覆寫舊結果。第一次遇到某組參數會 Lint／Build；後續 INI 變更可重用經 SHA256 驗證的同版 Binary。Build／RTL／TB／Simulator／Width 不同會使用另一份隔離 Build，快取不會跳過 Simulation 或 Assertions。

| Configuration | ADDR_WIDTH | AHB DATA_WIDTH |
|---|---:|---:|
| rv64 | 56 | 64 |
| rv32 | 34 | 32 |
| explicit32 | 32 | 32 |

這些是 Guard／AHB 參數，不是 CPU Instruction Width。

## 三個可直接操作的範例

以下僅列出要在完整 INI 中修改的值，**不要用片段覆蓋整份 INI**。每次儲存後執行上方 Runner 命令。

1. **No Fault**：在 `[fault]` 設 `FAULT_ENABLE = false`；在 `[run]` 選 `WORKLOAD = read_incr8` 或 `write_incr8`。預期 `NO_FAULT_PASS`，八筆正常完成；`mixed` 為八筆 Write 再八筆 Read。可用 BASE_DELAY_A／BASE_DELAY_B 測試合法 Skew。
2. **Core B 第 5 個 Write Beat 的完整 HWDATA Replace**：`CONFIGURATION = rv64`、`WORKLOAD = write_incr8`、`FAULT_ENABLE = true`、`FAULT_TARGET = B`、`FAULT_LOCATION = Ingress`、`FAULT_TYPE = Data`、`DATA_MODE = replace`、`DATA_VALUE = 0x123456789ABCDEF0`；Trigger 設 `TRIGGER_MODE = transaction`、`INJECT_AT_TRANSACTION = 5`、`INJECT_AT_BEAT = 5`、`INJECT_AT_CYCLE = none`。預期四筆 Prefix Write 保留，第五筆產生 Comparator Reason bit 7，不進入下游。
3. **Core A 延遲 3 Cycles**：`FAULT_ENABLE = true`、`FAULT_TARGET = A`、`FAULT_TYPE = Delay`、`DELAY_CYCLES = 3`；選 Write Workload、`INJECT_AT_TRANSACTION = 5`、`INJECT_AT_BEAT = 5`、`INJECT_AT_CYCLE = none`，BASE_DELAY_A/B=0。只延遲第五筆的 Address 提出，其他 Payload 不變。預期 `DELAY_VERIFIED`、實測 Delay=3、沒有 Mismatch、完整八筆完成。

## 如何修改各種 Fault

- 完整 Data：`DATA_MODE=replace`，修改 `DATA_VALUE`；64-bit 可到 `0xFFFFFFFFFFFFFFFF`，32-bit 可到 `0xFFFFFFFF`。
- Bit Flip：`DATA_MODE=bit_flip`，修改十進位 `FAULT_BIT`，0-based；或 `xor_mask` 配合 `XOR_MASK`。
- Address：`FAULT_TYPE=Address`，使用 ADDRESS_MODE／ADDRESS_BIT／ADDRESS_VALUE／ADDRESS_XOR_MASK。工具不自動修正 Alignment。只改一側的不對齊 Address 先被 Comparator 偵測，不可誤稱 Validator Policy Reject。
- Control：`FAULT_TYPE=Control`，指定 CONTROL_SIGNAL／CONTROL_VALUE。Reason Bits：HWRITE=1、HSIZE=2、HBURST=3、HPROT=4、HTRANS=5、HMASTLOCK=6、HWSTRB=8；Address=0、Write Data=7。
- HSIZE 編碼受 AHB Data Width 限制，超出正常支援大小的編碼可作刻意 Corruption，但仍先經 A/B 比較。HWSTRB 只用於 Write；Read HWDATA／HWSTRB Fault 會被拒絕。
- HTRANS=NONSEQ／SEQ 可建立有效的 Mismatch。HTRANS=IDLE 會造成固定 Burst 提前終止，本工具明確拒絕這種注入；BUSY 只允許在 Burst 中間，因不建立有效 Request，結果為 NOT_INJECTED，不能當成 Comparator PASS。第一筆 BUSY 不支援。
- Delay：只延後未接受的 Request。HREADY Stall 期間保存 Address／Control／Data，Burst 中使用 BUSY 等待；沒有以假 Response 推進 Source。0 Cycle 是 `DELAY_ZERO_VERIFIED` 參考案例，不宣稱已施加非零 Delay，`INJECTION_APPLIED=false`。

## Trigger 與時序契約

每次 Simulation 只有 Reset Epoch=1，一個 Trigger 最多嘗試一次。

- Transaction 使用 A/B 共用的 1-based Workload 邏輯序號，而非誰先到的時間順序。單 Burst=1～8；mixed=1～16。只有兩側正常完成才能前進到下一筆；Fault 後停止，不會因 Skew 改選另一筆。
- Beat 使用 1-based，等於 `(Transaction-1)%8+1`。指定衝突會報錯；`none` 關閉一致性檢查。
- Cycle 使用 0-based，從共同 Reset 解除後第一個 Rising Edge 起算。只比對指定側「原本預定的安全 Address 提出 Edge」，在注入 Delay 之前。若該 Edge 是 Data／Pending 期間而沒有新 Request，不延後命中，回報 NOT_INJECTED。
- transaction 模式的 Cycle 必須為 `none`；cycle 模式的 Transaction 必須為 `none`。Cycle 動態命中的 Beat 與設定衝突也不猜測。
- 實際 Data／Strobe 注入 Edge 是有效 Address Acceptance 後一拍的 Capture；Address／Control 為 Address Acceptance Edge。INI 的 Cycle Trigger 不是要求在已接受的 Data Phase 中途改資料。
- Detection Latency 為首個 Rising Edge 觀察到 Fault 的 Cycle 減去實際 Payload Capture Cycle，包含 Registered Comparator／觀察延遲，不能當 CPU CPI 或 Guard 系統 Overhead。
- BASE_DELAY_A/B 是每筆的基礎提出延遲；DELAY_CYCLES 只作用於被 Trigger 選中的那一側、那一筆。實測 Delay 由實際 Acceptance Cycle 減去該側原定 Cycle，並非只抄設定值。

Watchdog 預設 2000 Cycles，可設 32～100000；它只是 TB 等待上限，不是 Guard Timeout Fault。到期結果為 FAIL。上游和下游 Stall 都有獨立的 Payload Stability Assertions。

## 如何確認真的植入

`summary.json` 分開列出 `INJECTION_REQUESTED`、`INJECTION_APPLIED`、`FAULT_DETECTED`、`FAIL_CLOSED_VERIFIED`。Mismatch 成功需四者都為 true、Reason 正確、零新授權／下游接受／假完成，且獨立 Memory Scoreboard 通過。

- Data Replace 與原值相同或 XOR=0：NO_EFFECT、Exit Code=4，不是 Fault PASS。
- 沒有安全 Cycle Request／BUSY 未形成有效 Request：NOT_INJECTED、Exit Code=3。
- 動態 Trigger 衝突／命中 Read 無意義 Write Lanes：INVALID_TRIGGER、Exit Code=3。
- INI 錯誤：INVALID_CONFIGURATION、Exit Code=2，附繁體中文說明，不執行 RTL。
- Build／Simulation／Assertion／Watchdog 問題：FAIL、Exit Code=1。
- 正常 No Fault、真正 Mismatch、非零 Delay、刻意零 Delay 參考驗證：Exit Code=0，但 result 欄位各自區分，不把 Delay 說成 Mismatch。

Comparator Fault 可傳遞到 Validator reason[7] 與 gate_fault[0]；這不是獨立 Validator Policy Reject。工具保存原始 Reason 並另外分類 `fault_origin=COMPARATOR_MISMATCH`。

Mismatch 後，未完成 Burst 可留在合法 BUSY 等待共同 Reset；這不同於 F3b 的 Slave ERROR 取消為 IDLE。已完成的 Prefix Write 不回復。

## 檔案與 GTKWave

每次結果目錄包含：INI Snapshot、Parsed Configuration、Runner Source、Source SHA256、Exit Code、Git Diff、Simulation Log、`summary.json`、`injection.csv/json`、`owner-ledger.csv/json`、`guard-events.csv`、`source-events.csv`、`memory.csv`、Memory Hash，及選擇儲存時的 `f3c-fault.fst`。Invalid Config 不會產生 Simulation／FST，另有 error.log。

Build Reference 與 Binary SHA256 在 environment.json；對應 Build 目錄保存 Lint／Build Logs、完整命令、RTL／TB Snapshot。Memory 以 Byte 保存，Before／Final 與已授權 Write 的 Address／Data／Strobe 逐筆核對。Data Fault 的 changed_mask 是 Original HWDATA XOR Injected HWDATA；Delay 的 value 欄位以 Cycles 表示，不是 Payload Bit Corruption。

```bash
gtkwave artifacts/ahb-lockstep-step3f/f3c-run-005/f3c-fault.fst
```

在 `f3c_fault_tb` 加入 `addr[0/1]`、`wd[0/1]`、`strb[0/1]`、`trans[0/1]`、`ready[0/1]`、`rd[0/1]`、`resp[0/1]`、`pair_valid/pair_ready`、`match_valid/match_ready`、`authorized_dispatch`、`fault_valid`、`compare_fault_reason`、`M_HTRANS`、`M_HREADY`、`down_accept/down_complete`、`writes`；可展開 `dut.comparator`、`dut.output_backend.burst_mode.validator`。以 Injection 的 applied_cycle 對照 source-events.csv 的相對 Cycle，再看 Reason 和下游是否停止有效 Beat；Memory 以 CSV／Ledger 為判據。

## 實際驗收

完整矩陣命令：`python3 tests/ahb_lockstep/verify_f3c.py --output NEW_OUTPUT_DIRECTORY`。最終結果在 `artifacts/ahb-lockstep-step3f/f3c-validation-run-002/`；包含正常、負向預期結果的逐案 Command／Log／INI／Summary，不把負向結果改成工具 PASS。實際 **248/248 案例符合預期**：208 個正向執行成功，40 個負向案例以預期的非零 Exit Code 拒絕或結束。工具本身沒有把負向結果改成 PASS。

| 類別 | 實際驗證 |
|---|---|
| No Fault | 27 組 Read／Write／mixed／Skew，另有 Waveform 關閉及忽略欄位案例，合計 29 PASS |
| Data | A/B × 三種模式 × Beat 1/5/8 × 三寬度 = 54 PASS；每模式 18 |
| Address | 同樣 54 PASS，含不對齊 Address 的 Comparator Reason=0 |
| Control | 七個 Signal × A/B × 三寬度 = 42 PASS，逐 Reason 核對 |
| Delay | A/B × 0/1/3/8 × 三寬度 = 24 PASS；18 非零實測、6 零 Delay 參考 |
| Cycle Trigger | 4 個有效命中 PASS；3 個無安全 Request 回報 NOT_INJECTED；1 個動態 Beat 衝突回報 INVALID_TRIGGER |
| 未使用欄位 | 額外的超寬未使用 Replace Value 不影響有效 Bit Flip，PASS |
| NO_EFFECT | 3 個同值 Replace + 3 個零 XOR，皆 Exit Code=4 |
| BUSY | 3 個未建立有效 Request，皆 NOT_INJECTED／Exit Code=3 |
| Invalid Config | 26 個案例皆拒絕執行並回傳 Exit Code=2，含重複 Key／未知 Section／Key／格式／範圍等 |
| Watchdog | 1 個刻意過短上限觸發 FAIL／Exit Code=1，沒有當成功 Mismatch |

另於 `f3c-boundary-validation-run-001/` 完成 **8/8 邊界案例 PASS**：Data Bit 63／31、Address Bit 55／33／31、完整 64／32-bit Replace。所有成功 Mismatch 均確認完整 Guard 路徑、正確 Reason、Fail-Closed、零未授權 Write Side Effect。

本輪 Regression：F1 103；F2 三寬度各 37；F3a 1008 Mismatch／21 Reset；F3b 432 ERROR／18 Reset；3B～3E；Controller 25 cases／148 transactions；EBU 27 cases／236 transactions，全部 PASS。結果在 `f3c-regression-run-001/`。新 Python 的 Ruff py39／py313、Verilator Lint／Build／Assertions 與 Diff Check 均 PASS，完整結果見最終 Audit。

開發問題均保留：首次 Lint 三個 Width Expansion 警告改成有界 32-bit 中間運算後轉型；Reset 解除後立即讀 HREADY 的 Delta Timing 問題加收斂等待；Runner 最初誤要求 Validator Fault=0，修正為辨識 Comparator Fault 傳遞。不改 Guard，也沒有 Warning Suppression。

## 限制

只處理一個 Reset Epoch、一筆手動 Injection，不提供自動 Recovery 或執行中重新配置。HRESP ERROR 的回歸仍保留，但不是這份 INI 的 Fault Type。

F2b 仍 NOT_MET，`full_F2_acceptance_complete=false`。舊 Data Pending 時的下一筆完整 Guard Mismatch 仍為 `NOT_REACHABLE_IN_CURRENT_ARCHITECTURE`。真雙 Core、CoreRTL 植錯、Shared Uncore、CPU Trap／Recovery／CPI 都 Pending。本輪完成後停止，不進入 F3d。
