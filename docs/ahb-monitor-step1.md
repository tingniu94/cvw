# A-only Passive AHB Monitor — Step 1 實作報告

## 修改與保留

本次 RTL 只修改 `src/wally/wallypipelinedsoc.sv`，並新增 `src/ebu/ahb_monitor.sv`。

- SoC 移除舊 `A_H*` 中介線與 Guard 實例，恢復 HEAD 的 Core／Uncore 接線，再加入被動 Monitor。
- Monitor 的所有 ports 都是 input，不回饋或驅動 Bus；紀錄邏輯置於 `ifndef SYNTHESIS`，目前用於模擬觀察。
- `ebu.sv`、`ebufsmarb.sv`、`uncore.sv`、`wallypipelinedcore.sv` 均逐位元組確認與 HEAD 相同。
- `tests/riscof/config.ini` 的 Sail PATH 是原先已有的變更，本次未修改。
- 未加入 Core B、硬體 Comparator、Burst 轉換、Rollback、額外 request／response 通道。
- 未 commit、push、reset --hard、git clean 或刪除舊成果。

舊版完整備份位於 `backups/ahb_guard_before_passive_step1/`。先複製並逐位元組確認成功，才恢復 SoC；`SHA256.json` 保存原始雜湊，最後再驗證一次。

| 備份 | 內容 |
|---|---|
| `ahb_guard.sv.step1` | 舊透明 Guard／Monitor |
| `ahb_guard.sv` | 舊 Stage 2 Guard |
| `wallypipelinedsoc.sv` | 原先串接 Guard 的 SoC，兩版 Guard 使用相同介面 |
| `wallypipelinedsoc.sv.before_guard` | 原先已有的 SoC 備份 |
| `wallypipelinedsoc.sv.original` | HEAD 原始 SoC，用於建立基準 |
| `working-tree.patch` | 修改前未暫存差異 |

原位置的舊 Guard、Step 1 備份、SoC 備份均保留且未改寫。

## Bus 架構

修改前：

```text
Core（IFU／LSU → EBU／ebufsmarb）⇄ A_H* ⇄ Stage 2 Guard ⇄ H* ⇄ Uncore
```

修改後：

```text
Core（IFU／LSU → EBU／ebufsmarb）⇄ 原始 H* ⇄ Uncore → Memory／APB Peripheral
                                            │
                                            └→ Passive Monitor（只有 input）
```

原始 request 與 write data 由 Core 送往 Uncore；`HRDATA/HREADY/HRESP` 由 Uncore 回到 Core。Monitor 不介入任何方向的訊號傳遞。

## Monitor 行為與訊號

觀察 `HCLK`、`HRESETn`、`HADDR`、`HTRANS`、`HWRITE`、`HSIZE`、`HBURST`、`HPROT`、`HMASTLOCK`、`HWDATA`、`HWSTRB`、`HRDATA`、`HREADY`、`HRESP`。

位址寬度使用 `P.PA_BITS`，資料使用 `P.AHBW`，byte strobe 維持 Wally 的 `P.XLEN/8`。

- `HREADY && HTRANS[1]` 時保存有效 NONSEQ／SEQ 的 address/control。
- 保存的 pending transaction 在後續 `HREADY` 有效時完成；讀取當時的 read data／write data、strobe 與 response。
- 同一個 clock edge 可以完成舊 data phase 並接收下一個 address phase。
- `HREADY=0` 時保留 pending metadata，累計等待周期，不重複輸出。
- IDLE／BUSY 不建立新交易，但不會取消前一筆待完成 data phase。
- reset 清除待完成交易與計數。
- 每筆完成的 beat 最多一行紀錄；不將 burst 改寫或重新發送。

預設只顯示前 20 筆完成交易，`+AHB_MONITOR_LIMIT=0` 顯示全部，`+AHB_MONITOR=0` 關閉輸出。`addr_cycle/done_cycle` 以 reset 解除後第一個上升緣為 cycle 0。

## 測試命令與結果

工作目錄為 repository root，工具為 Verilator 5.036。使用既有 `examples/C/hello/hello` ELF，未重新編譯 C 程式。

先在原始 SoC 接線、尚未加入 Monitor 時執行：

```bash
WALLY=/home/tingniu94/cvw python3 bin/wsim rv64gc \
  --elf examples/C/hello/hello -s verilator -v \
  > /tmp/ahb-passive-validation/baseline.log 2>&1
python3 tests/ahb_monitor/extract_bus.py sim/verilator/testbench.vcd \
  /tmp/ahb-passive-validation/baseline
```

基準 VCD 另存於 `/tmp/ahb-passive-validation/baseline.vcd`。加入 Monitor 後執行：

```bash
WALLY=/home/tingniu94/cvw python3 bin/wsim rv64gc \
  --elf examples/C/hello/hello -s verilator -v \
  -a '+AHB_MONITOR_LIMIT=0' \
  > /tmp/ahb-passive-validation/monitor.log 2>&1
python3 tests/ahb_monitor/extract_bus.py sim/verilator/testbench.vcd \
  /tmp/ahb-passive-validation/monitor
python3 tests/ahb_monitor/check_results.py /tmp/ahb-passive-validation
```

基準首次編譯因沙箱內 ccache 寫入唯讀目錄失敗，經權限核准後以相同命令在沙箱外完成。Monitor 首次編譯發現 log limit 的 32/64-bit 比較警告，已將其改為 64-bit unsigned；最終編譯與執行成功。未因此更動 Bus 架構或工具設定。

| 比較項目 | 原始接線 | 加入 Monitor |
|---|---:|---:|
| Hello Wally 與 0–9 輸出 | 完成 | 完成 |
| 結束時間（VCD，ps） | 116160 | 116160 |
| Clock 上升緣，含 reset | 11617 | 11617 |
| 完成 beat 數 | 1541 | 1541 |
| Read beat | 1504 | 1504 |
| Write beat | 37 | 37 |
| Pending data phase stall 周期 | 1253 | 1253 |

14 個觀察訊號的**全部變化與時間戳**逐項一致；標準化 Bus event SHA-256 皆為：

```text
516632f3004ce8445e73541b2b726a2059d2754bdc42d11eae97751f87eab3eb
```

Monitor 的 1541 筆紀錄另與基準波形在 clock edge 前的值獨立解碼，確認 address/control、讀寫資料、write strobe、response、address/done cycle、wait cycle 全部一致。保留了原本的 burst 與 SEQ；第一筆為位址 `0x80000000`、HBURST=5、HTRANS=NONSEQ。

Hello ELF 的原有 testbench 會印出 `Single Elf file tests are not signatured verified.`；本次驗證的是程式完成、可見輸出與 Bus 波形一致，並非新增 ISA signature 或 lockstep 驗證。

另執行小型 Monitor 測試。當時使用 `/tmp/ahb-passive-validation/monitor_tb.sv`，其內容原樣保存為 `tests/ahb_monitor/monitor_tb.sv`；可用下列等價命令重跑：

```bash
verilator --binary --timing --assert --top-module monitor_tb \
  --Mdir /tmp/ahb-passive-validation/unit-obj \
  src/ebu/ahb_monitor.sv tests/ahb_monitor/monitor_tb.sv
/tmp/ahb-passive-validation/unit-obj/Vmonitor_tb
```

結果：`MONITOR_TEST_PASS`，涵蓋讀寫重疊、連續 stall、IDLE/BUSY、兩周期 error response 與 reset 取消 pending transaction。`git diff --check` 也通過。

完整測試 log、兩版標準化 Bus events、交易清單與摘要另保存在 `backups/ahb_guard_before_passive_step1/validation/`。離線 Python 比對程式只用於驗證，沒有加入硬體 Comparator。

## 下一階段：A-only Arbitration／Guard 骨架

新增 SoC 層級的共用 Bus Arbitration Unit，先僅有 A 輸入，owner 固定為 A，Guard 預設允許。保持 AHB 值與時序透明，Monitor 留在共用 Bus 旁被動觀察。

保留 Core 內部既有 EBU／IFU-LSU 仲裁，也保留 Uncore。先定義 Guard policy 與阻擋時的完成方式，再加入主動控制；現有 EBU 未使用 HRESP，不能假設回傳 error 就會產生 Core access fault。未來真正需要第二個來源時，再擴充共享仲裁的 address/data owner 與回應選路。本次未實作這些功能。
