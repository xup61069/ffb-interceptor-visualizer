# FFB Interceptor + Visualizer 1.0.0

FFB Interceptor 會觀察遊戲送出的 DirectInput8 力回饋「命令」，把資料送到 SimHub
外掛或獨立 Python 檢視器。它不會量到方向盤基座／馬達的實際扭力，也不是反作弊、
駕駛安全或硬體保護裝置。

> 高扭力方向盤可能突然動作。請先把增益調到最低、讓手部遠離轉動範圍、準備實體
> 急停，並只在離線／單機環境測試。

## 首選：下載、解壓縮、雙擊 Manager

一般使用者不必自己建置，也不必把任何 DLL 放進遊戲資料夾。

1. 到 [GitHub Releases](https://github.com/xup61069/ffb-interceptor-visualizer/releases)，
   下載 `FFBInterceptor-Launcher-1.0.0.zip`。不要下載名稱含 `source` 或
   `ffb-proxy` 的檔案來代替它。
2. 驗證 Release 頻道、`SHA256SUMS` 與來源證明後，把整個 ZIP 解壓縮到本機固定
   資料夾；不要直接在壓縮檔預覽視窗內執行。
3. 正常雙擊 `FFBInterceptor.Manager.exe`，不要選「以系統管理員身分執行」。
4. 第一次使用時，選擇離線遊戲 EXE 與 SimHub 安裝資料夾，按「安裝／更新插件」。
   Windows 只會在安裝 SimHub 外掛時要求 UAC。
5. 到 SimHub 的 **Settings → Plugins** 啟用 **FFB Interceptor**，視需要匯入套件內
   Dashboard／Overlay，回到 Manager 按「一鍵啟動」。
6. 之後只要雙擊 Manager、選遊戲設定檔，再按「一鍵啟動」。Manager 可保存最多
   64 個遊戲設定檔，只記錄名稱、路徑、啟動參數與偏好，不保存帳號、密碼或 Token。

SimHub 安裝根目錄必須位於實體固定本機磁碟；網路／卸除式磁碟、`SUBST` 磁碟代號、
junction 或其他 reparse 路徑會被拒絕，避免 UAC 驗證後目的路徑被換到別處。

這個首選套件完全不包含、也不會在遊戲目錄放置或修改 `dinput8.dll`。Manager 只會
呼叫套件內固定的 x86／x64 Launcher 與 Hook，建立使用者明確選取的新遊戲子程序；
不會指定既有 PID、不會附加到已執行程序，也不能選任意 DLL。Hook 只在該新子程序的
記憶體中接上 `DirectInput8Create`，不修改遊戲 EXE 或遊戲資料夾。

完整 Launcher ZIP 只能由具有指紋相符之 SimHub SDK 的完整發行流程產生。如果某個
Release 頁面沒有 `FFBInterceptor-Launcher-1.0.0.zip`，代表該次只有 GitHub-hosted
基礎實驗版資產，尚未提供即開即用的 Manager 套件；請勿把 Proxy ZIP 當成替代品。

更詳細的 Manager 操作見 [即開即用管理器說明](launcher/MANAGER.zh-TW.md)，版本差異見
[變更紀錄](CHANGELOG.md)。

## Stable 與 Experimental 要怎麼分

`v1.0.0` 是首個 1.x 產品版本；它不等於「已簽章」。V1 目前兩條公開 workflow 都只發布
未簽章 Experimental；完整流程收到 `stable` 會 fail-closed，且兩條流程都完全不讀簽章
secrets。下列 Stable 規則是仍保留於程式與封裝測試中的政策支援，並不是已啟用的公開頻道。

| 頻道 | 啟動規則 | 使用者應做的驗證 |
| --- | --- | --- |
| Stable（穩定版，公開流程未啟用） | 程式內保留 fail-closed Manager 政策：驗證執行中 Manager，以及 manifest 內所有 `.exe`、`.dll`、`.ps1`、`.psm1`；目前 Launcher allowlist 合計 11 個簽章 payload。全部必須通過 Windows Authenticode 信任鏈與撤銷檢查、使用同一簽署者，並符合建置時釘選的憑證 SHA-256；任一項失敗就拒絕安裝與啟動。 | 未來公開 Stable 還必須有獨立且不執行未信任建置程式的簽章 job、公信程式碼簽章憑證，以及實體方向盤／商業遊戲測試。現行公開 workflow 不會產生 Stable 資產。 |
| Experimental（實驗版，現行公開頻道） | 兩條公開發行流程都固定不簽章，也完全不讀任何 Stable 簽章 secrets。Manager 仍會嚴格驗證套件內 `SHA256SUMS.txt`、必要檔案、精確清單與逐檔 SHA-256，但不把 Authenticode 當成啟動門檻，介面會顯示警告。 | 從官方 Release 下載，核對外層 `SHA256SUMS`，並在執行前以 GitHub CLI 的 `gh attestation verify <檔案> --repo xup61069/ffb-interceptor-visualizer` 驗證 provenance attestation。Attestation 不是 Authenticode，也不能取代解壓後的逐檔雜湊。 |

Manager 啟動或安裝前還會確認套件沒有缺檔、多檔、重複／跳脫路徑、reparse point
或雜湊不符，檢查遊戲與 Launcher／Hook 架構一致、SimHub 外掛安裝狀態及具名管道
readiness。驗證成功後，必要檔案會保持唯讀鎖定直到安裝或遊戲程序完成；若程序逾時而
狀態不明，Manager 會停用後續變更。診斷資訊可一鍵複製，複製前會把家目錄改寫成
`%USERPROFILE%`。安全升級與解除安裝只處理受保護安裝狀態所記錄的檔案，發現遭修改
時會拒絕覆寫或移除。外掛目的目錄與 `%ProgramData%` 安裝狀態在實際寫入期間也會以
實體磁碟、逐層目錄身分及跨程序、零共享的 delete-on-close mutation lease 重新確認並
保持鎖定；若既有狀態指向另一個 SimHub 根目錄，必須先解除安裝再切換。

尚未啟用於公開發行的 Stable Manager 支援會內含唯一、NUL 結尾的
`FFB_MANAGER_BUILD_POLICY_V1|MODE=STABLE|SIGNER_SHA256=<64 HEX>|END` marker。封裝器會
在簽章前後都重新解析 raw PE，要求 marker 完整落在 `.rdata` 的 raw size 與 mapped
`VirtualSize` 範圍；該區段必須是 initialized-data／READ、不得 WRITE／EXEC，並拒絕
未釘選、格式錯誤或只塞在 raw padding、憑證表／檔尾 overlay 的 Manager。最後再核對
Authenticode leaf certificate SHA-256 與 marker 一致，通過後才產生最終 manifest。

Proxy、Hook、Launcher 與 Manager 使用靜態 MSVC CRT，並設定
`/DEPENDENTLOADFLAG:0x800`，讓 PE 的靜態匯入相依只從 System32 搜尋，降低安全檢查進入
點之前的 app-local DLL 劫持面；這不會替任意動態載入提供同樣保證。

## 削峰偵測的白話定義

v1.0.0 使用 `ConservativeAbsoluteSumPerDevice`（同裝置絕對值保守加總）：

- 對同一來源／session 內，每一個 DirectInput 裝置分開計算。當下正在播放且可建模的
  Constant、Ramp、Periodic 效果，會先取瞬時命令的絕對值，再在「同一裝置」內加總。
- 不同裝置的數值不會互加；系統只取各裝置加總值中的最大值。因此方向盤與另一個
  DirectInput 裝置不會被誤當成同一顆馬達相加。
- 不同來源／session 也不互加。`AnyClipping` 是對資料可靠之來源做布林 OR，不是把
  多個遊戲或程序的命令值相加。
- 同裝置內，實際方向相反的效果可能彼此抵消，但保守模型仍會加上絕對值，所以可能
  高估、不能低估純量同向碰頂；這是命令削峰上界，不是力向量重建或馬達扭力。
- 偵測值使用未套用 effect／device gain 的合併命令；套用 gain 後的
  `CombinedEffectiveCommandLevel` 會另外公開供顯示，不混成實際扭力結論。

預設在合併命令達 98% 時進入 LIMIT 候選；連續 100 ms 碰頂，或最近 1 秒內至少 5%
的時間碰頂，就觸發 CLIP。低於 95% 且持續 500 ms 才解除。這些門檻都是相對於
`DI_FFNOMINALMAX` 的 DirectInput 命令比例。

Condition 與 Custom 效果會列入不支援效果計數，但不會被硬猜成力值。若同時有可支援
效果，仍可對那些效果計算；畫面必須保留「模型受限」資訊。

## 可靠性與容量上限

削峰狀態採 fail-closed：資料不完整時寧可顯示「不可靠」，不繼續沿用可能錯誤的 CLIP。

- Protocol v1 會帶入 TriggerButton 設定，卻沒有遊戲輸入按鍵的即時狀態。只要存在
  按鍵觸發效果，就無法知道驅動何時自行開始播放；該來源會標成
  `TriggerStateUnavailable`，`DataReliable`、`AtLimit` 與 `IsClipping` 會停用。
- 封包遺失、舊 session 重連或狀態容量超限，也會清除／停用舊削峰結論並公開原因與
  drop counter。每來源問題需建立新的 producer session；若全域 source 容量曾超限，
  `_sourceStateDrops` 會保持 fail-closed，需重啟 SimHub／接收端建立新的 Core instance。
- Core 最多保留 64 個來源；每個來源最多 64 個裝置、1,024 個效果。超出時不會靜默
  截斷後照常判定，而是增加容量 drop 並停用受影響的削峰結論。
- SimHub 安全具名管道最多同時接受 32 個 client；每個 frame 上限 64 KiB、最多 8 軸。
  每來源診斷 transition queue 上限 256；公開 SimHub 事件則由已發布 snapshot 的邊緣
  產生，不依賴這個可丟棄的診斷佇列。

## SimHub SDK 相容性指紋

可安裝外掛只允許使用儲存庫列入矩陣的真實 SimHub SDK 建置，不會 vendoring 或重新
散布 SimHub 自有組件。v1.0.0 目前只有 SimHub **9.11.22** 的 exact-length-and-SHA256
profile（矩陣紀錄日期 2026-08-30）：

| 檔案 | 位元組 | SHA-256 |
| --- | ---: | --- |
| `GameReaderCommon.dll` | 388248 | `7A5EE7BA3D81B5DC373EA81C28967B06F5CC1CDF32D375DDA33EDEA9137A719F` |
| `log4net.dll` | 270336 | `1D45A6AFA38F0B10814063F2A42E6EFCE45752853667650E765844B8566B3332` |
| `SimHub.Logging.dll` | 14488 | `35FDD0CE83D0B0124B634849C186E200F20EA553EA0C9EBECF8651FAF3C69293` |
| `SimHub.Plugins.dll` | 9472664 | `F36D1930270089F6E8AC3B909D2B0A75A9A40EB22AC75ED551FD8831373D16EF` |

四個檔案必須全部存在，且長度與 SHA-256 同時完全相符；其他 SimHub 版本會拒絕產生
可發布外掛。這是建置 API 相容性閘門，不代表已用該版本完成所有商業遊戲或實體方向盤
測試。權威資料見 [SDK 相容矩陣](simhub/sdk-compatibility.json)。

## CI、E2E 與覆蓋率

GitHub-hosted Windows CI 不需要 proprietary SimHub SDK，就能執行以下驗證：

- x86／x64 建置 Proxy、Launcher、Hook、Manager 與原生測試。
- 專案自有的 `FFBInterceptor.E2E.Probe.exe` 透過真正的系統 DirectInput8，驗證
  **Launcher → Hook → DirectInput8 → current-user secure pipe → SimHub Core** 完整路徑；
  測試會先確認 fixture 目錄沒有 `dinput8.dll`。這是受控 fixture E2E，不是商業遊戲
  或實體方向盤測試。由於 GitHub Windows runner 固定以關閉 UAC 的管理員執行，CI
  會在隔離暫存目錄用一次性標準使用者帳號執行正式 Launcher，完成後刪除帳號與暫存；
  測試期間只把該帳號 SID 暫時加入目前 runner 的互動 window station／desktop ACL，
  結束時先確認 ACL 未被其他程序變更，再還原完整原始 ACL；若已變更就拒絕覆寫。
  整段作業另以跨程序鎖序列化，再刪除帳號，不會為測試編入提權繞過。IAT 單元測試另
  同時覆蓋 `DirectInput8Create` 的名稱匯入與 `dinput8.dll` ordinal 1 匯入，且不會覆寫
  已被其他元件修改的 IAT 項目。
- 原生 `/src/` 與 `/launcher/manager_model.cpp` 的產品程式碼合併 line coverage 至少
  50%，且至少追蹤 900 行，兩個路徑都必須出現在報告；SimHub Core line coverage
  至少 75%、追蹤至少 500 行；
  Python viewer 的 pytest coverage 門檻為 85%。
- Python 3.12／3.13 的 lint、型別與測試，以及 dashboard schema、安裝器 fixture、
  SDK／release gate fixture、CodeQL C++／C#／Python、dependency audit、完整歷史
  gitleaks、actionlint、zizmor 與 SPDX header audit。

上述是自動化與合成測試證據。除非另有可重現報告，專案目前不宣稱完成實體高扭力
方向盤、所有商業遊戲、反作弊環境或長時間硬體 endurance 測試。

## Release 資產與 SBOM

兩條公開發行 workflow 都只接受授權維護者送出的 `repository_dispatch`，而且只從
預設分支 `master` 載入 workflow。基礎流程的 payload 必須剛好只有 `tag`；完整流程
必須剛好只有 `tag`、`channel` 與 `simhub_path`，其中 `channel` 只接受小寫
`experimental`，`stable` 會 fail-closed。欄位多一個、少一個或格式不合都會停止。
建立或推送 tag 本身不會發布 Release；維護者仍須先為該 tag 選定唯一 publisher。Full 即使
恢復 private mutable draft，也要求 `github.sha`、checkout、當下 `origin/master`、tag commit
與 build output 是同一 SHA；只有 Base Experimental 草稿恢復可使用 master ancestor。

GitHub-hosted Experimental 基礎發行會產生：

- `ffb-proxy-x86.zip`、`ffb-proxy-x64.zip`（傳統模式，不是首選）；
- `ffb-viewer-x64.zip`；
- `ffb-interceptor-visualizer-v1.0.0-source.zip`；
- `sbom.cdx.json`（CycloneDX 1.6）與 `sbom.spdx.json`（SPDX 2.3）；
- `python-environment.cdx.json` 與 `python-environment.spdx.json`；
- `SHA256SUMS` 與每個資產的 GitHub build-provenance attestation。

component SBOM 不只列 ZIP：它包含 8 個第一方元件（Proxy、Hook、Launcher、Manager、
Core、SimHub adapter、Dashboards、Viewer）、`uv.lock` 中完整的 registry Python
元件與依賴關係，以及未重新散布、僅供建置的 SimHub SDK exact fingerprint。
Python environment SBOM 則描述實際鎖定／安裝的 Python 發行套件；兩套都各有
CycloneDX 與 SPDX 格式。

Full 流程的 self-hosted 建置才會另外加入 `FFBInterceptor-SimHub-1.0.0.zip` 與首選的
`FFBInterceptor-Launcher-1.0.0.zip`，建置 runner labels 必須完整符合
`[self-hosted, Windows, X64, simhub-sdk, ephemeral, ffb-release]`；不含 secrets 的預檢則用
獨立 `ffb-preflight` label，避免兩類工作互搶。資產一旦同名上傳就不可由發行
腳本覆寫。

完整流程會把權限切成兩個 job：Low IL AppContainer 內的 self-hosted 建置 job 只有
`actions: read`、`checks: read`、`contents: read`，固定以未簽章政策建置並透過 Actions
artifact 移交精確 11 個資產；它沒有 Release、OIDC、attestation 或簽章 secret 權限。
獨立的 `windows-latest` 發布 job 才具有 `contents: write`、`id-token: write` 與
`attestations: write`，並綁定 `stable-signing` environment 的人工核准。該 job 只驗證
下載資料的精確清單、路徑與 SHA-256，不執行任何建置產物，最後產生 provenance 並發布為
prerelease Experimental。environment 名稱沿用既有設定，不代表 V1 正在執行 Stable 簽章。
其中 SimHub／Launcher ZIP 會在 hosted job 再做純靜態 exact-entry、內層 SHA-256、禁止
`dinput8.dll` 與禁止夾帶 SimHub proprietary SDK DLL 的驗證。Attestation 只證明 publisher
收到並送出的 exact bytes 與 workflow／commit 身分，不代表 self-hosted 主機乾淨或二進位可重現。
它也不會把允許名稱下的 scripts、文件、Dashboard 或 PE 內容逐一和受信任 checkout 做
同源比對；遭入侵的 builder 仍可能產生內層 manifest 自洽但內容惡意的 Experimental 資產。
這是本版明示接受的殘餘風險，未來 Stable 不得沿用這個信任假設。

截至 2026-09-03，GitHub 已啟用 immutable releases；tag ruleset `21893944` 會保護
`refs/tags/v*`，禁止更新或刪除；`stable-signing` environment 只允許 `master`，並由
`xup61069` 審核。完整發行的 self-hosted 建置只使用按工作臨時註冊、完成後自動退役的
ephemeral runner；
若使用持續存在的 Windows 主機，runner 必須位於通過原生 credential／filesystem probe 的
Low IL AppContainer，且 SDK 與 x64／x86 toolchain snapshots 對 job 唯讀；
目前仍沒有公信程式碼簽章憑證與對應 secrets，也沒有實體方向盤／商業遊戲測試證據，
因此不能把未簽章 Full 資產宣稱為 Stable。公開 Stable 還需另建不執行未信任建置程式的
獨立簽章 job、公信憑證與實體測試；目前沒有 Stable dispatch 或 Stable recovery。操作與
Experimental 草稿恢復規則見
[發行流程](docs/release-process.md)。

## 支援範圍

- 目前只支援透過 `DirectInput8Create` 建立的 x86／x64 DirectInput8 裝置。GameInput、
  WinRT、XInput、私有 SDK 與驅動／HID Hook 不在 v1.0.0 範圍。
- Launcher 模式只支援使用者明確選取、由它新建立的本機離線子程序；會拒絕系統目錄
  目標與提升權限執行。專案不提供任意 PID／DLL 注入、記憶體掃描或反作弊規避。
- iRacing 明列為不支援項目；這是維護者的支援政策，不是 GPL 額外用途限制。
- 傳統 `dinput8.dll` Proxy 仍供開發與相容性研究，但不是即開即用首選。絕對不要覆寫
  遊戲原有同名 DLL；先建立可驗證備份，並確認能完整還原。
- Named Pipe 限制為本機、目前 Windows 使用者並核對 Hello PID，但同一使用者底下的
  惡意程序不在完整信任邊界內。所有 telemetry queue 均有容量上限，傳送失敗不阻斷
  原始 DirectInput 呼叫。

## 從原始碼建置

需求為 Windows、Visual Studio C++ 工具、Windows SDK、CMake 3.20+、Ninja 與
PowerShell 7（`pwsh`；建置 SimHub 套件時使用）。

```powershell
cmake --preset msvc-x64-release
cmake --build --preset x64-release --target dinput8 ffb_hook ffb_launcher ffb_manager
ctest --test-dir build/x64-release --output-on-failure
```

x86 請在 `VsDevCmd.bat -arch=x86` 環境設定獨立的 `build/x86-release`。建置 SimHub
外掛與 Launcher ZIP 前，先用實際安裝的 SDK 驗證指紋：

```powershell
pwsh -File simhub\tools\Test-SimHubSdk.ps1 -SimHubInstallPath 'C:\Program Files (x86)\SimHub'
pwsh -File simhub\tools\Build-SimHubPackage.ps1
pwsh -File simhub\tools\Build-LauncherPackage.ps1
```

獨立 Python viewer 需求為 Python 3.12+ 與 [uv](https://docs.astral.sh/uv/)：

```powershell
cd viewer
uv sync --locked --extra dev
uv run ffb-viewer
```

協定、資料處理與安全細節見 [Protocol v1](docs/protocol-v1.md)、
[安全模型](docs/security-model.md)、[trace 格式](docs/trace-format.md) 與
[SECURITY.md](SECURITY.md)。

## 授權

本專案依 [GNU GPLv3](LICENSE) 發行。上游 MIT 聲明與其他第三方資訊保留於
[上游授權檔](licenses/upstream-dcs-force-feedback-fix-MIT.txt) 與
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。貢獻前請閱讀
[CONTRIBUTING.md](CONTRIBUTING.md) 與 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。
