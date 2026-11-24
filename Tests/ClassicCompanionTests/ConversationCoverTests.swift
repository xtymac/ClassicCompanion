import AppKit
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 带对话地址打开的标签页（⇧⌘T 重新打开、⌘ 点击和 ⇧⌘ 点击对话链接）的遮挡等对话内容（用户 11-24 报告：⇧⌘T 时先出来一下
/// 新聊天页，然后才是对话）。规则在 ChatWindowController 的“等对话内容”那一段，看网页内容的在 ChatTabs.watchConversation(_:)。
/// 核对：
/// - 外壳出来（提交后报出同一深浅的底色、加载完成：原来这时撤）不撤，写一行“等对话内容”；对话内容出来才撤（提交以后才看）。
/// - 一直认不出内容：外壳出来以后 contentWaitLimit 撤（从显示着的那一刻算）。
/// - 加载失败、网页离开那段对话（地址换成别的、首页、登录页）马上撤；同一段对话（带查询参数、多了 /g/<gpt>）不撤。
/// - ⌘T 新增的、链接不是对话的、网页增强关着的：照原来的规则（外壳出来就撤）。
/// - ⌘ 点击在后台打开的：在下面渲染时内容出来就在后台撤，换上来不盖；藏起以后还没内容的，时限不在后台走，
///   换上它时盖着，等内容或从那一刻起的时限。不显示时到了别的兜底（时限、上限）也一样留到显示时。
/// - 显示着开始等、切走了：到点不撤，再换上来时重新等。
/// 网页里有没有内容由测试定（ChatTabs.conversationShown 换成读 rig.contentShown）；网页视图不加载任何东西（不联网）。
/// 不显示窗口：找回窗口、窗口显示着、提示换成替身；切模式的快照和排版换成不做事的记录。
@MainActor
final class ConversationCoverTests: XCTestCase {
    static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private let chat = URL(string: "https://chatgpt.com/c/abc")!

    /// limit：等对话内容的时限（contentWaitLimit），默认长到测试里到不了。
    private func make(limit: TimeInterval = 60) -> ConversationRig {
        let name = "ConversationCoverTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = ConversationRig(defaults: UserDefaults(suiteName: name)!)
        rig.controller.contentWaitLimit = limit
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

    /// 关掉一个停在 chat 的标签页，再 ⇧⌘T 重新打开它；网页视图报出它加载的地址（测试里不真的加载）。
    private func reopened(_ rig: ConversationRig, at url: URL? = nil) throws -> ChatTab {
        let b = try XCTUnwrap(rig.tabs.newTab())
        rig.commit(b)
        rig.report(b, Self.white)
        XCTAssertFalse(b.page.isCovered, "新增的（新对话）照原来撤")
        b.runtime.onURLChange?(url ?? chat)
        rig.tabs.closeTab(b)
        let r = try XCTUnwrap(rig.tabs.reopenClosedTab())
        r.runtime.onURLChange?(url ?? chat)
        return r
    }

    private func tag(_ tab: ChatTab) -> String { TabLog.tag(tab.id) }

    // MARK: - ⇧⌘T

    /// 重新打开的（显示着）：提交前网页里就有内容也不看；提交、报出同一深浅的颜色、加载完成都不撤（写一行“等对话内容”）；
    /// 对话内容出来才撤，写一行带标签的、淡出。
    func testAReopenedTabStaysCoveredUntilTheConversationShows() async throws {
        let rig = make()
        let r = try reopened(rig)
        let mark = rig.mark()
        XCTAssertTrue(r.page.coverAwaitsContent)
        XCTAssertEqual(rig.controller.shownCoverKind, .newTab)
        rig.contentShown = true
        try await pause(0.15)
        XCTAssertTrue(r.page.isCovered, "提交之前不看")
        rig.contentShown = false

        rig.commit(r)
        rig.report(r, Self.white)
        rig.finish(r)
        try await pause(0.15)
        XCTAssertTrue(r.page.isCovered, "外壳出来不撤")
        XCTAssertEqual(rig.controller.shownCoverKind, .newTab)
        XCTAssertEqual(rig.launchLines(since: mark), [
            "[launch] 新标签页的遮挡：网页开始显示，提交后页面底色报为浅色，等对话内容（最多 60000ms） \(tag(r))",
        ])

        rig.contentShown = true
        try await waitUntil { !r.page.isCovered }
        XCTAssertFalse(r.page.isCovered)
        XCTAssertNil(rig.controller.shownCoverKind)
        XCTAssertEqual(rig.controller.launchFadeView?.rootView.kind, .newTab)
        XCTAssertEqual(rig.launchLines(since: mark).last, "[launch] 启动画面结束：对话内容已出现（…ms） \(tag(r))")
        XCTAssertNil(r.conversationWatch, "看完自己停")
    }

    /// 一直认不出对话内容（选择器失效）：外壳出来以后 contentWaitLimit 撤。外壳是加载完成时出来的也一样。
    func testWithoutContentTheCoverGoesAfterTheWaitFromTheShell() async throws {
        let rig = make(limit: 0.3)
        let r = try reopened(rig)
        let mark = rig.mark()
        rig.commit(r)
        try await pause(0.4)
        XCTAssertTrue(r.page.isCovered, "外壳还没出来：时限不走")
        rig.finish(r)
        try await pause(0.15)
        XCTAssertTrue(r.page.isCovered)
        try await waitUntil { !r.page.isCovered }
        XCTAssertNil(rig.controller.shownCoverKind)
        XCTAssertEqual(rig.launchLines(since: mark), [
            "[launch] 新标签页的遮挡：网页已加载，等对话内容（最多 300ms） \(tag(r))",
            "[launch] 启动画面结束：等对话内容 300ms 还没出来（…ms） \(tag(r))",
        ])
    }

    /// 加载失败：马上撤，不等时限。
    func testAFailedLoadEndsItAtOnce() throws {
        let rig = make()
        let r = try reopened(rig)
        let mark = rig.mark()
        rig.fail(r)
        XCTAssertFalse(r.page.isCovered)
        XCTAssertNil(rig.controller.shownCoverKind)
        XCTAssertEqual(rig.launchLines(since: mark), ["[launch] 启动画面结束：加载失败（…ms） \(tag(r))"])
    }

    /// 网页离开要打开的那段对话（别的对话、首页、登录页）：马上撤，那一行没有地址。同一段对话换了写法（查询参数、
    /// 多了 /g/<gpt>）不撤。外壳出来之后离开的也马上撤。
    func testLeavingTheConversationEndsItAtOnce() throws {
        let away = ["https://chatgpt.com/c/other", "https://chatgpt.com/", "https://chatgpt.com/auth/login",
                    "https://auth.openai.com/log-in"]
        for (n, address) in away.enumerated() {
            let rig = make()
            let r = try reopened(rig)
            let mark = rig.mark()
            r.runtime.onURLChange?(URL(string: "https://chatgpt.com/c/abc?model=x"))
            r.runtime.onURLChange?(URL(string: "https://chatgpt.com/g/g-p-1/c/abc"))
            XCTAssertTrue(r.page.isCovered, "同一段对话（\(n)）")
            if n % 2 == 1 {
                rig.commit(r)
                rig.report(r, Self.white)
                XCTAssertTrue(r.page.isCovered)
            }
            r.runtime.onURLChange?(URL(string: address))
            XCTAssertFalse(r.page.isCovered, "离开（\(n)）")
            let lines = rig.launchLines(since: mark)
            XCTAssertEqual(lines.last, "[launch] 启动画面结束：网页不在要打开的那段对话上（…ms） \(tag(r))", "\(n)")
            XCTAssertFalse(lines.joined().contains("other"), "没有地址")
        }
    }

    // MARK: - 照原来的规则

    /// ⌘T 新增的（新对话）、⌘ 点击的链接不是对话（首页、GPT 首页）、网页增强关着时重新打开的：不等对话内容，
    /// 外壳出来（提交后报出同一深浅的颜色）就撤，照原来那一行。
    func testTabsWithoutAConversationToWaitForKeepTodaysRule() throws {
        let rig = make()
        let b = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertFalse(b.page.coverAwaitsContent)
        rig.commit(b)
        rig.report(b, Self.white)
        XCTAssertFalse(b.page.isCovered, "⌘T")

        for address in ["https://chatgpt.com/", "https://chatgpt.com/g/g-1"] {
            let link = try XCTUnwrap(rig.tabs.openLink(URL(string: address)!, from: rig.tabs.selected, .foreground))
            XCTAssertFalse(link.page.coverAwaitsContent, address)
            rig.commit(link)
            rig.report(link, Self.white)
            XCTAssertFalse(link.page.isCovered, address)
            rig.tabs.closeTab(link)
        }

        let off = make()
        off.settings.webEnhancements = false
        let r = try reopened(off)
        XCTAssertFalse(r.page.coverAwaitsContent)
        let mark = off.mark()
        off.commit(r)
        off.report(r, Self.white)
        XCTAssertFalse(r.page.isCovered, "网页增强关着")
        XCTAssertEqual(off.launchLines(since: mark),
                       ["[launch] 启动画面结束：网页开始显示，提交后页面底色报为浅色（…ms） \(tag(r))"])
    }

    /// ⇧⌘ 点击对话链接（马上显示）：和 ⇧⌘T 一样等对话内容。
    func testAForegroundConversationLinkWaitsForTheContent() async throws {
        let rig = make()
        let t = try XCTUnwrap(rig.tabs.openLink(chat, from: rig.first, .foreground))
        XCTAssertTrue(t.page.coverAwaitsContent)
        rig.commit(t)
        rig.report(t, Self.white)
        XCTAssertTrue(t.page.isCovered)
        rig.contentShown = true
        try await waitUntil { !t.page.isCovered }
        XCTAssertFalse(t.page.isCovered)
        XCTAssertEqual(rig.launchLines().last, "[launch] 启动画面结束：对话内容已出现（…ms） \(tag(t))")
    }

    // MARK: - ⌘ 点击在后台打开的

    /// 在下面渲染时对话内容就出来了：在后台撤（不显示的那一行），窗口不变；换上它不盖、不淡出。
    func testABackgroundTabWhoseContentShowsBehindIsNeverCoveredWhenShown() async throws {
        let rig = make(limit: 0.2)
        let b = try XCTUnwrap(rig.tabs.openLink(chat, from: rig.first, .background))
        XCTAssertTrue(b.page.coverAwaitsContent)
        XCTAssertTrue(rig.controller.isRenderingBehind(b.runtime.webView))
        b.runtime.onURLChange?(chat)
        let window = rig.windowState()
        rig.commit(b)
        rig.report(b, Self.white)
        try await pause(0.35)
        XCTAssertTrue(b.page.isCovered, "不显示：时限不走")
        rig.contentShown = true
        try await waitUntil { !b.page.isCovered }
        XCTAssertFalse(b.page.isCovered)
        XCTAssertEqual(rig.launchLines(), [
            "[launch] 新标签页的遮挡：网页开始显示，提交后页面底色报为浅色，等对话内容（页面显示时再等） \(tag(b))",
            "[launch] 不显示的页面的遮挡结束（新标签页）：对话内容已出现（…ms） \(tag(b))",
        ])
        XCTAssertEqual(rig.windowState(), window, "窗口不变")
        rig.tabs.select(b)
        XCTAssertNil(rig.controller.shownCoverKind)
        XCTAssertNil(rig.controller.launchFadeView)
    }

    /// 藏起以后还没有内容：时限不在后台走，也不再看网页；换上它时盖着，从那一刻起等时限（或内容）。
    func testABackgroundTabHiddenBeforeItsContentIsCoveredWhenShownUntilTheWaitEnds() async throws {
        let rig = make(limit: 0.3)
        rig.tabs.backgroundRenderSettle = 0.05
        let b = try XCTUnwrap(rig.tabs.openLink(chat, from: rig.first, .background))
        b.runtime.onURLChange?(chat)
        rig.commit(b)
        rig.finish(b)
        try await waitUntil { !rig.controller.isRenderingBehind(b.runtime.webView) }
        try await pause(0.5)
        XCTAssertTrue(b.page.isCovered, "时限不在后台走")
        XCTAssertNil(b.conversationWatch, "藏着不看")

        let mark = rig.mark()
        let shown = Date()
        rig.tabs.select(b)
        XCTAssertEqual(rig.controller.shownCoverKind, .newTab, "换上来盖着")
        try await pause(0.15)
        XCTAssertTrue(b.page.isCovered)
        try await waitUntil { !b.page.isCovered }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(shown), 0.28, "从显示时算")
        XCTAssertNil(rig.controller.shownCoverKind)
        XCTAssertEqual(rig.launchLines(since: mark), ["[launch] 启动画面结束：等对话内容 300ms 还没出来（…ms） \(tag(b))"])
    }

    /// 藏起以后网页里才有内容（藏着时不看）：换上它时盖着，再看到内容就撤。
    func testABackgroundTabHiddenBeforeItsContentEndsWhenTheContentShowsAfterSelecting() async throws {
        let rig = make()
        rig.tabs.backgroundRenderSettle = 0.05
        let b = try XCTUnwrap(rig.tabs.openLink(chat, from: rig.first, .background))
        b.runtime.onURLChange?(chat)
        rig.commit(b)
        rig.finish(b)
        try await waitUntil { !rig.controller.isRenderingBehind(b.runtime.webView) }
        rig.contentShown = true
        try await pause(0.3)
        XCTAssertTrue(b.page.isCovered, "藏着不看")
        rig.tabs.select(b)
        XCTAssertEqual(rig.controller.shownCoverKind, .newTab)
        try await waitUntil { !b.page.isCovered }
        XCTAssertFalse(b.page.isCovered)
        XCTAssertEqual(rig.launchLines().last, "[launch] 启动画面结束：对话内容已出现（…ms） \(tag(b))")
    }

    /// 不显示时到了原来的兜底（时限、上限）：不撤，留到显示时再等。
    func testFallbacksWhileHiddenWaitForTheTabToBeShown() async throws {
        let rig = make(limit: 0.3)
        rig.controller.launchScreenLimit = 0.05
        rig.controller.launchScreenCap = 0.1
        rig.tabs.backgroundRenderSettle = 0.05
        let b = try XCTUnwrap(rig.tabs.openLink(chat, from: rig.first, .background))
        rig.commit(b)
        try await pause(0.3)
        XCTAssertTrue(b.page.isCovered, "时限、上限都到了")
        XCTAssertTrue(b.page.contentWaitDue)
        rig.tabs.select(b)
        XCTAssertEqual(rig.controller.shownCoverKind, .newTab)
        try await pause(0.15)
        XCTAssertTrue(b.page.isCovered)
        try await waitUntil { !b.page.isCovered }
        XCTAssertEqual(rig.launchLines().last, "[launch] 启动画面结束：等对话内容 300ms 还没出来（…ms） \(tag(b))")
    }

    // MARK: - 切走、切回

    /// 显示着开始等、还没到点就切走：到点不撤；切回来盖着，从那一刻起重新等。
    func testSwitchingAwayDuringTheWaitRestartsItWhenShownAgain() async throws {
        let rig = make(limit: 0.3)
        let r = try reopened(rig)
        rig.commit(r)
        rig.report(r, Self.white)
        XCTAssertTrue(r.page.contentWaitRunning)
        rig.tabs.select(rig.first)
        try await pause(0.5)
        XCTAssertTrue(r.page.isCovered, "切走了：到点不撤")
        XCTAssertFalse(r.page.contentWaitRunning)
        let shown = Date()
        rig.tabs.select(r)
        XCTAssertEqual(rig.controller.shownCoverKind, .newTab)
        try await waitUntil { !r.page.isCovered }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(shown), 0.28)
        XCTAssertEqual(rig.launchLines().last, "[launch] 启动画面结束：等对话内容 300ms 还没出来（…ms） \(tag(r))")
    }
}

/// 网页里有没有排出对话内容（AdapterScripts.conversationShown，经适配器的 conversationContentShown()）。
/// 真实的 WebKit，固定的假页面（loadHTMLString，地址是主站的对话，不联网），网页视图不放进窗口。
@MainActor
final class ConversationShownScriptTests: XCTestCase {
    private func adapter(_ body: String, enhancements: Bool = true) async throws -> (ChatGPTAdapter, WKWebView) {
        let name = "ConversationShownScriptTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: name)!)
        settings.webEnhancements = enhancements
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 720, height: 520), configuration: config)
        web.loadHTMLString("<html><body>\(body)</body></html>", baseURL: URL(string: "https://chatgpt.com/c/abc"))
        for _ in 0..<150 where web.isLoading || web.url == nil {
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(50))
        return (ChatGPTAdapter(webView: web, diagnostics: Diagnostics(), settings: settings), web)
    }

    func testARenderedTurnCounts() async throws {
        for body in ["<main><div data-turn-key=\"t1\"><p>hello</p></div></main>",
                     "<article data-testid=\"conversation-turn-3\"><p>hello</p></article>",
                     "<div data-message-author-role=\"user\"><p>hello</p></div>"] {
            let (a, web) = try await adapter(body)
            let shown = await a.conversationContentShown()
            XCTAssertTrue(shown, body)
            _ = web
        }
    }

    /// 空的新聊天页（没有一问一答）、藏着留在页面里的旧内容、没有高度的：都不算。网页增强关着：不看，不算。
    func testNoTurnsHiddenTurnsOrEnhancementsOffDoNotCount() async throws {
        for body in ["<main><form><textarea></textarea></form></main>",
                     "<main><div data-turn-key=\"t1\" style=\"display:none\"><p>old</p></div></main>",
                     "<main><div data-turn-key=\"t1\" style=\"height:0;overflow:hidden\"></div></main>"] {
            let (a, web) = try await adapter(body)
            let shown = await a.conversationContentShown()
            XCTAssertFalse(shown, body)
            _ = web
        }
        let (off, web) = try await adapter("<main><div data-turn-key=\"t1\"><p>hello</p></div></main>", enhancements: false)
        let shown = await off.conversationContentShown()
        XCTAssertFalse(shown)
        _ = web
    }
}

/// 启动时的标签页（标签 1）、窗口和 ChatTabs，像 AppDelegate 那样建（同 NewTabEarlyRevealTests 的 EarlyRig）；
/// 新增的建法是正式运行时的 ChatTab.make，网页视图建好就固定在灰色，加载请求只记下来；网页里有没有对话内容读 contentShown。
@MainActor
private final class ConversationRig {
    static let start = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    let settings: AppSettings
    let diagnostics = Diagnostics()
    let appearance: PageAppearance
    let first: ChatTab
    let controller: ChatWindowController
    let network = NetworkStatus(startsMonitor: false)
    private(set) var tabs: ChatTabs!
    /// 网页里排出了对话内容（每个标签页都按它答）。
    var contentShown = false

    init(defaults: UserDefaults) {
        let rgb = ConversationCoverTests.white
        defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init), forKey: "pageBackgroundRGB")
        settings = AppSettings(defaults: defaults)
        appearance = PageAppearance(defaults: defaults)
        let list = TabList()
        first = Self.pin(ChatTab.make(id: list.selected, diagnostics: diagnostics, settings: settings))
        controller = ChatWindowController(webView: first.runtime.webView,
                                          toolbar: Color.clear.frame(height: WebBar.height).frame(maxWidth: .infinity),
                                          diagnostics: diagnostics, appearance: appearance, page: first.page)
        controller.pageColorSettleLimit = 60
        controller.layoutWaitLimit = 60
        tabs = ChatTabs(list: list, tab: first, windowController: controller, diagnostics: diagnostics, network: network,
                        hideWindow: { _ in },
                        focusInput: { _ in "ConversationCoverTests" },
                        saveLastConversation: { _ in },
                        mediaState: { _ in "none" },
                        openNewChat: { _ in true },
                        makeTab: { [weak self] id in self!.build(id) },
                        revealWindow: {})
        // 这里的测试核对关闭后马上收尾、照记录重新加载（原来的做法）：关闭的标签页不留着（留着见 ClosedTabKeepTests）。
        tabs.closedTabKeepTime = 0
        tabs.wire(first)
        first.runtime.loadRequest = { _ in }
        tabs.windowIsVisible = { true }
        tabs.showHint = { _, _ in }
        tabs.tipRecord = MemoryTabTipRecord(shown: true)
        tabs.conversationShown = { [weak self] _ in self?.contentShown ?? false }
        tabs.conversationCheckInterval = 0.02
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

    func report(_ tab: ChatTab, _ color: NSColor) {
        tab.runtime.webView.underPageBackgroundColor = color
    }

    func allLines() -> [String] {
        LiveInputLogLines.compared(diagnostics.entries)
            .filter { $0.category != "esc" && $0.category != "render" }
            .map { "[\($0.category)] \($0.message)" }
    }

    /// 现在写过几行（launchLines(since:) 从这里往后取）。
    func mark() -> Int { allLines().count }

    /// [launch] 那几行（从第 since 行起），耗时换成“…”。
    func launchLines(since: Int = 0) -> [String] {
        allLines().dropFirst(since).filter { $0.hasPrefix("[launch]") }
            .map { $0.replacingOccurrences(of: #"（\d+ms）"#, with: "（…ms）", options: .regularExpression) }
    }

    func windowState() -> String {
        "显示=\(tabs.tabs.firstIndex { $0.page === controller.page } ?? -1) "
            + "网页=\(tabs.tabs.firstIndex { $0.runtime.webView === controller.webView } ?? -1) "
            + "遮挡=\(controller.isShowingLaunchScreen) 样子=\(controller.shownCoverKind.map { "\($0)" } ?? "无") "
            + "淡出=\(controller.launchFadeView.map { "\(ObjectIdentifier($0))" } ?? "无") "
            + "提示=\(controller.shownLoadProblem.map { "\($0)" } ?? "无")"
    }
}
