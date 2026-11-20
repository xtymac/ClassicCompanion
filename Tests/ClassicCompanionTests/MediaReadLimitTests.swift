import AppKit
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// WebKit 的媒体请求（读媒体状态、全部暂停、全部挂起）有时限，关闭时不再等（ChatGPTAdapter.mediaRequest(_:)）。
/// WebKit 换成替身（sendMediaRequest）：记下请求和回答用的回调，不回答，或由测试在之后回答。
/// 单独的适配器的网页视图不放进窗口；标签页的几条用 TabCloseRig（它的窗口从不显示）。不联网。
/// 分两件事核对：
/// (a) 调用方在时限内拿到结果或 "timeout"；读状态的请求在 WebKit 那里只有一个在等，每秒读一次不叠着读
///     （ChatTabs.mediaTick 每个标签页一次只读一个）；回答迟到不出事，之后照常读。
/// (b) WebKit 一直不回答时关闭标签页：标签页、运行时、适配器、页面状态和网页视图马上释放（不等时限），这时测试还拿着
///     WebKit 的回调——回调不拿着它们；回调之后才调用什么都不做。每秒的读、页面变化后 0.8 秒的读、挂起和暂停实验都一样。
///     渲染自检的脚本回调也只弱引用运行时：网页一直忙、脚本不回来，关闭的运行时照样释放。
/// 网页真的会不会不回答、关闭后还有没有声音，这里看不到。
@MainActor
final class MediaReadLimitTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!
    private let other = URL(string: "https://chatgpt.com/c/def")!

    private func make() -> TabCloseRig {
        let name = "MediaReadLimitTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabCloseRig(defaults: UserDefaults(suiteName: name)!)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        return rig
    }

    private func settings() -> AppSettings {
        let name = "MediaReadLimitTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return AppSettings(defaults: UserDefaults(suiteName: name)!)
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(max(0, Int(seconds * 1000))))
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await pause(0.01) }
    }

    /// 一个单独的适配器（不带标签），网页视图不放进窗口；WebKit 换成 held。
    private func makeAdapter(_ held: HeldMediaRequests, timeout: TimeInterval) -> (ChatGPTAdapter, WKWebView, Diagnostics) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let diagnostics = Diagnostics()
        let adapter = ChatGPTAdapter(webView: web, diagnostics: diagnostics, settings: settings())
        held.install(on: adapter)
        adapter.mediaTimeout = timeout
        return (adapter, web, diagnostics)
    }

    private func lines(_ diagnostics: Diagnostics) -> [String] {
        diagnostics.entries.map { "[\($0.category)] \($0.message)" }
    }

    // MARK: - (a) 时限，不叠着读

    /// WebKit 不回答：同时读三次，只交给 WebKit 一次；三次都在时限（0.2 秒）后不久拿到 "timeout"，不写日志。
    /// 回答迟到：什么都不做；之后再读交一次新的，WebKit 回答就拿到它。
    func testAReadWebKitNeverAnswersEndsAsTimedOutAndReadsDoNotStack() async throws {
        let held = HeldMediaRequests()
        let (adapter, web, diagnostics) = makeAdapter(held, timeout: 0.2)
        let started = Date()
        let reads = (0..<3).map { _ in Task { await adapter.webMediaState() } }
        var results: [String] = []
        for read in reads { results.append(await read.value) }
        let waited = Date().timeIntervalSince(started)
        XCTAssertEqual(results, ["timeout", "timeout", "timeout"])
        XCTAssertGreaterThanOrEqual(waited, 0.19)
        XCTAssertLessThan(waited, 1.0, "时限 0.2 秒")
        XCTAssertEqual(held.requests, [.state], "只交给 WebKit 一次")
        XCTAssertEqual(adapter.pendingMediaRequests, 0)
        XCTAssertEqual(lines(diagnostics), [])

        held.answer(0, .playing)
        XCTAssertEqual(adapter.pendingMediaRequests, 0)
        let next = Task { await adapter.webMediaState() }
        try await waitUntil { held.requests.count == 2 }
        XCTAssertEqual(held.requests, [.state, .state], "迟到的回答之后，再读交一次新的")
        held.answer(1, .paused)
        let answered = await next.value
        XCTAssertEqual(answered, "paused")
        XCTAssertEqual(lines(diagnostics), [])
        withExtendedLifetime(web) {}
    }

    /// 全部暂停、挂起：WebKit 不回答，时限到返回 "timeout"，写一行（没有地址）；迟到的回答不再写。WebKit 回答的返回 "ok"。
    /// 关闭以后不交给 WebKit，马上返回 "closed"。
    func testPauseAndSuspendHaveTheSameLimit() async throws {
        let held = HeldMediaRequests()
        let (adapter, web, diagnostics) = makeAdapter(held, timeout: 0.2)
        let started = Date()
        let paused = await adapter.pauseAllMediaPlayback()
        XCTAssertEqual(paused, "timeout")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(lines(diagnostics), ["[adapter] WebKit 全部暂停没有在 0.2 秒内回答，不再等"])
        held.answer(0, nil)
        XCTAssertEqual(lines(diagnostics).count, 1, "迟到的回答不写")

        let suspend = Task { await adapter.setAllMediaPlaybackSuspended(true) }
        try await waitUntil { held.requests.count == 2 }
        held.answer(1, nil)
        let suspended = await suspend.value
        XCTAssertEqual(suspended, "ok")
        XCTAssertEqual(held.requests, [.pauseAll, .suspendAll(true)])

        adapter.close()
        let afterClose = await adapter.setAllMediaPlaybackSuspended(false)
        let stateAfterClose = await adapter.webMediaState()
        XCTAssertEqual(afterClose, "closed")
        XCTAssertEqual(stateAfterClose, "closed")
        XCTAssertEqual(held.requests.count, 2, "关闭以后不交给 WebKit")
        withExtendedLifetime(web) {}
    }

    /// 等着的时候关闭（时限放到 60 秒）：读状态、暂停都马上返回 "closed"，不等时限、不写日志；之后的回答什么都不做。
    func testClosingEndsTheWaitAtOnce() async throws {
        let held = HeldMediaRequests()
        let (adapter, web, diagnostics) = makeAdapter(held, timeout: 60)
        let read = Task { await adapter.webMediaState() }
        let pause = Task { await adapter.pauseAllMediaPlayback() }
        try await waitUntil { held.requests.count == 2 }
        XCTAssertEqual(adapter.pendingMediaRequests, 2)
        let closedAt = Date()
        adapter.close()
        let readResult = await read.value
        let pauseResult = await pause.value
        XCTAssertEqual(readResult, "closed")
        XCTAssertEqual(pauseResult, "closed")
        XCTAssertLessThan(Date().timeIntervalSince(closedAt), 0.5)
        XCTAssertEqual(adapter.pendingMediaRequests, 0)
        held.answer(0, .playing)
        held.answer(1, nil)
        XCTAssertEqual(lines(diagnostics), [])
        withExtendedLifetime(web) {}
    }

    /// 每秒读（正式的适配器，和 AppDelegate 一样）：WebKit 不回答时连着到点 5 次，只读一次、只交给 WebKit 一次；
    /// 时限（0.3 秒）到了显示 "timeout"，写一行。之后到点再读一次：不再交给 WebKit（等着的那一个还没回答），
    /// WebKit 回答时拿到它的回答。
    func testTheTickDoesNotStackReadsWhenWebKitDoesNotAnswer() async throws {
        let rig = make()
        rig.realAdapter = true
        let held = HeldMediaRequests()
        held.install(on: rig.first.adapter)
        rig.first.adapter.mediaTimeout = 0.3
        let mark = rig.mark()
        let started = Date()
        for _ in 0..<5 { rig.tabs.mediaTick() }
        try await pause(0.1)
        XCTAssertEqual(rig.mediaRead, ["1"], "上一次还没读完，到点的不再读")
        XCTAssertEqual(held.requests, [.state])
        try await waitUntil { rig.diagnostics.webMediaState == "timeout" }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(rig.lines(since: mark), ["读媒体 1", "[media] WebKit 媒体状态 none → timeout（窗口可见=false） 【标签1】"])

        rig.tabs.mediaTick()
        try await waitUntil { rig.mediaRead.count == 2 }
        try await pause(0.05)
        XCTAssertEqual(held.requests, [.state], "等着的那一个还没回答，不再交")
        held.answer(0, .playing)
        try await waitUntil { rig.diagnostics.webMediaState == "playing" }
        XCTAssertEqual(rig.lines(since: mark).last, "[media] WebKit 媒体状态 timeout → playing（窗口可见=false） 【标签1】")
        rig.tabs.mediaTick()
        try await waitUntil { held.requests.count == 2 }
        XCTAssertEqual(rig.mediaRead.count, 3, "读完就放开，下一次照常读")
        held.answer(1, .playing)
        try await waitUntil { !rig.first.mediaReadInFlight }
    }

    // MARK: - (b) 关闭以后释放，WebKit 不回答也一样

    /// 选中的 2 正在等 WebKit（不回答，时限 60 秒）时关闭 2：每秒的读、页面变化后 0.8 秒的读、挂起实验、暂停实验，
    /// 都经适配器交给 WebKit（交的是哪一个请求），都在关闭后马上释放（测试这时还拿着 WebKit 的回调）；
    /// 回调之后才调用：不写诊断、不写日志。两种实验在关闭时写一行“没有做完”：那一步是关闭让它马上结束的（"closed"），
    /// 请求已经交给 WebKit、没有撤回（测试还拿着它的回调）。
    func testAClosedTabIsReleasedAtOnceWhileWebKitHoldsItsMediaRequest() async throws {
        let kinds: [(String, ChatGPTAdapter.MediaRequest, @MainActor (TabCloseRig, Refs) -> Void, [String])] = [
            ("每秒的读", .state, { rig, _ in rig.tabs.mediaTick() }, []),
            ("页面变化后的读", .state, { [chat, other] _, refs in
                refs.runtime?.onURLChange?(chat)
                refs.runtime?.onURLChange?(other)
            }, []),
            ("挂起实验", .suspendAll(true), { rig, _ in _ = Task { await rig.tabs.runExperiment(.suspendAll) } },
             ["[diag] 媒体实验“WebKit setAllMediaPlaybackSuspended(true)”没有做完：标签页在“全部挂起”这一步关闭，这一步的结果丢弃；"
              + "关闭时马上不再等 WebKit 回答，已交给 WebKit 的请求没有撤回 【标签2】"]),
            ("暂停实验", .pauseAll, { rig, _ in _ = Task { await rig.tabs.runExperiment(.pauseAll) } },
             ["[diag] 媒体实验“WebKit pauseAllMediaPlayback”没有做完：标签页在“全部暂停”这一步关闭，这一步的结果丢弃；"
              + "关闭时马上不再等 WebKit 回答，已交给 WebKit 的请求没有撤回 【标签2】"]),
        ]
        for (name, request, start, cutShort) in kinds {
            let rig = make()
            rig.realAdapter = true
            let held = HeldMediaRequests()
            let refs = autoreleasepool {
                let b = rig.add()
                held.install(on: b.adapter)
                b.adapter.mediaTimeout = 60
                rig.tabs.select(b)
                return Refs(b)
            }
            let shown = rig.diagnostics.webMediaState, experiments = rig.diagnostics.experiments
            start(rig, refs)
            try await waitUntil(3) { held.requests.count == 1 }
            XCTAssertEqual(held.requests, [request], name)
            XCTAssertTrue(refs.noneReleased, "\(name)：等着的时候还拿着它")
            let mark = rig.mark()
            let closedAt = Date()
            autoreleasepool {
                guard let tab = refs.tab else { return XCTFail("还没关就释放了") }
                rig.tabs.closeTab(tab)
            }
            try await waitUntil(2) { refs.allReleased }
            XCTAssertTrue(refs.allReleased, "\(name)：WebKit 没回答也释放了")
            XCTAssertLessThan(Date().timeIntervalSince(closedAt), 1.0, "\(name)：不等时限")
            XCTAssertEqual(held.requests.count, 1, "\(name)：测试还拿着回调")

            held.answer(0, held.requests[0] == .state ? .playing : nil)
            try await pause(0.1)
            XCTAssertEqual(rig.diagnostics.webMediaState, shown, name)
            XCTAssertEqual(rig.diagnostics.experiments, experiments, name)
            XCTAssertEqual(rig.lines(since: mark).filter { $0.contains("【标签2】") },
                           ["[tabs] 关闭（剩 1 个） 【标签2】", "[web] 关闭网页：停止加载 【标签2】"] + cutShort, name)
        }
    }

    /// 渲染自检：加载完成 3 秒后在网页里跑一个只取数量的脚本。网页在那之前忙起来（3 秒），脚本发出去回不来时关闭 2：
    /// 2 在网页忙完之前就释放（回调只弱引用运行时），之后不写“自检”那一行。
    func testTheRenderCheckDoesNotHoldAClosedRuntimeWhileItsScriptIsOut() async throws {
        let rig = make()
        let refs = autoreleasepool {
            let b = rig.add()
            rig.tabs.select(b)
            return Refs(b)
        }
        // 测试自己不拿着它们（只弱引用），用完就放开。
        await rig.loadPage(refs.tab!, "<html><body><p>x</p></body></html>")
        let loaded = Date()
        XCTAssertEqual(refs.web?.url, chat)
        _ = try await refs.web?.evaluateJavaScript(
            "setTimeout(() => { const end = Date.now() + 3000; while (Date.now() < end) {} }, 2500); 0")
        let mark = rig.mark()
        try await pause(3.4 - Date().timeIntervalSince(loaded))
        XCTAssertTrue(refs.noneReleased)
        autoreleasepool {
            guard let tab = refs.tab else { return XCTFail("还没关就释放了") }
            rig.tabs.closeTab(tab)
        }
        try await waitUntil(3) { refs.allReleased }
        XCTAssertTrue(refs.allReleased)
        XCTAssertLessThan(Date().timeIntervalSince(loaded), 4.8, "网页忙完（5.5 秒）之前就释放")
        try await pause(5.8 - Date().timeIntervalSince(loaded))
        XCTAssertFalse(rig.allLines(since: mark).contains { $0.hasPrefix("[render]") }, "不写自检那一行")
    }

    // MARK: - 替身

    /// 标签页和它的几样的弱引用。
    @MainActor
    private final class Refs {
        weak var tab: ChatTab?
        weak var runtime: WebRuntime?
        weak var adapter: ChatGPTAdapter?
        weak var page: PageLoadState?
        weak var web: WKWebView?

        init(_ tab: ChatTab) {
            self.tab = tab
            runtime = tab.runtime
            adapter = tab.adapter
            page = tab.page
            web = tab.runtime.webView
        }

        var allReleased: Bool { tab == nil && runtime == nil && adapter == nil && page == nil && web == nil }
        var noneReleased: Bool { tab != nil && runtime != nil && adapter != nil && page != nil && web != nil }
    }

    /// 代替 WebKit 接媒体请求：记下请求和回答用的回调（拿着它们），不回答；测试用 answer 回答第 i 个。不拿着网页视图。
    @MainActor
    private final class HeldMediaRequests {
        private(set) var requests: [ChatGPTAdapter.MediaRequest] = []
        private var answers: [@MainActor (WKMediaPlaybackState?) -> Void] = []

        func install(on adapter: ChatGPTAdapter) {
            adapter.sendMediaRequest = { [weak self] _, request, done in
                self?.requests.append(request)
                self?.answers.append(done)
            }
        }

        func answer(_ index: Int, _ state: WKMediaPlaybackState?) {
            guard answers.indices.contains(index) else { return XCTFail("没有第 \(index) 个请求") }
            answers[index](state)
        }
    }
}
