# Meeting 展示：A-only Passive AHB Monitor

本資料由既有 `sim/verilator/testbench.vcd`、Monitor Log 及已保存的 Bus events 整理，沒有修改 RTL，也沒有重跑模擬。

## 重要限制

既有 1541 筆完成交易中，288 筆為 HBURST=5 的 read beat，全部 waits=0；1216 筆 SINGLE read 與 37 筆 SINGLE write 各有 1 個 wait。因此目前**不存在同一個 Read Burst 內含 HREADY stall 的案例**。

展示採用同一個 5050–5350 ps 視窗，依序觀察 INCR8 Read Burst、UART status SINGLE read stall、Hello Wally 的 `H` SINGLE write stall。不可把後兩者的 stall 說成前面 burst 的 stall。若 meeting 必須展示「burst 本身被 slave 插入 wait」，需要另有帶 wait-state memory 的測試案例；本次沒有新增或執行該測試。

## 檔案與開啟方式

- `ahb-only.vcd`：從已驗證的 Bus events 匯出，只有 14 個既有 AHB 訊號，約 683 KiB，保留完整時間軸與原始 1 ps timescale。已與目前完整 VCD 的 AHB events／交易逐項比對一致。
- `ahb-meeting.gtkw`：14 個必要訊號，HTRANS 用 binary，其他 multi-bit 訊號用 hex。
- `overview.tcl`：將顯示範圍設成 5050–5350 ps，加入具名稱的 A–H markers。
- `uart-H.gtkw`、`uart-H.tcl`：UART write 的 5280–5360 ps 特寫。
- `selected-transactions.csv`、`selected-monitor.log`：本次展示的 beat 193–202。
- `source-sha256.json`：完整來源 VCD、來源 Bus events 與精簡 VCD 的 SHA-256。

從 repository root 執行：

```bash
gtkwave docs/waveforms/ahb-monitor-step1/ahb-only.vcd \
  docs/waveforms/ahb-monitor-step1/ahb-meeting.gtkw \
  -S docs/waveforms/ahb-monitor-step1/overview.tcl
```

UART 特寫：

```bash
gtkwave docs/waveforms/ahb-monitor-step1/ahb-only.vcd \
  docs/waveforms/ahb-monitor-step1/uart-H.gtkw \
  -S docs/waveforms/ahb-monitor-step1/uart-H.tcl
```

也可將第一個參數換成 `sim/verilator/testbench.vcd`，相同 `testbench.dut.H*` 路徑可沿用。精簡 VCD 是固定展示副本，避免後續模擬覆寫完整 VCD。

`.gtkw` 已靜態檢查訊號名稱／寬度；本次沒有啟動 GUI 做實際畫面檢查。檔案中的 dumpfile/savefile 為此 workspace 絕對路徑；搬到別台電腦時，明確指定 VCD 和 gtkw 如上，或修改這兩個路徑。

## GTKWave 時間定位

VCD 的 `$timescale` 是 **1 ps**，HCLK 周期 **10 ps**。5050 ps = 5.050 ns；5310 ps = 5.310 ns。工具若自動顯示 ns，請勿把 5310 ps 誤當成 5310 ns。

使用 `Time → Move To Time` 輸入 `5050 ps` 或 `5280 ps`，再縮放；也可用視窗 From／To 控制可瀏覽時間範圍並 Zoom Best Fit。上面的 Tcl 會直接設定精確可見範圍，無須手動拖曳。

A–H marker 時間：A=5070、B=5150、C=5220、D=5230、E=5240、F=5310、G=5320、H=5330 ps。可在 Move To Time 輸入 marker 字母跳轉。

上升緣同時有暫存器更新，GTKWave 在該時間點通常顯示更新後的值；硬體在該緣接收的是更新前的值。要讀第一筆 burst address，將游標放 **5065 ps**；第一筆 read data 放 **5075 ps**。UART address 放 **5305 ps**，data/stall 放 **5315 ps**，最後完成前的資料放 **5325 ps**。

## Read Burst：beat 193–200

建議特寫 **5050–5160 ps**。第一筆 address 出現在 [5060,5070) ps，於 5070 ps 上升緣被接受；最後一筆 data 於 5150 ps 上升緣完成。

固定控制值：HWRITE=0、HSIZE=3（8 bytes）、HBURST=5（INCR8）、HPROT=2、HMASTLOCK=0、HRESP=0、HREADY=1。

| Beat | Address 被接受（ps） | HADDR | HTRANS | Data 完成（ps） | HRDATA |
|---|---:|---|---|---:|---|
| 193 | 5070 | 0x80000200 | 10 NONSEQ | 5080 | 0x644260e2450152e0 |
| 194 | 5080 | 0x80000208 | 11 SEQ | 5090 | 0x80826105690264a2 |
| 195 | 5090 | 0x80000210 | 11 SEQ | 5100 | 0x619c00a78023619c |
| 196 | 5100 | 0x80000218 | 11 SEQ | 5110 | 0x07b78082e19c0785 |
| 197 | 5110 | 0x80000220 | 11 SEQ | 5120 | 0x00e781a3470d1000 |
| 198 | 5120 | 0x80000228 | 11 SEQ | 5130 | 0x0715100007378082 |
| 199 | 5130 | 0x80000230 | 11 SEQ | 5140 | 0x0207f79300074783 |
| 200 | 5140 | 0x80000238 | 11 SEQ | 5150 | 0x8023100007b7dfe5 |

例如 [5070,5080) ps：HADDR 已是第二筆 0x80000208、HTRANS=SEQ，但 HRDATA 是第一筆 0x80000200 的資料。這正是 AHB address/data pipeline，不能將同拍 HADDR 與 HRDATA 直接配對。

最後一筆 address 在 5140 ps 被接受後，Bus 的 HADDR/HTRANS 變為 0/IDLE；最後一筆 read data 仍到 5150 ps 才完成。Read 時 HWDATA/HWSTRB 不代表讀取內容，不應用它們判斷讀取成功。

## Read Stall：UART LSR，beat 201

精確交易 **[5210,5240] ps**，建議特寫 5200–5250 ps。

- Address phase [5210,5220)：HADDR=0x10000005、HTRANS=10、HWRITE=0、HSIZE=0（1 byte）、HBURST=0（SINGLE）、HPROT=3、HREADY=1；在 5220 ps 接受。
- Data phase [5220,5240)：前半 [5220,5230) HREADY=0，所以 5230 ps 上升緣尚未完成。
- 5230 ps 更新後 HREADY 變成 1，HRDATA=0x6060606060606060；在 **5240 ps** 上升緣完成。HRESP=0、HMASTLOCK=0。

UART_BASE=0x10000000；程式的 `uartSend()` 先讀 offset 5 的 LSR，等待 bit 5 的 THRE，再寫 offset 0 的 THR。0x60 的 bit 5 是 1，代表此次輪詢允許送出。

實際波形在 data phase 顯示 HADDR=0、HTRANS=IDLE、HPROT=2，這是下一個 address phase 的 idle 值；已接受的讀取仍是 0x10000005。Uncore 保存前一拍的 slave select，Monitor 也保存位址。HRDATA 重複 0x60 是 UART wrapper 將單一 byte 複製到全部資料 lanes 的既有行為。

## UART Write：Hello Wally 的字母 H，beat 202

精確交易 **[5300,5330] ps**，建議特寫 **5280–5360 ps**。

| 時間／phase | 訊號與行為 |
|---|---|
| [5300,5310) Address | HADDR=0x10000000、HTRANS=10、HWRITE=1、HSIZE=0、HBURST=0、HPROT=3、HREADY=1 |
| 5310 ps 上升緣 | 接受 address；開始對應的 write data phase |
| [5310,5320) Data wait | HREADY=0、HWDATA=0x4848484848484848、HWSTRB=0x01 |
| 5320 ps 上升緣 | 取樣到此前 HREADY=0，仍未完成；此緣更新後 HREADY 才變 1 |
| [5320,5330) Data ready | HREADY=1、HWDATA/HWSTRB 保持相同 |
| 5330 ps 上升緣 | 寫入完成，HRESP=0，Monitor 輸出 beat=202、waits=1 |

HMASTLOCK=0。0x48 是 ASCII `H`；因 HWSTRB=0x01，只有低 byte 有效，並非寫入八個 H。之後字母 e 的 THR write 在 5680 ps 接受、5700 ps 完成，可作第二個例子。

在 write data phase，實際 HWRITE=0、HTRANS=IDLE、HADDR=0，這些是下一個 address phase 的控制值；不會取消已接受的 write。應配對先前保存的 HWRITE=1 與此刻穩定的 HWDATA/HWSTRB。Monitor 只觀察，沒有產生或解除這個 stall。

## HREADY=0 的資料流

AHB address phase 和前一筆 data phase 可以同時存在。HREADY=0 會延長當前 data phase，該上升緣不接受下一個 address，也不完成目前交易；下一個 address/control 必須按原協定保持，write data 在等待中維持有效。Read data 在尚未完成時不必當作有效結果，應在 HREADY=1 的完成緣取樣。

這份波形中，下一個 address 是 IDLE，因此看到 HADDR=0 不代表原交易位址遺失。Monitor 的 pending/address 暫存保留原交易；它不在每個等待周期重複產生一筆紀錄，而是在完成緣產生一行 waits=1 的結果。內部記錄不驅動任何 H* 訊號。

## 加入 Monitor 前後一致的證據

原始完整 Monitor VCD：`sim/verilator/testbench.vcd`。
原始 baseline VCD：`/tmp/ahb-passive-validation/baseline.vcd`（暫存路徑，不應作為唯一保存證據）。

持久保存於 `backups/ahb_guard_before_passive_step1/validation/`：

- `baseline/bus-events.txt`、`monitor/bus-events.txt`：14 個訊號的標準化變化及時間戳，逐位元組相同。
- `baseline/transactions.json`、`monitor/transactions.json`：1541 筆獨立解碼交易，逐位元組相同。
- `baseline/summary.json`、`monitor/summary.json`：皆於 116160 ps 結束，1504 reads、37 writes、1253 stalled data cycles。
- `baseline.log`、`monitor.log`：兩次 Hello Wally 的完成與輸出；本案例 Monitor Log 第 285–294 行。

Bus event SHA-256 皆為 `516632f3004ce8445e73541b2b726a2059d2754bdc42d11eae97751f87eab3eb`。

本次只重新解析既有 VCD 並執行離線比對，沒有重新執行 Hello Wally：

```bash
python3 tests/ahb_monitor/check_results.py \
  backups/ahb_guard_before_passive_step1/validation
```

結果通過。另將精簡 VCD 解碼，確認其 Bus events、transactions 與完整 VCD 完全一致。原實作報告位於 `docs/ahb-monitor-step1.md`。
