# FFB Interceptor v0.3.0 不改遊戲 DLL 一鍵版

> **僅供離線／單機測試。**不提供反作弊規避、受保護遊戲或線上競技支援。
>
> **高扭力安全警告：**方向盤可能突然動作。第一次啟動前先把 gain 調到最低、讓手部
> 遠離轉動範圍並準備實體急停。本工具只觀察與轉送命令，不是硬體安全控制器。

`FFBInterceptor-Launcher-0.3.0.zip` 的建議入口是原生視窗程式
`FFBInterceptor.Manager.exe`。它會協助安裝／更新 SimHub 外掛、記住多個離線遊戲設定、
診斷環境並一鍵啟動。ZIP **不含 `dinput8.dll`**，Manager 路徑也不會寫入遊戲資料夾。

## 先確認發行通道

以下兩個頻道是封裝政策，不代表目前已有公開 Stable 資產。本儲存庫目前不宣稱已配置
公信程式碼簽章憑證、所需 self-hosted runner 或已發布 Stable。建立或推送 tag 不會自動
發布；維護者必須從預設分支送出對應且欄位精確的 `repository_dispatch` 事件。

- **穩定版：**必要 EXE、DLL 與 PowerShell 腳本必須通過 Windows Authenticode 信任鏈
  與撤銷檢查，簽署者必須一致並符合建置時釘選的簽署者 SHA-256。Manager 採
  fail-closed；任一檔案不符就禁止安裝與啟動。套件另有 GitHub provenance attestation。
- **實驗版：**兩條公開流程都固定未簽章且不讀 Stable secrets；Manager 仍會驗證精確檔案清單與每個檔案 SHA-256，但不強制
  Windows 簽章。內部 manifest 只能發現解壓後變更，不能單獨證明來源；請只使用已驗證
  官方 GitHub Release attestation 與外層 checksum 的套件。

不要為了執行實驗版而盲目關閉 SmartScreen、防毒或其他保護。Manager 的「環境診斷」
會明確顯示目前是穩定版簽章政策或實驗版警告。

## 第一次使用

1. 把整個 ZIP 解壓到新的本機空資料夾，不要直接在 ZIP 裡執行，也不要自行增刪套件
   檔案；精確 manifest 會拒絕缺漏、額外或被改過的檔案。
2. 正常雙擊 `FFBInterceptor.Manager.exe`，**不要**使用「以系統管理員身分執行」。
3. 選擇真正的離線遊戲 EXE 與 SimHub 安裝資料夾；可填遊戲參數，也可勾選「一鍵啟動時
   自動開啟 SimHub」。
4. 關閉 SimHub，按「安裝／更新插件」。Windows UAC 只授權外掛安裝子程序，不會用
   管理員權限啟動遊戲。
5. 開啟 SimHub，到「設定 → 插件」啟用 **FFB Interceptor**，並匯入包內 800×480
   Dashboard 或 480×160 Overlay。
6. 回到 Manager 按「一鍵啟動」。Manager 會再次鎖定並驗證套件、檢查 x86／x64
   架構、SimHub 外掛版本與 pipe，然後建立新的遊戲程序。

SimHub 必須位於實體固定本機磁碟；網路／卸除式磁碟、`SUBST`、junction 或其他
reparse 路徑不會通過安裝邊界。

第一次啟用外掛後，日常使用只需開啟 Manager、選擇遊戲設定檔並按「一鍵啟動」。
Manager 最多保存 64 個遊戲設定檔，內容只有路徑、參數與啟動偏好，不保存帳號、密碼或
Token。

## 安裝、升級與移除

### 安裝／修復

「安裝／更新插件」只管理 SimHub 目錄內的 `FFBInterceptor.SimHub.dll` 與
`FFBInterceptor.Core.dll`。安裝前必須關閉 SimHub；既有同名檔會先做可驗證備份，安裝
狀態保存在受管理員 ACL 保護的位置。若診斷顯示套件或簽章錯誤，請重新下載可信 Release，
不要修改 `SHA256SUMS.txt`。實際寫入期間會依固定順序為 SimHub 目的樹與
`%ProgramData%` 狀態目錄取得跨程序、零共享的 delete-on-close mutation lease，再建立
本次作業的隨機 sentinel，並重驗實體磁碟、每層目錄身分與 reparse 狀態。

### 升級到新版本

1. 關閉遊戲與 SimHub，把新 ZIP 解壓到**新的空資料夾**；不要覆蓋舊資料夾，否則可能
   因殘留額外檔案而被精確 manifest 拒絕。
2. 從新資料夾啟動 Manager，確認診斷中的版本與發行通道，再按「安裝／更新插件」。
3. 若目前受管理的外掛版本不同或狀態指向另一個 SimHub 根目錄，依 Manager 提示先對
   原目錄按「解除安裝插件」還原舊版，再重新安裝。不要手動混用不同版本的 Core 與
   SimHub DLL，也不要直接把受保護狀態切到新目錄。
4. 開啟 SimHub，確認外掛已啟用並完成一次一鍵啟動；驗證正常後才刪除舊套件資料夾。

### 解除安裝

1. 關閉遊戲與 SimHub，在 Manager 按「解除安裝插件」並確認。
2. 解除安裝器只移除安裝狀態中記錄、且 SHA-256 仍相符的受管理檔案；必要時還原安裝前
   備份。檔案若被其他程式修改，會拒絕刪除，避免誤傷。若 SimHub 主程式已因升級而
   移除，只要受保護狀態、固定磁碟、目錄身分與雜湊仍全部吻合，解除安裝仍可進行。
3. 已匯入的 Dashboard 不會自動刪除，請在 SimHub 內手動移除。
4. 最後可刪除整個解壓資料夾；遊戲資料夾不需清理。Manager 的遊戲設定檔位於目前
   使用者的 `HKCU\Software\FFBInterceptor\Launcher`，外掛解除安裝不會自動刪除它。

請優先使用 Manager 安裝或解除安裝。包內 `Install-SimHubPlugin.cmd` 與
`Uninstall-SimHubPlugin.cmd` 不再自行要求 UAC：兩支腳本會先用自包含 bootstrap 鎖住
套件並驗證精確 manifest、SHA-256、reparse point 與簽章狀態，通過後才載入 helper；
一般使用者若未明確指定無提權模式，就會停止並導向 Manager，直接提升腳本也會拒絕。
Manager 會保持套件 handle 鎖，以 `runas` 提升同一個已鎖定、已驗證的原生 Manager；提升
helper 會先重鎖、重驗整包，再用不繼承呼叫端 .NET startup／module／`PATH` 變數的最小環境
啟動 System32 Windows PowerShell。腳本仍會再次鎖定並驗證整包，透過一次性同步事件確認後
才寫入；父 Manager 與提升 helper 都等到子程序結束才解鎖。`-NoElevation` 只適用於不需
管理員權限的受控測試目錄，不是繞過 UAC 的開關。

## 「不改 dinput8.dll」實際代表什麼

- ZIP 內沒有 `dinput8.dll`，遊戲 EXE 與遊戲資料夾內的 DLL 都不會被新增或替換。
- Manager 只能啟動使用者選定的新程序；不能輸入既有 PID、附加已執行程序或指定任意
  Hook DLL。
- Manager 依遊戲架構選擇包內固定的 x86／x64 `FFBInterceptor.Launcher.exe` 與
  `FFBInterceptor.Hook.dll`。
- Windows 載入器完成後，Launcher 會在遊戲入口點的**程序記憶體**暫放同步斷點，並在
  第一條遊戲指令執行前還原原位元組。
- Hook 只替換尚未被其他元件修改的 `dinput8.dll!DirectInput8Create` IAT 指標；遊戲
  結束後，程序內變更隨程序消失。

所以這是「不修改遊戲磁碟檔案」，不是「程序記憶體完全不變」。若你改用傳統 proxy
套件，該路徑會把 `dinput8.dll` 放到遊戲旁，兩者不可混為一談。

## v0.3.0 Dashboard 數值怎麼看

削峰判定使用同一 DirectInput 裝置內所有可建模效果的**瞬時命令絕對值和**，再取命令
最大的裝置。不同裝置不相加；同裝置也不推測方向向量抵消，因此這是可能高估、但避免
低估疊加的保守上界，不是實際合力或馬達扭力。

- Constant 使用當下 magnitude。
- Ramp 依播放時間在 start 與 end 間內插。
- Square、Sine、Triangle、SawtoothUp、SawtoothDown 依 elapsed time、phase、period、
  offset 與 magnitude 計算當下波形；period 為零時不納入。
- Envelope attack／fade 會改變 Constant、Ramp 與 Periodic 的瞬時振幅。
- 效果與裝置 gain 另算增益後估計；增益前的命令削峰不會因 gain 降低而被隱藏。

Dashboard gauge 顯示截在 100% 的 combined 值；數字與峰值可以顯示未截斷的保守上界。
預設在 98% 進入、95% 離開；連續碰頂 100 ms 或最近 1 秒碰頂至少 5% 會觸發，低於
95% 持續 500 ms 後解除。

Condition、Custom 與未知效果因缺少位置、速度、自訂樣本或裝置內部資料，只列為模型
限制並排除，不會虛構力值。

## TriggerButton、可靠性與容量

protocol v1 能看到效果設定了 `TriggerButton`，卻看不到實體按鍵現在是否按下。因此，
來源內存在這類效果狀態時會顯示 `TriggerStateUnavailable`、令
`DataReliable=false`，並清除／停止 `AtLimit`、`IsClipping` 與削峰事件結論。這是刻意的
保守停止，不代表「沒有削峰」。效果被移除後，這項動態限制可解除。

producer 掉幀、同 session 重連或狀態容量超限也會令 `DataReliable=false`。資料缺口與
重連通常要重啟遊戲建立新的 producer session；若容量 drop 重啟遊戲後仍不歸零，請再
重啟 SimHub 以重新建立偵測引擎。

狀態上限為：

- 整個引擎最多 **64 個來源**；
- 每個來源最多 **64 個裝置**；
- 每個來源最多 **1024 個效果**。

超出的來源、裝置或效果會被拒絕並累計 `SourceStateDrops`、`DeviceStateDrops`、
`EffectStateDrops`／`StateCapacityDrops`；容量 drop 不為零時不會發布可信削峰結論。

## SimHub 版本與 SDK 限制

v0.3.0 的支援矩陣目前只有 **SimHub 9.11.22 的一組精確 SDK 指紋**。發布流程會比對
`GameReaderCommon.dll`、`log4net.dll`、`SimHub.Logging.dll` 與 `SimHub.Plugins.dll` 的
檔案長度和 SHA-256；任一不同就拒絕建立可發布外掛。相近或較新的版本不代表已相容，
目前都屬未列入支援矩陣。這些 SimHub 自有 DLL 不會隨包重新散布。

## 支援範圍與限制

- `--offline-only` 是使用者確認與本專案支援政策，**不是防火牆，也不會替你斷網**。
- 不支援反作弊規避、隱匿、提權、任意程序注入、受保護遊戲或線上競技。
- 支援 x86／x64 Windows 程式，以及標準匯入
  `dinput8.dll!DirectInput8Create` 的 DirectInput8 路徑。
- 使用 `GetProcAddress`、私有 loader、GameInput、XInput、WinRT、專有 FFB SDK 的遊戲
  可能沒有資料；iRacing 明列為不支援。
- 遊戲若先啟動另一個 launcher 再建立真正遊戲程序，目前不會自動追蹤下一層子程序。
- 後載入模組只在有限時間內重查；非常晚才載入 DirectInput 的特殊遊戲可能無法攔截。

## 常見問題

### 一鍵啟動說 SimHub 插件管線尚未就緒

先開啟 SimHub，到「設定 → 插件」啟用 **FFB Interceptor**。若剛升級，確認 Manager
診斷顯示已安裝 DLL 與目前套件雜湊一致。

### 遊戲啟動但 Dashboard 沒資料

確認選到真正遊戲 EXE，且遊戲走標準 DirectInput8 匯入路徑。另一層 launcher、動態解析
函式或其他輸入 API 都可能不在支援範圍。

### 顯示模型受限或資料不可靠

查看 `ReliabilityText`、Trigger 計數與 capacity drops。TriggerButton 狀態不可觀測時，
外掛不會猜測；資料缺口時請重啟遊戲建立新 session，容量 drop 若仍存在則再重啟
SimHub。

### Windows 阻擋執行

先確認發行通道、Release attestation 與 checksum。公開 Experimental 固定未簽章；來源不明或驗證
不符就不要執行，也不要關閉防護硬闖。

### 方向盤動作不正常

立即按實體急停、關閉遊戲並停止使用。Dashboard 是命令遙測，不是硬體保護。
