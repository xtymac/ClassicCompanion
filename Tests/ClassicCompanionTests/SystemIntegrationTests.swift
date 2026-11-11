import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ClassicCompanion

/// Dock、⌘Tab、Finder 再次打开这些入口背后的决策。实际系统行为要在真实安装包上验证，这里不能代替。
final class SystemIntegrationTests: XCTestCase {
    // MARK: - 找回窗口

    func testRevealRestoresHiddenWindow() {
        XCTAssertEqual(ChatWindowController.revealAction(visible: false, miniaturized: false, shownAndActive: false), .restore)
    }

    func testRevealRestoresMinimizedWindow() {
        // 最小化的窗口可能仍报告可见：⌘Tab 切入时用户同样看不到它。
        XCTAssertEqual(ChatWindowController.revealAction(visible: true, miniaturized: true, shownAndActive: false), .restore)
    }

    func testRevealOnlyActivatesVisibleWindow() {
        XCTAssertEqual(ChatWindowController.revealAction(visible: true, miniaturized: false, shownAndActive: false), .activate)
    }

    func testRevealLeavesWindowAloneWhenAlreadyInFront() {
        XCTAssertEqual(ChatWindowController.revealAction(visible: true, miniaturized: false, shownAndActive: true), .none)
    }

    // MARK: - 聊天窗口

    /// 聊天窗口是 NSPanel（见 orderIntoActiveSpace），但其余行为必须和普通窗口一样。
    @MainActor private func makeChatWindow() throws -> ChatWindow {
        let controller = ChatWindowController(webView: WKWebView(), toolbar: EmptyView(), diagnostics: Diagnostics())
        addTeardownBlock { @MainActor in controller.window?.orderOut(nil) }
        return try XCTUnwrap(controller.window as? ChatWindow)
    }

    @MainActor func testChatWindowStaysVisibleWhenAppDeactivates() throws {
        XCTAssertFalse(try makeChatWindow().hidesOnDeactivate)
    }

    @MainActor func testChatWindowCanBecomeMain() throws {
        // 面板默认不能成为主窗口；窗口菜单和“关闭窗口”菜单项都要用到主窗口。
        XCTAssertTrue(try makeChatWindow().canBecomeMain)
    }

    @MainActor func testChatWindowIsNotFloating() throws {
        let window = try makeChatWindow()
        XCTAssertFalse(window.isFloatingPanel)
        XCTAssertEqual(window.level, .normal)
    }

    @MainActor func testChatWindowIsListedInWindowMenu() throws {
        XCTAssertFalse(try makeChatWindow().isExcludedFromWindowsMenu)
    }

    /// 主队列先进先出：这里排的块执行时，之前排的块已经执行完。
    @MainActor private func waitForNextRunLoopTurn() {
        let turn = expectation(description: "下一轮 run loop")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 1)
    }

    @MainActor func testOrderingIntoActiveSpaceLeavesAnOrdinaryActivatingWindow() throws {
        let window = try makeChatWindow()
        window.orderIntoActiveSpace {}
        XCTAssertTrue(window.isVisible)
        waitForNextRunLoopTurn()
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
    }

    /// 同一轮里激活，进入全屏后的第一次唤醒每次都被系统搬到另一块屏幕。
    @MainActor func testActivationWaitsUntilTheWindowHasEnteredTheSpace() throws {
        let window = try makeChatWindow()
        var activations = 0
        window.orderIntoActiveSpace { activations += 1 }
        XCTAssertEqual(activations, 0)
        waitForNextRunLoopTurn()
        XCTAssertEqual(activations, 1)
    }

    @MainActor func testHidingBeforeActivationCancelsIt() throws {
        let window = try makeChatWindow()
        var activations = 0
        window.orderIntoActiveSpace { activations += 1 }
        window.orderOut(nil)
        waitForNextRunLoopTurn()
        XCTAssertEqual(activations, 0)
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
    }

    // MARK: - 单实例

    private func instance(_ pid: pid_t, _ seconds: TimeInterval?) -> SingleInstance.Candidate {
        SingleInstance.Candidate(pid: pid, launchDate: seconds.map(Date.init(timeIntervalSince1970:)))
    }

    func testEarliestInstanceSurvives() {
        let first = instance(900, 100), second = instance(200, 200)
        XCTAssertEqual(SingleInstance.survivor(among: [second, first]), first)
    }

    func testPidBreaksLaunchTimeTies() {
        // 两边同时启动时必须得出同一个结论，否则可能都退出或都留下。
        let low = instance(200, 100), high = instance(900, 100)
        XCTAssertEqual(SingleInstance.survivor(among: [high, low]), low)
        XCTAssertEqual(SingleInstance.survivor(among: [low, high]), low)
    }

    func testInstanceWithKnownLaunchTimeBeatsUnknown() {
        let known = instance(900, 100), unknown = instance(200, nil)
        XCTAssertEqual(SingleInstance.survivor(among: [unknown, known]), known)
    }

    func testAloneInstanceSurvives() {
        let only = instance(500, 100)
        XCTAssertEqual(SingleInstance.survivor(among: [only]), only)
    }

    // MARK: - Bundle 信息

    func testVersionAndBuildComeFromBundleInfo() {
        let info = AppInfo(infoDictionary: ["CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "20301231.2359"])
        XCTAssertEqual(info.version, "9.8.7")
        XCTAssertEqual(info.build, "20301231.2359")
        XCTAssertEqual(info.summary, "9.8.7 (20301231.2359)")
    }

    func testUnbundledRunDoesNotInventAVersion() {
        let info = AppInfo(infoDictionary: nil)
        XCTAssertEqual(info.summary, "dev (unbundled)")
    }

    func testPlaceholderIconIsReportedFromBundleInfo() {
        XCTAssertTrue(AppInfo(infoDictionary: ["CCIconStatus": "placeholder"]).usesPlaceholderIcon)
        XCTAssertFalse(AppInfo(infoDictionary: ["CCIconStatus": "final"]).usesPlaceholderIcon)
        XCTAssertFalse(AppInfo(infoDictionary: nil).usesPlaceholderIcon)
    }

    func testFeedbackTextCarriesVersionBuildAndSystem() {
        let info = AppInfo(infoDictionary: ["CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "20301231.2359"])
        let text = info.feedbackText(system: "macOS 27.2", architecture: "arm64")
        for part in ["Classic Companion", "9.8.7", "20301231.2359", "macOS 27.2", "arm64"] {
            XCTAssertTrue(text.contains(part), part)
        }
    }

    func testFeedbackGoesToGitHubIssuesAndTrialNotesSayTheSame() throws {
        // 用户 2026-11-08 建好公开仓库并开了 Issues。改地址时两处一起改。
        XCTAssertEqual(AppInfo.feedbackURL?.absoluteString, "https://github.com/xtymac/ClassicCompanion/issues")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let notes = try String(contentsOf: root.appendingPathComponent("docs/trial-notes.md"), encoding: .utf8)
        XCTAssertTrue(notes.contains("https://github.com/xtymac/ClassicCompanion/issues"))
        XCTAssertFalse(notes.contains("尚未确定"), "verify-release.sh --final 会拦下")
    }

    // MARK: - 试用版说明

    func testTrialNotesSplitsHeadingsAndBody() {
        let blocks = TrialNotes.blocks(from: "# 标题\n\n说明 **重点**\n\n## 小节\n1. 第一项\n")
        XCTAssertEqual(blocks, [.title("标题"), .body("说明 **重点**"), .heading("小节"), .body("1. 第一项")])
    }

    func testTrialNotesFromBundleWithoutResourceIsNil() {
        for language in AppLanguage.allCases {
            XCTAssertNil(TrialNotes.text(language, in: Bundle(for: Self.self)))
        }
    }

    /// 每种界面语言的说明在 docs/，build-app.sh 按语言生成 TrialNotes.<语言>.md（文件名和签名句子与脚本一致）。
    func testTrialNotesExistInEveryLanguageWithTheSameFeedbackAddress() throws {
        let sources: [AppLanguage: String] = [.simplifiedChinese: "trial-notes.md", .traditionalChinese: "trial-notes.zh-Hant.md",
                                              .english: "trial-notes.en.md", .japanese: "trial-notes.ja.md"]
        XCTAssertEqual(Set(sources.keys), Set(AppLanguage.allCases), "每种界面语言都要有说明")
        // ad-hoc 构建由 build-app.sh 把这句换成“没有签名和公证”，句子改了要同步脚本。
        let signed: [AppLanguage: String] = [
            .simplifiedChinese: "本版使用 Developer ID 签名，并经过 Apple 公证。",
            .traditionalChinese: "本版使用 Developer ID 簽署，並經過 Apple 公證。",
            .english: "This build is signed with Developer ID and notarized by Apple.",
            .japanese: "このビルドは Developer ID で署名され、Apple の公証を受けています。",
        ]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        for language in AppLanguage.allCases {
            let notes = try String(contentsOf: root.appendingPathComponent("docs/\(sources[language]!)"), encoding: .utf8)
            XCTAssertTrue(notes.contains("https://github.com/xtymac/ClassicCompanion/issues"), "\(language)")
            XCTAssertTrue(notes.contains("{{VERSION}}") && notes.contains("{{BUILD}}"), "\(language) 版本和构建号由构建脚本填")
            XCTAssertTrue(notes.contains(signed[language]!), "\(language)")
            XCTAssertTrue(script.contains(signed[language]!), "\(language) build-app.sh 要能把签名句改掉")
            XCTAssertTrue(script.contains(sources[language]!) && script.contains(TrialNotes.resourceName(language)), "\(language)")
            for unsettled in ["尚未确定", "尚未確定", "临时占位", "暫時佔位", "TBD", "未定"] { XCTAssertFalse(notes.contains(unsettled), "\(language) \(unsettled)") }
        }
    }

    /// ad-hoc 构建按整段替换签名说明；脚本里的整段和说明里的不一致时，build-app.sh 会在构建时才报错。这里提前核对。
    func testBuildScriptSignedParagraphsMatchTheTrialNotesExactly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        let sources = ["TrialNotes.zh-Hans.md": "trial-notes.md", "TrialNotes.zh-Hant.md": "trial-notes.zh-Hant.md",
                       "TrialNotes.en.md": "trial-notes.en.md", "TrialNotes.ja.md": "trial-notes.ja.md"]
        let pattern = try NSRegularExpression(pattern: #"^  SIGNED\[(TrialNotes\.[A-Za-z-]+\.md)\]='([^']*)'$"#, options: .anchorsMatchLines)
        let matches = pattern.matches(in: script, range: NSRange(script.startIndex..., in: script))
        XCTAssertEqual(matches.count, 4)
        for m in matches {
            let target = String(script[Range(m.range(at: 1), in: script)!])
            let paragraph = String(script[Range(m.range(at: 2), in: script)!])
            let notes = try String(contentsOf: root.appendingPathComponent("docs/\(try XCTUnwrap(sources[target]))"), encoding: .utf8)
            XCTAssertTrue(notes.components(separatedBy: "\n").contains(paragraph), "\(target) 的签名说明段和 build-app.sh 不一致")
        }
    }
}
