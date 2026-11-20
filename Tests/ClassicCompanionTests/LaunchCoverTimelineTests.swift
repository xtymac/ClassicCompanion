import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ClassicCompanion

/// 只有一个页面时启动画面的每一条规则，逐行钉住窗口写的日志和每一步之后窗口的样子。
/// 写好时先在改动之前的代码（启动画面的状态还是窗口一份）上跑过、全过，之后把这些状态搬到每页一份（PageLoadState）时
/// 日志和窗口必须一行不差：开始、加载完成、加载失败、到时限（已提交 / 还没提交）、到时限后等提交和兜底、上限、
/// 又开始一次、旧的兜底和计时不生效。
/// 启动画面结束那行最后的耗时每次不一样，换成同一个记号；不算跟着真实鼠标、键盘、屏幕写的行（LiveInputLogLines）。
/// WebKit 报的页面颜色和 LaunchColourTests 一样直接设 underPageBackgroundColor。这些测试不显示窗口。
@MainActor
final class LaunchCoverTimelineTests: XCTestCase {
    private let savedDark = NSColor(srgbRed: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x0E / 255.0, alpha: 1)
    /// 起始颜色：不是白色（见 LaunchColourTests.make(saved:reported:)）。
    private let blankDark = NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)

    private var web: WKWebView!
    private var controller: ChatWindowController!
    private var diagnostics: Diagnostics!

    /// 记下的页面颜色是 savedDark，网页视图报着 blankDark，没有启动画面。
    private func make() {
        let name = "LaunchCoverTimelineTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = UserDefaults(suiteName: name)!
        let rgb = savedDark.usingColorSpace(.sRGB)!
        defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init), forKey: "pageBackgroundRGB")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        web.underPageBackgroundColor = blankDark
        diagnostics = Diagnostics()
        controller = ChatWindowController(webView: web, toolbar: EmptyView(), diagnostics: diagnostics,
                                          appearance: PageAppearance(defaults: defaults))
        addTeardownBlock { [controller] in controller?.window?.orderOut(nil) }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await pause(0.02) }
    }

    private var lines: [String] {
        LiveInputLogLines.compared(diagnostics.entries).map {
            "[\($0.category)] " + $0.message.replacingOccurrences(of: #"（\d+ms）$"#, with: "（…ms）", options: .regularExpression)
        }
    }

    /// 窗口的样子：启动画面、它的淡出那层、启动保护、提示。
    private var window: String {
        "启动画面=\(controller.isShowingLaunchScreen) 淡出=\(controller.launchFadeView != nil) "
            + "启动保护=\(controller.isHoldingPageColor) 提示=\(controller.shownLoadProblem.map { "\($0)" } ?? "无")"
    }

    private let hold = "[appearance] 启动保护：网页加载完成前不跟随页面底色（保持深色）"
    private let release = "[appearance] 启动保护解除：加载完成时报的是深色，等页面颜色变化再采用"

    private func limitLine(reveal: Int, cap: Int) -> String {
        "[launch] 启动画面到时限：网页还没提交，继续显示（等加载完成、失败、提交后 \(reveal)ms，最多到 \(cap) 秒）"
    }

    // MARK: - 时限之前

    /// 加载完成（应用里的顺序：先结束启动画面，再加载完成）。
    func testALoadThatFinishesInTime() {
        make()
        controller.beginLaunchScreen()
        XCTAssertEqual(window, "启动画面=true 淡出=false 启动保护=true 提示=无")
        XCTAssertEqual(lines, [hold])
        controller.endLaunchScreen("网页已加载")
        controller.pageDidFinishLoading()
        XCTAssertEqual(window, "启动画面=false 淡出=true 启动保护=false 提示=无")
        XCTAssertEqual(lines, [hold, "[launch] 启动画面结束：网页已加载（…ms）", release])
    }

    /// 加载失败（应用里的顺序：运行时先报“等待重试”，再结束启动画面）：启动保护不解除。
    func testALoadThatFailsInTime() {
        make()
        controller.beginLaunchScreen()
        controller.showLoadProblem(.waiting)
        controller.endLaunchScreen("加载失败")
        XCTAssertEqual(window, "启动画面=false 淡出=true 启动保护=true 提示=waiting")
        XCTAssertEqual(lines, [hold, "[launch] 启动画面结束：加载失败（…ms）"])
    }

    /// 到时限时已经提交：时限结束它。之后提交后的兜底到点不再做事。
    func testACommitBeforeTheLimitLetsTheLimitEndIt() async throws {
        make()
        controller.launchScreenLimit = 0.1
        controller.pageRevealLimit = 0.4
        controller.beginLaunchScreen()
        controller.pageDidCommit()
        XCTAssertEqual(window, "启动画面=true 淡出=false 启动保护=true 提示=无")
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertEqual(window, "启动画面=false 淡出=true 启动保护=true 提示=无")
        // 兜底在 0.4 秒到点；淡出那层 0.2 秒后自己拿掉。
        try await pause(0.6)
        try await waitUntil { controller.launchFadeView == nil }
        XCTAssertEqual(window, "启动画面=false 淡出=false 启动保护=true 提示=无")
        XCTAssertEqual(lines, [hold, "[launch] 启动画面结束：超过时限（…ms）"])
    }

    /// 时限之前提交、提交后的兜底先到点：启动画面不在等提交，兜底不结束它，照常由时限结束。
    func testACommitFallbackBeforeTheLimitDoesNotEndIt() async throws {
        make()
        controller.launchScreenLimit = 0.5
        controller.pageRevealLimit = 0.1
        controller.beginLaunchScreen()
        controller.pageDidCommit()
        // 兜底在 0.1 秒到点，时限在 0.5 秒。
        try await pause(0.3)
        XCTAssertEqual(window, "启动画面=true 淡出=false 启动保护=true 提示=无", "兜底不结束它")
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertEqual(lines, [hold, "[launch] 启动画面结束：超过时限（…ms）"])
    }

    // MARK: - 到时限时还没提交

    /// 之后提交了、一直没加载完成：提交后 pageRevealLimit 结束。
    func testAfterTheLimitTheCommitFallbackEndsIt() async throws {
        make()
        controller.launchScreenLimit = 0.05
        controller.pageRevealLimit = 0.3
        controller.beginLaunchScreen()
        try await waitUntil { lines.count == 2 }
        XCTAssertEqual(window, "启动画面=true 淡出=false 启动保护=true 提示=无")
        controller.pageDidCommit()
        try await pause(0.15)
        XCTAssertEqual(window, "启动画面=true 淡出=false 启动保护=true 提示=无", "兜底之前")
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertEqual(window, "启动画面=false 淡出=true 启动保护=true 提示=无")
        XCTAssertEqual(lines, [hold, limitLine(reveal: 300, cap: 30), "[launch] 启动画面结束：提交后 300ms 还没加载完成（…ms）"])
    }

    /// 之后提交、加载完成：加载完成结束它；之后提交后的兜底到点不做事。
    func testAfterTheLimitAFinishEndsIt() async throws {
        make()
        controller.launchScreenLimit = 0.05
        controller.pageRevealLimit = 0.3
        controller.beginLaunchScreen()
        try await waitUntil { lines.count == 2 }
        controller.pageDidCommit()
        controller.endLaunchScreen("网页已加载")
        controller.pageDidFinishLoading()
        XCTAssertEqual(window, "启动画面=false 淡出=true 启动保护=false 提示=无")
        try await pause(0.5)
        XCTAssertEqual(lines, [hold, limitLine(reveal: 300, cap: 30), "[launch] 启动画面结束：网页已加载（…ms）", release])
    }

    /// 之后加载失败：失败结束它。
    func testAfterTheLimitAFailureEndsIt() async throws {
        make()
        controller.launchScreenLimit = 0.05
        controller.beginLaunchScreen()
        try await waitUntil { lines.count == 2 }
        controller.showLoadProblem(.waiting)
        controller.endLaunchScreen("加载失败")
        XCTAssertEqual(window, "启动画面=false 淡出=true 启动保护=true 提示=waiting")
        XCTAssertEqual(lines, [hold, limitLine(reveal: 1000, cap: 30), "[launch] 启动画面结束：加载失败（…ms）"])
    }

    /// 既不提交也不失败：上限结束它。
    func testTheCapEndsIt() async throws {
        make()
        controller.launchScreenLimit = 0.05
        controller.launchScreenCap = 0.4
        controller.beginLaunchScreen()
        try await waitUntil { lines.count == 2 }
        XCTAssertEqual(window, "启动画面=true 淡出=false 启动保护=true 提示=无")
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertEqual(window, "启动画面=false 淡出=true 启动保护=true 提示=无")
        XCTAssertEqual(lines, [hold, limitLine(reveal: 1000, cap: 0), "[launch] 启动画面结束：超过上限（…ms）"])
    }

    /// 到时限后提交两次：第一次的兜底到点不做事，按第二次计时结束。
    func testAfterTheLimitOnlyTheLatestCommitsFallbackEndsIt() async throws {
        make()
        controller.launchScreenLimit = 0.05
        controller.pageRevealLimit = 0.4
        controller.beginLaunchScreen()
        try await waitUntil { lines.count == 2 }
        controller.pageDidCommit()
        try await pause(0.2)
        controller.pageDidCommit()
        // 第一次的兜底在 0.4 秒到点，第二次的在约 0.6 秒。
        try await pause(0.3)
        XCTAssertEqual(window, "启动画面=true 淡出=false 启动保护=true 提示=无", "第一次的兜底不生效")
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertEqual(lines, [hold, limitLine(reveal: 400, cap: 30), "[launch] 启动画面结束：提交后 400ms 还没加载完成（…ms）"])
    }

    // MARK: - 结束以后、又开始一次

    /// 加载完成结束以后：时限、兜底和上限到点都不做事。
    func testTimersAfterTheEndDoNothing() async throws {
        make()
        controller.launchScreenLimit = 0.1
        controller.launchScreenCap = 0.3
        controller.pageRevealLimit = 0.2
        controller.beginLaunchScreen()
        controller.pageDidCommit()
        controller.endLaunchScreen("网页已加载")
        controller.pageDidFinishLoading()
        try await pause(0.5)
        try await waitUntil { controller.launchFadeView == nil }
        XCTAssertEqual(window, "启动画面=false 淡出=false 启动保护=false 提示=无")
        XCTAssertEqual(lines, [hold, "[launch] 启动画面结束：网页已加载（…ms）", release])
    }

    /// 到时限后在等提交时又开始一次：这一次从头算，不再等提交。提交后的兜底先到点也不结束它，由这一次的时限结束。
    func testBeginningAgainStartsWithoutWaitingForACommit() async throws {
        make()
        controller.launchScreenLimit = 0.05
        controller.beginLaunchScreen()
        try await waitUntil { lines.count == 2 }
        controller.launchScreenLimit = 0.6
        controller.pageRevealLimit = 0.1
        controller.beginLaunchScreen()
        controller.pageDidCommit()
        // 兜底在 0.1 秒到点，这一次的时限在 0.6 秒。
        try await pause(0.3)
        XCTAssertEqual(window, "启动画面=true 淡出=false 启动保护=true 提示=无", "兜底不结束它")
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertEqual(lines, [hold, limitLine(reveal: 1000, cap: 30), hold, "[launch] 启动画面结束：超过时限（…ms）"])
    }

    /// 结束以后又开始一次：前一次的上限到点不结束这一次，这一次的照常结束。
    func testAnEarlierCapDoesNotEndALaterCover() async throws {
        make()
        controller.launchScreenCap = 0.4
        controller.beginLaunchScreen()
        controller.endLaunchScreen("网页已加载")
        try await pause(0.2)
        let second = Date()
        controller.beginLaunchScreen()
        // 第一次的上限在 0.4 秒到点，第二次的在约 0.6 秒。
        try await pause(0.3)
        XCTAssertEqual(window, "启动画面=true 淡出=false 启动保护=true 提示=无")
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertEqual(lines, [hold, "[launch] 启动画面结束：网页已加载（…ms）", hold, "[launch] 启动画面结束：超过上限（…ms）"])
        // 耗时从这一次开始算（不是第一次）：不超过从这一次开始到现在。
        let since = Int(Date().timeIntervalSince(second) * 1000)
        let ended = try XCTUnwrap(diagnostics.entries.last { $0.message.hasPrefix("启动画面结束：超过上限") }?.message)
        let logged = try XCTUnwrap(Int(ended.replacingOccurrences(of: #"^.*（(\d+)ms）$"#, with: "$1", options: .regularExpression)))
        XCTAssertLessThanOrEqual(logged, since, "耗时从这一次开始算：\(ended)")
        XCTAssertGreaterThanOrEqual(logged, 390)
    }
}
