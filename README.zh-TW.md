# FFB Interceptor + Visualizer（繁體中文）

這是一個 Windows 實驗性工具，觀察遊戲經 DirectInput8 傳出的力回饋命令
與效果參數，並在 viewer 即時顯示；每個 DirectInput 呼叫與 HRESULT 都原樣
轉發。圖表的 **Command Peak/RMS** 只代表選定 API 通道的命令值，不是方向盤
馬達扭力量測。

v0.1.0 提供 C++17 的 x86/x64 `dinput8.dll` proxy，以及 Python 3.12+、
PySide6/pyqtgraph 的 x64 viewer。proxy 源自
[walmis/dcs-force-feedback-fix](https://github.com/walmis/dcs-force-feedback-fix)
v0.2（MIT）並保留完整歷史；新增程式採 GPL-3.0-only。

目前只支援由 `DirectInput8Create` 建立的 DirectInput8 FFB；GameInput、WinRT、
XInput、私有 SDK、反作弊規避、線上競技、驅動／HID hook、記憶體掃描、網路服務、
SimHub 與實際扭力量測均不在 v0.1 範圍。iRacing 明列不支援，這是支援政策，並非
GPL 額外用途限制。

高扭力 wheelbase 可能突然動作：先把 gain 設為最低、離線測試並保持手部遠離。遊戲
資料夾若已有 `dinput8.dll`，絕對不要覆寫；先備份並在移除時還原原檔。啟動失敗時
刪除本 proxy 與 viewer 即可回復系統 DLL。

viewer 提供 producer／device／effect 篩選、1／5／10／30 秒視窗、Magnitude／
Ramp／Periodic 通道切換、暫停、事件標記與原始參數面板。資料只留在有界記憶體
佇列；按下 `Export CSV`、`Export PNG` 或 `Save .ffbtrace` 後才會由使用者主動
保存。`.ffbtrace` 是版本化格式，只含相對時間、行程內 stable ID 與已遮罩的命令
欄位，不含完整路徑、序號、帳號或主機名。

proxy 的 A/W COM 介面共用控制區塊，跨介面 `QueryInterface(IUnknown)`、AddRef
與 Release 維持同一個 identity 與 refcount；aggregation 與未知介面則原樣轉發。

建置與執行指令請見英文 [README.md](README.md)。協定、安全模型與貢獻規範分別見
[docs/protocol-v1.md](docs/protocol-v1.md)、[docs/security-model.md](docs/security-model.md)、
[docs/trace-format.md](docs/trace-format.md)、[CONTRIBUTING.md](CONTRIBUTING.md)。
