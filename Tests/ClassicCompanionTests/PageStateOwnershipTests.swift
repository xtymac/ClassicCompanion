import AppKit
import Combine
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 页面状态一页一份：事件带着它属于的页面交给窗口，先改那个页面自己的状态，只有它显示着时窗口才跟着变。
/// B 是窗口显示着的页面（controller.page），A 是另一个从来不显示的 PageLoadState（以后的后台标签页）。
/// 核对四件事：
/// - A 的提交、加载完成、加载失败、提示变化只改 A 自己的状态；B 的状态、启动画面、启动保护、提示（状态、那一层、淡出那层）、
///   颜色和窗口的日志都不变。
/// - 两个页面的事件交错时，各自的状态互不覆盖。
/// - 排着的回调只对排下它的那个页面、那一次起作用：代号变了、页面释放了、或者同样的事件来自另一个页面，都不跨过去。
/// - 只有一个页面时，带页面的入口（传 controller.page）和原来的入口写出的日志一行不差，最后的状态也一样。
/// WebKit 报的页面颜色和 LaunchColourTests 一样直接设 underPageBackgroundColor 来模拟。这些测试不显示窗口。
@MainActor
final class PageStateOwnershipTests: XCTestCase {
    private let savedDark = NSColor(srgbRed: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x0E / 255.0, alpha: 1)
    private let pageBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    /// 起始颜色：不是白色，也不是测试里要报的颜色，所以之后设的每个颜色都是真的变化（见 LaunchColourTests.make(saved:reported:)）。
    private let blankDark = NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)

    private var defaults: UserDefaults!
    private var web: WKWebView!
    private var appearance: PageAppearance!
    private var controller: ChatWindowController!
    private var diagnostics: Diagnostics!
    /// 显示着的页面。
    private var b: PageLoadState!
    /// 顶部一条等原生部分用过的每一个颜色（PageAppearance.background 的每次变化）。
    private var shown: [NSColor?] = []
    private var watch: AnyCancellable?

    /// 记下的页面颜色是 savedDark，网页视图开始时报着 blankDark，没有启动画面。显示着的页面是 b。
    private func make() {
        let name = "PageStateOwnershipTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        defaults = UserDefaults(suiteName: name)!
        let rgb = savedDark.usingColorSpace(.sRGB)!
        defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init), forKey: "pageBackgroundRGB")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        web.underPageBackgroundColor = blankDark
        XCTAssertTrue(PageAppearance.sameColor(web.underPageBackgroundColor, blankDark), "起始颜色已设上")
        appearance = PageAppearance(defaults: defaults)
        diagnostics = Diagnostics()
        b = PageLoadState()
        controller = ChatWindowController(webView: web, toolbar: EmptyView(), diagnostics: diagnostics, appearance: appearance, page: b)
        XCTAssertTrue(controller.page === b)
        addTeardownBlock { [controller] in controller?.window?.orderOut(nil) }
        shown = []
        watch = appearance.$background.dropFirst().sink { [weak self] in self?.shown.append($0) }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await pause(0.02) }
    }

    private func count(_ text: String) -> Int {
        diagnostics.entries.filter { $0.message.contains(text) }.count
    }

    // MARK: - 核对用

    /// 一个页面的全部状态，逐项比较。
    private struct Fields: Equatable, CustomStringConvertible {
        var committed = false
        var awaiting = false
        var generation = 0
        var notice: LoadRecovery.Status = .hidden
        var held = false
        var holds = false
        var colorBefore = "nil"
        var finished = false
        var finishColor = "nil"

        var description: String {
            "提交=\(committed) 等加载完成=\(awaiting) 代号=\(generation) 提示=\(notice) 留着=\(held) 启动保护=\(holds) "
                + "加载完成前的颜色=\(colorBefore) 第一次加载已完成=\(finished) 加载完成时的颜色=\(finishColor)"
        }
    }

    private func fields(_ p: PageLoadState) -> Fields {
        Fields(committed: p.hasCommittedPage, awaiting: p.awaitingFinish, generation: p.commitGeneration, notice: p.notice,
               held: p.noticeAwaitsLoad, holds: p.holdsPageColor, colorBefore: Self.rgb(p.colorBeforeFirstLoad),
               finished: p.hasFinishedFirstLoad, finishColor: Self.rgb(p.colorAtLastFinish))
    }

    /// 提示那一层：内容视图里第一个 LoadProblemView（初始化时加的；淡出那层加在它上面，排在后面）。
    private var noticeCover: NSHostingView<LoadProblemView> {
        controller.window!.contentView!.subviews.compactMap { $0 as? NSHostingView<LoadProblemView> }.first!
    }

    /// 窗口上看得见的一切，加上窗口的日志（类别和内容，按顺序；不算跟着真实鼠标、键盘、屏幕写的行，见 LiveInputLogLines）。
    private func windowState() -> [String] {
        let cover = noticeCover
        return [
            "启动画面=\(controller.isShowingLaunchScreen)",
            "启动画面淡出那层=\(Self.identity(controller.launchFadeView))",
            "启动保护=\(controller.isHoldingPageColor)",
            "提示=\(String(describing: controller.shownLoadProblem))",
            "提示那层藏着=\(cover.isHidden) 内容=\(cover.rootView.model.status)",
            "提示淡出那层=\(Self.identity(controller.loadProblemFadeView))",
            "页面颜色=\(Self.rgb(appearance.background))",
            "顶部外观=\(controller.chromeAppearance?.name.rawValue ?? "nil")",
            "窗口底色=\(Self.rgb(controller.window?.backgroundColor))",
            "用过的颜色=\(shown.map { Self.rgb($0) })",
        ] + LiveInputLogLines.compared(diagnostics.entries).map { "[\($0.category)] \($0.message)" }
    }

    /// 窗口和显示着的页面 B 都和之前一样。
    private func assertUntouched(_ window: [String], _ displayed: Fields, _ step: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(windowState(), window, "\(step)：窗口", file: file, line: line)
        XCTAssertEqual(fields(b), displayed, "\(step)：显示着的页面", file: file, line: line)
    }

    private static func identity(_ view: NSView?) -> String {
        view.map { "\(ObjectIdentifier($0))" } ?? "无"
    }

    /// sRGB 分量，三位小数；没有颜色时写 nil。
    private static func rgb(_ color: NSColor?) -> String {
        guard let color else { return "nil" }
        guard let c = color.usingColorSpace(.sRGB) else { return color.description }
        return String(format: "(%.3f, %.3f, %.3f, a %.2f)", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    // MARK: - 不显示的页面的事件不动窗口

    /// B 的启动画面还在（启动保护中）。A 提交、提示变化、留着、加载完成、加载失败、直接收起、解除自己的启动保护、提交后兜底到点：
    /// 每一步 A 的状态照规则变，B 和窗口一点不变。
    func testABackgroundPagesEventsChangeOnlyItsOwnState() async throws {
        make()
        controller.pageRevealLimit = 0.2
        controller.beginLaunchScreen()
        XCTAssertTrue(controller.isShowingLaunchScreen)
        XCTAssertTrue(b.holdsPageColor)
        let a = PageLoadState()
        let window = windowState(), displayed = fields(b)

        controller.pageDidCommit(a)
        assertUntouched(window, displayed, "A 提交")
        XCTAssertEqual(fields(a), Fields(committed: true, awaiting: true, generation: 1))

        controller.showLoadProblem(.waiting, for: a)
        assertUntouched(window, displayed, "A 等待重试")
        XCTAssertEqual(fields(a), Fields(committed: true, awaiting: true, generation: 1, notice: .waiting))

        controller.showLoadProblem(.hidden, for: a)
        assertUntouched(window, displayed, "A 收到可以收起")
        XCTAssertEqual(fields(a), Fields(committed: true, awaiting: true, generation: 1, notice: .waiting, held: true),
                       "A 已提交、还没加载完成：A 的提示照规则留着")

        controller.endLaunchScreen("网页已加载", for: a)
        controller.pageDidFinishLoading(a, reportedColor: white)
        assertUntouched(window, displayed, "A 加载完成")
        XCTAssertEqual(fields(a), Fields(committed: true, generation: 2, finished: true, finishColor: Self.rgb(white)),
                       "A 留着的提示在 A 的状态里收起，不淡出")

        // 应用里加载失败是：结束启动画面，再收到“等待重试”。
        controller.endLaunchScreen("加载失败", for: a)
        controller.showLoadProblem(.waiting, for: a)
        assertUntouched(window, displayed, "A 加载失败")
        XCTAssertEqual(fields(a), Fields(committed: true, generation: 2, notice: .waiting, finished: true,
                                         finishColor: Self.rgb(white)))

        controller.showLoadProblem(.hidden, for: a)
        assertUntouched(window, displayed, "A 直接收起")
        XCTAssertEqual(fields(a), Fields(committed: true, generation: 2, finished: true, finishColor: Self.rgb(white)),
                       "没有提交在等加载完成：直接收起")

        // A 也在启动保护里（以后：启动的页面换到后台）：加载完成时只解除 A 自己的。
        a.holdsPageColor = true
        controller.pageDidFinishLoading(a, reportedColor: pageBlack)
        assertUntouched(window, displayed, "A 解除启动保护")
        XCTAssertEqual(fields(a), Fields(committed: true, generation: 3, finished: true, finishColor: Self.rgb(pageBlack)),
                       "不显示的页面不设加载完成前的颜色：等颜色变化是窗口的事")

        // A 的提交后兜底到点：只收起 A 自己留着的提示。
        controller.showLoadProblem(.connecting, for: a)
        controller.pageDidCommit(a)
        controller.showLoadProblem(.hidden, for: a)
        XCTAssertEqual(fields(a), Fields(committed: true, awaiting: true, generation: 4, notice: .connecting, held: true,
                                         finished: true, finishColor: Self.rgb(pageBlack)))
        try await waitUntil { !a.noticeAwaitsLoad }
        XCTAssertEqual(fields(a), Fields(committed: true, awaiting: true, generation: 4, finished: true,
                                         finishColor: Self.rgb(pageBlack)), "A 的兜底收起 A 的提示")
        assertUntouched(window, displayed, "A 的兜底到点")
        XCTAssertTrue(controller.isShowingLaunchScreen)
    }

    /// B 的提示显示着。A 的提示留着、加载完成（显示着的话会淡出）：B 的提示、提示那层和淡出那层都不变；之后 B 的照常变。
    func testABackgroundPageNeverTouchesTheDisplayedNotice() {
        make()
        controller.beginLaunchScreen()
        controller.endLaunchScreen("加载失败")
        controller.showLoadProblem(.waiting)
        XCTAssertEqual(controller.shownLoadProblem, .waiting)
        let a = PageLoadState()
        let window = windowState(), displayed = fields(b)

        controller.showLoadProblem(.connecting, for: a)
        controller.pageDidCommit(a)
        controller.showLoadProblem(.hidden, for: a)
        assertUntouched(window, displayed, "A 的提示留着")
        controller.pageDidFinishLoading(a, reportedColor: white)
        assertUntouched(window, displayed, "A 加载完成")
        XCTAssertNil(controller.loadProblemFadeView, "没有淡出那层")
        XCTAssertEqual(fields(a), Fields(committed: true, generation: 2, finished: true, finishColor: Self.rgb(white)))

        controller.showLoadProblem(.stopped)
        XCTAssertEqual(controller.shownLoadProblem, .stopped, "B 的提示照常变")
        XCTAssertEqual(noticeCover.rootView.model.status, .stopped)
        XCTAssertEqual(a.notice, .hidden, "A 的不跟着变")
    }

    // MARK: - 两个页面的状态互不覆盖

    /// 两个页面的事件交错：每一步之后两个页面逐项核对，窗口的提示一直照 B 的。
    func testInterleavedEventsKeepEachPagesStateApart() {
        make()
        controller.pageRevealLimit = 5
        let a = PageLoadState()
        var ea = Fields(), eb = Fields()
        func check(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(fields(a), ea, "\(step)：A", file: file, line: line)
            XCTAssertEqual(fields(b), eb, "\(step)：B", file: file, line: line)
            XCTAssertEqual(controller.shownLoadProblem, eb.notice == .hidden ? nil : eb.notice, "\(step)：窗口的提示照 B",
                           file: file, line: line)
            XCTAssertEqual(noticeCover.rootView.model.status, eb.notice, "\(step)：提示那层照 B", file: file, line: line)
        }

        controller.beginLaunchScreen()
        eb.holds = true
        check("B 启动画面")
        controller.pageDidCommit(a)
        ea.committed = true; ea.awaiting = true; ea.generation = 1
        check("A 提交")
        controller.showLoadProblem(.waiting)
        eb.notice = .waiting
        check("B 等待重试")
        controller.pageDidCommit()
        eb.committed = true; eb.awaiting = true; eb.generation = 1
        check("B 提交")
        controller.showLoadProblem(.connecting, for: a)
        ea.notice = .connecting
        check("A 正在连接")
        controller.pageDidCommit(a)
        ea.generation = 2
        check("A 又提交")
        controller.showLoadProblem(.hidden)
        eb.held = true
        check("B 收到可以收起")
        controller.showLoadProblem(.hidden, for: a)
        ea.held = true
        check("A 收到可以收起")
        controller.endLaunchScreen("网页已加载", for: a)
        XCTAssertTrue(controller.isShowingLaunchScreen, "A 的加载完成不结束 B 的启动画面")
        controller.pageDidFinishLoading(a, reportedColor: white)
        ea.awaiting = false; ea.generation = 3; ea.held = false; ea.notice = .hidden; ea.finished = true
        ea.finishColor = Self.rgb(white)
        check("A 加载完成")
        XCTAssertNil(controller.loadProblemFadeView, "A 的提示收起不淡出")
        controller.endLaunchScreen("网页已加载")
        XCTAssertFalse(controller.isShowingLaunchScreen)
        controller.pageDidFinishLoading()
        eb.awaiting = false; eb.generation = 2; eb.held = false; eb.notice = .hidden; eb.holds = false
        eb.colorBefore = Self.rgb(blankDark); eb.finished = true; eb.finishColor = Self.rgb(blankDark)
        check("B 加载完成")
        XCTAssertEqual(controller.loadProblemFadeView?.rootView.model.status, .waiting, "B 的提示淡出")
        controller.showLoadProblem(.stopped, for: a)
        ea.notice = .stopped
        check("A 不再自动重试")
        controller.pageDidCommit()
        eb.committed = true; eb.awaiting = true; eb.generation = 3
        check("B 又提交")
        controller.pageDidFinishLoading(a, reportedColor: pageBlack)
        ea.generation = 4; ea.finishColor = Self.rgb(pageBlack)
        check("A 又加载完成：没有留着的提示，A 的“不再自动重试”不动")
    }

    // MARK: - 回调不跨页面

    /// B 的启动画面到时限时还没提交、在等它的提交。A 提交后兜底到点：启动画面还在。B 自己的兜底照常结束它。
    func testABackgroundCommitFallbackLeavesTheLaunchScreenWaitingForItsPage() async throws {
        make()
        controller.launchScreenLimit = 0.05
        controller.pageRevealLimit = 0.3
        controller.beginLaunchScreen()
        try await waitUntil { count("启动画面到时限：网页还没提交，继续显示") == 1 }
        XCTAssertEqual(count("启动画面到时限：网页还没提交，继续显示"), 1)
        let a = PageLoadState()
        controller.showLoadProblem(.connecting, for: a)
        controller.pageDidCommit(a)
        controller.showLoadProblem(.hidden, for: a)
        let window = windowState(), displayed = fields(b)
        try await waitUntil { !a.noticeAwaitsLoad }
        XCTAssertEqual(fields(a), Fields(committed: true, awaiting: true, generation: 1), "A 的兜底到点，收起 A 的提示")
        assertUntouched(window, displayed, "A 的兜底到点")
        XCTAssertTrue(controller.isShowingLaunchScreen, "启动画面还在等 B")

        controller.pageDidCommit()
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertFalse(controller.isShowingLaunchScreen, "B 的兜底结束启动画面")
        let ended = diagnostics.entries.filter { $0.message.hasPrefix("启动画面结束") }.map(\.message)
        XCTAssertEqual(ended.count, 1)
        XCTAssertNotNil(ended.first?.range(of: #"^启动画面结束：提交后 300ms 还没加载完成（\d+ms）$"#, options: .regularExpression),
                        "和原来一样的日志：\(ended)")
    }

    /// 先给 A 排下兜底，再给 B 送同样的事件。两个页面的代号一样，A 的兜底到点时只动 A，不动 B；B 的兜底照常。
    func testABackgroundCommitFallbackNeverActsOnTheDisplayedPage() async throws {
        make()
        controller.pageRevealLimit = 0.5
        let a = PageLoadState()
        controller.showLoadProblem(.connecting, for: a)
        controller.pageDidCommit(a)
        controller.showLoadProblem(.hidden, for: a)
        try await pause(0.25)
        controller.showLoadProblem(.connecting)
        controller.pageDidCommit()
        controller.showLoadProblem(.hidden)
        XCTAssertEqual(a.commitGeneration, b.commitGeneration, "代号一样：只看代号分不出页面")
        XCTAssertTrue(a.noticeAwaitsLoad)
        XCTAssertTrue(b.noticeAwaitsLoad)
        let window = windowState(), displayed = fields(b)

        try await waitUntil { !a.noticeAwaitsLoad }
        XCTAssertEqual(fields(a), Fields(committed: true, awaiting: true, generation: 1), "A 的兜底收起 A 的提示")
        assertUntouched(window, displayed, "A 的兜底到点")
        XCTAssertEqual(controller.shownLoadProblem, .connecting)

        try await waitUntil { controller.shownLoadProblem == nil }
        XCTAssertNil(controller.shownLoadProblem, "B 的兜底照常收起")
        XCTAssertFalse(b.noticeAwaitsLoad)
        XCTAssertEqual(count("无法连接提示：提交后 500ms 还没加载完成，收起"), 1)
    }

    /// 显示着的页面排下兜底后又加载完成、又提交（代号变了）：旧的兜底到点时什么都不做，按最后一次提交计时。
    func testAStaleCommitFallbackOfTheDisplayedPageDoesNothing() async throws {
        make()
        controller.pageRevealLimit = 0.6
        controller.showLoadProblem(.connecting)
        controller.pageDidCommit()
        controller.showLoadProblem(.hidden)
        try await pause(0.2)
        controller.pageDidFinishLoading()
        controller.showLoadProblem(.waiting)
        try await pause(0.2)
        controller.pageDidCommit()
        controller.showLoadProblem(.hidden)
        XCTAssertEqual(b.commitGeneration, 3)
        XCTAssertTrue(b.noticeAwaitsLoad)
        // 第一次提交的兜底在 0.6 秒到点，第三次的在约 1.0 秒。
        try await pause(0.4)
        XCTAssertEqual(controller.shownLoadProblem, .waiting, "旧的兜底不生效")
        XCTAssertTrue(b.noticeAwaitsLoad)
        XCTAssertEqual(count("还没加载完成，收起"), 0)
        try await waitUntil { controller.shownLoadProblem == nil }
        XCTAssertNil(controller.shownLoadProblem, "按最后一次提交计时收起")
        XCTAssertEqual(count("无法连接提示：提交后 600ms 还没加载完成，收起"), 1)
    }

    /// 给 A 排下兜底后 A 释放了：兜底不持有它，到点时什么都不做，不崩溃。
    /// 这时 B 的启动画面在等 B 的提交（到时限后），兜底一旦错用就会把它结束。
    func testACallbackForADroppedPageDoesNothing() async throws {
        make()
        controller.launchScreenLimit = 0.05
        controller.pageRevealLimit = 0.2
        controller.beginLaunchScreen()
        try await waitUntil { count("启动画面到时限：网页还没提交，继续显示") == 1 }
        var a: PageLoadState? = PageLoadState()
        weak let dropped = a
        controller.showLoadProblem(.connecting, for: a!)
        controller.pageDidCommit(a!)
        controller.showLoadProblem(.hidden, for: a!)
        let window = windowState(), displayed = fields(b)
        a = nil
        XCTAssertNil(dropped, "排着的兜底不持有页面")
        try await pause(0.5)
        assertUntouched(window, displayed, "A 释放后兜底到点")
        XCTAssertTrue(controller.isShowingLaunchScreen)
    }

    /// 启动画面的时限和上限只对排下它们的那一次起作用：结束后又开始一次启动画面，前一次的上限到点时不结束这一次。
    /// （应用里只在启动时开始一次启动画面，这里只验证代号检查。）
    func testAnEarlierLaunchScreensCapDoesNotEndALaterOne() async throws {
        make()
        controller.launchScreenCap = 0.4
        controller.beginLaunchScreen()
        controller.endLaunchScreen("网页已加载")
        try await pause(0.2)
        controller.beginLaunchScreen()
        // 第一次的上限在 0.4 秒到点，第二次的在约 0.6 秒。
        try await pause(0.3)
        XCTAssertTrue(controller.isShowingLaunchScreen, "前一次的上限不生效")
        XCTAssertEqual(count("超过上限"), 0)
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertFalse(controller.isShowingLaunchScreen, "这一次的上限照常结束")
        XCTAssertEqual(count("启动画面结束：超过上限"), 1)
    }

    // MARK: - 启动画面属于启动的页面

    /// 启动画面是给 B 开始的：A 的加载完成、加载失败不结束它；B 的结束它，日志和原来一样。
    func testOnlyTheLaunchPagesFinishOrFailureEndsTheLaunchScreen() {
        for outcome in ["网页已加载", "加载失败"] {
            make()
            controller.beginLaunchScreen()
            let a = PageLoadState()
            controller.pageDidCommit(a)
            controller.endLaunchScreen("网页已加载", for: a)
            controller.pageDidFinishLoading(a, reportedColor: white)
            controller.endLaunchScreen("加载失败", for: a)
            controller.showLoadProblem(.waiting, for: a)
            XCTAssertTrue(controller.isShowingLaunchScreen, "\(outcome)：A 的事件不结束启动画面")
            XCTAssertNil(controller.launchFadeView)
            XCTAssertTrue(controller.isHoldingPageColor, "\(outcome)：B 的启动保护还在")
            XCTAssertEqual(count("启动画面结束"), 0)

            controller.endLaunchScreen(outcome, for: b)
            XCTAssertFalse(controller.isShowingLaunchScreen, "\(outcome)：B 的结束它")
            XCTAssertNotNil(controller.launchFadeView, "\(outcome)：照常淡出")
            let ended = diagnostics.entries.filter { $0.category == "launch" && $0.message.hasPrefix("启动画面结束") }.map(\.message)
            XCTAssertEqual(ended.count, 1)
            XCTAssertNotNil(ended.first?.range(of: "^启动画面结束：\(outcome)（\\d+ms）$", options: .regularExpression),
                            "\(outcome)：和原来一样的日志：\(ended)")
        }
    }

    /// 到时限时看的是启动的页面有没有提交：A 提交过不算，启动画面继续显示。
    func testTheLaunchLimitLooksAtTheLaunchPagesCommitOnly() async throws {
        make()
        controller.launchScreenLimit = 0.05
        let a = PageLoadState()
        controller.beginLaunchScreen()
        controller.pageDidCommit(a)
        try await waitUntil { count("启动画面到时限") == 1 }
        XCTAssertEqual(count("启动画面到时限：网页还没提交，继续显示"), 1)
        XCTAssertTrue(controller.isShowingLaunchScreen)
        XCTAssertEqual(count("启动画面结束"), 0)
    }

    // MARK: - 颜色

    /// A 加载完成时报的颜色和“第一次加载已完成”只记在 A 里，不采用到窗口，也不保存。
    func testABackgroundFinishRecordsItsColourOnlyInItsOwnState() async throws {
        make()
        let a = PageLoadState()
        XCTAssertFalse(a.hasFinishedFirstLoad)
        XCTAssertNil(a.colorAtLastFinish)
        controller.pageDidFinishLoading(a, reportedColor: white)
        XCTAssertTrue(a.hasFinishedFirstLoad)
        XCTAssertTrue(PageAppearance.sameColor(a.colorAtLastFinish, white))
        XCTAssertFalse(b.hasFinishedFirstLoad, "B 的不变")
        XCTAssertNil(b.colorAtLastFinish)
        try await pause(0.4)
        XCTAssertTrue(shown.isEmpty, "没有采用")
        XCTAssertTrue(PageAppearance.sameColor(appearance.background, savedDark))
        XCTAssertEqual(controller.chromeAppearance?.name, .darkAqua)
        let saved = try XCTUnwrap(defaults.array(forKey: "pageBackgroundRGB") as? [Double])
        XCTAssertEqual(saved[0], 0x0E / 255.0, accuracy: 0.001, "保存的颜色没变")

        // 加载完成时没有报颜色：颜色是 nil，第一次加载已完成照样记着。
        controller.pageDidFinishLoading(a, reportedColor: nil)
        XCTAssertTrue(a.hasFinishedFirstLoad)
        XCTAssertNil(a.colorAtLastFinish)
    }

    /// B 解除启动保护后在等颜色变化（到时限按当前颜色采用）。A 第一次加载完成、解除它自己的启动保护：B 的等待照常到点采用。
    func testABackgroundFinishDoesNotCancelTheDisplayedPagesSettleWait() async throws {
        make()
        controller.pageColorSettleLimit = 0.3
        controller.beginLaunchScreen()
        web.underPageBackgroundColor = white
        controller.endLaunchScreen("网页已加载")
        controller.pageDidFinishLoading()
        XCTAssertNotNil(b.colorBeforeFirstLoad, "B 在等颜色变化")
        let a = PageLoadState()
        a.holdsPageColor = true
        controller.pageDidFinishLoading(a, reportedColor: pageBlack)
        XCTAssertFalse(a.holdsPageColor)
        XCTAssertNil(a.colorBeforeFirstLoad)
        XCTAssertNotNil(b.colorBeforeFirstLoad, "B 还在等")
        try await waitUntil { appearance.isDark == false }
        XCTAssertEqual(appearance.isDark, false, "B 的等待到点按当前颜色采用")
        XCTAssertEqual(count("加载完成后 300ms 页面颜色没有变，按当前颜色采用"), 1)
        XCTAssertNil(b.colorBeforeFirstLoad)
        XCTAssertEqual(shown.count, 1)
    }

    /// B 报的颜色还在 150ms 的队里时 A 解除启动保护：这次更新照常生效。
    func testABackgroundReleaseDoesNotDropTheDisplayedPagesQueuedColour() async throws {
        make()
        web.underPageBackgroundColor = white
        let a = PageLoadState()
        a.holdsPageColor = true
        controller.pageDidFinishLoading(a, reportedColor: pageBlack)
        try await waitUntil { appearance.isDark == false }
        XCTAssertEqual(appearance.isDark, false, "排着队的更新照常采用")
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(PageAppearance.sameColor(appearance.background, white))
    }

    // MARK: - 不显示时的事件和显示着时一样落在页面自己的状态里

    /// 同一串事件：一份给不显示的 A（窗口显示着 B），一份给另一个窗口里显示着的 R。每一步之后 A 和 R 逐项一样，
    /// 只有 colorBeforeFirstLoad 不同：它是窗口等颜色变化用的，只给显示着的页面设（不显示的页面解除启动保护时保持 nil）。
    /// 显示着 B 的窗口从头到尾不变。
    func testABackgroundPagesEventsLandInItsStateAsIfItWereDisplayed() async throws {
        make()
        controller.pageRevealLimit = 0.2
        let reference = try makeReference()
        reference.controller.pageRevealLimit = 0.2
        let r = reference.controller.page
        let a = PageLoadState()
        let window = windowState(), displayed = fields(b)
        func step(_ name: String, file: StaticString = #filePath, line: UInt = #line,
                  _ event: (ChatWindowController, PageLoadState) -> Void) {
            event(controller, a)
            event(reference.controller, r)
            XCTAssertEqual(fields(a), fields(r), "\(name)：A 和显示着时一样", file: file, line: line)
            assertUntouched(window, displayed, name, file: file, line: line)
        }

        step("第一次加载失败") { $0.endLaunchScreen("加载失败", for: $1); $0.showLoadProblem(.waiting, for: $1) }
        step("正在连接") { $0.showLoadProblem(.connecting, for: $1) }
        step("提交") { $0.pageDidCommit($1) }
        step("收到可以收起：留着") { $0.showLoadProblem(.hidden, for: $1) }
        step("加载完成") { $0.pageDidFinishLoading($1, reportedColor: white) }
        step("又提交") { $0.pageDidCommit($1) }
        step("又失败") { $0.endLaunchScreen("加载失败", for: $1); $0.showLoadProblem(.waiting, for: $1) }
        step("又收到可以收起：留着") { $0.showLoadProblem(.hidden, for: $1) }
        XCTAssertTrue(a.noticeAwaitsLoad)
        try await waitUntil { !a.noticeAwaitsLoad && !r.noticeAwaitsLoad }
        XCTAssertEqual(fields(a), fields(r), "提交后兜底到点：A 和显示着时一样")
        XCTAssertEqual(a.notice, .hidden)
        assertUntouched(window, displayed, "A 的兜底到点")
        step("加载完成，没报颜色") { $0.pageDidFinishLoading($1, reportedColor: nil) }
        step("不再自动重试") { $0.showLoadProblem(.stopped, for: $1) }

        // 启动保护：R 由它的窗口进入（显示着的页面只能这样进入），A 直接设上（以后启动的页面换到后台时就是这样）。
        reference.controller.beginLaunchScreen()
        a.holdsPageColor = true
        XCTAssertEqual(fields(a), fields(r))
        controller.pageDidFinishLoading(a, reportedColor: pageBlack)
        reference.controller.pageDidFinishLoading(r, reportedColor: pageBlack)
        var expected = fields(r)
        XCTAssertEqual(expected.colorBefore, Self.rgb(pageBlack), "显示着的页面记下加载完成前的颜色，等它变化")
        expected.colorBefore = "nil"
        XCTAssertEqual(fields(a), expected, "解除启动保护：除了加载完成前的颜色，A 和显示着时一样")
        assertUntouched(window, displayed, "A 解除启动保护")
    }

    /// 另一个窗口，显示着它自己的页面。
    private func makeReference() throws -> (controller: ChatWindowController, web: WKWebView) {
        let name = "PageStateOwnershipTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        web.underPageBackgroundColor = blankDark
        let controller = ChatWindowController(webView: web, toolbar: EmptyView(), diagnostics: Diagnostics(),
                                              appearance: PageAppearance(defaults: defaults))
        addTeardownBlock { [controller] in controller.window?.orderOut(nil) }
        return (controller, web)
    }

    #if DEBUG
    // MARK: - 换走再换回来（测试用的接缝 setDisplayedPageForTesting，只换窗口认作显示着的页面）

    /// A 显示着时提交（排下兜底，代号 1），换到 B；A 在后台又加载（加载完成、又出问题、又提交，或者只是又提交），
    /// A 自己的状态照常变；再换回 A。代号 1 的兜底到点时：窗口不动，A 的状态也不动。按最后一次提交排下的兜底照常起作用。
    func testAStaleCommitFallbackStaysDeadAfterSwitchingAwayAndBack() async throws {
        for finishesInBetween in [true, false] {
            make()
            controller.pageRevealLimit = 0.6
            let a = PageLoadState()
            controller.setDisplayedPageForTesting(a)
            controller.showLoadProblem(.connecting, for: a)
            controller.pageDidCommit(a)
            controller.showLoadProblem(.hidden, for: a)
            XCTAssertEqual(fields(a), Fields(committed: true, awaiting: true, generation: 1, notice: .connecting, held: true))
            controller.setDisplayedPageForTesting(b)
            try await pause(0.3)
            if finishesInBetween {
                controller.pageDidFinishLoading(a, reportedColor: white)
                XCTAssertEqual(fields(a), Fields(committed: true, generation: 2, finished: true, finishColor: Self.rgb(white)),
                               "后台加载完成：A 的状态照常变")
                controller.showLoadProblem(.waiting, for: a)
                XCTAssertEqual(fields(a), Fields(committed: true, generation: 2, notice: .waiting, finished: true,
                                                 finishColor: Self.rgb(white)))
                controller.pageDidCommit(a)
                controller.showLoadProblem(.hidden, for: a)
                XCTAssertEqual(fields(a), Fields(committed: true, awaiting: true, generation: 3, notice: .waiting, held: true,
                                                 finished: true, finishColor: Self.rgb(white)), "后台又提交：A 的状态照常变")
            } else {
                controller.pageDidCommit(a)
                XCTAssertEqual(fields(a), Fields(committed: true, awaiting: true, generation: 2, notice: .connecting, held: true),
                               "后台又提交：A 的状态照常变")
            }
            XCTAssertEqual(count("收起"), 0)
            controller.setDisplayedPageForTesting(a)
            let window = windowState(), current = fields(a)
            // 代号 1 的兜底在 0.6 秒到点，后台那次提交的在约 0.9 秒。
            try await pause(0.45)
            XCTAssertEqual(windowState(), window, "旧的兜底：窗口不动（\(finishesInBetween)）")
            XCTAssertEqual(fields(a), current, "旧的兜底：A 的状态不动（\(finishesInBetween)）")
            try await waitUntil { !a.noticeAwaitsLoad }
            XCTAssertEqual(a.notice, .hidden, "按最后一次提交排下的兜底照常收起（\(finishesInBetween)）")
            XCTAssertNil(controller.shownLoadProblem)
            XCTAssertEqual(count("无法连接提示：提交后 600ms 还没加载完成，收起"), 1)
        }
    }

    /// 颜色的等待（加载完成后到时限按当前颜色采用）。
    /// - A 解除启动保护后换到 B 再换回来，A 这一段颜色没有往前走：等待到点照常采用（不是“换过就作废”）。
    /// - 换到 B 时到点：不是显示着的页面，什么都不做。
    /// - 换回 A 后 A 又开始一段（又进入、解除启动保护）：前一段的等待到点时不做事，这一段的照常采用。
    func testTheColourSettleWaitFollowsItsOwnPageAndGeneration() async throws {
        make()
        controller.pageColorSettleLimit = 0.3
        var a = PageLoadState()
        controller.setDisplayedPageForTesting(a)
        controller.beginLaunchScreen()
        web.underPageBackgroundColor = white
        controller.endLaunchScreen("网页已加载", for: a)
        controller.pageDidFinishLoading(a, reportedColor: web.underPageBackgroundColor)
        controller.setDisplayedPageForTesting(b)
        controller.setDisplayedPageForTesting(a)
        try await waitUntil { appearance.isDark == false }
        XCTAssertEqual(appearance.isDark, false, "换走又换回来：这一段的等待照常采用")
        XCTAssertEqual(count("加载完成后 300ms 页面颜色没有变，按当前颜色采用"), 1)
        XCTAssertNil(a.colorBeforeFirstLoad)

        make()
        controller.pageColorSettleLimit = 0.3
        a = PageLoadState()
        controller.setDisplayedPageForTesting(a)
        controller.beginLaunchScreen()
        web.underPageBackgroundColor = white
        controller.endLaunchScreen("网页已加载", for: a)
        controller.pageDidFinishLoading(a, reportedColor: web.underPageBackgroundColor)
        controller.setDisplayedPageForTesting(b)
        try await pause(0.6)
        XCTAssertTrue(shown.isEmpty, "到点时 A 不显示：不采用")
        XCTAssertEqual(count("页面颜色没有变"), 0)

        make()
        controller.pageColorSettleLimit = 0.5
        a = PageLoadState()
        controller.setDisplayedPageForTesting(a)
        controller.beginLaunchScreen()
        web.underPageBackgroundColor = white
        controller.endLaunchScreen("网页已加载", for: a)
        controller.pageDidFinishLoading(a, reportedColor: web.underPageBackgroundColor)
        controller.setDisplayedPageForTesting(b)
        controller.setDisplayedPageForTesting(a)
        try await pause(0.25)
        controller.beginLaunchScreen()
        controller.endLaunchScreen("网页已加载", for: a)
        controller.pageDidFinishLoading(a, reportedColor: web.underPageBackgroundColor)
        // 前一段的等待在 0.5 秒到点，这一段的在约 0.75 秒。
        try await pause(0.4)
        XCTAssertEqual(count("页面颜色没有变"), 0, "前一段的等待不生效")
        XCTAssertTrue(shown.isEmpty)
        XCTAssertNotNil(a.colorBeforeFirstLoad)
        try await waitUntil { appearance.isDark == false }
        XCTAssertEqual(appearance.isDark, false, "这一段的等待照常采用")
        XCTAssertEqual(count("加载完成后 500ms 页面颜色没有变，按当前颜色采用"), 1)
    }

    /// 换到 B 期间，窗口的颜色代号怎么变（都是真实代码里会让它变的做法）。
    private enum Supersede: String, CaseIterable {
        /// 显示着 B 时换成另一个网页视图，换回 A 之前再换回 A 的网页视图（以后切换标签页会这样换），每次换代号加一。
        case swapView = "换网页视图"
        /// 显示着的 B 开始启动画面（进入启动保护，代号加一），B 加载完成（解除启动保护，代号加一）。
        case holdAndRelease = "B 进入、解除启动保护"
    }

    /// 窗口显示着 a：换到 B，按 how 让窗口的颜色代号变，再换回 a。都是同步做的，150ms 的颜色更新还没到点。
    private func switchToBAndBack(from a: PageLoadState, superseding how: Supersede) {
        controller.setDisplayedPageForTesting(b)
        switch how {
        case .swapView:
            let other = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            other.underPageBackgroundColor = blankDark
            controller.replaceWebView(with: other)
            controller.replaceWebView(with: web)
        case .holdAndRelease:
            controller.beginLaunchScreen()
            controller.endLaunchScreen("网页已加载", for: b)
            controller.pageDidFinishLoading(b, reportedColor: web.underPageBackgroundColor)
        }
        controller.setDisplayedPageForTesting(a)
    }

    /// A 的颜色等待（加载完成后到时限按当前颜色采用）和 A 排着的 150ms 颜色更新属于排下它们时窗口的那一段颜色。
    /// 换到 B 期间那一段被取代（窗口的颜色代号变了，做法见 Supersede），再换回 A：到点时 A 又是显示着的页面，
    /// 但两个回调都不起作用——不采用、不保存，A 等待前记下的颜色也还记着。
    /// 对照：那一段没被取代、只是换走又换回来时照常采用；A 换回来后自己又开始一段时前一段的等待不起作用：
    /// 都见 testTheColourSettleWaitFollowsItsOwnPageAndGeneration。
    func testAColourCallbackFromASupersededEpisodeStaysDeadAfterSwitchingBack() async throws {
        for how in Supersede.allCases {
            make()
            controller.pageColorSettleLimit = 0.3
            let a = PageLoadState()
            controller.setDisplayedPageForTesting(a)
            controller.beginLaunchScreen()
            web.underPageBackgroundColor = white
            controller.endLaunchScreen("网页已加载", for: a)
            controller.pageDidFinishLoading(a, reportedColor: web.underPageBackgroundColor)
            XCTAssertTrue(PageAppearance.sameColor(a.colorBeforeFirstLoad, white), "\(how.rawValue)：A 在等颜色变化")
            switchToBAndBack(from: a, superseding: how)
            XCTAssertTrue(controller.page === a)
            // A 的等待在 0.3 秒到点；起作用的话再过 150ms 采用。
            try await pause(0.7)
            XCTAssertTrue(shown.isEmpty, "\(how.rawValue)：A 前一段的等待不采用")
            XCTAssertTrue(PageAppearance.sameColor(appearance.background, savedDark), "\(how.rawValue)")
            XCTAssertEqual(count("页面颜色没有变"), 0, "\(how.rawValue)：等待到点不做事")
            XCTAssertTrue(PageAppearance.sameColor(a.colorBeforeFirstLoad, white), "\(how.rawValue)：A 记下的颜色没有被这次等待清掉")

            make()
            let a2 = PageLoadState()
            controller.setDisplayedPageForTesting(a2)
            web.underPageBackgroundColor = white
            switchToBAndBack(from: a2, superseding: how)
            XCTAssertTrue(controller.page === a2)
            try await pause(0.5)
            XCTAssertTrue(shown.isEmpty, "\(how.rawValue)：A 前一段排着的更新不采用")
            XCTAssertTrue(PageAppearance.sameColor(appearance.background, savedDark), "\(how.rawValue)")
            XCTAssertEqual(count("页面底色："), 0, "\(how.rawValue)")
        }
    }

    /// 排着的 150ms 颜色更新只对排下它的页面起作用（窗口的颜色代号一直没变，只有“是不是这个页面”分得开）：
    /// - A 报的颜色还在队里时换到 B，到点时显示着的是 B：不采用。
    /// - 换到 B 又马上换回 A，还是那一段：照常采用。
    func testAQueuedColourUpdateOnlyActsForThePageThatQueuedIt() async throws {
        make()
        var a = PageLoadState()
        controller.setDisplayedPageForTesting(a)
        web.underPageBackgroundColor = white
        controller.setDisplayedPageForTesting(b)
        try await pause(0.5)
        XCTAssertTrue(shown.isEmpty, "到点时 A 不显示：不采用")
        XCTAssertTrue(PageAppearance.sameColor(appearance.background, savedDark))
        XCTAssertEqual(controller.chromeAppearance?.name, .darkAqua)
        XCTAssertEqual(count("页面底色："), 0)

        make()
        a = PageLoadState()
        controller.setDisplayedPageForTesting(a)
        web.underPageBackgroundColor = white
        controller.setDisplayedPageForTesting(b)
        controller.setDisplayedPageForTesting(a)
        try await waitUntil { appearance.isDark == false }
        XCTAssertEqual(appearance.isDark, false, "换走又马上换回来，还是那一段：照常采用")
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(count("页面底色：浅色"), 1)
    }

    /// 启动画面的时限和上限，启动的页面是 A。
    /// - 换到 B 再换回来，还是这一次启动画面：时限、上限照常起作用。
    /// - 换到 B 时到点：A 不显示，不动启动画面。
    /// - 换回 A 后又开始一次启动画面：前一次的上限到点时不结束这一次，这一次的照常结束。
    func testTheLaunchTimersFollowTheLaunchPageAndTheirOwnLaunch() async throws {
        make()
        controller.launchScreenLimit = 0.1
        controller.launchScreenCap = 0.4
        var a = PageLoadState()
        controller.setDisplayedPageForTesting(a)
        controller.beginLaunchScreen()
        controller.setDisplayedPageForTesting(b)
        controller.setDisplayedPageForTesting(a)
        try await waitUntil { count("启动画面到时限") == 1 }
        XCTAssertEqual(count("启动画面到时限：网页还没提交，继续显示"), 1, "换走又换回来：时限照常")
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertFalse(controller.isShowingLaunchScreen)
        XCTAssertEqual(count("启动画面结束：超过上限"), 1, "上限照常")

        make()
        controller.launchScreenLimit = 0.1
        controller.launchScreenCap = 0.3
        a = PageLoadState()
        controller.setDisplayedPageForTesting(a)
        controller.beginLaunchScreen()
        controller.setDisplayedPageForTesting(b)
        try await pause(0.5)
        XCTAssertTrue(controller.isShowingLaunchScreen, "到点时 A 不显示：不动启动画面")
        XCTAssertEqual(count("启动画面"), 0)
        // 显示着的 B 不是启动的页面：它的加载完成、失败也不结束 A 的启动画面。
        controller.endLaunchScreen("网页已加载", for: b)
        controller.endLaunchScreen("加载失败")
        XCTAssertTrue(controller.isShowingLaunchScreen, "启动画面只属于 A")
        XCTAssertEqual(count("启动画面"), 0)

        make()
        controller.launchScreenLimit = 0.4
        controller.launchScreenCap = 0.5
        a = PageLoadState()
        controller.setDisplayedPageForTesting(a)
        controller.beginLaunchScreen()
        controller.endLaunchScreen("网页已加载", for: a)
        controller.setDisplayedPageForTesting(b)
        controller.setDisplayedPageForTesting(a)
        try await pause(0.2)
        controller.launchScreenLimit = 0.8
        controller.launchScreenCap = 1.0
        controller.beginLaunchScreen()
        // 前一次的时限、上限在 0.4、0.5 秒到点，这一次的在约 1.0、1.2 秒。
        try await pause(0.5)
        XCTAssertTrue(controller.isShowingLaunchScreen, "前一次的上限不生效")
        XCTAssertEqual(count("启动画面到时限"), 0, "前一次的时限不生效")
        XCTAssertEqual(count("超过上限"), 0)
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertEqual(count("启动画面到时限：网页还没提交，继续显示"), 1, "这一次的时限照常")
        XCTAssertEqual(count("启动画面结束：超过上限"), 1, "这一次的上限照常")
    }
    #endif

    // MARK: - 只有一个页面时和原来一样

    /// 同样的配置两套：一套只用原来的入口，一套用带页面的入口（传 controller.page，加载完成时带上网页视图此刻报的颜色）。
    @MainActor private final class Rig {
        let explicit: Bool
        let web: WKWebView
        let appearance: PageAppearance
        let diagnostics = Diagnostics()
        let controller: ChatWindowController
        private(set) var shown: [NSColor?] = []
        private var watch: AnyCancellable?

        init(explicit: Bool, defaults: UserDefaults, reported: NSColor) {
            self.explicit = explicit
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            web.underPageBackgroundColor = reported
            appearance = PageAppearance(defaults: defaults)
            controller = ChatWindowController(webView: web, toolbar: EmptyView(), diagnostics: diagnostics, appearance: appearance)
            watch = appearance.$background.dropFirst().sink { [weak self] in self?.shown.append($0) }
        }

        func commit() { explicit ? controller.pageDidCommit(controller.page) : controller.pageDidCommit() }
        func finish() {
            explicit ? controller.pageDidFinishLoading(controller.page, reportedColor: web.underPageBackgroundColor)
                : controller.pageDidFinishLoading()
        }
        func problem(_ status: LoadRecovery.Status) {
            explicit ? controller.showLoadProblem(status, for: controller.page) : controller.showLoadProblem(status)
        }
        func end(_ outcome: String) {
            explicit ? controller.endLaunchScreen(outcome, for: controller.page) : controller.endLaunchScreen(outcome)
        }

        /// 断网后重试、网页提交、收到“可以收起”：和 PageRevealTests.offlineThenCommit 同样的顺序。
        func offlineThenCommit() {
            controller.beginLaunchScreen()
            end("加载失败")
            problem(.waiting)
            problem(.connecting)
            commit()
            problem(.hidden)
        }

        /// 日志的类别和内容，按顺序。启动画面结束那行最后的耗时每次不一样，换成同一个记号。
        /// 不算跟着真实鼠标、键盘、屏幕写的行（见 LiveInputLogLines）：两个窗口建立的时刻不同，用户按没按着鼠标也可能不同。
        var lines: [String] {
            LiveInputLogLines.compared(diagnostics.entries).map {
                "[\($0.category)] " + $0.message.replacingOccurrences(of: #"（\d+ms）$"#, with: "（…ms）", options: .regularExpression)
            }
        }

        /// 最后的状态。淡出那两层按动画时间拿掉，不比。
        var state: [String] {
            let p = controller.page
            return ["启动画面=\(controller.isShowingLaunchScreen)", "启动保护=\(controller.isHoldingPageColor)",
                    "提示=\(String(describing: controller.shownLoadProblem))", "页面颜色=\(rgb(appearance.background))",
                    "用过的颜色=\(shown.map(rgb))", "顶部外观=\(controller.chromeAppearance?.name.rawValue ?? "nil")",
                    "提交=\(p.hasCommittedPage) 等加载完成=\(p.awaitingFinish) 代号=\(p.commitGeneration) 提示=\(p.notice) "
                        + "留着=\(p.noticeAwaitsLoad) 启动保护=\(p.holdsPageColor) 加载完成前的颜色=\(rgb(p.colorBeforeFirstLoad)) "
                        + "第一次加载已完成=\(p.hasFinishedFirstLoad) 加载完成时的颜色=\(rgb(p.colorAtLastFinish))"]
        }

        private func rgb(_ color: NSColor?) -> String {
            guard let c = color?.usingColorSpace(.sRGB) else { return color == nil ? "nil" : "其他" }
            return String(format: "(%.3f, %.3f, %.3f)", c.redComponent, c.greenComponent, c.blueComponent)
        }
    }

    /// 两套同时走同样的步骤，日志一行不差、最后的状态一样。expected：每套的日志里都该有的内容，免得两边都是空的也算一样。
    private func compare(_ name: String, configure: (Rig) -> Void = { _ in }, expected: [String],
                         _ steps: ([Rig]) async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async throws {
        let suite = "PageStateOwnershipTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let rigs = [false, true].map { explicit in
            let defaults = UserDefaults(suiteName: "\(suite)-\(explicit)")!
            addTeardownBlock { UserDefaults().removePersistentDomain(forName: "\(suite)-\(explicit)") }
            let rgb = savedDark.usingColorSpace(.sRGB)!
            defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init), forKey: "pageBackgroundRGB")
            return Rig(explicit: explicit, defaults: defaults, reported: blankDark)
        }
        for rig in rigs {
            configure(rig)
            addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        }
        try await steps(rigs)
        let implicit = rigs[0], explicit = rigs[1]
        for text in expected {
            XCTAssertTrue(implicit.lines.contains { $0.contains(text) }, "\(name)：日志里有“\(text)”", file: file, line: line)
        }
        XCTAssertEqual(implicit.lines, explicit.lines, "\(name)：日志", file: file, line: line)
        XCTAssertEqual(implicit.state, explicit.state, "\(name)：最后的状态", file: file, line: line)
    }

    /// LaunchColourTests 的几段：恢复跟随、到时限采用、第一次加载失败后重试。
    func testOnePageLaunchColourSequencesLogTheSameLines() async throws {
        try await compare("加载完成前的颜色不采用，真实颜色采用", expected: ["启动保护：", "启动保护中：页面底色报为浅色", "启动画面结束：网页已加载",
                                                           "启动保护解除：加载完成时报的是浅色"]) { rigs in
            for rig in rigs { rig.controller.beginLaunchScreen() }
            for rig in rigs { rig.web.underPageBackgroundColor = white }
            for rig in rigs { rig.end("网页已加载") }
            for rig in rigs { rig.finish() }
            try await pause(0.4)
            for rig in rigs { rig.web.underPageBackgroundColor = pageBlack }
            try await waitUntil { rigs.allSatisfy { PageAppearance.sameColor($0.appearance.background, pageBlack) } }
        }
        try await compare("页面真是这个颜色：到时限采用", configure: { $0.controller.pageColorSettleLimit = 0.3 },
                          expected: ["加载完成后 300ms 页面颜色没有变，按当前颜色采用", "页面底色：浅色"]) { rigs in
            for rig in rigs { rig.controller.beginLaunchScreen() }
            for rig in rigs { rig.web.underPageBackgroundColor = white }
            for rig in rigs { rig.end("网页已加载") }
            for rig in rigs { rig.finish() }
            try await waitUntil { rigs.allSatisfy { $0.appearance.isDark == false } }
        }
        try await compare("第一次加载失败后重试", expected: ["启动画面结束：加载失败", "启动保护解除", "页面底色：浅色"]) { rigs in
            for rig in rigs { rig.controller.beginLaunchScreen() }
            for rig in rigs { rig.end("加载失败") }
            for rig in rigs { rig.web.underPageBackgroundColor = white }
            try await pause(0.3)
            for rig in rigs { rig.finish() }
            for rig in rigs { rig.web.underPageBackgroundColor = pageBlack }
            try await waitUntil { rigs.allSatisfy { PageAppearance.sameColor($0.appearance.background, pageBlack) } }
            for rig in rigs { rig.web.underPageBackgroundColor = white }
            try await waitUntil { rigs.allSatisfy { $0.appearance.isDark == false } }
        }
    }

    /// PageRevealTests 的几段：提示留到加载完成再淡出、提交后兜底收起、新问题、启动画面的时限、兜底和上限。
    func testOnePageRevealSequencesLogTheSameLines() async throws {
        try await compare("提示留到加载完成，淡出", configure: { $0.controller.pageColorSettleLimit = 0.05 },
                          expected: ["无法连接提示：网页已提交，留到加载完成", "无法连接提示：加载完成，淡出", "页面底色：浅色"]) { rigs in
            for rig in rigs { rig.offlineThenCommit() }
            for rig in rigs { rig.problem(.hidden) }
            try await pause(0.1)
            for rig in rigs { rig.web.underPageBackgroundColor = white }
            for rig in rigs { rig.end("网页已加载") }
            for rig in rigs { rig.finish() }
            try await waitUntil { rigs.allSatisfy { $0.appearance.isDark == false } }
        }
        try await compare("提交后兜底收起提示", configure: { $0.controller.pageRevealLimit = 0.3 },
                          expected: ["无法连接提示：提交后 300ms 还没加载完成，收起"]) { rigs in
            for rig in rigs { rig.offlineThenCommit() }
            try await waitUntil { rigs.allSatisfy { $0.controller.shownLoadProblem == nil } }
        }
        try await compare("留着时又失败，旧兜底不生效", configure: { $0.controller.pageRevealLimit = 0.2 },
                          expected: ["无法连接提示：网页已提交，留到加载完成"]) { rigs in
            for rig in rigs { rig.offlineThenCommit() }
            for rig in rigs { rig.problem(.waiting) }
            try await pause(0.4)
            for rig in rigs { rig.finish() }
        }
        try await compare("到时限还没提交，提交后兜底结束", configure: {
            $0.controller.launchScreenLimit = 0.05
            $0.controller.pageRevealLimit = 0.3
        }, expected: ["启动画面到时限：网页还没提交，继续显示", "启动画面结束：提交后 300ms 还没加载完成"]) { rigs in
            for rig in rigs { rig.controller.beginLaunchScreen() }
            try await pause(0.2)
            for rig in rigs { rig.commit() }
            try await waitUntil { rigs.allSatisfy { !$0.controller.isShowingLaunchScreen } }
        }
        try await compare("到上限结束", configure: {
            $0.controller.launchScreenLimit = 0.05
            $0.controller.launchScreenCap = 0.4
        }, expected: ["启动画面到时限", "启动画面结束：超过上限"]) { rigs in
            for rig in rigs { rig.controller.beginLaunchScreen() }
            try await waitUntil { rigs.allSatisfy { !$0.controller.isShowingLaunchScreen } }
        }
        try await compare("到时限时已提交", configure: { $0.controller.launchScreenLimit = 0.1 },
                          expected: ["启动画面结束：超过时限"]) { rigs in
            for rig in rigs { rig.controller.beginLaunchScreen() }
            for rig in rigs { rig.commit() }
            try await waitUntil { rigs.allSatisfy { !$0.controller.isShowingLaunchScreen } }
        }
    }
}
