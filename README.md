# FFB Interceptor + Visualizer（台灣繁體中文）

FFB Interceptor 是一套**未經數位簽章的實驗性** Windows 工具，用來觀察遊戲透過
DirectInput8 傳送的力回饋（Force Feedback，FFB）命令，並在即時檢視器中顯示命令
參數。每一個 DirectInput 呼叫與 HRESULT 都會原樣轉送。畫面上的
**Command Peak/RMS** 代表所選 API 通道的命令值，不是方向盤馬達的實際扭力量測。

v0.2.0 支援 x86／x64 的 C++17 `dinput8.dll` Proxy DLL（代理 DLL）、**不改遊戲
DLL 的離線啟動器／Hook（攔截模組）**、Python 3.12+ x64 PySide6／pyqtgraph
檢視器，以及 .NET Framework 4.8 SimHub 外掛。Proxy DLL 源自
[walmis/dcs-force-feedback-fix](https://github.com/walmis/dcs-force-feedback-fix)
v0.2（MIT），並保留原始歷史；本專案新增程式碼採 GPL-3.0-only。

## 快速開始（建議方式）

取得或自行建置 `FFBInterceptor-Launcher-*.zip` 後，建議使用這個不改遊戲 DLL 的
版本。它不會在遊戲資料夾放置或替換 `dinput8.dll`：

1. 解壓縮整個 ZIP，不要直接從壓縮檔內執行。
2. 關閉 SimHub。
3. 雙擊 `Start-FFBInterceptor.cmd`。
4. Windows 顯示 UAC 時按「是」；系統管理員權限只用來安裝 SimHub 外掛，不會用來啟動遊戲。
5. SimHub 開啟後，到 **Settings → Plugins** 啟用 **FFB Interceptor**。
6. 依自動開啟的 SimHub 畫面匯入儀表板（Dashboard）／覆疊顯示（Overlay），再回到提示視窗按 Enter。
7. 再次雙擊 `Start-FFBInterceptor.cmd`，選擇真正的離線遊戲 `.exe`。

平常使用只要執行第 7 步。完整白話操作、解除安裝與疑難排解請見
[SimHub 不改遊戲 DLL 版操作說明](simhub/LAUNCHER.zh-TW.md)。

## 支援範圍與安全提醒

目前只支援透過 `DirectInput8Create` 建立的 DirectInput8 裝置。GameInput、WinRT、
XInput 與私有 SDK 路徑不在 v0.2.0 支援範圍。本專案不提供反作弊規避、線上競技功能、
驅動程式／HID Hook、任意記憶體掃描、網路服務或實體扭力量測。啟動器只會解析它
所建立之新子處理程序內、受邊界限制的 PE 匯入資料。iRacing 明列為不支援項目，
這是專案的支援政策，不是 GPL 額外附加的用途限制。

高扭力方向盤基座可能突然動作。請讓手部遠離轉動範圍、準備實體急停、從最低增益
（gain）開始，並只在離線環境測試。建議使用的啟動器套件不含 `dinput8.dll`，也不會
寫入遊戲資料夾；執行時仍會把同資料夾內的固定 Hook 載入它剛建立的新子處理程序。
它不能指定既有 PID 或其他 DLL，也會拒絕以系統管理員權限執行，以及 Windows 系統
目錄內的目標。

傳統 Proxy DLL 模式仍然保留。使用該模式時，絕對不要直接覆寫遊戲原本的
`dinput8.dll`；請先保留原檔，並確保能完整還原。

## 建置 Windows 資料來源端

請安裝 Visual Studio 2022／2026 C++ 工具、Windows SDK、CMake 3.20+ 與 Ninja，
再從 Visual Studio 開發人員命令提示字元執行：

```powershell
cmake --preset msvc-x64-release
cmake --build --preset x64-release --target dinput8 ffb_hook ffb_launcher ffb_protocol_tests ffb_wrapper_tests ffb_dinput_wrapper_tests ffb_performance_tests ffb_telemetry_tests ffb_iat_hook_tests
cmake --preset msvc-x86-release   # 請從 -arch=x86 的開發人員命令提示字元執行
cmake --build --preset x86-release --target dinput8 ffb_hook ffb_launcher ffb_protocol_tests ffb_wrapper_tests ffb_dinput_wrapper_tests ffb_performance_tests ffb_telemetry_tests ffb_iat_hook_tests
ctest --test-dir build/x64-release --output-on-failure
ctest --test-dir build/x86-release --output-on-failure
```

傳統 Proxy DLL 模式必須先備份遊戲既有的 Proxy DLL，才能把建置出的 `dinput8.dll`
放到遊戲執行檔旁。Proxy DLL 會延後載入 System32 內真正的 `dinput8.dll`；即使檢視器
沒有執行，DirectInput 呼叫仍會照常原樣轉送，不應阻斷遊戲。

不改遊戲 DLL 的模式必須讓各架構的 `FFBInterceptor.Launcher.exe` 與
`FFBInterceptor.Hook.dll` 保持在同一個資料夾，再執行：

```powershell
.\FFBInterceptor.Launcher.exe --offline-only --game "C:\Games\Example\game.exe" --
```

啟動器會在子處理程序第一條入口點指令執行前完成同步，只載入固定的同層 Hook，還原暫時
放置於記憶體的同步斷點，只替換尚未被修改的
`dinput8.dll!DirectInput8Create` IAT 指標，完成後解除偵錯關係。它不會修改遊戲
EXE，也不會修改遊戲資料夾內的任何 DLL。

Proxy DLL 與啟動器 Hook 共用同一套攔截核心。Proxy DLL 的 ANSI／Wide COM 介面共用
控制區塊；跨介面的 `QueryInterface(IUnknown)`、`AddRef` 與 `Release` 會維持相同的
identity 與 reference count，aggregation 與未知介面則原樣轉送。

## 執行 Python 檢視器

需求為 Windows x64、Python 3.12+ 與 [uv](https://docs.astral.sh/uv/)：

```powershell
cd viewer
uv sync --extra dev
uv run ffb-viewer
```

檢視器會建立可供多個來源連線的具名管道（Named Pipe）
`\\.\pipe\ffb-interceptor-v1`。除非使用者主動按下匯出功能，資料只會留在記憶體。
介面提供資料來源／裝置／效果篩選、1／5／10／30 秒時間範圍、通道與 Condition 軸選擇、
暫停及事件標記，並以容量受限的循環緩衝區保留近期資料。

通道選擇器會顯示已觀察到的 Constant、Ramp、Periodic 參數，以及 Condition 的
offset、coefficient、saturation、deadband。缺少的參數會顯示為沒有樣本，不會合成
不存在的力值。`Export CSV`、`Export PNG` 與 `Save .ffbtrace` 都是使用者主動
操作。版本化 trace 只含相對時間、處理程序內穩定 ID 與已遮罩的命令欄位，不會儲存完整
路徑、序號、帳號或主機名稱。

CSV 另含長度受限的資料來源執行檔名稱與處理程序 ID，讓同時選取多個來源時仍能辨識
裝置／效果 ID。原始詳細資料面板只顯示最後一筆選取命令，不會虛構 Condition 力值。

## 建置與使用 SimHub 外掛

SimHub 外掛與 Python 檢視器可以同時運作。Proxy DLL 或啟動器 Hook 會寫入兩個互相獨立
的接收端：既有的 `\\.\pipe\ffb-interceptor-v1` 檢視器具名管道，以及
`\\.\pipe\ffb-interceptor-simhub-v1`。每個接收端都有自己的固定大小佇列、
傳送工作、丟棄統計與重新連線路徑，因此單一接收端停滯不會反向拖慢另一端。

多執行緒 DirectInput 呼叫會依嚴格遞增的序號送往兩端；SimHub 會拒絕重複或倒退的
封包。遊戲失去焦點並成功 `Unacquire`，或回報 acquisition loss 時，也會停止舊的
效果狀態，避免殘留資料造成假削峰。

已安裝 SimHub 時，可使用本機 SDK 建置與封裝外掛：

```powershell
powershell -ExecutionPolicy Bypass -File simhub\tools\Build-SimHubPackage.ps1
```

這會產生不納入 Git 的 `simhub/dist/FFBInterceptor-SimHub-0.2.0.zip`，而且不會重新
散布 SimHub 組件（assemblies）。套件內含兩個專案 DLL、800×480 儀表板、480×160
高對比覆疊顯示（Overlay），以及台灣繁體中文安裝說明。詳見
[SimHub 外掛說明](simhub/README.md)。

完成兩個架構的啟動器／Hook 建置後，可產生建議使用的不改遊戲 DLL 可攜式套件：

```powershell
powershell -ExecutionPolicy Bypass -File simhub\tools\Build-LauncherPackage.ps1
```

輸出為 `simhub/dist/FFBInterceptor-Launcher-0.2.0.zip`。解壓縮後執行
`Start-FFBInterceptor.cmd`：第一次會安裝 SimHub 外掛並開啟 SimHub，之後則讓
使用者選擇並啟動離線遊戲。套件採明確允許清單（allowlist）與 SHA-256 雜湊清單
（manifest），不含
`dinput8.dll`。生命週期測試會驗證首次安裝、同版本重複執行、不同版本拒絕、同名
目錄拒絕、檔案遭修改時拒絕，以及正常解除安裝後還原原檔。

傳統 Proxy DLL 型可攜式套件仍可用下列命令建置：

```powershell
powershell -ExecutionPolicy Bypass -File simhub\tools\Build-ReadyToUsePackage.ps1
```

輸出為 `simhub/dist/FFBInterceptor-ReadyToUse-0.2.0.zip`。使用者解壓縮後執行
`Install-FFBInterceptor.cmd`，安裝器會要求選取遊戲 EXE、自動判斷 x86／x64、
備份既有 `dinput8.dll`、安裝 SimHub 外掛，並開啟兩個儀表板匯入檔。配套的
解除安裝器會驗證已安裝檔案的雜湊後才還原備份。詳見
[傳統 Proxy DLL 可攜版操作說明](simhub/PORTABLE.zh-TW.md)。

削峰偵測預設在命令值達 98% 時進入候選狀態，低於 95% 時準備解除；連續飽和
100 ms，或最近 1 秒內有 5% 的時間飽和，就會觸發削峰，低於 95% 持續 500 ms 後
解除。這是 `DI_FFNOMINALMAX` 的 DirectInput 命令飽和判定，不代表馬達的實際扭力。
Constant、Ramp 與 Periodic 效果可參與判定。Condition 與 Custom 效果仍會計數，但
不納入削峰結論，因為只靠目前參數無法還原它們的實際出力。

外掛提供設定頁、SimHub properties、削峰開始／結束事件、跨資料來源的
`AnyClipping`，以及 800×480 儀表板與 480×160 高對比覆疊顯示。

## 通訊協定

Protocol v1 使用明確的小端序（little-endian）32 位元組標頭，以及不含指標、長度
受限的承載資料（payload）。每個訊框（frame）上限為 64 KiB、最多八個軸。未知或
自訂效果只攜帶 GUID、宣告長度，以及是否已遮罩／截短的旗標。詳見
[Protocol v1](docs/protocol-v1.md)、[安全模型](docs/security-model.md) 與
[trace 格式](docs/trace-format.md)。

## 驗證與發行來源

Windows CI 矩陣會建置並測試 x86／x64 Proxy DLL 與啟動器／Hook、Python 3.12／3.13、
net48 削峰核心，以及兩個儀表板結構描述（schema）。合成效能門檻要求 telemetry
queue hot path 在每秒 1,000+ 事件下 p99 小於 100 微秒、具名管道 ingestion 在相同
事件率下 p99 小於 5 毫秒，Qt 更新路徑則必須在 60 Hz 計時器運作時保有 30 FPS 的
畫面更新預算。

具名管道測試會使用實際 current-user DACL、分段寫入、重新連線與核心回報的 Hello PID
驗證。安全工作流程另以 gitleaks 掃描完整 Git 歷史，並用 actionlint 與 zizmor 檢查
所有 GitHub Actions workflow。

正式發行只能從既有的 `vX.Y.Z` tag 建置。CI 會 checkout 該 tag，再核對 tag commit、
CMake 專案版本與 Python 檢視器版本，最後才建置、封存並產生建置來源證明
（provenance attestation）。詳見 [發行流程](docs/release-process.md)。

## 貢獻方式與授權

請參考 [CONTRIBUTING.md](CONTRIBUTING.md)、[SECURITY.md](SECURITY.md) 與
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。本專案依
[GNU GPLv3](LICENSE) 授權發行。上游聲明保留於
[`licenses/upstream-dcs-force-feedback-fix-MIT.txt`](licenses/upstream-dcs-force-feedback-fix-MIT.txt)
及 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 目前狀態

v0.2.0 是預發行版本，標示為 **UNSIGNED EXPERIMENTAL（未經數位簽章的實驗版）**。發行門檻
以合成的通訊協定與佇列測試為主。除非附有明確授權及可重現證據，實體硬體或商業遊戲
測試結果都不代表本專案做出相容性保證。
