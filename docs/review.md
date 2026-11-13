# Source review guide

## Scope

Classic Companion is a SwiftUI/AppKit/WKWebView wrapper for the official ChatGPT site. This public tree contains the app, its tests, required icons, four-language beta-note templates and build tooling. It starts with a new Git history; internal development records, poster sources and screenshots are excluded.

## Suggested review order

1. `Package.swift` and App/AppDelegate: package structure, lifecycle and single-instance behavior.
2. Web/WebRuntime, CompanionCore/NavigationPolicy and Adapter: allowed navigation, popups/downloads, isolated scripts and message origin validation.
3. CompanionCore/Redactor and Diagnostics: URL redaction and accidental information exposure. The debug-only driver is opt-in via a local preference, allows local notification-driven UI actions, and is excluded from release builds. Keep it disabled for ordinary use.
4. CompanionCore/LoadRecovery and its core/web tests: failed/last URL, allowed retry destinations, 2/5/15/30/60-second backoff with at most five retries, cancellation, offline/online transitions, reload and wake behavior.
5. Window, Hotkey, UI and Localization: focus, IME/Esc, minimizing/restoring, displays, four-language consistency and accessibility.

Privacy descriptions are implementation goals to inspect, not an independent security audit. There are no external Swift package dependencies declared in Package.swift. This does not license Apple's frameworks or OpenAI's website content.

## Verification

Public-tree validation results are recorded in [verification.md](verification.md). The source includes the first-load recovery fix; 0.1.0-beta.2 (20261113.1719) is the first published build that contains it, and 0.1.0-beta.1 (20261110.0137) predates it. Installers are published separately as Releases.

Prior isolated-copy acceptance recorded six proxy-simulated network checks: offline launch/reconnection, reload button and command, backoff/exhaustion, disconnection after a page is present, wake versus mode-switch behavior, and reload while the first load is pending. Those prior checks are not a new live acceptance run of this public export.

Still unverified: actual system Wi-Fi disconnection signals, reboot/login-item startup, a Developer ID signed and notarized build of this tree, macOS 15/26, other Macs, and physical keyboard/mouse input (prior acceptance used automation). Read Aloud transitions, some image/interactive components, long-chat scrolling, minimized-window recovery and localization details remain documented in the [beta notes](trial-notes.en.md).

## 日本語

README の手順でビルドとテストを行い、ナビゲーション・診断のプライバシー境界、読み込み復旧、ウインドウ操作と入力を重点的に確認してください。検証結果は verification.md にあります。公開済みインストーラーには復旧修正が含まれていません。実際の Wi-Fi 切断、再起動からの自動起動、署名・公証済み構成などは未検証です。

## 中文

按 README 构建测试，重点检查导航和诊断的隐私边界、加载恢复、窗口与输入行为。验证结果见 verification.md。公开安装包尚不包含恢复修复；真正关闭 Wi-Fi、重启后的登录项启动、签名公证构建等仍未验收。

## Feedback

Include commit SHA, OS/toolchain, reproduction steps, expected/actual results and relevant file/line. Use redacted diagnostics and synthetic conversations. Code review is not company deployment approval.
