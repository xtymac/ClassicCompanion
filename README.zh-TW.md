# Classic Companion

[English](README.md) · [日本語](README.ja.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md)

<img src="assets/icon/AppIcon-1024.png" alt="Classic Companion 應用程式圖示" width="80">

**按下快速鍵，就能在原生 macOS 視窗中使用 ChatGPT。**

以 SwiftUI、AppKit 和 WKWebView 顯示 ChatGPT 官方網站。預設 `⌥ Space` 喚出小視窗，`⌃⌘F` 切換完整視窗，提供自訂快速鍵、登入狀態保留、頁面縮放，以及繁體中文、簡體中文、英文和日文介面。對話與朗讀由官方網站提供；這是與 OpenAI 無隸屬關係的獨立應用程式。

這是採用 [Apache-2.0](LICENSE) 的**公開原始碼儲存庫**。下載及使用者意見仍放在 [ClassicCompanion](https://github.com/mactokyo/ClassicCompanion)。

## 審查與驗證

架構、驗證結果與未驗證項目見[審查指南](docs/review.md)。原始碼包含首次離線載入復原修正，已發布 beta v0.1.0-beta.1（20261110.0137）不包含此修正。

## 建置與測試

需要 Apple silicon Mac、macOS 15 以上及支援 Swift 6 的完整 Xcode。本次驗證環境為 Xcode 27.2 / Swift 6.4.2 / macOS 27.2；其他工具鏈與最低系統版本尚未驗證。

```sh
git clone https://github.com/mactokyo/ClassicCompanion-App.git
cd ClassicCompanion-App
xcodebuild -version
swift --version
swift test
CC_SIGNING_MODE=adhoc scripts/build-app.sh debug
open "build/$(cat build/LATEST)/Classic Companion.app"
```

請在已登入的 macOS 桌面工作階段執行 `swift test`。部分測試會建立 AppKit 視窗及載入合成頁面的實際 WKWebView，視窗測試會短暫顯示視窗，執行期間請勿輸入。自動測試不需要 ChatGPT 登入；官方網站的手動驗收需要網路與 ChatGPT 帳號。

debug 使用 ad-hoc 簽署，不需要維護者的發布憑證或公證認證資料，僅供本機審查。啟動前先結束已安裝版本：相同 Bundle ID 會共用設定與 WebKit 登入資料；需要隔離時請使用另一個 macOS 使用者。每次輸出至新的 `build/<時間戳記>/`，同一分鐘重複建置會被拒絕。

## 原始碼結構

| 路徑 | 內容 |
| --- | --- |
| `Sources/ClassicCompanion/` | 啟動、視窗、快速鍵、WKWebView、DOM 適配、語言及診斷 |
| `Sources/CompanionCore/` | 導覽策略、URL 去識別化、縮放及載入復原 |
| `Tests/` | 核心邏輯、語言、原生 UI 與合成網頁測試 |
| `scripts/` | 本機建置、發布封裝、公證及驗證 |
| `assets/` | 應用程式圖示及設計資源 |

## 已知限制

官方網站 DOM 變更可能影響網頁增強；首次離線載入後的復原已在原始碼中修正，但尚未納入已發布版本，系統離線訊號（實際關閉 Wi-Fi）及登入時的實際啟動仍未驗證。圖片預覽、互動元件、朗讀切換、長對話捲動及部分視窗、輸入法行為仍需確認。尚未驗證 macOS 15/26、全新使用者和單螢幕全螢幕情境；不支援 Intel。完整問題見[試用版說明](docs/trial-notes.zh-Hant.md)及 review 指南。


## 貢獻與授權

請閱讀[貢獻說明](CONTRIBUTING.md)、[品牌說明](BRANDING.md)及[發布設定](docs/release-signing.md)。程式碼和隨附素材採用 Apache-2.0；不授予商標權。
