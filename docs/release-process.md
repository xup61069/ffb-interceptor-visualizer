# v1.0.0 發行流程

本專案有兩條公開發行路徑：GitHub-hosted 的「基礎 Experimental」，以及用真實 SimHub
SDK 在 self-hosted AppContainer 建置、再由 GitHub-hosted job 發布的「Full Experimental」。
兩者都只能針對既有 `vX.Y.Z` tag，且都會等待 tag 所在 exact commit 的必要 checks。
V1 公開流程一律未簽章；Full 的 `stable` 請求會 fail-closed，且完全不讀簽章 secrets。

## 共通先決條件

發行 tag 必須符合沒有 prerelease suffix 的 SemVer：`vX.Y.Z`。兩條 workflow 都只接受
GitHub `repository_dispatch`，因此 workflow 來源固定為預設分支 `master`；job 另要求
`github.ref == 'refs/heads/master'`，不接受呼叫端指定其他 ref。事件與 payload 必須精確
符合下列契約，多一個或少一個欄位都會停止：

- 基礎 Experimental：事件 `ffb-experimental-base-release`，`client_payload` 剛好是
  `{ "tag": "vX.Y.Z" }`；
- 完整發行：事件 `ffb-full-release`，`client_payload` 剛好包含 `tag`、`channel`、
  `simhub_path`；`channel` 只能是小寫 `experimental`，`stable` 會立即停止；
  `simhub_path` 必須是 Windows 本機磁碟的絕對路徑。

白話說，呼叫端只能交付這幾個資料欄位，不能指定要執行哪個分支版本的 workflow；
GitHub 一律使用 default branch 上已審查的流程內容。

job 一律先 checkout 受信任的 `master`，不會先 checkout payload 指定的 tag。基礎流程會把
release API、draft preflight、publisher、release-ref verifier 與 exact-check waiter 複製到
`$RUNNER_TEMP` 的每-job 唯一目錄；Full 的 self-hosted 建置 job 只 snapshot 唯讀 preflight／
驗證 controls，不含 publisher。Full publisher 只由通過人工核准的獨立 `windows-latest` job
從受信任來源另行 snapshot。第二次 checkout tag 後，每個 job 仍只執行各自從受信任 master
snapshot 的 control 副本。每個 control 的絕對路徑與 SHA-256 都由 named step output
傳遞，每次 dot-source 或執行前重新計算並比對；檔案遺失、hash 格式不正確或內容改變都會停止。
snapshot、preflight 與 tag 綁定結果也透過 named step output 傳遞，後續 step 以明確的 `env`
綁定，不沿用 tag source 可寫入的 `GITHUB_ENV`。Full 流程同樣把正規化後的 `simhub_path` 寫進
`validated-payload` step output，SDK fingerprint 與 package builders 都明確綁定該 output。
產品建置、測試與封裝才使用被驗證的 tag source。

`$RUNNER_TEMP` 目錄本身不是同一個 runner 使用者下的權限隔離邊界；重新驗 hash 能發現消費前的
內容變更，但無法把同一主機上的惡意背景程序變成安全沙箱。因此 tag source 的信任前提仍是：
它必須是已通過必要 checks 的受審查 `master` commit。只有 Base Experimental 的 draft
recovery 可使用仍在 master 歷史中的 ancestor；Full Experimental 即使恢復草稿，也必須綁定
當下 master HEAD。V1 沒有 Stable recovery，因為 `stable` payload 在建置前就會 fail-closed。

在綁定 tag 前，common release API 會列舉 Releases collection（不能用 draft 不可見的
`/releases/tags/<tag>` 當唯一真相），並 fail-closed 檢查 response、tag、boolean state、asset
名稱與唯一 numeric release ID。狀態只允許：

- **沒有既有 release**：tag 必須等於當下 master HEAD；
- **唯一、private、mutable draft**：記住 numeric release ID；Base Experimental 可接受仍在
  master 歷史中的 ancestor，Full Experimental 則仍要求 tag 等於當下 master HEAD；
- **已發布 release**：仍先套用 tag 必須等於 master HEAD 的嚴格策略，然後在 SDK、建置與
  publisher 前停止；不會把既有公開 release 當成 recovery 對象。

draft preflight 只接受本次預期資產集合的無重複子集；Base 明確使用 9 個基礎 asset 名稱，Full
明確使用 11 個完整 asset 名稱。任一重複 release、API/JSON/state failure、immutable draft、未知
asset 或 preflight 前後 numeric ID 改變都停止。後續 publisher 一律收到
`-ExpectedReleaseId`：無 release 時為 `0`，draft-recovery 時為同一個正 numeric ID；因此
preflight 後新出現的 release 不能被本次工作接手。publisher 會在 upload 前、upload 後與 final
read-back 重新驗證相同 ID；缺少資產只用 numeric release-ID 的 asset endpoint 上傳，metadata
也只用 numeric release-ID 最終化，不以 tag lookup 當 mutation target。

綁定步驟會先 fetch `origin/master` 與指定 tag、確認第一個 checkout 的 `HEAD` 等於
`origin/master`，再解析 annotated tag 到完整 40 位 commit SHA：

- 沒有 release 或已發布 release 時，tag commit 必須等於 `origin/master` HEAD；
- Base Experimental 的唯一 private mutable draft recovery 時，tag commit 可是
  `origin/master` 的 ancestor；Full Experimental 的 recovery 仍要求 tag commit 精確等於
  `origin/master` HEAD。Stable payload 不會進入這段流程。

第二次 checkout 該 tag SHA 後，才由受信任 master snapshot 的
`.github/scripts/verify-release-ref.ps1` 檢查：

- tag 真實存在，且 `HEAD` 與 tag 解析到相同的 40 位 commit SHA；
- Base 非 recovery 與所有 Full run（包含 draft recovery）都要求 tag、`HEAD`、事件的
  `github.sha` 與當下 `origin/master` HEAD 是同一個完整 40 位 commit SHA；
- `CMakeLists.txt`、`viewer/pyproject.toml`、viewer runtime `__version__`，以及所有具有
  `<Version>` 的 SimHub C# 專案，版本都等於去掉 `v` 的 tag。

綁定後 commit SHA 只透過 named step output 傳遞，接著第二次 checkout 該 tag SHA；
建置前與實際 publisher 呼叫前都會重新 fetch，核對 tag 與 checkout 仍等於這個 SHA，
而且該 SHA 仍存在於當下 `origin/master` 歷史。Base 非 recovery 與所有 Full run 從初次
綁定到最終發布都要求 tag 等於 master HEAD；期間 master 前進會安全停止該 run。只有 Base
draft recovery 從一開始可接受同一個 ancestor SHA。tag 被移動、綁定 commit 不再符合該路徑
的 master 關係，或事件不是從 default branch workflow 進入，都會 fail-closed。

第二次 checkout tag 後、執行任何 tag 來源的測試或封裝腳本前，workflow 會再以 trusted
master snapshot 查一次 release collection：原本不存在就必須仍不存在；draft recovery 則
必須仍是相同 numeric ID 的 private mutable draft，且資產仍是預期集合的子集。state 或 ID
在兩次檢查間改變都會停止，不會因舊 tag source 開始執行而放寬 release 狀態。

`.github/scripts/wait-required-checks.ps1` 不看分支上「最新一次」結果，而是用該完整
commit SHA 查詢下列 11 個 check run；每一個都必須存在、完成且為 `success`：

1. `proxy-x64`
2. `proxy-x86`
3. `simhub-core-net48`
4. `coverage-windows`
5. `viewer-py3.12`
6. `viewer-py3.13`
7. `codeql-cpp`
8. `codeql-csharp`
9. `codeql-python`
10. `dependency-audit`
11. `history-and-workflow-audit`

預設最多等待 1,200 秒、每 15 秒查詢。任一 check 失敗、取消、逾時或缺少都會停止
發行。`coverage-windows` 目前要求 native `/src/`＋`/launcher/manager_model.cpp` 的
產品程式碼 line coverage 至少 50% 且至少 900 tracked lines（兩個路徑都必須出現），
SimHub Core 至少 75% 且至少 500 tracked lines；viewer pytest 另由 `viewer-py*` job
執行 85% 門檻。原生 coverage
只量測可插樁的測試執行檔；正式 Launcher／Hook 的完整功能路徑由 `proxy-x64` 與
`proxy-x86` 在一次性標準使用者帳號下另外執行。測試只在執行期間把該帳號 SID 加入
目前 runner 的互動 window station／desktop ACL；整段作業以跨程序鎖序列化，還原前
確認 ACL 仍等於本次授權結果，若已被其他程序變更就拒絕覆寫。正常路徑會還原完整原始
ACL，再刪除帳號與 staging，避免把提權繞過混進產品或 coverage。IAT 測試同時覆蓋名稱匯入與
`dinput8.dll` ordinal 1，且保留「目前指標仍是 System32 原函式」的覆寫門檻。

## 路徑 A：GitHub-hosted 基礎 Experimental

工作流程：`.github/workflows/release.yml`（顯示名稱 `Experimental base release`）

只接受 `repository_dispatch` 事件 `ffb-experimental-base-release`。單純 push
`v*.*.*` tag 不會自動發布；維護者必須先決定該 tag 要走基礎 Experimental 或完整
self-hosted，再呼叫唯一一條 workflow。PowerShell 範例：

```powershell
@{
  event_type = 'ffb-experimental-base-release'
  client_payload = @{ tag = 'v1.0.0' }
} | ConvertTo-Json -Depth 3 | gh api --method POST `
  repos/xup61069/ffb-interceptor-visualizer/dispatches --input -
```

執行環境為 GitHub-hosted `windows-2022`，不具有 proprietary SimHub SDK。流程依序：

1. checkout 受信任 master、完整抓取 history、snapshot 到 `$RUNNER_TEMP` 的 release-control scripts，
   且不保留 checkout credential。
2. 以 Base 的 9 個預期 asset 做唯讀 release preflight。僅唯一 private mutable draft 可進 recovery；
   它的 numeric release ID 會被釘選。無 release 或已發布 release 則維持 tag 必須等於 master HEAD。
3. 把 tag 綁到上述合法狀態所允許的 master HEAD／ancestor 與所有專案版本，再 checkout 綁定的 tag SHA；
   已發布 state 在此嚴格綁定完成後即停止，絕不執行 publisher。
4. 等待上述 exact-commit checks。
5. 另在發行 job 內重跑 pinned gitleaks `v8.30.1` 的完整歷史掃描與 SPDX header audit；
   任何 finding 都在建置或上傳前停止。
6. 使用 Python 3.13、uv 0.12.5 執行 `.github/scripts/package-release.ps1`，建立固定未
   簽章的 Experimental 基礎資產。這條 workflow 完全不引用 Stable 簽章 secrets，
   不會因環境中恰好有憑證就改成已簽章版本。
7. 對 `release/*` 每個檔案產生 GitHub build-provenance attestation。
8. 由 trusted publisher 以 prerelease、`未簽章實驗版` 標題和 Experimental notice 發布不可覆寫
   資產；若是 recovery，必須使用 preflight 釘選的同一 numeric draft ID。

基礎資產為：

- `ffb-proxy-x86.zip`、`ffb-proxy-x64.zip`；
- `ffb-viewer-x64.zip`；
- `ffb-interceptor-visualizer-v1.0.0-source.zip`（其他版本依 tag 更換版本段）；
- `sbom.cdx.json`（CycloneDX 1.6 component SBOM）；
- `sbom.spdx.json`（SPDX 2.3 component SBOM）；
- `python-environment.cdx.json`；
- `python-environment.spdx.json`；
- `SHA256SUMS`。

component SBOM 會從共同版本、8 個第一方元件、`uv.lock` 全部 registry Python 元件與
dependency graph，以及 SimHub SDK build-time-only exact fingerprint 產生；SDK 標記為
未重新散布。Python environment SBOM 則從 `uv sync --locked --extra dev` 的實際環境
產生 CycloneDX／SPDX 描述。Viewer 會先以 offscreen 模式做 packaged smoke；若啟動後
立即退出便停止封裝。

這條路徑不會產生 SimHub 外掛 ZIP、Launcher／Hook ZIP 或 Manager。Release 若只有
這些基礎資產，就不是「下載、解壓、雙擊 Manager」版本。

## 路徑 B：Full Experimental（self-hosted 建置＋hosted 發布）

工作流程：`.github/workflows/simhub-sdk-release.yml`（顯示名稱 `Full SimHub release`）

正式建立不可移動的 tag 前，先以 `.github/workflows/simhub-runner-preflight.yml` 對專用的
`[self-hosted, Windows, X64, simhub-sdk, ephemeral, ffb-preflight]` labels 跑一次不含 secrets、
只有 `contents: read` 的完整本機建置／封裝預檢。
payload 只接受預期的 master 40 位 commit SHA 與隔離 SimHub SDK 路徑；預檢會驗證
master 綁定、SDK 指紋、uv-managed Python、x86／x64 全部測試，以及 SimHub／Launcher
套件，但不建立 tag、attestation 或 Release。預檢 runner 完成一個 job 後必須退役；
正式建置另用全新 profile 與全新 `--ephemeral` runner，不能重用預檢工作目錄。具 Release
寫入與 OIDC 權限的 attestation／發布則改在獨立的 GitHub-hosted Windows job 執行。

預檢 dispatch 的 payload 必須剛好包含凍結的 master SHA 與私有 SDK snapshot：

```powershell
@{
  event_type = 'ffb-full-runner-preflight'
  client_payload = @{
    commit = '<40 位小寫 master SHA>'
    simhub_path = '<隔離 profile 內的 SimHub SDK snapshot 絕對路徑>'
  }
} | ConvertTo-Json -Depth 3 | gh api --method POST `
  repos/xup61069/ffb-interceptor-visualizer/dispatches --input -
```

預檢通過後必須凍結 master；推 tag 前再次確認 `origin/master` 仍等於預檢 SHA。正式發行
runner 另加 `ffb-release` label，不能帶 `ffb-preflight`，避免兩種 queued job 互搶。

只接受 `repository_dispatch` 事件 `ffb-full-release`。payload 必須剛好包含：

- `tag`：既有且位於 master 的 canonical `vX.Y.Z` tag；
- `channel`：V1 Full workflow 只接受小寫 `experimental`；`stable` 目前 fail-closed 停止；
- `simhub_path`：一次性 runner runtime 內、job 只有讀取權的 SimHub SDK 四檔 snapshot
  Windows 本機磁碟絕對路徑；不可直接指向持續使用主機的 SimHub 安裝目錄。

PowerShell 範例：

```powershell
@{
  event_type = 'ffb-full-release'
  client_payload = @{
    tag = 'v1.0.0'
    channel = 'experimental'
    simhub_path = 'C:\ffb-v1-<32-hex>\Sdk'
  }
} | ConvertTo-Json -Depth 3 | gh api --method POST `
  repos/xup61069/ffb-interceptor-visualizer/dispatches --input -
```

建置 job 沒有 environment、Release 寫入或 OIDC 權限，只會排到精確 labels：

```yaml
runs-on: [self-hosted, Windows, X64, simhub-sdk, ephemeral, ffb-release]
```

流程依序：

1. self-hosted 建置 job checkout 受信任 master，先以唯讀 GitHub 權限確認事件的
   `github.sha`、初始 checkout、當下 `origin/master` 與 tag commit 是同一個 40 位 SHA，
   再確認 release slot 與該 exact commit 的 11 個必要 checks。即使是 draft recovery 也不接受
   ancestor；綁定 SHA 會成為 build job output，供 hosted 發布 job 複驗。
   唯一 private mutable draft 只能含本次 11 個預期 asset 的無重複子集，並釘選 numeric ID；
   已發布、immutable、未知檔名或 state／ID 改變都 fail-closed。
2. 執行 `simhub/tools/Test-SimHubSdk.ps1`。v1.0.0 只接受
   `simhub/sdk-compatibility.json` 中 SimHub 9.11.22 的四檔 exact length＋SHA-256；
   少檔、長度不同或 digest 不同都停止。SimHub 自有 DLL 不會進入套件。
3. 以鎖版 `setup-uv` 將 uv-managed Python 3.13.15 安裝到 runner 暫存區，不使用 Windows
   self-hosted 首次安裝時需要管理員權限的 `setup-python`。可信 host preflight 先從固定的
   Visual Studio 2022 Build Tools 為 x64、x86 各產生一份不含秘密的環境 `.cmd` snapshot；
   兩檔在 AppContainer 內唯讀，workflow 逐次驗 SHA-256 且拒絕 reparse point，不在容器內
   依賴看不到 host registry 的 `vswhere` 或會切換到 Program Files cwd 的 `VsDevCmd.bat`。
   兩個 snapshot、`simhub_path`、runner temp 與 workspace 必須綁定同一個
   `C:\ffb-v1-<32-hex>` 一次性 runtime，且 snapshot 內的 host／target 架構不得重複或互換。
   再對 x64、x86 各自執行
   `cmake --build ... --target all`
   與完整 CTest；V1 固定 `FFB_STABLE_PACKAGE=OFF` 且不引用任何 signing secret。
4. 建立基礎資產。封裝器先要求目前 `HEAD` 等於步驟 1 綁定的完整 40 位 commit；source ZIP
   直接使用該 commit object，而不是可變的 tag 名稱，並在封裝前後重新驗證 HEAD 與 tag
   仍指向同一 commit。SimHub builder 在 `RUNNER_TEMP` 下的唯一隔離目錄執行，必須恰好
   產生一個 `FFBInterceptor-SimHub-1.0.0.zip` 才複製到 `release/`，finally 一律刪除
   隔離目錄；兩個 standalone `.simhubdash` 不會成為 Release asset。接著建立含 x86／
   x64 Launcher／Hook、x64 Manager、Core、SimHub adapter、Dashboard／Overlay 的
   `FFBInterceptor-Launcher-1.0.0.zip`。最後重算涵蓋除 checksum 檔自身之外所有外層
   資產的 `SHA256SUMS`。
5. 建置 job 用鎖定 commit 的 `actions/upload-artifact` 只移交精確 11 個 Release 資產；它只有
   `actions: read`、`checks: read`、`contents: read`，沒有
   `contents: write`、`id-token: write` 或 `attestations: write`。即使建置程式留下同 SID
   背景程序，也拿不到後續 Release／OIDC 權限。
6. 獨立 `windows-latest` 發布 job 才有 `contents: write`、`id-token: write`、
   `attestations: write`，並綁定 `stable-signing` 人工核准環境。它下載資料後不執行
   任何建置產物；它先驗精確檔名、reparse、`SHA256SUMS` 全覆蓋與逐檔 digest。SimHub 與
   Launcher ZIP 另以純靜態方式驗 exact entry allowlist、大小、case-insensitive duplicate、
   traversal／ADS／特殊檔案型別、內層 manifest 全覆蓋與逐檔 SHA-256；兩者都不得含
   `dinput8.dll`，也不得夾帶 SimHub 的四個 proprietary SDK DLL。
7. 發布 job 再確認 build output SHA、自己的 checkout、當下 `origin/master` 與 tag commit
   完全相同，並複驗 11 個 checks 與原先釘選的 release slot／numeric ID，才對 `release/*`
   產生 provenance attestation，並以 prerelease 與「未簽章」警示發布。

目前 Full workflow 明確拒絕 `stable`，也完全沒有 signing secret 引用。`stable-signing`
在 V1 只作為 hosted 發布 job 的人工核准環境，名稱不代表正在簽章。程式庫仍保留
Stable Manager／簽章封裝的 fail-closed 實作與測試，但要公開 Stable，必須先新增獨立、
不執行未信任建置程式的簽章 job，取得公信憑證並完成實體測試；不得把本版改標 Stable。

MSVC 原生目標使用靜態 CRT，Proxy、Hook、Launcher 與 Manager 另以
`/DEPENDENTLOADFLAG:0x800` 限制 PE 靜態匯入的 DLL 搜尋到 System32。CI 會以 `dumpbin`
同時拒絕動態 MSVC runtime imports 並確認 `Dependent Load Flag`；這個閘門不涵蓋任意
動態 `LoadLibrary` 路徑。

### GitHub 已設定與仍缺少的外部條件

截至 2026-09-03，GitHub 儲存庫端已完成：

- 啟用 immutable releases；
- 啟用 tag ruleset `21893944`，保護 `refs/tags/v*`，禁止更新與刪除；
- 建立 `stable-signing` environment，只允許 `master` 部署，必要 reviewer 為
  `xup61069`。

目前 Full Experimental 的外部執行條件：

- Full job 只使用發版前臨時註冊、labels 完全相符，且工作完成後立即退役並清除工作目錄
  的 ephemeral self-hosted Windows x64 runner；持續使用主機上的 Experimental runner
  必須在 Low IL AppContainer 內，runtime 使用受保護的唯一 C: 目錄，並在註冊前以 native
  fail-closed probe 驗證 Windows Credential Manager、SSH agent、CurrentUser 憑證、私人
  gh 設定與檔案隔離。SDK 四檔與 x64／x86 toolchain snapshots 必須 job 唯讀且 SHA-256
  綁定。`ephemeral` label 本身不是銷毀證明，維護者仍須保留註冊、退役與清理證據；

未來公開 Stable 仍缺少公信 Windows code-signing 憑證與對應金鑰管理、獨立且不執行未信任
建置程式的簽章 job，以及實體方向盤／商業遊戲測試台。這些是未啟用的未來條件，不是目前
Full Experimental self-hosted job 的輸入。

`repository_dispatch` 固定使用 default branch workflow，再加上
`if: github.ref == 'refs/heads/master'` 與精確 payload 驗證，構成 workflow 內的入口 gate；
目前 `stable-signing` environment 的 deployment branch policy 與 reviewer 是獨立
`windows-latest` 發布 job 的人工核准邊界；該 job 具有 Release／OIDC／attestation 權限，
但不讀 signing secrets，也不執行下載的建置產物。Full Experimental 的 self-hosted job
可使用持續存在的 Windows 主機，但必須使用上述
已驗證的 AppContainer credential／filesystem boundary；runner 仍須以
`config.cmd --ephemeral` 做單次註冊。工作後須驗證 GitHub 已退役 runner，清除唯一
AppContainer profile 與 runner／work 目錄，且 Release 說明必須揭露這只是
邏輯清理，不等同一次性 VM 或安全抹除。V1 公開 workflow 不會把 PFX 匯入 self-hosted
runner；任何未來 Stable 設計都必須另外界定金鑰隔離與一次性執行環境，不能沿用目前
執行未信任建置碼的 job 作為簽章邊界。

Hosted attestation 證明的是該發布 job 收到並驗證後送出的 exact bytes，以及其 workflow／
commit 身分；它不證明 self-hosted 主機乾淨、所有二進位可重現，或 Proxy／Viewer／SBOM
內容已由 hosted runner 獨立重建。靜態 ZIP gate 也不會把允許檔名下的 scripts、文件、
Dashboard 或 PE 內容逐一和 trusted checkout 做同源比對；若 builder 遭入侵，仍可產生
內層 manifest 自洽但內容惡意的資產。這項殘餘風險只在未簽章 Experimental 明示接受，
不能沿用為未來 Stable 的供應鏈保證。

沒有第一項 runner／SDK 時，新的 Full job 不會執行，只能產生 hosted Experimental 基礎
資產；現行 Full 一律標示 Experimental，不能稱為 Stable。發行說明
不可捏造 runner、退役清理、簽章或硬體測試已完成。

immutable-releases 設定屬於 repository Administration 權限，workflow 內建的
`GITHUB_TOKEN` 無法要求這個額外權限。維護者必須在送出 dispatch 前，用具有該儲存庫
Administration read 的管理 token 做最後一次唯讀檢查：

```powershell
$policy = gh api `
  -H 'Accept: application/vnd.github+json' `
  -H 'X-GitHub-Api-Version: 2026-03-10' `
  repos/xup61069/ffb-interceptor-visualizer/immutable-releases |
  ConvertFrom-Json -ErrorAction Stop
if ($policy.enabled -ne $true) { throw 'Immutable releases is not enabled.' }
```

GitHub [GA changelog](https://github.blog/changelog/2025-10-28-immutable-releases-are-now-generally-available/)
說明：啟用後的新 Release 會 immutable，既有 Release 則維持 mutable，
除非重新發布。這套 publisher 不會重新發布或修改任何 public Release；而 API 也沒有欄位可在
private draft 公開前預測其 eligibility。為避免只能在公開後才發現問題，本專案採用更保守的
營運 gate：若本次是既有 draft recovery，維護者必須取得可稽核、時間早於該 draft `created_at` 的
`enabled=true` 證據，例如保留時間戳的先前 API observation、適用的組織 audit log，或 GitHub
Support 確認。此 endpoint 沒有啟用時間欄位，所以「現在是 enabled」本身不足以證明舊 draft
符合資格；無法證明時必須停止，不可先公開再試。新 release slot 則因上述檢查發生在 workflow
建立 draft 之前，自然滿足這個時間順序。

publisher 在公開後仍會以同一 numeric ID 讀回，只有 `draft=false`、頻道 metadata、全部資產與
`immutable=true` 同時符合才回報成功；但這是發布後偵測，不能撤回已經公開的 mutable Release。
管理者若在最後檢查與公開之間關閉政策，run 會在 final read-back 失敗；GitHub 沒有提供可把
「確認政策」與「發布草稿」合併成單一原子操作的 Actions 權限。

## 每個 tag 發布前只能選一個資產發布者

兩條 workflow 都只能由維護者發出各自的 `repository_dispatch` 事件，且共用
`release-<tag>` concurrency group；同一 tag 的兩個 job 不會同時上傳。然而 concurrency
只負責序列化，不會把基礎 Experimental 轉成完整 Stable。維護者在 dispatch 前仍必須
明確選定唯一 publisher。

完整 workflow 也會產生同名的 Proxy、Viewer、source、SBOM 與 `SHA256SUMS`，完整 checksum
另涵蓋 SimHub／Launcher 資產。因此，Full Experimental recovery 只允許與當下 master HEAD
同一 tag commit 的唯一、未公開、mutable private draft，且現有資產是本次完整預期集合的
無重複子集。任何已公開 Release
都不會進 recovery，既有 Experimental draft／public Release 也不可能被 Full workflow
轉成 Stable。V1 沒有 Stable recovery；`stable` dispatch 會在執行建置前 fail-closed。
若未來另行啟用 Stable，必須以新 SemVer tag、全新 release slot 與獨立安全簽章流程發布。
不要刪除、替換或覆寫既有資產來強行轉換 channel。基礎 Experimental 仍可透過
`ffb-experimental-base-release` 事件指定 tag 發布。

## 不可變資產政策

`.github/scripts/publish-release-assets.ps1` 對 1～64 個安全檔名的非空資產執行：

- 在任何遠端 mutation 前，先要求本機 `release/` 的檔名與數量精確等於 workflow 傳入的
  `ExpectedAssetNames`：Base 9 項、Full 11 項；少檔、多檔、重複、空檔或非預期名稱都停止。
- 若 Release 沒有同名資產，只上傳缺少者。
- 若已有同名資產，先比大小；GitHub 有 `sha256:` digest 時再比 digest。
- 若遠端沒有 digest，下載該資產並比本機 SHA-256。
- 若遠端包含本次本機集合未列出的資產，立即失敗，避免把未知檔案帶入最後狀態。
- 任一既有資產不同便失敗；腳本不使用 `--clobber`、不刪除、不覆寫。
- 既有資產同內容時跳過，可安全恢復只缺部分資產的上傳。

這是發行腳本的 immutable-assets 政策，不表示 GitHub tag 本身具有密碼學不可變性。
workflow 會在發布前重驗 tag 未移動；GitHub release immutability 已於 2026-08-31
啟用，tag ruleset `21893944` 也禁止更新或刪除 `refs/tags/v*`。維護者仍須保護 repository
管理權限，並確認發行確實已進入 immutable 狀態。

### Metadata-last 發布順序與失敗狀態

這套流程是 metadata-last 的 fail-safe 發布順序，不是可回滾的完整 transaction：

- recovery draft 先以 release collection 的唯一 numeric ID 釘選，再驗證全部既有資產、
  用 `POST /repos/{owner}/{repo}/releases/{id}/assets` 上傳缺少項目，重新以同一 ID 查詢並驗證
  最終集合；只有全部成功後，才用唯一一次 `PATCH /repos/{owner}/{repo}/releases/{id}` 更新
  title、body、prerelease 與發布狀態。
- 新 Release 先以 private draft 建立。只有資產上傳與 read-back 驗證全部成功，才將
  draft 發布；在此之前不會公開成錯誤頻道。
- 同名不同內容、非預期資產、numeric ID 改變或複驗失敗都發生在 metadata edit 前，因此
  public Release 不會被 mutation，draft 也不會被提前公開；新 Release 則通常保留為 draft。
- GitHub 的多檔 upload 不是原子操作；上傳中途失敗可能留下部分已上傳資產，腳本不會
  rollback、delete 或 clobber；private draft 可能保留部分資產，但既有公開 Release 不會
  被 recovery publisher 修改。網路中斷時，最後一次 API 操作的遠端結果仍可能需要人工確認。

## Release notes marker 行為

`.github/release-notes.md` 是唯一產生內容的 template，publisher 會替換 `{{TAG}}`、
去掉前置 `v` 的 `{{VERSION}}` 與 `{{CHANNEL_NOTICE}}`，再包在：

```text
<!-- ffb-generated:start -->
...
<!-- ffb-generated:end -->
```

- 新 Release 只有一個 generated block。
- 既有 body 若沒有 marker，保留原文並在後面附加 generated block。
- 已有一組 marker 時只替換該區塊，marker 外的人工說明保留。
- 偵測到兩組以上 marker 立即失敗，避免不確定地改錯段落。

只有 Release 仍是 private mutable draft 時，finalization 才會更新 metadata
（title／body／prerelease flag），資產仍遵守不可覆寫政策；修改 notes template 後重跑不會抹掉
marker 外的維護者備註。Release 一旦公開且 immutable，只接受內容完全相同的 idempotent 重跑；
任何 metadata 或資產差異都會停止，不會修改公開 Release。

## 本機重現與發行前稽核

從乾淨 clone 重現基礎封裝：

```powershell
git checkout v1.0.0
$env:RELEASE_TAG = 'v1.0.0'
.github\scripts\verify-release-ref.ps1
.github\scripts\package-release.ps1
```

這只重現本機基礎資產，不會自行產生 GitHub attestation，也不會變成公開 Stable；V1 公開
workflow 不讀 PFX 或其他簽章 secrets。完整套件另需：

```powershell
pwsh -File simhub\tools\Test-SimHubSdk.ps1 -SimHubInstallPath 'C:\Program Files (x86)\SimHub'
pwsh -File simhub\tools\Build-SimHubPackage.ps1
pwsh -File simhub\tools\Build-LauncherPackage.ps1
simhub\tools\Test-SimHubPackage.ps1 -PackagePath <SimHub-ZIP>
simhub\tools\Test-LauncherPackage.ps1 -PackagePath <Launcher-ZIP>
```

Launcher package tester 使用專案自有 fake-SimHub fixture，驗證 ZIP allowlist、無
`dinput8.dll`、manifest 完整覆蓋、腳本語法、x86／x64 validation，以及在 SimHub 關閉
時的安裝、重裝、不同版本拒絕、tamper 拒絕與解除安裝還原。這些 fixture 不等於真實
SimHub、商業遊戲或方向盤硬體測試。

公開前最後確認：

- tag、exact commit 與所有版本一致；
- 使用正確的 `repository_dispatch` event type 與精確 `client_payload`，workflow 來源為
  default branch `master`。新 release slot 與已發布 state 要求 tag 等於當下 master HEAD；
  Full 的 `channel` 必須是 `experimental`，且包含 draft recovery 在內都要求 `github.sha`、
  checkout、當下 `origin/master`、tag commit 與 build output 是同一 SHA。只有 Base
  Experimental draft recovery 可使用 master ancestor，而且必須對應同一個 unique mutable
  draft numeric ID；
- 11 個必要 checks 都屬於該 exact commit；
- 在 dispatch 前選定唯一 publisher；完整流程的遠端 asset preflight 必須通過；
- 頻道是未簽章 Experimental；公開 workflow 未讀取 PFX 或其他 signing secrets；
- 完整資產只在 SDK exact fingerprint 通過後出現；
- 本機 release set 精確為 Base 9 項或 Full 11 項，沒有額外檔案；四份 SBOM、`SHA256SUMS`
  與所有預期資產都存在且非空；
- provenance attestation 已由獨立 `windows-latest` 發布 job 產生，該 job 只驗證資料而不執行
  self-hosted 建置產物；
- 維護者已用上面的 Administration-read API 在 dispatch 前確認 immutable releases 啟用；
  既有 draft recovery 另有早於 draft `created_at` 的啟用證據，且已納入發行稽核紀錄；
  publisher 的 final read-back 也必須看到新 Release `immutable=true`；tag ruleset
  `21893944` 保護 `refs/tags/v*`；Full 的 hosted 發布 job 綁定 `stable-signing` environment，
  只允許 master、reviewer 是 `xup61069`；self-hosted AppContainer 建置 job 只有 read 權，
  並確實使用工作後退役清理的 `ephemeral` runner；label 本身不是銷毀生命週期的證明；
- Release notes 明確保留「命令遙測、非馬達扭力」、支援限制與高扭力警告；
- 沒有宣稱尚未執行的 runner、憑證、商業遊戲或實體硬體測試。
