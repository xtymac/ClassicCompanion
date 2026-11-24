import AppKit
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 关闭的标签页留着（ChatTabs.closeTab(_:) → park(_:)，最多一个，closedTabKeepTime 秒）：
/// - 每个关闭的入口（标签栏的 × 和中键都经 tabBar.onClose、⌘W 键、关闭选中的）都先留着，不释放；
/// - 留着期间 ⇧⌘T 原样放回同一个 ChatTab（同一个网页视图），放在原位置、选中、不遮挡、不加载；
/// - 到时间释放，和原来关闭时一样（运行时关闭、网页视图离开窗口），记录照旧，之后 ⇧⌘T 照记录重新加载；
/// - 再关一个时先留着的马上释放；临时聊天不留；到上限时不放回、接着留着；
/// - 留着时不出声、不弹出：媒体停掉、对话框按取消回答、弹窗关掉、新窗口不开；放回后对话框照常；
/// - 菜单（canReopenClosedTab、onTabsChanged）跟着变；退出时释放；改设置时它也跟着改。
/// 标签页按正式的建法建（TabCloseRig），窗口不显示，加载只记下来，媒体停掉换成记录（不碰 WebKit 的媒体）。
@MainActor
final class ClosedTabKeepTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!
    private let other = URL(string: "https://chatgpt.com/c/def")!

    private func make(capacity: Int = TabList.defaultCapacity) -> TabCloseRig {
        let name = "ClosedTabKeepTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabCloseRig(defaults: UserDefaults(suiteName: name)!, capacity: capacity)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        rig.tabs.closedTabKeepTime = TabList.closedTabKeepSeconds   // TabCloseRig 设成 0（原来的做法），这里用正式的值
        return rig
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await pause(0.02) }
    }

    /// 媒体停掉、放开的调用记在 calls 里（“2 停”“2 放开”），不碰 WebKit。
    private func recordMedia(_ tab: ChatTab, into calls: MediaCalls) {
        let name = "\(tab.id.rawValue)"
        tab.runtime.setMediaSuspended = { _, suspended in calls.list.append("\(name) \(suspended ? "停" : "放开")") }
    }

    /// 加一个标签页，记下媒体调用，报一个地址。
    private func add(_ rig: TabCloseRig, at url: URL?, media: MediaCalls = MediaCalls()) -> ChatTab {
        let tab = rig.add()
        recordMedia(tab, into: media)
        if let url { tab.runtime.onURLChange?(url) }
        return tab
    }

    /// tab 留着：不在这组里、不在标签栏上、是 parked、运行时和页面都没关、运行时留着、网页视图不是显示着的那个、列表记着它。
    private func assertParked(_ rig: TabCloseRig, _ tab: ChatTab, _ step: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(rig.tabs.parked === tab, step, file: file, line: line)
        XCTAssertFalse(rig.tabs.holds(tab), step, file: file, line: line)
        XCTAssertFalse(rig.tabs.tabBar.items.contains { $0.id == tab.id }, step, file: file, line: line)
        XCTAssertEqual(rig.tabs.list.kept?.id, tab.id, step, file: file, line: line)
        XCTAssertFalse(rig.tabs.list.tabs.contains(tab.id), step, file: file, line: line)
        XCTAssertFalse(tab.runtime.isClosed, step, file: file, line: line)
        XCTAssertTrue(tab.runtime.isParked, step, file: file, line: line)
        XCTAssertFalse(tab.page.isClosed, step, file: file, line: line)
        XCTAssertFalse(rig.controller.webView === tab.runtime.webView, step, file: file, line: line)
        XCTAssertTrue(tab.runtime.webView.superview == nil || tab.runtime.webView.isHidden, "藏着或不在窗口里：\(step)",
                      file: file, line: line)
        XCTAssertTrue(rig.tabs.canReopenClosedTab, step, file: file, line: line)
    }

    // MARK: - 每个关闭的入口都先留着

    func testEveryCloseEntryParksTheTab() throws {
        let entries: [(String, (TabCloseRig, ChatTab) -> Void)] = [
            ("标签栏的 ×、中键（不选中的）", { rig, tab in rig.tabs.tabBar.onClose?(tab.id) }),
            ("标签栏的 ×、中键（选中的）", { rig, tab in
                rig.tabs.select(tab)
                rig.tabs.tabBar.onClose?(tab.id)
            }),
            ("⌘W 键", { rig, tab in
                rig.tabs.select(tab)
                XCTAssertTrue(rig.tabs.handleKey(TabKeys.Match(.closeTab, "⌘W"), TabKeys.Context(inChatWindow: true)))
            }),
            ("菜单的关闭标签页（closeSelectedTab）", { rig, tab in
                rig.tabs.select(tab)
                rig.tabs.closeSelectedTab()
            }),
        ]
        for (entry, close) in entries {
            let rig = make()
            let media = MediaCalls()
            let b = add(rig, at: chat, media: media)
            _ = rig.add()
            let mark = rig.mark()
            close(rig, b)
            assertParked(rig, b, entry)
            XCTAssertEqual(media.list, ["2 停"], entry)
            XCTAssertEqual(rig.tabs.tabs.count, 2, entry)
            XCTAssertTrue(rig.controller.webView === rig.tabs.selected.runtime.webView, entry)
            let tabLines = rig.lines(since: mark).filter { $0.hasPrefix("[tabs]") && $0.hasSuffix("【标签2】") }
            XCTAssertEqual(Array(tabLines.suffix(2)), ["[tabs] 关闭（剩 2 个） 【标签2】",
                                                       "[tabs] 留着（60 秒内 ⇧⌘T 原样放回） 【标签2】"], entry)
            XCTAssertTrue(rig.lines(since: mark).contains("[web] 留着：停掉媒体 【标签2】"), entry)
            XCTAssertFalse(rig.lines(since: mark).contains { $0.hasPrefix("[") && $0.contains("chatgpt.com/c/") },
                           "日志里没有地址：\(entry)")
        }
    }

    // MARK: - ⇧⌘T 原样放回

    /// 显示过的 2（在对话上）关掉、留着，⇧⌘T：回来的是同一个 ChatTab、同一个网页视图，在原位置（第 2 个），选中、窗口显示它，
    /// 没有遮挡、没有新的加载、没有建新的标签页；它的记录一起消耗；运行时不再留着、媒体放开。之后的对话框照常显示。
    func testReopenBringsBackTheSameTabAtItsPlaceWithoutLoadOrCover() throws {
        let rig = make()
        let media = MediaCalls()
        let b = add(rig, at: chat, media: media)
        let c = rig.add()
        rig.tabs.select(b)
        let web = b.runtime.webView
        let loadsBefore = rig.loads
        rig.tabs.closeSelectedTab()
        XCTAssertTrue(rig.tabs.selected === c, "右边的邻居")
        assertParked(rig, b, "关掉选中的")
        XCTAssertTrue(web.isHidden, "藏在容器里")

        let mark = rig.mark()
        let back = try XCTUnwrap(rig.tabs.reopenClosedTab())
        XCTAssertTrue(back === b)
        XCTAssertTrue(back.runtime.webView === web)
        XCTAssertEqual(rig.tabs.tabs.map(\.id.rawValue), [1, 2, 3], "原位置")
        XCTAssertTrue(rig.tabs.selected === b)
        XCTAssertTrue(rig.controller.webView === web)
        XCTAssertTrue(rig.controller.page === b.page)
        XCTAssertFalse(web.isHidden)
        XCTAssertFalse(b.page.isCovered, "不遮挡")
        XCTAssertFalse(rig.controller.isShowingLaunchScreen)
        XCTAssertEqual(rig.loads, loadsBefore, "不加载")
        XCTAssertNil(rig.tabs.parked)
        XCTAssertNil(rig.tabs.list.kept)
        XCTAssertFalse(b.runtime.isParked)
        XCTAssertTrue(rig.tabs.list.recentlyClosed.isEmpty, "它的记录一起消耗")
        XCTAssertFalse(rig.tabs.canReopenClosedTab)
        XCTAssertEqual(media.list, ["2 停", "2 放开"])
        XCTAssertEqual(b.url, chat, "地址还是它的")
        let tabLines = rig.lines(since: mark).filter { $0.hasPrefix("[tabs]") }
        XCTAssertEqual(tabLines, ["[tabs] 原样放回（第 2 个，现在 3 个，还有 0 条记录） 【标签2】", "[tabs] 选中 【标签2】"])
    }

    /// 写了草稿、还没对话地址的新对话页（这里是首页）：原来关掉就不能重新打开；留着时能放回，回来的还是它。
    func testATabWithoutAConversationAddressCanBeBroughtBackWhileKept() throws {
        let rig = make()
        let b = add(rig, at: WebRuntime.homeURL)
        rig.tabs.closeTab(b)
        XCTAssertTrue(rig.tabs.list.recentlyClosed.isEmpty, "不记")
        XCTAssertTrue(rig.tabs.canReopenClosedTab, "留着的也算")
        XCTAssertTrue(rig.tabs.reopenClosedTab() === b)
        XCTAssertEqual(rig.tabs.tabs.count, 2)
        XCTAssertFalse(rig.tabs.canReopenClosedTab)
    }

    /// 留着的网页视图在留着期间报的地址、标题记在它上面：放回时是现在的（不是关闭那一刻的）。
    func testTheKeptTabFollowsItsOwnAddressAndTitleWhileKept() throws {
        let rig = make()
        let b = add(rig, at: WebRuntime.homeURL)
        rig.tabs.closeTab(b)
        b.runtime.onURLChange?(chat)
        b.runtime.onTitleChange?("T", false)
        XCTAssertEqual(b.url, chat)
        XCTAssertEqual(b.title, "T")
        XCTAssertFalse(rig.tabs.tabBar.items.contains { $0.id == b.id }, "不进标签栏")
        XCTAssertTrue(rig.tabs.reopenClosedTab() === b)
        XCTAssertTrue(rig.tabs.tabBar.items.contains { $0.id == b.id })
    }

    // MARK: - 到时间释放

    /// 到时间：和原来关闭一样收尾（运行时、页面关闭，网页视图离开窗口），写一行；记录留着，⇧⌘T 照记录新建、加载。
    /// 菜单在释放时得到通知（onTabsChanged）。
    func testExpiryReleasesTheTabAndFallsBackToTheRecord() async throws {
        let rig = make()
        rig.tabs.closedTabKeepTime = 0.1
        var changes = 0
        rig.tabs.onTabsChanged = { changes += 1 }
        let b = add(rig, at: chat)
        rig.tabs.select(b)
        let web = b.runtime.webView
        XCTAssertNotNil(web.superview)
        rig.tabs.closeSelectedTab()
        assertParked(rig, b, "关掉以后")
        let changesAfterPark = changes
        let mark = rig.mark()
        try await waitUntil { rig.tabs.parked == nil }
        XCTAssertNil(rig.tabs.parked)
        XCTAssertNil(rig.tabs.list.kept)
        XCTAssertTrue(b.runtime.isClosed)
        XCTAssertTrue(b.page.isClosed)
        XCTAssertNil(web.superview, "网页视图离开窗口")
        XCTAssertEqual(changes, changesAfterPark + 1, "告诉菜单")
        XCTAssertEqual(rig.tabs.list.recentlyClosed.entries.map(\.url), [chat], "记录照旧")
        XCTAssertTrue(rig.tabs.canReopenClosedTab)
        let lines = rig.lines(since: mark)
        XCTAssertTrue(lines.contains("[tabs] 释放留着的标签页：到时间（0.1 秒） 【标签2】"), "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("[web] 关闭网页") && $0.hasSuffix("【标签2】") })

        let again = try XCTUnwrap(rig.tabs.reopenClosedTab())
        XCTAssertFalse(again === b, "新建的")
        XCTAssertEqual(rig.loads["\(again.id.rawValue)"], [chat], "照记录加载")
    }

    /// 没有记录的（新对话页）到时间就没了：菜单项变灰（canReopenClosedTab false），⇧⌘T 什么都不做。
    func testAKeptTabWithoutARecordIsGoneAfterExpiry() async throws {
        let rig = make()
        rig.tabs.closedTabKeepTime = 0.1
        let b = add(rig, at: WebRuntime.homeURL)
        rig.tabs.closeTab(b)
        XCTAssertTrue(rig.tabs.canReopenClosedTab)
        try await waitUntil { rig.tabs.parked == nil }
        XCTAssertTrue(b.runtime.isClosed)
        XCTAssertFalse(rig.tabs.canReopenClosedTab)
        XCTAssertNil(rig.tabs.reopenClosedTab())
    }

    /// 放回以后排下的到时间不再做事（不释放放回的那一个）。
    func testABroughtBackTabIsNotReleasedWhenItsTimeWouldHaveRunOut() async throws {
        let rig = make()
        rig.tabs.closedTabKeepTime = 0.1
        let b = add(rig, at: chat)
        rig.tabs.closeTab(b)
        XCTAssertTrue(rig.tabs.reopenClosedTab() === b)
        try await pause(0.3)
        XCTAssertFalse(b.runtime.isClosed)
        XCTAssertTrue(rig.tabs.holds(b))
    }

    // MARK: - 再关一个、临时聊天、上限

    /// 留着 2 时关 3：2 马上释放（它的记录留着），3 留着。⇧⌘T 先原样放回 3，再按一次照 2 的记录新建。
    func testClosingAnotherTabReleasesTheKeptOneAtOnce() throws {
        let rig = make()
        let b = add(rig, at: chat)
        let c = add(rig, at: other)
        rig.tabs.closeTab(b)
        let mark = rig.mark()
        rig.tabs.closeTab(c)
        XCTAssertTrue(b.runtime.isClosed)
        XCTAssertTrue(b.page.isClosed)
        assertParked(rig, c, "后关的那一个")
        XCTAssertEqual(rig.tabs.list.recentlyClosed.entries.map(\.url), [chat, other])
        let tabLines = rig.lines(since: mark).filter { $0.hasPrefix("[tabs]") }
        XCTAssertEqual(tabLines, ["[tabs] 关闭（剩 1 个） 【标签3】",
                                  "[tabs] 释放留着的标签页：又关闭了一个标签页 【标签2】",
                                  "[tabs] 留着（60 秒内 ⇧⌘T 原样放回） 【标签3】"])
        XCTAssertTrue(rig.tabs.reopenClosedTab() === c)
        let fresh = try XCTUnwrap(rig.tabs.reopenClosedTab())
        XCTAssertFalse(fresh === b)
        XCTAssertEqual(rig.loads["\(fresh.id.rawValue)"], [chat])
    }

    /// 临时聊天不留：马上释放，和原来一样（不进最近关闭，⇧⌘T 什么都不做）；之前留着的照样先释放。
    func testTemporaryChatsAreReleasedAtOnce() throws {
        let rig = make()
        let media = MediaCalls()
        let b = add(rig, at: WebRuntime.homeURL)
        let t = add(rig, at: URL(string: "https://chatgpt.com/?temporary-chat=true")!, media: media)
        rig.tabs.closeTab(b)
        rig.tabs.select(t)
        rig.tabs.closeSelectedTab()
        XCTAssertNil(rig.tabs.parked)
        XCTAssertTrue(t.runtime.isClosed)
        XCTAssertTrue(b.runtime.isClosed, "之前留着的先释放")
        XCTAssertEqual(media.list, [], "不留就不停媒体（运行时关闭）")
        XCTAssertFalse(rig.tabs.canReopenClosedTab)
        XCTAssertNil(rig.tabs.reopenClosedTab())
    }

    /// closedTabKeepTime 为 0：不留，马上释放（原来的做法）。
    func testZeroKeepTimeReleasesAtOnce() throws {
        let rig = make()
        rig.tabs.closedTabKeepTime = 0
        let b = add(rig, at: chat)
        rig.tabs.closeTab(b)
        XCTAssertNil(rig.tabs.parked)
        XCTAssertTrue(b.runtime.isClosed)
    }

    /// 到上限：⇧⌘T 和原来一样显示到上限的提示、不放回，2 接着留着，到时间照常释放。
    func testAtCapacityTheKeptTabStaysKeptUntilItsTimeRunsOut() async throws {
        let rig = make(capacity: 3)
        rig.tabs.closedTabKeepTime = 0.3
        let b = add(rig, at: chat)
        _ = rig.add()
        rig.tabs.closeTab(b)
        _ = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertTrue(rig.tabs.list.isFull)
        let mark = rig.mark()
        XCTAssertNil(rig.tabs.reopenClosedTab())
        XCTAssertEqual(rig.limitHints, 1)
        XCTAssertTrue(rig.lines(since: mark).contains("[tabs] 不重新打开标签页：已到上限（3 个）"))
        assertParked(rig, b, "到上限时")
        try await waitUntil { rig.tabs.parked == nil }
        XCTAssertTrue(b.runtime.isClosed)
        XCTAssertEqual(rig.tabs.list.recentlyClosed.entries.map(\.url), [chat])
    }

    // MARK: - 留着时不出声、不弹出

    /// 留着的 2：排着的对话框按取消回答（不显示），之后来的也马上按取消回答；开着的弹窗拆掉、关掉；要开新窗口：不开。
    /// 放回、选中以后对话框照常显示。
    func testAKeptTabIsInert() async throws {
        let rig = make()
        let c = try await capture()
        let b = add(rig, at: chat)
        let presented = Presented()
        b.runtime.presentAlert = { _, message, _ in presented.list.append(message) }
        let answers = Presented()
        askAlert(b, "排着的", c) { answers.list.append("排着的结束") }
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        let popup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable],
                             backing: .buffered, defer: true)
        popup.isReleasedWhenClosed = false
        b.runtime.adoptPopupForTesting(popup)

        let mark = rig.mark()
        rig.tabs.closeTab(b)
        try await waitUntil { answers.list.count == 1 }
        XCTAssertEqual(answers.list, ["排着的结束"])
        XCTAssertEqual(b.runtime.heldDialogCount, 0)
        XCTAssertFalse(b.runtime.tracksPopupForTesting(popup), "弹窗拆掉")
        XCTAssertTrue(rig.lines(since: mark).contains("[web] 留着：停掉媒体，关掉 1 个弹窗，网页的对话框按取消处理（提示框 1 个） 【标签2】"))

        askAlert(b, "留着时来的", c) { answers.list.append("留着时来的结束") }
        try await waitUntil { answers.list.count == 2 }
        XCTAssertEqual(presented.list, [], "都不显示")

        let popupMark = rig.mark()
        let opened = b.runtime.webView(b.runtime.webView, createWebViewWith: WKWebViewConfiguration(), for: c.action,
                                       windowFeatures: WKWindowFeatures())
        XCTAssertNil(opened)
        XCTAssertEqual(rig.lines(since: popupMark), ["[nav] 留着的标签页要开新窗口：不开 【标签2】"])

        XCTAssertTrue(rig.tabs.reopenClosedTab() === b)
        askAlert(b, "放回以后", c) { answers.list.append("放回以后结束") }
        try await waitUntil { answers.list.count == 3 }
        XCTAssertEqual(presented.list, ["放回以后"], "放回以后照常显示")
    }

    /// 正式的媒体停掉用的是 WebKit 的三个调用：在一个空白网页视图上调用不出错、能放开（不出声，测试里没有媒体）。
    func testTheRealMediaSuspensionCallsAreHarmlessOnAnEmptyPage() async throws {
        let web = WKWebView(frame: .zero)
        WebRuntime.suspendMedia(of: web, true)
        try await pause(0.2)
        WebRuntime.suspendMedia(of: web, false)
        let state = await web.requestMediaPlaybackState()
        XCTAssertEqual(state, WKMediaPlaybackState.none)
    }

    // MARK: - 退出、改设置

    /// 退出时（AppDelegate.applicationWillTerminate 调用 releaseParkedTab("应用退出")）：马上释放，写一行。没有留着的：什么都不做。
    func testQuittingReleasesTheKeptTab() throws {
        let rig = make()
        let b = add(rig, at: chat)
        rig.tabs.closeTab(b)
        let mark = rig.mark()
        rig.tabs.releaseParkedTab("应用退出")
        XCTAssertTrue(b.runtime.isClosed)
        XCTAssertNil(rig.tabs.parked)
        XCTAssertEqual(rig.lines(since: mark).first, "[tabs] 释放留着的标签页：应用退出 【标签2】")
        let again = rig.mark()
        rig.tabs.releaseParkedTab("应用退出")
        XCTAssertEqual(rig.lines(since: again), [])
    }

    /// 改页面缩放：留着的也改，放回时和别的标签页一样。
    func testSettingsReachTheKeptTab() throws {
        let rig = make()
        let b = add(rig, at: chat)
        rig.tabs.closeTab(b)
        rig.tabs.setPageZoom(1.25)
        XCTAssertEqual(b.runtime.webView.pageZoom, 1.25)
        rig.tabs.setPageAccessibilityAllowed(true)
        rig.tabs.applyEnhancementScripts()
        rig.tabs.retitlePopups()
        XCTAssertTrue(rig.tabs.reopenClosedTab() === b)
    }

    // MARK: - 像 WebKit 那样调用代理

    private func askAlert(_ tab: ChatTab, _ message: String, _ c: Captured, done: @escaping @MainActor () -> Void) {
        let delegate: any WKUIDelegate = tab.runtime
        delegate.webView?(tab.runtime.webView, runJavaScriptAlertPanelWithMessage: message, initiatedByFrame: c.frame) {
            done()
        }
    }

    /// 一个真的 frame 和导航动作（主机是 chatgpt.com），从一个不属于任何标签页的网页视图拿（本地 html，不联网）。
    private func capture() async throws -> Captured {
        let catcher = Catcher()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        web.navigationDelegate = catcher
        web.uiDelegate = catcher
        web.loadHTMLString("<html><body><input type=file id=f></body></html>", baseURL: chat)
        try await waitUntil(5) { web.url == chat && !web.isLoading && catcher.action != nil }
        _ = try await web.evaluateJavaScript("document.getElementById('f').click(); 0")
        try await waitUntil(5) { catcher.frame != nil }
        return Captured(frame: try XCTUnwrap(catcher.frame), action: try XCTUnwrap(catcher.action), web: web, catcher: catcher)
    }
}

@MainActor
private final class MediaCalls {
    var list: [String] = []
}

@MainActor
private final class Presented {
    var list: [String] = []
}

@MainActor
private struct Captured {
    let frame: WKFrameInfo
    let action: WKNavigationAction
    let web: WKWebView
    let catcher: Catcher
}

@MainActor
private final class Catcher: NSObject, WKNavigationDelegate, WKUIDelegate {
    var action: WKNavigationAction?
    var frame: WKFrameInfo?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        action = navigationAction
        return .allow
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        self.frame = frame
        return nil
    }
}
