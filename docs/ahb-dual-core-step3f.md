# Step 3F F1 — Burst Context / Validator

本次範圍僅為獨立 Validator；不修改 Output Gate、不接入真實第二顆 Core、不實作 BUSY Scheduler。CPU、Cache、EBU、BURST_EN 與 Performance ROI 保持原狀。

## Interface 與責任

`ahb_lockstep_burst_context.sv` 接收 Comparator 的 Registered MATCH Saved Payload：`cmd_addr/write/size/burst/trans/prot/lock`。Write Data/Strobe 比對仍屬既有 Comparator；Validator 不重寫 Payload、不產生 AHB Response，也不驅動下游 Bus。`consumer_ready` 表示未來 Backend 可保存該命令；Backend 必須在 authorized Edge 保存原 Payload。

`cmd_valid && cmd_ready` 是命令接收；`authorized` 表示合法，`rejected` 表示接收非法命令並 Sticky Fault。`compare_fault` 立即禁止新授權，Fault 保存至共同 Reset。預設 `ENABLE_INCR8=0` 保持 SINGLE/NONSEQ 政策；啟用後額外支援 INCR8，不改 CPU BURST_EN。

新增獨立事件輸入 `down_accept`、`down_complete`：沿用現有 Step 3E Backend 事件意義，未於本輪接線。`end_burst` 是未來 Scheduler 明確宣告結束的事件，不是 live IDLE、BUSY 或 cmd_valid=0。既有 Ingress 不保存 IDLE/BUSY，因此僅憑有效 Request Stream 無法區分合法空檔與主動過早終止。F2 必須建立正確的事件 Adapter；F1 不宣稱已檢查 live AHB 的所有結束情境。

## State / Timing Table

所有事件在 Rising Edge 前取樣，狀態以 NBA 更新。TB 在 Falling Edge 驅動，Rising Edge 後 #1 檢查，Clock Period=10ps。

| 原狀態 | 事件 | 更新與授權 |
|---|---|---|
| READY、無 Context | 合法 NONSEQ 命令與 credit | authorized；保存 Burst Control；計數清零；轉 ADDRESS |
| ADDRESS | 尚無 down_accept | 持有 Pending，不接受第二命令，不推進計數 |
| ADDRESS | down_accept | accepted_count+1；INCR8 expected_addr 加一 Beat；轉 DATA |
| DATA | 尚無 down_complete | 保留 Owner，不授權下一命令 |
| DATA | down_complete、第1～7筆 | completed_count+1；回 READY，Context 保留 |
| READY、有 Context | 合法 SEQ 命令與 credit | 地址／Control 驗證後授權，轉 ADDRESS |
| DATA、第8筆 | 第8筆 Address 已接受，Data 未完成 | active=1、accepted=8、completed=7、beat_index=7 |
| DATA、第8筆 | down_complete | completed=8、active=0、回 READY；才算 Burst Data 全部完成 |
| 任意 | 非法命令、錯誤事件或 compare_fault | Sticky Fault，禁止新授權；已授權工作仍可被記帳 |
| 任意 | 共同 Reset | 清除 Fault、Context、Owner、計數 |

`beat_index` 在 DATA 表示目前 Data Owner，否則表示下一筆 Address Index；`expected_addr` 在 down_accept 後指向下一個 Address。最終 Data Pending 時 beat_index 不得回捲成0。

BUSY/IDLE 不是有效命令，不推進任何計數；若錯誤地把它們當 cmd_valid 命令送入，Validator 拒絕。一般沒有 Request 的等待也不觸發 premature-end Fault。未支援新 Address Acceptance 與舊 Data Completion 同拍：F1 採一筆 Outstanding，誤送事件會 Fault；F2 應以保守 Scheduler 沿用此契約，或另行審查 Pipeline 擴充，不能直接以裸 HREADY 接線。

## Validation

- SINGLE 必須 NONSEQ，INCR8 必須 NONSEQ 後接七個 SEQ。
- 支援32/64-bit Data Bus；HSIZE不得超過Bus寬度，Address須自然對齊。
- INCR8第一筆以加寬運算驗證最後 Address，禁止跨1KB及Address Width溢位。
- 後續地址必須等於 expected_addr；HBURST、HSIZE、HWRITE、HPROT保持一致；Lock仍不支援。
- 不支援的 Burst Type 維持拒絕。
- 地址、Data完成及授權分別計數。Reset取消的Pending不能當成功完成。
- compare_fault中止未授權工作；之前已完成的Write無Rollback。本模組只保存Fault，不實作下游中途Burst收尾、Error Response或Recovery。

Fault reason：bit0 policy/shape、1 alignment、2 boundary/overflow、3 sequence、4 address、5 invariant control、6 premature end、7 comparator fault、8 event ownership。

## Tests / Evidence

Runner：`tests/ahb_lockstep/run_burst_context.py NEW_DIRECTORY`，使用 exclusive create、保存Source Snapshot/SHA256、工具版本、完整argv/cwd、Build/Simulation Logs、FST Waveform、summary.json。Warning維持Fatal，無RTL Warning Suppression。

測試矩陣：AW/DW=56/64、34/32、32/32，另有預設舊模式測試。32-bit INCR8測試不代表原始rv32gc的INCR16已支援。Comparator整合測試使用實際ahb_lockstep_compare，兩側相同的跨1KB非法Request先MATCH，再由Validator拒絕。

Directed測試包含SINGLE、8筆INCR8、Read/Write所有合法HSIZE及剛好結束於1KB的合法Burst、錯誤Address/HSIZE/HWRITE/HBURST/HPROT/Sequence、Alignment、Unsupported/Lock、過早結束、最後Data Pending、最後Completion同拍end、Reset、Comparator Fault後只完成舊Owner、Consumer Backpressure、無Owner的Accept/Complete。所有完整Burst獨立計算授權/Accept/Complete各8次。

最終測試結果與Debug紀錄於下方追加；尚未完成的項目為Pending。F2/F3、Uncore整合、真實雙Core與Fault Injection均不在本輪驗收範圍。

## 最終實測結果

Verilator 5.036；`--binary --timing --trace-fst --assert --timescale 1ps/1ps`。使用 FST 保存完整 Waveform，未停用 Assertions 或 Warning。

| 執行組 | Case數 | 結果 |
|---|---:|---|
| AW56/DW64，INCR8啟用 | 32 | PASS |
| AW34/DW32，INCR8啟用 | 30 | PASS |
| AW32/DW32，INCR8啟用 | 30 | PASS |
| AW56/DW64，舊SINGLE模式 | 10 | PASS |
| 真實Comparator：相同非法A/B | 1 | PASS，MATCH後由Boundary Validator拒絕 |

上述Directed功能全部PASS；HSIZE迴圈造成不同寬度Case數不同。每個完整合法Burst的獨立Epoch Ledger確認authorized/accepted/completed均為8。Console中的accepts/completes是**原始事件刺激次數**，包含刻意輸入一次無Owner accept及一次無Owner complete，並非合法交易計數；不能直接拿全測試Console總數相減判定交易遺失。授權後Reset取消、Data Pending Reset取消也有單獨情境。最後Data未完成時active=1、accepted=8、completed=7、beat_index=7；Completion後active=0、completed=8，Assertions PASS。

現有 `run_guard.py` 重新執行Step3E及遞迴Step3D/3C/3B Regression全部PASS，Build Warning=0，原SINGLE/NONSEQ及unsupported政策保留。F1未接到舊Guard，不能以此結果宣稱下游INCR8 Scheduler已完成。

實際命令：

```bash
python3 tests/ahb_lockstep/run_burst_context.py artifacts/ahb-lockstep-step3f/run-007
python3 tests/ahb_lockstep/run_guard.py artifacts/ahb-lockstep-step3f/regression-001
git diff --check
```

每次Build/Simulation的完整參數、cwd、returncode另存於各目錄`*-command.json`與`*-result.json`。Build透過獲准的sandbox外執行，因ccache需要寫入非workspace目錄；未更改Git設定。

證據：

- `artifacts/ahb-lockstep-step3f/run-007/summary.json`、`final-verification.json`。
- 同目錄`rv64/rv32/explicit32/legacy/compare`各自Build與Simulation Logs位於run根目錄。
- `rv64/burst-context.fst`、`rv32/burst-context.fst`、`explicit32/burst-context.fst`、`legacy/burst-context.fst`、`compare/compare-validator.fst`。
- `regression-001/summary.json`；內層`step3d-regression/step3c-regression/step3b-regression`為原Regression。
- `source-snapshot/`、`source-sha256.json`、`environment.json`保存可追溯版本。

## Problems & Solutions

1. `run-001`：CLI對bit參數傳32-bit值引發WIDTHTRUNC，TB Address期望式引發WIDTHEXPAND。改成明確1-bit CLI literal，並在Address運算前將正整數轉成AW寬度；不截斷計數器。
2. `run-002`：ccache因sandbox Read-only File System失敗。改以獲准的sandbox外Build，未更改RTL。
3. `run-003`：初版22/22/22/10及Comparator測試PASS，但之後補強全HSIZE/Write與最終Pending Index，故不是最終交付版本。最終RTL的beat_index於DATA使用accepted_count-1，避免第8筆Pending回捲0。
4. `run-004`：補強測試於VCD runtime發生SIGSEGV，非Assertion訊息。`debug-001`提高Stack上限仍重現；`debug-002`使用AddressSanitizer，stack指向`VerilatedVcd::printStr/emitTimeChange`，null address寫入。本機runtime於bufferFlush將Timestamp Pointer清空，當Flush發生於Timestamp輸出可造成後續指標問題；未修改工具安裝。
5. `run-005`：註解以Verilator開頭被當成工具directive，已更正一般註解。
6. `run-006`：嘗試`$dumpflush`，但本機生成程式沒有flush呼叫，仍SIGSEGV。撤除無效處理，改用FST Backend；原Stimulus、Assertion及RTL保持，最終`run-007`全部PASS。無Warning Suppression、未關閉Waveform、未縮減案例。所有失敗目錄均保留。

## Meeting Summary / 下一步

已完成F1獨立Burst Context及Saved MATCH後合法性檢查，103個計數案例PASS，Step3B～3E Regression PASS。Address Acceptance與Data Completion分開，最後Data Pending及相同非法A/B有實測Assertions。未修改CPU/Cache/EBU/Output Gate、未改Performance ROI。

F2可在確認本輪後開始：依F1 consumer credit及事件契約接入原Backend，保存Payload、實作真實INCR8/BUSY排程及live bus結束事件Adapter。F1沒有實作該Adapter、下游Burst收尾、Error Distribution、四態/Formal或雙Core；無完整Burst Rollback或Fault Recovery保證。
