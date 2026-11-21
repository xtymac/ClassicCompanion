import AppKit
import Combine
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 新标签页的遮挡（PageLoadState.CoverKind.newTab）：样子和启动画面不同（页面底色加小进度圈，没有图标和应用名），
/// 规则、时限、上限和启动画面是同一套（ChatWindowController.beginCover(for:kind:) 以下）。B 是窗口显示着的页面
/// （标签 1），A 是另一个页面（标签 2，以后的新标签页）。核对：
/// - 给不显示的 A 开始新标签页的遮挡（beginNewTabCover(for:)）：A 盖着、进入它自己的启动保护、计时开始；窗口一点不变
///   （启动画面那层和它的样子、淡出、启动保护、提示、颜色、日志），B 也不变。
/// - 窗口照显示着的页面的遮挡显示样子：换显示着的页面（display(_:webView:)）时启动画面 ↔ 新标签页的遮挡跟着换；淡出那层是结束的那种。
/// - 显示着的页面盖着新标签页的遮挡时，规则和日志和启动画面一行不差（每种结束方式各走两遍逐步比），只是结束的那一行
///   带它的标签（11-21）。新标签页的遮挡另外在页面开始显示时就撤：这里的页面不报颜色，那条在 NewTabEarlyRevealTests 里测。
/// - 不显示的页面的遮挡结束时写一行带它的标签的日志（原因和耗时，没有地址），窗口和 B 不变；没有标签的页面不写。
///   到时限还没提交时继续盖着、不写日志。显示着的页面的其余日志不变。
/// - 还盖着的页面被显示时沿用它自己的计时（不重新开始）。
/// - 关闭的页面不开始遮挡。
/// - “启动画面还在”（ChatTabs.isLaunchScreenUp）：只看启动时的那种遮挡还盖着，新标签页的遮挡不算。
/// 换显示着的页面用切换标签页的入口 ChatWindowController.display(_:webView:)（连同网页视图一起换，投上那个页面的遮挡）；
/// 只要“窗口当作显示着的页面换一下、别的都不做”的地方用测试的接缝 setDisplayedPageForTesting(_:)。
/// 这些测试不显示窗口；遮挡在屏幕上的样子（浅色、深色）要上屏看。
@MainActor
final class NewTabCoverTests: XCTestCase {
    private let savedDark = NSColor(srgbRed: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x0E / 255.0, alpha: 1)
    private let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    /// 起始颜色：不是白色（见 LaunchColourTests.make(saved:reported:)）。
    private let blankDark = NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)

    private var web: WKWebView!
    private var appearance: PageAppearance!
    private var controller: ChatWindowController!
    private var diagnostics: Diagnostics!
    /// 显示着的页面（标签 1）。
    private var b: PageLoadState!
    /// 另一个页面的标签（标签 2）。
    private var second: TabID!
    /// 顶部一条等原生部分用过的每一个颜色（PageAppearance.background 的每次变化）。
    private var shown: [NSColor?] = []
    private var watch: AnyCancellable?

    /// 记下的页面颜色是 savedDark，网页视图报着 blankDark，没有遮挡。显示着的页面是 b（标签 1）。
    /// 遮挡的时限和上限、提交后兜底放长（每次开始遮挡时读，测试在开始之前按需要改）。
    private func make() {
        let name = "NewTabCoverTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = UserDefaults(suiteName: name)!
        let rgb = savedDark.usingColorSpace(.sRGB)!
        defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init), forKey: "pageBackgroundRGB")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        web.underPageBackgroundColor = blankDark
        appearance = PageAppearance(defaults: defaults)
        diagnostics = Diagnostics()
        var list = TabList()
        guard case .added(let id) = list.append(select: false) else { preconditionFailure("加得进第二个") }
        second = id
        b = PageLoadState(logTag: list.selected)
        controller = ChatWindowController(webView: web, toolbar: EmptyView(), diagnostics: diagnostics, appearance: appearance, page: b)
        controller.launchScreenLimit = 60
        controller.launchScreenCap = 60
        controller.pageRevealLimit = 60
        addTeardownBlock { [controller] in controller?.window?.orderOut(nil) }
        shown = []
        watch = appearance.$background.dropFirst().sink { [weak self] in self?.shown.append($0) }
    }

    /// A：标签 2 的页面。
    private func makeA() -> PageLoadState {
        PageLoadState(logTag: second)
    }

    /// 另一个页面的网页视图（换上那个页面时一起换上），开始时报着 blankDark。
    private func makeWeb() -> WKWebView {
        let other = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        other.underPageBackgroundColor = blankDark
        return other
    }

    /// 给不显示的 p 开始新标签页的遮挡，这一次的时限和上限是 limit、cap；之后放回很长。
    private func beginNewTab(_ p: PageLoadState, limit: TimeInterval = 60, cap: TimeInterval = 60) {
        controller.launchScreenLimit = limit
        controller.launchScreenCap = cap
        controller.beginNewTabCover(for: p)
        controller.launchScreenLimit = 60
        controller.launchScreenCap = 60
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await pause(0.02) }
    }

    // MARK: - 核对用

    /// 一个页面的遮挡。
    private struct Cover: Equatable, CustomStringConvertible {
        var covered = false
        var awaits = false
        var kind = PageLoadState.CoverKind.launch
        var generation = 0
        var description: String { "盖着=\(covered) 等提交=\(awaits) 样子=\(kind) 代号=\(generation)" }
    }

    private func cover(_ p: PageLoadState) -> Cover {
        Cover(covered: p.isCovered, awaits: p.coverAwaitsCommit, kind: p.coverKind, generation: p.coverGeneration)
    }

    /// 一个页面的全部状态（遮挡开始的时刻也算），用来核对显示着的页面一点没变。
    private func all(_ p: PageLoadState) -> String {
        "\(cover(p)) 开始=\(p.coverStarted.timeIntervalSinceReferenceDate) 提交=\(p.hasCommittedPage) 等加载完成=\(p.awaitingFinish) "
            + "代号=\(p.commitGeneration) 提示=\(p.notice) 留着=\(p.noticeAwaitsLoad) 启动保护=\(p.holdsPageColor) "
            + "加载完成前的颜色=\(Self.rgb(p.colorBeforeFirstLoad)) 第一次加载已完成=\(p.hasFinishedFirstLoad) "
            + "加载完成时的颜色=\(Self.rgb(p.colorAtLastFinish)) 关闭=\(p.isClosed) 标签=\(p.logTag.map { "\($0.rawValue)" } ?? "无")"
    }

    /// 窗口上看得见的一切（不含日志）：遮挡那层和它的样子、淡出那层和它的样子、启动保护、提示、颜色。
    private func look() -> [String] {
        [
            "启动画面=\(controller.isShowingLaunchScreen)",
            "样子=\(controller.shownCoverKind.map { "\($0)" } ?? "无")",
            "启动画面淡出那层=\(Self.identity(controller.launchFadeView))",
            "淡出那层的样子=\(controller.launchFadeView.map { "\($0.rootView.kind)" } ?? "无")",
            "启动保护=\(controller.isHoldingPageColor)",
            "提示=\(String(describing: controller.shownLoadProblem))",
            "提示淡出那层=\(Self.identity(controller.loadProblemFadeView))",
            "页面颜色=\(Self.rgb(appearance.background))",
            "顶部外观=\(controller.chromeAppearance?.name.rawValue ?? "nil")",
            "窗口底色=\(Self.rgb(controller.window?.backgroundColor))",
            "用过的颜色=\(shown.map { Self.rgb($0) })",
        ]
    }

    /// 日志（不算跟着真实鼠标、键盘、屏幕写的行，见 LiveInputLogLines），行里的耗时换成“…”。
    private func lines() -> [String] {
        LiveInputLogLines.compared(diagnostics.entries).map {
            "[\($0.category)] " + $0.message.replacingOccurrences(of: #"（\d+ms）"#, with: "（…ms）", options: .regularExpression)
        }
    }

    /// 不显示的标签 2 的遮挡结束时那一行。
    private func backgroundEnd(_ outcome: String, kind: String = "新标签页") -> String {
        "[launch] 不显示的页面的遮挡结束（\(kind)）：\(outcome)（…ms） 【标签2】"
    }

    private static func identity(_ view: NSView?) -> String {
        view.map { "\(ObjectIdentifier($0))" } ?? "无"
    }

    private static func rgb(_ color: NSColor?) -> String {
        guard let color else { return "nil" }
        guard let c = color.usingColorSpace(.sRGB) else { return color.description }
        return String(format: "(%.3f, %.3f, %.3f, a %.2f)", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    /// 最后一行以 prefix 开头的日志里的毫秒数。
    private func milliseconds(_ prefix: String) throws -> Int {
        let line = try XCTUnwrap(diagnostics.entries.last { $0.message.hasPrefix(prefix) }?.message, "有一行“\(prefix)”")
        return try XCTUnwrap(Int(line.replacingOccurrences(of: #"^.*（(\d+)ms）.*$"#, with: "$1", options: .regularExpression)), line)
    }

    // MARK: - 开始：不显示的页面

    /// 给不显示的 A 开始新标签页的遮挡：A 盖着（新标签页的样子、代号 1、不在等提交）、进入它自己的启动保护；
    /// 窗口（没盖着、或盖着 B 的启动画面）的样子、颜色、日志一点不变，B 也不变。计时照常开始：到时限还没提交就等提交。
    func testBeginningANewTabCoverForAPageThatIsNotDisplayedLeavesTheWindowAlone() async throws {
        for displayedCovered in [false, true] {
            make()
            if displayedCovered { controller.beginLaunchScreen() }
            let window = look(), logged = lines(), displayed = all(b)
            let a = makeA()
            beginNewTab(a, limit: 0.1)
            XCTAssertEqual(cover(a), Cover(covered: true, kind: .newTab, generation: 1), "B 盖着=\(displayedCovered)")
            XCTAssertTrue(a.holdsPageColor, "A 进入它自己的启动保护")
            XCTAssertNil(a.colorBeforeFirstLoad)
            XCTAssertEqual(look(), window, "窗口不变（B 盖着=\(displayedCovered)）")
            XCTAssertEqual(controller.shownCoverKind, displayedCovered ? .launch : nil)
            XCTAssertEqual(lines(), logged, "不写日志（B 盖着=\(displayedCovered)）")
            XCTAssertEqual(all(b), displayed, "B 不变（B 盖着=\(displayedCovered)）")

            try await waitUntil { a.coverAwaitsCommit }
            XCTAssertEqual(cover(a), Cover(covered: true, awaits: true, kind: .newTab, generation: 1), "计时开始了：到时限还没提交，继续盖着")
            XCTAssertEqual(look(), window, "到时限：窗口不变")
            XCTAssertEqual(lines(), logged, "到时限：不写日志")
            XCTAssertEqual(all(b), displayed)
        }
    }

    /// 关闭的页面不开始新标签页的遮挡（显示着、不显示都一样）：遮挡、启动保护、窗口、日志都不变，之后也没有计时到点。
    /// 对照：没关闭时开始了。
    func testAClosedPageNeverBeginsANewTabCover() async throws {
        for displayed in [false, true] {
            for closes in [false, true] {
                make()
                let a = makeA()
                #if DEBUG
                if displayed { controller.setDisplayedPageForTesting(a) }
                #else
                guard !displayed else { continue }
                #endif
                let window = look(), logged = lines(), state = all(a)
                if closes { controller.pageClosed(a) }
                beginNewTab(a, limit: 0.05, cap: 0.1)
                if closes {
                    try await pause(0.3)
                    XCTAssertEqual(look(), window, "关闭的页面（显示着=\(displayed)）：窗口不变")
                    XCTAssertEqual(lines(), logged)
                    XCTAssertEqual(all(a), state.replacingOccurrences(of: "关闭=false", with: "关闭=true"), "关闭的页面：状态不变")
                } else {
                    XCTAssertEqual(cover(a), Cover(covered: true, kind: .newTab, generation: 1), "对照：开始了（显示着=\(displayed)）")
                    XCTAssertEqual(controller.isShowingLaunchScreen, displayed)
                }
            }
        }
    }

    // MARK: - 开始：显示着的页面；窗口照显示着的页面显示样子

    /// 显示着的页面开始新标签页的遮挡：马上盖上、是新标签页的样子；结束时淡出那层也是新标签页的样子。
    /// 启动画面照旧是启动画面的样子（单页的样子不变）。
    func testTheWindowShowsTheLookOfTheCoverItHasBegun() {
        for kind in [PageLoadState.CoverKind.launch, .newTab] {
            make()
            XCTAssertNil(controller.shownCoverKind)
            if kind == .launch { controller.beginLaunchScreen() } else { controller.beginNewTabCover(for: b) }
            XCTAssertTrue(controller.isShowingLaunchScreen)
            XCTAssertEqual(controller.shownCoverKind, kind)
            XCTAssertEqual(cover(b), Cover(covered: true, kind: kind, generation: 1))
            controller.endLaunchScreen("网页已加载")
            XCTAssertNil(controller.shownCoverKind)
            XCTAssertEqual(controller.launchFadeView?.rootView.kind, kind, "淡出的是结束的那种")
            XCTAssertEqual(b.coverKind, kind, "结束以后还记着是哪一种")
        }
    }

    /// 建窗口时窗口从它的页面的遮挡开始：盖不盖、哪一种样子都照页面（和提示一样）。新页面不盖、样子是启动画面（原来的初值）。
    func testTheWindowStartsFromItsPagesCover() {
        for kind in [PageLoadState.CoverKind.launch, .newTab] {
            for covered in [false, true] {
                let page = PageLoadState()
                page.isCovered = covered
                page.coverKind = kind
                let name = "NewTabCoverTests-\(UUID().uuidString)"
                addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
                let window = ChatWindowController(webView: WKWebView(), toolbar: EmptyView(), diagnostics: Diagnostics(),
                                                  appearance: PageAppearance(defaults: UserDefaults(suiteName: name)!), page: page)
                addTeardownBlock { window.window?.orderOut(nil) }
                XCTAssertEqual(window.shownCoverKind, covered ? kind : nil, "\(kind) 盖着=\(covered)")
            }
        }
        let fresh = PageLoadState()
        XCTAssertFalse(fresh.isCovered)
        XCTAssertEqual(fresh.coverKind, .launch)
    }

    #if DEBUG
    /// 换显示着的页面（display(_:webView:)，投上它的遮挡）：B 盖着启动画面、A 盖着新标签页的遮挡。
    /// 换到 A → 新标签页的样子；换回 B → 启动画面；B 结束后换到 A → 新标签页的样子，A 自己结束 → 撤掉、淡出新标签页的样子；
    /// 换到没有遮挡的页面 → 不盖。日志只有两行显示着时结束的：启动画面那行不带标签（和以前一样），新标签页的遮挡那行带 A 的标签（11-21）。
    func testTheWindowFollowsTheDisplayedPagesCoverKind() {
        make()
        controller.beginLaunchScreen()
        let a = makeA()
        beginNewTab(a)
        XCTAssertEqual(controller.shownCoverKind, .launch)
        let aWeb = makeWeb()
        controller.display(a, webView: aWeb)
        XCTAssertEqual(controller.shownCoverKind, .newTab, "启动画面 → 新标签页")
        controller.display(b, webView: web)
        XCTAssertEqual(controller.shownCoverKind, .launch, "新标签页 → 启动画面")
        controller.endLaunchScreen("网页已加载")
        XCTAssertNil(controller.shownCoverKind)
        XCTAssertEqual(controller.launchFadeView?.rootView.kind, .launch)
        controller.display(a, webView: aWeb)
        XCTAssertEqual(controller.shownCoverKind, .newTab, "没盖着 → 新标签页")
        controller.endLaunchScreen("加载失败", for: a)
        XCTAssertNil(controller.shownCoverKind)
        XCTAssertEqual(controller.launchFadeView?.rootView.kind, .newTab)
        let c = PageLoadState()
        controller.display(c, webView: makeWeb())
        XCTAssertNil(controller.shownCoverKind, "没有遮挡的页面：不盖")
        XCTAssertEqual(lines().filter { $0.hasPrefix("[launch]") },
                       ["[launch] 启动画面结束：网页已加载（…ms）", "[launch] 启动画面结束：加载失败（…ms） 【标签2】"])
    }
    #endif

    // MARK: - 显示着时：和启动画面同一套规则、同样的日志

    private enum Way: String, CaseIterable {
        case finish = "加载完成"
        case fail = "加载失败"
        case commitBeforeLimit = "到时限时已提交"
        case fallbackAfterLimit = "到时限后提交兜底"
        case cap = "上限"
    }

    /// 显示着的页面 B 盖着 kind 那种遮挡，照 way 走完。每一步记下窗口（不含遮挡的样子）和到这时的日志；
    /// 盖着和淡出时的样子要是 kind。
    private func displayedTimeline(_ way: Way, _ kind: PageLoadState.CoverKind) async throws -> [String] {
        make()
        var steps: [String] = []
        let step = { [unowned self] (name: String) in
            let state = look().filter { !$0.hasPrefix("样子=") && !$0.hasPrefix("淡出那层的样子=") && !$0.hasPrefix("启动画面淡出那层=") }
            steps.append("\(name)：\(state) 淡出=\(controller.launchFadeView != nil) \(lines())")
            if controller.isShowingLaunchScreen { XCTAssertEqual(controller.shownCoverKind, kind, "\(way.rawValue) \(name)") }
            if let fade = controller.launchFadeView { XCTAssertEqual(fade.rootView.kind, kind, "\(way.rawValue) \(name)：淡出") }
        }
        switch way {
        case .commitBeforeLimit:
            controller.launchScreenLimit = 0.1
            controller.pageRevealLimit = 0.4
        case .fallbackAfterLimit:
            controller.launchScreenLimit = 0.05
            controller.pageRevealLimit = 0.3
        case .cap:
            controller.launchScreenLimit = 0.05
            controller.launchScreenCap = 0.4
        case .finish, .fail:
            break
        }
        if kind == .launch { controller.beginLaunchScreen() } else { controller.beginNewTabCover(for: b) }
        step("开始")
        switch way {
        case .finish:
            controller.endLaunchScreen("网页已加载")
            controller.pageDidFinishLoading()
            step("加载完成")
        case .fail:
            controller.showLoadProblem(.waiting)
            controller.endLaunchScreen("加载失败")
            step("加载失败")
        case .commitBeforeLimit:
            controller.pageDidCommit()
            step("提交")
            try await waitUntil { !controller.isShowingLaunchScreen }
            step("时限")
        case .fallbackAfterLimit:
            try await waitUntil { b.coverAwaitsCommit }
            step("时限")
            controller.pageDidCommit()
            try await pause(0.1)
            step("提交")
            try await waitUntil { !controller.isShowingLaunchScreen }
            step("兜底")
        case .cap:
            try await waitUntil { b.coverAwaitsCommit }
            step("时限")
            try await waitUntil { !controller.isShowingLaunchScreen }
            step("上限")
        }
        return steps
    }

    /// 每种结束方式（加载完成、加载失败、到时限时已提交、到时限后提交兜底、上限）各走两遍：显示着的页面盖着启动画面、
    /// 盖着新标签页的遮挡。每一步窗口一样、日志一行不差（显示着的页面的日志就是原来那几行），只有样子不同；
    /// 只有新标签页的遮挡结束的那一行末尾多 B 的标签（11-21：那一行要写是哪个标签页），启动画面的行照旧不带。
    /// （新标签页的遮挡另外在页面开始显示时就撤，这里的页面不报颜色，走不到那条；见 NewTabEarlyRevealTests。）
    func testADisplayedNewTabCoverFollowsTheLaunchScreensRulesLineForLine() async throws {
        for way in Way.allCases {
            let launch = try await displayedTimeline(way, .launch)
            XCTAssertFalse(lines().contains { $0.contains("【标签") }, "\(way.rawValue)：启动画面的行不带标签")
            let newTab = try await displayedTimeline(way, .newTab)
            XCTAssertEqual(newTab.map { $0.replacingOccurrences(of: " 【标签1】", with: "") }, launch, way.rawValue)
            let tagged = lines().filter { $0.contains("【标签") }
            XCTAssertEqual(tagged.count, 1, "\(way.rawValue)：只有结束的那一行带标签")
            XCTAssertTrue(tagged.allSatisfy { $0.hasPrefix("[launch] 启动画面结束：") && $0.hasSuffix("（…ms） 【标签1】") },
                          "\(way.rawValue)：\(tagged)")
        }
    }

    // MARK: - 不显示的页面的遮挡结束：一行带标签的日志，窗口不变

    /// A 不显示、盖着新标签页的遮挡；B 显示着（没盖着、或盖着启动画面）。A 的遮挡按每一种方式结束：
    /// 只多一行带标签 2 的日志（原因和耗时，没有地址），窗口的样子、B 都不变，之后也不再多写。
    /// 到时限还没提交（兜底、上限两种）：继续盖着、不写日志。
    func testANonDisplayedCoverEndWritesOneTaggedLineAndNothingForTheWindow() async throws {
        let outcomes: [Way: String] = [.finish: "网页已加载", .fail: "加载失败", .commitBeforeLimit: "超过时限",
                                       .fallbackAfterLimit: "提交后 200ms 还没加载完成", .cap: "超过上限"]
        for displayedCovered in [false, true] {
            for way in Way.allCases {
                make()
                if displayedCovered { controller.beginLaunchScreen() }
                let a = makeA()
                if way == .commitBeforeLimit { controller.pageDidCommit(a) }
                switch way {
                case .finish, .fail: beginNewTab(a)
                case .commitBeforeLimit, .fallbackAfterLimit: beginNewTab(a, limit: 0.1)
                case .cap: beginNewTab(a, limit: 0.1, cap: 0.4)
                }
                let window = look(), logged = lines(), displayed = all(b)
                let name = "\(way.rawValue)（B 盖着=\(displayedCovered)）"
                switch way {
                case .finish:
                    controller.endLaunchScreen("网页已加载", for: a)
                    controller.pageDidFinishLoading(a, reportedColor: white)
                case .fail:
                    controller.showLoadProblem(.waiting, for: a)
                    controller.endLaunchScreen("加载失败", for: a)
                case .fallbackAfterLimit:
                    controller.pageRevealLimit = 0.2
                    try await waitUntil { a.coverAwaitsCommit }
                    XCTAssertTrue(a.isCovered, "\(name)：到时限还没提交，继续盖着")
                    XCTAssertEqual(lines(), logged, "\(name)：到时限不写日志")
                    controller.pageDidCommit(a)
                    try await pause(0.1)
                    XCTAssertTrue(a.isCovered, "\(name)：兜底之前还盖着")
                case .cap:
                    try await waitUntil { a.coverAwaitsCommit }
                    XCTAssertTrue(a.isCovered, "\(name)：到时限还没提交，继续盖着")
                    XCTAssertEqual(lines(), logged, "\(name)：到时限不写日志")
                case .commitBeforeLimit:
                    break
                }
                try await waitUntil { !a.isCovered }
                XCTAssertEqual(cover(a), Cover(kind: .newTab, generation: 1), "\(name)：A 的遮挡结束")
                XCTAssertEqual(lines(), logged + [backgroundEnd(outcomes[way]!)], "\(name)：只多一行带标签的")
                XCTAssertEqual(look(), window, "\(name)：窗口不变")
                XCTAssertEqual(all(b), displayed, "\(name)：B 不变")
                try await pause(0.3)
                XCTAssertEqual(lines(), logged + [backgroundEnd(outcomes[way]!)], "\(name)：之后不再写")
                XCTAssertEqual(look(), window, "\(name)：之后窗口也不变")
                if way == .cap {
                    XCTAssertGreaterThanOrEqual(try milliseconds("不显示的页面的遮挡结束"), 390, "耗时从 A 开始遮挡时算")
                }
            }
        }
    }

    /// 那一行写遮挡是哪一种：启动时的那种在不显示的页面上结束时也一样写一行，名字是“启动时”。
    /// 没有标签的页面（只在测试里单独建）不写：分不出是哪一页的行不写进窗口的类别里。
    func testTheLineNamesTheKindAndOnlyAPageWithATabWritesIt() async throws {
        #if DEBUG
        make()
        let a = makeA()
        controller.setDisplayedPageForTesting(a)
        controller.beginLaunchScreen()
        controller.display(b, webView: web)
        let logged = lines()
        controller.endLaunchScreen("网页已加载", for: a)
        XCTAssertEqual(lines(), logged + [backgroundEnd("网页已加载", kind: "启动时")])
        #endif

        make()
        let untagged = PageLoadState()
        beginNewTab(untagged, limit: 0.05, cap: 0.2)
        let window = look(), before = lines()
        try await waitUntil { !untagged.isCovered }
        XCTAssertEqual(cover(untagged), Cover(kind: .newTab, generation: 1), "照常结束")
        XCTAssertEqual(lines(), before, "没有标签：不写")
        XCTAssertEqual(look(), window)
    }

    // MARK: - 还盖着的页面被显示：沿用它自己的计时

    #if DEBUG
    /// A 不显示时开始（时限 0.05、上限 0.6），到时限还没提交、在等；0.25 秒后换上 A（投它的遮挡）：窗口盖着、新标签页的样子。
    /// 之后照 A 自己开始时排下的上限结束（不从显示那一刻重新算）：写显示着时的那一行（带 A 的标签，11-21），耗时从 A 开始时算；
    /// A 不显示时到的时限不补写；淡出新标签页的样子。
    func testAPageStillCoveredWhenDisplayedKeepsItsOwnClock() async throws {
        make()
        let a = makeA()
        let started = Date()
        beginNewTab(a, limit: 0.05, cap: 0.6)
        try await waitUntil { a.coverAwaitsCommit }
        try await pause(0.2)
        let logged = lines()
        let displayedAt = Date()
        controller.display(a, webView: makeWeb())
        XCTAssertTrue(controller.isShowingLaunchScreen)
        XCTAssertEqual(controller.shownCoverKind, .newTab)
        XCTAssertEqual(lines(), logged, "换上来时不写日志")
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertFalse(a.isCovered)
        XCTAssertEqual(controller.launchFadeView?.rootView.kind, .newTab)
        XCTAssertEqual(lines(), logged + ["[launch] 启动画面结束：超过上限（…ms） 【标签2】"], "显示着的页面的那一行，带标签")
        let ms = try milliseconds("启动画面结束：超过上限")
        XCTAssertGreaterThanOrEqual(ms, 590, "从 A 开始遮挡时算")
        XCTAssertLessThanOrEqual(ms, Int(Date().timeIntervalSince(started) * 1000))
        XCTAssertLessThan(Date().timeIntervalSince(displayedAt), 0.6, "没有从显示那一刻重新算上限")
    }

    /// A 不显示时开始（新标签页的遮挡），换上 A：A 的启动保护照常挡住它报的颜色，顶部一条和窗口底色、遮挡的底色
    /// 都还是窗口原来的颜色（记下的页面颜色），直到 A 第一次加载完成。
    /// （换上 A 时连同 A 的网页视图一起换，报颜色的是 A 的网页视图。）
    func testADisplayedNewTabCoverKeepsTheWindowsColourUntilItsFirstLoadFinishes() async throws {
        make()
        let a = makeA()
        beginNewTab(a)
        let aWeb = makeWeb()
        controller.display(a, webView: aWeb)
        aWeb.underPageBackgroundColor = white
        try await pause(0.3)
        XCTAssertEqual(Self.rgb(appearance.background), Self.rgb(savedDark), "不采用")
        XCTAssertTrue(shown.isEmpty)
        XCTAssertEqual(Self.rgb(controller.window?.backgroundColor), Self.rgb(savedDark))
        XCTAssertEqual(lines(), ["[appearance] 启动保护中：页面底色报为浅色，不采用"])
        XCTAssertTrue(controller.isShowingLaunchScreen)
    }
    #endif

    // MARK: - 遮挡的样子

    /// 新标签页的样子里没有图标和应用名：同一个视图按它想要的大小排，新标签页的只有进度圈那么大，
    /// 启动画面的至少有图标（96）那么高、应用名那么宽。屏幕上真正的样子（浅色、深色）要上屏看。
    func testTheNewTabLookHasNoIconOrAppName() {
        let appearance = PageAppearance(defaults: UserDefaults(suiteName: "NewTabCoverTests-look-\(UUID().uuidString)")!)
        let launch = NSHostingView(rootView: LaunchScreen(appearance: appearance)).fittingSize
        let newTab = NSHostingView(rootView: LaunchScreen(appearance: appearance, kind: .newTab)).fittingSize
        XCTAssertGreaterThanOrEqual(launch.height, 96 + 16, "启动画面：图标和下面的东西 \(launch)")
        XCTAssertLessThan(newTab.height, 40, "新标签页：只有进度圈 \(newTab)")
        XCTAssertLessThan(newTab.width, 40, "新标签页：没有应用名 \(newTab)")
        XCTAssertEqual(LaunchScreen(appearance: appearance).kind, .launch, "不指定时是启动画面（单页的样子）")
    }

    // MARK: - “启动画面还在”

    /// 窗口的判断：页面的启动时的那种遮挡还盖着、没有关闭。新标签页的遮挡、结束了的、关闭的都不算。
    func testOnlyALiveLaunchKindCoverCountsAsTheLaunchScreen() {
        make()
        XCTAssertFalse(controller.coversWithLaunchScreen(b), "没开始")
        controller.beginLaunchScreen()
        XCTAssertTrue(controller.coversWithLaunchScreen(b), "启动画面盖着")
        let a = makeA()
        beginNewTab(a)
        XCTAssertFalse(controller.coversWithLaunchScreen(a), "新标签页的遮挡不算")
        controller.endLaunchScreen("网页已加载")
        XCTAssertFalse(controller.coversWithLaunchScreen(b), "结束了")
        controller.beginLaunchScreen()
        controller.pageClosed(b)
        XCTAssertTrue(b.isCovered, "关闭时停在盖着")
        XCTAssertFalse(controller.coversWithLaunchScreen(b), "关闭的不算")
    }

    /// 这组标签页的判断（3.6 新增标签页的入口看它）：启动时的标签页的启动画面盖着时为真，包括到时限后还在等提交；
    /// 启动画面结束（这里是上限）以后为假；之后别的标签页盖着新标签页的遮挡也不算。
    /// 标签页按正式运行时的建法建（ChatTab.make），加载请求不发出去。
    func testTheTabsSayTheLaunchScreenIsUpOnlyWhileTheLaunchCoverIsOn() async throws {
        let rig = makeTabsRig()
        XCTAssertFalse(rig.tabs.isLaunchScreenUp, "还没开始")
        rig.controller.launchScreenLimit = 0.05
        rig.controller.launchScreenCap = 0.4
        rig.controller.beginLaunchScreen()
        XCTAssertTrue(rig.tabs.isLaunchScreenUp)
        try await waitUntil { rig.first.page.coverAwaitsCommit }
        XCTAssertTrue(rig.tabs.isLaunchScreenUp, "到时限后还在等提交")
        try await waitUntil { !rig.controller.isShowingLaunchScreen }
        XCTAssertFalse(rig.tabs.isLaunchScreenUp, "上限结束以后")
        let added = rig.add()
        rig.controller.beginNewTabCover(for: added.page)
        XCTAssertTrue(added.page.isCovered)
        XCTAssertFalse(rig.tabs.isLaunchScreenUp, "新标签页的遮挡不算")
    }

    // MARK: - 正式运行时的建法和接线

    /// 每个标签页的页面带它的标签：正式运行时的建法（ChatTab.make）是它的标识；测试里单独建的运行时不带标签，页面也不带。
    func testEveryTabsPageCarriesItsTabsTag() {
        let rig = makeTabsRig()
        XCTAssertEqual(rig.first.page.logTag, rig.first.id)
        let added = rig.add()
        XCTAssertEqual(added.page.logTag, added.id)
        XCTAssertEqual(added.id.rawValue, 2)
        let runtime = WebRuntime(diagnostics: rig.diagnostics, settings: rig.settings, watchesNetwork: false)
        let adapter = ChatGPTAdapter(webView: runtime.webView, diagnostics: rig.diagnostics, settings: rig.settings)
        let untagged = ChatTab(id: TabList().selected, runtime: runtime, adapter: adapter)
        XCTAssertNil(untagged.page.logTag)
        XCTAssertNil(untagged.logTag)
    }

    /// 新标签页（不选中、不显示）开始遮挡，再经它的运行时加载：提交、加载完成（接线带着它的页面交给窗口）结束它的遮挡，
    /// 写一行带“【标签2】”的；加载失败也一样。窗口的遮挡那层、启动画面的行都不变。
    func testANewTabsOwnLoadEndsItsCoverThroughTheWiring() {
        for fails in [false, true] {
            let rig = makeTabsRig()
            let added = rig.add()
            rig.controller.beginNewTabCover(for: added.page)
            XCTAssertFalse(rig.controller.isShowingLaunchScreen, "不显示：窗口不盖")
            if fails {
                let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                                    userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://chatgpt.com/")!])
                added.runtime.webView(added.runtime.webView, didFailProvisionalNavigation: nil, withError: error)
            } else {
                added.runtime.webView(added.runtime.webView, didCommit: nil)
                added.runtime.webView(added.runtime.webView, didFinish: nil)
            }
            XCTAssertFalse(added.page.isCovered, "失败=\(fails)")
            XCTAssertFalse(rig.controller.isShowingLaunchScreen)
            XCTAssertNil(rig.controller.launchFadeView)
            let launch = rig.lines().filter { $0.hasPrefix("[launch]") }
                .map { $0.replacingOccurrences(of: #"（\d+ms）"#, with: "（…ms）", options: .regularExpression) }
            XCTAssertEqual(launch, [backgroundEnd(fails ? "加载失败" : "网页已加载")], "失败=\(fails)")
            XCTAssertFalse(rig.lines().contains { $0.hasPrefix("[appearance]") }, "不显示的页面不写窗口的颜色行")
        }
    }

    private func makeTabsRig() -> TabsRig {
        let name = "NewTabCoverTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabsRig(defaults: UserDefaults(suiteName: name)!)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        return rig
    }
}

/// 启动时的标签页（标签 1）和之后加的，都按正式运行时的建法建（ChatTab.make，日志带标签），共用一份诊断和一个窗口。
/// 加载请求不发出去；AppDelegate 交给 ChatTabs 的几样换成不做事的替身。
@MainActor
private final class TabsRig {
    let settings: AppSettings
    let diagnostics = Diagnostics()
    let first: ChatTab
    let controller: ChatWindowController
    private(set) var tabs: ChatTabs!
    let network = NetworkStatus(startsMonitor: false)

    init(defaults: UserDefaults) {
        settings = AppSettings(defaults: defaults)
        let list = TabList()
        first = ChatTab.make(id: list.selected, diagnostics: diagnostics, settings: settings)
        first.runtime.loadRequest = { _ in }
        controller = ChatWindowController(webView: first.runtime.webView, toolbar: EmptyView(), diagnostics: diagnostics,
                                          appearance: PageAppearance(defaults: defaults), page: first.page)
        controller.pageColorSettleLimit = 60
        tabs = ChatTabs(list: list, tab: first, windowController: controller, diagnostics: diagnostics, network: network,
                        hideWindow: { _ in },
                        focusInput: { _ in "NewTabCoverTests" },
                        saveLastConversation: { _ in },
                        mediaState: { _ in "none" },
                        openNewChat: { _ in true })
        tabs.wire(first)
    }

    /// 加一个标签页（正式运行时的建法），不选中。
    func add() -> ChatTab {
        let tab = tabs.add { ChatTab.make(id: $0, diagnostics: diagnostics, settings: settings) }!
        tab.runtime.loadRequest = { _ in }
        return tab
    }

    /// 写过的日志（“[类别] 内容”），去掉跟着真实鼠标、键盘、屏幕写的（LiveInputLogLines）。
    func lines() -> [String] {
        diagnostics.entries.filter { !LiveInputLogLines.excludes($0) }.map { "[\($0.category)] \($0.message)" }
    }
}
