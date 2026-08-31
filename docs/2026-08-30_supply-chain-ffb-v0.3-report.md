# FFB Interceptor v0.3 供應鏈與執行邊界驗證報告

> 分析日期：2026-08-30 至 2026-08-31
>
> 報告模式：flavor = null
>
> Case ID：20260830-122917-authorized-local-source-implemen
>
> 驗證對象：FFB Interceptor v0.3.0 本機原始碼、專案自行建置的 x86／x64 產物與離線測試程式
>
> 驗證快照：codex/v0.3-hardening，基準提交 ccfd4a5

## 1. 執行摘要

本次工作針對 FFB Interceptor v0.3.0 的不改遊戲 DLL 執行路徑、SimHub 削峰核心、安裝器寫入邊界，以及原生程式與 Release 供應鏈政策進行授權內驗證。x64 與 x86 原生測試各 7/7 通過，專案自行建置的離線 probe 也完整走過 Launcher、Hook、系統 DirectInput8、安全 Named Pipe 與 SimHub Core。削峰核心 43 項測試及 viewer 兩個 Python 矩陣各 26/26 項測試通過，最新 native line coverage 為 68.37%（1589/2324），managed line coverage 為 83.72%（1023/1222）；本輪 viewer 實測為 Python 3.12 的 86.63% 與 Python 3.13 的 86.20%。削峰結果採同一來源、同一裝置的效果絕對值保守加總，不跨來源或跨裝置相加，因此是 DirectInput 命令上界，不是方向盤馬達扭力。最終未簽章 Experimental SimHub／Launcher ZIP 已在 PowerShell 7 與 Windows PowerShell 5.1 完整通過 lifecycle、目的地、併發鎖與 fail-closed fixtures。原生 x86／x64 產物也通過靜態 CRT 與 System32-only 靜態匯入政策；Stable Manager marker、簽章憑證匯入／失敗清除與 Release 草稿續傳均有正反向驗證。GitHub 已啟用 immutable releases、v* tag 更新／刪除保護與 stable-signing environment，但尚未在本報告快照發布 v0.3.0。這些證據支持目前的程式、套件與發布前控制，不代表已具備公信 Authenticode 簽章、完整 Stable runner、第三方商業遊戲或實體高扭力方向盤驗證。

## 2. 授權與範圍

權威範圍紀錄為 [scope.md](C:/Users/Administrator/reverse-skill/work/20260830-122917-authorized-local-source-implemen/scope.md)。

| 項目 | 內容 |
|---|---|
| 授權狀態 | granted |
| 授權依據 | own_system；使用者明確授權處理自有儲存庫與本機建置產物 |
| Case ID | 20260830-122917-authorized-local-source-implemen |
| 專案根目錄 | G:\AICODE\FFB |
| 網路設定 | authorized_target_only；僅限自有 GitHub 儲存庫與正式建置／文件來源 |
| 納入範圍 | 專案原始碼、測試、文件、CI／Release 設定、本機 build outputs、專案自行建置的離線 probe、唯讀 SimHub SDK 指紋 |
| 排除範圍 | 第三方遊戲、反作弊、線上服務、未擁有的程序／儲存庫、任意 PID／DLL 注入、繞過與實體硬體安全認證 |

本報告整理 E-001 至 E-005 已具備的驗證結果。遠端 GitHub 設定與本機封包會明確分開；沒有以尚未執行的 workflow、尚未發布的 Release 或第三方環境推論成功。

## 3. 架構、匯入與信任邊界

完整可編輯流程圖見 [v0.3-trust-flow.mmd](v0.3-trust-flow.mmd)。

### 3.1 執行與資料流

1. 一般權限 Manager 先確認套件 manifest、必要檔案、SHA-256、reparse point、架構與建置政策，再依遊戲架構選擇固定的 x86 或 x64 Launcher／Hook。
2. Launcher 只建立使用者明確選取的新遊戲子程序，不附加既有 PID；專案首選路徑不需要在遊戲資料夾建立、覆寫或刪除 dinput8.dll。
3. 固定同層 Hook 載入 System32 的 dinput8.dll，並針對尚未被修改的 DirectInput8Create IAT 項目導入共用 wrapper。
4. wrapper 將 DirectInput 命令事件送到目前使用者限定的本機 Named Pipe；SimHub Core 依來源、裝置與效果重建保守命令上界。
5. Core 只在資料可靠時輸出削峰狀態；來源、裝置、效果或 trigger 狀態不完整時會標記限制，而不是默默產生確定結論。

E-001 的 owned offline E2E 實際走過第 2 至第 4 步，且 fixture 目錄沒有 dinput8.dll。E-002 驗證第 4 至第 5 步的協定、削峰、可靠度與 viewer 行為。

### 3.2 原生匯入與 PE 政策

| 控制 | 實作契約 | 已驗證範圍 |
|---|---|---|
| MSVC runtime | 原生目標使用靜態 CRT，不依賴 app-local MSVCP、MSVCR、VCRUNTIME、CONCRT、UCRT 或 api-ms-win-crt DLL | E-003 的 x86／x64 dumpbin 檢查 |
| 靜態 DLL 搜尋 | Proxy、Hook、Launcher 與 Manager 設定 DependentLoadFlags 0x800，將 PE 靜態匯入限制到 System32 搜尋範圍 | E-003 的八個產物檢查 |
| DirectInput 載入 | Hook 明確以 LOAD_LIBRARY_SEARCH_SYSTEM32 載入 dinput8.dll | E-001 的 owned E2E 與 E-003 的匯入政策 |
| Stable marker | 唯一且 NUL 結尾，MODE 必須為 STABLE，signer 為 64 位大寫十六進位 SHA-256 | E-003 正反向 fixtures |
| Marker 區段 | 完整落在 .rdata 的 raw 與 mapped VirtualSize 範圍；區段必須為 initialized-data／READ，且不得 WRITE／EXEC | E-003 正反向 fixtures |
| 封裝重驗 | 封裝契約在簽章前解析 raw PE，簽章後重解析最終 bytes，再比對 marker signer 與 Authenticode signer | E-003 驗證 parser 與拒絕案例；本報告不宣稱已有公信發布簽章 |

DependentLoadFlags 只保護 PE 靜態匯入，不會自動約束所有執行期 LoadLibrary 或 GetProcAddress 路徑。Stable marker 也是建置政策證據，不取代 Authenticode 信任鏈、撤銷檢查、逐檔 manifest 與外層發行來源證明。

### 3.3 信任邊界

| 邊界 | 信任輸入 | Fail-closed 條件 | 剩餘風險 |
|---|---|---|---|
| 套件到 Manager | 精確 manifest、逐檔 SHA-256、固定 allowlist、PE 架構與建置政策 | 缺檔、多檔、雜湊不符、reparse、架構或 marker 不符即停止 | E-004 為未簽章 Experimental 本機套件；尚無公信 signer 證據 |
| 一般權限到提權作業 | 固定 Manager helper、固定安裝／移除動作、一次性同步事件與重新驗證 | 取消 UAC、錯誤 helper、缺少同步、SimHub 執行中或重驗失敗時停止 | 本次包含可觀察 handoff 與負向 fixture，但不包含真實 Program Files 完整 UAC 動態回歸 |
| 同時安裝／解除安裝 | 固定名稱、零共享、delete-on-close mutation lease，加上本次作業 GUID sentinel | 第二個 process／session、可替換磁碟代號、reparse、目錄身分改變或不同 SimHub state path 即停止 | 受管理檔案以外的 SimHub 升級行為仍不由本專案控制 |
| Manager 到遊戲程序 | 使用者選取的本機 EXE、相符架構的固定 Launcher／Hook | UNC、系統目錄、位元數或路徑政策不符時拒絕 | 商業遊戲、保護程序與下一層 launcher 未驗證 |
| Hook 到系統 DirectInput8 | System32 dinput8.dll 與未被修改的 DirectInput8Create IAT | 解析或比對不安全時不覆寫該項目 | 動態解析、私有 loader、GameInput、XInput 與專有 FFB SDK 不涵蓋 |
| Producer 到 Core | 本機目前使用者 Named Pipe、協定版本、frame 上限與 Hello PID | frame、session、容量或 trigger 狀態異常時降級為不可靠 | 同一 Windows 使用者下的惡意程序不在完整信任邊界 |
| 命令到實體硬體 | DirectInput 命令值 | 不做實體扭力安全判定 | 馬達電流、機構、驅動器限制與人體安全必須由硬體措施處理 |

## 4. Evidence

### E-001
- title: x64 與 x86 原生測試及 owned offline launcher pipeline 通過
- observed_at: 2026-08-30T21:20:00+08:00
- source_type: command
- source_ref: build/v0.3-final-x64；build/v0.3-final-x86；tests/e2e
- content_hash: n/a
- artifact_path: n/a
- repro_command: |
    ctest --test-dir build/v0.3-release-20260831-x64 -C Release --output-on-failure
    ctest --test-dir build/v0.3-release-20260831-x86 -C Release --output-on-failure
    tests/e2e/bin/Release/net48/FFBInterceptor.E2E.Tests.exe build/v0.3-release-20260831-x64/FFBInterceptor.Launcher.exe build/v0.3-release-20260831-x64/e2e/FFBInterceptor.E2E.Probe.exe
    tests/e2e/bin/Release/net48/FFBInterceptor.E2E.Tests.exe build/v0.3-release-20260831-x86/FFBInterceptor.Launcher.exe build/v0.3-release-20260831-x86/e2e/FFBInterceptor.E2E.Probe.exe
- raw_excerpt: |
    x64：7/7 CTest 通過。
    x86：7/7 CTest 通過。
    兩個 owned fixture 都通過 Launcher → Hook → System DirectInput8 → secure pipe → SimHub Core。
    E2E 先確認 fixture 目錄不存在 dinput8.dll。
- linked_workitem: WI-002
- supersedes: none

### E-002
- title: 削峰核心、viewer 與最新 coverage gates 通過
- observed_at: 2026-08-31T05:07:28+08:00
- source_type: command
- source_ref: simhub/FFBInterceptor.Core.Tests；viewer/tests；build/v0.3-coverage-current
- content_hash: n/a
- artifact_path: n/a
- repro_command: |
    simhub/FFBInterceptor.Core.Tests/bin/Release/net48/FFBInterceptor.Core.Tests.exe
    ./.github/scripts/assert-cobertura-coverage.ps1 -Report build/v0.3-coverage-current/native-final.cobertura.xml -PathContains @('/src/','/launcher/') -RequireEachPath -MinimumPercent 50 -MinimumTrackedLines 900
    ./.github/scripts/assert-cobertura-coverage.ps1 -Report build/v0.3-coverage-current/managed-final.cobertura.xml -PathContains '/simhub/FFBInterceptor.Core/' -MinimumPercent 75 -MinimumTrackedLines 500
    Push-Location viewer
    uv run pytest -s --cov=ffb_visualizer --cov-report=term-missing --cov-fail-under=85
    Pop-Location
- raw_excerpt: |
    Core：43 項通過。
    Native：68.37%（1589/2324 lines）。
    Managed Core：83.72%（1023/1222 lines）。
    Viewer：Python 3.12 與 3.13 各 26/26 項通過，本輪 coverage 分別為 86.63% 與 86.20%。
- linked_workitem: WI-003
- supersedes: none

### E-003
- title: 靜態 CRT、System32-only 匯入與 Stable Manager marker fail-closed fixtures 通過
- observed_at: 2026-08-30T22:13:02+08:00
- source_type: command
- source_ref: tests/powershell/binary_hardening_tests.ps1；tests/powershell/manager_policy_tests.ps1；simhub/tools/Test-ManagerBuildPolicy.ps1
- content_hash: n/a
- artifact_path: n/a
- repro_command: |
    $bins = @(
      'build/manager-elevation-x64/dinput8.dll',
      'build/manager-elevation-x64/FFBInterceptor.Hook.dll',
      'build/manager-elevation-x64/FFBInterceptor.Launcher.exe',
      'build/manager-elevation-x64/FFBInterceptor.Manager.exe',
      'build/manager-elevation-x86/dinput8.dll',
      'build/manager-elevation-x86/FFBInterceptor.Hook.dll',
      'build/manager-elevation-x86/FFBInterceptor.Launcher.exe',
      'build/manager-elevation-x86/FFBInterceptor.Manager.exe'
    )
    ./tests/powershell/binary_hardening_tests.ps1 -BinaryPaths $bins
    $signer = '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF'
    pwsh -NoProfile -File tests/powershell/manager_policy_tests.ps1 -StableManagerPath build/manager-policy-stable-local/FFBInterceptor.Manager.exe -ExperimentalManagerPath build/manager-policy-experimental-local/FFBInterceptor.Manager.exe -ExpectedSigner $signer
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/powershell/manager_policy_tests.ps1 -StableManagerPath build/manager-policy-stable-local/FFBInterceptor.Manager.exe -ExperimentalManagerPath build/manager-policy-experimental-local/FFBInterceptor.Manager.exe -ExpectedSigner $signer
- raw_excerpt: |
    PASS static CRT and System32-only import policy for 8 binaries。
    PASS stable Manager build-policy fixtures（PowerShell 7）。
    PASS stable Manager build-policy fixtures（Windows PowerShell 5.1）。
    Negative fixtures 拒絕 Experimental、重複、overlay-only、raw padding 與錯誤區段 marker。
- linked_workitem: WI-004
- supersedes: none
- notes: 本機 signer 值與建置產物只供測試，不是公信 Windows 發行信任根。

### E-004
- title: 最終未簽章 Experimental SimHub 與 Launcher 套件通過雙 PowerShell lifecycle 與目的地邊界
- observed_at: 2026-08-31T10:48:00+08:00
- source_type: artifact_and_command
- source_ref: build/v0.3-final-packages-20260831-final；simhub/tools/Test-SimHubPackage.ps1；simhub/tools/Test-LauncherPackage.ps1
- content_hash: Launcher SHA-256 92D3EDC3A24AD4403968154C2E697837769C045285DB2C9CD75EEBF852A87079；SimHub SHA-256 D574B834332A384FC9099643F4432F9E386E4FE6822148842EC151EDF1F23549
- artifact_path: build/v0.3-final-packages-20260831-final
- repro_command: |
    ./simhub/tools/Test-SimHubPackage.ps1 -PackagePath build/v0.3-final-packages-20260831-final/FFBInterceptor-SimHub-0.3.0.zip
    ./simhub/tools/Test-LauncherPackage.ps1 -PackagePath build/v0.3-final-packages-20260831-final/FFBInterceptor-Launcher-0.3.0.zip
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File simhub/tools/Test-SimHubPackage.ps1 -PackagePath build/v0.3-final-packages-20260831-final/FFBInterceptor-SimHub-0.3.0.zip
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File simhub/tools/Test-LauncherPackage.ps1 -PackagePath build/v0.3-final-packages-20260831-final/FFBInterceptor-Launcher-0.3.0.zip
- raw_excerpt: |
    SimHub ZIP 115902 bytes，SHA-256 D574B834332A384FC9099643F4432F9E386E4FE6822148842EC151EDF1F23549。
    Launcher ZIP 630281 bytes，SHA-256 92D3EDC3A24AD4403968154C2E697837769C045285DB2C9CD75EEBF852A87079。
    PowerShell 7 與 Windows PowerShell 5.1 四次最終套件驗證均通過。
    Fixtures 驗證跨程序 mutation lease、不同 SimHub path 拒絕、raw DOS 子目錄 alias 拒絕、SimHub EXE 缺少時仍可依受保護 state 解除，以及任何 SimHub process 存在時 fail-closed。
    可觀察安全 Manager stub 必須收到零參數與正確 cwd 的原子 sentinel；略過 Start-Process 會逾時失敗。
- linked_workitem: WI-004
- supersedes: none
- notes: 這兩個 ZIP 是未簽章 Experimental 本機產物，不是 Stable 或已發布 Release 證據。

### E-005
- title: Release dispatch、草稿續傳、簽章身分清除與 GitHub 外部保護通過發布前驗證
- observed_at: 2026-08-31T10:43:00+08:00
- source_type: command_and_remote_configuration
- source_ref: .github/workflows/release.yml；.github/workflows/simhub-sdk-release.yml；tests/powershell/release_gate_tests.ps1；tests/powershell/release_preflight_tests.ps1；owned GitHub repository settings
- content_hash: n/a
- artifact_path: n/a
- repro_command: |
    ./tests/powershell/release_gate_tests.ps1
    ./tests/powershell/release_preflight_tests.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/powershell/release_gate_tests.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/powershell/release_preflight_tests.ps1
    build/tools/actionlint-v1.7.12/actionlint.exe -config-file .github/actionlint.yaml
    uvx zizmor==1.29.0 --pedantic .github/workflows
- raw_excerpt: |
    兩個 workflow 只接受各自 repository_dispatch event，精確驗證 payload，先從 master 綁定 tag／commit，再以 SHA checkout 與發布前重驗防止 ref 移動。
    Base 與 Full Experimental 固定未簽章、不引用 Stable PFX secrets；Stable 才在 stable-signing environment 與 ephemeral runner 匯入唯一 private-key identity。
    真實 CurrentUser/My 暫存 code-signing certificate 正常路徑與匯入後受控失敗均清除成功；測試 subject、thumbprint、private key 與暫存 PFX 最終殘留皆為 0。
    Full preflight 只接受不存在的 Release，或含無重複預期資產子集的 private draft；公開、未知或重複資產均拒絕。
    actionlint 1.7.12 通過；zizmor 1.29.0 pedantic 為 0 findings、1 個明示 suppression。
    GitHub immutable releases 已啟用；ruleset 21893944 禁止更新／刪除 refs/tags/v*；stable-signing 只允許 master 且 reviewer 為 xup61069。
- linked_workitem: WI-005
- supersedes: none
- notes: 尚無可用 ephemeral self-hosted runner、公信 PFX secrets 或硬體證據，因此 Full／Stable 未執行。

## 5. Findings

### F-001
- title: 不改遊戲 dinput8.dll 的雙架構呼叫路徑已由 owned E2E 驗證
- severity: info
- category: design
- status: validated
- evidence_ids: [E-001, E-003]
- location: launcher/injector.cpp:769；launcher/injector.cpp:812；src/hook_dll.cpp:51；src/iat_hook.cpp:116
- impact: 首選 Manager／Launcher 模式可在不寫入遊戲資料夾 dinput8.dll 的情況下建立新子程序、載入固定 Hook、使用系統 DirectInput8 並送出遙測，降低覆寫既有遊戲 proxy 的衝突與復原風險。
- confidence: high
- repro_steps:
  1. 在 x64 與 x86 build 目錄各執行完整 CTest。
  2. 以 tests/e2e 的 owner-built probe 分別執行兩個 Launcher E2E。
  3. 確認輸出顯示完整 Launcher → Hook → System DirectInput8 → secure pipe → Core，且 fixture 無 dinput8.dll。
  4. 對兩個架構的 Hook／Launcher 執行 E-003 匯入政策檢查。
- remediation: 保留雙架構 E2E、固定 sibling Hook、System32 DirectInput8 與無 dinput8.dll fixture 斷言作為必要回歸門檻。
- optional_attack: ""

### F-002
- title: 削峰演算法與可靠度降級符合保守命令上界契約
- severity: info
- category: design
- status: validated
- evidence_ids: [E-001, E-002]
- location: simhub/FFBInterceptor.Core/ClippingEngine.cs:12；simhub/FFBInterceptor.Core/ClippingEngine.cs:314；simhub/FFBInterceptor.Core/Models.cs:211；simhub/FFBInterceptor.Core/Protocol.cs:116
- impact: Core 會在同一來源、同一裝置內加總效果絕對值，跨來源與跨裝置不相加；trigger 狀態、容量或 session 資訊不足時會標示不可靠，避免把缺資料誤報成已確認削峰。結果可用於命令遙測與調整，但不能作為馬達扭力或人體安全量測。
- confidence: high
- repro_steps:
  1. 執行 43 項 Core 測試。
  2. 執行 x64／x86 owned E2E，確認事件可由 producer 抵達 Core。
  3. 對最新 native-final.cobertura.xml 與 managed-final.cobertura.xml 執行 coverage gates。
  4. 在 viewer 目錄執行 26 項 pytest 與 85% coverage 門檻。
- remediation: 保留 protocol presence flags、來源／裝置／效果容量上限、trigger fail-closed、遺失／重連可靠度旗標與 coverage 門檻；文件持續明示命令上界不等於實際扭力。
- optional_attack: ""

### F-003
- title: 原生靜態相依與 Stable Manager marker 已具備 fail-closed 驗證
- severity: medium
- category: design
- status: validated
- evidence_ids: [E-001, E-003]
- location: CMakeLists.txt:43；CMakeLists.txt:44；simhub/tools/Test-ManagerBuildPolicy.ps1:108；simhub/tools/Build-LauncherPackage.ps1:135；simhub/tools/Build-LauncherPackage.ps1:179
- impact: 靜態 CRT 與 DependentLoadFlags 0x800 降低原生程式啟動時由套件目錄載入非預期 runtime／靜態相依的風險；marker 的唯一性、mapped initialized .rdata 邊界與簽章後重驗契約可拒絕 padding、憑證表或 overlay 偽造的 Stable 政策字串。
- confidence: high
- repro_steps:
  1. 對 x86／x64 的 Proxy、Hook、Launcher 與 Manager 執行 binary_hardening_tests.ps1。
  2. 以 PowerShell 7 執行 manager_policy_tests.ps1。
  3. 以 Windows PowerShell 5.1 重跑相同 marker fixtures。
  4. 確認錯誤模式、重複 marker、raw padding、overlay 與錯誤區段案例全數被拒絕。
- remediation: 正式封裝時維持簽章前解析、簽章後最終 bytes 重解析、marker signer 與 Authenticode leaf signer 比對；不得把本機測試 signer 當成 Stable 信任根。
- optional_attack: ""

### F-004
- title: SimHub 安裝與解除安裝目的地已具備跨程序互斥與 state 綁定
- severity: medium
- category: design
- status: validated
- evidence_ids: [E-003, E-004]
- location: simhub/launcher-portable/FFBInterceptor.Common.ps1；simhub/launcher-portable/Install-SimHubPlugin.ps1；simhub/launcher-portable/Uninstall-SimHubPlugin.ps1；simhub/tools/Test-LauncherPackage.ps1
- impact: 實際寫入在固定磁碟與逐層目錄身分重驗後，以固定名稱零共享 lease 讓另一 process／session 無法同時修改；受保護 state 不能靜默切換到另一個 SimHub 根目錄。解除安裝不再依賴 SimHub EXE 仍存在，但仍要求 state、檔案雜湊、目錄身分與程序關閉全部吻合。
- confidence: high
- repro_steps:
  1. 以 PowerShell 7 與 Windows PowerShell 5.1 執行 E-004 的 Launcher 套件驗證。
  2. 確認第二個 PowerShell process 在 lease 被持有時失敗，釋放或崩潰後不留固定 lease／GUID sentinel。
  3. 以不同 SimHub 根目錄重裝，確認拒絕且 state／新目錄未改變。
  4. 移除 fake SimHub EXE 後解除安裝，確認原始 DLL 還原且 state 清除。
- remediation: 保留 SimHub→state 固定鎖順序、鎖後重讀 state、fixed-volume／reparse／identity gates 與 package lifecycle fixtures；未經解除安裝不得支援跨目錄遷移。
- optional_attack: ""

### F-005
- title: 發布入口與不可變資產政策已具備 fail-closed 發布前控制
- severity: medium
- category: supply_chain
- status: validated
- evidence_ids: [E-003, E-005]
- location: .github/workflows/release.yml；.github/workflows/simhub-sdk-release.yml；.github/scripts/verify-release-ref.ps1；.github/scripts/publish-release-assets.ps1；.github/scripts/import-signing-certificate.ps1
- impact: 非預期 payload、非 master 信任來源、tag 移動、exact-commit checks 未完成、公開或未知草稿資產、Stable signer 不符，以及憑證清理狀態含糊都會在發布前停止。已存在的相符 private draft 只補缺少資產，最終逐一比對後才公開。
- confidence: high
- repro_steps:
  1. 在 PowerShell 7 與 Windows PowerShell 5.1 執行 release gate 與 preflight fixtures。
  2. 執行 actionlint 1.7.12 與 zizmor 1.29.0 pedantic。
  3. 以唯一暫存 code-signing PFX 驗證成功匯入與故意 GITHUB_ENV 寫入失敗，確認兩條路徑都以 DeleteKey 清除且零殘留。
  4. 讀回 owned GitHub repository 的 immutable-release、tag ruleset 與 environment 設定。
- remediation: 發布前仍須讓 PR 與 exact tag commit 的所有必要 checks 通過；Stable 只能在每次 job 後銷毀的 ephemeral runner 上使用公信 PFX 與釘選 signer，不得把 label 當作真正隔離。
- optional_attack: ""

## 6. Path

### P-001
- title: Manager 套件驗證至削峰狀態的執行呼叫流
- path_type: callflow
- start: 使用者以一般權限從已解壓縮套件選擇本機 x86 或 x64 遊戲 EXE
- goal: DirectInput8 命令經固定 Hook 與安全 Named Pipe 抵達 Core，產生有可靠度狀態的削峰命令上界
- steps:
  1. action: Manager 讀取精確 manifest，驗證必要檔案、SHA-256、reparse、架構與 Manager 建置政策。— evidence: E-003 — finding: F-003
  2. action: Manager 依目標架構選擇固定 Launcher／Hook，Launcher 只建立使用者指定的新子程序，不在遊戲目錄部署 dinput8.dll。— evidence: E-001 — finding: F-001
  3. action: 固定 Hook 載入 System32 dinput8.dll，並在安全比對後接管 DirectInput8Create IAT 項目。— evidence: E-001, E-003 — finding: F-001, F-003
  4. action: 共用 wrapper 保留 DirectInput COM 行為並把效果事件送往目前使用者限定的本機 Named Pipe。— evidence: E-001 — finding: F-001
  5. action: Core 解碼效果參數與 presence flags，依來源及裝置維護有限狀態。— evidence: E-001, E-002 — finding: F-002
  6. action: Core 以 ConservativeAbsoluteSumPerDevice 產生削峰上界；資料不完整時輸出可靠度限制，viewer 顯示相同狀態。— evidence: E-002 — finding: F-002
- residual_risks: 動態 GetProcAddress、私有 loader、下一層 launcher、GameInput、XInput、同一使用者惡意 pipe client、商業遊戲與實體方向盤不在本次動態證據內；命令值不是馬達扭力。

### P-002
- title: 經預設分支綁定與不可變資產驗證的發行路徑
- path_type: supply_chain
- start: 維護者已將審查過的 v0.3.0 commit 合併到 master，建立受保護 SemVer tag，並選定唯一 publisher
- goal: 只有 exact tag commit 的完整 checks 與本次產物通過後，才公開不可覆寫的 Release 資產與 provenance
- steps:
  1. action: 維護者送出欄位精確的 repository_dispatch；workflow 定義固定取自 default branch master。— evidence: E-005 — finding: F-005
  2. action: workflow 將 tag 初次綁定 current origin/master HEAD，再以 commit SHA checkout；後續只允許 master 正常前進，拒絕 tag／checkout 移動。— evidence: E-005 — finding: F-005
  3. action: exact commit 必要 checks、完整歷史 secret scan、SPDX 與依賴／coverage gates 皆通過才封裝。— evidence: E-002, E-003, E-005 — finding: F-003, F-005
  4. action: Experimental 固定未簽章；Stable 才在 stable-signing environment 的 ephemeral runner 匯入唯一 signer，並於失敗與 always 路徑刪除所有 imported cert private keys。— evidence: E-005 — finding: F-005
  5. action: publisher 建立 private draft、只補缺少資產，讀回並逐一驗證 size／SHA-256 後才設定最終 metadata 並公開。— evidence: E-005 — finding: F-005
  6. action: GitHub immutable release 與 tag ruleset 防止發布後覆寫資產或移動／刪除 v* tag。— evidence: E-005 — finding: F-005
- residual_risks: 本報告快照尚無實際 v0.3.0 run／attestation／公開資產證據；Stable runner、PFX secrets 與 reviewer 核准尚未具備，且 runner 當機清理只能靠真正銷毀 instance。

## 7. 可重現驗證

下列命令由 G:\AICODE\FFB 執行。x64 與 x86 建置應分別使用對應的 Visual Studio Developer PowerShell。

### 7.1 雙架構建置、CTest 與 owned E2E

    cmake --preset msvc-x64-release
    cmake --build --preset x64-release
    ctest --test-dir build/x64-release --output-on-failure

    cmake --preset msvc-x86-release
    cmake --build --preset x86-release
    ctest --test-dir build/x86-release --output-on-failure

    dotnet build tests/e2e/FFBInterceptor.E2E.Tests.csproj -c Release
    tests/e2e/bin/Release/net48/FFBInterceptor.E2E.Tests.exe build/x64-release/FFBInterceptor.Launcher.exe build/x64-release/e2e/FFBInterceptor.E2E.Probe.exe
    tests/e2e/bin/Release/net48/FFBInterceptor.E2E.Tests.exe build/x86-release/FFBInterceptor.Launcher.exe build/x86-release/e2e/FFBInterceptor.E2E.Probe.exe

### 7.2 Core、viewer 與 coverage

    dotnet build simhub/FFBInterceptor.Core.Tests/FFBInterceptor.Core.Tests.csproj -c Release
    simhub/FFBInterceptor.Core.Tests/bin/Release/net48/FFBInterceptor.Core.Tests.exe

    $build = (Resolve-Path build/v0.3-coverage-current).Path
    $suite = (Resolve-Path tests/powershell/run-native-coverage-suite.ps1).Path
    $e2e = (Resolve-Path tests/e2e/bin/Release/net48/FFBInterceptor.E2E.Tests.exe).Path
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $suite, '-BuildDirectory', $build, '-E2ETest', $e2e)
    $include = @("$build\ffb_*tests.exe", "$build\FFBInterceptor.Launcher.exe", "$build\FFBInterceptor.Hook.dll", "$build\e2e\FFBInterceptor.E2E.Probe.exe")
    ./.github/scripts/invoke-code-coverage.ps1 -CommandPath (Get-Command powershell.exe).Source -CommandArguments $arguments -IncludeFiles $include -Output build/v0.3-coverage-current/native-final.cobertura.xml
    ./.github/scripts/assert-cobertura-coverage.ps1 -Report build/v0.3-coverage-current/native-final.cobertura.xml -PathContains @('/src/','/launcher/') -RequireEachPath -MinimumPercent 50 -MinimumTrackedLines 900

    $test = (Resolve-Path simhub/FFBInterceptor.Core.Tests/bin/Release/net48/FFBInterceptor.Core.Tests.exe).Path
    $core = (Resolve-Path simhub/FFBInterceptor.Core.Tests/bin/Release/net48/FFBInterceptor.Core.dll).Path
    ./.github/scripts/invoke-code-coverage.ps1 -CommandPath $test -IncludeFiles @($core) -Output build/v0.3-coverage-current/managed-final.cobertura.xml
    ./.github/scripts/assert-cobertura-coverage.ps1 -Report build/v0.3-coverage-current/managed-final.cobertura.xml -PathContains '/simhub/FFBInterceptor.Core/' -MinimumPercent 75 -MinimumTrackedLines 500

    Push-Location viewer
    uv sync --locked --extra dev
    uv run pytest -s --cov=ffb_visualizer --cov-report=term-missing --cov-fail-under=85
    Pop-Location

### 7.3 Binary 與 Manager marker

    $bins = @(
      'build/x64-release/dinput8.dll',
      'build/x64-release/FFBInterceptor.Hook.dll',
      'build/x64-release/FFBInterceptor.Launcher.exe',
      'build/x64-release/FFBInterceptor.Manager.exe',
      'build/x86-release/dinput8.dll',
      'build/x86-release/FFBInterceptor.Hook.dll',
      'build/x86-release/FFBInterceptor.Launcher.exe',
      'build/x86-release/FFBInterceptor.Manager.exe'
    )
    ./tests/powershell/binary_hardening_tests.ps1 -BinaryPaths $bins

    $signer = '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF'
    pwsh -NoProfile -File tests/powershell/manager_policy_tests.ps1 -StableManagerPath build/manager-policy-stable-local/FFBInterceptor.Manager.exe -ExperimentalManagerPath build/manager-policy-experimental-local/FFBInterceptor.Manager.exe -ExpectedSigner $signer
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/powershell/manager_policy_tests.ps1 -StableManagerPath build/manager-policy-stable-local/FFBInterceptor.Manager.exe -ExperimentalManagerPath build/manager-policy-experimental-local/FFBInterceptor.Manager.exe -ExpectedSigner $signer

### 7.4 套件、安裝器與 Release 控制

    ./simhub/tools/Test-SimHubPackage.ps1 -PackagePath build/v0.3-final-packages-20260831-final/FFBInterceptor-SimHub-0.3.0.zip
    ./simhub/tools/Test-LauncherPackage.ps1 -PackagePath build/v0.3-final-packages-20260831-final/FFBInterceptor-Launcher-0.3.0.zip
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File simhub/tools/Test-SimHubPackage.ps1 -PackagePath build/v0.3-final-packages-20260831-final/FFBInterceptor-SimHub-0.3.0.zip
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File simhub/tools/Test-LauncherPackage.ps1 -PackagePath build/v0.3-final-packages-20260831-final/FFBInterceptor-Launcher-0.3.0.zip

    ./tests/powershell/release_gate_tests.ps1
    ./tests/powershell/release_preflight_tests.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/powershell/release_gate_tests.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/powershell/release_preflight_tests.ps1
    build/tools/actionlint-v1.7.12/actionlint.exe -config-file .github/actionlint.yaml
    uvx zizmor==1.29.0 --pedantic .github/workflows

## 8. 限制與剩餘風險

- 本報告已記錄遠端 GitHub 保護設定與最終本機封包雜湊，但沒有把尚未建立的 PR、遠端 checks、v0.3.0 Release、公開資產或 attestation 推論為成功；實際發布結果須另以後續 closure evidence 補記。
- E-003 的 signer 與 Stable Manager 產物是本機 fixture；沒有公信 Windows code-signing 憑證與完整正式發布證據，因此不能宣稱已發布 Stable。
- E2E 只使用專案自行建置的離線 probe；沒有執行第三方商業遊戲、反作弊程序、任意既有 PID 或線上服務。
- 本次沒有實體方向盤、馬達、電流或機構量測。高扭力硬體仍須使用實體急停、廠商限制與最低初始增益。
- ConservativeAbsoluteSumPerDevice 因不推測方向抵消，可能高估實際合力；它不跨來源或裝置相加，也不是扭力估測器。
- 目前支援面限於由 DirectInput8Create 建立的 x86／x64 DirectInput8；GameInput、WinRT、XInput、私有 SDK、動態解析與驅動／HID Hook 不在 v0.3.0 證據範圍。
- Named Pipe 限制為本機目前使用者並核對 Hello PID，但同一 Windows 使用者下的惡意程序不是完整隔離邊界。
- 靜態 CRT 與 DependentLoadFlags 0x800 只處理原生程式的靜態相依；任何額外動態載入仍須各自使用固定路徑與明確搜尋旗標。
- 本次有可觀察 Manager handoff、restricted-token、實際暫存 SimHub process 負向案例與雙 PowerShell lifecycle，但未包含真實受保護 Program Files SimHub 目錄的完整 UAC 安裝／移除動態回歸，因此仍須在一次性 self-hosted 環境重跑。
- Stable 發行仍缺真正每次銷毀的 ephemeral runner、公信 code-signing PFX／釘選 secrets、environment reviewer 實際核准與完成簽章產物；本機暫存憑證只證明清除路徑。

## 9. Timeline 摘要

| 時間（Asia/Taipei） | 事件 | Evidence／結果 |
|---|---|---|
| 2026-08-30 12:29 | 建立 case 與初始 scope | Case 20260830-122917-authorized-local-source-implemen |
| 2026-08-30 12:35 | 確認 own_system 授權、in-scope 與排除範圍 | scope.md：auth=granted，ready_for_act=true |
| 2026-08-30 21:20 | 完成雙架構 native 與 owned offline E2E | E-001：x64 7/7、x86 7/7、兩條 E2E 通過 |
| 2026-08-30 21:23 | 完成原生載入政策與 Manager marker fixtures | E-003：static CRT、DependentLoadFlags、marker 正反向案例通過 |
| 2026-08-30 21:28 | 完成 Core 行為測試 | E-002：Core 43 項通過 |
| 2026-08-31 04:56 | 產生最新 native／managed coverage 報告並重跑 gates | E-002：native 68.37%（1589/2324）、managed 83.72%（1023/1222） |
| 2026-08-31 10:05 | 以 locked dev environment 重跑 viewer Python 3.12／3.13 | E-002：各 26/26 通過、coverage 86.63%／86.20% |
| 2026-08-31 10:20 | 完成 repository_dispatch、draft recovery、Stable secret 隔離與憑證清除 hardening | E-005：PS7／PS5 fixtures、actionlint、zizmor 通過 |
| 2026-08-31 10:43 | 用唯一暫存 code-signing PFX 驗證正常與匯入後失敗清除 | E-005：CurrentUser/My、private key、subject 與暫存 PFX 最終殘留 0 |
| 2026-08-31 10:48 | 重建並驗證最終 Experimental SimHub／Launcher ZIP | E-004：PS7／PS5 套件 lifecycle 與目的地 fixtures 通過 |

## 10. 結論

在目前授權範圍與發布前證據下，v0.3.0 的雙架構 no-game-DLL 呼叫路徑、削峰核心、跨程序安裝目的地鎖、最終 Experimental 套件，以及 Release／Stable signer fail-closed 控制均達到可重現狀態。交付時必須保留本報告的邊界：這是專案自行建置 fixture、本機未簽章套件與 owned GitHub 設定的驗證；在實際 PR checks、tag、attestation 與 Release 完成前，不是公開發布成功證明，也不是商業遊戲相容性、實體扭力安全或公信簽章證明。
