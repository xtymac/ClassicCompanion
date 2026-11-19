import AppKit
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// “无法连接”提示的状态放在页面状态里（PageLoadState.notice），窗口里的提示那一层只照它投出来。
/// 照 PageRevealTests、LoadRecoveryWebTests 走过的顺序重放一遍，每一步之后都核对：页面的状态、留着与否、
/// 提示那一层显不显示和它显示的内容、shownLoadProblem、淡出那层，一一对上。
/// 两段“看起来不一样”的时候单独核对：留到加载完成（WebRuntime 已说可以收起，提示仍显示收起前的状态），
/// 淡出中（页面状态和提示那层都已收起，另一层还盖着淡出）。
/// 这些测试不显示窗口。
@MainActor
final class NoticeStateTests: XCTestCase {
    private var web: WKWebView!
    private var controller: ChatWindowController!
    private var diagnostics: Diagnostics!

    private func make(page: PageLoadState = PageLoadState()) {
        let name = "NoticeStateTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        diagnostics = Diagnostics()
        controller = ChatWindowController(webView: web, toolbar: EmptyView(), diagnostics: diagnostics,
                                          appearance: PageAppearance(defaults: UserDefaults(suiteName: name)!), page: page)
        addTeardownBlock { [controller] in controller?.window?.orderOut(nil) }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await pause(0.02) }
    }

    private func logCount(_ text: String) -> Int {
        diagnostics.entries.filter { $0.message.contains(text) }.count
    }

    /// 提示那一层：内容视图里第一个 LoadProblemView（初始化时加的；淡出那层加在它上面，排在后面）。
    private var cover: NSHostingView<LoadProblemView> {
        controller.window!.contentView!.subviews.compactMap { $0 as? NSHostingView<LoadProblemView> }.first!
    }

    /// 每一步之后核对。`fading`：淡出那层应显示的内容；nil 表示不该有淡出那层。
    private func check(_ notice: LoadRecovery.Status, held: Bool = false, fading: LoadRecovery.Status? = nil,
                       _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(controller.page.notice, notice, "\(step)：页面的提示状态", file: file, line: line)
        XCTAssertEqual(controller.page.noticeAwaitsLoad, held, "\(step)：留到加载完成", file: file, line: line)
        XCTAssertEqual(cover.isHidden, notice == .hidden, "\(step)：提示那层显不显示", file: file, line: line)
        XCTAssertEqual(cover.rootView.model.status, notice, "\(step)：提示那层的内容", file: file, line: line)
        XCTAssertEqual(controller.shownLoadProblem, notice == .hidden ? nil : notice, "\(step)：shownLoadProblem",
                       file: file, line: line)
        if let fading {
            let fade = controller.loadProblemFadeView
            XCTAssertNotNil(fade, "\(step)：该有淡出那层", file: file, line: line)
            XCTAssertFalse(fade === cover, "\(step)：淡出的是另一层", file: file, line: line)
            XCTAssertEqual(fade?.isHidden, false, "\(step)：淡出那层显示着", file: file, line: line)
            XCTAssertEqual(fade?.rootView.model.status, fading, "\(step)：淡出那层的内容", file: file, line: line)
        } else {
            XCTAssertNil(controller.loadProblemFadeView, "\(step)：不该有淡出那层", file: file, line: line)
        }
    }

    /// 淡出那层 0.2 秒后拿掉。
    private func waitForTheFadeToEnd(file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil { controller.loadProblemFadeView == nil }
        XCTAssertNil(controller.loadProblemFadeView, "淡出那层没有拿掉", file: file, line: line)
    }

    /// 断网后重试、网页提交、收到“可以收起”：和 PageRevealTests.offlineThenCommit 同样的顺序，每步核对。
    private func offlineThenCommitChecked() {
        check(.hidden, "初始")
        controller.beginLaunchScreen()
        check(.hidden, "启动画面出现")
        controller.endLaunchScreen("加载失败")
        check(.hidden, "启动画面结束")
        controller.showLoadProblem(.waiting)
        check(.waiting, "等待重试")
        controller.showLoadProblem(.connecting)
        check(.connecting, "正在连接")
        controller.pageDidCommit()
        check(.connecting, "网页提交")
        controller.showLoadProblem(.hidden)
        // 不一样的一段：WebRuntime 已经是 .hidden，页面状态和提示那层仍是“正在连接”，记着留到加载完成。
        check(.connecting, held: true, "收到可以收起：留着")
    }

    // MARK: - 顺序重放

    /// 等待 → 提交 → 留着 → 加载完成淡出 → 淡出结束。
    func testWaitingCommittedHeldThenFinished() async throws {
        make()
        offlineThenCommitChecked()
        controller.showLoadProblem(.hidden)
        check(.connecting, held: true, "又收到一次可以收起：照样留着")
        XCTAssertEqual(logCount("无法连接提示：网页已提交，留到加载完成"), 1)
        controller.endLaunchScreen("网页已加载")
        check(.connecting, held: true, "启动画面已结束过，不再动")
        controller.pageDidFinishLoading()
        // 不一样的一段：页面状态和提示那层都已收起，另一层还显示“正在连接”在淡出。
        check(.hidden, fading: .connecting, "加载完成：淡出中")
        XCTAssertEqual(logCount("无法连接提示：加载完成，淡出"), 1)
        try await waitForTheFadeToEnd()
        check(.hidden, "淡出结束")
    }

    /// 没有提交在等加载完成：等待 → 直接收起，不留、不淡出。各种状态之间直接换也一样。
    func testWaitingThenHiddenDirectly() {
        make()
        check(.hidden, "初始")
        controller.showLoadProblem(.waiting)
        check(.waiting, "等待重试")
        controller.showLoadProblem(.hidden)
        check(.hidden, "直接收起")
        for status: LoadRecovery.Status in [.stopped, .connecting, .waiting, .hidden, .hidden, .stopped, .hidden] {
            controller.showLoadProblem(status)
            check(status, "直接换成 \(status)")
        }
        XCTAssertEqual(logCount("留到加载完成"), 0)
    }

    /// 留着的时候又失败了：换成新的状态，不再留着；之后的加载完成不收起它、不淡出。
    func testAFailureAfterTheCommit() async throws {
        make()
        controller.pageRevealLimit = 0.2
        offlineThenCommitChecked()
        controller.showLoadProblem(.waiting)
        check(.waiting, "提交后又失败")
        try await pause(0.4)
        check(.waiting, "旧的兜底到点：不收起")
        controller.pageDidFinishLoading()
        check(.waiting, "加载完成：不收起新问题")
        XCTAssertEqual(logCount("还没加载完成，收起"), 0)
    }

    /// 提交后一直没有加载完成：兜底到点收起，不淡出；之后的加载完成不再动它。
    func testTheCommitFallbackFires() async throws {
        make()
        controller.pageRevealLimit = 0.2
        offlineThenCommitChecked()
        try await pause(0.05)
        check(.connecting, held: true, "兜底时间之前")
        try await waitUntil { controller.page.notice == .hidden }
        check(.hidden, "兜底收起")
        XCTAssertEqual(logCount("无法连接提示：提交后 200ms 还没加载完成，收起"), 1)
        controller.pageDidFinishLoading()
        check(.hidden, "之后的加载完成")
        XCTAssertEqual(logCount("无法连接提示：加载完成，淡出"), 0)
    }

    /// 淡出中又出了问题：页面状态和提示那层换成新的，淡出那层照旧显示收起前的内容直到拿掉。
    func testANewProblemWhileTheFadeIsInProgress() async throws {
        make()
        offlineThenCommitChecked()
        controller.pageDidFinishLoading()
        check(.hidden, fading: .connecting, "加载完成：淡出中")
        controller.showLoadProblem(.waiting)
        check(.waiting, fading: .connecting, "淡出中又失败：新提示显示，淡出那层还在")
        try await waitForTheFadeToEnd()
        check(.waiting, "淡出结束：新提示还在")
    }

    // MARK: - 页面状态对象

    /// 外面给的 PageLoadState：经窗口写进去的提示状态就在这个对象上。
    func testTheNoticeLandsOnTheSuppliedPageState() async throws {
        let state = PageLoadState()
        make(page: state)
        XCTAssertTrue(controller.page === state)
        check(.hidden, "初始")
        controller.showLoadProblem(.stopped)
        XCTAssertEqual(state.notice, .stopped)
        check(.stopped, "不再自动重试")
        controller.pageDidCommit()
        controller.showLoadProblem(.hidden)
        XCTAssertEqual(state.notice, .stopped)
        XCTAssertTrue(state.noticeAwaitsLoad)
        check(.stopped, held: true, "留着")
        controller.pageDidFinishLoading()
        XCTAssertEqual(state.notice, .hidden)
        check(.hidden, fading: .stopped, "淡出中")
    }

    /// 给的页面状态里已经有提示：窗口一开始就照它显示（默认的页面状态是 .hidden，和原来一样一开始不显示）。
    func testASuppliedPageStateWithANoticeIsShownFromTheStart() {
        let state = PageLoadState()
        XCTAssertEqual(state.notice, .hidden, "默认不显示")
        state.notice = .waiting
        make(page: state)
        check(.waiting, "一开始")
        controller.showLoadProblem(.hidden)
        check(.hidden, "收起")
    }

    /// 换网页视图不换页面状态：淡出中换（这时已经停下来），页面状态还是那一个，提示状态和淡出那层都不动。
    func testReplacingTheWebViewKeepsThePageAndItsNotice() async throws {
        make()
        let page = controller.page
        controller.showLoadProblem(.connecting)
        check(.connecting, "正在连接")
        controller.pageDidCommit()
        check(.connecting, "网页提交")
        controller.showLoadProblem(.hidden)
        check(.connecting, held: true, "留着")
        controller.pageDidFinishLoading()
        check(.hidden, fading: .connecting, "淡出中")
        controller.replaceWebView(with: WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        XCTAssertTrue(controller.page === page)
        XCTAssertEqual(logCount("还没停下来"), 0, "淡出中已经算停下来")
        check(.hidden, fading: .connecting, "换过网页视图")
        controller.showLoadProblem(.waiting)
        XCTAssertEqual(page.notice, .waiting)
        check(.waiting, fading: .connecting, "换过之后又失败")
        try await waitForTheFadeToEnd()
        check(.waiting, "淡出结束")
    }
}
