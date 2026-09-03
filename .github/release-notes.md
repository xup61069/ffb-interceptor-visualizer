# FFB Interceptor {{TAG}}

> {{CHANNEL_NOTICE}}

這是 DirectInput8 力回饋「命令」遙測工具，不會量測方向盤基座／馬達實際扭力，也不是
反作弊、硬體保護或駕駛安全裝置。高扭力方向盤可能突然動作；請準備實體急停、讓手部
遠離轉動範圍、從最低增益開始，並只在離線／單機環境測試。

## 首選用法

若本 Release 附有 `FFBInterceptor-Launcher-{{VERSION}}.zip`：

1. 驗證下方 SHA-256 與 provenance attestation 後，完整解壓縮；V1 公開 Release 只有
   未簽章 Experimental。
2. 正常雙擊 `FFBInterceptor.Manager.exe`。
3. 第一次選遊戲 EXE 與 SimHub 路徑、按「安裝／更新插件」，在 SimHub 啟用
   **FFB Interceptor**。
4. 回到 Manager 按「一鍵啟動」；之後可直接選擇已保存的多遊戲設定檔。

Launcher 套件完全不含、也不會在遊戲資料夾放置或修改 `dinput8.dll`。它只對使用者
選取、由 Launcher 新建立的子程序使用固定同層 Hook；不附加既有 PID、不接受任意 DLL、
不修改遊戲 EXE。若沒有 Launcher ZIP，這次只有 hosted 基礎資產，不能把
`ffb-proxy-*.zip` 當成即開即用替代品。

## v{{VERSION}} 重點

- 完整 Launcher 套件提供原生 Windows `FFBInterceptor.Manager.exe`：首次選遊戲／SimHub、插件安裝、最多
  64 個遊戲設定檔、一鍵啟動、台灣中文結構化診斷、複製前遮罩 `%USERPROFILE%`、安全
  升級與解除安裝。設定檔只存路徑／偏好，不存秘密。
- 啟動前驗證精確套件 allowlist、必要 manifest 項目、逐檔 SHA-256、路徑邊界、
  reparse point、x86／x64 架構、已安裝插件雜湊與 SimHub pipe readiness；驗證後鎖定
  必要檔案直到操作完成，逾時狀態不明時停用後續變更。
- 獨立 SimHub PowerShell 安裝／解除安裝入口不再自行要求 UAC。它們會在 dot-source
  helper 前，以自包含 bootstrap 鎖定全包檔案並核對 exact manifest、SHA-256、reparse
  point 與 Authenticode 狀態；一般使用者預設導向 Manager，`-NoElevation` 只供不需
  管理員權限的受控測試目錄。
- 尚未啟用於公開發行的 Stable Manager 政策採 Authenticode fail-closed：執行中 Manager 與 manifest 內全部
  `.exe`、`.dll`、`.ps1`、`.psm1` 都要驗證；目前 allowlist 合計 11 個簽章 payload。
  它們必須全數通過 Windows 信任鏈及撤銷檢查、同 signer，並符合編譯時釘選的
  certificate SHA-256。封裝器另解析 raw PE，要求唯一、NUL 結尾且已釘選 signer 的
  `FFB_MANAGER_BUILD_POLICY_V1` marker 在簽章前後都重新解析，必須完整位於 `.rdata` 的
  raw size 與 mapped `VirtualSize`，具有 initialized-data／READ 且不得 WRITE／EXEC；
  raw padding、憑證表／overlay 假標記都會拒絕，最後核對 Manager Authenticode signer
  後才封裝。
- Proxy、Hook、Launcher 與 Manager 使用靜態 MSVC CRT，並以
  `/DEPENDENTLOADFLAG:0x800` 將 PE 靜態匯入的 DLL 搜尋限制到 System32；這不涵蓋任意
  動態載入。
- V1 兩條公開流程都固定為 Experimental；Full 收到 `stable` 會 fail-closed，而且兩條流程
  都完全不讀 Stable 簽章 secrets。Experimental 仍
  強制內層 SHA-256 manifest，並要求使用者從官方 Release 外部驗證 GitHub provenance
  attestation。Attestation 不是 Authenticode。
- 削峰模型改為 `ConservativeAbsoluteSumPerDevice`：同來源的 active Constant／Ramp／
  Periodic 效果以瞬時絕對值在同一裝置內保守加總，再取最忙的裝置；跨裝置與跨來源
  不相加。`AnyClipping` 是可靠來源間的 OR。這可能因方向抵消而高估，是命令上界，
  不是馬達扭力。
- 預設 98% 進入、連續 100 ms 或 1 秒視窗達 5% 觸發、低於 95% 持續 500 ms 解除。
  Condition／Custom 不猜值；TriggerButton 缺少即時按鍵狀態時標記
  `TriggerStateUnavailable` 並停用不可靠的 CLIP。
- 容量上限為 64 sources、每來源 64 devices／1,024 effects、32 pipe clients、64 KiB
  frame／8 axes，以及每來源 256 diagnostic transitions；資料缺口、session 重連或容量
  超限都公開 drop／reason 並 fail-closed，不用部分狀態繼續判定。每來源問題需新
  producer session；全域 source 超限後需重啟 SimHub／接收端的新 Core instance。
- SimHub 外掛只接受 9.11.22 exact-length-and-SHA256 SDK profile；四個輸入為
  `GameReaderCommon.dll` 388248 bytes、`log4net.dll` 270336 bytes、
  `SimHub.Logging.dll` 14488 bytes、`SimHub.Plugins.dll` 9472664 bytes，digest 必須與
  儲存庫 `simhub/sdk-compatibility.json` 完全相符。SimHub 自有 DLL 不會重新散布。
- x86／x64 E2E 使用專案 probe，實際走過
  Launcher → Hook → 系統 DirectInput8 → secure pipe → SimHub Core，且 fixture 目錄沒有
  `dinput8.dll`。這不是商業遊戲或實體方向盤測試。
- Coverage 閘門：native `/src/`＋`/launcher/` 至少 50%／900 tracked lines，SimHub Core
  至少 75%／500 tracked lines，Python pytest 85%；另有 CodeQL C++／C#／Python、
  dependency、完整歷史 secret、workflow 與 SPDX 稽核。
- Release 同時提供完整 component SBOM 與 Python environment SBOM，各有 CycloneDX 1.6
  與 SPDX 2.3。component SBOM 列出 8 個第一方元件、`uv.lock` 全部 registry Python
  元件／依賴，以及未重新散布的 SimHub SDK exact fingerprint。
- 發行 workflow 只從預設分支 `master` 接受 `repository_dispatch`，並精確驗證 event
  type 與 `client_payload`；push tag 本身不會自動發布。GitHub 已啟用 immutable releases，
  tag ruleset `21893944` 會禁止更新或刪除 `refs/tags/v*`。
- Full 即使恢復 private mutable draft，也要求 `github.sha`、checkout、當下
  `origin/master`、tag commit 與 build output 是同一 SHA；只有 Base Experimental 的草稿
  恢復可使用仍在 master 歷史中的 ancestor。
- Full 的 Low IL AppContainer self-hosted job 只有 `actions: read`、`checks: read`、
  `contents: read`，只建置並以 Actions artifact 移交精確 11 個資產。獨立
  `windows-latest` job 才有 `contents: write`、`id-token: write`、`attestations: write`，
  綁定 `stable-signing` environment 人工核准，只驗證下載資料、不執行建置產物。SimHub／
  Launcher ZIP 會再做 exact entry、路徑／型別、內層 SHA-256 與禁止 proprietary SDK／
  `dinput8.dll` 的純靜態檢查，最後才產生 provenance 並發布為 prerelease Experimental。
- Attestation 只記錄 publisher 收到與送出的 exact bytes；它不證明 self-hosted builder
  乾淨，也未把允許檔名下的 scripts、文件、Dashboard 或 PE 內容逐一與 trusted checkout
  比對。遭入侵 builder 仍可能產生 manifest 自洽但內容惡意的資產；此殘餘風險只限本版
  未簽章 Experimental，不能作為未來 Stable 的信任模型。

## 資產

每條發行路徑都會有：

- `ffb-interceptor-visualizer-{{TAG}}-source.zip`
- `ffb-proxy-x86.zip`
- `ffb-proxy-x64.zip`
- `ffb-viewer-x64.zip`
- `sbom.cdx.json`
- `sbom.spdx.json`
- `python-environment.cdx.json`
- `python-environment.spdx.json`
- `SHA256SUMS`

只有在 `[self-hosted, Windows, X64, simhub-sdk, ephemeral, ffb-release]` 的 read-only
AppContainer 建置 job 驗過真實 SDK 後，才會另外有：

- `FFBInterceptor-SimHub-{{VERSION}}.zip`
- `FFBInterceptor-Launcher-{{VERSION}}.zip`（一般使用首選）

SimHub build 的兩個 standalone `.simhubdash` 只存在於隔離暫存目錄；完整 workflow
只複製唯一 SimHub ZIP，並在 finally 清掉暫存目錄，因此不會把 `.simhubdash` 當成
獨立 Release asset。

不要因為檔名列在說明中，就假設頁面一定已附上完整套件。只有資產清單真的出現上述
兩個 ZIP，才表示完整 workflow 曾在 labels 相符的 runner 上完成；`ephemeral` label
本身不是主機退役或清理證明，仍須以維護者保留的註冊、退役與清理紀錄確認。
`stable-signing` environment 已限制只允許 `master`，reviewer 為 `xup61069`；V1 只把它
當作 hosted 發布 job 的人工核准邊界，該 job 不讀簽章 secrets。公開 Stable 尚未啟用；
未來必須另有不執行未信任建置程式的獨立簽章 job、公信 code-signing 憑證與實體測試。
目前 Full 資產一律是 Experimental，也不能用這份說明假裝已完成實體硬體／商業遊戲測試。

若本版由持續使用的 Windows 主機建置，則使用 Low IL AppContainer 內、只有 read 權的 GitHub
`--ephemeral` 單次 runner；runner runtime 採唯一、受保護的 C: 目錄，SimHub SDK 與
x64／x86 toolchain 環境快照為 job 不可寫，並在工作前以 native probe 驗證主機 gh token、
Credential Manager、SSH agent、使用者憑證與私人檔案無法從容器讀取。工作後會驗證 GitHub
退役並清除 AppContainer profile、runner／work 目錄。
這是邏輯清理，不等同一次性 VM 或磁碟安全抹除。GitHub provenance 證明 hosted publisher
收到並驗證後送出的 exact bytes 與 workflow／commit 身分，但不能證明 self-hosted 主機來自
全新映像、所有二進位可重現，或排除主機層污染；因此這類資產只會標示為未簽章
Experimental，不能視為 Stable 或 Authenticode 供應鏈保證。

## 驗證

1. 以 `SHA256SUMS` 核對下載檔。
2. 對每個資產執行：

   ```powershell
   gh attestation verify <下載檔> --repo xup61069/ffb-interceptor-visualizer
   ```

3. 本版是未簽章 Experimental，不能當成 Stable。未來若另行啟用 Stable，仍須以 Windows
   檔案內容或 `Get-AuthenticodeSignature` 確認有效 Authenticode。
4. Launcher ZIP 解壓後不要修改 `SHA256SUMS.txt` 或拆開搬移檔案；Manager 會拒絕
   缺漏、額外或遭修改的內容。

Release 腳本不會刪除或覆寫既有同名資產；內容不同就停止。重新執行只更新由
publisher 管理的單一產生區塊，並保留該區塊之外的人工說明；實際 marker 契約記錄在
`docs/release-process.md`，不在此 template 內嵌 marker，以免干擾下一次解析。

## 支援限制

只支援由 `DirectInput8Create` 建立的 x86／x64 DirectInput8；不支援 GameInput、WinRT、
XInput、私有 SDK、驅動／HID Hook、任意 PID／DLL 注入、反作弊規避或 iRacing。
Named Pipe 限制為本機目前使用者並核對 Hello PID，但同一使用者下的惡意程序不在完整
信任邊界。傳統 Proxy 模式仍供研究；絕對不要覆寫遊戲原有 `dinput8.dll`，務必先備份
並確認可還原。
