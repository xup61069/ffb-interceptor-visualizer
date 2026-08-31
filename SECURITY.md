# v0.3 安全政策

FFB Interceptor 是 DirectInput8 命令遙測工具，不是硬體安全控制、反作弊或扭力計。
發現安全問題時，請使用 GitHub 的 Private Vulnerability Reporting，或在
`xup61069/ffb-interceptor-visualizer` 建立 draft security advisory；不要先開公開 issue。

## 支援版本

| 版本 | 安全修正 |
| --- | --- |
| 最新受支援的 `v0.3.x` GitHub Release（依頁面標示 Stable／Experimental） | 支援 |
| `v0.2.x` 與更舊版本 | 不支援；請升級並重新驗證套件 |
| 未標記 commit／自行修改套件 | 不提供 Release 完整性保證 |

維護者會在 14 天內確認收到有效報告，並在公開細節前協調修正、緩解方式與揭露時間。
若問題正在被利用或可能造成實體傷害，請在標題明確標示嚴重性。

## 回報時請提供

- 完整版本／tag、Release 頻道（Stable 或 Experimental）與資產檔名。
- 資產 SHA-256、Windows 版本、遊戲程序架構，以及必要時的 SimHub 版本。
- 最小重現步驟、預期與實際結果、影響範圍；能用專案 fixture 重現時優先使用 fixture。
- 已去識別化的 Manager 診斷。內建「複製診斷資訊」會把使用者家目錄改成
  `%USERPROFILE%`，但送出前仍請人工檢查。

請勿在公開或私人報告中附上遊戲帳號、密碼、Token、序號、完整主機／使用者路徑、
未遮罩的私人 telemetry、含個資的 crash dump、簽章 PFX 或任何私鑰。若必要證據含
敏感資料，先描述資料類型，等維護者提供安全傳送方式。

## 安全邊界

### Launcher／Hook 模式

首選的 `FFBInterceptor-Launcher-0.3.0.zip` 不含 `dinput8.dll`，也不會在遊戲目錄
放置或修改它。Manager／Launcher 只會為使用者明確選取的本機 x86／x64 EXE 建立新
子程序，並載入套件內固定、同架構的 Hook；不接受既有 PID、任意 DLL、Windows 系統
目錄目標或提升權限執行。Hook 只在新子程序內接上 `DirectInput8Create`，不修改磁碟上
的遊戲 EXE。

這不是一般用途 sandbox。使用者選取的遊戲仍會以使用者本身權限執行；請只選信任、
離線的遊戲 EXE。專案不提供反作弊規避，也不支援線上競技環境。iRacing 明列不支援。

Proxy、Hook、Launcher 與 Manager 使用靜態 MSVC CRT，並以
`/DEPENDENTLOADFLAG:0x800` 將靜態匯入相依限制到 System32 搜尋範圍，降低進入
`main()`／`WinMain()` 前從可寫套件目錄載入同名 DLL 的風險。這項設定只涵蓋 PE 的
靜態相依，不代表任意 `LoadLibrary`／`GetProcAddress` 動態載入也自動受保護。

### Manager 設定與診斷

設定檔放在目前使用者的 `HKCU\Software\FFBInterceptor\Launcher`，只保存顯示名稱、
遊戲／SimHub 路徑、啟動參數與偏好，最多 64 個，不保存憑證或登入秘密。路徑本身仍
可能透露個資，分享登錄匯出或診斷前應先檢查。

Manager 會驗證精確檔案清單、SHA-256、路徑邊界、reparse point、x86／x64 架構、
已安裝插件雜湊與 pipe readiness。驗證後以唯讀 handle 鎖定套件目錄、manifest 與
必要檔案直到子程序完成；如果安裝／啟動逾時且程序可能仍在執行，後續變更會被停用，
避免兩個不確定操作重疊。

### 獨立 PowerShell 安裝器的提權邊界

`Install-SimHubPlugin.ps1` 與 `Uninstall-SimHubPlugin.ps1` 不再自行呼叫 UAC。一般使用者
未指定 `-NoElevation` 時，腳本只會完成自包含套件驗證後停止，並提示改用 Manager；
直接提升後執行也會拒絕寫入；`-NoElevation` 只用於不需管理員權限的受控測試目錄。這兩支入口在 dot-source
`FFBInterceptor.Common.ps1` 前，會自行拒絕 reparse directory／file、解析受限大小且精確
涵蓋全包的 manifest，並用不允許寫入或刪除的 read handle 鎖住每個檔案後從同一 handle
重算 SHA-256。若入口本身有有效 Authenticode，所有 `.exe`、`.dll`、`.ps1`、`.psm1`
還必須有效且為相同 signer；未簽章實驗包則不可混入其他簽章狀態。

Manager 只會在自己先鎖定、重驗整包後，透過 `ShellExecuteExW` 的 `runas` 提升同一個
已鎖定、已驗證且使用靜態 CRT 的原生 Manager；不使用 `cmd`、`PATH`、App Paths，也不
搜尋其他 helper。特殊提升模式會在建立 GUI／單一 instance mutex 前嚴格解析固定操作，確認
自己位於套件根目錄，開啟一次性同步事件，再自行重鎖並完成 manifest、SHA-256、reparse
point 與 Authenticode 重驗。之後才以 `CreateProcessW` 啟動由安全 handle 解析的 System32
內建 Windows PowerShell，並傳入由 Windows API／已知資料夾重建、排序且雙 NUL 結尾的最小
Unicode 環境；不繼承呼叫端的 `PATH`、`PSModulePath`、`COR_*`、`COMPLUS_*`、`DOTNET_*`
或 AppDomain manager startup 變數。固定腳本在驗證套件前只從執行中引擎的唯讀
`$PSHOME` 載入固定 inbox module，不信任繼承的 `SystemRoot`／`PSModulePath`；之後仍會
自行從路徑重新開啟並鎖定同一批檔案，
完成相同重驗，載入已驗 helper 後才 signal。父 Manager 全程保留原鎖並等待 signal 與提升
helper 的 exit code；提升 helper 也會保留自己的鎖到 PowerShell 結束。取消、缺少 signal 或
逾時都 fail closed。這消除「低權限先驗證，等待 UAC 時替換 main／helper，再由高權限重讀」的
窗口。未簽章實驗包的自我檢查仍不建立發布者信任，正式操作必須另行核對官方 Release
checksum／attestation。

### Named Pipe 與同使用者程序

Viewer 與 SimHub 管道只允許本機、目前 Windows 使用者，啟用
`PIPE_REJECT_REMOTE_CLIENTS`，並將 Hello PID 與核心回報的 client PID 綁定。訊框有
固定上限與嚴格解碼；來源、裝置、效果、client 與佇列都有容量限制。

這些控制不能把「同一使用者下的另一個惡意程序」排除在完整信任邊界外。同使用者程序
仍可能嘗試連線、消耗容量或偽造內容；容量超限與資料缺口會讓削峰判定 fail-closed，
但不可把 telemetry 當授權或安全決策來源。

### 傳統 Proxy 模式

傳統 `dinput8.dll` Proxy 會把原始 DirectInput 呼叫 fail-open 轉送：telemetry 序列化、
佇列或管道失敗不應阻斷遊戲呼叫。這降低觀察工具造成遊戲故障的風險，但不保證遊戲、
驅動或硬體安全。

Proxy 模式不是一般使用者首選。絕對不要直接覆寫遊戲既有的 `dinput8.dll`；先做可驗證
備份並確認解除安裝能還原。對遊戲目錄內 DLL 載入有完整性／反作弊要求的軟體，不應
使用此模式。

## 套件完整性與簽章

### Stable：Authenticode fail-closed

Stable Manager 以 `FFB_STABLE_PACKAGE=ON` 與建置時釘選的 signer certificate SHA-256
編譯。每次安裝或啟動前，執行中的 Manager 加上 manifest 內所有 `.exe`、`.dll`、
`.ps1`、`.psm1` 都必須通過 Windows Authenticode 信任鏈與整條鏈撤銷檢查，leaf signer
必須相同且符合釘選值。目前 Launcher allowlist 的簽章集合共 11 個 payload：

- 執行中的 `FFBInterceptor.Manager.exe`；
- `FFBInterceptor.Common.ps1`、`Install-SimHubPlugin.ps1`、
  `Uninstall-SimHubPlugin.ps1`、`Start-FFBInterceptor.ps1`；
- x86／x64 的 `FFBInterceptor.Launcher.exe` 與 `FFBInterceptor.Hook.dll`；
- `FFBInterceptor.Core.dll` 與 `FFBInterceptor.SimHub.dll`。

缺檔、未簽章、不受信任、撤銷狀態失敗、混用 signer 或釘選不符都會拒絕繼續。撤銷
驗證可能需要網路；無法取得有效結果時仍應視為失敗。簽章必須先完成，才可產生套件
內 `SHA256SUMS.txt`。

Stable Manager 還內嵌唯一、NUL 結尾的 build-policy marker，格式為
`FFB_MANAGER_BUILD_POLICY_V1|MODE=STABLE|SIGNER_SHA256=<64 uppercase hex>|END`。Launcher
封裝器不載入候選 EXE，而是以受限大小的 raw PE parser 檢查 marker 完整落在 `.rdata`
的 raw size 與 mapped `VirtualSize` 範圍，且區段必須是 initialized-data／READ、不得
WRITE／EXEC；憑證表、raw padding 或 overlay 內的假標記都會被拒絕。簽章前後都會重新
解析最終 PE bytes，之後再核對有效 Authenticode leaf certificate SHA-256 與 marker
相同；未釘選、重複、格式錯誤或不合即拒絕封裝。Marker 只證明編譯／封裝政策，不取代
Authenticode 信任驗證。

流程具備 Stable 能力不等於已有 Stable 信任根。本儲存庫目前不宣稱已配置公信
Windows 程式碼簽章憑證、GitHub secrets、`[self-hosted, Windows, X64, simhub-sdk]`
runner 或已發布 Stable 資產。使用者應在執行 Manager 前先由 Windows 檢查簽章；
已被替換且先行執行的惡意 EXE 不能只靠「自我檢查」建立信任。

### Experimental：SHA-256 加外部 attestation

Experimental 可能未簽章，不能把 Windows 的未知發行者警告當成 Stable 證據。Manager
仍會拒絕套件內 `SHA256SUMS.txt` 未精確涵蓋所有檔案、必要項目缺少、額外檔案、路徑
跳脫、單檔超過 512 MiB 或總驗證量超過 1 GiB，以及任何 SHA-256 不符。

執行前應同時：

1. 從官方 Release 下載，不使用第三方重新封裝。
2. 核對 Release 的 `SHA256SUMS`。
3. 執行 `gh attestation verify <資產> --repo xup61069/ffb-interceptor-visualizer`。

GitHub provenance attestation 證明資產與 workflow 身分的關係，不是 Authenticode，
也不保護檔案在解壓後被本機程序修改。外層 checksum、attestation 與內層逐檔 manifest
是互補控制。

## SimHub SDK 與供應鏈

可發布 SimHub 外掛只接受 [相容矩陣](simhub/sdk-compatibility.json) 中 SimHub 9.11.22
四個 SDK DLL 的 exact length＋SHA-256 指紋；不相符便停止建置。SimHub 自有 DLL 是
外部 proprietary build-time API，不會 vendoring 或重新散布。這個指紋只說明建置
輸入相符，不等於 SimHub 官方背書或硬體／遊戲測試。

Release 必須等待 tag 所指 exact commit 的 CI／Security checks 成功，並產生 component
與 Python environment 的 CycloneDX／SPDX SBOM、`SHA256SUMS` 與 provenance。發布
腳本只上傳缺少的資產；既有同名資產若大小、digest 或下載內容不同就失敗，不會刪除或
覆寫。詳見 [發行流程](docs/release-process.md)。

## 削峰可靠性不是安全訊號

v0.3.0 的削峰只是同裝置多效果瞬時絕對值和之保守上界；跨裝置、跨來源不相加。它可能
因向量抵消而高估，也不包含馬達控制器、電流、機構或實際扭力。

TriggerButton 的即時按鍵狀態不在 Protocol v1；來源含按鍵觸發效果時，判定會標成
不可靠並停用 CLIP。封包遺失、session 重連或 64 sources／每來源 64 devices／1,024
effects 容量超限也會停用結論。每來源狀態需由新的 producer session 重建；全域 source
容量曾超限時需重啟 SimHub／接收端建立新的 Core instance。這些 fail-closed 行為只能
防止顯示過時判定，不能防止方向盤動作。

高扭力硬體請一律使用實體急停、廠商限制與最低初始增益。本專案尚無可宣稱的實體
高扭力方向盤、所有商業遊戲或長時間硬體測試證據。
