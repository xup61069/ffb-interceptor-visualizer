# v0.3.0 發行流程

本專案有兩條公開發行路徑：GitHub-hosted 的「基礎 Experimental」與具有真實 SimHub
SDK 的「完整 self-hosted」。兩者都只能針對既有 `vX.Y.Z` tag，且都會等待 tag 所在
exact commit 的必要 checks；差別在能否建置 SimHub／Manager 套件，以及 Stable 是否
啟用 Authenticode fail-closed。

## 共通先決條件

發行 tag 必須符合沒有 prerelease suffix 的 SemVer：`vX.Y.Z`。兩條 workflow 都只接受
GitHub `repository_dispatch`，因此 workflow 來源固定為預設分支 `master`；job 另要求
`github.ref == 'refs/heads/master'`，不接受呼叫端指定其他 ref。事件與 payload 必須精確
符合下列契約，多一個或少一個欄位都會停止：

- 基礎 Experimental：事件 `ffb-experimental-base-release`，`client_payload` 剛好是
  `{ "tag": "vX.Y.Z" }`；
- 完整發行：事件 `ffb-full-release`，`client_payload` 剛好包含 `tag`、`channel`、
  `simhub_path`；`channel` 只能是小寫 `experimental` 或 `stable`，`simhub_path` 必須是
  Windows 本機磁碟的絕對路徑。

白話說，呼叫端只能交付這幾個資料欄位，不能指定要執行哪個分支版本的 workflow；
GitHub 一律使用 default branch 上已審查的流程內容。

job 先 checkout 受信任的 master，重新 fetch 遠端 master 與指定 tag，再由 master 版本的
`.github/scripts/verify-release-ref.ps1` 檢查：

- tag 真實存在，且 `HEAD` 與 tag 解析到相同的 40 位 commit SHA；
- tag、`HEAD` 與當下 `origin/master` HEAD 是同一個完整 40 位 commit SHA；
- `CMakeLists.txt`、`viewer/pyproject.toml`、viewer runtime `__version__`，以及所有具有
  `<Version>` 的 SimHub C# 專案，版本都等於去掉 `v` 的 tag。

驗證後 commit SHA 會寫入 step output／`FFB_RELEASE_COMMIT`，接著只 checkout 該 SHA；
建置前與實際 publisher 呼叫前都會重新 fetch，核對 tag 與 checkout 仍等於這個 SHA，
而且該 SHA 仍存在於當下 `origin/master` 歷史。正常的新 commit 進入 master 不會破壞
已綁定工作；tag 被移動、綁定 commit 不再屬於 master，或事件不是從 default branch
workflow 進入，都會 fail-closed。

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
`proxy-x86` 在一次性標準使用者帳號下另外執行，避免把提權繞過混進產品或 coverage。

## 路徑 A：GitHub-hosted 基礎 Experimental

工作流程：`.github/workflows/release.yml`（顯示名稱 `Experimental base release`）

只接受 `repository_dispatch` 事件 `ffb-experimental-base-release`。單純 push
`v*.*.*` tag 不會自動發布；維護者必須先決定該 tag 要走基礎 Experimental 或完整
self-hosted，再呼叫唯一一條 workflow。PowerShell 範例：

```powershell
@{
  event_type = 'ffb-experimental-base-release'
  client_payload = @{ tag = 'v0.3.0' }
} | ConvertTo-Json -Depth 3 | gh api --method POST `
  repos/xup61069/ffb-interceptor-visualizer/dispatches --input -
```

執行環境為 GitHub-hosted `windows-2022`，不具有 proprietary SimHub SDK。流程依序：

1. checkout 受信任 master，完整抓取 history，且不保留 checkout credential。
2. 把 tag 精確綁到當下 master HEAD 與所有專案版本，再 checkout 綁定的 commit SHA。
3. 等待上述 exact-commit checks。
4. 另在發行 job 內重跑 pinned gitleaks `v8.30.1` 的完整歷史掃描與 SPDX header audit；
   任何 finding 都在建置或上傳前停止。
5. 使用 Python 3.13、uv 0.12.5 執行 `.github/scripts/package-release.ps1`，建立固定未
   簽章的 Experimental 基礎資產。這條 workflow 完全不引用 Stable 簽章 secrets，
   不會因環境中恰好有憑證就改成已簽章版本。
6. 對 `release/*` 每個檔案產生 GitHub build-provenance attestation。
7. 以 prerelease、`未簽章實驗版` 標題和 Experimental notice 發布不可覆寫資產。

基礎資產為：

- `ffb-proxy-x86.zip`、`ffb-proxy-x64.zip`；
- `ffb-viewer-x64.zip`；
- `ffb-interceptor-visualizer-v0.3.0-source.zip`（其他版本依 tag 更換版本段）；
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

## 路徑 B：完整 self-hosted SimHub 發行

工作流程：`.github/workflows/simhub-sdk-release.yml`（顯示名稱 `Full SimHub release`）

只接受 `repository_dispatch` 事件 `ffb-full-release`。payload 必須剛好包含：

- `tag`：既有且位於 master 的 canonical `vX.Y.Z` tag；
- `channel`：小寫 `experimental` 或 `stable`；
- `simhub_path`：runner 上已安裝 SimHub 的 Windows 本機磁碟絕對路徑。

PowerShell 範例：

```powershell
@{
  event_type = 'ffb-full-release'
  client_payload = @{
    tag = 'v0.3.0'
    channel = 'experimental'
    simhub_path = 'C:\Program Files (x86)\SimHub'
  }
} | ConvertTo-Json -Depth 3 | gh api --method POST `
  repos/xup61069/ffb-interceptor-visualizer/dispatches --input -
```

job 綁定 `stable-signing` environment，且只會排到精確 labels：

```yaml
runs-on: [self-hosted, Windows, X64, simhub-sdk, ephemeral]
```

流程依序：

1. checkout 受信任 master，將 tag 綁定到當下 master HEAD，checkout 該 SHA、重驗版本，
   並等待同一 exact commit 的 11 個 checks。
2. 對 GitHub Releases API 執行唯讀 preflight。Release 不存在時，必須再確認 repository
   API 可正常存取，才把該 404 視為「尚未建立」。若上次中斷留下 private draft，資產
   名稱必須無重複，而且只能是本次 11 個預期資產的子集，才允許 publisher 逐檔核對
   size／SHA-256 後續傳；任何已公開 Release（即使零資產）、未知檔名、重複檔名或 API
   錯誤，都會在 SDK／編譯／簽章前停止，且不刪除或修改遠端內容。
3. 執行 `simhub/tools/Test-SimHubSdk.ps1`。v0.3.0 只接受
   `simhub/sdk-compatibility.json` 中 SimHub 9.11.22 的四檔 exact length＋SHA-256；
   少檔、長度不同或 digest 不同都停止。SimHub 自有 DLL 不會進入套件。
4. 只有 `stable` channel 才讀取 `WINDOWS_SIGNING_PFX_BASE64`、密碼與
   `WINDOWS_SIGNER_SHA256`。pin 必須是精確 64 位 uppercase hex；PFX 必須在 Ephemeral
   store 預檢為恰好一個 private-key identity，該 identity 必須有 code-signing EKU、
   在有效期內，且 leaf certificate DER 的 SHA-256 完全符合釘選值。PFX 內每張憑證的
   thumbprint 都會被追蹤；若 `CurrentUser\My` 已存在其中任一張就停止，避免沿用前次
   中斷的身分。`experimental` channel 固定未簽章，完全不引用這三個 secrets。
5. 以 Visual Studio C++ tools 對 x64、x86 各自執行 `cmake --build ... --target all`
   與完整 CTest。Stable 加入 `FFB_STABLE_PACKAGE=ON` 與
   `FFB_EXPECTED_SIGNER_SHA256=<64 hex>`；Experimental 則為 OFF。
6. 建立基礎資產。SimHub builder 在 `RUNNER_TEMP` 下的唯一隔離目錄執行，必須恰好
   產生一個 `FFBInterceptor-SimHub-0.3.0.zip` 才複製到 `release/`，finally 一律刪除
   隔離目錄；兩個 standalone `.simhubdash` 不會成為 Release asset。接著建立含 x86／
   x64 Launcher／Hook、x64 Manager、Core、SimHub adapter、Dashboard／Overlay 的
   `FFBInterceptor-Launcher-0.3.0.zip`。最後重算涵蓋除 checksum 檔自身之外所有外層
   資產的 `SHA256SUMS`。
7. Stable 以 SHA-256 Authenticode 加 RFC 3161 timestamp 簽署 Proxy、Viewer、
   Manager、4 個 PowerShell 腳本、兩種架構 Launcher／Hook、Core／SimHub adapter；
   任一簽署或 `signtool verify /pa /all` 失敗就停止。Launcher 內部 manifest 在所有
   簽章完成後才產生。
8. 對完整 `release/*` 產生 provenance attestation，發布前再次確認 tag 未移動、綁定
   SHA 仍在 master 歷史且 checkout 沒有偏離。Stable 不標 prerelease；Experimental
   標為 prerelease 並明示「未簽章」。Stable 在一般失敗路徑與 `always()` cleanup 都會
   逐一核對本次追蹤的 thumbprint，再以 `Remove-Item -DeleteKey` 移除所有已匯入憑證。

Stable Manager 每次安裝與啟動都會重新驗證執行中 Manager 與 manifest 內全部
`.exe`、`.dll`、`.ps1`、`.psm1`；目前 allowlist 因而是 11 個簽章 payload。
Windows Authenticode 信任鏈、整條鏈撤銷狀態、
同一 leaf signer，以及建置時釘選的 certificate SHA-256 必須全數通過，否則
fail-closed。Experimental Manager 仍強制精確檔案清單與 SHA-256，但 Authenticode
不是啟動門檻，使用者必須外部驗證 attestation。

Stable Manager 會內嵌唯一、NUL 結尾且含 64 位 uppercase signer SHA-256 的
`FFB_MANAGER_BUILD_POLICY_V1` marker。`Build-LauncherPackage.ps1 -RequireSigning`
會在簽章前後重新解析 raw PE，要求 marker 完整位於 `.rdata` 的 raw size 與 mapped
`VirtualSize` 範圍，且區段具有 initialized-data／READ、不得 WRITE／EXEC；raw padding、
憑證表／overlay 假標記都會拒絕。完成最終 bytes 重驗後再確認 Manager 的 Authenticode
leaf certificate SHA-256 相符。未釘選、重複、格式錯誤、區段錯誤或 signer 不合，都會
在 manifest 建立前停止。

MSVC 原生目標使用靜態 CRT，Proxy、Hook、Launcher 與 Manager 另以
`/DEPENDENTLOADFLAG:0x800` 限制 PE 靜態匯入的 DLL 搜尋到 System32。CI 會以 `dumpbin`
同時拒絕動態 MSVC runtime imports 並確認 `Dependent Load Flag`；這個閘門不涵蓋任意
動態 `LoadLibrary` 路徑。

### GitHub 已設定與仍缺少的外部條件

截至 2026-08-31，GitHub 儲存庫端已完成：

- 啟用 immutable releases；
- 啟用 tag ruleset `21893944`，保護 `refs/tags/v*`，禁止更新與刪除；
- 建立 `stable-signing` environment，只允許 `master` 部署，必要 reviewer 為
  `xup61069`。

仍未具備、不可假裝已完成的項目：

- labels 完全相符、每次 job 後銷毀且不重用磁碟／使用者 profile 的 ephemeral
  self-hosted Windows x64 runner；該 runner 還必須安裝符合 exact fingerprint 的
  SimHub 9.11.22；
- 公信 Windows code-signing PFX、對應 private key、密碼與釘選 SHA-256 secrets；
- 實體方向盤或商業遊戲測試台。

`repository_dispatch` 固定使用 default branch workflow，再加上
`if: github.ref == 'refs/heads/master'` 與精確 payload 驗證，構成 workflow 內的入口 gate；
真正保護簽章 secrets 的外部邊界是 `stable-signing` environment 的 deployment branch
policy 與 reviewer。PFX 仍會暫時匯入 runner 的 `CurrentUser\My`；正常或可捕捉的失敗
會用 `-DeleteKey` 清理，但主機斷電／runner crash 無法保證 cleanup，因此 `ephemeral`
必須代表 job 後直接銷毀整個 runner，而不是只加 label 的長期共用主機。

沒有這些外部條件時，只能產生 hosted Experimental 基礎資產，不能把它稱為完整 Stable。
發行說明不可捏造 runner、簽章或硬體測試已完成。

## 每個 tag 發布前只能選一個資產發布者

兩條 workflow 都只能由維護者發出各自的 `repository_dispatch` 事件，且共用
`release-<tag>` concurrency group；同一 tag 的兩個 job 不會同時上傳。然而 concurrency
只負責序列化，不會把基礎 Experimental 轉成完整 Stable。維護者在 dispatch 前仍必須
明確選定唯一 publisher。

完整 workflow 也會產生同名的 Proxy、Viewer、source、SBOM 與 `SHA256SUMS`。Stable
內容因簽章必然與未簽章基礎版不同，完整 checksum 又會涵蓋額外的 SimHub／Launcher
資產。因此，Full preflight 只允許「尚無 Release」或「未公開 private draft，且現有
資產是本次完整預期集合的無重複子集」；任何已公開 Release 都會 fail-closed。不要刪除、
替換或覆寫既有資產來強行轉成 Stable，應建立新的 SemVer tag。基礎 Experimental 仍可
透過 `ffb-experimental-base-release` 事件指定 tag 發布。

## 不可變資產政策

`.github/scripts/publish-release-assets.ps1` 對 1～64 個安全檔名的非空資產執行：

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

- 既有 Release 會先驗證全部既有資產、上傳缺少項目，再重新查詢並驗證最終集合；只有
  全部成功後，才用唯一一次 metadata edit 更新 title、body、prerelease 與發布狀態。
- 新 Release 先以 private draft 建立。只有資產上傳與 read-back 驗證全部成功，才將
  draft 發布；在此之前不會公開成錯誤頻道。
- 同名不同內容、非預期資產或複驗失敗都發生在 metadata edit 前，因此既有 Release 的
  title／body／prerelease 不會被提前改成 Stable，新 Release 則通常保留為 draft。
- GitHub 的多檔 upload 不是原子操作；上傳中途失敗可能留下部分已上傳資產，腳本不會
  rollback、delete 或 clobber。既有公開 Experimental 可能暫時看見這些部分資產，draft
  也可能保留部分資產。網路中斷時，最後一次 API 操作的遠端結果仍可能需要人工確認。

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

metadata（title／prerelease flag）可更新，但資產仍遵守不可覆寫政策。修改 notes template
後重跑不會抹掉 marker 外的維護者備註。

## 本機重現與發行前稽核

從乾淨 clone 重現基礎封裝：

```powershell
git checkout v0.3.0
$env:RELEASE_TAG = 'v0.3.0'
.github\scripts\verify-release-ref.ps1
.github\scripts\package-release.ps1
```

這只重現本機基礎資產，不會自行產生 GitHub attestation，也不會在沒有 PFX 時變成
Stable。完整套件另需：

```powershell
simhub\tools\Test-SimHubSdk.ps1 -SimHubInstallPath 'C:\Program Files (x86)\SimHub'
simhub\tools\Build-SimHubPackage.ps1
simhub\tools\Build-LauncherPackage.ps1
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
  default branch `master`，且 tag 正好指向當下 master HEAD；
- 11 個必要 checks 都屬於該 exact commit；
- 在 dispatch 前選定唯一 publisher；完整流程的遠端 asset preflight 必須通過；
- Stable 才宣稱 Authenticode，且已實際完成 PFX pin、timestamp 與驗證；
- 完整資產只在 SDK exact fingerprint 通過後出現；
- 四份 SBOM、`SHA256SUMS` 與所有預期資產都存在且非空；
- provenance attestation 已由 workflow 產生；
- GitHub release immutability 已啟用，tag ruleset `21893944` 保護 `refs/tags/v*`；Full
  的 `stable-signing` environment 只允許 master、reviewer 是 `xup61069`，且實際執行時
  runner 確實是一次性銷毀的 `ephemeral` instance；
- Release notes 明確保留「命令遙測、非馬達扭力」、支援限制與高扭力警告；
- 沒有宣稱尚未執行的 runner、憑證、商業遊戲或實體硬體測試。
