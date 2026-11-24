import AppKit
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 登录等弹窗的窗口关上以后（WebRuntime.tearDownPopup(_:)）：
/// - 不管怎么关上（用户点关闭按钮、网页 window.close()、这一页关闭），都拆一次：不再记着它，它的网页视图断开代理，
///   网页视图在下一轮从窗口里拿出来；
/// - 之后它的网页视图（和不认识的网页视图）来的请求一律不给做：对话框不显示、按取消回答，导航取消、外部链接不交给浏览器，
///   不给新窗口；排着时弹窗关上的对话框放出来时也不显示；
/// - 开着的弹窗（在不在屏幕上）照原来。
/// 不开窗口、不联网、不弹模态框：弹窗的窗口从不显示（关上一个从不显示的窗口照样发关上的通知），网页视图不放进显示的窗口；
/// 显示弹窗、对话框、交给浏览器都换成记录（Rig）。网页的 frame、导航动作、导航响应、文件选择参数从一个不属于任何运行时的
/// 网页视图拿（本地 html，地址是聊天页面）。
@MainActor
final class PopupWindowTeardownTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!
    private let external = URL(string: "https://example.com/page")!

    /// 一个没接上标签页的运行时（选中与否、弹窗在不在屏幕上由测试定），显示和交给浏览器都换成记录。
    @MainActor
    private final class Rig {
        let diagnostics = Diagnostics()
        let runtime: WebRuntime
        var browser: [URL] = []
        var shownPopups: [NSWindow] = []
        var presented: [String] = []

        init(settings: AppSettings) {
            runtime = WebRuntime(diagnostics: diagnostics, settings: settings, watchesNetwork: false)
            runtime.loadRequest = { _ in }
            runtime.openInBrowser = { [unowned self] in browser.append($0) }
            runtime.showPopupWindow = { [unowned self] in shownPopups.append($0) }
            runtime.presentAlert = { [unowned self] _, _, _ in presented.append("提示框") }
            runtime.presentConfirm = { [unowned self] _, _, _ in
                presented.append("确认框")
                return true
            }
            runtime.presentOpenPanel = { [unowned self] _, _, _ in
                presented.append("文件选择")
                return [URL(fileURLWithPath: "/tmp/选的文件.txt")]
            }
        }

        var lines: [String] { diagnostics.entries.map { "[\($0.category)] \($0.message)" } }
        func lines(since mark: Int) -> [String] { Array(lines.dropFirst(mark)) }
    }

    private func make() -> Rig {
        let name = "PopupWindowTeardownTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return Rig(settings: AppSettings(defaults: UserDefaults(suiteName: name)!))
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func plainWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
    }

    /// rig 的运行时开着的一个弹窗：网页视图的代理是运行时（和 createWebViewWith 开的一样），放进一个从不显示的窗口，
    /// 记作运行时的弹窗（adoptPopupForTesting，和真的弹窗一样听它关上）。
    private func popup(_ rig: Rig) -> (web: WKWebView, window: NSWindow) {
        let web = plainWebView()
        web.navigationDelegate = rig.runtime
        web.uiDelegate = rig.runtime
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = "旧标题"
        window.contentView = web
        rig.runtime.adoptPopupForTesting(window)
        return (web, window)
    }

    /// WebKit 真交来的东西：打开聊天页面时的导航动作和主框架 frame，点外部链接的导航动作，点文件输入框的文件选择参数，
    /// 和一个导航响应（data: 地址）。
    private func capture() async throws -> Captured {
        let catcher = Catcher()
        let web = plainWebView()
        web.navigationDelegate = catcher
        web.uiDelegate = catcher
        web.loadHTMLString("<html><body><a id=e href='\(external.absoluteString)'>e</a><input type=file id=f></body></html>",
                           baseURL: chat)
        try await waitUntil(5) { web.url == chat && !web.isLoading }
        _ = try await web.evaluateJavaScript("document.getElementById('e').click(); document.getElementById('f').click(); 0")
        try await waitUntil(5) { catcher.link != nil && catcher.parameters != nil }
        let load = try XCTUnwrap(catcher.load)
        // 本地 html 没有导航响应：另开一个网页视图打开 data: 地址（text/html）拿。
        let responder = Catcher()
        let dataWeb = plainWebView()
        dataWeb.navigationDelegate = responder
        dataWeb.load(URLRequest(url: URL(string: "data:text/html,<p>x</p>")!))
        try await waitUntil(5) { responder.response != nil && !dataWeb.isLoading }
        return Captured(load: load, frame: try XCTUnwrap(load.targetFrame), response: try XCTUnwrap(responder.response),
                        link: try XCTUnwrap(catcher.link), parameters: try XCTUnwrap(catcher.parameters),
                        keep: [web, catcher, dataWeb, responder])
    }

    // MARK: - 拆

    /// 用户关上弹窗的窗口（这里 close()）：不再记着它（改界面语言也不碰它），网页视图断开代理，写一行；下一轮网页视图从窗口里
    /// 拿出来。再关一遍、网页再 window.close()、这一页关闭，都不再拆（关闭那一行不算它）。
    func testClosingThePopupWindowTearsItDownOnce() async throws {
        let rig = make()
        let (web, window) = popup(rig)
        XCTAssertTrue(rig.runtime.tracksPopupForTesting(window))
        let mark = rig.lines.count

        window.close()
        XCTAssertFalse(rig.runtime.tracksPopupForTesting(window))
        XCTAssertNil(web.navigationDelegate)
        XCTAssertNil(web.uiDelegate)
        rig.runtime.retitlePopups()
        XCTAssertEqual(window.title, "旧标题", "不再记着它")
        try await waitUntil { window.contentView !== web }
        XCTAssertFalse(window.contentView === web, "网页视图从窗口里拿出来了")

        window.close()
        rig.runtime.webViewDidClose(web)
        rig.runtime.close()
        XCTAssertEqual(rig.lines(since: mark), ["[web] 弹窗的窗口关上了：停止加载，断开代理", "[web] 关闭网页：停止加载"])
    }

    /// 网页自己 window.close()：窗口关上一次，拆一次，只写一行（关上的通知不再拆一遍）。再来一次什么都不做。
    func testAPageClosingItsPopupTearsItDownOnce() {
        let rig = make()
        let (web, window) = popup(rig)
        var closed = 0
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                           queue: nil) { _ in closed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let mark = rig.lines.count

        rig.runtime.webViewDidClose(web)
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(rig.runtime.tracksPopupForTesting(window))
        XCTAssertNil(web.navigationDelegate)
        XCTAssertNil(web.uiDelegate)
        rig.runtime.webViewDidClose(web)
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(rig.lines(since: mark), ["[web] 网页关掉了弹窗：停止加载，断开代理"])
    }

    /// 这一页关闭：开着的弹窗也拆掉（代理断开、不再记着），关上一次；只写关闭那一行。
    func testClosingThePageTearsDownItsPopups() {
        let rig = make()
        let (web, window) = popup(rig)
        var closed = 0
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                           queue: nil) { _ in closed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let mark = rig.lines.count

        rig.runtime.close()
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(rig.runtime.tracksPopupForTesting(window))
        XCTAssertNil(web.navigationDelegate)
        XCTAssertNil(web.uiDelegate)
        XCTAssertEqual(rig.lines(since: mark), ["[web] 关闭网页：停止加载，关掉 1 个弹窗"])
    }

    // MARK: - 关上的弹窗、不认识的网页视图：不给做

    /// 窗口关上的弹窗的网页视图、从没记下的网页视图：提示框、确认框、文件选择都不显示，马上按取消回答；导航、导航响应取消；
    /// 外部链接不交给浏览器；新窗口（外部地址、聊天页面）都不给、不显示。各写一行（没有地址、没有网页的文字）。
    /// 这一页是选中的（没接上的运行时总是）：原来的规则下这些都会做。
    func testAClosedPopupOrUnknownWebViewGetsNothingDone() async throws {
        let c = try await capture()
        let rig = make()
        let (closedPopup, window) = popup(rig)
        window.close()
        let unknown = plainWebView()
        XCTAssertTrue(rig.runtime.isSelectedTab())

        for (name, web) in [("关上的弹窗", closedPopup), ("不认识的", unknown)] {
            let mark = rig.lines.count
            await rig.runtime.webView(web, runJavaScriptAlertPanelWithMessage: "机密", initiatedByFrame: c.frame)
            let confirmed = await rig.runtime.webView(web, runJavaScriptConfirmPanelWithMessage: "机密", initiatedByFrame: c.frame)
            let files = await rig.runtime.webView(web, runOpenPanelWith: c.parameters, initiatedByFrame: c.frame)
            let linkPolicy = await rig.runtime.webView(web, decidePolicyFor: c.link, preferences: WKWebpagePreferences()).0
            let loadPolicy = await rig.runtime.webView(web, decidePolicyFor: c.load, preferences: WKWebpagePreferences()).0
            let responsePolicy = await rig.runtime.webView(web, decidePolicyFor: c.response)
            let externalWindow = rig.runtime.webView(web, createWebViewWith: WKWebViewConfiguration(), for: c.link,
                                                     windowFeatures: WKWindowFeatures())
            let chatWindow = rig.runtime.webView(web, createWebViewWith: WKWebViewConfiguration(), for: c.load,
                                                 windowFeatures: WKWindowFeatures())
            XCTAssertFalse(confirmed, name)
            XCTAssertNil(files, name)
            XCTAssertEqual(linkPolicy, .cancel, name)
            XCTAssertEqual(loadPolicy, .cancel, name)
            XCTAssertEqual(responsePolicy, .cancel, name)
            XCTAssertNil(externalWindow, name)
            XCTAssertNil(chatWindow, name)
            XCTAssertEqual(rig.lines(since: mark), [
                "[web] 关掉的弹窗或不认识的网页视图的提示框：不显示，按取消回答",
                "[web] 关掉的弹窗或不认识的网页视图的确认框：不显示，按取消回答",
                "[web] 关掉的弹窗或不认识的网页视图的文件选择：不显示，按取消回答",
                "[nav] 关掉的弹窗或不认识的网页视图要导航：取消",
                "[nav] 关掉的弹窗或不认识的网页视图要导航：取消",
                "[nav] 关掉的弹窗或不认识的网页视图要开新窗口：不开",
                "[nav] 关掉的弹窗或不认识的网页视图要开新窗口：不开",
            ], name)
        }
        XCTAssertEqual(rig.presented, [])
        XCTAssertEqual(rig.browser, [])
        XCTAssertEqual(rig.shownPopups, [])
        XCTAssertEqual(rig.runtime.heldDialogCount, 0)
        XCTAssertFalse(rig.lines.contains { $0.contains("机密") })
    }

    /// 弹窗的窗口不在屏幕上、这一页不是选中的：它的确认框排着；排着时窗口关上了。这一页被选中、放出来时：不显示，按取消回答
    /// （网页拿到 false），写一行；不排着了。
    func testADialogHeldWhileItsPopupClosesIsCancelledWhenReleased() async throws {
        let c = try await capture()
        let rig = make()
        var selected = false
        rig.runtime.isSelectedTab = { selected }
        rig.runtime.popupWindowIsOnScreen = { _ in false }
        let (web, window) = popup(rig)
        var answer: Bool?
        Task { answer = await rig.runtime.webView(web, runJavaScriptConfirmPanelWithMessage: "x", initiatedByFrame: c.frame) }
        try await waitUntil { rig.runtime.heldDialogCount == 1 }
        XCTAssertEqual(rig.runtime.heldDialogCount, 1)
        window.close()
        let mark = rig.lines.count

        selected = true
        rig.runtime.showHeldDialogs()
        try await waitUntil { answer != nil }
        XCTAssertEqual(answer, false)
        XCTAssertEqual(rig.presented, [])
        XCTAssertEqual(rig.runtime.heldDialogCount, 0)
        XCTAssertEqual(rig.lines(since: mark), ["[web] 排着的确认框的弹窗已经关上：不显示，按取消回答"])
    }

    // MARK: - 开着的弹窗：照原来

    /// 开着的弹窗：窗口在屏幕上时外部链接交给浏览器、对话框马上显示，不管这一页选不选中；不在屏幕上（藏起、最小化）时和这一页
    /// 一样（选中就交、就显示；不选中不交）。它要开的新窗口照原来开（显示之前已经记下）。
    func testAnOpenPopupKeepsItsBehaviour() async throws {
        let c = try await capture()
        let rig = make()
        var selected = false
        var onScreen = true
        rig.runtime.isSelectedTab = { selected }
        rig.runtime.popupWindowIsOnScreen = { _ in onScreen }
        let (web, window) = popup(rig)

        let shownPolicy = await rig.runtime.webView(web, decidePolicyFor: c.link, preferences: WKWebpagePreferences()).0
        await rig.runtime.webView(web, runJavaScriptAlertPanelWithMessage: "x", initiatedByFrame: c.frame)
        XCTAssertEqual(shownPolicy, .cancel)
        XCTAssertEqual(rig.browser, [external], "在屏幕上：交给浏览器")
        XCTAssertEqual(rig.presented, ["提示框"], "在屏幕上：马上显示")

        onScreen = false
        let hiddenPolicy = await rig.runtime.webView(web, decidePolicyFor: c.link, preferences: WKWebpagePreferences()).0
        XCTAssertEqual(hiddenPolicy, .cancel)
        XCTAssertEqual(rig.browser, [external], "不在屏幕上、这一页不选中：不交")

        selected = true
        let selectedPolicy = await rig.runtime.webView(web, decidePolicyFor: c.load, preferences: WKWebpagePreferences()).0
        _ = await rig.runtime.webView(web, decidePolicyFor: c.link, preferences: WKWebpagePreferences())
        let confirmed = await rig.runtime.webView(web, runJavaScriptConfirmPanelWithMessage: "x", initiatedByFrame: c.frame)
        XCTAssertEqual(selectedPolicy, .allow, "聊天页面照常导航")
        XCTAssertEqual(rig.browser, [external, external], "不在屏幕上、这一页选中：交")
        XCTAssertTrue(confirmed)
        XCTAssertEqual(rig.presented, ["提示框", "确认框"])

        var trackedWhenShown: Bool?
        rig.runtime.showPopupWindow = { [unowned rig] in
            rig.shownPopups.append($0)
            trackedWhenShown = rig.runtime.tracksPopupForTesting($0)
        }
        let child = rig.runtime.webView(web, createWebViewWith: WKWebViewConfiguration(), for: c.load,
                                        windowFeatures: WKWindowFeatures())
        XCTAssertNotNil(child)
        XCTAssertEqual(rig.shownPopups.count, 1)
        XCTAssertEqual(trackedWhenShown, true, "显示之前已经记下")
        XCTAssertTrue(rig.runtime.tracksPopupForTesting(window))
        rig.runtime.close()
        XCTAssertFalse(rig.shownPopups.contains { rig.runtime.tracksPopupForTesting($0) })
    }
}

/// capture() 拿到的东西。拿它们的网页视图和代理跟着它（keep），用到这些东西时还在。
private struct Captured {
    let load: WKNavigationAction
    let frame: WKFrameInfo
    let response: WKNavigationResponse
    let link: WKNavigationAction
    let parameters: WKOpenPanelParameters
    let keep: [AnyObject]
}

/// 记下打开页面的导航动作和响应（放行）、点链接的导航动作（取消：不联网）、文件选择参数（回答 nil）。新窗口都不给。
@MainActor
private final class Catcher: NSObject, WKNavigationDelegate, WKUIDelegate {
    var load: WKNavigationAction?
    var response: WKNavigationResponse?
    var link: WKNavigationAction?
    var parameters: WKOpenPanelParameters?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if load == nil {
            load = navigationAction
            return .allow
        }
        link = navigationAction
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response = navigationResponse
        return .allow
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        self.parameters = parameters
        return nil
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}
