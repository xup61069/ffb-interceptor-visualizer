# FFB Interceptor + Visualizer 0.3.0（台灣繁體中文）

本檔是完整台灣中文使用說明。FFB Interceptor 觀察 DirectInput8 力回饋命令，將資料
送到 SimHub 外掛或 Python 檢視器；它不會量到方向盤馬達實際扭力，也不能當反作弊、
硬體保護或駕駛安全裝置。

> 高扭力方向盤可能突然動作。請準備實體急停、讓手部遠離轉動範圍、從最低增益開始，
> 並只在離線／單機環境測試。

## 即開即用首選

1. 從 [GitHub Releases](https://github.com/xup61069/ffb-interceptor-visualizer/releases)
   下載 `FFBInterceptor-Launcher-0.3.0.zip`。
2. 驗證 `SHA256SUMS`、Release 頻道與 provenance attestation，完整解壓縮 ZIP。
3. 正常雙擊 `FFBInterceptor.Manager.exe`，不要用系統管理員身分啟動 Manager。
4. 第一次選擇離線遊戲 EXE 與 SimHub 資料夾，按「安裝／更新插件」並接受安裝所需的
   UAC；到 SimHub **Settings → Plugins** 啟用 **FFB Interceptor**。
5. 回到 Manager 按「一鍵啟動」。往後可在最多 64 個設定檔間切換；設定檔只保存名稱、
   路徑、啟動參數與偏好，不保存密碼、帳號或 Token。

SimHub 必須安裝在實體固定本機磁碟；網路／卸除式磁碟、`SUBST` 磁碟代號、junction
與其他 reparse 路徑會被拒絕，避免 UAC 驗證後目的路徑被換走。

這個 Launcher ZIP 完全不含 `dinput8.dll`，也不會在遊戲目錄放置、覆寫或修改
`dinput8.dll`。Manager 只會使用套件內固定架構的 Launcher／Hook，建立使用者選取的
新遊戲子程序；不會附加既有 PID、選任意 DLL 或修改遊戲 EXE。若 Release 頁面沒有
`FFBInterceptor-Launcher-0.3.0.zip`，表示只有 GitHub-hosted 基礎實驗版，尚未提供
即開即用套件；`ffb-proxy-*.zip` 不是替代品。

詳細按鈕、診斷、升級與解除安裝方式見
[Manager 操作說明](launcher/MANAGER.zh-TW.md)。

## 套件信任政策

| 頻道 | 實際政策 |
| --- | --- |
| Stable | 以 fail-closed Manager 建置。執行中 Manager 與 manifest 內所有 `.exe`、`.dll`、`.ps1`、`.psm1` 都要驗證；目前 Launcher allowlist 合計 11 個簽章 payload。全部必須通過 Authenticode 信任鏈及撤銷檢查、同一 signer，並符合建置時釘選的憑證 SHA-256，否則拒絕安裝與啟動。流程已實作，但儲存庫不宣稱目前已有公信簽章憑證、所需 self-hosted runner 或已發布 Stable 資產。 |
| Experimental | 兩條公開發行流程都固定不簽章，也完全不讀 Stable 的簽章 secrets；Manager 會明確警告。套件內 `SHA256SUMS.txt` 的精確檔案清單與 SHA-256 仍是硬性閘門；使用者另須從官方 Release 核對外層 `SHA256SUMS`，並用 `gh attestation verify <檔案> --repo xup61069/ffb-interceptor-visualizer` 驗證外部 provenance。Attestation 不等於 Authenticode。 |

Manager 會拒絕缺檔、多檔、重複或跳脫路徑、reparse point、雜湊錯誤、遊戲／Hook
架構不合、外掛安裝雜湊不合與未就緒狀態。通過後會鎖住套件必要檔案直到操作完成；
逾時且程序可能仍在執行時，會停止後續安裝、解除安裝與啟動。複製診斷時會把使用者
家目錄遮成 `%USERPROFILE%`。解除安裝只處理受保護狀態記錄且雜湊仍符合的檔案；實際
寫入 SimHub 與 `%ProgramData%` 狀態時，會重新核對實體磁碟與逐層目錄身分，並持有
跨程序、零共享的 delete-on-close mutation lease。既有狀態若指向另一個 SimHub 根目錄，
必須先解除安裝才能切換。

Stable EXE 另含唯一、NUL 結尾且釘選 signer 的 `FFB_MANAGER_BUILD_POLICY_V1` marker；
封裝器會在簽章前後重新解析 raw PE，要求 marker 完整落在 `.rdata` 的 raw size 與
mapped `VirtualSize` 範圍；區段必須是 initialized-data／READ、不得 WRITE／EXEC，並
拒絕 raw padding、憑證表／overlay 假標記。最後再核對 Manager Authenticode leaf
certificate SHA-256，兩者一致後才產生 manifest。Marker 是封裝政策閘門，不能取代
Authenticode。

Proxy、Hook、Launcher 與 Manager 使用靜態 MSVC CRT，並設定
`/DEPENDENTLOADFLAG:0x800`，讓 PE 的靜態匯入相依只從 System32 搜尋；這可降低進入
安全檢查前的 app-local DLL 劫持面，但不涵蓋任意動態載入。

## 削峰模型：同裝置保守加總、跨裝置不相加

v0.3.0 的 `ConservativeAbsoluteSumPerDevice` 模型，會對同一來源／session 中每一個
DirectInput 裝置分別計算：將當下播放且可建模的 Constant、Ramp、Periodic 效果取
瞬時絕對值，在同一 `DeviceId` 內加總，再取各裝置中最大的總和。

- 不同裝置不相加；不同來源／session 也不相加。`AnyClipping` 是可靠來源之間的 OR。
- 相反方向的效果可能在真實世界互相抵消，絕對值和仍會高估；因此這是命令削峰保守
  上界，不是力向量重建或馬達扭力。
- 判定使用未套用 effect／device gain 的合併命令；套用 gain 後的數值另行公開。
- 預設達 98% 進入候選；連續 100 ms 或最近 1 秒有 5% 時間碰頂便觸發；低於 95%
  持續 500 ms 才解除。基準是 `DI_FFNOMINALMAX`。
- Condition／Custom 不會被猜成力值，只會列為模型不支援；可支援效果仍可照常計算。

## Trigger 與容量可靠性

Protocol v1 有 TriggerButton 設定，卻沒有即時按鍵狀態，所以無法知道驅動是否自行
啟動按鍵觸發效果。只要來源存在這類效果，便標記 `TriggerStateUnavailable`，並停用
`DataReliable`、`AtLimit` 與 `IsClipping`。封包遺失、舊 session 重連或容量超限也會
清除／停用舊結論，不會用部分資料假裝可靠。

- Core 最多 64 個來源；每來源最多 64 個裝置、1,024 個效果。
- Secure Pipe 最多 32 個同時 client；frame 上限 64 KiB、最多 8 軸。
- 每來源診斷 transition queue 上限 256；公開 SimHub 事件由 snapshot 邊緣產生。
- 超限會增加明確 drop counter 並停用判定。每來源問題需建立新的 producer session；
  全域 source 容量曾超限時，需重啟 SimHub／接收端建立新的 Core instance。

## SimHub 9.11.22 exact fingerprint

外掛只對指紋精確相符的已安裝 SimHub SDK 建置；SimHub 自有 DLL 不會被放入 Release。
v0.3.0 相容矩陣目前只有下列 profile（紀錄日期 2026-08-30）：

| 檔案 | 位元組 | SHA-256 |
| --- | ---: | --- |
| `GameReaderCommon.dll` | 388248 | `7A5EE7BA3D81B5DC373EA81C28967B06F5CC1CDF32D375DDA33EDEA9137A719F` |
| `log4net.dll` | 270336 | `1D45A6AFA38F0B10814063F2A42E6EFCE45752853667650E765844B8566B3332` |
| `SimHub.Logging.dll` | 14488 | `35FDD0CE83D0B0124B634849C186E200F20EA553EA0C9EBECF8651FAF3C69293` |
| `SimHub.Plugins.dll` | 9472664 | `F36D1930270089F6E8AC3B909D2B0A75A9A40EB22AC75ED551FD8831373D16EF` |

四檔的長度與 SHA-256 必須同時完全一致。這是 SDK 建置閘門，不是商業遊戲或實體
方向盤相容性保證。權威資料為 [sdk-compatibility.json](simhub/sdk-compatibility.json)。

## E2E、coverage 與 SBOM

- Windows x86／x64 CI 使用專案 fixture，走完
  Launcher → Hook → 系統 DirectInput8 → secure pipe → SimHub Core；測試先確認 fixture
  目錄沒有 `dinput8.dll`。這不是硬體或商業遊戲測試。
- Native `/src/`＋`/launcher/` line coverage 門檻 50%、至少 900 tracked lines，且兩個
  路徑都要出現；SimHub Core 為 75%、至少 500 tracked lines；Python pytest 為 85%。
- Hosted CI 另測 Python 3.12／3.13、dashboard／installer／release fixture、CodeQL、
  dependency audit、完整歷史 secret scan 與 workflow／SPDX 稽核。
- `sbom.cdx.json`（CycloneDX 1.6）與 `sbom.spdx.json`（SPDX 2.3）包含 8 個第一方
  component、`uv.lock` 完整 registry Python component／dependency，以及不重新散布的
  SimHub SDK exact fingerprint。
- `python-environment.cdx.json` 與 `python-environment.spdx.json` 描述鎖定安裝的 Python
  環境。四份 SBOM 與所有 Release 資產都會納入 SHA-256 與 provenance attestation。

兩條公開發行 workflow 都只接受授權維護者送出的 `repository_dispatch`，並只從預設
分支 `master` 載入。基礎流程 payload 必須剛好只有 `tag`；完整流程必須剛好只有
`tag`、`channel` 與 `simhub_path`。欄位或格式不合就停止。建立或推送 tag 本身不會
發布 Release；維護者仍須先為該 tag 選定唯一 publisher。

Hosted Experimental 基礎發行只有 Proxy x86／x64、Viewer x64、source、四份 SBOM 與
`SHA256SUMS`。只有 labels 完整符合
`[self-hosted, Windows, X64, simhub-sdk, ephemeral]` 的完整流程，才會再產生
`FFBInterceptor-SimHub-0.3.0.zip` 與 `FFBInterceptor-Launcher-0.3.0.zip`。

截至 2026-08-31，GitHub 已啟用 immutable releases；tag ruleset `21893944` 會保護
`refs/tags/v*`，禁止更新或刪除；`stable-signing` environment 只允許 `master`，並由
`xup61069` 審核。目前仍沒有可用的一次性 ephemeral runner、公信程式碼簽章憑證與
對應 secrets，也沒有實體方向盤／商業遊戲測試證據。完整細節見
[發行流程](docs/release-process.md)。

## 支援限制

- 僅支援 `DirectInput8Create` 建立的 x86／x64 DirectInput8；不支援 GameInput、WinRT、
  XInput、私有 SDK、驅動／HID Hook、任意 PID／DLL 注入或反作弊規避。
- Launcher 只啟動使用者選取的新本機離線子程序；iRacing 明列為不支援。
- current-user Named Pipe 會拒絕遠端 client 並核對 Hello PID，但同一使用者的惡意程序
  不在完整安全邊界內。遙測失敗不會阻斷原始 DirectInput 呼叫。
- 傳統 Proxy 模式仍供開發／相容性研究，但不是首選。不要覆寫遊戲既有
  `dinput8.dll`；先備份並確認可還原。
- 目前沒有可宣稱的公信簽章憑證與 secrets、一次性 ephemeral SimHub runner、實體
  高扭力方向盤或完整商業遊戲測試證據。

## 開發者建置

```powershell
cmake --preset msvc-x64-release
cmake --build --preset x64-release --target dinput8 ffb_hook ffb_launcher ffb_manager
ctest --test-dir build/x64-release --output-on-failure

simhub\tools\Test-SimHubSdk.ps1 -SimHubInstallPath 'C:\Program Files (x86)\SimHub'
simhub\tools\Build-SimHubPackage.ps1
simhub\tools\Build-LauncherPackage.ps1
```

x86 請在 `VsDevCmd.bat -arch=x86` 環境獨立建置。Python viewer 需求為 Python 3.12+
與 uv：

```powershell
cd viewer
uv sync --locked --extra dev
uv run ffb-viewer
```

更多資料見 [Protocol v1](docs/protocol-v1.md)、[安全模型](docs/security-model.md)、
[SECURITY.md](SECURITY.md) 與 [發行流程](docs/release-process.md)。本專案依
[GNU GPLv3](LICENSE) 發行，上游與第三方授權見
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
