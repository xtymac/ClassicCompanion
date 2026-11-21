import AppKit
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 新标签页的遮挡在页面开始显示时就撤（用户 11-21 定，ChatWindowController.pageDidReportColor(_:_:)）：
/// 主框架提交以后，网页视图报出和遮挡同一深浅的不透明页面底色就结束，不等加载完成；原来的结束方式（加载完成、失败、
/// 时限、提交后兜底、上限）留作兜底。标签页按正式运行时的建法建（ChatTab.make，日志带标签），经 ChatTabs 的入口
/// （newTab()、openLink(_:from:_:)、select(_:)、close(_:)）和接线（ChatTabs.wire(_:)）走，提交、加载完成、失败直接调导航代理。
/// 网页视图报颜色用直接设 underPageBackgroundColor 模拟：颜色真的变了时，网页运行时和窗口的观察照样触发
/// （见 NewTabEntryTests.swift 里 NewTabRig.pinColour(_:)）。每个网页视图建好就固定在一个灰色（不是下面报的任何一个颜色），
/// 和这个测试进程的外观无关；记下的页面颜色（遮挡的底色）每个测试自己定。核对：
/// - 显示着的新标签页：提交后报出同一深浅的颜色就撤（加载完成之前），写带标签的那一行、淡出；之后的加载完成不再写、不再撤；
///   启动保护照旧到加载完成，报的颜色这时不采用。
/// - 提交之前报的、深浅和遮挡不同的、透明的颜色都不撤。没有记下的页面颜色时，遮挡的系统颜色（按它的外观）决定深浅。
/// - 兜底（加载完成、失败、到时限、提交后兜底、上限）各结束一次，那一行带标签；兜底或提前结束以后，再来的事件都不做事。
/// - ⌘ 点击在后台打开的：不显示时照同一条规则结束，写不显示的那一行，窗口不变；换上它时不盖、不淡出。
/// - 启动画面（启动时的那种）不照这条规则，那一行照旧不带标签。
/// - 遮挡还盖着时切走（它在后台照规则结束）、切回（显示着结束）；关闭以后它的颜色什么都不做。
/// 不显示窗口：找回窗口、窗口显示着换成替身；切模式的快照和排版换成不做事的记录。
@MainActor
final class NewTabEarlyRevealTests: XCTestCase {
    static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    /// ChatGPT 深色页面的底色。
    static let pageDark = NSColor(srgbRed: 0x21 / 255.0, green: 0x21 / 255.0, blue: 0x21 / 255.0, alpha: 1)
    /// 还没有页面时 WebKit 在深色外观下报的颜色（见 LaunchColourTests）。
    static let blankDark = NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)
    private let chat = URL(string: "https://chatgpt.com/c/abc")!

    /// saved：记下的页面颜色（遮挡的底色）；nil 是没有记下（遮挡用系统颜色）。
    private func make(saved: NSColor?) -> EarlyRig {
        let name = "NewTabEarlyRevealTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = EarlyRig(defaults: UserDefaults(suiteName: name)!, saved: saved)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        return rig
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await pause(0.02) }
    }

    /// 显示着的新标签页提前撤时那一行（标签 n）。
    private func shownEarly(_ shade: String, tab n: Int = 2) -> String {
        "[launch] 启动画面结束：网页开始显示，提交后页面底色报为\(shade)（…ms） 【标签\(n)】"
    }

    /// 浅色、深色两种：记下的页面颜色和页面报的同一深浅的颜色，日志里的说法。
    private let shades: [(saved: NSColor, page: NSColor, other: NSColor, name: String)] = [
        (white, white, blankDark, "浅色"),
        (pageDark, pageDark, white, "深色"),
    ]

    // MARK: - 显示着的新标签页

    /// ⌘T 新增的（显示着）：提交本身不撤；提交后报出和遮挡同一深浅的颜色就撤（还没加载完成），写一行带标签的、淡出新标签页的样子。
    /// 启动保护还在：报的颜色不采用，顶部一条的颜色不变。之后加载完成不再写那一行、不再淡出，启动保护照旧在这时解除；再报颜色也不做事。
    func testADisplayedNewTabsCoverGoesWhenItsPageReportsItsColourAfterTheCommit() async throws {
        for shade in shades {
            let rig = make(saved: shade.saved)
            let b = try XCTUnwrap(rig.tabs.newTab())
            XCTAssertEqual(rig.controller.shownCoverKind, .newTab, shade.name)
            rig.commit(b)
            XCTAssertTrue(b.page.isCovered, "提交本身不撤（\(shade.name)）")
            XCTAssertEqual(rig.launchLines(), [], shade.name)

            rig.report(b, shade.page)
            XCTAssertFalse(b.page.isCovered, shade.name)
            XCTAssertNil(rig.controller.shownCoverKind, shade.name)
            let fade = try XCTUnwrap(rig.controller.launchFadeView, shade.name)
            XCTAssertEqual(fade.rootView.kind, .newTab, shade.name)
            XCTAssertTrue(b.page.awaitingFinish, "还没加载完成（\(shade.name)）")
            XCTAssertTrue(rig.controller.isHoldingPageColor, "启动保护照旧到加载完成（\(shade.name)）")
            XCTAssertEqual(rig.launchLines(), [shownEarly(shade.name)], shade.name)
            try await pause(0.3)
            XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, shade.saved), "报的颜色不采用（\(shade.name)）")

            rig.finish(b)
            XCTAssertEqual(rig.launchLines(), [shownEarly(shade.name)], "加载完成不再写（\(shade.name)）")
            XCTAssertTrue(rig.controller.launchFadeView === fade, "不再淡出（\(shade.name)）")
            XCTAssertFalse(rig.controller.isHoldingPageColor, "启动保护在加载完成时解除（\(shade.name)）")
            XCTAssertEqual(b.page.coverGeneration, 1)
            rig.report(b, shade.other)
            rig.report(b, shade.page)
            XCTAssertEqual(rig.launchLines(), [shownEarly(shade.name)], "之后再报颜色也不做事（\(shade.name)）")
        }
    }

    /// 提交之前报的颜色（哪怕和遮挡同一深浅）不撤；提交以后没有再报（颜色没变）就照兜底：加载完成时撤，那一行带标签。
    func testAColourReportedBeforeTheCommitLeavesTheCoverOn() async throws {
        for shade in shades {
            let rig = make(saved: shade.saved)
            let b = try XCTUnwrap(rig.tabs.newTab())
            rig.report(b, shade.page)
            XCTAssertTrue(b.page.isCovered, "提交之前报的（\(shade.name)）")
            rig.commit(b)
            try await pause(0.2)
            XCTAssertTrue(b.page.isCovered, "提交以后颜色没变、没有再报（\(shade.name)）")
            XCTAssertEqual(rig.controller.shownCoverKind, .newTab)
            XCTAssertEqual(rig.launchLines(), [])
            rig.finish(b)
            XCTAssertFalse(b.page.isCovered)
            XCTAssertEqual(rig.launchLines(), ["[launch] 启动画面结束：网页已加载（…ms） 【标签2】"], shade.name)
        }
    }

    /// 提交以后报的颜色和遮挡深浅不同（深色里的空白白色、浅色里的空白深色），或者透明：不撤。之后报出同一深浅的才撤，只写一行。
    func testAColourOfTheOtherShadeOrATransparentOneLeavesTheCoverOn() throws {
        for shade in shades {
            let rig = make(saved: shade.saved)
            let b = try XCTUnwrap(rig.tabs.newTab())
            rig.commit(b)
            rig.report(b, shade.other)
            XCTAssertTrue(b.page.isCovered, "深浅不同（\(shade.name)）")
            rig.report(b, shade.page.withAlphaComponent(0.3))
            XCTAssertTrue(b.page.isCovered, "同一深浅但透明（\(shade.name)）")
            XCTAssertEqual(rig.launchLines(), [])
            rig.report(b, shade.page)
            XCTAssertFalse(b.page.isCovered, shade.name)
            XCTAssertEqual(rig.launchLines(), [shownEarly(shade.name)], shade.name)
        }
    }

    /// 没有记下的页面颜色：遮挡是系统颜色，按遮挡那层这一刻的外观（这里把窗口的外观定下来）定深浅。
    /// 深色外观：白色不撤、深色撤；浅色外观：深色不撤、白色撤。
    func testWithoutASavedColourTheCoversSystemColourDecidesTheShade() throws {
        for (look, other, page, name) in [(NSAppearance.Name.darkAqua, Self.white, Self.pageDark, "深色"),
                                          (.aqua, Self.blankDark, Self.white, "浅色")] {
            let rig = make(saved: nil)
            XCTAssertNil(rig.appearance.background)
            rig.controller.window?.appearance = NSAppearance(named: look)
            let b = try XCTUnwrap(rig.tabs.newTab())
            rig.commit(b)
            rig.report(b, other)
            XCTAssertTrue(b.page.isCovered, "系统颜色是\(name)：另一种深浅不撤")
            rig.report(b, page)
            XCTAssertFalse(b.page.isCovered, "系统颜色是\(name)：同一深浅撤")
            XCTAssertEqual(rig.launchLines(), [shownEarly(name)])
        }
    }

    // MARK: - 兜底

    private enum Fallback: String, CaseIterable {
        case finish = "网页已加载"
        case fail = "加载失败"
        case limit = "超过时限"
        case reveal = "提交后 200ms 还没加载完成"
        case cap = "超过上限"
    }

    /// 一直没有报颜色：照原来的规则结束，每种一次，那一行带标签（原因就是哪一条兜底）。结束以后提交、报同一深浅的颜色、
    /// 加载完成、失败、计时到点都不再写、不再撤。
    func testTheFallbacksStillEndTheCoverOnceWithATaggedLine() async throws {
        for way in Fallback.allCases {
            let rig = make(saved: Self.white)
            switch way {
            case .finish, .fail: break
            case .limit: rig.controller.launchScreenLimit = 0.1
            case .reveal:
                rig.controller.launchScreenLimit = 0.05
                rig.controller.pageRevealLimit = 0.2
            case .cap:
                rig.controller.launchScreenLimit = 0.05
                rig.controller.launchScreenCap = 0.3
            }
            let b = try XCTUnwrap(rig.tabs.newTab())
            switch way {
            case .finish:
                rig.commit(b)
                rig.finish(b)
            case .fail:
                rig.fail(b)
            case .limit:
                rig.commit(b)
            case .reveal:
                try await waitUntil { b.page.coverAwaitsCommit }
                XCTAssertTrue(b.page.isCovered, "到时限还没提交，继续盖着")
                rig.commit(b)
            case .cap:
                break
            }
            try await waitUntil { !b.page.isCovered }
            // 到时限还没提交的，先照旧写“继续显示”那一行（显示着的页面的这一行原来就不带标签，这次不改）。
            let waiting = "[launch] 启动画面到时限：网页还没提交，继续显示"
            let before: [String] = switch way {
            case .reveal: ["\(waiting)（等加载完成、失败、提交后 200ms，最多到 30 秒）"]
            case .cap: ["\(waiting)（等加载完成、失败、提交后 1000ms，最多到 0 秒）"]
            default: []
            }
            let ended = before + ["[launch] 启动画面结束：\(way.rawValue)（…ms） 【标签2】"]
            XCTAssertEqual(rig.launchLines(), ended, way.rawValue)
            XCTAssertNil(rig.controller.shownCoverKind, way.rawValue)

            if !b.page.hasCommittedPage { rig.commit(b) }
            rig.report(b, Self.white)
            rig.finish(b)
            rig.fail(b)
            try await pause(0.4)
            XCTAssertEqual(rig.launchLines(), ended, "\(way.rawValue)：之后不再写")
            XCTAssertFalse(b.page.isCovered)
            XCTAssertEqual(b.page.coverGeneration, 1)
        }
    }

    /// 提前撤以后，兜底的那几样（加载失败、加载完成、到时限、提交后兜底、上限）都不再做事：只有提前撤的那一行。
    func testAfterAnEarlyEndNoFallbackEndsItAgain() async throws {
        let rig = make(saved: Self.white)
        rig.controller.launchScreenLimit = 0.1
        rig.controller.launchScreenCap = 0.3
        rig.controller.pageRevealLimit = 0.15
        let b = try XCTUnwrap(rig.tabs.newTab())
        rig.commit(b)
        rig.report(b, Self.white)
        XCTAssertFalse(b.page.isCovered)
        let fade = rig.controller.launchFadeView
        rig.fail(b)
        rig.finish(b)
        try await pause(0.5)
        XCTAssertEqual(rig.launchLines(), [shownEarly("浅色")])
        XCTAssertFalse(b.page.isCovered)
        XCTAssertFalse(b.page.coverAwaitsCommit)
        XCTAssertNil(rig.controller.shownCoverKind)
        XCTAssertTrue(rig.controller.launchFadeView === fade, "没有第二次淡出")
    }

    // MARK: - ⌘ 点击在后台打开的

    /// 在后台打开的（不显示）：同一条规则——提交之前报的、深浅不同的不撤，提交后同一深浅的撤；写不显示的那一行（带标签），
    /// 窗口一点不变。之后加载完成不再写。换上它：不盖、没有淡出那层。
    func testABackgroundTabsCoverEndsByTheSameRuleWhileHidden() throws {
        for shade in shades {
            let rig = make(saved: shade.saved)
            let b = try XCTUnwrap(rig.tabs.openLink(chat, from: rig.first, .background))
            XCTAssertTrue(b.page.isCovered)
            XCTAssertTrue(rig.controller.page === rig.first.page)
            let window = rig.windowState()
            rig.report(b, shade.page)
            XCTAssertTrue(b.page.isCovered, "提交之前（\(shade.name)）")
            rig.commit(b)
            rig.report(b, shade.other)
            XCTAssertTrue(b.page.isCovered, "深浅不同（\(shade.name)）")
            rig.report(b, shade.page)
            XCTAssertFalse(b.page.isCovered, shade.name)
            let hidden = "[launch] 不显示的页面的遮挡结束（新标签页）：网页开始显示，提交后页面底色报为\(shade.name)（…ms） 【标签2】"
            XCTAssertEqual(rig.launchLines(), [hidden], shade.name)
            XCTAssertEqual(rig.windowState(), window, "窗口不变（\(shade.name)）")
            rig.finish(b)
            XCTAssertEqual(rig.launchLines(), [hidden], "加载完成不再写（\(shade.name)）")

            rig.tabs.select(b)
            XCTAssertNil(rig.controller.shownCoverKind, shade.name)
            XCTAssertNil(rig.controller.launchFadeView, "不显示时结束的，换上来不淡出（\(shade.name)）")
        }
    }

    // MARK: - 启动画面

    /// 启动时的那种遮挡（启动画面）不照这条规则：提交后报出同一深浅的颜色仍盖着，到加载完成才撤，那一行照旧不带标签。
    func testTheLaunchScreenKeepsItsOwnRule() throws {
        for shade in shades {
            let rig = make(saved: shade.saved)
            rig.controller.beginLaunchScreen()
            rig.commit(rig.first)
            rig.report(rig.first, shade.page)
            XCTAssertTrue(rig.first.page.isCovered, shade.name)
            XCTAssertEqual(rig.controller.shownCoverKind, .launch, shade.name)
            XCTAssertEqual(rig.launchLines(), [])
            rig.finish(rig.first)
            XCTAssertFalse(rig.first.page.isCovered)
            XCTAssertEqual(rig.launchLines(), ["[launch] 启动画面结束：网页已加载（…ms）"], shade.name)
        }
    }

    // MARK: - 盖着时切走、切回、关闭

    /// 新增的 B 提交以后切回 A（B 藏着、还盖着）：B 报出同一深浅的颜色，在后台照规则结束（不显示的那一行），窗口不变；
    /// 再换上 B：不盖、不淡出。
    func testACoveredTabSwitchedAwayEndsByTheRuleInTheBackground() throws {
        let rig = make(saved: Self.white)
        let b = try XCTUnwrap(rig.tabs.newTab())
        rig.commit(b)
        rig.tabs.select(rig.first)
        XCTAssertNil(rig.controller.shownCoverKind)
        XCTAssertTrue(b.page.isCovered)
        let window = rig.windowState()
        rig.report(b, Self.white)
        XCTAssertFalse(b.page.isCovered)
        XCTAssertEqual(rig.launchLines(),
                       ["[launch] 不显示的页面的遮挡结束（新标签页）：网页开始显示，提交后页面底色报为浅色（…ms） 【标签2】"])
        XCTAssertEqual(rig.windowState(), window)
        rig.tabs.select(b)
        XCTAssertNil(rig.controller.shownCoverKind)
        XCTAssertNil(rig.controller.launchFadeView)
    }

    /// 新增的 B 还没提交就切走又切回：窗口照它的状态盖着；之后提交、报颜色，显示着结束（显示着的那一行，带标签）。
    func testACoveredTabSwitchedBackEndsByTheRuleWhileShown() throws {
        let rig = make(saved: Self.pageDark)
        let b = try XCTUnwrap(rig.tabs.newTab())
        rig.tabs.select(rig.first)
        rig.tabs.select(b)
        XCTAssertEqual(rig.controller.shownCoverKind, .newTab)
        rig.commit(b)
        rig.report(b, Self.pageDark)
        XCTAssertNil(rig.controller.shownCoverKind)
        XCTAssertNotNil(rig.controller.launchFadeView)
        XCTAssertEqual(rig.launchLines(), [shownEarly("深色")])
    }

    /// 新增的 B 提交以后切回 A、关闭 B（还盖着）：之后 B 的网页视图报颜色（观察已停、回调已断开），或者直接把它的颜色交给窗口，
    /// 都什么都不做：不写、窗口不变，B 的遮挡停在关闭时。
    func testAClosedTabsColourDoesNothing() throws {
        let rig = make(saved: Self.white)
        let b = try XCTUnwrap(rig.tabs.newTab())
        rig.commit(b)
        rig.tabs.select(rig.first)
        rig.tabs.close(b)
        XCTAssertTrue(b.page.isClosed)
        XCTAssertNil(b.runtime.onPageColorChange, "回调已断开")
        let window = rig.windowState(), lines = rig.allLines()
        rig.report(b, Self.blankDark)
        rig.report(b, Self.white)
        rig.controller.pageDidReportColor(b.page, Self.white)
        XCTAssertEqual(rig.allLines(), lines)
        XCTAssertEqual(rig.windowState(), window)
        XCTAssertTrue(b.page.isCovered, "停在关闭时")
    }
}

/// 启动时的标签页（标签 1）、窗口和 ChatTabs，像 AppDelegate 那样建；新增的建法是正式运行时的 ChatTab.make，
/// 网页视图建好就固定在灰色，加载请求只记下来。找回窗口、窗口显示着、提示换成替身；切模式的快照和排版换成不做事的记录。
@MainActor
private final class EarlyRig {
    /// 网页视图建好时固定的颜色：不是测试报的任何一个（它变成测试报的颜色时观察才触发）。
    static let start = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    let settings: AppSettings
    let diagnostics = Diagnostics()
    let appearance: PageAppearance
    let first: ChatTab
    let controller: ChatWindowController
    let network = NetworkStatus(startsMonitor: false)
    private(set) var tabs: ChatTabs!

    init(defaults: UserDefaults, saved: NSColor?) {
        if let rgb = saved?.usingColorSpace(.sRGB) {
            defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init), forKey: "pageBackgroundRGB")
        }
        settings = AppSettings(defaults: defaults)
        appearance = PageAppearance(defaults: defaults)
        let list = TabList()
        first = Self.pin(ChatTab.make(id: list.selected, diagnostics: diagnostics, settings: settings))
        // 顶部一条和正式的一样高度固定（见 NewTabEntryTests 的 NewTabRig）。
        controller = ChatWindowController(webView: first.runtime.webView,
                                          toolbar: Color.clear.frame(height: WebBar.height).frame(maxWidth: .infinity),
                                          diagnostics: diagnostics, appearance: appearance, page: first.page)
        controller.pageColorSettleLimit = 60
        controller.layoutWaitLimit = 60
        tabs = ChatTabs(list: list, tab: first, windowController: controller, diagnostics: diagnostics, network: network,
                        hideWindow: { _ in },
                        focusInput: { _ in "NewTabEarlyRevealTests" },
                        saveLastConversation: { _ in },
                        mediaState: { _ in "none" },
                        openNewChat: { _ in true },
                        makeTab: { [weak self] id in self!.build(id) },
                        revealWindow: {})
        tabs.wire(first)
        first.runtime.loadRequest = { _ in }
        tabs.windowIsVisible = { true }
        tabs.showHint = { _, _ in }
        tabs.tipRecord = MemoryTabTipRecord(shown: true)
        controller.onSnapshotPage = { _ in }
        controller.onPrepareLayout = { _, _ in }
        controller.window!.contentView!.layoutSubtreeIfNeeded()
    }

    private static func pin(_ tab: ChatTab) -> ChatTab {
        tab.runtime.webView.underPageBackgroundColor = start
        return tab
    }

    private func build(_ id: TabID) -> ChatTab {
        let tab = Self.pin(ChatTab.make(id: id, diagnostics: diagnostics, settings: settings))
        tab.runtime.loadRequest = { _ in }
        return tab
    }

    /// 主框架提交、加载完成、加载失败（-1009）：直接调 tab 的运行时的导航代理。
    func commit(_ tab: ChatTab) {
        tab.runtime.webView(tab.runtime.webView, didCommit: nil)
    }

    func finish(_ tab: ChatTab) {
        tab.runtime.webView(tab.runtime.webView, didFinish: nil)
    }

    func fail(_ tab: ChatTab) {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://chatgpt.com/")!])
        tab.runtime.webView(tab.runtime.webView, didFailProvisionalNavigation: nil, withError: error)
    }

    /// tab 的网页视图报出 color（颜色真的变了时观察才触发）。
    func report(_ tab: ChatTab, _ color: NSColor) {
        tab.runtime.webView.underPageBackgroundColor = color
    }

    /// 写过的日志（“[类别] 内容”），不算跟着真实鼠标、键盘、屏幕写的行，也不算运行时加载完成后自己异步写的 [esc]、[render]。
    func allLines() -> [String] {
        LiveInputLogLines.compared(diagnostics.entries)
            .filter { $0.category != "esc" && $0.category != "render" }
            .map { "[\($0.category)] \($0.message)" }
    }

    /// [launch] 那几行，耗时换成“…”。
    func launchLines() -> [String] {
        allLines().filter { $0.hasPrefix("[launch]") }
            .map { $0.replacingOccurrences(of: #"（\d+ms）"#, with: "（…ms）", options: .regularExpression) }
    }

    /// 窗口上看得见的：显示的页面和网页视图、遮挡那层和样子、淡出那层、启动保护、提示、补排版、页面颜色和窗口底色。
    func windowState() -> String {
        "显示=\(tabs.tabs.firstIndex { $0.page === controller.page } ?? -1) "
            + "网页=\(tabs.tabs.firstIndex { $0.runtime.webView === controller.webView } ?? -1) "
            + "遮挡=\(controller.isShowingLaunchScreen) 样子=\(controller.shownCoverKind.map { "\($0)" } ?? "无") "
            + "淡出=\(controller.launchFadeView.map { "\(ObjectIdentifier($0))" } ?? "无") 启动保护=\(controller.isHoldingPageColor) "
            + "提示=\(controller.shownLoadProblem.map { "\($0)" } ?? "无") 补排版=\(controller.isCatchingUp) "
            + "页面颜色=\(appearance.background.map { "\($0)" } ?? "nil") 窗口底色=\(controller.window?.backgroundColor.description ?? "nil")"
    }
}
