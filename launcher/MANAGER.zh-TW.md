# 即開即用管理器

`FFBInterceptor.Manager.exe` 是原生 Windows 視窗程式，不需要安裝 .NET，也不依賴 SimHub SDK。它只會建立使用者選定的新遊戲程序，再呼叫套件內固定架構的 `FFBInterceptor.Launcher.exe` 與 `FFBInterceptor.Hook.dll`；不會附加到已執行程序，也不會把 `dinput8.dll` 寫進遊戲資料夾。

以下是 Manager 的封裝能力與頻道政策，不表示目前已有公開 Stable 資產。本儲存庫目前
不宣稱已配置公信程式碼簽章憑證或已發布 Stable；建立或推送
tag 也不會自動發布，維護者必須從預設分支送出對應的 `repository_dispatch` 事件。

## 第一次使用

1. 解壓縮完整的 Launcher ZIP，不要只拿出單一 EXE。
2. 正常雙擊 `FFBInterceptor.Manager.exe`，不要用「以系統管理員身分執行」。
3. 選擇離線／單機遊戲的 EXE 與 SimHub 安裝資料夾。
4. 按「安裝／更新插件」，接受一次 Windows UAC。
5. 開啟 SimHub，在「設定 → 插件」啟用 FFB Interceptor。
6. 回到管理器按「一鍵啟動」。

SimHub 必須位於實體固定本機磁碟；網路／卸除式磁碟、`SUBST`、junction 或其他
reparse 路徑會被拒絕。

完成第一次設定後，管理器會記住多個遊戲的路徑、參數、SimHub 路徑與自動啟動偏好。它不會儲存帳號、密碼、Token 或其他敏感資料。

## 啟動前會檢查什麼

- `SHA256SUMS.txt` 格式、必要項目、精確檔案清單與套件內每個檔案雜湊；未列出的額外檔案也會拒絕。
- manifest 路徑是否重複、跳脫套件根目錄或經重新導向連結指向外部。
- 遊戲、Launcher 與固定 Hook DLL 是否都是相同的 x86 或 x64 架構。
- SimHub 執行檔是否存在，已安裝的 Core／插件 DLL 是否與套件雜湊一致。
- SimHub 插件 named pipe 是否已就緒。
- 管理器是否誤用系統管理員權限執行。

必要檔案缺漏、額外出現或雜湊不符時，安裝與遊戲啟動都會被拒絕。真正執行前，管理器會鎖住 manifest、套件資料夾與所有列出的檔案，再於鎖定狀態下重做完整性與簽章驗證，避免驗證後遭替換。安裝或解除安裝需要寫入 SimHub 目錄時，Manager 只會透過 `runas` 啟動同一個已鎖定、已驗證的原生 Manager；不經 `cmd`、`PATH`、App Paths，也不搜尋其他 helper。所有參數會個別引用，不會拼成 PowerShell 指令字串。

提升後的實際寫入另會拒絕可替換的磁碟代號，依固定順序為 SimHub 目的樹與
`%ProgramData%` 狀態目錄取得固定名稱、零共享、delete-on-close mutation lease，再建立
本次作業的隨機 sentinel；每層目錄身分會在鎖定後重驗並維持到作業完成。另一個程序或
工作階段無法同時修改；程序崩潰時 handle 會由系統回收。dry-run 不建立任何鎖檔。

UAC 兩側無法安全繼承一般檔案 handle，因此父 Manager 會在整個作業期間繼續持有原本的套件鎖，並建立一次性的隨機同步事件。提升後的原生 Manager 會先確認自己位於套件根目錄，再自行重鎖、重驗 manifest、SHA-256、reparse point 與 Authenticode，然後以 `CreateProcessW` 啟動由安全 handle 解析出的 System32 內建 Windows PowerShell。子程序只收到 Windows API／已知資料夾重建的最小環境，不會繼承呼叫端的 `PATH`、`PSModulePath`、.NET profiler 或 startup hook 變數。固定腳本仍會再鎖定及驗證自身套件邊界，載入已驗證的共用 helper 後才回報同步事件；父 Manager 等待確認與 helper 結束碼，提升 helper 也等待 PowerShell 結束後才釋放自己的鎖。取消 UAC、缺少確認、驗證失敗或逾時都會 fail closed；若程序狀態不明，套件鎖會保留到 Manager 關閉。請重新下載官方 Release，不要自行改寫 manifest。

## 診斷、升級與解除安裝

- 「複製診斷資訊」會把使用者家目錄改寫成 `%USERPROFILE%` 後才放進剪貼簿。
- 「安裝／更新插件」沿用可回復安裝流程；若受保護狀態指向另一個 SimHub 根目錄，必須先
  對原目錄解除安裝，不能直接把狀態切到新目錄。
- 「解除安裝插件」只移除安裝狀態所記錄、且雜湊仍相符的檔案，必要時還原備份；即使
  SimHub 主程式已因升級而移除，仍可在目錄身分與雜湊全部吻合時解除。Dashboard 會保留。

## 封裝契約

官方封裝應把管理器放在 Launcher ZIP 根目錄。程式雖能從 `launcher/x64` 或 `launcher/x86` 找回套件根目錄，但任何額外的管理器副本也必須列入 manifest，否則會因精確檔案清單不符而拒絕操作。封裝必須在產生 `SHA256SUMS.txt` 前放入管理器，並讓 manifest 至少列出：

- `FFBInterceptor.Manager.exe`
- `Install-SimHubPlugin.ps1`
- `Uninstall-SimHubPlugin.ps1`
- `FFBInterceptor.Common.ps1`
- `Start-FFBInterceptor.ps1`
- 兩種架構的 Launcher 與 Hook DLL
- `simhub/FFBInterceptor.Core.dll`
- `simhub/FFBInterceptor.SimHub.dll`

封裝必須先完成所有 Authenticode 簽章，再產生 `SHA256SUMS.txt`。穩定版建置會 fail-closed：manifest 內所有 EXE、DLL 與 PowerShell 程式碼都必須通過 Windows 信任鏈與撤銷檢查，簽署者必須一致；若建置時指定簽署憑證 SHA-256，還必須完全相符。實驗版不強制簽章，只能搭配已驗證的官方 Release attestation 使用。SHA-256 逐檔驗證負責偵測解壓後的缺漏、額外檔案與變更。

Manager EXE 內含一個可由封裝工具直接讀取的 NUL 結尾 ASCII 建置政策標記：

`FFB_MANAGER_BUILD_POLICY_V1|MODE=<STABLE|EXPERIMENTAL>|SIGNER_SHA256=<64 個大寫十六進位字元|UNPINNED|NONE>|END`

封裝工具不得載入或執行待檢查的 EXE；應在簽章前後都解析受限大小的 raw PE，要求上述前綴恰好出現一次、整個標記完全符合格式並緊接 NUL，而且完整位於 `.rdata` 的 raw size 與 mapped `VirtualSize` 範圍。該區段必須是 initialized-data／READ、不得 WRITE／EXEC；raw padding、憑證表或檔尾 overlay 的假標記都必須拒絕。正式簽章封裝要求 `MODE=STABLE` 與 64 位 signer SHA-256；`UNPINNED` 只供非正式開發建置辨識，官方 `-RequireSigning` 封裝一律拒絕，`NONE` 只允許實驗版。最後仍須核對 Authenticode signer，再建立 manifest。這個標記是建置政策證據，不取代 Authenticode、簽署者比對與 manifest 驗證。
