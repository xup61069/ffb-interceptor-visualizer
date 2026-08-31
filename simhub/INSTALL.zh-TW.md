# FFB Interceptor SimHub v0.3.0 安裝、升級與移除

> **高扭力安全警告：**方向盤基座可能突然動作。第一次測試請先把 gain 調到最低、讓
> 手部遠離轉動範圍並準備實體急停。本工具不是硬體安全控制器；Dashboard 顯示的是
> DirectInput 命令，不是實際馬達扭力。

本專案只支援離線／單機測試，不提供反作弊規避、受保護遊戲、任意程序注入或線上競技
支援。

下列檔名是完整 self-hosted 發行的預期資產，不表示目前已有公開穩定版。請先確認 Release
頁面確實附有需要的 ZIP；本儲存庫目前不宣稱已配置公信程式碼簽章憑證、所需 runner 或
已發布 Stable。建立或推送 tag 不會自動發布，維護者必須從預設分支送出對應且欄位精確的
`repository_dispatch` 事件。

## 選擇套件

| 套件 | 建議用途 | 是否寫入遊戲資料夾 |
|---|---|---|
| `FFBInterceptor-Launcher-0.3.0.zip` | **建議。**含一鍵 Manager、x86／x64 Launcher／Hook、SimHub 外掛與 Dashboard | 否；不含也不安裝 `dinput8.dll` |
| `FFBInterceptor-SimHub-0.3.0.zip` | 只安裝 SimHub 外掛；producer 需另行提供 | 否 |
| `FFBInterceptor-ReadyToUse-*.zip`／傳統 proxy | 舊式直接啟動或特殊部署 | 是；會在遊戲 EXE 旁管理 `dinput8.dll` |

若你的要求是「不改遊戲 DLL」，請選 Launcher ZIP 與
`FFBInterceptor.Manager.exe`。不要同時安裝傳統 proxy。

## 建議安裝：一鍵 Manager

1. 從可信的 v0.3.0 Release 下載 Launcher ZIP，先驗證 Release attestation 與外層
   checksum，再完整解壓到新的本機空資料夾。不要直接在 ZIP 內執行。
2. 以一般使用者身分開啟 `FFBInterceptor.Manager.exe`，不要使用「以系統管理員身分
   執行」。Manager 是原生 Windows 視窗程式，不需要 .NET 或 SimHub SDK。
3. 選擇真正的離線遊戲 EXE 與 SimHub 安裝資料夾；可設定遊戲參數及「一鍵啟動時自動
   開啟 SimHub」。
4. 關閉 SimHub，按「安裝／更新插件」，接受一次 UAC。提權子程序只安裝
   `FFBInterceptor.SimHub.dll` 與 `FFBInterceptor.Core.dll`，不會用管理員權限啟動遊戲。
5. 開啟 SimHub，在「設定 → 插件」啟用 **FFB Interceptor**。
6. 雙擊包內任一 `.simhubdash`，匯入 800×480 Dashboard 或 480×160 Overlay。
7. 回到 Manager 按「一鍵啟動」。它會驗證精確 manifest、簽章政策、x86／x64 架構、
   外掛版本與 pipe 就緒狀態，然後建立新的遊戲程序。

SimHub 安裝根目錄必須位於實體固定本機磁碟。網路／卸除式磁碟、`SUBST` 磁碟代號、
junction 或其他 reparse 路徑都會 fail closed；請改選一般本機磁碟上的真正安裝根目錄。

Manager 可保存多個遊戲設定檔並複製去識別化診斷；它不保存帳號、密碼或 Token。

### Manager 為何不改 dinput8.dll

- Launcher ZIP 裡沒有 `dinput8.dll`，也不會新增、覆寫或刪除遊戲資料夾內的 DLL。
- Manager 不能輸入既有 PID，也不附加已執行程序；它只建立使用者選定的新遊戲程序。
- 它依遊戲架構使用套件內固定的 `FFBInterceptor.Launcher.exe` 與
  `FFBInterceptor.Hook.dll`，不允許指定任意 DLL。
- Hook 在新程序**記憶體**內替換尚未被其他元件修改的
  `dinput8.dll!DirectInput8Create` IAT 指標；同步入口點的原位元組會在第一條遊戲指令前
  還原，程序結束後記憶體變更自然消失。

這保證的是不修改遊戲磁碟檔案，不代表程序記憶體完全不變。

## 只安裝 SimHub 外掛

若使用 `FFBInterceptor-SimHub-0.3.0.zip`：

1. 關閉 SimHub。
2. **建議改下載 Launcher ZIP**，正常開啟其中的 `FFBInterceptor.Manager.exe`，再按
   「安裝／更新插件」。不要用系統管理員身分直接開啟 Manager。
3. 若一定只用 SimHub-only ZIP，請核對 Release checksum／attestation 後，透過 Windows
   檔案總管把 `simhub\FFBInterceptor.SimHub.dll` 與 `simhub\FFBInterceptor.Core.dll`
   複製到含有 `SimHubWPF.exe` 或 `SimHub.exe` 的精確 SimHub 安裝根目錄；由檔案總管處理
   必要的 UAC。只複製這兩個專案 DLL，不要改動其他 SimHub 檔案。
4. 開啟 SimHub，在「設定 → 插件」啟用 **FFB Interceptor**，再匯入 Dashboard。

上述檔案總管路徑是純手動安裝，不會建立 Manager 使用的受保護安裝狀態，也不會替既有
同名檔案建立可由 Manager 還原的備份。之後的升級與移除必須沿用下方「純手動」步驟，
不能假設 Manager 知道手動複製前的檔案狀態。

包內 `Install-SimHubPlugin.cmd`／`Uninstall-SimHubPlugin.cmd` 現在**不會自行要求 UAC**。
它們會先用腳本內建的 bootstrap 鎖住所有套件檔案，核對精確 manifest、逐檔 SHA-256、
reparse point 與 Authenticode 狀態一致性，通過後才載入共用 helper。一般使用者直接執行時
會停下並指向 Manager；直接以系統管理員開啟腳本也會拒絕寫入。只有一般權限 Manager
在持有整包檔案鎖時，才會用 `runas` 提升同一個已鎖定、已驗證的原生 Manager。提升 helper
會自行重鎖及重驗整包，再以不繼承呼叫端 .NET startup／module／`PATH` 變數的最小環境啟動
System32 內建 Windows PowerShell。腳本仍會重新鎖定、核對雜湊與簽章，透過一次性同步事件
回報驗證完成；父 Manager 與提升 helper 都等到子程序結束後才釋放鎖。`-NoElevation` 只保留
給不需管理員權限的受控測試目錄。這個限制避免在 UAC
等候期間，來源腳本或 DLL 被同一使用者替換後再以高權限執行。

真正寫入時，安裝器會鎖住 SimHub 目的樹，建立 delete-on-close sentinel，並重驗每層
目錄身分；受保護的 `%ProgramData%\FFBInterceptor` 狀態目錄也套用相同邊界。
`-WhatIf` 只做唯讀驗證，不會為了 dry-run 建立 sentinel。

建置流程不會把
`GameReaderCommon.dll`、`log4net.dll`、`SimHub.Logging.dll` 或 `SimHub.Plugins.dll`
重新包進 ZIP。

此外掛只負責接收 `\\.\pipe\ffb-interceptor-simhub-v1`；仍需由 Launcher／Hook 或傳統
proxy 產生遙測。Python viewer 使用獨立的 `\\.\pipe\ffb-interceptor-v1`，可同時執行。

## 傳統 dinput8.dll proxy

傳統 ReadyToUse 套件會選擇對應 x86／x64 proxy、備份既有 `dinput8.dll`，再把本專案的
DLL 放到遊戲 EXE 旁。這條路徑**會修改遊戲資料夾**，也可能與其他 proxy／模組衝突；
只應在離線環境使用。完整備份與多遊戲解除安裝規則見
[PORTABLE.zh-TW.md](PORTABLE.zh-TW.md)。

手動 proxy 安裝步驟為：先完成 SimHub 外掛安裝，再把與遊戲相同架構的本專案
`dinput8.dll` 放到遊戲 EXE 旁。若已有同名 DLL，不要直接覆蓋；改用受管理安裝器或停止。

## 升級 v0.3.x

### Manager／Launcher 路徑

1. 關閉遊戲與 SimHub，把新 ZIP 解壓到**新的空資料夾**。精確 manifest 會拒絕舊資料夾
   殘留的額外檔案，所以不要直接覆蓋解壓。
2. 從新套件開啟 Manager，查看「環境診斷」中的版本、完整性與簽章通道。
3. 按「安裝／更新插件」。若偵測到受管理的不同版本，或受保護狀態指向另一個 SimHub
   根目錄，先對原目錄按「解除安裝插件」安全還原，再重新安裝；不能直接切換狀態路徑。
4. 開啟 SimHub 並確認外掛已啟用；完成一次一鍵啟動後，才刪除舊套件資料夾。

### SimHub-only 路徑

若舊版原本由 Manager 安裝且具有受保護安裝狀態，請關閉 SimHub，使用 Launcher ZIP 的
Manager 先「解除安裝插件」並確認備份還原，再從新包按「安裝／更新插件」。

若舊版原本是透過檔案總管純手動複製，請關閉 SimHub，確認含有 `SimHubWPF.exe` 或
`SimHub.exe` 的精確安裝根目錄，只移除其中的 `FFBInterceptor.SimHub.dll` 與
`FFBInterceptor.Core.dll`，再一次複製新包內同版本的兩個 DLL；不要混放不同版本，也不要
刪除其他 SimHub 檔案。純手動路徑沒有 Manager protected state 或備份，Manager 無法還原
手動覆寫前的同名檔案。獨立 `.cmd` 不會自行提權。

### 傳統 proxy 路徑

先用舊版受管理解除安裝器還原原本 `dinput8.dll`，再用新包安裝。不要直接覆蓋既有 proxy，
否則可能失去原檔與所有權紀錄。

## 解除安裝與完整移除

### Manager／Launcher

1. 關閉遊戲與 SimHub，在 Manager 按「解除安裝插件」。
2. 解除安裝器只移除受管理狀態記錄且 SHA-256 仍相符的兩個 SimHub 外掛 DLL，必要時
   還原安裝前備份；遭其他程式修改的檔案會保留並報錯。若 SimHub 主程式已被升級程序
   移除，只要受保護狀態、固定磁碟、目錄身分與雜湊仍全部吻合，也能安全解除安裝。
3. 在 SimHub 內手動移除已匯入的 Dashboard。
4. 刪除解壓資料夾。遊戲端沒有 `dinput8.dll` 可清理。Manager profile 會留在目前使用者的
   `HKCU\Software\FFBInterceptor\Launcher`；若確定要連使用者偏好一起完整清除，請先
   關閉 Manager，再自行移除該登錄機碼。

### SimHub-only

若原本由 Manager 安裝且具有受保護安裝狀態，請關閉 SimHub，再用 Launcher ZIP 的
Manager 按「解除安裝插件」；安裝狀態或備份雜湊不符時，解除安裝器會拒絕猜測與刪除。

若原本是透過檔案總管純手動複製，Manager 沒有可用的安裝狀態或備份。請關閉 SimHub，
確認含有 `SimHubWPF.exe` 或 `SimHub.exe` 的精確安裝根目錄，只手動移除
`FFBInterceptor.SimHub.dll` 與 `FFBInterceptor.Core.dll`，不要刪除其他 SimHub 檔案。
Manager 無法保證還原純手動安裝前可能存在的同名檔案。已匯入的 Dashboard 仍須在 SimHub
內手動移除。獨立 `Uninstall-SimHubPlugin.cmd` 不會自行叫出 UAC；一般使用者執行時只會
驗證並導向 Manager。

### 傳統 proxy

使用 `Uninstall-FFBInterceptor.cmd` 並選擇相同遊戲 EXE，讓安裝器驗證目前 DLL、還原
備份並更新多遊戲參照狀態。不要直接刪除備份檔。

## SimHub 9.11.22 精確 SDK 相容性

v0.3.0 的可發布建置只接受 `sdk-compatibility.json` 中 **SimHub 9.11.22** 的精確 profile。
`Test-SimHubSdk.ps1` 會比對下列 DLL 的檔案長度與 SHA-256：

- `GameReaderCommon.dll`
- `log4net.dll`
- `SimHub.Logging.dll`
- `SimHub.Plugins.dll`

任一檔案不同就拒絕建立可發布外掛；相近或較新的 SimHub 版本目前仍是未列入支援矩陣，
不能由版本字串推定相容。這些 proprietary SDK DLL 只在建置時引用，不會重新散布。

## 穩定版與實驗版的驗證差異

- **穩定版：**Manager 對所有必要執行檔、Hook、外掛與腳本強制 Windows Authenticode
  信任鏈／撤銷檢查、相同簽署者與釘選 signer SHA-256；不符即禁止安裝與啟動。Release
  另有 GitHub provenance attestation。
- **實驗版：**公開流程固定未簽章且不讀 Stable secrets；Manager 不強制 Authenticode，但仍檢查精確檔案允許清單與
  SHA-256，並顯示風險提示。請另外驗證官方 Release attestation 與 checksum；套件內
  manifest 無法單獨證明發布者。

不要修改 manifest，也不要為實驗版關閉 SmartScreen 或防毒後硬闖。

## v0.3.0 削峰判定摘要

外掛對每個裝置分別計算正在輸出的可支援效果：Constant 使用當下 magnitude；Ramp 依
播放時間在 start／end 間內插；Periodic（Square、Sine、Triangle、SawtoothUp、
SawtoothDown）依 elapsed time、phase、period、offset 與 magnitude 計算當下 waveform；
Envelope attack 與 fade 會改變這些瞬時振幅。period 為零及 Condition／Custom／未知效果
不會硬套數值。

同一裝置內的**瞬時命令絕對值相加**，再取所有裝置中最大的值；**不同裝置不相加**。
因為不推測方向抵消，這是可能高估的保守上界，不是實際合力或馬達扭力。Dashboard gauge
使用截在 100% 的 combined 值，數字／峰值可顯示未截斷值。v0.2 的單一最大效果
屬性仍保留相容語意。

預設在 98% 進入、95% 離開；連續碰頂 100 ms 或最近 1 秒碰頂比例達 5% 時觸發，低於
95% 持續 500 ms 後解除。

### TriggerButton 與停止削峰結論

protocol v1 可看到效果設定了 `TriggerButton`，卻沒有輸入按鍵當前狀態。只要來源仍有
這類效果狀態，就會標記 `TriggerStateUnavailable`、令 `DataReliable=false`，並令
`AtLimit=false`、`IsClipping=false`、`ClipRatio=0`；外掛不會猜「正在播放」或「沒有
削峰」。移除該效果後，這項動態限制可解除。

producer 掉幀、同 session 重連或狀態容量超限也會停止削峰結論。資料缺口與重連通常要
重新啟動遊戲建立新 session；若容量 drop 重啟遊戲後仍不歸零，請再重啟 SimHub 讓
偵測引擎重新建立。

### 容量上限

- 整個偵測引擎最多保留 **64 個來源**；
- 每個來源最多 **64 個裝置**；
- 每個來源最多 **1024 個效果**。

超限項目會被拒絕，並增加 `SourceStateDrops`、`DeviceStateDrops`、`EffectStateDrops` 與
`StateCapacityDrops`。容量 drop 會令 `DataReliable=false`，不能繼續發布削峰結論。

## 支援範圍

- 支援 x86／x64 Windows 遊戲，以及標準匯入
  `dinput8.dll!DirectInput8Create` 的 DirectInput8 路徑。
- `--offline-only` 是支援政策與使用者確認，不是防火牆，也不會替你斷網。
- 不支援反作弊規避、隱匿、提權、任意程序注入、受保護遊戲或線上競技。
- 使用 `GetProcAddress`、私有 loader、GameInput、XInput、WinRT、專有 FFB SDK，或由
  第一層 launcher 再建立真正遊戲程序的遊戲可能無法觀測；iRacing 明列為不支援。
- 後載入模組只在有限時間內重查；非常晚才載入 DirectInput 的特殊遊戲可能無法攔截。
- Condition、Custom 與未知效果只列入限制／計數，不會在資訊不足時虛構削峰結論。

更完整的數值與屬性契約見 [README.md](README.md)，Manager 操作與疑難排解見
[LAUNCHER.zh-TW.md](LAUNCHER.zh-TW.md)。
