import Foundation
import Testing
@testable import CompanionCore

/// 2026-11-11 白屏：开机登录时网络还没连上，首次加载 -1009 失败，之后再也没有加载。
@Suite struct LoadRecoveryTests {
    let chat = URL(string: "https://chatgpt.com/c/abc")!
    let home = URL(string: "https://chatgpt.com/")!
    let backoff: [TimeInterval] = [2, 5, 15]

    /// 首次加载失败（没有页面），网络类错误。
    func failedFirstLoad(_ r: inout LoadRecovery, code: Int = -1009) -> LoadRecovery.Action {
        r.loadFailed(url: chat, domain: NSURLErrorDomain, code: code, hasPage: false)
    }

    @Test func networkErrorsAreRecognised() {
        for code in [-1009, -1001, -1003, -1004, -1005, -1006, -1018, -1020] {
            #expect(LoadRecovery.isNetworkError(domain: NSURLErrorDomain, code: code), "code \(code)")
        }
        #expect(!LoadRecovery.isNetworkError(domain: NSURLErrorDomain, code: -1202), "证书错误不自动重试")
        #expect(!LoadRecovery.isNetworkError(domain: NSURLErrorDomain, code: -999))
        #expect(!LoadRecovery.isNetworkError(domain: "WebKitErrorDomain", code: -1009))
    }

    @Test func firstLoadNetworkFailureSchedulesTheFirstBackoff() {
        var r = LoadRecovery(backoff: backoff)
        #expect(failedFirstLoad(&r) == .schedule(after: 2))
        #expect(r.failedURL == chat)
        #expect(r.status == .waiting)
    }

    @Test func timerRetriesTheFailedURLNotHome() {
        var r = LoadRecovery(backoff: backoff)
        _ = failedFirstLoad(&r)
        #expect(r.retryTimerFired() == .retry(chat))
        #expect(r.status == .connecting)
    }

    @Test func backoffGrowsWithEachFailedRetry() {
        var r = LoadRecovery(backoff: backoff)
        #expect(failedFirstLoad(&r) == .schedule(after: 2))
        _ = r.retryTimerFired()
        #expect(failedFirstLoad(&r) == .schedule(after: 5))
        _ = r.retryTimerFired()
        #expect(failedFirstLoad(&r) == .schedule(after: 15))
    }

    @Test func automaticRetriesStopAtTheLimit() {
        var r = LoadRecovery(backoff: backoff)
        _ = failedFirstLoad(&r)
        for _ in backoff {
            #expect(r.retryTimerFired() == .retry(chat))
            _ = failedFirstLoad(&r)
        }
        #expect(r.status == .stopped)
        #expect(r.retryTimerFired() == .none)
        #expect(r.networkChanged(online: false) == .none)
        #expect(r.networkChanged(online: true) == .none, "用完次数后网络恢复也不再自动请求")
        #expect(r.windowShown() == .none)
        #expect(r.failedURL == chat, "失败地址留给 ⌘R")
    }

    @Test func noRequestWhileOffline() {
        var r = LoadRecovery(backoff: backoff)
        #expect(r.networkChanged(online: false) == .none)
        #expect(failedFirstLoad(&r) == .none, "断网时不排定时器")
        #expect(r.retryTimerFired() == .none)
        #expect(r.windowShown() == .none)
        #expect(r.status == .waiting)
    }

    @Test func timerFiringWhileOfflineDoesNotSpendAnAttempt() {
        var r = LoadRecovery(backoff: backoff)
        _ = failedFirstLoad(&r)
        _ = r.networkChanged(online: false)
        #expect(r.retryTimerFired() == .none)
        #expect(r.networkChanged(online: true) == .retry(chat))
        #expect(failedFirstLoad(&r) == .schedule(after: 5), "只用掉一次")
    }

    @Test func comingBackOnlineRetriesAtOnce() {
        var r = LoadRecovery(backoff: backoff)
        _ = r.networkChanged(online: false)
        _ = failedFirstLoad(&r)
        #expect(r.networkChanged(online: true) == .retry(chat))
        #expect(r.networkChanged(online: true) == .none, "已经在线的重复通知不算恢复")
    }

    @Test func onlyOneRetryInFlight() {
        var r = LoadRecovery(backoff: backoff)
        _ = failedFirstLoad(&r)
        _ = r.networkChanged(online: false)
        #expect(r.networkChanged(online: true) == .retry(chat))
        #expect(r.retryTimerFired() == .none, "上一次重试还没有结果")
        #expect(r.windowShown() == .none)
    }

    @Test func wakingTheWindowRetriesOnceAndCountsAsAnAttempt() {
        var r = LoadRecovery(backoff: backoff)
        _ = failedFirstLoad(&r)
        #expect(r.windowShown() == .retry(chat))
        #expect(failedFirstLoad(&r) == .schedule(after: 5))
    }

    @Test func successClearsEverything() {
        var r = LoadRecovery(backoff: backoff)
        _ = failedFirstLoad(&r)
        _ = r.retryTimerFired()
        r.loadSucceeded()
        #expect(r.failedURL == nil)
        #expect(r.status == .hidden)
        #expect(r.retryTimerFired() == .none)
        #expect(r.manualReload() == nil, "有页面时 ⌘R 走普通重新加载")
        #expect(failedFirstLoad(&r) == .schedule(after: 2), "成功后次数重新计算")
    }

    @Test func manualReloadLoadsTheFailedURLAndRestoresTheBudget() {
        var r = LoadRecovery(backoff: backoff)
        _ = failedFirstLoad(&r)
        for _ in backoff {
            _ = r.retryTimerFired()
            _ = failedFirstLoad(&r)
        }
        #expect(r.status == .stopped)
        #expect(r.manualReload() == chat)
        #expect(r.status == .connecting)
        #expect(failedFirstLoad(&r) == .schedule(after: 2))
    }

    @Test func manualReloadWorksForNonNetworkFailuresToo() {
        var r = LoadRecovery(backoff: backoff)
        #expect(r.loadFailed(url: chat, domain: NSURLErrorDomain, code: -1202, hasPage: false) == .none)
        #expect(r.status == .stopped)
        #expect(r.retryTimerFired() == .none)
        #expect(r.manualReload() == chat)
    }

    @Test func failureWithAPageOnScreenNeverRetriesAutomatically() {
        var r = LoadRecovery(backoff: backoff)
        #expect(r.loadFailed(url: home, domain: NSURLErrorDomain, code: -1009, hasPage: true) == .none)
        #expect(r.status == .hidden, "页面还在，不盖提示")
        #expect(r.retryTimerFired() == .none)
        #expect(r.networkChanged(online: false) == .none)
        #expect(r.networkChanged(online: true) == .none)
        #expect(r.manualReload() == nil, "页面还在：⌘R 重新加载眼前的页面，不跳到之前失败的地址")
    }

    @Test func pageOnScreenClearsAnEarlierBlankFailure() {
        var r = LoadRecovery(backoff: backoff)
        _ = failedFirstLoad(&r)
        _ = r.loadFailed(url: home, domain: NSURLErrorDomain, code: -1009, hasPage: true)
        #expect(r.failedURL == nil)
        #expect(r.retryTimerFired() == .none)
    }

    @Test func missingFailingURLKeepsThePreviousOne() {
        var r = LoadRecovery(backoff: backoff)
        _ = failedFirstLoad(&r)
        _ = r.retryTimerFired()
        _ = r.loadFailed(url: nil, domain: NSURLErrorDomain, code: -1009, hasPage: false)
        #expect(r.failedURL == chat)
    }

    @Test func failureWithoutAnyURLFallsBackToHome() {
        var r = LoadRecovery(backoff: backoff)
        #expect(r.loadFailed(url: nil, domain: NSURLErrorDomain, code: -1009, hasPage: false) == .schedule(after: 2))
        #expect(r.failedURL == home, "窗口空白又不知道失败地址：回首页，不留白屏")
        #expect(r.status == .waiting)
    }

    /// 重试和 ⌘R 不越过导航边界：只加载应用内本来就允许的 https 地址（ChatGPT 和登录页）。
    @Test func retriesNeverLoadADisallowedURL() {
        let disallowed = ["https://example.com/x", "http://chatgpt.com/c/abc", "file:///etc/hosts",
                          "javascript:alert(1)", "data:text/html,hi", "about:blank"]
        for string in disallowed {
            var r = LoadRecovery(backoff: backoff)
            _ = r.loadFailed(url: URL(string: string)!, domain: NSURLErrorDomain, code: -1009, hasPage: false)
            #expect(r.failedURL == home, "\(string)")
            #expect(r.retryTimerFired() == .retry(home), "\(string)")
        }
        var r = LoadRecovery(backoff: backoff)
        _ = failedFirstLoad(&r)
        _ = r.loadFailed(url: URL(string: "https://example.com/x")!, domain: NSURLErrorDomain, code: -1009, hasPage: false)
        #expect(r.failedURL == chat, "不允许的地址不覆盖之前的失败地址")
        #expect(r.manualReload() == chat)
    }

    @Test func loginPagesAreRetriedInPlace() {
        var r = LoadRecovery(backoff: backoff)
        let login = URL(string: "https://auth.openai.com/log-in")!
        _ = r.loadFailed(url: login, domain: NSURLErrorDomain, code: -1009, hasPage: false)
        #expect(r.failedURL == login)
    }

    /// 重试被取消（例如框架中断），之后没有别的加载：不能一直停在“正在重新连接”，也不算一次失败。
    @Test func cancelledRetryWithNothingElseLoadingResumesWaiting() {
        var r = LoadRecovery(backoff: backoff)
        _ = failedFirstLoad(&r)
        #expect(r.retryTimerFired() == .retry(chat))
        #expect(r.navigationCancelled() == .schedule(after: 5))
        #expect(r.status == .waiting)
        #expect(r.failedURL == chat)
        #expect(r.retryTimerFired() == .retry(chat))
    }

    @Test func cancelledManualReloadAfterTheLimitStaysStopped() {
        var r = LoadRecovery(backoff: backoff)
        #expect(r.loadFailed(url: chat, domain: NSURLErrorDomain, code: -1202, hasPage: false) == .none)
        #expect(r.manualReload() == chat)
        #expect(r.navigationCancelled() == .none)
        #expect(r.status == .stopped)
    }

    @Test func cancelledRetryWhileOfflineWaitsForTheNetwork() {
        var r = LoadRecovery(backoff: backoff)
        _ = failedFirstLoad(&r)
        _ = r.retryTimerFired()
        _ = r.networkChanged(online: false)
        #expect(r.navigationCancelled() == .none)
        #expect(r.status == .waiting)
        #expect(r.networkChanged(online: true) == .retry(chat))
    }

    @Test func cancelWithoutAProblemDoesNothing() {
        var r = LoadRecovery(backoff: backoff)
        #expect(r.navigationCancelled() == .none)
        r.navigationStarted()
        #expect(r.navigationCancelled() == .none)
        #expect(r.status == .hidden)
        #expect(r.manualReload() == nil)
    }

    @Test func navigationStartMarksALoadInFlight() {
        var r = LoadRecovery(backoff: backoff)
        _ = failedFirstLoad(&r)
        r.navigationStarted()
        #expect(r.status == .connecting)
        #expect(r.retryTimerFired() == .none, "用户自己点的加载还没有结果")
    }

    @Test func defaultBackoffIsBoundedAndIncreasing() {
        let d = LoadRecovery.defaultBackoff
        #expect(d.count <= 6)
        #expect(d == d.sorted())
        #expect((d.first ?? 0) >= 1)
        #expect((d.last ?? 0) <= 120)
    }
}
