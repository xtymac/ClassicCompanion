import AppKit
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 切换标签页（ChatTabs.select(_:)）。三个标签页，正式运行时的建法（ChatTab.make，日志带标签 1、2、3）：
/// t1 是启动时的那个，选中、窗口显示着；t2、t3 由 ChatTabs.add 加进来。核对：
/// - 选中项、窗口显示的页面和网页视图一起换；写一行“选中 【标签N】”（没有地址和标题）；选中的、不在这组里的、关闭的：什么都不做。
/// - 顺序：先改选中项，再让窗口显示（进行中的切模式在显示时结束，换下去的那一页记下的阅读位置留给它自己，不放回）。
/// - 跟着换上来的那一页的事：聚焦（窗口是 key 窗口才聚焦，之前排着的都作废，D5）、记下可恢复的对话地址、
///   放回它留着的阅读位置（窗口显示它之后；它在后台换过页面的早已丢弃）。媒体状态每页和自己的比。
/// - 遮挡、提示、淡出层照换上来的那一页投（窗口那边的细节在 TabDisplayTests）。
/// - 显示过又换下去的标签页关闭以后，它的网页视图从窗口里拿出来，和标签页一起释放。
/// 真的 ChatWindowController（不显示窗口）、真的运行时（不看网络，加载请求记下来不发出去）。AppDelegate 交给 ChatTabs 的几样
/// 换成记录（只记名字，不持有适配器）。切模式的快照和排版换成手动送回（不显示窗口拍不到真的快照）。
@MainActor
final class TabSelectTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!
    private let other = URL(string: "https://chatgpt.com/c/def")!

    private func make() -> ThreeTabs {
        let name = "TabSelectTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = ThreeTabs(defaults: UserDefaults(suiteName: name)!)
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

    // MARK: - 选中、显示、日志

    /// 1 → 2 → 3 → 1：选中项、窗口显示的页面和网页视图一起换，换下去的网页视图藏着；每次一行“选中”，带换上来的标签。
    func testSelectMakesTheTabSelectedAndShownAndWritesOneLine() {
        let rig = make()
        let mark = rig.mark()
        for i in [1, 2, 0] {
            let tab = rig.t[i]
            rig.tabs.select(tab)
            XCTAssertTrue(rig.tabs.selected === tab)
            XCTAssertTrue(rig.controller.page === tab.page)
            XCTAssertTrue(rig.controller.webView === tab.runtime.webView)
            XCTAssertFalse(tab.runtime.webView.isHidden)
        }
        XCTAssertTrue(rig.t[1].runtime.webView.isHidden)
        XCTAssertTrue(rig.t[2].runtime.webView.isHidden)
        XCTAssertEqual(rig.lines(since: mark), ["[tabs] 选中 【标签2】", "[tabs] 选中 【标签3】", "[tabs] 选中 【标签1】"])
    }

    /// 选中的、拿掉的（不在这组里）、关闭的：什么都不做——选中项、窗口、日志、聚焦、记下的地址都不变。
    func testSelectingTheSelectedTabATabOutsideTheGroupOrAClosedTabDoesNothing() async throws {
        let rig = make()
        rig.tabs.windowIsKey = { true }
        rig.t[1].runtime.onURLChange?(chat)
        rig.t[2].runtime.onURLChange?(other)
        rig.tabs.removeForTesting(rig.t[1])
        rig.tabs.close(rig.t[2])
        let mark = rig.mark()

        rig.tabs.select(rig.t[0])
        rig.tabs.select(rig.t[1])
        rig.tabs.select(rig.t[2])
        try await pause(0.3)
        XCTAssertTrue(rig.tabs.selected === rig.t[0])
        XCTAssertTrue(rig.controller.page === rig.t[0].page)
        XCTAssertTrue(rig.controller.webView === rig.t[0].runtime.webView)
        XCTAssertNil(rig.t[1].runtime.webView.superview)
        XCTAssertNil(rig.t[2].runtime.webView.superview)
        XCTAssertEqual(rig.lines(since: mark), [])
        XCTAssertEqual(rig.focused, [])
        XCTAssertEqual(rig.saved, [])
    }

    // MARK: - 顺序：先改选中项

    /// 在 t1 上开始切模式（记下 t1 的阅读位置），网页还在排版时切换到 t2：窗口显示 t2 时先结束切模式，
    /// 那时选中的已经是 t2，所以 t1 的位置留在 t1 上，不放回到正要藏起的 t1（先显示、后改选中项的话会放回）。
    /// 再切回 t1：窗口显示 t1 之后放回那一次。
    func testTheSelectionChangesBeforeTheWindowEndsAModeSwitch() throws {
        let rig = make()
        rig.t[0].runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        let layout = rig.manualLayout()
        let mark = rig.mark()
        rig.controller.beginLayoutChangeForTesting(to: rig.biggerFrame())
        layout.snapshots[0](NSImage(size: NSSize(width: 10, height: 10)))
        XCTAssertEqual(calls.list, ["记下 1"])

        rig.tabs.select(rig.t[1])
        XCTAssertFalse(rig.controller.isChangingLayout)
        XCTAssertEqual(calls.list, ["记下 1"], "不放回到换下去的 t1")
        XCTAssertEqual(rig.t[0].pendingReadingRestore?.token, 1)
        XCTAssertEqual(rig.lines(since: mark).filter { !$0.hasPrefix("[window]") }, [
            "[tabs] 选中 【标签2】",
            "[reading] 阅读位置：这一页没有显示，记下的位置留到它再显示并排好版时放回 【标签1】",
        ])

        rig.tabs.select(rig.t[0])
        XCTAssertEqual(calls.list, ["记下 1", "放回 1（窗口显示着它）"], "窗口显示 t1 之后放回")
        XCTAssertEqual(calls.tokens, [1, 1])
        XCTAssertNil(rig.t[0].pendingReadingRestore)
        XCTAssertEqual(rig.lines(since: mark).filter { !$0.hasPrefix("[window]") }.suffix(2), [
            "[tabs] 选中 【标签1】",
            "[reading] 阅读位置：这一页又显示并排好版，放回留着的位置 【标签1】",
        ])
    }

    /// t1 留着阅读位置时在后台换了对话（或者重新提交）：当场丢弃；再切回 t1 时什么都不放回。
    func testAPendingPositionOfATabThatNavigatedMeanwhileIsNotRestoredOnReturn() throws {
        for commits in [false, true] {
            let rig = make()
            rig.t[0].runtime.onURLChange?(chat)
            let calls = rig.recordReadingPosition()
            let layout = rig.manualLayout()
            rig.controller.beginLayoutChangeForTesting(to: rig.biggerFrame())
            layout.snapshots[0](NSImage(size: NSSize(width: 10, height: 10)))
            rig.tabs.select(rig.t[1])
            XCTAssertNotNil(rig.t[0].pendingReadingRestore)
            if commits {
                rig.t[0].runtime.webView(rig.t[0].runtime.webView, didCommit: nil)
            } else {
                rig.t[0].runtime.onURLChange?(other)
            }
            XCTAssertEqual(calls.list, ["记下 1", "丢弃 1"], "后台换页面当场丢弃（提交=\(commits)）")
            rig.tabs.select(rig.t[0])
            XCTAssertEqual(calls.list, ["记下 1", "丢弃 1"], "切回来不放回（提交=\(commits)）")
        }
    }

    /// 两次切模式之间切换：t1 那次迟到的排版完成不结束 t2 上开始的那一次；t2 那次照常放回 t2，t1 留着的切回时放回 t1。
    func testALateLayoutOfTheOutgoingTabDoesNotEndTheNextTabsModeSwitch() {
        let rig = make()
        rig.t[0].runtime.onURLChange?(chat)
        rig.t[1].runtime.onURLChange?(other)
        let calls = rig.recordReadingPosition()
        let layout = rig.manualLayout()
        rig.controller.beginLayoutChangeForTesting(to: rig.biggerFrame())
        layout.snapshots[0](NSImage(size: NSSize(width: 10, height: 10)))
        rig.tabs.select(rig.t[1])
        rig.controller.beginLayoutChangeForTesting(to: rig.biggerFrame())
        layout.snapshots[1](NSImage(size: NSSize(width: 10, height: 10)))
        XCTAssertEqual(layout.prepared, ["1", "2"], "排版交给开始时选中的那一页")

        layout.prepares[0]()
        XCTAssertTrue(rig.controller.isChangingLayout, "t1 那次迟到的排版完成不结束 t2 这次")
        XCTAssertEqual(calls.list, ["记下 1", "记下 2"])
        layout.prepares[1]()
        XCTAssertFalse(rig.controller.isChangingLayout)
        XCTAssertEqual(calls.list, ["记下 1", "记下 2", "放回 2（窗口显示着它）"])
        rig.tabs.select(rig.t[0])
        XCTAssertEqual(calls.list, ["记下 1", "记下 2", "放回 2（窗口显示着它）", "放回 1（窗口显示着它）"])
        XCTAssertEqual(calls.tokens, [1, 2, 2, 1])
    }

    // MARK: - 聚焦（D5）

    /// 窗口是 key 窗口：换上来的那一页 80ms 后聚焦。切换之前给 t1 排着的聚焦作废。
    /// A → B → A（80ms 之内）：只聚焦最后换上来的 t1 一次。
    func testTheShownTabIsFocusedWhenTheWindowIsKey() async throws {
        let rig = make()
        rig.tabs.windowIsKey = { true }
        rig.tabs.focusInputSoon(for: rig.t[0])
        rig.tabs.select(rig.t[1])
        try await waitUntil { !rig.focused.isEmpty }
        try await pause(0.2)
        XCTAssertEqual(rig.focused, ["2"])

        rig.tabs.select(rig.t[0])
        rig.tabs.select(rig.t[1])
        rig.tabs.select(rig.t[0])
        try await waitUntil { rig.focused.count > 1 }
        try await pause(0.2)
        XCTAssertEqual(rig.focused, ["2", "1"])
    }

    /// 窗口不是 key 窗口：不聚焦；切换之前排着的聚焦也作废，A → B → A（80ms 之内）回到原来那一页也不再聚焦。
    func testNothingIsFocusedWhenTheWindowIsNotKey() async throws {
        let rig = make()
        rig.tabs.windowIsKey = { false }
        rig.tabs.select(rig.t[1])
        try await pause(0.3)
        XCTAssertEqual(rig.focused, [])

        rig.tabs.focusInputSoon(for: rig.t[1])
        rig.tabs.select(rig.t[0])
        rig.tabs.select(rig.t[1])
        try await pause(0.3)
        XCTAssertEqual(rig.focused, [], "切换之前排着的都作废")
    }

    // MARK: - 记下的对话地址、媒体状态

    /// 换上来的那一页的地址是可以恢复的对话就记下（它在后台换到这个地址时没记）；不是对话（新对话页）、还没有地址：不改。
    func testTheLastConversationFollowsTheShownTab() {
        let rig = make()
        rig.t[1].runtime.onURLChange?(chat)
        rig.t[2].runtime.onURLChange?(WebRuntime.homeURL)
        XCTAssertEqual(rig.saved, [], "后台换地址不记")
        rig.tabs.select(rig.t[1])
        XCTAssertEqual(rig.saved, [chat])
        rig.tabs.select(rig.t[2])
        rig.tabs.select(rig.t[0])
        XCTAssertEqual(rig.saved, [chat], "新对话页和没有地址的不改")
    }

    /// 每页和自己上次读到的媒体状态比：切换以后第一次读到的不写成“换走的那一页的状态 → 这一页的状态”。
    func testEachTabsMediaStateIsComparedWithItsOwn() async throws {
        let rig = make()
        rig.media = ["1": "playing", "2": "none"]
        let mark = rig.mark()
        rig.tabs.mediaTick()
        try await waitUntil { rig.mediaRead.count == 1 }
        rig.tabs.select(rig.t[1])
        rig.tabs.mediaTick()
        try await waitUntil { rig.mediaRead.count == 2 }
        rig.tabs.select(rig.t[0])
        rig.tabs.mediaTick()
        try await waitUntil { rig.mediaRead.count == 3 }
        rig.media["1"] = "paused"
        rig.tabs.mediaTick()
        try await waitUntil { rig.mediaRead.count == 4 }
        try await pause(0.1)
        XCTAssertEqual(rig.mediaRead, ["1", "2", "1", "1"])
        XCTAssertEqual(rig.lines(since: mark).filter { $0.hasPrefix("[media]") }, [
            "[media] WebKit 媒体状态 none → playing（窗口可见=false） 【标签1】",
            "[media] WebKit 媒体状态 playing → paused（窗口可见=false） 【标签1】",
        ])
        XCTAssertEqual(rig.diagnostics.webMediaState, "paused")
    }

    // MARK: - 换上来的那一页的状态

    /// t2 加载失败（等重试）、t3 盖着新标签页的遮挡：切换时窗口的提示和遮挡照换上来的那一页。
    /// t1 显示着结束启动画面、还在淡出时切换：淡出那层马上拿掉。
    func testTheShownTabsCoverAndNoticeAreProjectedAndARunningFadeGoes() throws {
        let rig = make()
        rig.controller.beginLaunchScreen()
        rig.t[1].runtime.load(chat)
        rig.t[1].runtime.webView(rig.t[1].runtime.webView, didFailProvisionalNavigation: nil,
                                 withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                                                    userInfo: [NSURLErrorFailingURLErrorKey: chat]))
        rig.controller.beginNewTabCover(for: rig.t[2].page)
        rig.t[0].runtime.webView(rig.t[0].runtime.webView, didCommit: nil)
        rig.t[0].runtime.webView(rig.t[0].runtime.webView, didFinish: nil)
        let fade = try XCTUnwrap(rig.controller.launchFadeView)

        rig.tabs.select(rig.t[1])
        XCTAssertNil(fade.superview, "淡出那层马上拿掉")
        XCTAssertEqual(rig.controller.shownLoadProblem, .waiting)
        XCTAssertNil(rig.controller.shownCoverKind)
        rig.tabs.select(rig.t[2])
        XCTAssertNil(rig.controller.shownLoadProblem)
        XCTAssertEqual(rig.controller.shownCoverKind, .newTab)
        rig.tabs.select(rig.t[0])
        XCTAssertNil(rig.controller.shownLoadProblem)
        XCTAssertNil(rig.controller.shownCoverKind)
    }

    // MARK: - 关闭以后释放

    /// 第四个标签页显示过（它的网页视图进了窗口）、又切换走（藏在窗口里）：关闭以后从窗口里拿出来，
    /// 标签页、运行时、页面状态和网页视图都释放。
    func testATabThatWasShownIsReleasedAfterItIsClosed() async throws {
        let rig = make()
        weak var tab: ChatTab?, page: PageLoadState?, web: WKWebView?
        autoreleasepool {
            let d = rig.add()
            tab = d
            page = d.page
            web = d.runtime.webView
            rig.tabs.select(d)
            rig.tabs.select(rig.t[0])
            XCTAssertNotNil(d.runtime.webView.superview, "藏在窗口里")
            rig.tabs.close(d)
            XCTAssertNil(d.runtime.webView.superview, "关闭时拿出来")
        }
        try await waitUntil(5) { tab == nil && page == nil && web == nil }
        XCTAssertNil(tab)
        XCTAssertNil(page)
        XCTAssertNil(web, "网页视图释放")
    }
}

/// 记下、放回、丢弃阅读位置的记录：“记下 1”“放回 1（窗口显示着它）”“丢弃 1”，和各自的编号。
@MainActor
private final class ReadingCalls {
    var list: [String] = []
    var tokens: [Int] = []
    var issued = 0
}

/// 手动送回的切模式快照和排版，记下每次排版交给的是哪个标签页。
@MainActor
private final class ManualLayout {
    var snapshots: [(NSImage?) -> Void] = []
    var prepares: [() -> Void] = []
    var prepared: [String] = []
}

/// 三个标签页、一个窗口和接线，正式运行时的建法（ChatTab.make，日志带标签）。t[0] 是启动时的那个（标签 1）。
@MainActor
private final class ThreeTabs {
    let settings: AppSettings
    let diagnostics = Diagnostics()
    let controller: ChatWindowController
    let network = NetworkStatus(startsMonitor: false)
    private(set) var tabs: ChatTabs!
    private(set) var t: [ChatTab] = []
    private(set) var focused: [String] = []
    private(set) var saved: [URL] = []
    private(set) var mediaRead: [String] = []
    /// 读网页媒体状态的替身按标签页的名字返回的状态，没写的是 none。
    var media: [String: String] = [:]

    init(defaults: UserDefaults) {
        settings = AppSettings(defaults: defaults)
        let list = TabList()
        let first = ChatTab.make(id: list.selected, diagnostics: diagnostics, settings: settings)
        first.runtime.loadRequest = { _ in }
        controller = ChatWindowController(webView: first.runtime.webView, toolbar: EmptyView(), diagnostics: diagnostics,
                                          appearance: PageAppearance(defaults: defaults), page: first.page)
        controller.pageColorSettleLimit = 60
        tabs = ChatTabs(list: list, tab: first, windowController: controller, diagnostics: diagnostics, network: network,
                        hideWindow: { _ in },
                        focusInput: { [weak self] adapter in
                            self?.focused.append(self?.name(adapter) ?? "?")
                            return "TabSelectTests"
                        },
                        saveLastConversation: { [weak self] url in self?.saved.append(url) },
                        mediaState: { [weak self] adapter in
                            let name = self?.name(adapter) ?? "?"
                            self?.mediaRead.append(name)
                            return self?.media[name] ?? "none"
                        },
                        openNewChat: { _ in true })
        tabs.wire(first)
        t = [first, add(), add()]
    }

    /// 加一个标签页（正式运行时的建法），不选中，加载请求不发出去。
    func add() -> ChatTab {
        let tab = tabs.add { ChatTab.make(id: $0, diagnostics: diagnostics, settings: settings) }!
        tab.runtime.loadRequest = { _ in }
        return tab
    }

    /// 标签页的名字：它的标签的数字。
    func name(_ adapter: ChatGPTAdapter) -> String {
        tabs.tabs.first { $0.adapter === adapter }.map(name) ?? t.first { $0.adapter === adapter }.map(name) ?? "?"
    }

    func name(_ tab: ChatTab) -> String {
        "\(tab.id.rawValue)"
    }

    func name(_ runtime: WebRuntime) -> String {
        t.first { $0.runtime === runtime }.map(name) ?? "?"
    }

    /// 现在写到第几行（之后用 lines(since:) 只看这之后的）。
    func mark() -> Int {
        diagnostics.entries.count
    }

    /// mark 之后写的日志（“[类别] 内容”），去掉跟着真实输入写的、运行时加载完成后自己异步写的 [esc]、[render]，毫秒数换成“…”。
    func lines(since mark: Int) -> [String] {
        diagnostics.entries.dropFirst(mark).filter { !LiveInputLogLines.excludes($0) }
            .map { "[\($0.category)] \($0.message)" }
            .filter { !$0.hasPrefix("[esc]") && !$0.hasPrefix("[render]") }
            .map { $0.replacingOccurrences(of: #"（\d+ms）"#, with: "（…ms）", options: .regularExpression) }
    }

    /// 把记下、放回、丢弃阅读位置换成记录。放回时记下窗口这时显示的是不是这一页的网页视图。
    func recordReadingPosition() -> ReadingCalls {
        let calls = ReadingCalls()
        tabs.holdReadingPosition = { [weak self] runtime in
            calls.issued += 1
            calls.list.append("记下 \(self?.name(runtime) ?? "?")")
            calls.tokens.append(calls.issued)
            return calls.issued
        }
        tabs.restoreReadingPosition = { [weak self] runtime, token, _ in
            let shown = self?.controller.webView === runtime.webView
            calls.list.append("放回 \(self?.name(runtime) ?? "?")" + (shown ? "（窗口显示着它）" : "（窗口没显示它）"))
            calls.tokens.append(token)
        }
        tabs.discardReadingPosition = { [weak self] runtime, token in
            calls.list.append("丢弃 \(self?.name(runtime) ?? "?")")
            calls.tokens.append(token)
        }
        return calls
    }

    /// 切模式的快照和排版换成手动送回（排版交给开始时选中的那一页，和 ChatTabs 接的一样，只记下是哪一页）。
    /// 排版前后的回调还是 ChatTabs 接的（记下、放回阅读位置）。
    func manualLayout() -> ManualLayout {
        let layout = ManualLayout()
        controller.onSnapshotPage = { done in layout.snapshots.append(done) }
        controller.onPrepareLayout = { [weak self] _, done in
            guard let self else { return }
            layout.prepared.append(self.name(self.tabs.selected))
            layout.prepares.append(done)
        }
        return layout
    }

    /// 比现在的窗口大一些的位置（切模式的目标）。
    func biggerFrame() -> NSRect {
        var frame = controller.window!.frame
        frame.size.width += 100
        frame.size.height += 60
        return frame
    }
}
