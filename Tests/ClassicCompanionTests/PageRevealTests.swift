import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ClassicCompanion

/// 遮挡撤掉后、网页画出来之前露出的空白白色（2026-11-15 对照：1404 也有，启动保护之后前面是深色，变得显眼）。
/// 断网恢复时“无法连接”提示在提交时就收起，网页要到加载完成后 33–64 ms 才画出来；加载慢时启动画面 10 秒到时限，
/// 网页还没提交就结束。两者都改成和正常启动一样：等加载完成再撤，并淡出 0.2 秒。
/// - 提示：提交后先留着，加载完成时淡出；提交后 pageRevealLimit（1 秒）还没加载完成，就收起。
/// - 启动画面：到时限时已经提交就照旧结束；还没提交就继续显示，直到加载完成、加载失败、提交后 pageRevealLimit，
///   或从启动起 launchScreenCap（30 秒）。
/// 这些测试不显示窗口。
@MainActor
final class PageRevealTests: XCTestCase {
    private let savedDark = NSColor(srgbRed: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x0E / 255.0, alpha: 1)
    private let pageBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    private var web: WKWebView!
    private var appearance: PageAppearance!
    private var controller: ChatWindowController!
    private var diagnostics: Diagnostics!

    private func make() {
        let name = "PageRevealTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = UserDefaults(suiteName: name)!
        let rgb = savedDark.usingColorSpace(.sRGB)!
        defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init), forKey: "pageBackgroundRGB")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        appearance = PageAppearance(defaults: defaults)
        diagnostics = Diagnostics()
        controller = ChatWindowController(webView: web, toolbar: EmptyView(), diagnostics: diagnostics, appearance: appearance)
        addTeardownBlock { [controller] in controller?.window?.orderOut(nil) }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await pause(0.02) }
    }

    private func logged(_ text: String) -> Bool {
        diagnostics.entries.contains { $0.message.contains(text) }
    }

    /// 断网后重试：提示显示中，重试的请求发出，网页提交。顺序和应用里一样：先通知提交，再收到“提示可以收起”。
    private func offlineThenCommit() {
        controller.beginLaunchScreen()
        controller.endLaunchScreen("加载失败")
        controller.showLoadProblem(.waiting)
        controller.showLoadProblem(.connecting)
        controller.pageDidCommit()
        controller.showLoadProblem(.hidden)
    }

    // MARK: - R1 “无法连接”提示

    /// 提交时网页还没画出来：提示留着（仍是“正在连接”），加载完成才收起。
    func testTheNoticeStaysAfterTheCommitUntilTheLoadFinishes() async throws {
        make()
        offlineThenCommit()
        XCTAssertEqual(controller.shownLoadProblem, .connecting, "提交时不收起")
        try await pause(0.3)
        XCTAssertEqual(controller.shownLoadProblem, .connecting, "加载完成前一直留着")
        controller.endLaunchScreen("网页已加载")
        controller.pageDidFinishLoading()
        XCTAssertNil(controller.shownLoadProblem, "加载完成时收起")
        XCTAssertTrue(logged("无法连接提示：加载完成，淡出"))
    }

    /// 收起时盖一层同样的提示淡出：内容停在收起前的状态，底色和外观固定在那一刻。
    func testTheNoticeFadesWithAFixedLook() async throws {
        make()
        controller.pageColorSettleLimit = 0.05
        offlineThenCommit()
        web.underPageBackgroundColor = white
        controller.pageDidFinishLoading()
        let fade = try XCTUnwrap(controller.loadProblemFadeView)
        XCTAssertEqual(fade.rootView.model.status, .connecting, "淡出那层仍显示收起前的内容")
        XCTAssertTrue(PageAppearance.sameColor(fade.rootView.fixedBackground, savedDark))
        XCTAssertEqual(fade.appearance?.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        // 页面真是浅色：1 秒颜色兜底按 0.05 秒算，在淡出那层还在时就采用。
        try await waitUntil { appearance.isDark == false }
        XCTAssertEqual(appearance.isDark, false)
        XCTAssertTrue(PageAppearance.sameColor(fade.rootView.fixedBackground, savedDark), "淡出那层的底色没换")
        XCTAssertEqual(fade.appearance?.bestMatch(from: [.aqua, .darkAqua]), .darkAqua, "淡出那层的外观没换")
        XCTAssertEqual(fade.rootView.model.status, .connecting)
    }

    /// 提交后一直没有加载完成（子资源卡住）：到 pageRevealLimit 就收起，不一直挡着已经能用的页面。
    func testTheNoticeGivesWayAfterTheLimitWithoutAFinish() async throws {
        make()
        controller.pageRevealLimit = 0.3
        offlineThenCommit()
        try await pause(0.15)
        XCTAssertEqual(controller.shownLoadProblem, .connecting, "兜底时间之前还在")
        try await waitUntil { controller.shownLoadProblem == nil }
        XCTAssertNil(controller.shownLoadProblem)
        XCTAssertTrue(logged("无法连接提示：提交后 300ms 还没加载完成，收起"))
    }

    /// 留着的时候又失败了：提示照常换成新的状态，之前排着的兜底不能把它收起。
    func testANewProblemCancelsThePendingHide() async throws {
        make()
        controller.pageRevealLimit = 0.2
        offlineThenCommit()
        controller.showLoadProblem(.waiting)
        XCTAssertEqual(controller.shownLoadProblem, .waiting)
        try await pause(0.5)
        XCTAssertEqual(controller.shownLoadProblem, .waiting, "旧的兜底没有生效")
        // 之后的加载完成也不收起正在显示的新问题（新问题要等它自己的提交和“可以收起”）。
        controller.pageDidFinishLoading()
        XCTAssertEqual(controller.shownLoadProblem, .waiting)
    }

    /// 没有提交在等加载完成时（例如取消后回到等待再收起）：和原来一样立刻收起。
    func testWithoutACommitTheNoticeHidesAtOnceAsBefore() {
        make()
        controller.showLoadProblem(.waiting)
        controller.showLoadProblem(.hidden)
        XCTAssertNil(controller.shownLoadProblem)
        XCTAssertNil(controller.loadProblemFadeView, "立刻收起，不淡出")
    }

    /// 又提交了一次（新的导航）：按新的提交重新计时，前一次提交的兜底不生效。
    func testASecondCommitRestartsTheWait() async throws {
        make()
        controller.pageRevealLimit = 0.4
        offlineThenCommit()
        try await pause(0.25)
        controller.pageDidCommit()
        controller.showLoadProblem(.hidden)
        try await pause(0.25)
        XCTAssertEqual(controller.shownLoadProblem, .connecting, "第一次提交的兜底（0.4 秒）不生效")
        try await waitUntil { controller.shownLoadProblem == nil }
        XCTAssertNil(controller.shownLoadProblem, "按第二次提交计时收起")
    }

    /// 加载完成已经过了，旧的兜底到点时不做任何事。
    func testTheFallbackDoesNothingAfterTheLoadFinished() async throws {
        make()
        controller.pageRevealLimit = 0.2
        offlineThenCommit()
        controller.pageDidFinishLoading()
        try await pause(0.4)
        XCTAssertNil(controller.shownLoadProblem)
        XCTAssertFalse(logged("还没加载完成，收起"))
    }

    // MARK: - R2 启动画面到时限

    /// 到时限时网页还没提交（窗口里没有页面）：启动画面继续显示，不露出空白。
    func testAtTheLimitWithoutAPageTheLaunchScreenStays() async throws {
        make()
        controller.launchScreenLimit = 0.05
        controller.beginLaunchScreen()
        try await pause(0.4)
        XCTAssertTrue(controller.isShowingLaunchScreen)
        XCTAssertTrue(logged("启动画面到时限：网页还没提交，继续显示"))
    }

    /// 之后加载完成：照正常路径结束并淡出。
    func testAfterTheLimitItEndsWhenTheLoadFinishes() async throws {
        make()
        controller.launchScreenLimit = 0.05
        controller.pageRevealLimit = 5
        controller.beginLaunchScreen()
        try await pause(0.2)
        controller.pageDidCommit()
        XCTAssertTrue(controller.isShowingLaunchScreen, "提交时不结束")
        controller.endLaunchScreen("网页已加载")
        controller.pageDidFinishLoading()
        XCTAssertFalse(controller.isShowingLaunchScreen)
        XCTAssertNotNil(controller.launchFadeView, "照常淡出")
        XCTAssertTrue(logged("启动画面结束：网页已加载"))
    }

    /// 提交了但一直没有加载完成：提交后 pageRevealLimit 结束。
    func testAfterTheLimitItEndsAfterTheCommitWithoutAFinish() async throws {
        make()
        controller.launchScreenLimit = 0.05
        controller.pageRevealLimit = 0.3
        controller.beginLaunchScreen()
        try await pause(0.2)
        controller.pageDidCommit()
        try await pause(0.15)
        XCTAssertTrue(controller.isShowingLaunchScreen, "兜底时间之前还在")
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertFalse(controller.isShowingLaunchScreen)
        XCTAssertTrue(logged("启动画面结束：提交后 300ms 还没加载完成"))
    }

    /// 加载失败：和原来一样结束，换成“无法连接”提示。
    func testAfterTheLimitAFailureEndsItAsBefore() async throws {
        make()
        controller.launchScreenLimit = 0.05
        controller.beginLaunchScreen()
        try await pause(0.2)
        controller.endLaunchScreen("加载失败")
        controller.showLoadProblem(.waiting)
        XCTAssertFalse(controller.isShowingLaunchScreen)
        XCTAssertEqual(controller.shownLoadProblem, .waiting)
    }

    /// 既不提交也不失败：到 launchScreenCap 照现在的方式结束，不一直挡着。
    func testTheCapEndsItWhenNothingHappens() async throws {
        make()
        controller.launchScreenLimit = 0.05
        controller.launchScreenCap = 0.4
        controller.beginLaunchScreen()
        try await pause(0.25)
        XCTAssertTrue(controller.isShowingLaunchScreen, "上限之前还在")
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertFalse(controller.isShowingLaunchScreen)
        XCTAssertTrue(logged("启动画面结束：超过上限"))
    }

    /// 到时限时已经提交（有页面，只是还没加载完成）：照旧在时限结束，露出网页。
    func testWithAPageAtTheLimitItEndsAsBefore() async throws {
        make()
        controller.launchScreenLimit = 0.1
        controller.beginLaunchScreen()
        controller.pageDidCommit()
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertFalse(controller.isShowingLaunchScreen)
        XCTAssertTrue(logged("启动画面结束：超过时限"))
    }

    /// 启动画面已经因为加载完成结束：之后的时限、兜底和上限都不做事。
    func testTimersDoNothingAfterTheLaunchScreenEnded() async throws {
        make()
        controller.launchScreenLimit = 0.1
        controller.launchScreenCap = 0.3
        controller.pageRevealLimit = 0.2
        controller.beginLaunchScreen()
        controller.pageDidCommit()
        controller.endLaunchScreen("网页已加载")
        controller.pageDidFinishLoading()
        try await pause(0.5)
        XCTAssertEqual(diagnostics.entries.filter { $0.message.contains("启动画面结束") }.count, 1)
        XCTAssertFalse(logged("启动画面到时限"))
    }
}
