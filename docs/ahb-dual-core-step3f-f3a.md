# Step 3F F3a：Mismatch、Fail-Closed 與共同 Reset

## 範圍與基準

基準為 `ahb-lockstep-step3`／`0a6d7cbf0`。沿用 Saved Payload MATCH → Burst Validator → INCR8/BUSY 序列化 Output → A/B Response Barrier；沒有修改任何功能 RTL、原始 CPU／Cache／EBU／Controller、`rv64gc` 或 `BURST_EN=1`。

本階段不是 F3b HRESP ERROR Handling、真實 CPU Recovery、Rollback 或真雙核心整合。F2b 仍為 **NOT_MET**，`full_F2_acceptance_complete=false`。

## 新增測試與事件定義

- `tests/ahb_lockstep/f3a_mismatch_tb.sv`：真正 A/B Ingress → Pair → Comparator → Validator → Output 路徑；獨立 Byte RAM、Shadow RAM、AHB Address/Data Ledger、上游 Response Assertions、共同 Reset。
- `tests/ahb_lockstep/f3a_output_tb.sv`：僅 Module-Level，透過 Output 公開 `inhibit` Port 驗證已授權 Owner 的責任，沒有 `force` Comparator Fault。
- `tests/ahb_lockstep/run_f3a.py`：四組 Lint／Build／Simulation、Payload 解碼、逐 Epoch／Ordinal Ownership、Memory Hash、Fault Edge 及 Source Snapshot 一致性檢查。

TB 在 Falling Edge 驅動；Oracle 在 Rising Edge 讀取更新前訊號；Stimulus 在 Rising Edge 後 `#2`、再到 Falling Edge 檢查 NBA 完成後狀態。Clock Period 為 10ps。這不是 Performance Baseline ROI。

Address Acceptance 使用 `M_HTRANS[1] && M_HREADY`；Data Completion 必須另有先前 Address Owner 且處於 DATA。BUSY 不建立 Beat。每個 Owner 以 `(reset_epoch, transaction_ordinal)` 識別，並核對 RTL `owner_seq`，不能只靠跨 Reset 會重複的 Sequence 值。

`guard-events.csv` 保留每個 Edge 的 Pair、MATCH、Authorization、Acceptance、Completion、Response、Fault、下游 Bus。`fault-evidence.json` 區分 Comparator 在 Pair Handoff Edge 的 NBA Fault 更新時間、下一個 Rising Edge 首次看到 Fault 的時間，以及持續觀察後的狀態。Beat Index 一律 **0-based**。

## Mismatch Matrix

每個有效欄位 × 8 個位置 × 3 種 Skew（B 先 3 Cycles／同步／A 先 3 Cycles）。只改 B 的 Core-facing 輸入，不注入內部 Fault。

| 欄位 | Read cases／寬度 | Write cases／寬度 | Comparator Reason Bit |
|---|---:|---:|---:|
| Address | 24 | 24 | 0 |
| HWDATA | 不適用 | 24 | 7 |
| HWSTRB | 不適用 | 24 | 8 |
| HWRITE | 24 | 24 | 1 |
| HSIZE | 24 | 24 | 2 |
| HBURST | 24 | 24 | 3 |
| HPROT | 24 | 24 | 4 |
| HTRANS | 24 | 24 | 5 |
| 合計 | 144 | 192 | 336 |

測試 HTRANS 的兩側都保持有效 Address：NONSEQ 與 SEQ 不同；IDLE／BUSY 不接受 Request，不能冒充同類 Mismatch。另有完整 INCR8 Read 刻意使 A/B Write Data／Strobe 不同，確認不誤判。

每個 Fault 前先完成合法 Prefix，Fault 後嘗試新 Address 並持續 12 Cycles；檢查 Sticky Fault、零新 Authorization／Acceptance／Completion／Write／成功 Response。完整 RAM Before／After 必須完全相同，並與 Shadow RAM 一致；資料含 Epoch 變化，避免跨案例重複資料掩蓋寫入錯誤。已完成 Prefix Writes 不回復。

## State／Timing 與可達性

| 狀態 | 已授權舊 Owner 的責任 | Fault 後新交易 | 驗證層級 |
|---|---|---|---|
| EMPTY | 無待履行 Data | 禁止授權 | Full Guard + Module |
| ADDRESS、HREADY=0 | Address／Control／Write Payload 保持；允許舊 Address 後續接受 | 禁止新授權 | Module |
| DATA、HREADY=0 | 保存 Owner／Data／Strobe；完成舊 Data 一次 | 禁止新授權 | Module |
| RESPONSE、Consumer 未 Ready | 保存舊 Read Data／Status，等待兩側 Ready | 禁止新授權 | Module |
| RELEASE、等待 A/B Completion | 只釋放舊 Response，不重送 | 禁止新授權 | Module |
| 最後 Address Accepted、最後 DATA Pending | 不提早清除 Burst Context；舊 Data 完成後結束其責任 | 禁止新授權 | Module |

單 Pending Slot 使下一筆完整 Request 必須等舊 Response 完成才能進入 Pair。因此，在完整 Guard 中「舊 Address／Data／Response Pending 時，下一筆 Comparator Mismatch」為 **NOT_REACHABLE_IN_CURRENT_ARCHITECTURE**。Module-Level 結果不可冒充完整 Guard 覆蓋。

Fault 傳遞：`cmp_fault` → Output `inhibit` → Validator Sticky Fault → Output Sticky `gate_fault[0]`。Validator 下一次取樣鎖存，Output 再下一次取樣讀取已鎖存的 Context Fault；不能要求兩級在第一次取樣後同時更新。`cmd_ready` 會先受 Fault Event 阻擋，因此此鎖存延遲不代表允許新授權。

## 共同 Reset

Reset 同時作用於 Guard、A/B TB Source、Slave Protocol State；RAM／Shadow RAM不清空。

七個完整 Guard 案例：ADDRESS 實際 Stall、Address 剛接受後 DATA Pending、DATA 實際 Stall、最後 Beat DATA 實際 Stall、RESPONSE Pending、RELEASE 等上游完成、單側 Peer Wait。Reset 後都執行新的合法 INCR8 Write／Read；另外驗證 Read 的無意義 Write Lanes 不造成 Mismatch。

守恆必須包含取消：Authorized−Accepted 對應取消的 ADDRESS Owner；Accepted−Data Completed 對應取消的 DATA Owner；Data Completed−A/B Completed 對應取消的已緩存 Response。已完成 Write 保留；取消協定狀態不等於 Rollback。真實 SoC Reset Coordinator 仍 Pending。

## 執行命令

```bash
python3 tests/ahb_lockstep/run_f3a.py artifacts/ahb-lockstep-step3f/f3a-run-005
python3 tests/ahb_lockstep/run_burst_context.py artifacts/ahb-lockstep-step3f/f3a-regression-run-001/burst_context
python3 tests/ahb_lockstep/run_burst_output.py artifacts/ahb-lockstep-step3f/f3a-regression-run-001/burst_output
python3 tests/ahb_lockstep/run_guard.py artifacts/ahb-lockstep-step3f/f3a-regression-run-001/guard
python3 tests/ahb_lockstep/run_controller_gate.py artifacts/ahb-lockstep-step3f/f3a-regression-run-001/controller_gate
python3 tests/ahb_lockstep/run_ebu_gate.py artifacts/ahb-lockstep-step3f/f3a-regression-run-001/ebu_gate
```

Runner 自動保存完整 argv／cwd；Verilator 使用 `--timing --assert --trace-fst --timescale 1ps/1ps`，另外執行 `--lint-only`。版本為 Verilator 5.036。新 Python 以 Ruff 0.12.4、`--no-fix --target-version py39` 與 `py313` 檢查，不掃描歷史 Artifacts。上述目錄均已存在，重現須指定新編號。

## 實際結果

最終加強 Stall Reset 的 `f3a-run-005`：全部 PASS，Lint／Build 0 Warning、0 Error，Assertions 啟用。

| Address／Data Width | Mismatch | 共同 Reset | 忽略 Read Write Lanes | Authorization | Address Accepted | Data Completed | A／B Completed | 合法 Write Effects |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 56／64 | 336 PASS | 7 PASS | 1 Burst PASS | 1317 | 1316 | 1313 | 各 1311 | 745 |
| 34／32 | 336 PASS | 7 PASS | 1 Burst PASS | 1317 | 1316 | 1313 | 各 1311 | 745 |
| 32／32 | 336 PASS | 7 PASS | 1 Burst PASS | 1317 | 1316 | 1313 | 各 1311 | 745 |

每個寬度 1654 個 Owner：1311 正常完成、343 共同 Reset 取消。取消包含 336 個 Mismatch Owner、1 個 Peer Wait、6 個已授權 Owner；最後六個分成 1 個 Address 尚未接受、3 個 Data 尚未完成、2 個 Data 已完成但上游 Response 尚未完成。因此 1317→1316→1313→1311 的差異均有逐 Owner 證據，並非交易遺失。

每個寬度均有 24 個「前四筆 Write 完成、第 5 Beat Mismatch」案例：每個案例合法 Prefix Write Effects=4，Fault／後續 Write Effects=0，Fault 後 RAM Changed Bytes=0。三寬度合計 72 個此類案例。全部 1008 個 Mismatch 案例的 Post-Fault Authorization／Acceptance／Completion／成功 Response 都為 0。

Module-Level 6 個狀態 PASS，共 12 Authorization／Address Acceptance／Data Completion／Response Fork；既有 Owner Drain 完成一次，沒有新授權。完整 Guard 的對應 In-Flight 新 Mismatch 仍不可達，未列為 PASS。

新 Python 的 Ruff py39／py313 均 PASS。`git diff --check` 與所有新增正式檔案的 Whitespace Check PASS。

Regression 已完成：F1 103 cases PASS；F2 三寬度各 37 Authorization／Acceptance／Data Completion／A/B Completion PASS；Step 3B～3E PASS；Controller Gate 25 cases／148 transactions PASS；EBU Gate 27 cases／236 transactions PASS。沒有修改 Regression 或降低標準。

## Problems & Solutions

1. `f3a-run-001`：ccache 遭唯讀沙箱拒絕，Build 失敗；保留原始 Log，取得執行權限後使用新目錄。不是 RTL Warning。
2. `f3a-run-002`：Module TB 在第一次 `inhibit` 取樣後就要求兩級 Sticky Fault 都完成，Assertion 失敗。修正 TB 為第一拍檢查 Validator／禁止握手，後續檢查 Output Sticky Fault；未改 RTL。
3. `f3a-run-003`：開發中迭代，Module Source 曾在執行期間調整，不作最終 Source Provenance；原始資料保留。run-004 起 Runner 在結束時核對所有 Source 與 Snapshot 一致。
4. Python Payload 解碼 Helper 最初觸發 Ruff B023；改為明確傳入 Width，不使用 Suppression。最終兩個 Target Version 都須 PASS。
5. 沒有發現本輪需修補的 Guard RTL 缺陷。補的是此前缺少的 Mismatch、Owner、Memory 與 Reset 證據。

## 證據與限制

最終結果位於 `artifacts/ahb-lockstep-step3f/f3a-run-005/`，Regression 位於同層 `f3a-regression-run-001/`。

各 `rv64/`、`rv32/`、`explicit32/` 內：`guard-events.csv`、`fault-ledger.csv/json`、`fault-evidence.json`、`owner-ledger.csv/json`、`memory.csv`、`f3a-mismatch.fst`。Module 證據為 `module/module-events.csv`、`module/f3a-output.fst`。Root 保存 Summary、Source Snapshot／SHA256、環境、Lint／Build／Simulation Logs 與命令。

F3b 的 Slave ERROR／兩週期 HRESP、Fault Drain 的 SoC 政策、真實共同 Reset Coordinator、真雙核心及 Shared Uncore 整合仍 Pending。不宣稱 Rollback／CPU Recovery／CPU CPI 或同拍下游 Pipeline PASS。
