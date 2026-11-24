# Step 3F F3b: AHB-Lite HRESP ERROR Handling

## 範圍與基準

基準為 `ahb-lockstep-step3`／`0a6d7cbf0`，保留未提交的 F3a 成果。正式架構仍為 Saved Payload MATCH → Burst Validator → INCR8/BUSY 序列化 Output → A/B Response Barrier。

本輪只修改 `src/ebu/ahb_lockstep_output.sv` 的 `M_HTRANS` 選擇；沒有修改 Ingress、Pair、Comparator、Burst Validator、原始 CPU／IFU／LSU／Cache／EBU／Controller、Configuration 或 `BURST_EN=1`。

依據 [ARM IHI 0033A §5.1.3、Figure 5-1](https://documentation-service.arm.com/static/5f914801f86e16515cdc2a27)：Slave ERROR 使用先 `HRESP=1,HREADY=0`、再 `HRESP=1,HREADY=1` 的兩 Cycle Response；Master 可在第二個 Cycle 取消後續 Burst，輸出 IDLE。本 Guard 選擇取消並 Fail-Closed，不繼續剩餘 Beat。

原始 `src/ebu/ebu.sv` 的 HRESP Input 仍標示 `Presently ignored`。本輪結果不表示 CPU Bus Error Trap、CPU Recovery、Checkpoint、Rollback 或 Instruction Replay 完成。

## 原始失敗與最小修正

`f3b-run-002` 使用修改前 RTL，在第一個 ERROR 案例失敗。原始 FST 轉出的 `failure-bus-state-002.json` 顯示：第一個 ERROR 已被取樣後，`M_HRESP=1`、`M_HREADY=1`、`data_phase=1`、`fault_valid=0`，但 `M_HTRANS=BUSY`。

原因：原本 `busy_gap` 只看 `context_active`、`context_accepted<8`、Address Phase，沒有考慮 `error_seen`。中途 ERROR 後沒有新授權，卻可能永遠留在 BUSY；這與本 Guard 的取消／HALTED 政策不一致。規範容許 ERROR 後繼續 Burst，不代表永久 BUSY 已完成合法取消。

最小修正：在既有 `error_seen` 鎖存後，優先輸出 `M_HTRANS=IDLE`。第一個 ERROR Cycle 仍保持原本的 BUSY／Control；其取樣後開始第二個 Cycle，合法地改變 HTRANS。Address、Control、HWDATA、HWSTRB、Data Owner 及 Response Owner 不變。

沒有把正常 BUSY 改為 IDLE，也沒有更動 Output FSM、Validator 事件契約或 Response Barrier。

## State／Timing

| 階段 | 下游／Owner 行為 | 上游 A/B 行為 |
|---|---|---|
| ADDRESS Stall | 保存授權 Owner，HREADY=0 不接受 | Ingress 保存 Pending |
| DATA Wait | HRESP=0、HREADY=0；不完成 | 不回傳假 Response |
| ERROR Cycle 1 | HRESP=1、HREADY=0；鎖存 error_seen，不產生 down_complete | 尚未收到 ERROR |
| ERROR Cycle 2 | HRESP=1、HREADY=1、HTRANS=IDLE；僅完成舊 Data Owner | 尚未收到 ERROR |
| RESPONSE | 緩存 HRDATA／ERROR，gate_fault[1] Sticky，等待共同 Ready | A/B 同 Edge 接收內部 Response |
| Ingress ERROR_1 | 下游保持 IDLE，無新 Address | 兩側 HRESP=1、HREADY=0 |
| Ingress ERROR_2 | Output 處於 RELEASE | 兩側 HRESP=1、HREADY=1，舊 Owner 完成一次 |
| HALTED | 維持 IDLE，禁止新 Authorization／Address | 可接受剩餘 Ingress Credit，但不能產生下游交易或假成功 |
| 共同 Reset | 同時清除 Guard、Source、Slave Protocol State | 新 Sequence；RAM 不清空 |

所有 Ledger 以 Rising Edge 更新前訊號取樣，TB 在 Falling Edge 驅動、Rising Edge 後 `#2` 再檢查 NBA 完成狀態。Clock Period=10ps；不是 Performance Baseline ROI。ERROR Stall 例外只允許已取樣 ERROR 後改變 HTRANS，其餘 Control／Write Data 仍必須穩定；一般 HREADY Stall 則檢查全部 Bus 穩定。

例：rv64 Epoch 71、Beat Index 3（0-based，第 4 Beat）、Write、同步、三個 Wait States：下游 ERROR Edges 為 **45055／45065ps**；A/B 上游 ERROR Edges 為 **45085／45095ps**。Response 延後送達但沒有換 Owner。

Validator `accepted_count/completed_count` 仍保留實際完成數。中途取消後 `burst_active` 保留未滿八筆的 Context 作診斷，直到 Reset；對外已由 `error_seen` 明確取消為 IDLE，且 HALTED 不再使用該 Context 授權。不得把此 Context 當正常完整 Burst。第八筆 ERROR 則在最後 Data Completion 後清除 active，Counts=8/8。

ERROR 案例要求 `gate_fault=3'b010`、Comparator Reason=0、Validator Fault=0；來源沒有被覆寫成 Mismatch／Validator Fault。

## 測試與實際結果

新檔案：`tests/ahb_lockstep/f3b_error_tb.sv`、`tests/ahb_lockstep/run_f3b.py`。所有新 ERROR 案例走完整 A/B Ingress → Pair → Comparator → Validator → Output，不使用 force。

每寬度：8 個 Beat 位置 × 3 種 A/B Skew × 2 組 Wait／Address Stall × 3 種方向／Slave 語意 = **144 ERROR cases**。

三種 Slave 語意分別為 Read ERROR、Write ERROR 不提交、已授權 Write 在 ERROR Completion 提交；各 48 cases／寬度。另測試正常 INCR8／SINGLE、Read／Write、各 Beat Stall，以及每次 Reset 後合法 INCR8 Write／Read。

| Address／Data Width | ERROR cases | Reset cases | Authorization／Acceptance | Data Completed | A／B Completed | Write Effects |
|---|---:|---:|---:|---:|---:|---:|
| 56／64 | 144 PASS | 6 PASS | 各 768 | 766 | 各 763 | 441 |
| 34／32 | 144 PASS | 6 PASS | 各 768 | 766 | 各 763 | 441 |
| 32／32 | 144 PASS | 6 PASS | 各 768 | 766 | 各 763 | 441 |

合計 **432 ERROR cases、18 Reset cases PASS**；三組 INCR8 的 Beat 1～8 全部驗證。每寬度 148 個下游 ERROR Completion（含 Reset 測試），上游 A/B 各完成 145 個 ERROR；差異為三個已緩存 ERROR Response 被共同 Reset 取消。另兩個已接受 Data Owner 在 ERROR 期間 Reset，沒有 Data Completion。因此 768→766→763 的差額均有 Owner Ledger，沒有假完成或交易錯配。

六個 Reset 狀態：ERROR 第一 Cycle 取樣前、第一 Cycle 取樣後／第二 Cycle 完成前、Output RESPONSE、上游 ERROR_1、上游 ERROR_2、HALTED。Reset 同時清除 Slave Pending；RAM／Shadow RAM不清空。

## Memory Side Effect

每寬度 441 個 Write Effects，其中 **393 個 OKAY Write、48 個已授權 ERROR Write**。ERROR Write 是否有 Side Effect 是 Slave Model 契約，不可僅因 HRESP=1 就宣稱零寫入。

- 不提交 ERROR Write：RAM Before／After 完全一致；Prefix 正常 Writes 保留。
- 提交 ERROR Write：只更新該已接受 Owner 的 Strobe Byte Lanes，與獨立 Shadow RAM 一致；Ledger 標示 `error_owner_write_effects=1`。
- Fault 後新 Write Side Effect、Authorization、Address Acceptance、假成功 Response：**0**。

TB 在 ERROR 後嘗試新 Request，驗證即使 Ingress 接受剩餘一筆 Credit，也無法繞過 Sticky Fault 進入下游。沒有 Rollback 宣稱。

## 執行與 Regression

```bash
python3 tests/ahb_lockstep/run_f3b.py artifacts/ahb-lockstep-step3f/f3b-run-003
```

完整 Lint／Build／Simulation argv／cwd 保存在 `*-command.json`。Verilator 5.036，`--timing --assert --trace-fst --timescale 1ps/1ps`，另有 `--lint-only`。重新執行需指定新的不存在目錄。

Regression Root：`artifacts/ahb-lockstep-step3f/f3b-regression-run-001/`，各 Root Command JSON 保存實際命令：F1 103 PASS；F2 三寬度各 37 transactions PASS；F3a 1008 Mismatch／21 Reset／6 Module-Level cases PASS；3B～3E PASS；Controller Gate 25 cases／148 transactions PASS；EBU Gate 27 cases／236 transactions PASS。

最終 F3b 與 Regression 0 Warning／0 Error，Assertions 啟用；新 Python Ruff py39／py313 PASS，未對 Artifacts 做自動修正。`git diff --check` 與新增正式檔案 Whitespace Check PASS。

## Problems & Solutions／證據

- run-001：Verilator 的階層式 Enum 常數參照觸發 Internal Fault；`--debug --gdbbt` 定位 Broken ENUMITEMREF。僅在 TB 使用與實際 enum 順序一致的 HALTED 編碼觀察，未刪除 Assertion 或更改功能 RTL。
- run-002：原始 Guard 的 ERROR→IDLE 取消測試 FAIL；原始 Log／FST／CSV 保留，另附 FST 衍生 VCD 與正確解析的 `failure-bus-state-002.json`。第一次解析腳本的 Root Scope 不符產生空值 JSON，也保留且不作判定依據。
- run-003：局部 `error_seen` 修正後三寬度全 PASS。
- 新 Python Docstring 最初觸發 Ruff RUF002；改為 ASCII 冒號，不使用 Suppression。

最終結果：`artifacts/ahb-lockstep-step3f/f3b-run-003/`。各寬度內保存 `guard-events.csv`、`error-cycle-trace.csv`、`error-ledger.csv/json`、`owner-ledger.csv/json`、`memory.csv`、`f3b-error.fst`。Root 保存 Summary、Source SHA256／Snapshot、保護檔案 Hash、工具版本、Logs／Commands、Git Diff／Audit。

## 限制與待辦

F2b **NOT_MET**，`full_F2_acceptance_complete=false`；實測下游同 Edge Address/Data Overlap=0。完整 Guard 的「舊 Data Pending 時下一筆 Mismatch」仍為 **NOT_REACHABLE_IN_CURRENT_ARCHITECTURE**；沒有以 Module-Level 結果代替完整整合。

真實 CPU Bus Error Trap、真雙核心／Shared Uncore、SoC Reset Coordinator、Recovery／Rollback、完整 CPU Performance 都 **Pending**。本輪只完成 Guard 在合法兩 Cycle ERROR 下的處理；不自行進入 F3c 或 Performance Optimization。
