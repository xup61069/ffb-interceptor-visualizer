# FFB Interceptor + Visualizer（繁體中文）

這是一個 Windows 實驗性工具，觀察遊戲經 DirectInput8 傳出的力回饋命令
與效果參數，並在 viewer 即時顯示；每個 DirectInput 呼叫與 HRESULT 都原樣
轉發。圖表的 **Command Peak/RMS** 只代表選定 API 通道的命令值，不是方向盤
馬達扭力量測。

v0.2.0 提供 C++17 的 x86/x64 `dinput8.dll` proxy、Python 3.12+
PySide6/pyqtgraph viewer，以及 .NET Framework 4.8 的 SimHub 外掛。proxy 源自
[walmis/dcs-force-feedback-fix](https://github.com/walmis/dcs-force-feedback-fix)
v0.2（MIT）並保留完整歷史；新增程式採 GPL-3.0-only。

目前只支援由 `DirectInput8Create` 建立的 DirectInput8 FFB；GameInput、WinRT、
XInput、私有 SDK、反作弊規避、線上競技、驅動／HID hook、記憶體掃描、網路服務與
實際扭力量測均不在支援範圍。iRacing 明列不支援，這是支援政策，並非
GPL 額外用途限制。

高扭力 wheelbase 可能突然動作：先把 gain 設為最低、離線測試並保持手部遠離。遊戲
資料夾若已有 `dinput8.dll`，絕對不要覆寫；先備份並在移除時還原原檔。啟動失敗時
刪除本 proxy 與 viewer 即可回復系統 DLL。

提供 `FFBInterceptor-ReadyToUse-*.zip` 時，使用者可解壓後雙擊
`Install-FFBInterceptor.cmd`，選取遊戲 EXE。安裝器會判斷 x86/x64、備份既有 DLL、
安裝 SimHub 外掛並開啟 Dashboard 匯入檔；解除安裝以
`Uninstall-FFBInterceptor.cmd` 執行。流程與限制見
[simhub/PORTABLE.zh-TW.md](simhub/PORTABLE.zh-TW.md)。

viewer 提供 producer／device／effect 篩選、1／5／10／30 秒視窗、通道與 Condition
軸切換、暫停、事件標記與原始參數面板。通道包含 Constant、Ramp、Periodic 的所有
已觀察參數，以及 Condition 的 offset、coefficient、saturation、deadband；缺少的
參數會顯示為沒有樣本，不會合成虛構力值。資料只留在有界記憶體佇列；按下
`Export CSV`、`Export PNG` 或 `Save .ffbtrace` 後才會由使用者主動保存。
`.ffbtrace` 是版本化格式，只含相對時間、行程內 stable ID 與已遮罩的命令欄位，
不含完整路徑、序號、帳號或主機名。
CSV 匯出另含受界限的 producer basename 與 process ID，讓多個 producer 同時選取時
仍可辨識 device/effect ID。

proxy 的 A/W COM 介面共用控制區塊，跨介面 `QueryInterface(IUnknown)`、AddRef
與 Release 維持同一個 identity 與 refcount；aggregation 與未知介面則原樣轉發。

SimHub 外掛與 Python viewer 可同時運作。proxy 分別寫入
`\\.\pipe\ffb-interceptor-v1` 與
`\\.\pipe\ffb-interceptor-simhub-v1`；兩端各有獨立的固定 queue、worker、
drop counter 與重連路徑。削峰預設在命令達 98% 時進入、低於 95% 時準備解除，
連續碰頂 100 ms 或最近 1 秒碰頂比例達 5% 即觸發，低於 95% 持續 500 ms 後解除。
這是 `DI_FFNOMINALMAX` 命令飽和判定，不是馬達扭力。外掛提供設定頁、properties、
開始／結束事件、跨 producer 的 `AnyClipping`，以及 800×480 Dashboard 和
480×160 高對比 Overlay。安裝與 property 清單見 [simhub/README.md](simhub/README.md)。
多執行緒 DirectInput 呼叫會以嚴格遞增序列提交到兩端；SimHub 會拒絕重複或倒退
的封包。遊戲失焦而成功 `Unacquire` 或回報 acquisition loss 時也會停止舊效果
狀態，避免殘留假削峰。

Windows CI 會測試 x86／x64 proxy、Python 3.12／3.13、net48 削峰核心與
Dashboard schema。合成門檻要求 proxy
queue hot path 在每秒 1,000+ 事件時 p99 小於 100 微秒、Named Pipe ingestion
p99 小於 5 毫秒，並確認 Qt 計時器以 60 Hz 更新且介面路徑保有至少 30 FPS
frame budget。pipe 測試使用實際 current-user DACL、fragmented 寫入、重連與
kernel 回報的 Hello PID 驗證。Security workflow 另會以 gitleaks 掃描完整 Git
歷史，並以 actionlint 與 zizmor 稽核所有 Actions workflow。

release 只會由既有 `vX.Y.Z` tag 建置：CI 會 checkout 該 tag，確認 tag commit
及兩個 package 版本，再產生 archive 與 provenance attestation。詳見
[docs/release-process.md](docs/release-process.md)。

建置與執行指令請見英文 [README.md](README.md)。協定、安全模型與貢獻規範分別見
[docs/protocol-v1.md](docs/protocol-v1.md)、[docs/security-model.md](docs/security-model.md)、
[docs/trace-format.md](docs/trace-format.md)、[CONTRIBUTING.md](CONTRIBUTING.md)。
