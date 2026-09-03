# 變更紀錄

版本號描述產品版本；Release 的 Stable／Experimental 標示另外描述 Authenticode
簽章與啟動政策。

## 1.0.0 - 2026-09-03

- 發布首個 1.x 產品版本，整合 DirectInput8 Protocol v1 遙測、SimHub 外掛與圖表。
- 提供不在遊戲資料夾放置或修改 `dinput8.dll` 的 x86／x64 Launcher、Hook 與
  `FFBInterceptor.Manager.exe` 一鍵流程。
- 提供 SimHub 9.11.22 指紋綁定外掛，以及同裝置多效果的保守削峰偵測、遲滯、持續
  時間／視窗判定與資料可靠性狀態。
- 補齊固定資產清單、SHA-256、CycloneDX／SPDX SBOM、GitHub provenance attestation、
  immutable Release 與不可移動／刪除的 `v*` tag 防護。
- 修正 Windows PowerShell 5.1 直接執行 SimHub SDK 驗證腳本時，預設 fingerprint 路徑
  可能在參數繫結階段解析為空值的問題。

本版完整 Launcher 頻道為未簽章 Experimental。它可即開即用，但不是 Authenticode
Stable，也不代表已完成所有商業遊戲、反作弊環境或實體方向盤驗證。
