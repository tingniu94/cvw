# Step 3G-2：真正 Dual-Core Hello Wally

本輪基準為 `ahb-lockstep-step3` / `2ed411b09`。沿用 `wallylockstepsoc` 的真正 `core`、`core_b`、唯一 `ahb_lockstep_guard` 與 `uncoregen.uncore`，沒有修改 Wrapper、Guard、原始 CPU、Cache、EBU、Uncore 或 rv64gc；`BURST_EN=1` 不變。

## 實作與終止條件

`testbench/testbench.sv` 透過 `CVW_DUAL_CORE` 選擇 DUT，保留原 Single-Core 預設、Memory Loader 與階層。新 `common/dualcore_monitor.svh` 在 Rising Edge 前取樣兩側 PC、Instruction、Retirement、AHB 與 Guard 事件。兩側各自退休對實際 ELF `tohost` 的成功 Store，且交易全部 Drain 後，才允許既有 TB 正常結束；250,000 Cycles Watchdog 防止無限等待。

`run_3g2.py` 固定 Hello ELF 與載入檔案、明確列出正式追蹤 RTL、保存 Source/Input SHA256，使用原 Makefile 與 Verilator 5.036、Assertions、Timing、FST。沒有混入未追蹤舊 `ahb_guard.sv`。`verify_3g2.py` 獨立重播 CSV，逐 Owner 核對保存資料、Pair、MATCH、Authorization、下游接受/完成、兩側 Response 及真正 UART Write。

## 實際結果

證據：`artifacts/ahb-lockstep-step3g/3g2-run-002/`。

| 驗收 | 結果 |
|---|---|
| DUAL_WRAPPER_RUNTIME_PASS | PASS |
| DUAL_CORE_FETCH_PASS | PASS：A/B 各 200 Instruction Fetch Beats、25 ICache Ack |
| DUAL_CORE_RETIRE_PASS | PASS：A/B 各 4,117 Retirement，PC/Instruction 序列相同 |
| GUARD_REAL_AHB_MATCH_PASS | PASS：993 個有序 Owner，所有階段逐筆守恆 |
| DUAL_CORE_HELLO_PASS | PASS：雙側成功 tohost Store、Drain、正常 $finish |

雙側成功退休 Store 的 PC 為 `0x800002e4`、Instruction `0xd2f73023`；tohost 為 ELF Data Symbol `0x80001000`。從 Monitor Reset Release 計數至該 Store 為 Cycle 12,767；這只是觀察資料，並非既有 Performance ROI Benchmark。

993 筆交易的 A/B Acceptance、Pair、MATCH、Authorization、下游 Acceptance/Completion、A/B Completion 全部各 993。合法 NONSEQ→七筆 SEQ 的 INCR8 保留，BUSY 1,260 Cycles、Data Wait 705 Cycles；觀察到的下游同拍重疊仍為 0。UART Register Write 37 次，其中 Character Write 36 次，與新跑 Single-Core 逐 Byte 相同：

```text
Hello Wally!
0 1 2 3 4 5 6 7 8 9
```

實際串流包含 LF/CR 與尾端空白，精確 Hex 見 Summary。沒有 Duplicate UART Owner 或未授權 UART Write。此程式沒有外部 RAM Write（0 次），不能以此聲稱已驗證全部 Dirty Cache Writeback。DCacheFlush Helper 原行為保留；沒有新增兩側完整 Cache/Register File 比較。

## 問題與修正

`3g2-run-001` 原始失敗完整保留：UART 已正確、993 筆交易已完成，但新增 Monitor 沒認出 tohost，於 Cycle 250,000 觸發 Watchdog。原 Function-Only Label Map 不含 Data Symbol `tohost`，其查詢結果為零；並非 Guard Deadlock。只修正新增 Runner 以原工具 `riscv64-unknown-elf-nm -n` 從凍結 ELF 取得完整位址，傳入 Monitor。沒有以 Self-Loop、單側 TestComplete 或假 Completion 放寬成功標準。修正後 `3g2-run-002` PASS。

## Regression 與重現

`artifacts/ahb-lockstep-step3g/3g2-regression-run-001/results.json` 記錄全部十組命令 Exit Code 0：F1、F2、F3a、F3b、F3c、3B～3E、Controller、EBU、Real Uncore、Single-Core。F3c 的負向設定與預期 Timeout 由既有驗收器判斷，不能把負向 Log 的 Error 當成正常路徑成功。

F1 103 cases；F2 三組各 37 transactions；F3a 1,008 Mismatch / 21 Reset；F3b 432 ERROR / 18 Reset；F3c 248/248；Controller 25 cases / 148 transactions；EBU 27 cases / 236 transactions，均由本輪重新執行的既有 Runner 驗證。新 Dual Lint/Build 零 Warning/Error，Simulation Assertions PASS。新 Python Ruff py39/py313 PASS；git diff --check PASS。

```bash
python3 tests/ahb_lockstep/run_3g2.py artifacts/ahb-lockstep-step3g/3g2-run-NEW
python3 tests/ahb_lockstep/verify_3g2.py artifacts/ahb-lockstep-step3g/3g2-run-NEW artifacts/ahb-lockstep-step3g/3g2-regression-run-001/single/single/logs/uart.out
```

替換 `NEW` 為不存在目錄。完整 Build/Simulation 命令、Source Manifest、Input Hash、ELF Symbol 輸出在 Run 根目錄；Regression 重現腳本保存在 Final Audit。

主要檔案：`dual/dualcore.fst`、`dual/retirement.csv`、`dual/dual-events.csv`、`dual/bus-ledger.csv`、`dual/uart-ledger.csv`、`dual/logs/uart.out`、`verification/owner-ledger.json` 與 CSV、`verification/summary.json`、根目錄 `summary.json`。

## 保留限制

F2b **NOT_MET**，`full_F2_acceptance_complete=false`。沒有下游 Pipeline 重構。原始 EBU 忽略 HRESP，不能聲稱 CPU Bus Error Trap 或 Recovery。此為相同 Clock/Reset/Input、No-Fault Hello 的真正 Dual-Core Integration；未驗證真實 Core Fault Injection、其他工作負載、完整架構狀態等價或 CPU CPI/Overhead Benchmark。本輪停止於 3G-2，不進入 3G-3，不 Commit/Push。
