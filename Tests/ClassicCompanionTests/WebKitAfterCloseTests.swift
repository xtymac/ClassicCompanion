import AppKit
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 关闭以后，真的 WebKit 回来的东西（不开窗口、不联网：网页视图不放进窗口，只打开本地 html 或 data: 地址）。
/// 网页运行时（WebRuntime.close()）：
/// - 导航响应：关闭以后一律取消（3.1 没有测到的）；
/// - 消息桥从网页里拿掉、地址观察停掉、还在解析的页面停止加载（3.1 只核对了回调断开，这三样现在看网页本身）；
/// - 关闭之前发出、之后才回来的网页脚本（加载完成后的 Esc 脚本、渲染自检、确认阅读位置、读浏览器标识）回来时什么都不写；
/// - 媒体采集请求照样拒绝、不写日志；新窗口、提示框、确认框按取消处理（只走关闭以后的那条路：没关闭的那条路会开窗口）。
/// 适配器（ChatGPTAdapter.close()）：
/// - 关闭以后不在网页里跑脚本、不读媒体状态，马上返回；
/// - 跑着的脚本在关闭以后返回、超时，都不写日志、不写诊断，新对话不再等页面变化；
/// - 脚本返回以后适配器马上可以释放，不等时限。
/// 每条都有一个没关闭的对照，说明看到的“没有”是关闭带来的。
@MainActor
final class WebKitAfterCloseTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await pause(0.02) }
    }

    private func settings() -> AppSettings {
        let name = "WebKitAfterCloseTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return AppSettings(defaults: UserDefaults(suiteName: name)!)
    }

    /// 一个网页运行时和它自己的日志。加载请求只记下来（不联网）；网页由测试直接 loadHTMLString 打开。
    private func makeRuntime() -> (WebRuntime, Diagnostics) {
        let diagnostics = Diagnostics()
        let runtime = WebRuntime(diagnostics: diagnostics, settings: settings(), watchesNetwork: false)
        runtime.loadRequest = { _ in }
        return (runtime, diagnostics)
    }

    private func lines(_ diagnostics: Diagnostics) -> [String] {
        diagnostics.entries.map { "[\($0.category)] \($0.message)" }
    }

    /// 关闭那一行之后的日志。
    private func linesAfterClose(_ diagnostics: Diagnostics) -> [String] {
        let all = lines(diagnostics)
        guard let index = all.firstIndex(where: { $0.hasPrefix("[web] 关闭网页") }) else { return ["（没有关闭那一行）"] }
        return Array(all.dropFirst(index + 1))
    }

    /// 打开本地 html（地址是 url），等到加载完成。
    private func open(_ web: WKWebView, _ html: String, at url: URL? = nil) async throws {
        let url = url ?? chat
        web.loadHTMLString(html, baseURL: url)
        try await waitUntil(5) { web.url == url && !web.isLoading }
        XCTAssertEqual(web.url, url)
    }

    /// 不属于任何运行时的网页视图（网站数据不落盘），用来拿 WebKit 的导航响应、frame，或者给适配器用。
    private func plainWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
    }

    /// 网页忙 seconds 秒（主线程卡住），从 after 秒后开始。之后发给它的脚本要等它忙完才执行、才返回。
    private func busy(_ web: WKWebView, for seconds: Double, after: Double = 0) async throws {
        _ = try await web.evaluateJavaScript(
            "setTimeout(() => { const end = Date.now() + \(Int(seconds * 1000)); while (Date.now() < end) {} }, \(Int(after * 1000))); 0")
    }

    private func evaluate(_ web: WKWebView, _ js: String, in world: WKContentWorld = .page) async throws -> String {
        let value = try await web.evaluateJavaScript(js, in: nil, contentWorld: world)
        return "\(value ?? "nil")"
    }

    // MARK: - 网页运行时：导航响应

    /// 一个真的导航响应（data: 地址的 text/html）：没关闭的运行时允许显示，关闭以后取消。
    func testANavigationResponseAfterCloseIsCancelled() async throws {
        let catcher = PolicyCatcher()
        let web = plainWebView()
        web.navigationDelegate = catcher
        web.load(URLRequest(url: URL(string: "data:text/html,<p>x</p>")!))
        try await waitUntil(5) { catcher.response != nil && !web.isLoading }
        let response = try XCTUnwrap(catcher.response)
        let (control, _) = makeRuntime()
        let (closed, diagnostics) = makeRuntime()
        closed.close()
        let allowed = await control.webView(control.webView, decidePolicyFor: response)
        let decided = await closed.webView(closed.webView, decidePolicyFor: response)
        XCTAssertEqual(allowed, .allow, "对照")
        XCTAssertEqual(decided, .cancel)
        XCTAssertEqual(linesAfterClose(diagnostics), [])
    }

    // MARK: - 网页运行时：消息桥、地址观察、停止加载

    /// 消息桥只在隔离世界里：关闭之前网页（隔离世界）看得到 cc，关闭以后看不到了。
    func testClosingTakesTheMessageBridgeOutOfThePage() async throws {
        let (runtime, _) = makeRuntime()
        try await open(runtime.webView, "<html><body>x</body></html>")
        let probe = "typeof window.webkit?.messageHandlers?.cc"
        let before = try await evaluate(runtime.webView, probe, in: .defaultClient)
        XCTAssertEqual(before, "object")
        runtime.close()
        let after = try await evaluate(runtime.webView, probe, in: .defaultClient)
        XCTAssertEqual(after, "undefined")
    }

    /// 网页自己改地址（history.pushState）：没关闭的运行时报出新地址；关闭以后（之后再接上的回调也）收不到——地址观察停掉了。
    /// 两边网页的地址都确实变了。
    func testClosingStopsWatchingTheAddress() async throws {
        let (control, _) = makeRuntime()
        let (closed, _) = makeRuntime()
        for runtime in [control, closed] { try await open(runtime.webView, "<html><body>x</body></html>") }
        closed.close()
        var reported: [String: [String]] = [:]
        control.onURLChange = { reported["对照", default: []].append($0?.path ?? "nil") }
        closed.onURLChange = { reported["关闭", default: []].append($0?.path ?? "nil") }
        for runtime in [control, closed] {
            _ = try await evaluate(runtime.webView, "history.pushState(null, '', '/c/zzz'); location.pathname")
        }
        try await pause(0.3)
        XCTAssertEqual(control.webView.url?.path, "/c/zzz")
        XCTAssertEqual(closed.webView.url?.path, "/c/zzz")
        XCTAssertEqual(reported["对照"], ["/c/zzz"])
        XCTAssertNil(reported["关闭"])
    }

    /// 页面提交以后、还在解析（一段内联脚本忙 0.6 秒，后面还有内容）时关闭：停止加载，页面停在“loading”，后面的内容不再解析。
    /// 对照：不关闭的照常解析完（complete，后面的内容在）。
    func testClosingStopsAPageThatIsStillParsing() async throws {
        let html = "<html><body><script>const end = Date.now() + 600; while (Date.now() < end) {}</script>"
            + "<div id='after'>a</div></body></html>"
        let (control, _) = makeRuntime()
        let (closed, _) = makeRuntime()
        closed.onMainFrameCommitted = { [weak closed] in closed?.close() }
        control.webView.loadHTMLString(html, baseURL: chat)
        closed.webView.loadHTMLString(html, baseURL: chat)
        try await pause(2.0)
        XCTAssertTrue(closed.isClosed)
        let state = "document.readyState + '|' + !!document.getElementById('after')"
        let controlState = try await evaluate(control.webView, state)
        let closedState = try await evaluate(closed.webView, state)
        XCTAssertEqual(controlState, "complete|true", "对照")
        XCTAssertEqual(closedState, "loading|false")
    }

    // MARK: - 网页运行时：关闭以后才回来的脚本

    /// 加载完成后的 Esc 脚本和小窗按钮样式：加载完成时（运行时先发出这两个脚本，再调用加载完成的回调）在回调里关闭，
    /// 两个脚本回来时什么都不写。对照：不关闭的写两行 [esc]。
    func testTheEscapeScriptsThatComeBackAfterCloseWriteNothing() async throws {
        let (control, controlLog) = makeRuntime()
        let (closed, closedLog) = makeRuntime()
        closed.onMainFrameLoaded = { [weak closed] in closed?.close() }
        for runtime in [control, closed] { try await open(runtime.webView, "<html><body>x</body></html>") }
        try await waitUntil { lines(controlLog).filter { $0.hasPrefix("[esc]") }.count == 2 }
        try await pause(0.3)
        XCTAssertEqual(lines(controlLog).filter { $0.hasPrefix("[esc]") }.count, 2, "对照")
        XCTAssertTrue(closed.isClosed)
        XCTAssertEqual(linesAfterClose(closedLog), [])
    }

    /// 读浏览器标识：建好就关闭，标识回来时不写诊断。对照：不关闭的写上。
    func testTheUserAgentThatComesBackAfterCloseIsNotWritten() async throws {
        let (control, controlLog) = makeRuntime()
        let (closed, closedLog) = makeRuntime()
        closed.close()
        try await waitUntil { controlLog.userAgent != "<未知>" }
        try await pause(0.2)
        XCTAssertNotEqual(controlLog.userAgent, "<未知>", "对照")
        XCTAssertEqual(closedLog.userAgent, "<未知>")
        _ = control
    }

    /// 放回阅读位置并请网页确认：发出以后马上关闭，确认的结果回来时不写 [reading]。对照：不关闭的写一行。
    func testAReadingConfirmationThatComesBackAfterCloseWritesNothing() async throws {
        let (control, controlLog) = makeRuntime()
        let (closed, closedLog) = makeRuntime()
        for runtime in [control, closed] {
            try await open(runtime.webView, "<html><body>x</body></html>")
            runtime.restoreReadingPosition(1, confirmingContinuation: true)
        }
        closed.close()
        try await waitUntil { lines(controlLog).contains { $0.hasPrefix("[reading]") } }
        try await pause(0.2)
        XCTAssertTrue(lines(controlLog).contains { $0.hasPrefix("[reading]") }, "对照")
        XCTAssertEqual(linesAfterClose(closedLog), [])
    }

    /// 加载完成后 3 秒的渲染自检：到点时还没关闭，自检脚本发出去了，但网页正忙（2.6–3.8 秒），脚本 3.8 秒左右才回来；
    /// 3.3 秒时关闭。回来时不写 [render]。对照：不关闭的写一行。（到点时已经关闭的那种见 WebRuntimeCloseTests。）
    func testARenderSelfCheckThatComesBackAfterCloseWritesNothing() async throws {
        let html = "<html><body>x<script>setTimeout(() => { const end = Date.now() + 1200; while (Date.now() < end) {} }, 2600)"
            + "</script></body></html>"
        let (control, controlLog) = makeRuntime()
        let (closed, closedLog) = makeRuntime()
        closed.onMainFrameLoaded = { [weak closed] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) { [weak closed] in MainActor.assumeIsolated { closed?.close() } }
        }
        control.webView.loadHTMLString(html, baseURL: chat)
        closed.webView.loadHTMLString(html, baseURL: chat)
        try await waitUntil(8) { lines(controlLog).contains { $0.hasPrefix("[render]") } }
        try await pause(0.5)
        XCTAssertTrue(lines(controlLog).contains { $0.hasPrefix("[render] 自检") }, "对照")
        XCTAssertTrue(closed.isClosed)
        XCTAssertEqual(linesAfterClose(closedLog), [])
        XCTAssertFalse(lines(closedLog).contains { $0.hasPrefix("[render]") })
    }

    // MARK: - 网页运行时：媒体采集、新窗口、对话框

    /// 媒体采集请求（真的 frame）：没关闭的拒绝并写一行；关闭以后照样拒绝，不写。
    func testAMediaCaptureRequestAfterCloseIsDeniedWithoutALine() async throws {
        let frame = try await capturedFrame()
        let (control, controlLog) = makeRuntime()
        let (closed, closedLog) = makeRuntime()
        closed.close()
        let allowed = await control.webView(control.webView, decideMediaCapturePermissionsFor: frame.securityOrigin,
                                            initiatedBy: frame, type: .microphone)
        let decided = await closed.webView(closed.webView, decideMediaCapturePermissionsFor: frame.securityOrigin,
                                           initiatedBy: frame, type: .microphone)
        XCTAssertEqual(allowed, .deny)
        XCTAssertEqual(lines(controlLog).last, "[media] 已拒绝媒体采集请求（Phase 0 不启用）", "对照")
        XCTAssertEqual(decided, .deny)
        XCTAssertEqual(linesAfterClose(closedLog), [])
    }

    /// 关闭以后网页要开新窗口、弹提示框、确认框：不开窗口（返回 nil、窗口数不变）、不显示（确认框按取消）、不写日志。
    /// 只走关闭以后的那条路：没关闭的那条路会真的开窗口、弹模态框，测试不能那样做（所以这几处没有做变异核对，见报告）。
    func testAfterCloseNoPopupOrDialogIsShown() async throws {
        let catcher = PolicyCatcher()
        let web = plainWebView()
        web.navigationDelegate = catcher
        try await open(web, "<html><body>x</body></html>")
        let action = try XCTUnwrap(catcher.action)
        let frame = try XCTUnwrap(action.targetFrame)
        let (closed, closedLog) = makeRuntime()
        closed.close()
        let windows = NSApplication.shared.windows.count
        let popup = closed.webView(closed.webView, createWebViewWith: WKWebViewConfiguration(), for: action,
                                   windowFeatures: WKWindowFeatures())
        XCTAssertNil(popup)
        await closed.webView(closed.webView, runJavaScriptAlertPanelWithMessage: "x", initiatedByFrame: frame)
        let confirmed = await closed.webView(closed.webView, runJavaScriptConfirmPanelWithMessage: "x", initiatedByFrame: frame)
        XCTAssertFalse(confirmed)
        XCTAssertEqual(NSApplication.shared.windows.count, windows)
        XCTAssertEqual(linesAfterClose(closedLog), [])
    }

    /// 一个真的主框架 frame（打开本地 html 时导航动作的目标 frame）。
    private func capturedFrame() async throws -> WKFrameInfo {
        let catcher = PolicyCatcher()
        let web = plainWebView()
        web.navigationDelegate = catcher
        try await open(web, "<html><body>x</body></html>")
        return try XCTUnwrap(catcher.action?.targetFrame)
    }

    // MARK: - 适配器

    private let newChatButton = "<html><body><button data-testid='create-new-chat-button' "
        + "onclick='window.clicks = (window.clicks || 0) + 1'>新对话</button></body></html>"

    /// 点下去要忙 ms 毫秒的“新对话”入口。
    private func slowNewChatButton(_ ms: Int) -> String {
        "<html><body><button data-testid='create-new-chat-button' onclick='const end = Date.now() + \(ms); "
            + "while (Date.now() < end) {} window.clicks = (window.clicks || 0) + 1'>新对话</button></body></html>"
    }

    /// 一个适配器，网页视图打开本地 html（地址是聊天页面，不联网）。适配器只弱引用网页视图：调用方要拿着返回的网页视图。
    private func makeAdapter(_ html: String) async throws -> (ChatGPTAdapter, WKWebView, Diagnostics) {
        let web = plainWebView()
        try await open(web, html)
        let diagnostics = Diagnostics()
        return (ChatGPTAdapter(webView: web, diagnostics: diagnostics, settings: settings()), web, diagnostics)
    }

    /// 关闭以后：新对话不点（入口没被点过）、媒体状态不读（"closed"）、聚焦、测量、朗读证据、实验都不跑脚本（按没有结果），
    /// 一共不到 0.5 秒（测量脚本本来要 2 秒）；探测不写诊断（不是聊天页面时也不写）；适配器不写日志。
    /// 对照：没关闭的点到入口、读到媒体状态、聚焦脚本照常回答，探测写诊断。
    func testAClosedAdapterRunsNoScriptAndAnswersAtOnce() async throws {
        let (adapter, web, diagnostics) = try await makeAdapter(newChatButton)
        adapter.close()
        XCTAssertTrue(adapter.isClosed)
        let started = Date()
        let newChat = await adapter.openNewChatInPage()
        let media = await adapter.webMediaState()
        let focus = await adapter.focusInput()
        let measured = await adapter.measureMedia()
        let evidence = await adapter.readAloudEvidence()
        let rate = await adapter.experimentSetRate(1.0)
        await adapter.probe()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertTrue(newChat, "不让调用方整页加载")
        XCTAssertEqual(media, "closed")
        XCTAssertEqual(focus, "timeout")
        XCTAssertEqual(measured, "webkitMedia=closed timeout")
        XCTAssertEqual(evidence, "{\"status\":\"timeout\",\"webkitMedia\":\"closed\"}")
        XCTAssertEqual(rate, "set=timeout measured=webkitMedia=closed timeout")
        XCTAssertEqual(diagnostics.capabilities, Diagnostics.PageCapabilities())
        let clicks = try await evaluate(web, "window.clicks || 0")
        XCTAssertEqual(clicks, "0", "入口没被点过")
        XCTAssertEqual(lines(diagnostics), [])

        let blank = ChatGPTAdapter(webView: plainWebView(), diagnostics: diagnostics, settings: settings())
        blank.close()
        await blank.probe()
        XCTAssertEqual(diagnostics.capabilities, Diagnostics.PageCapabilities(), "不是聊天页面时也不写")

        let (control, controlWeb, controlLog) = try await makeAdapter(newChatButton)
        let controlMedia = await control.webMediaState()
        let controlFocus = await control.focusInput()
        await control.probe()
        XCTAssertEqual(controlMedia, "none", "对照")
        XCTAssertEqual(controlFocus, "input-not-found", "对照")
        XCTAssertEqual(controlLog.capabilities.pageKind, "chat", "对照")
        _ = await control.openNewChatInPage()
        let controlClicks = try await evaluate(controlWeb, "window.clicks || 0")
        XCTAssertEqual(controlClicks, "1", "对照")
    }

    /// 跑着的脚本在关闭以后返回：
    /// - 新对话：点入口的脚本还没返回（入口点下去忙 0.4 秒）时关闭——返回以后不写“官方入口命中”，不再等页面变化（不到 0.8 秒就返回）；
    ///   已经点完、在等页面变化时关闭——下一次看的时候就返回，不写“已点击官方入口”；
    /// - 探测：网页忙着、探测脚本还没跑时关闭——回来以后不写诊断。
    /// 对照：不关闭的写两行，等满 1 秒；探测写诊断。
    func testAnAdapterScriptThatComesBackAfterCloseWritesNothing() async throws {
        let (clicking, clickingWeb, clickingLog) = try await makeAdapter(slowNewChatButton(400))
        let started = Date()
        let task = Task { await clicking.openNewChatInPage() }
        try await pause(0.1)
        clicking.close()
        let clicked = await task.value
        XCTAssertTrue(clicked)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
        XCTAssertEqual(lines(clickingLog), [])

        let (waiting, waitingWeb, waitingLog) = try await makeAdapter(newChatButton)
        let polling = Task { await waiting.openNewChatInPage() }
        try await pause(0.35)
        XCTAssertEqual(lines(waitingLog), ["[nav] 新建对话 官方入口命中=[0, 1, 0, 0, 0]"])
        let closedAt = Date()
        waiting.close()
        _ = await polling.value
        XCTAssertLessThan(Date().timeIntervalSince(closedAt), 0.3)
        XCTAssertEqual(lines(waitingLog), ["[nav] 新建对话 官方入口命中=[0, 1, 0, 0, 0]"])

        let (probing, probingWeb, probingLog) = try await makeAdapter("<html><body>x</body></html>")
        try await busy(probingWeb, for: 0.4)
        try await pause(0.05)
        let probe = Task { await probing.probe() }
        try await pause(0.1)
        probing.close()
        await probe.value
        XCTAssertEqual(probingLog.capabilities, Diagnostics.PageCapabilities())

        let (control, controlWeb, controlLog) = try await makeAdapter(slowNewChatButton(400))
        let controlStarted = Date()
        _ = await control.openNewChatInPage()
        XCTAssertGreaterThan(Date().timeIntervalSince(controlStarted), 1.3, "对照")
        XCTAssertEqual(lines(controlLog), ["[nav] 新建对话 官方入口命中=[0, 1, 0, 0, 0]",
                                           "[nav] 新建对话：已点击官方入口，保留页内切换，不追加整页加载"], "对照")
        await control.probe()
        XCTAssertEqual(controlLog.capabilities.pageKind, "chat", "对照")
        // 适配器只弱引用网页视图：测试拿着它们到最后。
        withExtendedLifetime((clickingWeb, waitingWeb, probingWeb, controlWeb)) {}
    }

    /// 网页忙 3.2 秒，聚焦脚本发出去了要等它忙完；0.1 秒后关闭一个。2.5 秒到时限：关闭的不写“脚本超时”，对照写一行；
    /// 网页忙完、脚本迟到返回时两边都不再写什么。
    func testAnAdapterScriptTimeoutAfterCloseIsNotLogged() async throws {
        let (closed, closedWeb, closedLog) = try await makeAdapter("<html><body>x</body></html>")
        let (control, controlWeb, controlLog) = try await makeAdapter("<html><body>x</body></html>")
        try await busy(closedWeb, for: 3.2)
        try await busy(controlWeb, for: 3.2)
        try await pause(0.05)
        let focusing = Task { await closed.focusInput() }
        let controlFocusing = Task { await control.focusInput() }
        try await pause(0.1)
        closed.close()
        let result = await focusing.value
        let controlResult = await controlFocusing.value
        XCTAssertEqual(result, "timeout")
        XCTAssertEqual(controlResult, "timeout")
        XCTAssertEqual(lines(controlLog), ["[adapter] 脚本超时"], "对照")
        XCTAssertEqual(lines(closedLog), [])
        try await pause(1.0)
        XCTAssertEqual(lines(controlLog), ["[adapter] 脚本超时"])
        XCTAssertEqual(lines(closedLog), [])
        withExtendedLifetime((closedWeb, controlWeb)) {}
    }

    /// 网页一直忙（4 秒），聚焦脚本到时限（2.5 秒）还没返回，适配器按没有结果返回，网页视图随即释放（标签页释放时就是这样）。
    /// 实测 WebKit 不是在网页视图释放时、而是等网页忙完才让那个还没返回的脚本出错（WKErrorDomain#5）。三个一起跑：
    /// - 对照（没关闭、还拿着）：写“脚本超时”和“脚本错误”两行；
    /// - 关闭了、还有人拿着适配器：两行都不写；
    /// - 关闭了、没人拿着：时限一到它就释放（脚本的回调只弱引用它），不等网页忙完。
    /// 三个网页视图都在时限时释放：还没返回的脚本不拿着网页视图。
    func testAScriptThatFailsAfterItsWebViewWentWritesNothingAndHoldsNothing() async throws {
        let logs = [Diagnostics(), Diagnostics(), Diagnostics()]
        var adapters: [ChatGPTAdapter] = []
        var views: [WeakBox<WKWebView>] = []
        var tasks: [Task<String, Never>] = []
        do {
            var webs: [WKWebView] = []
            for log in logs {
                let web = plainWebView()
                try await open(web, "<html><body>x</body></html>")
                webs.append(web)
                adapters.append(ChatGPTAdapter(webView: web, diagnostics: log, settings: settings()))
            }
            for web in webs { try await busy(web, for: 4) }
            try await pause(0.05)
            for adapter in adapters { tasks.append(Task { await adapter.focusInput() }) }
            try await pause(0.1)
            adapters[1].close()
            adapters[2].close()
            views = webs.map { WeakBox($0) }
        }
        let dropped = WeakBox(adapters[2])
        adapters.removeLast()
        let (control, kept) = (adapters[0], adapters[1])
        adapters = []
        for task in tasks {
            let result = await task.value
            XCTAssertEqual(result, "timeout")
        }
        tasks = []
        let timedOut = Date()
        try await waitUntil(1) { views.allSatisfy { $0.value == nil } && dropped.value == nil }
        XCTAssertTrue(views.allSatisfy { $0.value == nil }, "网页视图在时限时释放")
        XCTAssertNil(dropped.value, "关闭了、没人拿着：时限一到就释放")
        XCTAssertLessThan(Date().timeIntervalSince(timedOut), 0.5)
        XCTAssertEqual(lines(logs[0]), ["[adapter] 脚本超时"], "这时脚本还没出错")
        try await waitUntil(4) { lines(logs[0]).count == 2 }
        try await pause(0.3)
        XCTAssertEqual(lines(logs[0]).count, 2, "对照：\(lines(logs[0]))")
        XCTAssertEqual(lines(logs[0]).first, "[adapter] 脚本超时", "对照")
        XCTAssertTrue(lines(logs[0]).last?.hasPrefix("[adapter] 脚本错误 WKErrorDomain#") == true, "对照：\(lines(logs[0]))")
        XCTAssertEqual(lines(logs[1]), [])
        XCTAssertEqual(lines(logs[2]), [])
        withExtendedLifetime((control, kept)) {}
    }

    /// 脚本返回以后适配器马上可以释放（到时限的那一次只弱引用它），不等 2.5 秒的时限。关闭的也一样。
    func testAnAdapterIsReleasedWhenItsScriptReturnsNotAtTheTimeout() async throws {
        let web = plainWebView()
        try await open(web, "<html><body>x</body></html>")
        for closes in [false, true] {
            weak var released: ChatGPTAdapter?
            do {
                let adapter = ChatGPTAdapter(webView: web, diagnostics: Diagnostics(), settings: settings())
                released = adapter
                let focus = await adapter.focusInput()
                XCTAssertEqual(focus, "input-not-found")
                if closes { adapter.close() }
            }
            try await waitUntil(1) { released == nil }
            XCTAssertNil(released, "关闭=\(closes)")
        }
    }
}

/// 弱引用一个对象。
private final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// 记下网页视图的导航动作和导航响应（都放行）。
@MainActor
private final class PolicyCatcher: NSObject, WKNavigationDelegate {
    var action: WKNavigationAction?
    var response: WKNavigationResponse?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        action = navigationAction
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response = navigationResponse
        return .allow
    }
}
