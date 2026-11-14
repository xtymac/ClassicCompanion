import AppKit
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 2026-11-11 白屏：开机时首次加载 -1009 失败后，窗口一直空白，⌘R 也救不回来。
/// 不开窗口、不联网：直接调导航代理模拟失败，加载请求由 `loadRequest` 记录下来。
@MainActor
final class LoadRecoveryWebTests: XCTestCase {
    let chat = URL(string: "https://chatgpt.com/c/abc")!
    var loaded: [URL] = []

    private func makeRuntime(backoff: [TimeInterval] = [60]) -> WebRuntime {
        let name = "LoadRecoveryWebTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let web = WebRuntime(diagnostics: Diagnostics(), settings: AppSettings(defaults: UserDefaults(suiteName: name)!),
                             recovery: LoadRecovery(backoff: backoff), watchesNetwork: false)
        web.loadRequest = { [unowned self] request in self.loaded.append(request.url!) }
        return web
    }

    private func failFirstLoad(_ web: WebRuntime, code: Int = NSURLErrorNotConnectedToInternet) {
        let error = NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSURLErrorFailingURLErrorKey: chat])
        web.webView(web.webView, didFailProvisionalNavigation: nil, withError: error)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testReloadAfterAFailedFirstLoadExplicitlyLoadsTheFailedURL() {
        let web = makeRuntime()
        failFirstLoad(web)
        XCTAssertNil(web.webView.url, "首次加载失败后没有页面")
        web.reload()
        XCTAssertEqual(loaded, [chat])
    }

    func testFailedFirstLoadShowsTheProblem() {
        let web = makeRuntime()
        var seen: [LoadRecovery.Status] = []
        web.onLoadProblemChange = { seen.append($0) }
        failFirstLoad(web)
        XCTAssertEqual(web.loadProblem, .waiting)
        XCTAssertEqual(seen, [.waiting])
    }

    func testRetriesTheFailedURLAfterTheBackoff() {
        let web = makeRuntime(backoff: [0.05])
        failFirstLoad(web)
        XCTAssertEqual(loaded, [], "不立刻重试")
        spin(0.4)
        XCTAssertEqual(loaded, [chat])
        XCTAssertEqual(web.loadProblem, .connecting)
    }

    func testStopsAfterTheLimit() {
        let web = makeRuntime(backoff: [0.02, 0.02])
        failFirstLoad(web)
        spin(0.2)
        failFirstLoad(web)
        spin(0.2)
        failFirstLoad(web)
        spin(0.2)
        XCTAssertEqual(loaded, [chat, chat])
        XCTAssertEqual(web.loadProblem, .stopped)
    }

    func testNoRequestWhileOfflineAndRetryWhenBack() {
        let web = makeRuntime(backoff: [0.02])
        web.networkChanged(online: false)
        failFirstLoad(web)
        spin(0.2)
        XCTAssertEqual(loaded, [])
        web.networkChanged(online: true)
        XCTAssertEqual(loaded, [chat])
    }

    func testComingBackOnlineCancelsTheTimer() {
        let web = makeRuntime(backoff: [0.1, 60])
        failFirstLoad(web)
        web.networkChanged(online: false)
        web.networkChanged(online: true)
        XCTAssertEqual(loaded, [chat])
        failFirstLoad(web)
        spin(0.3)
        XCTAssertEqual(loaded, [chat], "旧定时器不再触发；下一次要等 60 秒")
    }

    func testShowingTheWindowRetries() {
        let web = makeRuntime()
        failFirstLoad(web)
        web.windowShown()
        XCTAssertEqual(loaded, [chat])
    }

    /// 切换小窗／完整窗口不是唤醒，不提前重试，免得来回切几次就把次数用完。
    func testSwitchingModesDoesNotSpendARetry() {
        let web = makeRuntime()
        failFirstLoad(web)
        web.windowShown(.modeSwitch)
        XCTAssertEqual(loaded, [])
        XCTAssertEqual(web.loadProblem, .waiting)
        web.windowShown(.activate)
        XCTAssertEqual(loaded, [chat], "已可见窗口被重新叫到前面，算用户回来")
    }

    func testWakingFromHiddenRetries() {
        let web = makeRuntime()
        failFirstLoad(web)
        web.windowShown(.wake)
        XCTAssertEqual(loaded, [chat])
        XCTAssertEqual(web.loadProblem, .connecting)
    }

    /// 重试被取消、之后没有别的加载：恢复等待并重新排定时器，不一直显示“正在重新连接”。
    func testCancelledRetryResumesWaiting() {
        let web = makeRuntime(backoff: [0.05, 0.05])
        failFirstLoad(web)
        web.reload()
        XCTAssertEqual(loaded, [chat])
        XCTAssertEqual(web.loadProblem, .connecting)
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [NSURLErrorFailingURLErrorKey: chat])
        web.webView(web.webView, didFailProvisionalNavigation: nil, withError: cancelled)
        XCTAssertEqual(web.loadProblem, .waiting)
        spin(0.4)
        XCTAssertEqual(loaded, [chat, chat])
    }

    func testFrameLoadInterruptedIsTreatedAsACancel() {
        let web = makeRuntime(backoff: [60])
        failFirstLoad(web)
        web.reload()
        let interrupted = NSError(domain: "WebKitErrorDomain", code: 102)
        web.webView(web.webView, didFailProvisionalNavigation: nil, withError: interrupted)
        XCTAssertEqual(web.loadProblem, .waiting)
        XCTAssertEqual(loaded, [chat])
    }

    /// 首次加载还没完成时按 ⌘R：窗口里没有页面，stopLoading + reload() 什么都不会加载，要显式重新加载请求的地址。
    func testReloadDuringTheFirstLoadRestartsIt() {
        let web = makeRuntime()
        web.load(chat)
        XCTAssertEqual(loaded, [chat])
        web.reload()
        XCTAssertEqual(loaded, [chat, chat])
    }

    /// 首次加载被取消、之后什么都没在加载：⌘R 仍能救回来。
    func testReloadAfterACancelledFirstLoadLoadsItAgain() {
        let web = makeRuntime()
        web.load(chat)
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [NSURLErrorFailingURLErrorKey: chat])
        web.webView(web.webView, didFailProvisionalNavigation: nil, withError: cancelled)
        XCTAssertEqual(web.loadProblem, .hidden, "取消不算加载故障")
        web.reload()
        XCTAssertEqual(loaded, [chat, chat])
    }

    /// 被更新的加载顶掉的取消（-999 到达时 WebKit 仍在加载）：交给新的加载，不改状态、不排定时器。
    func testCancelSupersededByANewerLoadIsIgnored() {
        let web = makeRuntime(backoff: [0.05, 0.05])
        web.mainFrameIsLoading = { true }
        failFirstLoad(web)
        web.reload()
        XCTAssertEqual(web.loadProblem, .connecting)
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [NSURLErrorFailingURLErrorKey: chat])
        web.webView(web.webView, didFailProvisionalNavigation: nil, withError: cancelled)
        XCTAssertEqual(web.loadProblem, .connecting)
        spin(0.3)
        XCTAssertEqual(loaded, [chat], "没有排新的定时器")
    }

    /// 页面已经提交过：之后的失败不盖提示，⌘R 重新加载眼前的页面（不靠 webView.url 判断）。
    func testFailureAfterACommittedPageKeepsThePage() {
        let web = makeRuntime()
        web.load(chat)
        web.webView(web.webView, didCommit: nil)
        failFirstLoad(web)
        XCTAssertEqual(web.loadProblem, .hidden)
        web.reload()
        XCTAssertEqual(loaded, [chat], "有页面时走普通重新加载")
    }

    /// 重试的地址不越过导航边界：错误里的失败地址不是应用内允许的 https 页面时，不去加载它。
    func testRetryNeverLoadsADisallowedFailingURL() {
        let web = makeRuntime()
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://example.com/phish")!])
        web.webView(web.webView, didFailProvisionalNavigation: nil, withError: error)
        XCTAssertEqual(web.loadProblem, .waiting)
        web.reload()
        XCTAssertEqual(loaded, [WebRuntime.homeURL])
    }

    /// 页面一提交就收起提示、取消定时器，不用等整页加载完。
    func testCommittedPageHidesTheProblemAndCancelsTheTimer() {
        let web = makeRuntime(backoff: [0.05])
        failFirstLoad(web)
        web.webView(web.webView, didCommit: nil)
        XCTAssertEqual(web.loadProblem, .hidden)
        spin(0.3)
        XCTAssertEqual(loaded, [], "旧定时器已取消")
    }

    func testSuccessfulLoadHidesTheProblem() {
        let web = makeRuntime()
        failFirstLoad(web)
        web.webView(web.webView, didFinish: nil)
        XCTAssertEqual(web.loadProblem, .hidden)
    }

    /// 提交时先通知窗口“提交了”，再发“提示可以收起”：窗口据此把提示留到加载完成（2026-11-15 空白白屏）。
    func testTheCommitIsReportedBeforeTheProblemIsCleared() {
        let web = makeRuntime()
        var events: [String] = []
        web.onLoadProblemChange = { events.append("problem \($0)") }
        web.onMainFrameCommitted = { events.append("commit") }
        failFirstLoad(web)
        web.webView(web.webView, didCommit: nil)
        XCTAssertEqual(events, ["problem waiting", "commit", "problem hidden"])
    }

    func testCancelledLoadIsNotAProblem() {
        let web = makeRuntime()
        failFirstLoad(web, code: NSURLErrorCancelled)
        XCTAssertEqual(web.loadProblem, .hidden)
        web.reload()
        XCTAssertEqual(loaded, [], "没有失败地址时走普通重新加载")
    }

    /// 1159 的窗口测试：小窗该是 720 高，却变成 858/866。提示的 NSHostingView 默认把 SwiftUI 的最小尺寸变成约束，
    /// 藏起来也照样生效：长文字挤窄后折成很多行，最小高度把窗口撑高。提示不能影响窗口能设的大小（最小 480×360）。
    func testProblemMessageNeverForcesTheWindowBigger() {
        let controller = ChatWindowController(webView: WKWebView(), toolbar: EmptyView(), diagnostics: Diagnostics())
        let content = controller.window!.contentView!
        for status: LoadRecovery.Status in [.hidden, .waiting, .connecting, .stopped] {
            controller.showLoadProblem(status)
            content.layoutSubtreeIfNeeded()
            let fitting = content.fittingSize
            XCTAssertLessThanOrEqual(fitting.height, 360, "\(status) 最小高度 \(fitting.height)")
            XCTAssertLessThanOrEqual(fitting.width, 480, "\(status) 最小宽度 \(fitting.width)")
        }
    }

    func testWindowCoversTheBlankPageWithTheProblem() {
        let controller = ChatWindowController(webView: WKWebView(), toolbar: EmptyView(), diagnostics: Diagnostics())
        XCTAssertNil(controller.shownLoadProblem)
        controller.showLoadProblem(.waiting)
        XCTAssertEqual(controller.shownLoadProblem, .waiting)
        controller.showLoadProblem(.stopped)
        XCTAssertEqual(controller.shownLoadProblem, .stopped)
        controller.showLoadProblem(.hidden)
        XCTAssertNil(controller.shownLoadProblem)
    }
}
