# FFB Interceptor 不改遊戲 DLL 版

> **未簽章實驗版，只供離線／單機測試。** 不要用於反作弊、受保護或線上競技遊戲。
> 高扭力方向盤可能突然動作；先把 gain 調到最低、保持手部遠離並準備實體急停。

這個 ZIP **不含 `dinput8.dll`**，也不會在遊戲資料夾新增、覆寫、改名或刪除檔案。
它只會把兩個 FFB Interceptor 外掛 DLL 安裝到 SimHub 目錄。

## 第一次使用

1. 解壓整個 `FFBInterceptor-Launcher-*.zip`，不要直接在 ZIP 裡執行。
2. 關閉 SimHub。
3. 雙擊 `Start-FFBInterceptor.cmd`。
4. Windows 詢問權限時按「是」；這次提權只用來安裝 SimHub 外掛，不會啟動遊戲。
5. SimHub 開啟後，到 **Settings → Plugins** 啟用 **FFB Interceptor**。
6. 依 SimHub 畫面匯入隨包附上的 Dashboard／Overlay。
7. 關閉第一次設定提示，再雙擊一次 `Start-FFBInterceptor.cmd`。

## 平常怎麼啟動

1. 雙擊 `Start-FFBInterceptor.cmd`。
2. 選擇真正的離線遊戲 `.exe`。
3. 程式會自動判斷 x86／x64、等待 SimHub 外掛準備完成，再啟動遊戲。
4. 在 SimHub 開啟 **FFB Interceptor 800x480** 或 **FFB Interceptor Overlay 480x160**。

請用一般使用者權限啟動；若以系統管理員身分執行，啟動器會基於安全理由拒絕啟動遊戲。

## 「不改 DLL」實際代表什麼

- ZIP 內沒有 `dinput8.dll`。
- 遊戲 EXE 與遊戲資料夾的 DLL 都不會被寫入或替換。
- 啟動器只能建立一個新的子程序，不能輸入既有 PID，也不能指定其他 DLL。
- 執行時會把同資料夾、同位元數的固定 `FFBInterceptor.Hook.dll` 載入剛建立的遊戲程序。
- Windows 載入器完成後，啟動器會在遊戲入口點的**記憶體**暫放一個同步斷點；原位元組會在第一條遊戲指令執行前還原。
- Hook 只把尚未被其他元件修改的 `dinput8.dll!DirectInput8Create` IAT 指標換成攔截函式；遊戲結束後所有記憶體變更自然消失。

因此它是「不修改遊戲磁碟檔案」，不是「程序記憶體完全不變」。防毒或 SmartScreen 可能因未簽章與程序內 Hook 行為提出警告；不要為了執行而盲目關閉防護。

## 支援範圍與限制

- `--offline-only` 是使用者確認與本專案的支援政策，**不是防火牆，也不會替你斷網**。
- 不提供反作弊規避、隱匿、提權、任意程序注入或線上競技支援。
- 只支援 x86／x64 Windows 程式，以及標準匯入 `dinput8.dll!DirectInput8Create` 的 DirectInput8 路徑。
- 使用 `GetProcAddress` 動態取得函式、私有 loader、GameInput、XInput、WinRT 或專有 FFB SDK 的遊戲可能抓不到資料。
- 遊戲若先啟動另一個 launcher 再建立真正遊戲程序，目前不會自動追蹤下一層子程序。
- 後載入模組會在有限時間內重新檢查；很晚才載入 DirectInput 的特殊遊戲可能無法攔截。
- 削峰表示遊戲送出的 DirectInput 命令接近 `DI_FFNOMINALMAX`，不是方向盤馬達的實際扭力。

## 解除安裝

1. 關閉 SimHub。
2. 雙擊 `Uninstall-SimHubPlugin.cmd`。
3. 驗證完成後，它只會移除自己管理的 SimHub 外掛檔並還原安裝前備份。
4. 已匯入的 Dashboard 不會自動刪除；需要時請在 SimHub 內手動移除。
5. 最後可直接刪除整個解壓資料夾；遊戲資料夾不需要清理。

解除安裝器會核對安裝檔與備份的 SHA-256。若檔案已被其他程式修改，它會拒絕刪除，避免誤傷。

## 更新版本

若新 ZIP 顯示已安裝的是不同版本，先關閉 SimHub，雙擊舊包或目前包內的
`Uninstall-SimHubPlugin.cmd`，確認還原完成後，再從新 ZIP 執行
`Start-FFBInterceptor.cmd`。安裝器不會把舊版誤認成同版，也不會直接混用新舊 DLL。

## 常見問題

**顯示「SimHub plug-in pipe did not become ready」**
確認 SimHub 已開啟，並在 **Settings → Plugins** 啟用 **FFB Interceptor**，再重試。

**遊戲有啟動，但 Dashboard 沒資料**
確認選到真正的遊戲 EXE，而且遊戲使用標準 DirectInput8 FFB。若遊戲透過另一層 launcher、動態解析函式或使用其他輸入 API，這版可能不支援。

**Windows 阻擋執行**
這是未簽章實驗版。先核對發布頁提供的 SHA-256；若來源或雜湊不符，請不要執行。

**方向盤動作不正常**
立即使用實體急停、關閉遊戲並停止使用。本工具只觀察與轉送命令，不是硬體安全控制器。
