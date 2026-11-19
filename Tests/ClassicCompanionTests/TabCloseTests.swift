import AppKit
import Combine
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 关闭标签页的收尾（ChatTabs.close(_:)）。两个标签页：B 是启动时的那个，选中、窗口显示着；A 由 ChatTabs.add 加进来，从不显示。
/// 关的是 A（不选中的；关选中的要先切换，切换入口以后做）。核对：
/// - 收尾的每一步：运行时和页面状态进入关闭态、排着的聚焦取消、列表和 tabs 一起拿掉、从网络状态去掉、回调断开；
/// - 关闭以后 A 不再加载：定时重试、网络变化、窗口显示后都不加载；
/// - A 晚到的失败、提交、加载完成、提示、地址变化（经运行时，或经关闭前就拿到的回调，或直接带 A 的页面交给窗口）
///   和 A 排着的提交后兜底，都不改 A 的状态、不改 B、不动窗口；
/// - 关两遍、关不在这组里的标签页都安全；
/// - 关闭以后（进行中的新对话那一步返回以后）标签页、运行时、页面状态和网页视图都释放；
/// - B 的状态和回调不受影响：和没关过 A 的一组逐步比较，一样。
///
/// 真的 ChatWindowController（不显示窗口）和真的 WebRuntime（不看网络，加载请求各自记下来），导航事件像 LoadRecoveryWebTests 一样
/// 直接调运行时的导航代理。AppDelegate 交进来的几样换成记录（只记名字，不持有适配器，免得拦住释放）。
/// A 的运行时写的日志记在 A 自己的 Diagnostics 里，共用的 diagnostics 里只有窗口、ChatTabs 和 B 的运行时写的。
@MainActor
final class TabCloseTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!
    private let other = URL(string: "https://chatgpt.com/c/def")!
    private let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    private func makeRig(backoffA: [TimeInterval] = [60]) -> ClosingTabs {
        let name = "TabCloseTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = ClosingTabs(defaults: UserDefaults(suiteName: name)!, backoffA: backoffA)
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

    /// 窗口、显示着的 B、共用的日志和替身的记录都和 before 一样。
    private func assertUntouched(_ rig: ClosingTabs, _ before: ClosingTabs.Snapshot, _ step: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let now = rig.snapshot()
        XCTAssertEqual(now.window, before.window, "\(step)：窗口", file: file, line: line)
        XCTAssertEqual(now.displayed, before.displayed, "\(step)：显示着的 B", file: file, line: line)
        XCTAssertEqual(now.lines, before.lines, "\(step)：窗口的日志", file: file, line: line)
        XCTAssertEqual(now.calls, before.calls, "\(step)：隐藏、聚焦、记下地址、读媒体状态、新对话", file: file, line: line)
    }

    // MARK: - 收尾的每一步

    /// 关 A：A 的运行时和页面状态都是关闭的，排着的聚焦任务取消了，列表和 tabs 里一起没了（选中项还是 B，不记最近关闭），
    /// 网络状态上只剩 B，A 的回调都断开了。B 一样不少；窗口和 ChatTabs 不写日志，A 的运行时写一行。
    func testClosingABackgroundTabTearsDownEachPart() throws {
        let rig = makeRig()
        let a = rig.a, b = rig.b
        rig.tabs.focusInputSoon(for: a)
        let focus = try XCTUnwrap(a.focusTask)
        XCTAssertEqual(rig.network.registeredCount, 2)
        let before = rig.snapshot(), markA = rig.diagnosticsA.entries.count

        rig.tabs.close(a)
        XCTAssertTrue(a.runtime.isClosed)
        XCTAssertTrue(a.page.isClosed)
        XCTAssertTrue(focus.isCancelled, "排着的聚焦取消了")
        XCTAssertNil(a.focusTask)
        XCTAssertFalse(rig.tabs.holds(a))
        XCTAssertEqual(rig.tabs.list.tabs, [b.id])
        XCTAssertEqual(rig.tabs.tabs.map(\.id), rig.tabs.list.tabs, "列表和 tabs 一起改")
        XCTAssertTrue(rig.tabs.selected === b)
        XCTAssertTrue(rig.tabs.list.recentlyClosed.isEmpty, "不记入最近关闭")
        XCTAssertEqual(rig.network.registeredCount, 1, "从网络状态上去掉")
        XCTAssertNil(a.runtime.onURLChange)
        XCTAssertNil(a.runtime.onMainFrameLoaded)
        XCTAssertNil(a.runtime.onMainFrameCommitted)
        XCTAssertNil(a.runtime.onLoadFailed)
        XCTAssertNil(a.runtime.onEscapeRequest)
        XCTAssertNil(a.runtime.onLoadProblemChange)

        XCTAssertFalse(b.runtime.isClosed)
        XCTAssertFalse(b.page.isClosed)
        XCTAssertNotNil(b.runtime.onURLChange, "B 的接线还在")
        XCTAssertNotNil(b.runtime.onMainFrameLoaded)
        XCTAssertNotNil(b.runtime.onLoadProblemChange)
        assertUntouched(rig, before, "关 A")
        XCTAssertEqual(rig.lines(rig.diagnosticsA, since: markA), ["[web] 关闭网页：停止加载"])
    }

    // MARK: - 关闭以后不再加载

    /// A、B 第一次加载都失败了（在线），都在等自动重试（A 0.1 秒后）。关 A，之后断网又恢复、窗口唤醒：
    /// A 不再加载（定时器、网络恢复、唤醒都不），也不再写日志；B 照常：网络恢复时重试，唤醒时聚焦 B。
    func testAClosedTabStartsNoLoadFromItsRetryTheNetworkOrAWake() async throws {
        let rig = makeRig(backoffA: [0.1, 0.1])
        rig.network.deliver(online: true)
        let a = rig.a
        a.runtime.load(chat)
        rig.fail(a.runtime)
        rig.b.runtime.load(chat)
        rig.fail(rig.b.runtime)
        XCTAssertTrue(a.runtime.hasScheduledRetry)
        let markA = rig.diagnosticsA.entries.count
        rig.tabs.close(a)
        rig.network.deliver(online: false)
        rig.network.deliver(online: true)
        rig.controller.onDidShow?(.wake)
        try await waitUntil { !rig.focused.isEmpty }
        try await pause(0.4)
        XCTAssertEqual(rig.loadedA, [chat], "A 关闭以后不再加载")
        XCTAssertEqual(rig.lines(rig.diagnosticsA, since: markA), ["[web] 关闭网页：停止加载，取消排着的自动重试"])
        XCTAssertEqual(a.page.notice, .waiting, "A 的提示停在关闭时")
        XCTAssertEqual(rig.loadedB, [chat, chat], "B 照常：网络恢复时重试一次（唤醒时已经在连接，不再发）")
        XCTAssertEqual(rig.netLog(rig.diagnostics), ["网络不可用", "网络可用"])
        XCTAssertEqual(rig.focused, ["B"])
    }

    // MARK: - 晚到的事件

    /// B 的启动画面还在（启动保护中，下面盖着“正在连接”）。A 加载失败、重新加载、提交（提示留到加载完成，排着提交后兜底）之后关闭。
    /// 之后 A 的事件晚到，三条路：经 A 的运行时（导航代理）；经关闭前拿到的回调（例如已经在路上的）；直接带 A 的页面交给窗口。
    /// 失败、提交、加载完成、提示变化、地址变化、Esc 都不改 A 的状态和路径，B 和窗口一点不变；A 的兜底到点也什么都不做。
    func testLateEventsOfAClosedTabChangeNothing() async throws {
        let rig = makeRig()
        rig.controller.pageRevealLimit = 0.3
        rig.tabs.windowIsKey = { true }
        rig.controller.beginLaunchScreen()
        rig.b.runtime.onLoadProblemChange?(.connecting)
        let a = rig.a
        a.runtime.load(chat)
        rig.fail(a.runtime)
        a.runtime.reload()
        rig.commit(a.runtime)
        XCTAssertEqual(PageFields(a.page), PageFields(committed: true, awaiting: true, generation: 1, notice: .connecting, held: true))
        let loaded = a.runtime.onMainFrameLoaded, failed = a.runtime.onLoadFailed, problem = a.runtime.onLoadProblemChange
        let committed = a.runtime.onMainFrameCommitted, urlChanged = a.runtime.onURLChange, escape = a.runtime.onEscapeRequest
        let aBefore = PageFields(a.page), before = rig.snapshot(), markA = rig.diagnosticsA.entries.count

        rig.tabs.close(a)
        rig.fail(a.runtime)
        rig.commit(a.runtime)
        rig.finish(a.runtime)
        loaded?()
        failed?()
        problem?(.waiting)
        committed?()
        urlChanged?(other)
        escape?()
        rig.controller.pageDidCommit(a.page)
        rig.controller.showLoadProblem(.stopped, for: a.page)
        rig.controller.pageDidFinishLoading(a.page, reportedColor: white)
        rig.controller.endLaunchScreen("加载失败", for: a.page)
        XCTAssertEqual(PageFields(a.page), aBefore, "A 的状态停在关闭时")
        XCTAssertNil(a.lastPath, "A 的路径不变")
        XCTAssertEqual(a.adapter.generation, 0)
        assertUntouched(rig, before, "A 的事件晚到")
        try await pause(0.6)
        XCTAssertEqual(PageFields(a.page), aBefore, "A 的兜底到点也不改 A")
        assertUntouched(rig, before, "A 的兜底到点后")
        XCTAssertTrue(rig.controller.isShowingLaunchScreen)
        XCTAssertEqual(rig.loadedA, [chat, chat])
        XCTAssertEqual(rig.lines(rig.diagnosticsA, since: markA), ["[web] 关闭网页：停止加载"])
    }

    // MARK: - 关两遍、关不在这组里的

    /// 关两遍：第二遍什么都不做（列表、网络登记、日志都不变）。关一个不在这组里的标签页：什么都不做，连它的运行时也不关。
    func testClosingTwiceOrClosingATabNotInTheGroupIsHarmless() {
        let rig = makeRig()
        let a = rig.a
        rig.tabs.close(a)
        let list = rig.tabs.list, before = rig.snapshot(), countA = rig.diagnosticsA.entries.count
        rig.tabs.close(a)
        XCTAssertEqual(rig.tabs.list, list)
        XCTAssertEqual(rig.network.registeredCount, 1)
        XCTAssertEqual(rig.diagnosticsA.entries.count, countA)
        assertUntouched(rig, before, "关两遍")

        let stranger = ChatTab(id: TabList().selected, runtime: WebRuntime(diagnostics: Diagnostics(), settings: rig.settings,
                                                                           watchesNetwork: false),
                               adapter: ChatGPTAdapter(webView: WKWebView(), diagnostics: Diagnostics(), settings: rig.settings))
        rig.tabs.close(stranger)
        XCTAssertFalse(stranger.runtime.isClosed)
        XCTAssertFalse(stranger.page.isClosed)
        XCTAssertEqual(rig.tabs.list, list)
        assertUntouched(rig, before, "关不在这组里的")
    }

    // MARK: - 释放

    /// C（运行时、适配器都由这一组建，测试只弱引用）第一次加载失败、排着定时重试，排着聚焦，换过两次页面（排着 0.8 秒的媒体日志）。
    /// 关 C 以后这组不再持有它：标签页、运行时、适配器、页面状态和网页视图都释放；B 照常。
    func testAClosedTabAndItsWebViewAreReleased() async throws {
        let rig = makeRig()
        weak var tab: ChatTab?, runtime: WebRuntime?, adapter: ChatGPTAdapter?, page: PageLoadState?, web: WKWebView?
        autoreleasepool {
            let c = rig.addC(backoff: [0.2])
            tab = c
            runtime = c.runtime
            adapter = c.adapter
            page = c.page
            web = c.runtime.webView
            c.runtime.load(chat)
            rig.fail(c.runtime)
            XCTAssertTrue(c.runtime.hasScheduledRetry)
            rig.tabs.focusInputSoon(for: c)
            c.runtime.onURLChange?(chat)
            c.runtime.onURLChange?(other)
            rig.tabs.close(c)
        }
        try await waitUntil(5) { tab == nil && runtime == nil && adapter == nil && page == nil && web == nil }
        XCTAssertNil(tab, "标签页释放")
        XCTAssertNil(runtime, "运行时释放")
        XCTAssertNil(adapter, "适配器释放")
        XCTAssertNil(page, "页面状态释放")
        XCTAssertNil(web, "网页视图释放")
        try await pause(0.9)
        XCTAssertEqual(rig.loadedC, [chat], "关闭以后定时重试不加载")
        XCTAssertTrue(rig.focused.isEmpty)
        XCTAssertTrue(rig.mediaRead.isEmpty, "关闭以后不记媒体状态")
        XCTAssertEqual(rig.tabs.tabs.map(\.id), [rig.b.id, rig.a.id])
    }

    /// C 选中时按新对话，页面里的入口还在等（拿着 C）时选中 B、关 C。等的那一步返回以后：没点到也不整页加载 C，
    /// 点到了也不聚焦（谁都不聚焦）；之后 C 和它的网页视图释放。
    func testAnInFlightNewChatOfAClosedTabNeitherLoadsNorFocusesAndThenLetsItGo() async throws {
        for inPage in [false, true] {
            let rig = makeRig()
            rig.newChatInPage = inPage
            rig.newChatDelay = 0.2
            weak var tab: ChatTab?, web: WKWebView?
            autoreleasepool {
                let c = rig.addC()
                tab = c
                web = c.runtime.webView
                rig.tabs.selectForTesting(c)
            }
            rig.tabs.newChat()
            try await waitUntil { !rig.newChatAsked.isEmpty }
            XCTAssertEqual(rig.newChatAsked, ["C"])
            autoreleasepool {
                rig.tabs.selectForTesting(rig.b)
                if let tab { rig.tabs.close(tab) }
            }
            XCTAssertNotNil(tab, "页面里的入口还拿着 C（点到了=\(inPage)）")
            try await waitUntil { tab == nil && web == nil }
            XCTAssertNil(tab, "那一步返回以后 C 释放（点到了=\(inPage)）")
            XCTAssertNil(web)
            try await pause(0.2)
            XCTAssertEqual(rig.loadedC, [], "不整页加载（点到了=\(inPage)）")
            XCTAssertTrue(rig.focused.isEmpty, "谁都不聚焦（点到了=\(inPage)）")
            XCTAssertEqual(rig.loadedB, [])
        }
    }

    // MARK: - 另一个标签页不受影响

    /// 两组：一组先关掉 A，另一组不关（对照）。之后给 B 送同样一串事件（加载、失败、断网又恢复时重试、提交、加载完成、
    /// 换到对话地址、Esc、加载完成后聚焦），每一步之后两组的 B、窗口、窗口的日志和替身的记录都一样。
    func testTheOtherTabBehavesExactlyAsIfNothingWasClosed() async throws {
        let rig = makeRig(), control = makeRig()
        for r in [rig, control] { r.tabs.windowIsKey = { true } }
        rig.tabs.close(rig.a)
        func step(_ name: String, file: StaticString = #filePath, line: UInt = #line, _ event: (ClosingTabs) -> Void) {
            event(rig)
            event(control)
            let now = rig.snapshot(), expected = control.snapshot()
            XCTAssertEqual(now.window, expected.window, "\(name)：窗口", file: file, line: line)
            XCTAssertEqual(now.displayed, expected.displayed, "\(name)：B", file: file, line: line)
            XCTAssertEqual(now.lines, expected.lines, "\(name)：窗口的日志", file: file, line: line)
            XCTAssertEqual(now.calls, expected.calls, "\(name)：替身", file: file, line: line)
            XCTAssertEqual(rig.loadedB, control.loadedB, "\(name)：B 的加载", file: file, line: line)
        }
        step("开始启动画面") { $0.controller.beginLaunchScreen() }
        step("加载") { $0.b.runtime.load(self.chat) }
        step("失败") { $0.fail($0.b.runtime) }
        step("断网") { $0.network.deliver(online: false) }
        step("网络恢复，重试") { $0.network.deliver(online: true) }
        XCTAssertEqual(rig.loadedB, [chat, chat])
        step("提交") { $0.commit($0.b.runtime) }
        step("加载完成") { $0.finish($0.b.runtime) }
        XCTAssertFalse(rig.controller.isShowingLaunchScreen)
        step("换到对话地址") { $0.b.runtime.onURLChange?(self.chat) }
        step("Esc") { $0.b.runtime.onEscapeRequest?() }
        try await waitUntil { rig.focused.count == 1 && control.focused.count == 1 }
        try await pause(0.2)
        step("加载完成后聚焦") { _ in }
        XCTAssertEqual(rig.focused, ["B"])
        XCTAssertEqual(rig.saved, [chat])
        XCTAssertEqual(rig.hidden, ["网页 Esc"])
    }
}

/// 一个页面的全部状态，逐项比较。
private struct PageFields: Equatable, CustomStringConvertible {
    var committed = false
    var awaiting = false
    var generation = 0
    var notice: LoadRecovery.Status = .hidden
    var held = false
    var holds = false
    var colorBefore = "nil"
    var finished = false
    var finishColor = "nil"

    init(committed: Bool = false, awaiting: Bool = false, generation: Int = 0, notice: LoadRecovery.Status = .hidden,
         held: Bool = false, holds: Bool = false, colorBefore: String = "nil", finished: Bool = false, finishColor: String = "nil") {
        self.committed = committed
        self.awaiting = awaiting
        self.generation = generation
        self.notice = notice
        self.held = held
        self.holds = holds
        self.colorBefore = colorBefore
        self.finished = finished
        self.finishColor = finishColor
    }

    @MainActor init(_ p: PageLoadState) {
        self.init(committed: p.hasCommittedPage, awaiting: p.awaitingFinish, generation: p.commitGeneration, notice: p.notice,
                  held: p.noticeAwaitsLoad, holds: p.holdsPageColor, colorBefore: ClosingTabs.rgb(p.colorBeforeFirstLoad),
                  finished: p.hasFinishedFirstLoad, finishColor: ClosingTabs.rgb(p.colorAtLastFinish))
    }

    var description: String {
        "提交=\(committed) 等加载完成=\(awaiting) 代号=\(generation) 提示=\(notice) 留着=\(held) 启动保护=\(holds) "
            + "加载完成前的颜色=\(colorBefore) 第一次加载已完成=\(finished) 加载完成时的颜色=\(finishColor)"
    }
}

/// 两个标签页、一个窗口和接线，和 TabEventOwnershipTests 的 TwoTabs 一样建：B 是启动时的那个（列表、标签页、窗口、ChatTabs、wire），
/// A 之后由 ChatTabs.add 加进来。A 的运行时和适配器另外留着（runtimeA），关闭以后还能给它送晚到的事件。
/// addC 再加一个 C：它的运行时和适配器在 add 的闭包里建，这里不持有，用来核对释放。
/// AppDelegate 交给 ChatTabs 的几样换成记录：只记名字（A、B、C），不持有适配器。
@MainActor
private final class ClosingTabs {
    static let dark = NSColor(srgbRed: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x0E / 255.0, alpha: 1)
    static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    let settings: AppSettings
    /// 窗口、ChatTabs 和 B 的运行时写的日志。
    let diagnostics = Diagnostics()
    /// A 的运行时和适配器自己写的日志。
    let diagnosticsA = Diagnostics()
    /// C 的运行时和适配器自己写的日志。
    let diagnosticsC = Diagnostics()
    let appearance: PageAppearance
    let b: ChatTab
    let runtimeA: WebRuntime
    let adapterA: ChatGPTAdapter
    private weak var addedA: ChatTab?
    let controller: ChatWindowController
    private(set) var tabs: ChatTabs!
    let network = NetworkStatus(startsMonitor: false)
    /// 共用的日志（“[类别] 内容”）和替身的调用，按发生的顺序。
    private var timeline: [String] = []
    private(set) var loadedA: [URL] = []
    private(set) var loadedB: [URL] = []
    private(set) var loadedC: [URL] = []
    private(set) var hidden: [String] = []
    private(set) var focused: [String] = []
    private(set) var saved: [URL] = []
    private(set) var mediaRead: [String] = []
    private(set) var newChatAsked: [String] = []
    var newChatInPage = false
    var newChatDelay: Double = 0
    /// C 的适配器（不持有）。
    private weak var adapterC: ChatGPTAdapter?
    private var watch: AnyCancellable?

    init(defaults: UserDefaults, backoffA: [TimeInterval]) {
        settings = AppSettings(defaults: defaults)
        appearance = PageAppearance(defaults: defaults)
        let runtimeB = WebRuntime(diagnostics: diagnostics, settings: settings, recovery: LoadRecovery(backoff: [60]),
                                  watchesNetwork: false)
        runtimeB.webView.underPageBackgroundColor = Self.dark
        let adapterB = ChatGPTAdapter(webView: runtimeB.webView, diagnostics: diagnostics, settings: settings)
        let list = TabList()
        b = ChatTab(id: list.selected, runtime: runtimeB, adapter: adapterB)
        controller = ChatWindowController(webView: runtimeB.webView, toolbar: EmptyView(), diagnostics: diagnostics,
                                          appearance: appearance, page: b.page)
        // 解除启动保护后等颜色变化的时限放长：它到点写的日志不在这些测试的时间线里。
        controller.pageColorSettleLimit = 60
        runtimeA = WebRuntime(diagnostics: diagnosticsA, settings: settings, recovery: LoadRecovery(backoff: backoffA),
                              watchesNetwork: false)
        runtimeA.webView.underPageBackgroundColor = Self.white
        adapterA = ChatGPTAdapter(webView: runtimeA.webView, diagnostics: diagnosticsA, settings: settings)
        runtimeB.loadRequest = { [weak self] request in self?.loadedB.append(request.url!) }
        runtimeA.loadRequest = { [weak self] request in self?.loadedA.append(request.url!) }
        tabs = ChatTabs(list: list, tab: b, windowController: controller, diagnostics: diagnostics,
                        network: network,
                        hideWindow: { [weak self] reason in
                            self?.hidden.append(reason)
                            self?.timeline.append("隐藏窗口：\(reason)")
                        },
                        focusInput: { [weak self] adapter in
                            let name = self?.name(adapter) ?? "?"
                            self?.focused.append(name)
                            self?.timeline.append("聚焦输入框 \(name)")
                            return "TabCloseTests"
                        },
                        saveLastConversation: { [weak self] url in
                            self?.saved.append(url)
                            self?.timeline.append("记下对话地址 \(url.absoluteString)")
                        },
                        mediaState: { [weak self] adapter in
                            let name = self?.name(adapter) ?? "?"
                            self?.mediaRead.append(name)
                            self?.timeline.append("读网页媒体状态 \(name)")
                            return "媒体\(name)"
                        },
                        openNewChat: { [weak self] adapter in
                            let name = self?.name(adapter) ?? "?"
                            self?.newChatAsked.append(name)
                            self?.timeline.append("页面里新对话 \(name)")
                            if let delay = self?.newChatDelay, delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
                            return self?.newChatInPage ?? false
                        })
        watch = diagnostics.$entries.dropFirst().sink { [weak self] entries in
            guard let self, let entry = entries.last, !LiveInputLogLines.excludes(entry) else { return }
            self.timeline.append("[\(entry.category)] \(entry.message)")
        }
        tabs.wire(b)
        addedA = tabs.add(runtime: runtimeA, adapter: adapterA)
    }

    /// 加进来的 A。关闭后这一组不再持有它：要用的测试先自己拿住。
    var a: ChatTab { addedA! }

    /// 再加一个标签页 C（不选中、接好线、登记网络）。运行时和适配器在这里建，这一组不持有它们。
    func addC(backoff: [TimeInterval] = [60]) -> ChatTab {
        tabs.add { id in
            let runtime = WebRuntime(diagnostics: diagnosticsC, settings: settings, recovery: LoadRecovery(backoff: backoff),
                                     watchesNetwork: false)
            runtime.loadRequest = { [weak self] request in self?.loadedC.append(request.url!) }
            let adapter = ChatGPTAdapter(webView: runtime.webView, diagnostics: diagnosticsC, settings: settings)
            adapterC = adapter
            return ChatTab(id: id, runtime: runtime, adapter: adapter)
        }!
    }

    func name(_ adapter: ChatGPTAdapter) -> String {
        adapter === b.adapter ? "B" : adapter === adapterA ? "A" : adapter === adapterC ? "C" : "?"
    }

    func netLog(_ diagnostics: Diagnostics) -> [String] {
        diagnostics.entries.filter { $0.category == "net" }.map(\.message)
    }

    /// diagnostics 里第 mark 条之后的日志（“[类别] 内容”）。
    func lines(_ diagnostics: Diagnostics, since mark: Int) -> [String] {
        diagnostics.entries.dropFirst(mark).map { "[\($0.category)] \($0.message)" }
    }

    // MARK: 运行时的导航代理，和 LoadRecoveryWebTests 一样直接调

    func fail(_ runtime: WebRuntime, _ url: URL = URL(string: "https://chatgpt.com/c/abc")!) {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                            userInfo: [NSURLErrorFailingURLErrorKey: url])
        runtime.webView(runtime.webView, didFailProvisionalNavigation: nil, withError: error)
    }

    func commit(_ runtime: WebRuntime) {
        runtime.webView(runtime.webView, didCommit: nil)
    }

    func finish(_ runtime: WebRuntime) {
        runtime.webView(runtime.webView, didFinish: nil)
    }

    // MARK: 看得见的

    /// 时间线，启动画面结束的毫秒数换成“…”。去掉 B 的运行时加载完成后自己异步写的 [esc]、[render]，它们不归接线管。
    var lines: [String] {
        timeline.filter { !$0.hasPrefix("[esc]") && !$0.hasPrefix("[render]") }
            .map { $0.replacingOccurrences(of: #"（\d+ms）"#, with: "（…ms）", options: .regularExpression) }
    }

    /// 提示那一层：内容视图里第一个 LoadProblemView（初始化时加的；淡出那层加在它上面，排在后面）。
    var noticeCover: NSHostingView<LoadProblemView> {
        controller.window!.contentView!.subviews.compactMap { $0 as? NSHostingView<LoadProblemView> }.first!
    }

    /// 窗口上看得见的：启动画面、启动保护、提示（状态、那一层、内容、有没有淡出那层）、颜色，和窗口认作显示着的页面。
    /// 淡出那两层只看有没有（两组的对象不同）。
    var window: String {
        let cover = noticeCover
        return "启动画面=\(controller.isShowingLaunchScreen) 启动画面淡出=\(controller.launchFadeView != nil) "
            + "启动保护=\(controller.isHoldingPageColor) 提示=\(controller.shownLoadProblem.map { "\($0)" } ?? "无") "
            + "提示那层藏着=\(cover.isHidden) 内容=\(cover.rootView.model.status) "
            + "提示淡出=\(controller.loadProblemFadeView != nil) 页面颜色=\(Self.rgb(appearance.background)) "
            + "顶部外观=\(controller.chromeAppearance?.name.rawValue ?? "nil") 窗口底色=\(Self.rgb(controller.window?.backgroundColor)) "
            + "显示着=\(controller.page === b.page ? "B" : "不是 B")"
    }

    struct Snapshot {
        let window: String
        let displayed: PageFields
        let lines: [String]
        let calls: String
    }

    func snapshot() -> Snapshot {
        Snapshot(window: window, displayed: PageFields(b.page), lines: lines,
                 calls: "隐藏=\(hidden) 聚焦=\(focused) 记下=\(saved) 读媒体=\(mediaRead) 新对话=\(newChatAsked)")
    }

    static func rgb(_ color: NSColor?) -> String {
        guard let color else { return "nil" }
        guard let c = color.usingColorSpace(.sRGB) else { return color.description }
        return String(format: "(%.3f, %.3f, %.3f, a %.2f)", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }
}
