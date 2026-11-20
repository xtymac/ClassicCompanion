import AppKit
import Combine
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 第一次加载的遮挡（启动画面）每个页面一份（PageLoadState 的 isCovered、coverAwaitsCommit、coverGeneration、coverStarted），
/// 规则只有 ChatWindowController 里那一套。B 是窗口显示着的页面（controller.page），A 是另一个页面（以后的后台标签页）。
/// 核对：
/// - 不显示的页面照常走自己的时限、上限、提交后兜底，按时结束自己的遮挡（再显示时不会一直盖着，也不会提前撤掉），
///   但不动窗口：启动画面那层、淡出那层、启动保护、提示、颜色、窗口的日志都不变；也不结束显示着的页面的遮挡。
/// - 显示着的页面盖着时，另一个页面的加载完成、失败、计时都不动它。
/// - 排着的计时只对排下它的那个页面、那一次遮挡起作用；提交后兜底只按最后一次提交起作用。
/// - 关闭的页面：不再开始遮挡，事件和计时都不改它的遮挡（停在关闭时），也不动窗口和别的页面。
///   显示着的页面关闭后启动画面停在关闭时的样子，换上别的页面时窗口照那个页面的遮挡显示（不会因为关闭的页面一直盖着）。
/// - 释放的页面：计时什么都不做；窗口显示着的页面由窗口持有，它的遮挡总能按时结束。
/// 只有一个页面时日志和窗口和改动之前一行不差，见 LaunchCoverTimelineTests（先在改动之前的代码上跑过）。
/// 换显示着的页面只用测试的接缝 setDisplayedPageForTesting(_:showingItsCover:)（不换网页视图，不是切换标签页的入口）。
/// WebKit 报的页面颜色和 LaunchColourTests 一样直接设 underPageBackgroundColor。这些测试不显示窗口。
@MainActor
final class CoverOwnershipTests: XCTestCase {
    private let savedDark = NSColor(srgbRed: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x0E / 255.0, alpha: 1)
    private let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    /// 起始颜色：不是白色（见 LaunchColourTests.make(saved:reported:)）。
    private let blankDark = NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)

    private var web: WKWebView!
    private var appearance: PageAppearance!
    private var controller: ChatWindowController!
    private var diagnostics: Diagnostics!
    /// 显示着的页面。
    private var b: PageLoadState!
    /// 顶部一条等原生部分用过的每一个颜色（PageAppearance.background 的每次变化）。
    private var shown: [NSColor?] = []
    private var watch: AnyCancellable?

    /// 记下的页面颜色是 savedDark，网页视图报着 blankDark，没有启动画面。显示着的页面是 b。
    /// 启动画面的时限和上限放长（每次开始遮挡时读，测试在开始之前按需要改）。
    private func make() {
        let name = "CoverOwnershipTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = UserDefaults(suiteName: name)!
        let rgb = savedDark.usingColorSpace(.sRGB)!
        defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init), forKey: "pageBackgroundRGB")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        web.underPageBackgroundColor = blankDark
        appearance = PageAppearance(defaults: defaults)
        diagnostics = Diagnostics()
        b = PageLoadState()
        controller = ChatWindowController(webView: web, toolbar: EmptyView(), diagnostics: diagnostics, appearance: appearance, page: b)
        controller.launchScreenLimit = 60
        controller.launchScreenCap = 60
        controller.pageRevealLimit = 60
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

    /// 一个页面的遮挡。
    private struct Cover: Equatable, CustomStringConvertible {
        var covered = false
        var awaits = false
        var generation = 0
        var description: String { "盖着=\(covered) 等提交=\(awaits) 代号=\(generation)" }
    }

    private func cover(_ p: PageLoadState) -> Cover {
        Cover(covered: p.isCovered, awaits: p.coverAwaitsCommit, generation: p.coverGeneration)
    }

    /// 一个页面的全部状态（遮挡开始的时刻也算），用来核对显示着的页面一点没变。
    private func all(_ p: PageLoadState) -> String {
        "\(cover(p)) 开始=\(p.coverStarted.timeIntervalSinceReferenceDate) 提交=\(p.hasCommittedPage) 等加载完成=\(p.awaitingFinish) "
            + "代号=\(p.commitGeneration) 提示=\(p.notice) 留着=\(p.noticeAwaitsLoad) 启动保护=\(p.holdsPageColor) "
            + "加载完成前的颜色=\(Self.rgb(p.colorBeforeFirstLoad)) 第一次加载已完成=\(p.hasFinishedFirstLoad) "
            + "加载完成时的颜色=\(Self.rgb(p.colorAtLastFinish)) 关闭=\(p.isClosed)"
    }

    /// 窗口上看得见的一切，加上窗口的日志（不算跟着真实鼠标、键盘、屏幕写的行，见 LiveInputLogLines）。
    private func windowState() -> [String] {
        [
            "启动画面=\(controller.isShowingLaunchScreen)",
            "启动画面淡出那层=\(Self.identity(controller.launchFadeView))",
            "启动保护=\(controller.isHoldingPageColor)",
            "提示=\(String(describing: controller.shownLoadProblem))",
            "提示淡出那层=\(Self.identity(controller.loadProblemFadeView))",
            "页面颜色=\(Self.rgb(appearance.background))",
            "顶部外观=\(controller.chromeAppearance?.name.rawValue ?? "nil")",
            "窗口底色=\(Self.rgb(controller.window?.backgroundColor))",
            "用过的颜色=\(shown.map { Self.rgb($0) })",
        ] + LiveInputLogLines.compared(diagnostics.entries).map { "[\($0.category)] \($0.message)" }
    }

    /// 窗口和显示着的页面 B 都和之前一样。
    private func assertUntouched(_ window: [String], _ displayed: String, _ step: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(windowState(), window, "\(step)：窗口", file: file, line: line)
        XCTAssertEqual(all(b), displayed, "\(step)：显示着的页面", file: file, line: line)
    }

    private static func identity(_ view: NSView?) -> String {
        view.map { "\(ObjectIdentifier($0))" } ?? "无"
    }

    private static func rgb(_ color: NSColor?) -> String {
        guard let color else { return "nil" }
        guard let c = color.usingColorSpace(.sRGB) else { return color.description }
        return String(format: "(%.3f, %.3f, %.3f, a %.2f)", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    /// 启动画面结束那行日志里的毫秒数。
    private func endedMilliseconds(_ prefix: String) throws -> Int {
        let line = try XCTUnwrap(diagnostics.entries.last { $0.message.hasPrefix(prefix) }?.message, "有一行“\(prefix)”")
        return try XCTUnwrap(Int(line.replacingOccurrences(of: #"^.*（(\d+)ms）$"#, with: "$1", options: .regularExpression)), line)
    }

    #if DEBUG
    /// 让 A 盖着自己的遮挡、但不显示：先把 A 当作显示着的、开始遮挡（时限 limit、上限 cap），再换回 B，
    /// 把 B 的遮挡投到窗口上（B 没有遮挡时窗口的启动画面藏起）。B 盖着（displayedCovered）时之后再给 B 开始一次长的遮挡。
    /// 都做完以后时限和上限放回很长。
    private func coverInBackground(_ a: PageLoadState, limit: TimeInterval, cap: TimeInterval, displayedCovered: Bool) {
        controller.setDisplayedPageForTesting(a)
        controller.launchScreenLimit = limit
        controller.launchScreenCap = cap
        controller.beginLaunchScreen()
        controller.launchScreenLimit = 60
        controller.launchScreenCap = 60
        controller.setDisplayedPageForTesting(b, showingItsCover: true)
        if displayedCovered { controller.beginLaunchScreen() }
        XCTAssertEqual(cover(a), Cover(covered: true, generation: 1))
        XCTAssertTrue(a.holdsPageColor, "A 进入它自己的启动保护")
        XCTAssertEqual(controller.isShowingLaunchScreen, displayedCovered, "窗口照显示着的 B 盖不盖")
        XCTAssertEqual(b.isCovered, displayedCovered)
    }

    // MARK: - 不显示的页面按时结束自己的遮挡，不动窗口

    /// A 不显示，网页一直没提交。到时限：A 继续盖着、等提交；到上限：A 的遮挡结束。两次都只改 A：
    /// 窗口（盖着 B 的或没盖）、淡出那层、日志、B 一点不变。B 盖着时之后 B 自己的结束照常。
    func testABackgroundCoverRunsOutOnItsOwnWithoutTouchingTheWindow() async throws {
        for displayedCovered in [false, true] {
            make()
            let a = PageLoadState()
            coverInBackground(a, limit: 0.1, cap: 0.4, displayedCovered: displayedCovered)
            let window = windowState(), displayed = all(b)

            try await waitUntil { a.coverAwaitsCommit }
            XCTAssertEqual(cover(a), Cover(covered: true, awaits: true, generation: 1), "到时限还没提交：继续盖着（B 盖着=\(displayedCovered)）")
            assertUntouched(window, displayed, "A 到时限（B 盖着=\(displayedCovered)）")

            try await waitUntil { !a.isCovered }
            XCTAssertEqual(cover(a), Cover(generation: 1), "到上限：A 的遮挡结束（B 盖着=\(displayedCovered)）")
            assertUntouched(window, displayed, "A 到上限（B 盖着=\(displayedCovered)）")
            XCTAssertEqual(count("启动画面到时限"), 0)
            XCTAssertEqual(count("启动画面结束"), 0)
            XCTAssertTrue(a.holdsPageColor, "遮挡结束不解除启动保护（和显示着时一样）")

            guard displayedCovered else { continue }
            controller.endLaunchScreen("网页已加载")
            XCTAssertFalse(controller.isShowingLaunchScreen, "B 自己的结束照常")
            XCTAssertNotNil(controller.launchFadeView)
            XCTAssertEqual(count("启动画面结束：网页已加载"), 1)
        }
    }

    /// A 不显示、盖着，B 显示着、也盖着。A 的遮挡按应用里的每一种方式结束（加载完成、加载失败、到时限时已提交、
    /// 到时限后提交兜底、上限）：只有 A 的遮挡结束，B 的遮挡、窗口（还盖着、没有淡出）、日志、B 的状态都不变。
    /// 之后 B 自己的加载完成照常结束窗口的启动画面，写一行日志。
    func testABackgroundCoverEndsOnItsOwnEventsAndNeverEndsTheDisplayedOne() async throws {
        let ways = ["网页已加载", "加载失败", "到时限时已提交", "到时限后提交兜底", "上限"]
        for way in ways {
            make()
            let a = PageLoadState()
            let short = way == "到时限时已提交" || way == "到时限后提交兜底" || way == "上限"
            if way == "到时限时已提交" { controller.pageDidCommit(a) }
            coverInBackground(a, limit: short ? 0.1 : 60, cap: way == "上限" ? 0.4 : 60, displayedCovered: true)
            let window = windowState(), displayed = all(b)

            switch way {
            case "网页已加载":
                controller.endLaunchScreen("网页已加载", for: a)
                controller.pageDidFinishLoading(a, reportedColor: white)
            case "加载失败":
                controller.showLoadProblem(.waiting, for: a)
                controller.endLaunchScreen("加载失败", for: a)
            case "到时限后提交兜底":
                controller.pageRevealLimit = 0.2
                try await waitUntil { a.coverAwaitsCommit }
                controller.pageDidCommit(a)
                try await pause(0.1)
                XCTAssertTrue(a.isCovered, "兜底之前还盖着")
            default:
                break
            }
            try await waitUntil { !a.isCovered }
            XCTAssertEqual(cover(a), Cover(generation: 1), "\(way)：A 的遮挡结束")
            assertUntouched(window, displayed, "\(way)：A 的遮挡结束")
            try await pause(0.3)
            assertUntouched(window, displayed, "\(way)：之后")
            XCTAssertTrue(controller.isShowingLaunchScreen, "\(way)：窗口还盖着 B 的")

            controller.endLaunchScreen("网页已加载")
            XCTAssertFalse(controller.isShowingLaunchScreen, "\(way)：B 自己的结束照常")
            XCTAssertNotNil(controller.launchFadeView)
            let ended = diagnostics.entries.filter { $0.message.hasPrefix("启动画面结束") }.map(\.message)
            XCTAssertEqual(ended.count, 1, "\(way)：只有 B 的一行：\(ended)")
            XCTAssertNotNil(ended.first?.range(of: #"^启动画面结束：网页已加载（\d+ms）$"#, options: .regularExpression), "\(way)")
        }
    }

    /// 两个遮挡各走各的钟：B（显示着）时限 0.1、上限 0.6，A（不显示）时限 0.1、上限 0.3。
    /// A 到上限时只有 A 结束；窗口的日志只有 B 的到时限和 B 的上限各一行。
    func testTwoCoversRunOnTheirOwnClocks() async throws {
        make()
        let a = PageLoadState()
        coverInBackground(a, limit: 0.1, cap: 0.3, displayedCovered: false)
        controller.launchScreenLimit = 0.1
        controller.launchScreenCap = 0.6
        controller.beginLaunchScreen()
        try await waitUntil { !a.isCovered }
        XCTAssertTrue(b.isCovered, "A 到上限时 B 还盖着")
        XCTAssertTrue(controller.isShowingLaunchScreen)
        XCTAssertEqual(count("启动画面结束"), 0)
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertFalse(b.isCovered)
        XCTAssertEqual(count("启动画面到时限：网页还没提交，继续显示"), 1, "只有 B 的")
        XCTAssertEqual(count("启动画面结束：超过上限"), 1, "只有 B 的")
        let ms = try endedMilliseconds("启动画面结束：超过上限")
        XCTAssertGreaterThanOrEqual(ms, 590, "是 B 的上限结束的（不是 A 的）")
    }

    // MARK: - 旧的计时、旧的兜底

    /// A 不显示：第一次遮挡（时限 0.3、上限 0.5）马上因加载完成结束，0.1 秒后又开始一次（时限 0.8、上限 1.0）。
    /// 第一次的时限、上限到点时 A 的第二次遮挡不动；第二次的照常：到时限等提交，到上限结束。窗口从头到尾不变。
    func testLateTimersOfAnEarlierCoverOfABackgroundPageDoNothing() async throws {
        make()
        let a = PageLoadState()
        coverInBackground(a, limit: 0.3, cap: 0.5, displayedCovered: false)
        controller.endLaunchScreen("网页已加载", for: a)
        XCTAssertEqual(cover(a), Cover(generation: 1))
        try await pause(0.1)
        coverInBackground2(a, limit: 0.8, cap: 1.0)
        XCTAssertEqual(cover(a), Cover(covered: true, generation: 2))
        let window = windowState(), displayed = all(b)
        // 第一次的时限、上限在 0.3、0.5 秒到点，第二次的在约 0.9、1.1 秒。
        try await pause(0.55)
        XCTAssertEqual(cover(a), Cover(covered: true, generation: 2), "第一次的时限、上限不动第二次")
        assertUntouched(window, displayed, "第一次的计时到点")
        try await waitUntil { a.coverAwaitsCommit }
        XCTAssertEqual(cover(a), Cover(covered: true, awaits: true, generation: 2), "第二次的时限照常")
        try await waitUntil { !a.isCovered }
        XCTAssertEqual(cover(a), Cover(generation: 2), "第二次的上限照常")
        assertUntouched(window, displayed, "第二次的计时到点")
    }

    /// 已经盖着过一次的 A 再开始一次（不检查第一次的结果）。
    private func coverInBackground2(_ a: PageLoadState, limit: TimeInterval, cap: TimeInterval) {
        controller.setDisplayedPageForTesting(a)
        controller.launchScreenLimit = limit
        controller.launchScreenCap = cap
        controller.beginLaunchScreen()
        controller.launchScreenLimit = 60
        controller.launchScreenCap = 60
        controller.setDisplayedPageForTesting(b, showingItsCover: true)
    }

    /// A 不显示，到时限还没提交、在等提交。
    /// - 提交两次：第一次的兜底到点时 A 还盖着，按最后一次提交计时结束。
    /// - 提交后加载完成（应用里加载完成先结束遮挡，这里故意不结束）：兜底到点不做事（已经不在等加载完成），A 还盖着、还在等。
    /// 窗口从头到尾不变。
    func testOnlyTheLatestCommitsFallbackEndsABackgroundCover() async throws {
        make()
        controller.pageRevealLimit = 0.4
        var a = PageLoadState()
        coverInBackground(a, limit: 0.05, cap: 60, displayedCovered: false)
        try await waitUntil { a.coverAwaitsCommit }
        var window = windowState(), displayed = all(b)
        controller.pageDidCommit(a)
        try await pause(0.2)
        controller.pageDidCommit(a)
        // 第一次的兜底在 0.4 秒到点，第二次的在约 0.6 秒。
        try await pause(0.3)
        XCTAssertEqual(cover(a), Cover(covered: true, awaits: true, generation: 1), "第一次提交的兜底不生效")
        try await waitUntil { !a.isCovered }
        XCTAssertEqual(cover(a), Cover(generation: 1), "按最后一次提交结束")
        assertUntouched(window, displayed, "两次提交")

        make()
        controller.pageRevealLimit = 0.2
        a = PageLoadState()
        coverInBackground(a, limit: 0.05, cap: 60, displayedCovered: false)
        try await waitUntil { a.coverAwaitsCommit }
        window = windowState()
        displayed = all(b)
        controller.pageDidCommit(a)
        controller.pageDidFinishLoading(a, reportedColor: white)
        try await pause(0.4)
        XCTAssertEqual(cover(a), Cover(covered: true, awaits: true, generation: 1), "加载完成以后兜底不做事")
        assertUntouched(window, displayed, "提交后加载完成")
    }

    // MARK: - 关闭的页面

    /// A 不显示、盖着，B 显示着、也盖着。A 关闭以后：它的结束、提交、时限、上限都不改 A 的遮挡（停在关闭时），
    /// 窗口和 B 不变；B 自己的结束照常。关闭前就排着的提交后兜底（A 到时限后在等提交）到点也不做事。
    func testAClosedBackgroundPagesCoverStaysFrozenAndTouchesNothing() async throws {
        for awaiting in [false, true] {
            make()
            controller.pageRevealLimit = 0.2
            let a = PageLoadState()
            coverInBackground(a, limit: awaiting ? 0.05 : 0.1, cap: 0.4, displayedCovered: true)
            if awaiting {
                try await waitUntil { a.coverAwaitsCommit }
                controller.pageDidCommit(a)
            }
            let frozen = cover(a)
            XCTAssertEqual(frozen, Cover(covered: true, awaits: awaiting, generation: 1))
            let window = windowState(), displayed = all(b)
            controller.pageClosed(a)
            controller.endLaunchScreen("网页已加载", for: a)
            controller.endLaunchScreen("加载失败", for: a)
            controller.pageDidCommit(a)
            XCTAssertEqual(cover(a), frozen, "关闭以后的事件（在等提交=\(awaiting)）")
            try await pause(0.6)
            XCTAssertEqual(cover(a), frozen, "关闭以后时限、上限、兜底到点（在等提交=\(awaiting)）")
            assertUntouched(window, displayed, "A 关闭以后（在等提交=\(awaiting)）")
            controller.endLaunchScreen("网页已加载")
            XCTAssertFalse(controller.isShowingLaunchScreen, "B 自己的结束照常（在等提交=\(awaiting)）")
            XCTAssertEqual(count("启动画面结束"), 1)
        }
    }

    /// 关闭的页面不开始遮挡：把关闭的 A 当作显示着的、开始启动画面：A 的遮挡、启动保护、窗口、日志都不变。
    /// 对照：没关闭时开始了。
    func testAClosedPageNeverStartsACover() {
        for closes in [false, true] {
            make()
            let a = PageLoadState()
            controller.setDisplayedPageForTesting(a)
            let window = windowState(), state = all(a)
            if closes { controller.pageClosed(a) }
            controller.beginLaunchScreen()
            if closes {
                XCTAssertEqual(windowState(), window, "关闭的页面：窗口不变")
                XCTAssertEqual(all(a), state.replacingOccurrences(of: "关闭=false", with: "关闭=true"), "关闭的页面：状态不变")
            } else {
                XCTAssertEqual(cover(a), Cover(covered: true, generation: 1), "对照：开始了")
                XCTAssertTrue(controller.isShowingLaunchScreen)
                XCTAssertTrue(a.holdsPageColor)
            }
        }
    }

    /// 显示着的 B 盖着时关闭：启动画面停在关闭时（和以前一样，见 PageCloseTests），B 的计时到点也不动它。
    /// 换上没有遮挡的 A（把 A 的遮挡投到窗口上）：窗口不再盖着，之后 B 的上限到点也不再盖上、不写日志。
    /// 换上还盖着的 A：窗口照 A 盖着，A 自己的结束照常撤掉。关闭的页面不会让窗口一直盖着，也不会结束别的页面的遮挡。
    func testAClosedDisplayedPagesCoverGoesAwayWithIt() async throws {
        for aCovered in [false, true] {
            make()
            let a = PageLoadState()
            if aCovered { coverInBackground(a, limit: 60, cap: 60, displayedCovered: false) }
            controller.launchScreenLimit = 0.1
            controller.launchScreenCap = 0.4
            controller.beginLaunchScreen()
            controller.pageClosed(b)
            try await pause(0.2)
            XCTAssertTrue(controller.isShowingLaunchScreen, "关闭的 B 显示着时启动画面停着")
            XCTAssertEqual(count("启动画面到时限"), 0, "关闭以后 B 的时限不动作")
            controller.setDisplayedPageForTesting(a, showingItsCover: true)
            XCTAssertEqual(controller.isShowingLaunchScreen, aCovered, "窗口照换上来的 A 盖不盖（A 盖着=\(aCovered)）")
            try await pause(0.4)
            XCTAssertEqual(controller.isShowingLaunchScreen, aCovered, "B 的上限到点不动窗口（A 盖着=\(aCovered)）")
            XCTAssertEqual(cover(a), Cover(covered: aCovered, generation: aCovered ? 1 : 0), "也不动 A")
            XCTAssertEqual(count("启动画面"), 0)
            guard aCovered else { continue }
            controller.endLaunchScreen("网页已加载", for: a)
            XCTAssertFalse(controller.isShowingLaunchScreen, "A 自己的结束照常")
            XCTAssertEqual(count("启动画面结束：网页已加载"), 1)
        }
    }

    // MARK: - 释放的页面

    /// A 不显示、盖着（时限 0.1、上限 0.3），B 显示着、也盖着。A 释放：计时不持有它，到点时什么都不做，窗口和 B 不变。
    func testAReleasedBackgroundPagesCoverTimersDoNothing() async throws {
        make()
        var a: PageLoadState? = PageLoadState()
        weak let dropped = a
        coverInBackground(a!, limit: 0.1, cap: 0.3, displayedCovered: true)
        let window = windowState(), displayed = all(b)
        a = nil
        XCTAssertNil(dropped, "计时不持有页面")
        try await pause(0.5)
        assertUntouched(window, displayed, "A 释放后计时到点")
        XCTAssertTrue(controller.isShowingLaunchScreen)
    }
    #endif

    /// 窗口持有显示着的页面：别处都不再持有它，它的遮挡照样按上限结束（启动画面不会因为页面释放而一直盖着）。
    func testTheWindowHoldsTheDisplayedPageSoItsCoverEnds() async throws {
        weak var held: PageLoadState?
        let name = "CoverOwnershipTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        diagnostics = Diagnostics()
        let window: ChatWindowController = autoreleasepool {
            let page = PageLoadState()
            held = page
            return ChatWindowController(webView: WKWebView(), toolbar: EmptyView(), diagnostics: diagnostics,
                                        appearance: PageAppearance(defaults: UserDefaults(suiteName: name)!), page: page)
        }
        addTeardownBlock { window.window?.orderOut(nil) }
        window.launchScreenLimit = 0.05
        window.launchScreenCap = 0.3
        window.beginLaunchScreen()
        try await waitUntil { !window.isShowingLaunchScreen }
        XCTAssertNotNil(held, "窗口持有它")
        XCTAssertFalse(window.isShowingLaunchScreen)
        XCTAssertEqual(count("启动画面结束：超过上限"), 1)
    }

    #if DEBUG
    // MARK: - 再显示时照它自己的遮挡

    /// 不显示时结束了的遮挡，换上来时窗口不盖（不会一直盖着）；不显示时还在等提交的，换上来时窗口盖着（不会提前撤掉），
    /// 之后照它自己的规则结束：提交后兜底撤掉、淡出，日志里的耗时从它自己开始遮挡时算。
    /// 还没到时限就换上来：时限到点时它显示着，照显示着时一样写“到时限”、继续盖着。
    func testABackgroundCoverIsShownAsItStandsWhenThePageIsDisplayed() async throws {
        make()
        var a = PageLoadState()
        coverInBackground(a, limit: 0.05, cap: 0.3, displayedCovered: true)
        try await waitUntil { !a.isCovered }
        XCTAssertTrue(controller.isShowingLaunchScreen, "窗口盖着 B 的")
        let lines = diagnostics.entries.count
        controller.setDisplayedPageForTesting(a, showingItsCover: true)
        XCTAssertFalse(controller.isShowingLaunchScreen, "结束了的遮挡：不盖")
        XCTAssertNil(controller.launchFadeView, "不淡出")
        XCTAssertEqual(diagnostics.entries.count, lines, "不写日志")

        make()
        controller.pageRevealLimit = 0.2
        a = PageLoadState()
        let started = Date()
        coverInBackground(a, limit: 0.05, cap: 60, displayedCovered: false)
        try await waitUntil { a.coverAwaitsCommit }
        try await pause(0.2)
        controller.setDisplayedPageForTesting(a, showingItsCover: true)
        XCTAssertTrue(controller.isShowingLaunchScreen, "还在等提交的遮挡：盖着")
        controller.pageDidCommit(a)
        try await pause(0.1)
        XCTAssertTrue(controller.isShowingLaunchScreen, "兜底之前还盖着")
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertNotNil(controller.launchFadeView, "照常淡出")
        XCTAssertFalse(a.isCovered)
        let ms = try endedMilliseconds("启动画面结束：提交后 200ms 还没加载完成")
        XCTAssertGreaterThanOrEqual(ms, 450, "从 A 开始遮挡时算")
        XCTAssertLessThanOrEqual(ms, Int(Date().timeIntervalSince(started) * 1000))
        XCTAssertEqual(count("启动画面到时限"), 0, "A 不显示时到的时限不写日志")

        make()
        a = PageLoadState()
        coverInBackground(a, limit: 0.4, cap: 60, displayedCovered: false)
        try await pause(0.1)
        controller.setDisplayedPageForTesting(a, showingItsCover: true)
        XCTAssertTrue(controller.isShowingLaunchScreen)
        try await waitUntil { a.coverAwaitsCommit }
        XCTAssertTrue(controller.isShowingLaunchScreen, "到时限还没提交：继续盖着")
        XCTAssertEqual(count("启动画面到时限：网页还没提交，继续显示"), 1, "显示着时到的时限照常写")
    }
    #endif
}
