import AppKit
import Combine
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 启动时的接线（ChatTabs.wire(_:)、urlChanged、focusInputSoon，原来写在 AppDelegate 里）：网页运行时的回调按什么顺序动窗口。
/// 冷启动看起来对不对靠这些顺序（加载完成时先结束启动画面、再解除启动保护、最后聚焦），这里把现在的行为钉住，之后再搬动。
///
/// 用真的 ChatWindowController（不显示窗口）和真的 WebRuntime（不看网络，加载请求只记下来），直接调运行时的回调，
/// 或者像 LoadRecoveryWebTests 一样直接调它的导航代理。AppDelegate 交进来的几样（隐藏窗口、聚焦输入框、记下对话地址、
/// 网页媒体状态）换成记录。日志和这些记录按发生的顺序排在同一条时间线上。
/// 只有一个标签页：它的 page 就是窗口的 page（同一个对象），它的网页视图就是窗口显示着的那个。
@MainActor
final class LaunchWiringTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!

    /// tagged：运行时和适配器像正式运行时那样带这个标签页的标签（见 TabLog）。不带是原来的样子。
    private func makeRig(tagged: Bool = false) -> Rig {
        let name = "LaunchWiringTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = Rig(defaults: UserDefaults(suiteName: name)!, tagged: tagged)
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

    /// 首次加载失败（-1009），和 LoadRecoveryWebTests 一样直接调导航代理。
    private func failLoad(_ rig: Rig) {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                            userInfo: [NSURLErrorFailingURLErrorKey: chat])
        rig.tab.runtime.webView(rig.tab.runtime.webView, didFailProvisionalNavigation: nil, withError: error)
    }

    // MARK: - 只有一个标签页

    /// 带页面的入口传的就是窗口显示着的页面，报颜色的网页视图就是窗口显示着的那个：所以和原来不带页面的入口一样。
    func testTheOnlyTabsPageAndWebViewAreTheWindowsOwn() {
        let rig = makeRig()
        XCTAssertTrue(rig.tab.page === rig.controller.page)
        XCTAssertTrue(rig.controller.webView === rig.tab.runtime.webView)
        XCTAssertTrue(rig.tabs.selected === rig.tab)
        XCTAssertEqual(rig.tab.id, TabList().selected)
    }

    // MARK: 1. 冷启动：提交、留着提示、加载完成

    /// 启动画面还在时盖着“无法连接”提示（这里直接让运行时报一个状态），网页提交、提示要收起时留着、加载完成：
    /// 先结束启动画面，再淡出提示、解除启动保护（加载完成时报的是这个网页视图的颜色），窗口是 key 窗口就最后聚焦。
    func testALoadDuringTheLaunchScreenEndsItThenReleasesTheColourThenFocuses() async throws {
        let rig = makeRig()
        rig.tabs.windowIsKey = { true }
        rig.controller.beginLaunchScreen()
        rig.tab.runtime.onLoadProblemChange?(.connecting)
        XCTAssertEqual(rig.window, "启动画面=true 启动画面淡出=false 启动保护=true 提示=connecting 提示那层藏着=false 提示淡出=false")

        rig.tab.runtime.onMainFrameCommitted?()
        XCTAssertTrue(rig.tab.page.hasCommittedPage)
        XCTAssertTrue(rig.tab.page.awaitingFinish)
        rig.tab.runtime.onLoadProblemChange?(.hidden)
        XCTAssertTrue(rig.tab.page.noticeAwaitsLoad, "提交后、加载完成前要收起：留着")
        XCTAssertEqual(rig.window, "启动画面=true 启动画面淡出=false 启动保护=true 提示=connecting 提示那层藏着=false 提示淡出=false")

        rig.tab.runtime.onMainFrameLoaded?()
        XCTAssertEqual(rig.window, "启动画面=false 启动画面淡出=true 启动保护=false 提示=无 提示那层藏着=true 提示淡出=true")
        XCTAssertTrue(rig.tab.page.hasFinishedFirstLoad)
        XCTAssertTrue(PageAppearance.sameColor(rig.tab.page.colorAtLastFinish, Rig.dark), "报的是这个标签页的网页视图的颜色")
        let loaded = [
            "[appearance] 启动保护：网页加载完成前不跟随页面底色（保持系统颜色）",
            "[nav] 无法连接提示：网页已提交，留到加载完成",
            "[launch] 启动画面结束：网页已加载（…ms）",
            "[nav] 无法连接提示：加载完成，淡出",
            "[appearance] 启动保护解除：加载完成时报的是深色，等页面颜色变化再采用",
        ]
        XCTAssertEqual(rig.lines, loaded, "聚焦要等 80ms，加载完成的回调里还没有")

        try await waitUntil { !rig.focused.isEmpty }
        XCTAssertEqual(rig.lines, loaded + ["聚焦输入框"])
        XCTAssertEqual(rig.focused.count, 1)
        XCTAssertTrue(rig.focused.first === rig.tab.adapter)
    }

    // MARK: 2. 启动时加载失败

    /// 运行时先报“无法连接”（waiting），再报加载失败：提示先盖上，启动画面再结束（淡出时下面已经是提示）。
    /// 启动保护不解除，不聚焦，不隐藏窗口。
    func testAFailedLaunchLoadShowsTheNoticeThenEndsTheLaunchScreen() async throws {
        let rig = makeRig()
        rig.tabs.windowIsKey = { true }
        rig.controller.beginLaunchScreen()
        rig.tab.runtime.load(chat)
        failLoad(rig)
        XCTAssertEqual(rig.window, "启动画面=false 启动画面淡出=true 启动保护=true 提示=waiting 提示那层藏着=false 提示淡出=false")
        XCTAssertEqual(rig.tab.page.notice, .waiting)
        try await pause(0.3)
        XCTAssertEqual(rig.lines, [
            "[appearance] 启动保护：网页加载完成前不跟随页面底色（保持系统颜色）",
            "[nav] 加载 https://chatgpt.com/c/<id>",
            "[nav] 加载失败 NSURLErrorDomain#-1009 @ <nil>",
            "[nav] 60 秒后自动重试",
            "[nav] 无法连接提示：waiting",
            "[launch] 启动画面结束：加载失败（…ms）",
        ])
    }

    /// 接着上面：点提示里的“重新加载”、网页提交、加载完成，都经过运行时自己的导航代理。
    /// 启动画面已经结束，加载完成不再写“启动画面结束”；提示留到加载完成再淡出，启动保护这时才解除，然后聚焦。
    func testAfterAFailedLaunchTheRetryHoldsTheNoticeUntilTheLoadFinishes() async throws {
        let rig = makeRig()
        rig.tabs.windowIsKey = { true }
        rig.controller.beginLaunchScreen()
        rig.tab.runtime.load(chat)
        failLoad(rig)
        rig.timeline = []

        rig.noticeCover.rootView.model.onReload()
        XCTAssertEqual(rig.loaded, [chat, chat])
        XCTAssertEqual(rig.window, "启动画面=false 启动画面淡出=true 启动保护=true 提示=connecting 提示那层藏着=false 提示淡出=false")
        rig.tab.runtime.webView(rig.tab.runtime.webView, didCommit: nil)
        XCTAssertEqual(rig.window, "启动画面=false 启动画面淡出=true 启动保护=true 提示=connecting 提示那层藏着=false 提示淡出=false")
        rig.tab.runtime.webView(rig.tab.runtime.webView, didFinish: nil)
        XCTAssertEqual(rig.window, "启动画面=false 启动画面淡出=true 启动保护=false 提示=无 提示那层藏着=true 提示淡出=true")

        try await waitUntil { !rig.focused.isEmpty }
        XCTAssertEqual(rig.lines, [
            "[nav] 重新加载失败的地址",
            "[nav] 加载 https://chatgpt.com/c/<id>",
            "[nav] 无法连接提示：connecting",
            "[nav] 无法连接提示：hidden",
            "[nav] 无法连接提示：网页已提交，留到加载完成",
            "[nav] 加载完成 <nil>",
            "[nav] 无法连接提示：加载完成，淡出",
            "[appearance] 启动保护解除：加载完成时报的是深色，等页面颜色变化再采用",
            "聚焦输入框",
        ])
    }

    // MARK: 3. 提示的状态原样交给窗口

    func testLoadProblemValuesReachTheWindowUnchanged() {
        let rig = makeRig()
        for status: LoadRecovery.Status in [.waiting, .connecting, .stopped, .hidden, .stopped, .waiting, .hidden] {
            rig.tab.runtime.onLoadProblemChange?(status)
            XCTAssertEqual(rig.tab.page.notice, status)
            XCTAssertEqual(rig.controller.shownLoadProblem, status == .hidden ? nil : status)
            XCTAssertEqual(rig.noticeCover.rootView.model.status, status)
            XCTAssertEqual(rig.noticeCover.isHidden, status == .hidden)
        }
        XCTAssertEqual(rig.lines, [], "没有提交过：不留着，窗口也不写日志")
    }

    // MARK: 4. 地址变化

    /// 对话地址（去掉 query）每次都记下，路径没变也记；首页不记，之前记下的不动。
    /// 只有路径变了才算换页面：记下路径、适配器的代号先加一、再写日志；不是第一次换页面时 0.8 秒后再记一次网页媒体状态。
    func testURLChangesSaveConversationsAndCountOnlyPathChanges() async throws {
        let rig = makeRig()
        rig.tab.runtime.onURLChange?(URL(string: "https://chatgpt.com/c/abc?model=x")!)
        XCTAssertEqual(rig.tab.lastPath, "chatgpt.com/c/abc")
        XCTAssertEqual(rig.tab.adapter.generation, 1)

        rig.tab.runtime.onURLChange?(URL(string: "https://chatgpt.com/c/abc?model=y")!)
        XCTAssertEqual(rig.tab.lastPath, "chatgpt.com/c/abc")
        XCTAssertEqual(rig.tab.adapter.generation, 1, "只有 query 变了：不算换页面")

        rig.tab.runtime.onURLChange?(WebRuntime.homeURL)
        XCTAssertEqual(rig.tab.lastPath, "chatgpt.com/")
        XCTAssertEqual(rig.tab.adapter.generation, 2)
        XCTAssertEqual(rig.saved, [chat, chat], "首页不记，之前记下的不动")
        XCTAssertEqual(rig.generationAtPageChange, [1, 2], "适配器的代号在写日志之前加一")
        let changes = [
            "记下对话地址 https://chatgpt.com/c/abc",
            "[nav] 页面变化 https://chatgpt.com/c/<id>?<redacted>",
            "记下对话地址 https://chatgpt.com/c/abc",
            "[nav] 页面变化 https://chatgpt.com/",
        ]
        XCTAssertEqual(rig.lines, changes)

        let changed = Date()
        try await waitUntil { rig.lines.count > changes.count }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(changed), 0.7)
        try await pause(0.3)
        XCTAssertEqual(rig.lines, changes + ["读网页媒体状态", "[media] 页面变化后 0.8s WebKit 媒体状态=none"],
                       "第一次换页面（之前没有路径）不记媒体状态")
        XCTAssertEqual(rig.mediaRead.count, 1)
        XCTAssertTrue(rig.mediaRead.first === rig.tab.adapter)
    }

    // MARK: 5. Esc

    func testTheWebPagesEscapeRequestHidesTheWindow() {
        let rig = makeRig()
        rig.tab.runtime.onEscapeRequest?()
        XCTAssertEqual(rig.lines, ["隐藏窗口：网页 Esc"])
    }

    // MARK: 6. 聚焦

    /// 条件就是窗口是不是 key 窗口（windowController.isKey）。测试里窗口没显示，不是 key 窗口：加载完成不聚焦。
    func testALoadDoesNotFocusWhenTheWindowIsNotKey() async throws {
        let rig = makeRig()
        XCTAssertFalse(rig.controller.isKey)
        XCTAssertFalse(rig.tabs.windowIsKey(), "默认读窗口")
        rig.tab.runtime.onMainFrameLoaded?()
        try await pause(0.3)
        XCTAssertTrue(rig.focused.isEmpty)
        XCTAssertFalse(rig.lines.contains("聚焦输入框"))
    }

    /// 窗口是 key 窗口：80ms 后聚焦这个标签页的输入框一次，结果交给诊断计数。80ms 内再加载完成一次，只聚焦一次（先取消排着的）。
    func testALoadFocusesOnceWhenTheWindowIsKey() async throws {
        let rig = makeRig()
        rig.tabs.windowIsKey = { true }
        let counted = rig.diagnostics.inputFocusResults[Rig.focusResult] ?? 0
        rig.tab.runtime.onMainFrameLoaded?()
        rig.tab.runtime.onMainFrameLoaded?()
        XCTAssertTrue(rig.focused.isEmpty, "不是马上聚焦")
        try await waitUntil { !rig.focused.isEmpty }
        try await pause(0.3)
        XCTAssertEqual(rig.focused.count, 1)
        XCTAssertTrue(rig.focused.first === rig.tab.adapter)
        XCTAssertEqual(rig.diagnostics.inputFocusResults[Rig.focusResult], counted + 1)
    }

    // MARK: 7. 提示里的“重新加载”

    /// 提示里的按钮（LoadProblemModel.onReload）交给这个标签页的运行时重新加载：还没有页面时重新加载请求的地址。
    func testTheNoticesReloadGoesToTheTabsRuntime() {
        let rig = makeRig()
        rig.tab.runtime.load(chat)
        rig.noticeCover.rootView.model.onReload()
        XCTAssertEqual(rig.loaded, [chat, chat])
        XCTAssertEqual(rig.lines, [
            "[nav] 加载 https://chatgpt.com/c/<id>",
            "[nav] 还没有页面，重新加载请求的地址",
            "[nav] 加载 https://chatgpt.com/c/<id>",
        ])
    }

    // MARK: 8. 对选中的（就是这一个）标签页做的操作，原来写在 AppDelegate 里

    /// ⌘R 和提示里的“重新加载”一样，交给这个标签页的运行时。
    func testReloadingTheSelectedTabReloadsThisTab() {
        let rig = makeRig()
        rig.tab.runtime.load(chat)
        rig.tabs.reloadSelectedTab()
        XCTAssertEqual(rig.loaded, [chat, chat])
    }

    /// 新对话在启动画面还在时开不了新标签页（有空位时开在新标签页，见 NewChatTabTests），照原来在这个标签页里新建：
    /// 先写一行，再问页面里的入口；没点到就整页加载新对话页，不聚焦。点到了不加载，80ms 后聚焦一次。
    func testNewChatLoadsTheHomePageOrFocusesAfterAnInPageSwitch() async throws {
        let rig = makeRig()
        rig.controller.beginLaunchScreen()
        XCTAssertTrue(rig.tabs.isLaunchScreenUp)
        rig.timeline = []
        let stays = "[tabs] 新建对话：启动画面还在，在当前标签页新建"
        rig.tabs.newChat()
        try await waitUntil { !rig.loaded.isEmpty }
        try await pause(0.2)
        XCTAssertEqual(rig.loaded, [WebRuntime.homeURL])
        XCTAssertEqual(rig.lines, [stays, "页面里新对话", "[nav] 加载 https://chatgpt.com/"])
        XCTAssertTrue(rig.focused.isEmpty)
        XCTAssertEqual(rig.tabs.tabs.count, 1)

        rig.timeline = []
        rig.newChatInPage = true
        rig.tabs.newChat()
        try await waitUntil { !rig.focused.isEmpty }
        XCTAssertEqual(rig.lines, [stays, "页面里新对话", "聚焦输入框"])
        XCTAssertEqual(rig.loaded, [WebRuntime.homeURL])
        XCTAssertTrue(rig.focused.first === rig.tab.adapter)
    }

    /// 窗口显示后：先请求聚焦，再让运行时按显示方式提前重试。第一次加载失败、在等自动重试时，切模式不提前重试，唤醒提前重试一次。
    /// 两次请求聚焦，只聚焦最新的一次。
    func testWindowShownRequestsFocusThenRetriesEarly() async throws {
        let rig = makeRig()
        rig.tab.runtime.load(chat)
        failLoad(rig)
        rig.timeline = []
        rig.controller.onDidShow?(.modeSwitch)
        XCTAssertEqual(rig.loaded, [chat])
        rig.controller.onDidShow?(.wake)
        XCTAssertEqual(rig.loaded, [chat, chat])
        try await waitUntil { !rig.focused.isEmpty }
        try await pause(0.2)
        XCTAssertEqual(rig.focused.count, 1)
        XCTAssertEqual(rig.lines, [
            "[nav] 自动重试（窗口显示）第 1 次",
            "[nav] 加载 https://chatgpt.com/c/<id>",
            "[nav] 无法连接提示：connecting",
            "聚焦输入框",
        ])
    }

    /// 记下、放回、丢弃阅读位置换成时间线上的记录（“记下阅读位置”“放回阅读位置 1”“放回阅读位置 2 要网页确认”“丢弃阅读位置 3”），
    /// 编号从 1 起。
    private func recordReadingPosition(_ rig: Rig) {
        var count = 0
        rig.tabs.holdReadingPosition = { [weak rig] runtime in
            rig?.timeline.append(runtime === rig?.tab.runtime ? "记下阅读位置" : "记下别的")
            count += 1
            return count
        }
        rig.tabs.restoreReadingPosition = { [weak rig] runtime, token, confirm in
            rig?.timeline.append((runtime === rig?.tab.runtime ? "放回阅读位置" : "放回别的") + " \(token)" + (confirm ? " 要网页确认" : ""))
        }
        rig.tabs.discardReadingPosition = { [weak rig] runtime, token in
            rig?.timeline.append((runtime === rig?.tab.runtime ? "丢弃阅读位置" : "丢弃别的") + " \(token)")
        }
    }

    /// 排版变化前后：记下、放回都给这个标签页，次数和顺序照窗口的回调，套着的也一样；放回的是那一次的编号。
    /// 中间换了页面（3.2 起）：记下时还没有地址、之后有了对话地址，连续性规则说丢弃：两次都在换页面那一刻丢弃
    /// （网页里按编号丢掉，各写一行日志），排版结束时不再放回。阶段 2 时照样放回，那是临时例外。
    func testLayoutChangesHoldAndRestoreOnThisTab() {
        let rig = makeRig()
        recordReadingPosition(rig)
        rig.controller.onWillChangeLayout?()
        rig.controller.onDidChangeLayout?()
        rig.controller.onWillChangeLayout?()
        rig.controller.onWillChangeLayout?()
        rig.tab.runtime.onURLChange?(chat)
        rig.controller.onDidChangeLayout?()
        rig.controller.onDidChangeLayout?()
        let dropped = "[reading] 阅读位置：丢弃排版前记下的位置（不知道记下时或现在的地址）"
        XCTAssertEqual(rig.lines, [
            "记下阅读位置", "放回阅读位置 1", "记下阅读位置", "记下阅读位置",
            "记下对话地址 https://chatgpt.com/c/abc", "[nav] 页面变化 https://chatgpt.com/c/<id>",
            "丢弃阅读位置 2", dropped, "丢弃阅读位置 3", dropped,
        ])
    }

    /// 只有一个标签页时，3.2 唯一有意的变化：切模式、拖边途中选中的页面换了对话，旧位置不再放回。
    /// 换到别的对话：当场丢弃（网页里丢掉、写一行日志），排版结束时什么都不做。只变 query：照常放回，不写日志。
    func testTheOnlyTabDropsThePositionWhenItChangesConversationDuringALayoutChange() {
        let rig = makeRig()
        rig.tab.runtime.onURLChange?(chat)
        recordReadingPosition(rig)
        rig.timeline = []
        rig.controller.onWillChangeLayout?()
        rig.tab.runtime.onURLChange?(URL(string: "https://chatgpt.com/c/abc?model=x")!)
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(rig.lines, ["记下阅读位置", "记下对话地址 https://chatgpt.com/c/abc", "放回阅读位置 1"])

        rig.timeline = []
        rig.controller.onWillChangeLayout?()
        rig.tab.runtime.onURLChange?(URL(string: "https://chatgpt.com/c/def")!)
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(rig.lines, [
            "记下阅读位置", "记下对话地址 https://chatgpt.com/c/def", "[nav] 页面变化 https://chatgpt.com/c/<id>",
            "丢弃阅读位置 2", "[reading] 阅读位置：丢弃排版前记下的位置（换了对话）",
        ])
        XCTAssertNil(rig.tab.pendingReadingRestore, "只有一个标签页，它总是选中的，没有留着的")
    }

    /// 只有一个标签页：新对话页在排版途中拿到对话地址（/ → /c/…）：放回，但要网页确认（确认不了网页自己丢掉）。
    /// 排版途中整页重新加载（提交）：丢弃。
    func testTheOnlyTabAsksThePageToConfirmANewChatThatGotItsAddressAndDropsAfterAReload() {
        let rig = makeRig()
        rig.tab.runtime.onURLChange?(WebRuntime.homeURL)
        recordReadingPosition(rig)
        rig.timeline = []
        rig.controller.onWillChangeLayout?()
        rig.tab.runtime.onURLChange?(chat)
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(rig.lines, [
            "记下阅读位置", "记下对话地址 https://chatgpt.com/c/abc", "[nav] 页面变化 https://chatgpt.com/c/<id>",
            "放回阅读位置 1 要网页确认",
        ])

        rig.timeline = []
        rig.controller.onWillChangeLayout?()
        rig.tab.runtime.webView(rig.tab.runtime.webView, didCommit: nil)
        XCTAssertEqual(rig.tab.mainFrameCommits, 1)
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(rig.lines.filter { $0.contains("阅读位置") }, [
            "记下阅读位置", "丢弃阅读位置 2", "[reading] 阅读位置：丢弃排版前记下的位置（页面重新加载过）",
        ])
    }

    /// 每秒的媒体状态：读这个标签页的适配器，显示读到的；和上次一样不写日志。
    func testTheMediaTickReadsThisTabAndLogsOnlyChanges() async throws {
        let rig = makeRig()
        rig.tabs.mediaTick()
        try await waitUntil { !rig.mediaRead.isEmpty }
        try await pause(0.1)
        XCTAssertTrue(rig.mediaRead.first === rig.tab.adapter)
        XCTAssertEqual(rig.diagnostics.webMediaState, "none")
        XCTAssertEqual(rig.lines, ["读网页媒体状态"])
    }

    // MARK: 9. 日志的标签

    /// 冷启动的一整段：加载失败、点提示里的“重新加载”、提交、加载完成、聚焦，再换两次页面、0.8 秒后记媒体状态。
    private func runLaunch(_ rig: Rig) async throws {
        rig.tabs.windowIsKey = { true }
        rig.controller.beginLaunchScreen()
        rig.tab.runtime.load(chat)
        failLoad(rig)
        try await pause(0.3)
        rig.noticeCover.rootView.model.onReload()
        rig.tab.runtime.webView(rig.tab.runtime.webView, didCommit: nil)
        rig.tab.runtime.webView(rig.tab.runtime.webView, didFinish: nil)
        try await waitUntil { !rig.focused.isEmpty }
        rig.tab.runtime.onURLChange?(URL(string: "https://chatgpt.com/c/abc?model=x")!)
        rig.tab.runtime.onURLChange?(WebRuntime.homeURL)
        try await waitUntil { rig.lines.last?.hasPrefix("[media]") == true }
        try await pause(0.1)
    }

    /// 运行时和适配器带着标签页的标签时（正式运行时就是这样，见 ChatTab.make）：运行时和 ChatTabs 为这个标签页写的行
    /// 末尾多了“ 【标签1】”；窗口写的（启动保护、启动画面、提示留着和淡出）不带，和 [nav] 里运行时写的提示行分得开。
    /// 同一段不带标签再走一遍：去掉行末的标签就一字不差、顺序不变，别的什么都没多。
    func testWithItsTagTheTabsLinesEndInItTheWindowsDoNotAndNothingElseChanges() async throws {
        let tagged = makeRig(tagged: true)
        try await runLaunch(tagged)
        let tag = " 【标签1】"
        XCTAssertEqual(tagged.lines, [
            "[appearance] 启动保护：网页加载完成前不跟随页面底色（保持系统颜色）",
            "[nav] 加载 https://chatgpt.com/c/<id>" + tag,
            "[nav] 加载失败 NSURLErrorDomain#-1009 @ <nil>" + tag,
            "[nav] 60 秒后自动重试" + tag,
            "[nav] 无法连接提示：waiting" + tag,
            "[launch] 启动画面结束：加载失败（…ms）",
            "[nav] 重新加载失败的地址" + tag,
            "[nav] 加载 https://chatgpt.com/c/<id>" + tag,
            "[nav] 无法连接提示：connecting" + tag,
            "[nav] 无法连接提示：hidden" + tag,
            "[nav] 无法连接提示：网页已提交，留到加载完成",
            "[nav] 加载完成 <nil>" + tag,
            "[nav] 无法连接提示：加载完成，淡出",
            "[appearance] 启动保护解除：加载完成时报的是深色，等页面颜色变化再采用",
            "聚焦输入框",
            "记下对话地址 https://chatgpt.com/c/abc",
            "[nav] 页面变化 https://chatgpt.com/c/<id>?<redacted>" + tag,
            "[nav] 页面变化 https://chatgpt.com/" + tag,
            "读网页媒体状态",
            "[media] 页面变化后 0.8s WebKit 媒体状态=none" + tag,
        ])

        let plain = makeRig()
        try await runLaunch(plain)
        XCTAssertEqual(tagged.lines.count, plain.lines.count)
        for (withTag, without) in zip(tagged.lines, plain.lines) {
            XCTAssertTrue(withTag == without || withTag == without + tag, "只多行末的标签：\(withTag) / \(without)")
        }
    }
}

/// 一个标签页、一个窗口和接线。AppDelegate 交给 ChatTabs 的几样换成记录，和日志一起按顺序记在 timeline 里。
@MainActor
private final class Rig {
    static let dark = NSColor(srgbRed: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x0E / 255.0, alpha: 1)
    static let focusResult = "LaunchWiringTests"

    let settings: AppSettings
    let diagnostics = Diagnostics()
    let tab: ChatTab
    let controller: ChatWindowController
    private(set) var tabs: ChatTabs!
    /// 日志（“[类别] 内容”）和替身的调用，按发生的顺序。
    var timeline: [String] = []
    private(set) var loaded: [URL] = []
    private(set) var focused: [ChatGPTAdapter] = []
    private(set) var saved: [URL] = []
    private(set) var mediaRead: [ChatGPTAdapter] = []
    /// 每次写“页面变化”日志时适配器的代号。
    private(set) var generationAtPageChange: [Int] = []
    /// 共用的网络状态，不看真实网络。
    let network = NetworkStatus(startsMonitor: false)
    /// 页面里的新对话入口点到了没有（替身的返回值）。
    var newChatInPage = false
    private var watch: AnyCancellable?

    init(defaults: UserDefaults, tagged: Bool) {
        settings = AppSettings(defaults: defaults)
        let id = TabList().selected
        let runtime = WebRuntime(diagnostics: diagnostics, settings: settings, recovery: LoadRecovery(backoff: [60]),
                                 watchesNetwork: false, tab: tagged ? id : nil)
        // 网页视图报深色：日志里写“深色”，看得出加载完成时报的是这个标签页的网页视图的颜色。窗口建好之前设，窗口不会看到变化。
        runtime.webView.underPageBackgroundColor = Self.dark
        let adapter = ChatGPTAdapter(webView: runtime.webView, diagnostics: diagnostics, settings: settings,
                                     tab: tagged ? id : nil)
        tab = ChatTab(id: id, runtime: runtime, adapter: adapter)
        controller = ChatWindowController(webView: tab.runtime.webView, toolbar: EmptyView(), diagnostics: diagnostics,
                                          appearance: PageAppearance(defaults: defaults), page: tab.page)
        // 解除启动保护后等颜色变化的时限放长：它到点写的日志不在这些测试的时间线里。
        controller.pageColorSettleLimit = 60
        runtime.loadRequest = { [weak self] request in self?.loaded.append(request.url!) }
        tabs = ChatTabs(list: TabList(), tab: tab, windowController: controller, diagnostics: diagnostics,
                        network: network,
                        hideWindow: { [weak self] reason in self?.timeline.append("隐藏窗口：\(reason)") },
                        focusInput: { [weak self] adapter in
                            self?.focused.append(adapter)
                            self?.timeline.append("聚焦输入框")
                            return Self.focusResult
                        },
                        saveLastConversation: { [weak self] url in
                            self?.saved.append(url)
                            self?.timeline.append("记下对话地址 \(url.absoluteString)")
                        },
                        mediaState: { [weak self] adapter in
                            self?.mediaRead.append(adapter)
                            self?.timeline.append("读网页媒体状态")
                            return "none"
                        },
                        openNewChat: { [weak self] _ in
                            self?.timeline.append("页面里新对话")
                            return self?.newChatInPage ?? false
                        })
        // 跟着真实鼠标、键盘、屏幕写的行不进时间线（见 LiveInputLogLines）。
        watch = diagnostics.$entries.dropFirst().sink { [weak self] entries in
            guard let self, let entry = entries.last, !LiveInputLogLines.excludes(entry) else { return }
            if entry.message.hasPrefix("页面变化") { self.generationAtPageChange.append(self.tab.adapter.generation) }
            self.timeline.append("[\(entry.category)] \(entry.message)")
        }
        tabs.wire(tab)
    }

    /// 时间线，启动画面结束的毫秒数换成“…”。去掉运行时加载完成后自己异步写的 [esc]、[render]（注入脚本、渲染自检），它们不归接线管。
    var lines: [String] {
        timeline.filter { !$0.hasPrefix("[esc]") && !$0.hasPrefix("[render]") }
            .map { $0.replacingOccurrences(of: #"（\d+ms）"#, with: "（…ms）", options: .regularExpression) }
    }

    /// 提示那一层：内容视图里第一个 LoadProblemView（初始化时加的；淡出那层加在它上面，排在后面）。
    var noticeCover: NSHostingView<LoadProblemView> {
        controller.window!.contentView!.subviews.compactMap { $0 as? NSHostingView<LoadProblemView> }.first!
    }

    /// 窗口上看得见的：启动画面和它淡出那层、启动保护、提示（状态、那一层、淡出那层）。
    var window: String {
        "启动画面=\(controller.isShowingLaunchScreen) 启动画面淡出=\(controller.launchFadeView != nil) "
            + "启动保护=\(controller.isHoldingPageColor) 提示=\(controller.shownLoadProblem.map { "\($0)" } ?? "无") "
            + "提示那层藏着=\(noticeCover.isHidden) 提示淡出=\(controller.loadProblemFadeView != nil)"
    }
}
