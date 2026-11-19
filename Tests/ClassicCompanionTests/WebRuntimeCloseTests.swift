import AppKit
import Foundation
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 网页运行时的关闭（WebRuntime.close()）：先进入关闭态，之后运行时自己不再发起任何加载（定时重试、网络变化、窗口显示后、
/// 内容进程终止后的重新加载、⌘R、新对话），网页的导航事件不再改它的状态、不再转出去；回调断开，弹窗关掉；关两遍安全。
/// 不开窗口、不联网：加载请求由 loadRequest 记下来，导航事件像 LoadRecoveryWebTests 一样直接调导航代理。
/// 每条都有一个没关闭的对照：同样的步骤会加载（或写日志），说明这里看到的“没有”是关闭带来的。
/// 日志只看关闭之后的：关闭写一行“关闭网页…”，之后什么都不写。
@MainActor
final class WebRuntimeCloseTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!

    @MainActor
    private final class Loads {
        var urls: [URL] = []
    }

    /// 一个运行时、它自己的日志和发出的加载请求。
    @MainActor
    private struct Runtime {
        let web: WebRuntime
        let loads: Loads
        let diagnostics: Diagnostics
        var lines: [String] { diagnostics.entries.map { "[\($0.category)] \($0.message)" } }
    }

    /// `offline: true`：运行时一开始就当作断网（恢复规则里的状态）。
    private func makeRuntime(backoff: [TimeInterval] = [60], offline: Bool = false) -> Runtime {
        let name = "WebRuntimeCloseTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        var recovery = LoadRecovery(backoff: backoff)
        if offline { _ = recovery.networkChanged(online: false) }
        let diagnostics = Diagnostics()
        let web = WebRuntime(diagnostics: diagnostics, settings: AppSettings(defaults: UserDefaults(suiteName: name)!),
                             recovery: recovery, watchesNetwork: false)
        let loads = Loads()
        web.loadRequest = { request in loads.urls.append(request.url!) }
        return Runtime(web: web, loads: loads, diagnostics: diagnostics)
    }

    private func fail(_ web: WebRuntime, code: Int = NSURLErrorNotConnectedToInternet) {
        let error = NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSURLErrorFailingURLErrorKey: chat])
        web.webView(web.webView, didFailProvisionalNavigation: nil, withError: error)
    }

    /// 第一次加载失败、窗口里没有页面、在等自动重试（提示“等待重试”）。
    private func makeWaiting(backoff: [TimeInterval] = [60], offline: Bool = false) -> Runtime {
        let r = makeRuntime(backoff: backoff, offline: offline)
        r.web.load(chat)
        fail(r.web)
        XCTAssertEqual(r.web.loadProblem, .waiting)
        XCTAssertEqual(r.loads.urls, [chat])
        return r
    }

    /// 关闭，返回关闭之后（含关闭那一行）日志的起点。
    private func close(_ r: Runtime) -> Int {
        let mark = r.diagnostics.entries.count
        r.web.close()
        XCTAssertTrue(r.web.isClosed)
        return mark
    }

    private func lines(_ r: Runtime, since mark: Int) -> [String] {
        Array(r.lines.dropFirst(mark))
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - 定时重试

    /// 首次加载失败（在线）已经排了定时重试：关闭时取消，到点不加载、不写日志，提示停在关闭时的样子。
    /// 对照：不关闭时定时器到点重试（NetworkStatusTests.testRemovingDoesNotCancelARetryTheRuntimeHasAlreadyArmed 只注销不关闭，也重试）。
    func testClosingCancelsAnArmedRetryAndItNeverFires() {
        let control = makeWaiting(backoff: [0.05])
        let r = makeWaiting(backoff: [0.05])
        XCTAssertTrue(r.web.hasScheduledRetry)
        let mark = close(r)
        XCTAssertFalse(r.web.hasScheduledRetry, "关闭时取消排着的重试")
        spin(0.3)
        XCTAssertEqual(r.loads.urls, [chat], "关闭以后定时器不加载")
        XCTAssertEqual(r.web.loadProblem, .waiting)
        XCTAssertEqual(lines(r, since: mark), ["[web] 关闭网页：停止加载，取消排着的自动重试"])
        XCTAssertEqual(control.loads.urls, [chat, chat], "对照：不关闭时到点重试")
    }

    // MARK: - 网络变化

    /// 断网时首次加载失败、在等网络恢复。关闭以后网络恢复（直接送到运行时，不经共用的网络状态）：不重试、不记日志。
    func testANetworkComebackAfterCloseDoesNotLoad() {
        let control = makeWaiting(offline: true)
        let r = makeWaiting(offline: true)
        XCTAssertFalse(r.web.hasScheduledRetry, "断网期间不排定时器")
        let mark = close(r)
        r.web.networkChanged(online: true)
        r.web.networkChanged(online: false)
        r.web.networkChanged(online: true)
        XCTAssertEqual(r.loads.urls, [chat])
        XCTAssertEqual(lines(r, since: mark), ["[web] 关闭网页：停止加载"], "关闭以后网络变化不记、不重试")
        control.web.networkChanged(online: true)
        XCTAssertEqual(control.loads.urls, [chat, chat], "对照：不关闭时网络恢复重试")
    }

    // MARK: - 窗口显示后

    /// 在等重试。关闭以后窗口显示（唤醒、叫到前面）：不提前重试，不写日志，不排定时器。
    func testWindowShownAfterCloseDoesNotLoad() {
        let control = makeWaiting()
        let r = makeWaiting()
        let mark = close(r)
        r.web.windowShown(.wake)
        r.web.windowShown(.activate)
        XCTAssertEqual(r.loads.urls, [chat])
        XCTAssertFalse(r.web.hasScheduledRetry)
        XCTAssertEqual(r.web.loadProblem, .waiting)
        XCTAssertEqual(lines(r, since: mark), ["[web] 关闭网页：停止加载，取消排着的自动重试"])
        control.web.windowShown(.wake)
        XCTAssertEqual(control.loads.urls, [chat, chat], "对照：不关闭时提前重试")
    }

    // MARK: - ⌘R 和内容进程终止

    /// 关闭以后 ⌘R（有失败地址时会显式加载它）和网页内容进程终止（会走 reload）：不加载、不写日志、提示不变。
    /// 首次加载还没提交时 reload 会重新加载请求的地址：关闭以后也不。
    func testReloadAndContentProcessTerminationAfterCloseDoNotLoad() {
        let control = makeWaiting()
        let failed = makeWaiting()
        let firstLoad = makeRuntime()
        firstLoad.web.load(chat)
        firstLoad.web.webView(firstLoad.web.webView, didStartProvisionalNavigation: nil)
        let closing = [(failed, close(failed), "[web] 关闭网页：停止加载，取消排着的自动重试"),
                       (firstLoad, close(firstLoad), "[web] 关闭网页：停止加载")]
        for (r, mark, closeLine) in closing {
            r.web.reload()
            r.web.webViewWebContentProcessDidTerminate(r.web.webView)
            XCTAssertEqual(r.loads.urls, [chat], "关闭以后不重新加载")
            XCTAssertEqual(lines(r, since: mark), [closeLine])
        }
        XCTAssertEqual(failed.web.loadProblem, .waiting)
        control.web.reload()
        control.web.webViewWebContentProcessDidTerminate(control.web.webView)
        XCTAssertEqual(control.loads.urls, [chat, chat, chat], "对照：不关闭时两次都加载失败的地址")
    }

    // MARK: - 直接加载

    /// 关闭以后直接要求加载（新对话、加载某个地址）：什么都不发。
    func testDirectLoadsAfterCloseAreRefused() {
        let r = makeRuntime()
        let mark = close(r)
        r.web.load(chat)
        r.web.newChat()
        XCTAssertEqual(r.loads.urls, [])
        XCTAssertEqual(lines(r, since: mark), ["[web] 关闭网页：停止加载"])
    }

    // MARK: - 晚到的导航事件

    /// 在等重试时关闭，之后网页的导航事件晚到（开始、提交、加载完成、网络失败、取消）：恢复状态和提示都不变、不排定时器、
    /// 不加载、不写日志，回调（已断开）一次都没被调用。过一会儿（加载完成后的自检、可能排下的重试）也什么都没有。
    func testLateNavigationEventsAfterCloseAreIgnored() {
        let r = makeWaiting(backoff: [0.05, 0.05])
        r.web.webViewWebContentProcessDidTerminate(r.web.webView)
        XCTAssertEqual(r.web.loadProblem, .connecting, "重新加载失败的地址，正在连接")
        var called: [String] = []
        r.web.onURLChange = { _ in called.append("地址") }
        r.web.onMainFrameLoaded = { called.append("加载完成") }
        r.web.onMainFrameCommitted = { called.append("提交") }
        r.web.onLoadFailed = { called.append("失败") }
        r.web.onEscapeRequest = { called.append("Esc") }
        r.web.onLoadProblemChange = { called.append("提示 \($0)") }
        fail(r.web)
        XCTAssertEqual(called, ["提示 waiting", "失败"], "关闭之前照常转出去")
        called = []
        let mark = close(r)
        let web = r.web.webView
        r.web.webView(web, didStartProvisionalNavigation: nil)
        XCTAssertEqual(r.web.loadProblem, .waiting, "开始导航不改提示")
        r.web.webView(web, didCommit: nil)
        XCTAssertEqual(r.web.loadProblem, .waiting, "提交不改提示")
        r.web.webView(web, didFinish: nil)
        fail(r.web)
        fail(r.web, code: NSURLErrorCancelled)
        r.web.webView(web, didFail: nil, withError: NSError(domain: "WebKitErrorDomain", code: 102))
        XCTAssertEqual(r.web.loadProblem, .waiting)
        XCTAssertFalse(r.web.hasScheduledRetry, "失败、取消都不排重试")
        spin(0.3)
        XCTAssertEqual(r.loads.urls, [chat, chat])
        XCTAssertEqual(called, [])
        XCTAssertEqual(lines(r, since: mark), ["[web] 关闭网页：停止加载，取消排着的自动重试"])
    }

    /// 加载完成后 3 秒的渲染自检：到点时已经关闭就不做（不跑网页脚本、不写日志）。对照：不关闭的照常写一行 [render]。
    func testTheRenderSelfCheckDoesNotRunAfterClose() {
        let control = makeRuntime()
        let r = makeRuntime()
        for runtime in [control, r] {
            runtime.web.load(chat)
            runtime.web.webView(runtime.web.webView, didCommit: nil)
            runtime.web.webView(runtime.web.webView, didFinish: nil)
        }
        let mark = close(r)
        let deadline = Date().addingTimeInterval(6)
        while !control.lines.contains(where: { $0.hasPrefix("[render]") }), Date() < deadline { spin(0.05) }
        XCTAssertTrue(control.lines.contains { $0.hasPrefix("[render] 自检") }, "对照：不关闭的照常自检")
        spin(0.2)
        XCTAssertFalse(lines(r, since: mark).contains { $0.hasPrefix("[render]") }, "关闭以后不自检")
    }

    // MARK: - 回调、弹窗、关两遍

    /// 关闭时断开全部回调：接线的闭包（它们持有页面状态）不再被运行时持有。
    func testClosingDetachesEveryCallback() {
        let r = makeRuntime()
        r.web.onURLChange = { _ in }
        r.web.onMainFrameLoaded = {}
        r.web.onMainFrameCommitted = {}
        r.web.onLoadFailed = {}
        r.web.onEscapeRequest = {}
        r.web.onLoadProblemChange = { _ in }
        r.web.close()
        XCTAssertNil(r.web.onURLChange)
        XCTAssertNil(r.web.onMainFrameLoaded)
        XCTAssertNil(r.web.onMainFrameCommitted)
        XCTAssertNil(r.web.onLoadFailed)
        XCTAssertNil(r.web.onEscapeRequest)
        XCTAssertNil(r.web.onLoadProblemChange)
    }

    /// 这个页面开着的弹窗在关闭时关掉，之后改界面语言也不再碰它（运行时不再记着它）。日志写关掉了几个。
    func testClosingClosesThePagesPopups() {
        let r = makeRuntime()
        let popup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: true)
        popup.isReleasedWhenClosed = false
        popup.title = "旧标题"
        r.web.adoptPopupForTesting(popup)
        var closed = 0
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: popup,
                                                           queue: nil) { _ in closed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let mark = close(r)
        XCTAssertEqual(closed, 1, "弹窗关掉了")
        r.web.retitlePopups()
        XCTAssertEqual(popup.title, "旧标题", "运行时不再记着它")
        r.web.close()
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(lines(r, since: mark), ["[web] 关闭网页：停止加载，关掉 1 个弹窗"])
    }

    /// 关两遍：第二遍什么都不做（不再写日志、状态不变）。之后的事件照样不理。
    func testClosingTwiceIsHarmless() {
        let r = makeWaiting(backoff: [0.05])
        let mark = close(r)
        r.web.close()
        XCTAssertTrue(r.web.isClosed)
        XCTAssertFalse(r.web.hasScheduledRetry)
        r.web.windowShown(.wake)
        r.web.networkChanged(online: true)
        spin(0.2)
        XCTAssertEqual(r.loads.urls, [chat])
        XCTAssertEqual(lines(r, since: mark), ["[web] 关闭网页：停止加载，取消排着的自动重试"])
    }

    // MARK: - 网页自己发起的导航（真的 WebKit，不联网）

    /// 关闭以后网页自己发起的导航（这里用 loadHTMLString 代替：不经过 load，直接让网页视图导航）被导航策略拒绝，页面不提交。
    /// 对照：没关闭的运行时同样的导航照常提交（地址变成那个地址）。只用本地 HTML，不联网。
    func testAClosedPageCannotNavigateOnItsOwn() {
        let control = makeRuntime()
        let r = makeRuntime()
        let mark = close(r)
        let html = "<html><body>x</body></html>"
        control.web.webView.loadHTMLString(html, baseURL: chat)
        r.web.webView.loadHTMLString(html, baseURL: chat)
        let deadline = Date().addingTimeInterval(10)
        while control.web.webView.url != chat || control.web.webView.isLoading, Date() < deadline { spin(0.05) }
        XCTAssertEqual(control.web.webView.url, chat, "对照：没关闭的照常导航")
        let settle = Date().addingTimeInterval(1)
        while r.web.webView.isLoading, Date() < settle { spin(0.05) }
        spin(0.3)
        XCTAssertNil(r.web.webView.url, "关闭以后网页自己导航被拒绝，页面不提交")
        XCTAssertFalse(r.web.webView.isLoading)
        XCTAssertEqual(r.loads.urls, [])
        XCTAssertEqual(lines(r, since: mark), ["[web] 关闭网页：停止加载"])
    }
}
