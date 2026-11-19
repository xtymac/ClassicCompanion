import Foundation
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 全应用共用的网络监视（NetworkStatus）只通知，重试与否由每个页面自己的恢复规则决定。
/// 不开窗口、不联网、不开真实监视：状态由 `deliver(online:)` 送入，加载请求由 `loadRequest` 记下来。
@MainActor
final class NetworkStatusTests: XCTestCase {
    let chat = URL(string: "https://chatgpt.com/c/abc")!

    /// 每个运行时各记各的加载请求。
    @MainActor
    private final class Loads {
        var urls: [URL] = []
    }

    @MainActor
    private struct Runtime {
        let web: WebRuntime
        let loads: Loads
        let diagnostics: Diagnostics
        /// 运行时记下的网络日志（“网络可用”“网络不可用”）。只在它眼里的状态变化时才记。
        var netLog: [String] { diagnostics.entries.filter { $0.category == "net" }.map(\.message) }
    }

    /// `offline: true`：运行时一开始就当作断网（恢复规则里的状态），用来看见补发的“在线”。
    private func makeRuntime(backoff: [TimeInterval] = [60], offline: Bool = false) -> Runtime {
        let name = "NetworkStatusTests.\(UUID().uuidString)"
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

    private func failFirstLoad(_ web: WebRuntime, code: Int = NSURLErrorNotConnectedToInternet) {
        let error = NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSURLErrorFailingURLErrorKey: chat])
        web.webView(web.webView, didFailProvisionalNavigation: nil, withError: error)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// 一次变化送到每个登记过的运行时。
    func testOneUpdateReachesEveryRuntime() {
        let network = NetworkStatus(startsMonitor: false)
        let a = makeRuntime(), b = makeRuntime()
        network.add(a.web)
        network.add(b.web)
        network.deliver(online: false)
        XCTAssertEqual(a.netLog, ["网络不可用"])
        XCTAssertEqual(b.netLog, ["网络不可用"])
        network.deliver(online: true)
        XCTAssertEqual(a.netLog, ["网络不可用", "网络可用"])
        XCTAssertEqual(b.netLog, ["网络不可用", "网络可用"])
        XCTAssertEqual(a.loads.urls, [])
        XCTAssertEqual(b.loads.urls, [])
    }

    /// 同 LoadRecoveryWebTests.testNoRequestWhileOfflineAndRetryWhenBack，只是状态经共用对象送来，
    /// 而且运行时是在已知断网之后才登记的：靠补发知道断网，断网期间失败不发请求，网络恢复时重试。
    func testRuntimeAddedWhileOfflineWaitsAndRetriesWhenBack() {
        let network = NetworkStatus(startsMonitor: false)
        network.deliver(online: false)
        let r = makeRuntime(backoff: [0.02])
        network.add(r.web)
        failFirstLoad(r.web)
        spin(0.2)
        XCTAssertEqual(r.loads.urls, [], "断网期间不发请求")
        XCTAssertEqual(r.web.loadProblem, .waiting)
        network.deliver(online: true)
        XCTAssertEqual(r.loads.urls, [chat])
        XCTAssertEqual(r.web.loadProblem, .connecting)
    }

    /// 还不知道网络状态时登记：什么都不补发。两种运行时都看得出多发的一次：
    /// 当作在线的会因“断网”记日志，当作断网、首次加载已失败的会因“在线”记日志并重试。
    func testAddingBeforeAnyStatusIsKnownDeliversNothing() {
        let network = NetworkStatus(startsMonitor: false)
        let assumesOnline = makeRuntime()
        let assumesOffline = makeRuntime(offline: true)
        failFirstLoad(assumesOffline.web)
        network.add(assumesOnline.web)
        network.add(assumesOffline.web)
        XCTAssertNil(network.online)
        XCTAssertEqual(assumesOnline.netLog, [])
        XCTAssertEqual(assumesOffline.netLog, [])
        XCTAssertEqual(assumesOffline.loads.urls, [])
        XCTAssertEqual(assumesOffline.web.loadProblem, .waiting)
        // 第一次报告到了才送，而且每个只送一次。
        network.deliver(online: true)
        XCTAssertEqual(assumesOnline.netLog, [])
        XCTAssertEqual(assumesOffline.netLog, ["网络可用"])
        XCTAssertEqual(assumesOffline.loads.urls, [chat])
    }

    /// 名单只弱引用：释放的运行时不被留住，下次送状态时去掉，不崩溃；其余照常收到。
    func testReleasedRuntimeIsDroppedAndNotKeptAlive() {
        let network = NetworkStatus(startsMonitor: false)
        let kept = makeRuntime()
        weak var released: WebRuntime?
        autoreleasepool {
            let r = makeRuntime()
            network.add(r.web)
            released = r.web
        }
        network.add(kept.web)
        XCTAssertNil(released, "名单不留住运行时")
        network.deliver(online: false)
        XCTAssertEqual(network.registeredCount, 1)
        XCTAssertEqual(kept.netLog, ["网络不可用"])
    }

    /// 已知在线之后登记：补发一次“在线”，它自己不引起加载。
    /// 当作断网的运行时由这一次补发变成在线（只记一行）；它没有失败的加载，所以不加载。
    /// 首次加载已失败、在等定时重试的运行时：补发的“在线”不是“从断网恢复”，不提前重试，提示照旧。
    func testRuntimeAddedAfterOnlineGetsOneReplayAndDoesNotLoad() {
        let network = NetworkStatus(startsMonitor: false)
        network.deliver(online: true)
        let assumesOffline = makeRuntime(offline: true)
        network.add(assumesOffline.web)
        XCTAssertEqual(assumesOffline.netLog, ["网络可用"])
        XCTAssertEqual(assumesOffline.loads.urls, [])
        XCTAssertEqual(assumesOffline.web.loadProblem, .hidden)

        let waiting = makeRuntime(backoff: [60])
        failFirstLoad(waiting.web)
        network.add(waiting.web)
        XCTAssertEqual(waiting.netLog, [])
        XCTAssertEqual(waiting.loads.urls, [])
        XCTAssertEqual(waiting.web.loadProblem, .waiting)
    }

    /// 第一次报告不管在登记之前还是之后到，每个运行时都只收到一次；之后的变化照常送到。
    /// 同一个运行时重复登记不加条，也不再补发。
    func testFirstStatusReachesEachRuntimeOnceBeforeOrAfterRegistration() {
        let network = NetworkStatus(startsMonitor: false)
        let early = makeRuntime()
        network.add(early.web)
        network.deliver(online: false)
        let late = makeRuntime()
        network.add(late.web)
        network.add(late.web)
        XCTAssertEqual(network.registeredCount, 2)
        XCTAssertEqual(early.netLog, ["网络不可用"])
        XCTAssertEqual(late.netLog, ["网络不可用"])
        network.deliver(online: true)
        XCTAssertEqual(early.netLog, ["网络不可用", "网络可用"])
        XCTAssertEqual(late.netLog, ["网络不可用", "网络可用"])
    }

    /// 边界：共用对象只通知，不替页面决定加载。同一个对象上登记的几个页面收到同样的“断网 → 在线”，
    /// 只有首次加载失败、在等重试的那个重试；没失败过的、正在首次加载的、已加载好的、
    /// 失败后重新加载正在进行的、失败不是网络原因的，都不发加载请求。
    func testNetworkComingBackOnlyRetriesThePageThatIsWaitingForIt() {
        let network = NetworkStatus(startsMonitor: false)

        let neverLoaded = makeRuntime()

        let firstLoadInFlight = makeRuntime()
        firstLoadInFlight.web.mainFrameIsLoading = { true }
        firstLoadInFlight.web.load(chat)
        firstLoadInFlight.web.webView(firstLoadInFlight.web.webView, didStartProvisionalNavigation: nil)

        let loadedFine = makeRuntime()
        loadedFine.web.load(chat)
        loadedFine.web.webView(loadedFine.web.webView, didCommit: nil)
        loadedFine.web.webView(loadedFine.web.webView, didFinish: nil)

        let reloadInFlight = makeRuntime()
        reloadInFlight.web.mainFrameIsLoading = { true }
        failFirstLoad(reloadInFlight.web)
        reloadInFlight.web.reload()

        let notANetworkFailure = makeRuntime()
        failFirstLoad(notANetworkFailure.web, code: NSURLErrorServerCertificateUntrusted)

        let waiting = makeRuntime()
        failFirstLoad(waiting.web)

        let all = [neverLoaded, firstLoadInFlight, loadedFine, reloadInFlight, notANetworkFailure, waiting]
        let before = all.map { $0.loads.urls }
        XCTAssertEqual(before, [[], [chat], [chat], [chat], [], []])
        XCTAssertEqual(reloadInFlight.web.loadProblem, .connecting)
        XCTAssertEqual(notANetworkFailure.web.loadProblem, .stopped)
        XCTAssertEqual(waiting.web.loadProblem, .waiting)

        all.forEach { network.add($0.web) }
        network.deliver(online: false)
        network.deliver(online: true)

        XCTAssertEqual(neverLoaded.loads.urls, before[0], "没失败过：不加载")
        XCTAssertEqual(firstLoadInFlight.loads.urls, before[1], "正在首次加载：不再发一次")
        XCTAssertEqual(loadedFine.loads.urls, before[2], "已加载好：不重新加载")
        XCTAssertEqual(reloadInFlight.loads.urls, before[3], "失败后的重新加载正在进行：不再发一次")
        XCTAssertEqual(notANetworkFailure.loads.urls, before[4], "不是网络原因的失败：不自动重试")
        XCTAssertEqual(waiting.loads.urls, [chat], "在等重试的页面：网络恢复时重试一次")
        XCTAssertEqual(waiting.web.loadProblem, .connecting)
        for r in all { XCTAssertEqual(r.netLog, ["网络不可用", "网络可用"]) }
    }
}
