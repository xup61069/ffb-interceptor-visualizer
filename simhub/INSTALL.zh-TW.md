# FFB Interceptor SimHub 外掛

## 安裝

1. 關閉 SimHub。
2. 將 `FFBInterceptor.SimHub.dll` 與 `FFBInterceptor.Core.dll` 複製到 SimHub 安裝目錄（通常是 `C:\Program Files (x86)\SimHub`）。
3. 啟動 SimHub，在 **Settings → Plugins** 啟用 **FFB Interceptor**。
4. 雙擊所需的 `.simhubdash` 匯入 800×480 Dashboard 或 480×160 Overlay。
5. 把本專案對應位元數的 `dinput8.dll` 放到遊戲執行檔旁；既有 Python viewer 可同時開啟。

請先啟動 SimHub 與外掛，再啟動遊戲，讓偵測器從完整效果生命週期開始接收。
若 Dashboard 顯示 `DATA GAP`，代表 proxy 已回報掉幀；外掛會捨棄可能過期的
效果狀態以避免誤報，重新啟動遊戲即可建立可信的新 session。

外掛監聽 `\\.\pipe\ffb-interceptor-simhub-v1`，Python viewer 仍使用原本的
`\\.\pipe\ffb-interceptor-v1`。兩條 pipe 有獨立 queue 與傳送執行緒，任一消費端停滯不會拖慢另一端。

## 預設削峰條件

- 進入門檻：98%
- 離開門檻：95%
- 連續碰頂 100 ms，或最近 1 秒內碰頂比例達 5%
- 降到 95% 以下持續 500 ms 後解除

判定的是遊戲送入 DirectInput 的命令訊號是否碰到 `DI_FFNOMINALMAX`，不是方向盤馬達的實際扭力。Constant、Ramp 與 Periodic 效果納入判定；Condition 與 Custom 效果仍會列入統計，但不會在資訊不足時硬判為削峰。
遊戲成功呼叫 `Unacquire`，或 proxy 在輪詢時偵測到 acquisition loss（常見於
失焦或切到背景）時，外掛會停止該裝置的播放狀態，避免留下假的削峰警示；後續
`Start` 仍可沿用已保存的效果參數。

## 來源選擇與事件

預設自動選擇最近有活動的 producer。也可在外掛設定頁以 PID／Session ID 固定來源；`FFBInterceptor.AnyClipping` 會跨所有已連線來源彙總。

SimHub 事件：

- `FFBInterceptor.ClippingStarted`
- `FFBInterceptor.ClippingEnded`
- `FFBInterceptor.SourceConnected`
- `FFBInterceptor.SourceDisconnected`

`ClippingStarted`／`ClippingEnded` 是全域 `AnyClipping` 邊緣事件：第一個來源開始
削峰時觸發一次，最後一個來源解除後才觸發結束。

可在 SimHub 的事件／控制映射中自行配置聲音或其他動作，外掛不會強制播放提示音。
