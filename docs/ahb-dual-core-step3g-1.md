# Step 3G-1：Real Uncore Gate 與 Dual-Core Wrapper

## 範圍與結果

基準 `ahb-lockstep-step3`／`be73f8e8d`。結果分開標示：

- **UNCORE_GATE_PASS**：Synthetic A/B Source → 原始完整 Guard → 真正原始 Uncore。
- **WRAPPER_BUILD_PASS**：兩顆真正 `wallypipelinedcore` 的 Lint／JSON Elaboration／Port Check／完整 C++ Build PASS；沒有執行該 Binary。
- **REAL_DUAL_CORE_HELLO_PENDING**：沒有以 Gate 或 Wrapper Build 冒充雙 Core 程式執行。
- 原 Single-Core Hello Wally Build／Simulation PASS；原 `wallypipelinedsoc` 與 `testbench.sv` 未修改。

本輪沒有修改原始 CPU／IFU／LSU／Cache／EBU／Controller／Uncore／rv64gc 或 Guard 功能。`BURST_EN=1`、INCR8、MATCH-before-dispatch 與 Response Barrier 保留。未 Commit／Push。

## 架構與檔案

`src/wally/wallylockstepsoc.sv` 沿用原 SoC 介面與結構，新增 `core`／`core_b`、唯一 `lockstep_guard`、唯一 `uncoregen.uncore`。兩顆 Core 同一 P、clk、同步 reset、四種 Interrupt、MTIME_CLINT、ExternalStall；MHARTID 仍為原始 0。

每側 Core HADDR／HWDATA／HWSTRB／HWRITE／HSIZE／HBURST／HPROT／HTRANS／HMASTLOCK 分別進 Guard A/B。HRDATA／HREADY／HRESP 由 Guard 各自回傳，沒有廣播 Uncore HREADY。Guard M_* 接唯一原始 Uncore。Core 的 HCLK／HRESETn Output 接獨立觀察線；共同 HCLK／HRESETn 由 Wrapper 定義，沒有短接兩個 Output。Clock／Reset 一致性 Assertions 已編譯，尚未執行 Wrapper Runtime 驗證。

初版 Wrapper 明確限制 rv64gc 類型的 64-bit AHB／XLEN、512-bit I/D Cache Line、BUS_SUPPORTED／BURST_EN。沒有宣稱其他 SoC Configuration 也已驗證。

新增：

- `tests/ahb_lockstep/uncore_gate_tb.sv`：沿用既有 Synthetic Driver／Oracle，替換為真正 Uncore；不使用簡化 Slave 的 HREADY／HRESP／Memory Write。
- `tests/ahb_lockstep/wrapper_build_tb.sv`：只供 Build；Reset 保持 Assert，不執行 CPU 程式；若誤跑會由 Watchdog Fatal 結束，不能得到假 PASS。
- `tests/ahb_lockstep/uncore_gate_dpi.cpp`：原始 RAM／ROM `getenvval` DPI 的 Top-independent Link Helper。
- `tests/ahb_lockstep/run_3g1.py`：明確 Source Manifest、Lint／Build／Simulation、Frozen Hello Inputs、Source Snapshot／SHA256。
- `tests/ahb_lockstep/verify_3g1.py`：FST 轉 VCD 後按 Edge 前訊號獨立 Replay，核對 A/B Payload／Owner／實際 RAM Write／UART APB。

調整 `verify_f3c.py`：各案例先明確設定完整測試基準，再套用個別設定。修正依賴使用者手動 INI 最後模式的問題；沒有改使用者 `fault_config.ini`，沒有降低 248 個案例的預期結果。

## 真正 Uncore Gate

採原始 `cvw_t P`／rv64gc，完整 Uncore 含 RAM、ROM、AHB/APB、UART、CLINT／PLIC 等。RAM 測試區為原始 RAM Base 起 256 Bytes，初始值由 TB Backdoor 載入，後續寫入全部經實際 Bus／RAM RTL。Shadow RAM 只是獨立期望值，不驅動 Slave。

| 測試 | 結果 |
|---|---|
| RAM SINGLE Read／Write／Readback | PASS |
| 連續兩次 INCR8 Write、連續兩次 INCR8 Read | PASS |
| 八個 Byte Lane Write／Readback | PASS |
| 共同 Reset 保留 RAM，再 INCR8 Read／Write | PASS |
| APB UART THR Write 0x47 | 恰一次，PASS |
| NONSEQ／SEQ／BUSY／IDLE／Address/Data Owner | PASS |
| A Early／B Early／同步、A/B Response Barrier | PASS |

共 **61** Pair／Registered MATCH／Authorization／Downstream Acceptance／Data Completion／A Completion／B Completion，兩個 Reset Epoch。六個完整 INCR8 共48 Beats，另13筆 SINGLE。實際 RAM Write Effects=**33**，UART Write Effects=**1**，未授權／重複 Write Effects=**0**。

下游 BUSY=**297 Cycles**，實際 APB Data Stall=**1 Cycle**，Address Stall=**0**；沒有用假 HREADY 製造等待。RAM_LATENCY 保持原設定0。非零 Address Stall／更廣泛 Slave Wait Pattern 未觸發，不宣稱已覆蓋。

UART Ledger 核對實際 PSEL=8、PENABLE=1、PWRITE=1、PADDR=UART_BASE、PWDATA=0x47、PSTRB=1、UART MEMWb=0、DLAB=0。主控台實際印出一次 G；本 Gate 驗證 THR 接收／APB Side Effect，沒有把它當完整 Serial Frame 解碼。

原始 RAM 的 memwriteD／HADDRD 與 Data Owner 逐 Edge 核對；FST Replay 驗證33次物理 Write 與 Golden Byte Memory 最終相等。Read Data 對 Shadow Memory，兩側 Response 對相同緩存結果。共同 Reset 同時送 Guard／Source／Uncore，RAM 不清空；本 Gate Reset 為已完成交易後的 Quiescent Reset，沒有宣稱測到真正 Uncore 的 In-Flight Reset Cancellation。

## Wrapper Elaboration／Build

Verilator JSON AST 確認：

1. `core`／`core_b` 都綁定同一個原始 `wallypipelinedcore` 專用化 Module，P 相同。
2. 兩側九個 Request 與三個 Response Port 全部分別綁定 A_/B_ Nets。
3. Clock Output／Reset Output 獨立；八個共同輸入相同。
4. Guard M_* 與唯一 Uncore 的 Bus Nets 一一一致。
5. 保留 `dut.core`、`dut.core_b`、`dut.uncoregen.uncore`。沒有把舊 `ahb_guard.sv` 編入 Manifest。

`connection-check.json` 保存實際 AST 接線，`wrapper.tree.json` 保存完整 Elaboration；`wrapper-build.log` 證明完成可執行 Binary 的 Link，而非只有 Lint。

獨立 Runner 以原始 `sim/verilator/Makefile`、TESTBENCH／SOURCES／WRAPPER／WORKDIR Override 選擇 Wrapper Harness。沒有修改 `wsim`、Makefile 或原始 Testbench；`wsim rv64gc` 行為保留。Wrapper Binary 不會由 Runner 執行。

## 命令、環境與證據

```bash
python3 tests/ahb_lockstep/run_3g1.py artifacts/ahb-lockstep-step3g/3g1-run-006 --phase all
python3 tests/ahb_lockstep/verify_3g1.py artifacts/ahb-lockstep-step3g/3g1-run-006 --output artifacts/ahb-lockstep-step3g/3g1-run-006/verification-002
```

上述目錄已存在，重現需換新編號。`--phase gate/wrapper/single` 可獨立執行，但也必須使用新目錄。

Verilator 5.036；Clock10ps，`--timing --assert --trace-fst --timescale 1ps/1ps`。實際 Make／Lint／Build／JSON／Simulation argv、cwd、Env、Exit Code 全部在 Command／Result JSON。Single Simulation 使用複製後的相同 Hello ELF／memfile／objdump／addr／lab，保存在 inputs/，並保存 SHA256；正常結束、UART為 Hello Wally 與0～9，沒有簽章驗證宣稱。

Gate 有20ns Simulation Watchdog；每個 Runner 子程序有1800秒上限。Single 沿用原 Testbench Watchdog，另有子程序上限。Timeout 不會 PASS。

最終 Root：`artifacts/ahb-lockstep-step3g/3g1-run-006/`。

- `gate/uncore-gate.fst`、guard-events.csv、memory.csv、uart-effects.csv。
- `verification-002/ab-downstream-ledger.json`、owner-ledger.csv、ram-side-effects.csv、uart-apb-ledger.csv、uncore-replay.json。
- `wrapper.tree.json`、connection-check.json、elaboration-instances.json、wrapper-build.log；Wrapper 無執行 Log。
- `single/logs/uart.out`、single-simulation.log、inputs/、Input Hash。
- summary.json、Source Manifest／Snapshot／SHA256、Git Diff、最終 Audit。

## Regression 與 Problems & Solutions

F1 103 PASS；F2 三寬度各37 PASS；F3a 1008 Mismatch／21 Reset PASS；F3b 432 ERROR／18 Reset PASS；3B～3E PASS；Controller25 cases／148 transactions PASS；EBU27 cases／236 transactions PASS。保存在 `regression-run-001/`。其中初次 F3c 受手動 INI 模式影響而失敗，修正驗收 Driver 後 `regression-run-002/f3c/` 的248案例全符合預期。使用者 INI 保留。

- run-001：原 Memory DPI getenvval 缺 Link，新增獨立 Helper；不是協定缺陷。
- run-002：Gate 所有 Assertions 通過，但 UART G 與 PASS Marker 黏在同一行，修正 Runner 解析。
- run-003/004：新增 Wrapper 的診斷 Ports／B Address 宣告筆誤，依 Lint 修正；沒有改原始 RTL。
- run-005：舊 XML Elaboration CLI 觸發 Deprecated Warning；改用建議的 JSON API，不抑制 Warning。
- run-006：Gate／Wrapper／Single 全 PASS；Gate獨立 Replay亦PASS。
- 新 Replay Python Closure 綁定修正後，Ruff py39／py313 PASS。

最終 Lint／Build 沒有 Warning／Error；F3c 的刻意 Watchdog 負向案例另列，不當成 Unexpected Error。所有舊失敗 Log 保留。

## 3G-2 前置工作／限制

下一步才在原 Testbench 加可選 Dual DUT，保持既有 A／Uncore 階層；新增 B Retirement／PC／完成觀察，以及雙側完成與 Guard Drain 驗收。確認真正 Cache／HPTW／Flush、時間／Interrupt 的採樣一致性，不能僅憑本 Gate 判定真 Core 一定不 Deadlock。

目前沒有 Dual-Core Program Runtime、真 CPU Performance、CPU Bus Error Trap、Recovery／Rollback 結論；BootROM／其他周邊只隨 Uncore Build，不代表功能案例已測。F2b NOT_MET、full_F2_acceptance_complete=false、既有 NOT_REACHABLE_IN_CURRENT_ARCHITECTURE 限制保留。本輪完成後停止，不進入3G-2。
