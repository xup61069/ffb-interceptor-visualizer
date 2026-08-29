# 即開即用安裝包

此 ZIP 不需要安裝 Visual Studio、.NET SDK 或手動挑選 x86/x64 DLL。解壓縮後，雙擊
`Install-FFBInterceptor.cmd`，在跳出的視窗選擇遊戲的主程式 `.exe`；安裝器會：

1. 讀取 EXE 的位元數並選擇正確的 `dinput8.dll`。
2. 把遊戲資料夾既有的同名 DLL 移到唯一的
   `dinput8.dll.ffb-interceptor-backup*` 備份檔，再寫入本工具 DLL。
3. 安裝兩個 SimHub 外掛 DLL 到偵測到的 SimHub 目錄，並同樣保留既有同名檔案的備份。
4. 開啟兩個 `.simhubdash`，讓 SimHub 匯入完整 Dashboard 與 Overlay。
5. 將安裝狀態保存在目前 Windows 使用者的
   `%LOCALAPPDATA%\FFBInterceptor\install-state.json`，以便安全解除安裝。

出現 UAC 視窗時請允許，因為預設 SimHub 安裝在 `Program Files`。安裝後，開啟 SimHub，
在 **Settings → Plugins** 啟用 **FFB Interceptor**，最後才啟動遊戲。

## 解除安裝

關閉遊戲和 SimHub 後，雙擊 `Uninstall-FFBInterceptor.cmd`，再選擇相同的遊戲 EXE。
程式只會刪除雜湊值仍與安裝包相同的檔案；若 DLL 曾被其他工具更新，會停止並保留該檔，
避免誤刪。原有 `dinput8.dll` 與 SimHub 外掛會從備份還原。

可用同一個安裝包依序安裝多個遊戲；SimHub 外掛會保留到最後一個遊戲解除安裝時才移除。

## 注意事項

- 只支援 DirectInput8 的 x86/x64 遊戲，不支援 iRacing、GameInput、XInput、WinRT 或私有 SDK。
- `dinput8.dll` 可能和其他模組衝突。安裝器會備份，但請先以離線模式測試。
- 這是遊戲 FFB 命令的削峰判定，不是方向盤馬達的實際扭力；先把 wheelbase gain 降低。
- ZIP 為未簽章的實驗性軟體。僅從專案 GitHub Release 或可信的校驗碼來源取得。
