<!-- SPDX-License-Identifier: GPL-3.0-only -->
# FFB Interceptor SimHub v0.3.0

`FFBInterceptor.SimHub` 是 .NET Framework 4.8 的 SimHub 外掛，透過
`\\.\pipe\ffb-interceptor-simhub-v1` 接收 DirectInput8 FFB 命令遙測。既有 Python
viewer 繼續使用原本的 pipe，兩者可以同時執行。

> **高扭力安全警告：**方向盤基座可能突然動作。第一次測試前請把硬體 gain 調到最低、
> 讓手部遠離轉動範圍，並準備可立即按下的實體急停。本工具不是硬體安全控制器；任何
> 顯示值都不能取代方向盤廠商的扭力、溫度與安全保護。

本專案只支援離線／單機測試，不提供反作弊規避、隱匿、任意程序注入或線上競技支援。
削峰結果代表遊戲送出的 DirectInput 命令接近上限，**不是實際馬達扭力**。

## v0.3.0 重點

- Launcher ZIP 內提供原生視窗版 `FFBInterceptor.Manager.exe`，可安裝／更新 SimHub
  外掛、管理多個遊戲設定檔、啟動 SimHub、做環境診斷及一鍵啟動遊戲。
- 建議的 Manager／Launcher 路徑不含、也不會寫入 `dinput8.dll`；遊戲資料夾保持不變。
- 削峰判定改用「同一裝置內，多個支援效果的瞬時命令絕對值相加」的保守上界；不同
  裝置不相加。
- Ramp 依播放時間內插，Periodic 依波形、phase 與 period 取瞬時值，Envelope 的 attack
  與 fade 會改變瞬時振幅。
- TriggerButton、資料缺口、session 重連及狀態容量超限都會明確降低可靠性；不可靠時
  `DataReliable=false`，並停止發布 `AtLimit`／`IsClipping` 削峰結論。
- 可發布的 SimHub 建置只接受相容矩陣中 **SimHub 9.11.22 的精確 SDK 指紋**。

## 建議使用方式：一鍵 Manager

1. 從可信的 v0.3.0 Release 取得 `FFBInterceptor-Launcher-0.3.0.zip`，完整解壓到新的本機
   資料夾；不要直接在 ZIP 內執行，也不要混入其他檔案。
2. 以一般使用者身分雙擊 `FFBInterceptor.Manager.exe`。Manager 本身不需要 .NET 或
   SimHub SDK，也不要用「以系統管理員身分執行」。
3. 選擇真正的離線遊戲 EXE 與 SimHub 安裝資料夾，按「安裝／更新插件」。只有安裝
   SimHub 外掛的子程序會要求一次 UAC；遊戲仍以一般使用者權限啟動。
4. 開啟 SimHub，在「設定 → 插件」啟用 **FFB Interceptor**。這是第一次唯一需要手動
   完成的 SimHub 步驟；再匯入隨包附上的 Dashboard／Overlay。
5. 回到 Manager 按「一鍵啟動」。可勾選自動開啟 SimHub；Manager 會確認外掛 pipe
   就緒、遊戲與固定 Launcher／Hook 架構相符，再建立新的遊戲程序。

SimHub 安裝根目錄必須位於實體固定本機磁碟；網路／卸除式磁碟、`SUBST` 磁碟代號、
junction 或其他 reparse 路徑會被拒絕。

Manager 會驗證 `SHA256SUMS.txt`、精確檔案清單、每個檔案雜湊、路徑安全、x86／x64
架構及發行通道的簽章政策。它不會附加既有 PID，也不允許替換任意 Hook DLL。

### 「不改 dinput8.dll」的精確意思

- Launcher ZIP 不含 `dinput8.dll`，不會新增、覆寫、改名或刪除遊戲資料夾內的檔案。
- Manager 只呼叫套件內固定架構的 `FFBInterceptor.Launcher.exe` 與
  `FFBInterceptor.Hook.dll`，並只建立使用者選定的新遊戲子程序。
- 執行期間會在新程序記憶體內載入固定 Hook，短暫同步遊戲入口點，並在第一條遊戲
  指令前還原原位元組；Hook 只替換尚未被其他元件修改的
  `dinput8.dll!DirectInput8Create` IAT 指標。

因此保證的是「不修改遊戲磁碟檔案」，不是「程序記憶體完全不變」。

## 安裝、升級與移除

### 安裝

優先使用上一節的 Manager。若只取得 `FFBInterceptor-SimHub-0.3.0.zip`，請關閉
SimHub，核對 Release checksum／attestation，並確認目標資料夾內確實有
`SimHubWPF.exe` 或 `SimHub.exe`。再透過 Windows 檔案總管把包內
`simhub\FFBInterceptor.SimHub.dll` 與 `simhub\FFBInterceptor.Core.dll` 複製到這個精確的
SimHub 安裝根目錄，最後啟用外掛及匯入 Dashboard。這是純手動安裝：不會建立 Manager
使用的受保護安裝狀態，也不會替既有同名檔案建立可由 Manager 還原的備份。套件不會
重新散布 `GameReaderCommon.dll`、`log4net.dll`、`SimHub.Logging.dll` 或
`SimHub.Plugins.dll`。

獨立 `Install-SimHubPlugin.cmd`／`Uninstall-SimHubPlugin.cmd` 不會自行要求 UAC。它們先
鎖住並驗證精確 manifest、逐檔 SHA-256、reparse point 與 Authenticode 狀態，之後才會
載入共用 helper；一般使用者直接執行會停止並導向 Manager，直接提升腳本也會拒絕。
Manager 保持整包 handle 鎖，以 `runas` 提升同一個已驗證的原生 Manager；提升後會先重鎖、
重驗整包，再用乾淨的最小環境啟動 System32 Windows PowerShell。腳本仍會重新鎖定及驗證，
透過一次性同步事件回報後才寫入；父 Manager 與提升 helper 都等到子程序結束才解鎖。
`-NoElevation` 只保留給不需管理員權限的受控測試目錄。

提升寫入 SimHub 或 `%ProgramData%` 狀態時，還會驗證固定實體 volume，依固定順序取得
跨程序、零共享的 delete-on-close mutation lease，再建立隨機 sentinel 並重驗每層目錄
身分；第二個同時操作會 fail-closed，程序崩潰後鎖會由系統回收，`-WhatIf` 保持純唯讀。

傳統 `dinput8.dll` proxy 仍是次要選項，會寫入遊戲資料夾；其備份、衝突與解除安裝
規則見 [PORTABLE.zh-TW.md](PORTABLE.zh-TW.md)。若目標是不改遊戲 DLL，請使用
Manager／Launcher，不要使用傳統 proxy。

### 升級

若原本由 Manager 管理：

1. 關閉遊戲與 SimHub，把新 ZIP 解壓到**新的空資料夾**，不要覆蓋舊套件。
2. 從新套件開啟 Manager，按「安裝／更新插件」。
3. 若偵測到受管理的不同版本，或受保護狀態指向另一個 SimHub 根目錄，先對原目錄按
   「解除安裝插件」安全還原舊版，再按「安裝／更新插件」。不要手動混放新舊
   Core／SimHub DLL，也不要直接切換狀態路徑。
4. 啟動 SimHub，確認外掛已啟用，再一鍵啟動遊戲；確認正常後才刪除舊套件資料夾。

若原本是透過檔案總管純手動複製：先關閉 SimHub，確認含有 `SimHubWPF.exe` 或
`SimHub.exe` 的精確安裝根目錄，只移除該目錄內的 `FFBInterceptor.SimHub.dll` 與
`FFBInterceptor.Core.dll`，再一次複製新包內同版本的兩個檔案。不要刪除或改動其他
SimHub 檔案。純手動路徑沒有 Manager protected state 或備份，不能使用 Manager 還原
手動覆寫前的檔案。

### 移除

1. 若外掛原本由 Manager 安裝且具有受保護安裝狀態，請關閉遊戲與 SimHub，再於 Manager
   按「解除安裝插件」。解除安裝器只處理狀態記錄且 SHA-256 仍相符的兩個外掛 DLL，
   必要時還原當時建立的備份；不確定或遭修改的檔案會保留並報錯。即使 SimHub 主程式
   已被升級程序移除，只要受保護狀態、固定磁碟、目錄身分與雜湊全部吻合，也能解除。
2. 若外掛原本是透過檔案總管純手動複製，Manager 沒有可用的安裝狀態或備份。請關閉
   SimHub，確認含有 `SimHubWPF.exe` 或 `SimHub.exe` 的精確安裝根目錄，並且只手動移除
   `FFBInterceptor.SimHub.dll` 與 `FFBInterceptor.Core.dll`；不要刪除其他 SimHub 檔案。
   Manager 無法保證還原純手動安裝前可能存在的同名檔案。
3. 已匯入的 Dashboard 會保留，請在 SimHub 內手動移除。最後可直接刪除解壓資料夾；
   Manager 路徑從未寫入遊戲資料夾，所以遊戲端不需清理。

## v0.3.0 削峰模型

### 瞬時效果值

- **Constant：**使用當下 magnitude，並套用 Envelope。
- **Ramp：**依效果開始後經過時間，在 start 與 end 之間內插，不再用兩端最大值代表
  整段效果。
- **Periodic：**Square、Sine、Triangle、SawtoothUp、SawtoothDown 會依 elapsed time、
  phase、period、offset 與 magnitude 計算當下波形；period 為零時視為不支援。
- **Envelope：**attack 由 attack level 走向持續振幅，fade 在效果結尾走向 fade level；
  Constant、Ramp 與 Periodic 的瞬時值都會受到影響。

有限長效果仍遵守 duration、start delay 與 iteration count；Pause 會凍結效果時鐘，關閉
actuator 只靜音而不凍結。`Unacquire`、acquisition loss、Stop、Unload、Release 與 Reset
也會更新已保存的播放狀態。

Condition、Custom 與未知效果因需要位置、速度、自訂樣本或裝置內部處理，在輸出時會
列入 `UnsupportedEffectCount` 並排除於數值模型。這會令 `ModelLimited=true`，但本身
不會虛構力值或必然令 `DataReliable=false`。效果與裝置 gain 另提供增益後估計；削峰
判定使用增益前命令，因此 gain 不會掩蓋命令已碰頂的事實。

### 同裝置保守絕對值和

對每個 DirectInput 裝置，v0.3.0 先把所有正在輸出、可建模效果的**瞬時命令絕對值**
相加，再取所有裝置中最大的那一組：

```text
UnclampedCombined = max_device(sum(abs(instantaneous effect command)))
Combined          = min(1, UnclampedCombined)
```

不同裝置的效果**不會互相相加**。同裝置內也不嘗試推測方向向量抵消，因此結果可能高估
實際合力；這是避免低估命令疊加的保守上界，不是 mixer 的精確輸出，更不是馬達扭力。
Dashboard gauge 使用截在 100% 的 `CombinedCommandPercent`，數字與峰值可用未截斷的
`UnclampedCombinedCommandPercent` 顯示超過 100% 的上界。

為相容 v0.2，`CommandLevel`／`CommandPercent`、`PeakCommandPercent` 與
`EffectiveCommandPercent` 保留「最大單一支援效果」語意；新 Dashboard 不再把它們當
主要削峰值。

預設門檻為 98% 進入、95% 離開；連續碰頂 100 ms 或設定視窗內削峰比例達 5% 時進入，
低於離開門檻 500 ms 後解除。預設比例視窗為 1 秒。

## 可靠性與容量界限

下列狀況會停止削峰結論，而不是猜測：

| 狀況 | v0.3.0 行為 |
|---|---|
| producer 回報掉幀／同 session 重連 | 清除可能過期的播放狀態，標記資料缺口 |
| 效果設定了 `TriggerButton` | protocol v1 看得到設定，卻看不到按鍵目前是否按下；標記 `TriggerStateUnavailable` |
| 狀態表容量超限 | 拒絕新增狀態並增加對應 drop 計數，標記 `StateCapacityExceeded` |

只要選取來源存在上述可靠性問題，`DataReliable=false`，`AtLimit=false`、
`IsClipping=false`、`ClipRatio=0`，全域事件也不會把該來源當成可信削峰來源。移除帶
TriggerButton 的效果後，該動態限制可解除；資料缺口或同 session 重連通常要建立新的
producer session。容量超限時先重啟遊戲；若 `SourceStateDrops`／`StateCapacityDrops`
仍不歸零，還要重啟 SimHub 讓偵測引擎重新建立，才能恢復完整可信狀態。

狀態記憶體有明確上限：

- 整個引擎最多保留 **64 個來源**；
- 每個來源最多 **64 個裝置**；
- 每個來源最多 **1024 個效果**。

超限值分別發布為 `SourceStateDrops`、`DeviceStateDrops`、`EffectStateDrops`，總和為
`StateCapacityDrops`。容量超限時不再發布削峰結論，不能把 drop 計數為零以外的畫面當成
完整模型。

## SimHub 屬性、事件與動作

所有屬性都有 `FFBInterceptor.` 前綴。

| 群組 | 屬性 |
|---|---|
| 來源 | `Connected`, `SourceCount`, `SelectedProcessName`, `SelectedProcessId`, `SelectedSessionId`, `SelectionMode`, `SelectionModeText`, `ManualSourceAvailable` |
| v0.2 相容單效果 | `CommandLevel`, `CommandPercent`, `PeakCommandPercent`, `EffectiveCommandPercent`, `EffectGainPercent`, `DeviceGainPercent` |
| v0.3 同裝置合併 | `CombinedCommandLevel`, `CombinedCommandPercent`, `UnclampedCombinedCommandLevel`, `UnclampedCombinedCommandPercent`, `CombinedEffectiveCommandLevel`, `CombinedEffectiveCommandPercent`, `PeakCombinedCommandLevel`, `PeakCombinedCommandPercent`, `PeakUnclampedCombinedCommandLevel`, `PeakUnclampedCombinedCommandPercent`, `DetectionLevel`, `DetectionPercent`, `AggregationModel`, `AggregationText` |
| 削峰狀態 | `AtLimit`, `IsClipping`, `AnyClipping`, `ClipRatio`, `ClipPercent`, `RatioWindowMilliseconds`, `ClipWindowText` |
| 模型與可靠性 | `DataReliable`, `ModelLimited`, `ReliabilityIssues`, `ReliabilityIssueMask`, `ReliabilityReason`, `ReliabilityText`, `TriggerStateUnavailable`, `StateCapacityExceeded`, `UnobservedTriggerEffectCount` |
| 診斷 | `ActiveEffectCount`, `UnsupportedEffectCount`, `LastEffectKind`, `DroppedFrames`, `ProtocolErrors`, `SourceStateDrops`, `DeviceStateDrops`, `EffectStateDrops`, `StateCapacityDrops`, `StatusText`, `Definition` |

`ClipRatio1s`／`ClipPercent1s` 是保留名稱的相容 alias，實際視窗仍以設定值為準。
`ClippingStarted`／`ClippingEnded` 是可信 `AnyClipping` 的全域邊緣事件；來源數事件為
`SourceConnected`／`SourceDisconnected`。動作為 `ResetPeak` 與
`UseAutomaticSource`。

## SimHub SDK 精確相容矩陣

v0.3.0 的可發布建置目前只接受 `simhub/sdk-compatibility.json` 中 **SimHub 9.11.22**
這一組 profile。`Test-SimHubSdk.ps1` 會逐一比對以下 SimHub 自有 DLL 的檔案長度與
SHA-256：

- `GameReaderCommon.dll`
- `log4net.dll`
- `SimHub.Logging.dll`
- `SimHub.Plugins.dll`

只要其中一個檔案不同，即使顯示版本相近，也會拒絕產生可發布外掛。這表示其他 SimHub
版本目前是**未列入支援矩陣**，不是自動相容。這些 DLL 只在建置時引用，不會放進發布
套件。

建置需求：Windows、.NET Framework 4.8 Developer Pack、Visual Studio 2022 或更新版，
以及符合上述指紋的本機 SimHub 安裝。

```powershell
powershell -ExecutionPolicy Bypass -File simhub\tools\Build-SimHubPackage.ps1
powershell -ExecutionPolicy Bypass -File simhub\tools\Build-LauncherPackage.ps1
```

若 SimHub 不在預設路徑，傳入 `-SimHubInstallPath`。一般 CI 可建置 Core tests 並
執行 `Test-Dashboards.ps1` 的文字／JSON 契約檢查；完整 SimHub adapter 編譯仍需要上述
proprietary SDK。

## 穩定版與實驗版簽章

- **穩定版：**所有會執行或安裝的必要檔案都必須通過 Windows Authenticode 信任鏈與
  撤銷檢查，簽署者必須一致，且要符合建置時釘選的簽署者 SHA-256。Manager 以
  fail-closed 執行；任一簽章不符即禁止安裝與啟動。完整套件另有 GitHub provenance
  attestation。
- **實驗版：**可能完全未簽章，Manager 不把 Authenticode 當強制門檻，但仍核對套件內
  精確檔案清單與 SHA-256，並顯示警告。內部 manifest 只能發現解壓後變更，不能單獨證明
  發布者身分；只應使用已驗證官方 GitHub Release attestation 與外層 checksum 的套件。

不要為執行實驗版而盲目關閉 SmartScreen、防毒或其他防護。

## 支援範圍與安全邊界

- 支援 x86／x64 Windows 遊戲，以及標準匯入
  `dinput8.dll!DirectInput8Create` 的 DirectInput8 路徑。
- 使用 `GetProcAddress`、私有 loader、GameInput、XInput、WinRT、專有 FFB SDK，或由
  第一層 launcher 再建立真正遊戲程序的遊戲可能無法觀測；iRacing 明列為不支援。
- 後載入模組只在有限時間內重查；非常晚才載入 DirectInput 的特殊遊戲可能無法攔截。
- `--offline-only` 是使用者確認與支援政策，不是防火牆，也不會替使用者斷網。
- pipe 使用目前使用者／SYSTEM ACL、拒絕遠端 client、嚴格 frame 與序號檢查及 client
  PID 驗證；同一使用者仍可產生合成遙測，因此它不是信任或反作弊邊界。

詳細的一鍵操作說明見 [LAUNCHER.zh-TW.md](LAUNCHER.zh-TW.md)，安裝選項見
[INSTALL.zh-TW.md](INSTALL.zh-TW.md)。
