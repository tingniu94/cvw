# Step 3F F2 — INCR8 Output Gate / BUSY Scheduler

## 範圍與結果

HEAD 8b4c9a1ef、Branch ahb-lockstep-step3。受控Synthetic A/B的序列化INCR8路徑完成；三種寬度PASS、F1全部103案例PASS、Step3B～3E Regression PASS，最終Build零Warning。未接真實Core B或Shared Uncore，未修改CPU/Cache/IFU/LSU/原EBU/buscachefsm/config，未實作F3完整Fault/Error/Reset政策。

**重要驗收限制：本版不支援下游同Edge舊Data Completion＋新Address Acceptance。** F1要求一筆Outstanding，故Scheduler以BUSY序列化；實測下游Overlap為0，不把它列為PASS。已驗證的同Edge重疊是上游Ingress：SINGLE Write→Read及最後Burst Response→SINGLE。若驗收要求真正下游Pipeline，此項仍Pending，需另行審查F1 Event/Owner契約，不應直接以裸HREADY新增Overlap。F2不是所有AHB模式或完整Fault-safe設計完成。

## Architecture / 授權

`Synthetic A/B → 原Dual Ingress → 原Pair → 原Registered Comparator → F1 Validator → Output Backend → Controlled Slave`。

下游Response經原Saved Response/Atomic Fork回Ingress A/B；M_HREADY只提供Backend及Validator Consumer Credit，不廣播給上游。

新增兩個既有Module的`ENABLE_INCR8`參數，預設0；與CPU `BURST_EN=1`無關。關閉時選取原SINGLE政策；啟用時instantiate原F1 Validator，無修改F1。Validator與Backend在同Edge消耗MATCH，Backend保存cmd_addr/write/size/burst/trans/prot/wdata/wstrb及owner_seq。Write Data/Strobe來自Saved Comparator Payload，不用live A/B Bus。

授權條件：Registered MATCH、Backend EMPTY、無Gate Fault、M_HREADY提供Credit、F1處於可接收且無Comparator Fault、所有Validation合法。非法命令以policy_reject消耗並Sticky Fault，不建立ADDRESS。既有Unsupported檢查保留在SINGLE模式；Burst模式使用F1的完整Allowlist/Alignment/Boundary/Sequence/Control檢查。

## FSM / Address-Data Timing Table

事件在Rising Edge前取樣，NBA更新；TB Falling Edge驅動，Rising Edge後檢查。Clock 10ps。

| 原狀態 | 事件／輸出 | 下一步與Owner |
|---|---|---|
| EMPTY | MATCH及F1授權 | 保存完整Owner，轉ADDRESS |
| ADDRESS | 首Beat NONSEQ；其餘SEQ；HBURST=5 | HREADY0保持全部Address/Control與Saved Data；HREADY1才down_accept |
| DATA，第1～7筆 | Address Phase為BUSY，Address指向下一Beat | 舊Write Data/Strobe仍屬已接受Owner；HREADY0保持；HREADY1才down_complete |
| RESPONSE | 保存完成的HRDATA/HRESP | 等A/B都ready才一次Atomic Fork |
| RELEASE | Ingress各自回覆Core-facing Completion | 兩側完成前保持Response Owner，之後回EMPTY |
| EMPTY/RESPONSE/RELEASE，Burst未滿8筆 | BUSY及下一Address/相同Burst Control | 等下一合法MATCH，不建立有效Beat |
| 第8筆Address接受後DATA | 下一Address Phase為IDLE，不再BUSY | Context仍Active、Accepted8/Completed7；最後Data完成才清Context |
| HALTED，未完成Burst | 保持BUSY、無有效Address | 不將Partial Burst偽裝正常結束，等待共同Reset；F3完整政策Pending |

F1的`down_accept`接Backend ADDRESS&&M_HREADY；`down_complete`接DATA&&M_HREADY，絕不把BUSY的HREADY當完成。Data Owner、Response Buffer、Burst Expected Address分開。`end_burst`接0：Backend自己只在已接受8筆Address後輸出IDLE；上游live IDLE/BUSY沒有被原Ingress保存，不在F2臆造結束事件。錯誤NONSEQ/SEQ等仍由Validator拒絕。

M_HADDR於BUSY使用Context Expected Address；其餘有效Address來自Saved Owner。Burst模式HWRITE保留Burst方向，不能依當前Address是否有效而清除舊Write Data。最後Address接受後的IDLE也不能清除Pending Data或Response。首筆與續筆HBURST皆保留INCR8，未轉SINGLE。

## Directed Tests / 實測

AW/DW/SW矩陣：56/64/8、34/32/4、32/32/4。32-bit INCR8測試不等於原rv32gc INCR16支援。

每組包含：

- 4個完整Burst：Zero-wait Read/Write各1個、逐Beat有Address/Data Stall的Read/Write各1個，共32 Beats。
- 4筆SINGLE，共36筆正常交易；含Write/Read、Burst→SINGLE。
- Aearly/Bearly/simultaneous，Peer Skew最長3cycles；BUSY等Peer與Consumer Credit。
- 各Byte Lane及混合Full/Partial Strobe，Byte RAM與獨立Shadow Memory核對；Read Data/Status同時回A/B。
- 最後Data Pending時Context仍Active、HTRANS=IDLE且不能提前回覆；共8個最後Data Stall Cycles。
- 2次上游同Edge Completion/Acceptance：舊Write→Read、最後Burst→SINGLE。
- 無Peer時0授權；Comparator初始Mismatch 0下游交易；相同非法Boundary Request MATCH後Validator拒絕。
- 中途非法第二Beat：前綴1筆已完成，非法Beat不授權、不產生Write、無假Response，保持BUSY與Active至Reset。僅此最小Fail-closed驗證，非F3全面測試。

| 每組寬度 | Authorized | Down Accepted | Down Completed | A Completed | B Completed | Policy Reject |
|---|---:|---:|---:|---:|---:|---:|
| 56/64/8 | 37 | 37 | 37 | 37 | 37 | 2 |
| 34/32/4 | 37 | 37 | 37 | 37 | 37 | 2 |
| 32/32/4 | 37 | 37 | 37 | 37 | 37 | 2 |

37=36正常交易＋1筆Fault前綴；33個INCR8 Beats=32完整Burst Beats＋1前綴，不能把它報為第5個完整Burst。Policy Reject兩次是初始Boundary及中途Address錯誤，另有Comparator Mismatch與未配對案例。

每組獨立CSV Replay：276 BUSY Cycles、31 Address Stall Cycles、51 Data Stall Cycles、2 Upstream Overlap Edges、0 Downstream Overlap Edges、Beat Latency 1～5 cycles。BUSY包含正常等待與Fault前綴後停等，不是純Peer Wait，也不是CPU Overhead。原ROI與Performance定義不變。

SV Assertions檢查：所有有效Address必有已授權Owner；NONSEQ/SEQ/Address/Control正確；Stall期間Master整組Payload穩定；每Beat一次Acceptance/Completion；Write Data/Strobe；Response不得早於Downstream Completion或重複，A/B Data/Status正確；Ledger逐Beat守恆。另有獨立Burst Oracle驗證BUSY位置、下一地址、Control、不可提前IDLE。額外合成Credit-Stress刻意強制BUSY時M_HREADY0，驗證保持與Backpressure；不宣稱這是無Pending Transfer時標準Slave應對BUSY產生的Wait。

Python Replay按Epoch及Owner Sequence還原Pair/MATCH/Auth/Accept/Data Complete/A/B Capture/Complete，核對37筆唯一Owner；資料與所有Cycle事件保存JSON。CSV的owner_seq在Authorization Edge仍可能是上一Owner，故Replay到Address Acceptance才取已保存的新Owner，不臆用同拍NBA後數值。

## 實際命令／證據

```bash
python3 tests/ahb_lockstep/run_burst_output.py artifacts/ahb-lockstep-step3f/f2-run-004
python3 tests/ahb_lockstep/summarize_burst_output.py artifacts/ahb-lockstep-step3f/f2-run-004
python3 tests/ahb_lockstep/run_burst_context.py artifacts/ahb-lockstep-step3f/f2-f1-regression-001
python3 tests/ahb_lockstep/run_guard.py artifacts/ahb-lockstep-step3f/f2-regression-001
git diff --check
```

Verilator5.036，F2使用`--binary --timing --trace-fst --assert --timescale 1ps/1ps`，完整argv/cwd/returncode、Source Snapshot/SHA256/HEAD/版本保存在每個run。Build以獲准sandbox外執行，處理ccache寫入需求。

F2結果：`artifacts/ahb-lockstep-step3f/f2-run-004/{summary,replay-summary,final-verification}.json`。各組根目錄`*-build.log/*-simulation.log`；runtime `guard-events.csv`、`events.json`（完整Cycle事件）、`transactions.json`（Address接受時資料）、`beat-ledger.json`（完整Owner生命週期）、`replay-summary.json`、`burst-output.fst`。

F1：`f2-f1-regression-001/summary.json`確認32/30/30/10＋Comparator1，共103案例PASS。舊模式：`f2-regression-001/summary.json`確認Step3E及巢狀3D/3C/3B全部PASS、Warning0。沒有修改或覆蓋舊run-001～007、其他Step artifacts及Backups。

## Problems & Solutions

- f2-run-001：Verilator無Warning，但C++ Build因ccache Read-only File System失敗；保留Log，以獲准外部Build重跑。
- f2-run-002：RV64 RTL/Assertions已PASS，但Python將CSV十進位HBURST=5誤當二進位字串101，離線Assertion失敗。改為int解析，未改RTL或降低檢查標準；原始資料保留。
- f2-run-003：三組PASS。之後補強每Beat Stall、最後Burst Response同Edge接受下一SINGLE及BUSY Credit Stress，最終採f2-run-004，全部PASS。
- 沿用F1已驗證FST，沒有再次觸發VCD SIGSEGV，沒有Warning Suppression或停用Assertions。

## Git / 後續限制

只修改既有ahb_lockstep_output與ahb_lockstep_guard，新增burst_output_tb/run_burst_output/summarize_burst_output及本文件，Meeting Log只追加。F1、Ingress/Pair/Comparator不變。既有config.ini修改、F1未提交檔、Artifacts/Backups均保留，未Commit/Push。

F3 Pending：中途Comparator Mismatch各位置、完整AHB ERROR取消/重建Response、所有Pending狀態共同Reset與下游Flush、安全Fault Drain/Recovery責任。已完成Write前綴不可Rollback。保持BUSY等待共同Reset不是自動恢復；不完整Burst不列正常完成。下游Pipeline Overlap、完整Controller/實際Uncore、真實Core B、CPU Performance均未驗證。本輪停止，不進入F3～F6、3G或Fault Injection。

## F2b：架構阻礙審查與停止紀錄（2026-11-23）

本輪依補充要求，在確認需要改動Ingress/Response契約後停止RTL擴充。沒有修改任何RTL或既有TB，沒有新增Backend-only合成MATCH正向測例冒充完整Guard。`full_F2_acceptance_complete=false`維持不變。F2b所需的實際下游Overlap未完成，不能列PASS。

### 實際阻礙

1. Output的ADDRESS與DATA為互斥FSM狀態，down_accept=address_phase&&M_HREADY、down_complete=data_phase&&M_HREADY；現有12組state/ready真值表不可能同時為1。
2. F1的READY→ADDRESS→DATA契約也互斥，DATA時禁止下一命令；只增加Output Register會違反Event Ownership。
3. 更根本的是每側Ingress只有一個Pending Slot。OFFER交出後進WAIT_RESPONSE；舊Downstream Data先完成，Backend才能保存Response，再Fork給Ingress，Ingress進RELEASE_OK之後才使HREADY=1，允許下一Address接受。下一Request還要完成Write Data Capture、Pair與Registered MATCH，才能授權。
4. 因此，保持目前契約時，下一筆Saved MATCH不可能在舊Data Completion之前存在。增加Output FIFO或讓F1同拍加減計數，都不會產生下一筆合法Payload。讀取尚未接受的live Address、提前宣告成功或對Write只先比Address而不比Data，都改變既定保證，不能作為本輪小修。

在新的及既有RV64/RV32/explicit32證據中，每組37個成功Owner、35條同Epoch相鄰Owner依賴鏈皆符合：舊DataComplete < 舊A/BComplete <= 下一A/B AddressAccept < 下一Pair <= 下一Auth < 下一DownAccept。最短下一Pair仍晚於舊Data3cycles。這是Source與實測相互核對，不把有限測試當成所有輸入的Formal證明。

### 真實Edge範例（本輪RV64 FST，1ps）

| Rising Edge | 事件 | 下游／Ownership |
|---:|---|---|
| 105ps | Owner0 Address接受 | NONSEQ，HADDR=0x100 |
| 115ps | Owner0 Data完成 | Address Phase為BUSY；沒有新Address Acceptance |
| 125ps | 兩側Response Capture | 仍屬Owner0 |
| 135ps | A/B完成Owner0 | 此後各側才有下一Address Credit |
| 145ps / 165ps | B/A接受Owner1 Address | Peer Skew，尚未Pair |
| 185ps | Owner1 Pair Handoff | 舊Data已完成70ps |
| 195ps | Registered MATCH授權 | 保存Owner1 |
| 205ps | Owner1 Address接受 | SEQ，HADDR=0x108；與115ps不同Edge |

PNG的事件值以Edge前為準；FST在Edge後會顯示NBA更新。`waveform-first-two-owners.png`與`waveform-burst-boundary.png`直接由本輪真實FST透過fst2vcd匯出再渲染，不是GTKWave GUI截圖，也不是合成的理想時序。渲染Script與VCD保留，可重現。

### 保留BUSY序列化是否仍可用

下游AHB不要求每拍都有有效Beat；合法BUSY和HREADY等待可維持Beat順序與INCR8語意。原Controller已具HREADY Stall處理，因此不支援Overlap本身主要降低吞吐量，並非必然的功能錯誤。但本輪沒有兩顆真實Core或實際Uncore的Hello Wally驗證；不能宣稱已證明整個SoC可用。Fault/Error/Reset與先前標記的Controller/Uncore驗證仍Pending。

### 最小修改與大幅修改的風險

- 保留現有序列化：不增加新的Owner風險，維持已測功能；保留Performance成本，F2b要求仍未達成。
- 只加Backend的Address/Data Slot：可供預先排隊的獨立Command Source使用，但本Guard沒有這種Source；不能解開上游因果依賴，單獨PASS會誤導。
- 實際全路徑Overlap：須先審查上游Request取得時點、Write Data取得／比較、Ingress Credit、Response Ownership/Queue，以及F1跨Burst的Address/Completion Context。最後SEQ Data未完成時接下一NONSEQ還涉及新舊Burst同時存活。單純加深Ingress也不保證可行，標準AHB下一Write Data在上一Completion/下一Address接受後才進入對應Data Phase。這是架構議題，不能保證靠Buffer改動就能兼顧全部原則。

沒有實作或聲稱這些變更安全；依本輪停止條件，保留目前MATCH-before-dispatch及Response正確性，停止擴大修改。

### 本輪重新執行與數字

新目錄`artifacts/ahb-lockstep-step3f/f2b-run-001/`：

- `f1-regression`：103 cases PASS。
- `step3e-regression`：Step3E及巢狀3D/3C/3B全部PASS。
- `f2-regression`：三組寬度各37 Auth、37 DownAccept、37 DownComplete、A/B各37 Complete；原全部案例PASS。
- 獨立Replay：每組BUSY276、Address Stall31、Data Stall51、Upstream Overlap2、Downstream Overlap0、Beat Latency1～5。這是未修改Guard的Unit數據，不是CPU cycles/CPI/SoC overhead。
- 本輪全部Build及Simulation returncode0；Build Warning0/Error0。F2b正向Overlap案例未實作，驗收NOT_MET，不與Regression PASS混淆。

實際命令及cwd存各driver-command.json、各Run的*-command.json。新增analyze_dependency.py、render_waveform.py只位於Artifacts，沒有改RTL/TB。環境缺少matplotlib，改用現有libcairo渲染真實FST，未安裝套件或更改工具。

Evidence ZIP包含RTL Snapshot、相對HEAD既有F2 Diff、本輪空RTL Diff、原TB/Assertions、Logs/JSON/CSV、依賴分析、PNG、技術文件及Codex回覆；不包含Generated Build Objects。FST位置／SHA256另存manifest，大型FST留原路徑。ZIP不是F2b成功證據，必須保留full_F2_acceptance_complete=false與架構阻礙結論。
