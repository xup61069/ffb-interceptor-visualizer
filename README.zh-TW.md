# FFB Interceptor + Visualizer 1.0.0（台灣繁體中文）

本檔是完整台灣中文使用說明。FFB Interceptor 觀察 DirectInput8 力回饋命令，將資料
送到 SimHub 外掛或 Python 檢視器；它不會量到方向盤馬達實際扭力，也不能當反作弊、
硬體保護或駕駛安全裝置。

> 高扭力方向盤可能突然動作。請準備實體急停、讓手部遠離轉動範圍、從最低增益開始，
> 並只在離線／單機環境測試。

## 即開即用首選

1. 從 [GitHub Releases](https://github.com/xup61069/ffb-interceptor-visualizer/releases)
   下載 `FFBInterceptor-Launcher-1.0.0.zip`。
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
`FFBInterceptor-Launcher-1.0.0.zip`，表示只有 GitHub-hosted 基礎實驗版，尚未提供
即開即用套件；`ffb-proxy-*.zip` 不是替代品。

詳細按鈕、診斷、升級與解除安裝方式見
[Manager 操作說明](launcher/MANAGER.zh-TW.md)，版本差異見 [變更紀錄](CHANGELOG.md)。

## 套件信任政策

`v1.0.0` 是首個 1.x 產品版本，不代表資產已簽章。V1 目前兩條公開 workflow 都只發布
未簽章 Experimental；完整流程收到 `stable` 會 fail-closed，且完全不讀簽章 secrets。
Stable 的程式內政策與封裝測試仍保留，但不是已啟用的公開頻道。

| 頻道 | 實際政策 |
| --- | --- |
| Stable（公開流程未啟用） | 程式內保留 fail-closed Manager 政策：執行中 Manager 與 manifest 內所有 `.exe`、`.dll`、`.ps1`、`.psm1` 都要驗證；目前 Launcher allowlist 合計 11 個簽章 payload。全部必須通過 Authenticode 信任鏈及撤銷檢查、同一 signer，並符合建置時釘選的憑證 SHA-256，否則拒絕安裝與啟動。未來公開 Stable 還需要獨立且不執行未信任建置程式的簽章 job、公信憑證與實體測試。 |
| Experimental（現行公開頻道） | 兩條公開發行流程都固定不簽章，也完全不讀任何 Stable 簽章 secrets；Manager 會明確警告。套件內 `SHA256SUMS.txt` 的精確檔案清單與 SHA-256 仍是硬性閘門；使用者另須從官方 Release 核對外層 `SHA256SUMS`，並用 `gh attestation verify <檔案> --repo xup61069/ffb-interceptor-visualizer` 驗證外部 provenance。Attestation 不等於 Authenticode。 |

Manager 會拒絕缺檔、多檔、重複或跳脫路徑、reparse point、雜湊錯誤、遊戲／Hook
架構不合、外掛安裝雜湊不合與未就緒狀態。通過後會鎖住套件必要檔案直到操作完成；
逾時且程序可能仍在執行時，會停止後續安裝、解除安裝與啟動。複製診斷時會把使用者
家目錄遮成 `%USERPROFILE%`。解除安裝只處理受保護狀態記錄且雜湊仍符合的檔案；實際
寫入 SimHub 與 `%ProgramData%` 狀態時，會重新核對實體磁碟與逐層目錄身分，並持有
跨程序、零共享的 delete-on-close mutation lease。既有狀態若指向另一個 SimHub 根目錄，
必須先解除安裝才能切換。

未啟用於公開發行的 Stable EXE 支援另含唯一、NUL 結尾且釘選 signer 的
`FFB_MANAGER_BUILD_POLICY_V1` marker；
封裝器會在簽章前後重新解析 raw PE，要求 marker 完整落在 `.rdata` 的 raw size 與
mapped `VirtualSize` 範圍；區段必須是 initialized-data／READ、不得 WRITE／EXEC，並
拒絕 raw padding、憑證表／overlay 假標記。最後再核對 Manager Authenticode leaf
certificate SHA-256，兩者一致後才產生 manifest。Marker 是封裝政策閘門，不能取代
Authenticode。

Proxy、Hook、Launcher 與 Manager 使用靜態 MSVC CRT，並設定
`/DEPENDENTLOADFLAG:0x800`，讓 PE 的靜態匯入相依只從 System32 搜尋；這可降低進入
安全檢查前的 app-local DLL 劫持面，但不涵蓋任意動態載入。

## 削峰模型：同裝置保守加總、跨裝置不相加

v1.0.0 的 `ConservativeAbsoluteSumPerDevice` 模型，會對同一來源／session 中每一個
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
v1.0.0 相容矩陣目前只有下列 profile（紀錄日期 2026-08-30）：

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
  目錄沒有 `dinput8.dll`。GitHub Windows runner 本身是 UAC 關閉的管理員，因此 CI 會
  在隔離暫存目錄用一次性標準使用者帳號執行正式 Launcher，完成後刪除帳號與暫存，
  並在測試期間暫時把該帳號 SID 加入目前 runner 的互動 window station／desktop ACL；
  整段作業以跨程序鎖序列化，結束時先確認 ACL 未被其他程序變更，再還原完整原始 ACL；
  若已變更就拒絕覆寫。之後才刪除帳號，不會編入提權繞過。IAT 單元測試另覆蓋
  `DirectInput8Create` 的名稱匯入與 `dinput8.dll` ordinal 1 匯入，並確認不覆寫已被其他
  元件修改的 IAT 項目。這不是硬體或商業遊戲測試。
- Native `/src/`＋`/launcher/manager_model.cpp` 產品程式碼 line coverage 門檻 50%、
  至少 900 tracked lines，且兩個路徑都要出現；SimHub Core 為 75%、至少 500
  tracked lines；Python pytest 為 85%。
- Hosted CI 另測 Python 3.12／3.13、dashboard／installer／release fixture、CodeQL、
  dependency audit、完整歷史 secret scan 與 workflow／SPDX 稽核。
- `sbom.cdx.json`（CycloneDX 1.6）與 `sbom.spdx.json`（SPDX 2.3）包含 8 個第一方
  component、`uv.lock` 完整 registry Python component／dependency，以及不重新散布的
  SimHub SDK exact fingerprint。
- `python-environment.cdx.json` 與 `python-environment.spdx.json` 描述鎖定安裝的 Python
  環境。四份 SBOM 與所有 Release 資產都會納入 SHA-256 與 provenance attestation。

兩條公開發行 workflow 都只接受授權維護者送出的 `repository_dispatch`，並只從預設
分支 `master` 載入。基礎流程 payload 必須剛好只有 `tag`；完整流程必須剛好只有
`tag`、`channel` 與 `simhub_path`，其中 `channel` 只接受小寫 `experimental`；`stable`、
欄位或格式不合都會 fail-closed。建立或推送 tag 本身不會發布 Release；維護者仍須先為
該 tag 選定唯一 publisher。Full 即使恢復 private mutable draft，也要求 `github.sha`、
checkout、當下 `origin/master`、tag commit 與 build output 是同一 SHA；只有 Base
Experimental 草稿恢復可使用 master ancestor。

Hosted Experimental 基礎發行只有 Proxy x86／x64、Viewer x64、source、四份 SBOM 與
`SHA256SUMS`。只有 labels 完整符合
`[self-hosted, Windows, X64, simhub-sdk, ephemeral, ffb-release]` 的完整流程，才會再產生
`FFBInterceptor-SimHub-1.0.0.zip` 與 `FFBInterceptor-Launcher-1.0.0.zip`。

完整流程的 Low IL AppContainer self-hosted 建置 job 只有 `actions: read`、`checks: read`、
`contents: read`，只建置並透過 Actions artifact 移交精確 11 個資產；它沒有 Release、OIDC、
attestation 或簽章 secret 權限。獨立 `windows-latest` 發布 job 才具有
`contents: write`、`id-token: write`、`attestations: write`，並綁定 `stable-signing`
environment 人工核准。它只驗證資料的精確清單、路徑與 SHA-256，不執行建置產物，之後
產生 provenance 並發布為 prerelease Experimental。environment 名稱不代表正在簽署 Stable。
其中 SimHub／Launcher ZIP 會在 hosted job 再做純靜態 exact-entry、內層 SHA-256、禁止
`dinput8.dll` 與禁止夾帶 SimHub proprietary SDK DLL 的驗證。Attestation 只證明 publisher
收到並送出的 exact bytes 與 workflow／commit 身分，不代表 self-hosted 主機乾淨或二進位可重現。
它也不會把允許名稱下的 scripts、文件、Dashboard 或 PE 內容逐一和受信任 checkout 做
同源比對；遭入侵的 builder 仍可能產生內層 manifest 自洽但內容惡意的 Experimental 資產。
這是本版明示接受的殘餘風險，未來 Stable 不得沿用這個信任假設。

截至 2026-09-03，GitHub 已啟用 immutable releases；tag ruleset `21893944` 會保護
`refs/tags/v*`，禁止更新或刪除；`stable-signing` environment 只允許 `master`，並由
`xup61069` 審核。完整發行只使用按工作臨時註冊、完成後自動退役的一次性 runner。
若使用持續存在的 Windows 主機，runner 必須位於通過原生 credential／filesystem probe 的
Low IL AppContainer，且 SDK 與 x64／x86 toolchain snapshots 對 job 唯讀；
目前仍沒有公信程式碼簽章憑證與對應 secrets，也沒有實體方向盤／商業遊戲測試證據，不能
把未簽章 Full 資產宣稱為 Stable。未來公開 Stable 還必須有獨立且不執行未信任建置程式的
簽章 job、公信憑證與實體測試；目前沒有 Stable dispatch 或 Stable recovery。完整細節見
[發行流程](docs/release-process.md)。

## 支援限制

- 僅支援 `DirectInput8Create` 建立的 x86／x64 DirectInput8；不支援 GameInput、WinRT、
  XInput、私有 SDK、驅動／HID Hook、任意 PID／DLL 注入或反作弊規避。
- Launcher 只啟動使用者選取的新本機離線子程序；iRacing 明列為不支援。
- current-user Named Pipe 會拒絕遠端 client 並核對 Hello PID，但同一使用者的惡意程序
  不在完整安全邊界內。遙測失敗不會阻斷原始 DirectInput 呼叫。
- 傳統 Proxy 模式仍供開發／相容性研究，但不是首選。不要覆寫遊戲既有
  `dinput8.dll`；先備份並確認可還原。
- 目前沒有可宣稱的公信簽章憑證與 secrets、實體高扭力方向盤或完整商業遊戲測試證據。

## 開發者建置

```powershell
cmake --preset msvc-x64-release
cmake --build --preset x64-release --target dinput8 ffb_hook ffb_launcher ffb_manager
ctest --test-dir build/x64-release --output-on-failure

pwsh -File simhub\tools\Test-SimHubSdk.ps1 -SimHubInstallPath 'C:\Program Files (x86)\SimHub'
pwsh -File simhub\tools\Build-SimHubPackage.ps1
pwsh -File simhub\tools\Build-LauncherPackage.ps1
```

x86 請在 `VsDevCmd.bat -arch=x86` 環境獨立建置；SimHub 封裝腳本需求為 PowerShell 7
（`pwsh`）。Python viewer 需求為 Python 3.12+ 與 uv：

```powershell
cd viewer
uv sync --locked --extra dev
uv run ffb-viewer
```

更多資料見 [Protocol v1](docs/protocol-v1.md)、[安全模型](docs/security-model.md)、
[SECURITY.md](SECURITY.md) 與 [發行流程](docs/release-process.md)。本專案依
[GNU GPLv3](LICENSE) 發行，上游與第三方授權見
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
