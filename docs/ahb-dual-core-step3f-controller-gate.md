# Step 3F — Controller Compatibility Gate

## 工作目標與範圍

使用兩個原始`ahbcacheinterface`，其內部直接使用原始`buscachefsm`，將A/B輸出接現有ENABLE_INCR8=1的Guard及可控制等待的Byte RAM Slave。Cache端命令與Cache Word由TB提供；沒有直接驅動AHB NONSEQ/SEQ、HADDR、HWDATA或HWSTRB。Configuration直接include未修改的rv64gc/config.vh、config-shared.vh、parameter-defs.vh，完整cvw_t P由原設定建立；Assertions確認512-bit Cache Line、64-bit AHB/LLEN、BURST_EN=1。

本輪沒有修改任何Guard／CPU／Cache／IFU／LSU／EBU／Controller功能RTL。本Gate不是實際Cache SRAM/FSM、EBU仲裁、真CPU、Shared Uncore或Step3G驗證。F2b full_F2_acceptance_complete=false保留，沒有將上游重疊當成下游Pipeline。

## Architecture / 真正RTL

A/B各一個原始ahbcacheinterface → 原Ingress/Pair/Comparator/F1/Output → Controlled Slave → 原Response Fork → A/B Controller。

原始相依：src/cvw.sv、ahbcacheinterface.sv、buscachefsm.sv、swbytemask.sv、flopen.sv、flopenr.sv、generic/mux.sv。DCache組READ_ONLY_CACHE=0，Read/Write均走完整Data Path；ICache組READ_ONLY_CACHE=1，額外驗證Read-only生成分支。

Cache端提供CacheBusRW/CacheBusAdr/CacheReadDataWordM；Writeback資料依原始BeatCount選擇不同64-bit Word，經原wdreg與HWSTRBReg延遲，不是固定零。另用原Uncached介面BusRW/WriteDataM測八個Byte Lane SINGLE Store與Readback。

## 時序與Assertions

Rising Edge前取樣，原RTL在NBA更新；TB在Falling Edge更新激勵，tick於Rising後#2再到Falling檢查。Clock10ps，timescale1ps/1ps。Scoreboard與獨立Python Replay均以pre-edge事件判定；Ack時的Fetch Buffer改以FST同時間戳的NBA後值核對，避免漏掉最後Word。

| Edge/事件 | 實際行為與檢查 |
|---|---|
| 上游Address接受 | 保存Address/Control與原BeatCount、預期Cache Word，序號單調 |
| 下一Edge，Write Capture | 原wdreg已更新，HREADY即使0也保存正確Data/Strobe；與獨立pattern/byte mask比較 |
| Pair/MATCH/Auth | 兩側完整Saved Payload才允許Output；每Owner只一次 |
| 下游Address接受 | 比較所有metadata、NONSEQ/SEQ、HBURST5、地址每筆+8 |
| Data Wait | Address/Control與舊Data Owner必要資料保持；BUSY不算新Beat |
| 下游Data完成 | 比對獨立Shadow Memory；Write每Byte依Strobe更新一次 |
| A/B完成 | Response Data/Status正確且兩側同步，不早於下游完成 |
| CacheBusAck | 必須與上游最後Beat7完成同Edge，且8筆下游Data皆已完成 |
| Fetch Buffer | 依8個實際Read Response組512-bit期望值，比較原FetchBuffer完整快照 |

原Controller先輸出下一Address而Data仍屬前一Address；Scoreboard不使用live HWRITE解釋舊HWDATA。上游Write Data/Strobe於Stall期間保持。下游使用保守BUSY序列化，最後Address後HTRANS=IDLE但最後Data仍Pending。

## 實際結果

最終執行目錄`artifacts/ahb-lockstep-step3f/controller-gate-run-005/`，全部Lint/Build/Simulation/Assertions/獨立Replay PASS。

| 組態 | Cases | Pair/Auth/DownAccept/DownComplete | A/B Complete | Cache Burst | A/B Ack |
|---|---:|---:|---:|---:|---:|
| DCache Read/Write | 19 | 各106 | 各106 | 12（Read7、Write5） | 各12 |
| ICache Read-only | 6 | 各42 | 各42 | 5（全Read） | 各5 |

DCache：56個Cache Read Beats＋40個Cache Write Beats＋2個SINGLE Read＋8個Byte Store=106。ICache：40個Cache Read Beats＋2個SINGLE Read=42。

Read Refill PASS：DCache7次、ICache5次；A/B共24份完整512-bit Fetch Buffer快照與8個期望Word逐一相等。Writeback PASS：5次完整INCR8、40個不同Cache Word與完整Strobe；另外8個SINGLE Store逐一核對Byte Lane/Strobe，最後Readback確認所有Byte。沒有False Mismatch、Unexpected ERROR或Watchdog Timeout。

案例：同步Zero-wait Read/Write；Aearly3/Bearly2的Read、Bearly4/Aearly2的Write；每Beat Address等待1～3、Data等待1～4；連續Read→Read、Writeback→Refill、Refill→Writeback；Burst結束後接SINGLE。連續Burst由原FSM在最後Completion時產生新NONSEQ，DCache有3次、ICache1次上游Burst邊界同Edge接受，非人工AHB激勵。

| 代表案例 | Controller Window cycles（含首尾事件） |
|---|---:|
| DCache同步Zero-wait Refill | 49 |
| DCache同步Zero-wait Writeback | 57 |
| DCache Refill，Aearly3＋Wait | 89 |
| DCache Writeback，Bearly4＋Wait | 96 |
| DCache Refill，Bearly2＋Wait | 87 |
| DCache Writeback，Aearly2＋Wait | 96 |
| DCache連續Read/Read，兩Burst | 168 |
| DCache連續Write/Read，兩Burst | 177 |
| DCache連續Read/Write，兩Burst | 178 |

所有原始Case數據在cases.csv/json；每Burst獨立數據在burst-metrics.json。兩Burst Case表包含Driver啟動與交接，不拿來當CPU overhead。

## Counter定義與實測

- Controller Window：首個上游Address接受至最後A Completion，inclusive edge count；每Burst明確保存first/last cycle。
- Case cycles：Driver end_cycle-start_cycle，含啟動／連續操作。
- Controller總期間：最後sample cycle減第一個resetn有效sample cycle3，包含正常Idle/Drain。DCache1163-3=1160；ICache432-3=429，為Edge距離。
- Address Stall：ADDRESS且M_HREADY0；Data Stall：DATA且M_HREADY0。
- BUSY：HTRANS=01；Peer Wait：兩側完整req_valid XOR，沿用原Pair定義。
- Beat Latency：down_complete_cycle-down_accept_cycle，無Wait=1。
- 原Performance ROI、CPU cycles/CPI定義完全不變。

| 指標 | DCache | ICache Read-only |
|---|---:|---:|
| Controller總期間 | 1160 | 429 |
| Address Stall cycles | 180 | 69 |
| Data Stall cycles | 223 | 83 |
| BUSY cycles | 615 | 239 |
| Peer Wait cycles | 11 | 5 |
| Pair/Consumer Backpressure | 0/0 | 0/0 |
| 最後Data Pending的Wait cycles | 40 | 16 |
| Beat Latency min/max | 1/5 | 1/5 |
| 下游同拍Overlap | 0 | 0 |

這些是Controller/Guard Unit數據，不是完整CPU CPI或雙核心Overhead。Consumer Backpressure=0為本測試觀察值，不能宣稱已額外測到非零Consumer Backpressure；其既有測試保留在F2 Regression。

## 關鍵波形

- 首Write：545ps上游Address接受、585ps下游Address接受、595ps下游Data完成，原Write Data經wdreg保存。
- Stalled Write最後Beat：2905ps最後Address接受、2955ps最後Data完成、2975ps A/B CacheBusAck。
- 首Refill最後Beat：495ps最後Address接受、505ps最後Data完成、525ps CacheBusAck；最後Fetch Word於525ps NBA更新。

Ack比最後下游Data完成晚2cycles（所有Burst一致），不把Address8接受當成Data8完成。PNG直接由本輪真實FST匯出渲染，非GTKWave GUI截圖。controller-gate.gtkw已與VCD Header核對，未啟動GUI。

## 實際命令及Regression

```bash
python3 tests/ahb_lockstep/run_controller_gate.py artifacts/ahb-lockstep-step3f/controller-gate-run-005
python3 tests/ahb_lockstep/summarize_controller_gate.py artifacts/ahb-lockstep-step3f/controller-gate-run-005
python3 tests/ahb_lockstep/render_controller_gate.py artifacts/ahb-lockstep-step3f/controller-gate-run-005
git diff --check
```

本輪Regression存controller-gate-regression-001，分別執行原run_burst_context.py（F1 103cases）、run_burst_output.py（F2三組各37Owners）、run_guard.py（Step3E含3D/3C/3B），全部PASS。完整argv/cwd/returncode保存在Run JSON。Verilator5.036，--timing --assert --trace-fst --timescale1ps/1ps。Final Lint/Build零Warning/Error，沒有Suppression或停用Assertion。ccache需要獲准sandbox外寫入。

## Problems & Solutions

1. run-001 Runner錯用不存在的generic/mux/mux2.sv；核對後改成實際generic/mux.sv，原始RTL未改。
2. run-002 TB的兩個file descriptor直接作邏輯AND引發2個WIDTHTRUNC；改成fd!=0判斷，不截斷資料，Lint零Warning。
3. run-003 Lint PASS，Build因ccache Read-only File System失敗；獲准sandbox外執行新run-004。
4. run-004兩組Simulation第一次即全部PASS；沒有Guard/Controller不相容、沒有功能Assertion失敗。
5. 離線PNG Renderer初版Python try/except縮排SyntaxError，修正Renderer，不改Simulation或結果。最終三張真實FST PNG已生成及檢視。

## Evidence與結論

Run含Source Snapshot/SHA256、工具/HEAD/命令、Build/Lint/Simulation Logs、events.csv/json、beat-ledger.json、ack-fetch-ledger.json、cases.csv/json、burst-metrics.json、metrics/verification/final-verification JSON、FST/VCD、GTKWave設定及PNG、Codex回覆與進度、Git Diff及Evidence ZIP。ZIP排除Generated Objects及大型FST，另列原始路徑/Hash。

本Gate支持現有序列化架構與原始Controller相容，可作為後續EBU Gate或F3的起點；不表示完整Cache/EBU/Uncore/雙Core系統已完成，也不證明所有無界等待環境都不Deadlock。本輪只測No-Fault；Slave ERROR/Fault Drain/Reset Recovery、Interrupt/Flush中途交易仍Pending。F2b NOT_MET不變，不自行進入下一階段。

### 最終補強：全Slave Memory核對

run-004是首次全部Simulation PASS的版本；之後只追加TB最終4096個Byte逐一與Shadow比對及memory-actual.hex/memory-expected.hex Dump。最終交付採run-005，重新Lint/Build/Simulation/Replay/PNG全部PASS，交易/時序數字與run-004相同，兩組4096 Byte Dump均完全相等。原run-001～004與失敗資料不覆蓋。memory-and-boundary-verification.json另確認所有Ack晚於最後下游Data2cycles，及原Controller連續Burst邊界同Edge接受的Owner身分。
