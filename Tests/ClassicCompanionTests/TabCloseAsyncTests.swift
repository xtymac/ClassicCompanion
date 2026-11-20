import AppKit
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 关闭标签页以后，关闭前开始、还在等的操作（新对话、读媒体状态、页面变化后的媒体日志、聚焦、证据采集和媒体实验）：
/// 它们等的那一步返回或到时限以后不再有任何页面或窗口的副作用（不加载、不聚焦、不写诊断、不写日志、窗口不变；
/// 只有证据采集和媒体实验写一行“没有做完”，见 EvidenceCutShortTests），
/// 也不再拿着标签页。每条核对：开始操作 → 关闭标签页（经入口 closeTab）→ 让它返回 → 什么都没发生；
/// 以及标签页、运行时、适配器、页面状态和网页视图什么时候释放（弱引用）：
/// - 什么都没在等：closeTab 返回时就释放（同一轮里，不用等）；
/// - 在等一步：那一步返回时释放（替身等多久就是多久）；正式运行时那一步是网页脚本（适配器的时限 2.5 秒，测量 4 秒）
///   或 WebKit 的媒体请求（适配器的时限 2.5 秒，关闭时马上按 "closed" 结束、不等 WebKit，见 MediaReadLimitTests）；
/// - 排着、还没开始的（80ms 后的聚焦、0.8 秒后的媒体日志）只弱引用标签页：关闭时马上释放，到点什么都不做。
/// 替身见 TabCloseRig（TabCloseEntryTests.swift）；最后两条用真的适配器和本地网页（不联网）。
@MainActor
final class TabCloseAsyncTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!
    private let other = URL(string: "https://chatgpt.com/c/def")!

    private func make() -> TabCloseRig {
        let name = "TabCloseAsyncTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabCloseRig(defaults: UserDefaults(suiteName: name)!)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        return rig
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await pause(0.01) }
    }

    /// 关闭 2（选中的）那三行：关闭、选中 1、2 的运行时关闭。
    private let closedTwo = ["[tabs] 关闭（剩 1 个） 【标签2】", "[tabs] 选中 【标签1】", "[web] 关闭网页：停止加载 【标签2】"]

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

    /// 加一个标签页 2 并选中它，这里不持有它（只弱引用）。
    private func selectedTwo(_ rig: TabCloseRig) -> Refs {
        autoreleasepool {
            let b = rig.add()
            rig.tabs.select(b)
            return Refs(b)
        }
    }

    private func close(_ refs: Refs, in rig: TabCloseRig) {
        autoreleasepool {
            guard let tab = refs.tab else { return XCTFail("还没关就释放了") }
            rig.tabs.closeTab(tab)
        }
    }

    // MARK: - 什么都没在等

    /// 什么都没在等：关闭不选中的、关闭选中的、关闭盖着新标签页遮挡的（遮挡的时限、上限和加载请求都排着）、
    /// 关闭加载过本地网页的（加载完成后的 Esc 脚本回调、3 秒后的渲染自检都排着）——closeTab 一返回，标签页、运行时、适配器、
    /// 页面状态和网页视图就都释放了，不用等下一轮。
    func testWithNothingInFlightTheClosedTabIsReleasedAtOnce() async throws {
        for variant in ["不选中的", "选中的", "新标签页的遮挡盖着", "加载过网页"] {
            let rig = make()
            var refs: Refs!
            switch variant {
            case "不选中的":
                refs = autoreleasepool {
                    let b = rig.add()
                    rig.tabs.select(b)
                    rig.tabs.select(rig.first)
                    return Refs(b)
                }
            case "选中的":
                refs = selectedTwo(rig)
            case "新标签页的遮挡盖着":
                refs = autoreleasepool { Refs(rig.tabs.newTab()!) }
            default:
                refs = selectedTwo(rig)
                if let tab = refs.tab { await rig.loadPage(tab, "<html><body><p>x</p></body></html>") }
                XCTAssertEqual(refs.web?.url, chat)
            }
            XCTAssertTrue(refs.noneReleased, variant)
            close(refs, in: rig)
            XCTAssertNil(refs.tab, "\(variant)：标签页")
            XCTAssertNil(refs.runtime, "\(variant)：运行时")
            XCTAssertNil(refs.adapter, "\(variant)：适配器")
            XCTAssertNil(refs.page, "\(variant)：页面状态")
            XCTAssertNil(refs.web, "\(variant)：网页视图")
        }
    }

    // MARK: - 新对话

    /// 选中的 2 按新对话，页面里的入口还在等（0.4 秒）时关 2。那一步返回以后：点到了不聚焦 2，没点到也不整页加载 2，
    /// 只有切换给 1 排的聚焦；日志只有关闭的那三行。等的时候 2 还在（那一步拿着它），返回时释放。
    func testAnInFlightNewChatOfTheClosedTabDoesNothingAndHoldsItOnlyUntilItReturns() async throws {
        for inPage in [true, false] {
            let rig = make()
            rig.newChatInPage = inPage
            rig.delays["newChat"] = 0.4
            rig.tabs.windowIsKey = { true }
            let refs = selectedTwo(rig)
            try await waitUntil { rig.focused == ["2"] }
            let started = Date()
            rig.tabs.newChat()
            try await waitUntil { rig.newChatAsked == ["2"] }
            let mark = rig.mark()
            close(refs, in: rig)
            try await pause(0.2)
            XCTAssertTrue(refs.noneReleased, "那一步还拿着它（点到了=\(inPage)）")
            try await waitUntil(2) { refs.allReleased }
            let held = Date().timeIntervalSince(started)
            XCTAssertTrue(refs.allReleased, "那一步返回时释放（点到了=\(inPage)）")
            XCTAssertGreaterThanOrEqual(held, 0.35)
            XCTAssertLessThan(held, 0.8)
            try await pause(0.3)
            XCTAssertEqual(rig.lines(since: mark), closedTwo + ["聚焦 1", "页面里新对话 2 返回"], "点到了=\(inPage)")
            XCTAssertNil(rig.loads["2"])
            XCTAssertEqual(rig.focused, ["2", "1"])
        }
    }

    // MARK: - 媒体状态

    /// 每秒读媒体状态：读 2 的时候（0.4 秒）关 2。读完不显示、不写日志、不改记下的状态；2 读完时释放。
    func testAnInFlightMediaReadOfTheClosedTabWritesNothing() async throws {
        let rig = make()
        rig.delays["media"] = 0.4
        let refs = selectedTwo(rig)
        let shown = rig.diagnostics.webMediaState
        rig.tabs.mediaTick()
        try await waitUntil { rig.mediaRead == ["2"] }
        let mark = rig.mark()
        close(refs, in: rig)
        XCTAssertTrue(refs.noneReleased, "读的时候还拿着它")
        try await waitUntil(2) { refs.allReleased }
        XCTAssertTrue(refs.allReleased, "读完释放")
        try await pause(0.2)
        XCTAssertEqual(rig.diagnostics.webMediaState, shown)
        XCTAssertEqual(rig.lines(since: mark), closedTwo)
    }

    /// 页面变化后 0.8 秒的媒体日志：
    /// - 还没到点就关：到点不读、不写（排着的那次只弱引用 2，关闭时 2 就释放了）；
    /// - 正在读（0.4 秒）时关：读完不写那一行；2 读完时释放。
    func testTheMediaLineAfterAPageChangeIsNotWrittenForAClosedTab() async throws {
        let early = make()
        let refs = selectedTwo(early)
        refs.runtime?.onURLChange?(chat)
        refs.runtime?.onURLChange?(other)
        close(refs, in: early)
        XCTAssertTrue(refs.allReleased, "排着的那次不拿着它")
        try await pause(1.0)
        XCTAssertEqual(early.mediaRead, [])

        let rig = make()
        rig.delays["media"] = 0.4
        let reading = selectedTwo(rig)
        reading.runtime?.onURLChange?(chat)
        reading.runtime?.onURLChange?(other)
        try await waitUntil(2) { rig.mediaRead == ["2"] }
        let mark = rig.mark()
        close(reading, in: rig)
        XCTAssertTrue(reading.noneReleased, "读的时候还拿着它")
        try await waitUntil(2) { reading.allReleased }
        XCTAssertTrue(reading.allReleased)
        try await pause(0.2)
        XCTAssertEqual(rig.lines(since: mark), closedTwo, "不写“页面变化后 0.8s”那一行")
    }

    // MARK: - 聚焦

    /// 2 排着聚焦：
    /// - 还没到 80ms 就关：取消，不聚焦 2（只聚焦切换换上的 1），2 马上释放；
    /// - 正在等页面的结果（0.4 秒）时关：结果不记进诊断（1 的照记），2 在结果回来时释放。
    func testAPendingFocusOfTheClosedTabNeitherFocusesNorRecords() async throws {
        let early = make()
        early.tabs.windowIsKey = { true }
        let refs = selectedTwo(early)
        close(refs, in: early)
        XCTAssertTrue(refs.allReleased, "排着的聚焦不拿着它")
        try await pause(0.3)
        XCTAssertEqual(early.focused, ["1"])

        let rig = make()
        rig.delays["focus"] = 0.4
        rig.tabs.windowIsKey = { true }
        let results = { (name: String) in rig.diagnostics.inputFocusResults["TabCloseRig-\(name)"] ?? 0 }
        let before = (results("1"), results("2"))
        let waiting = selectedTwo(rig)
        try await waitUntil { rig.focused == ["2"] }
        close(waiting, in: rig)
        XCTAssertTrue(waiting.noneReleased, "等结果时还拿着它")
        try await waitUntil(2) { waiting.allReleased }
        XCTAssertTrue(waiting.allReleased)
        try await waitUntil(2) { results("1") == before.0 + 1 }
        XCTAssertEqual(results("1"), before.0 + 1, "1 的照记")
        XCTAssertEqual(results("2"), before.1, "2 的不记")
        XCTAssertEqual(rig.focused, ["2", "1"])
    }

    // MARK: - 证据采集、媒体实验

    /// 证据采集（要测量）和三种实验，第一步在等（0.3 秒）时关 2：之后的步骤一步都不做，诊断不写（证据、测量、实验记录），
    /// 2 在那一步返回时释放。那一步返回时写一行“没有做完”（只一行，带 2 的标签；替身的挂起返回 "ok"，不是关闭让它结束的，
    /// 只说结果丢弃）。
    func testEvidenceAndExperimentsStopAtTheClosedTab() async throws {
        let kinds: [(String, @MainActor (ChatTabs) async -> Void, String, String)] = [
            ("证据", { await $0.collectEvidence(measure: true) }, "probe",
             "[diag] 证据采集没有做完：标签页在“探测页面能力”这一步关闭，这一步的结果丢弃；网页脚本没有取消，是它返回、出错或超时以后丢弃的 【标签2】"),
            ("暂停全部", { await $0.runExperiment(.suspendAll) }, "suspend",
             "[diag] 媒体实验“WebKit setAllMediaPlaybackSuspended(true)”没有做完：标签页在“全部挂起”这一步关闭，这一步的结果丢弃 【标签2】"),
            ("播放速度", { await $0.runExperiment(.setRate(1.25)) }, "setRate",
             "[diag] 媒体实验“DOM playbackRate=1.25”没有做完：标签页在“设置播放速度并测量”这一步关闭，这一步的结果丢弃 【标签2】"),
            ("测量", { await $0.runExperiment(.measure) }, "measure",
             "[diag] 媒体实验“测量”没有做完：标签页在“测量速率”这一步关闭，这一步的结果丢弃 【标签2】"),
        ]
        for (name, run, firstStep, cutShort) in kinds {
            let rig = make()
            let steps = SlowEvidenceSteps()
            rig.tabs.evidenceTarget = { tab in SlowEvidence(name: "\(tab.id.rawValue)", steps: steps, delay: 0.3) }
            let refs = selectedTwo(rig)
            let evidence = rig.diagnostics.readAloudEvidence, measured = rig.diagnostics.mediaMeasurement
            let experiments = rig.diagnostics.experiments
            let task = Task { await run(rig.tabs) }
            try await waitUntil { !steps.list.isEmpty }
            let mark = rig.mark()
            close(refs, in: rig)
            XCTAssertTrue(refs.noneReleased, "\(name)：那一步还拿着它")
            await task.value
            XCTAssertTrue(refs.allReleased, "\(name)：那一步返回时释放")
            XCTAssertEqual(steps.list, ["\(firstStep) 2", "\(firstStep) 2 返回"], name)
            XCTAssertEqual(rig.diagnostics.readAloudEvidence, evidence, name)
            XCTAssertEqual(rig.diagnostics.mediaMeasurement, measured, name)
            XCTAssertEqual(rig.diagnostics.experiments, experiments, name)
            XCTAssertEqual(rig.lines(since: mark), closedTwo + [cutShort], name)
        }
    }

    // MARK: - 真的适配器（本地网页，不联网）

    /// 2 打开一个本地网页，“新对话”入口点下去要忙 0.4 秒。真的适配器点它（和 AppDelegate 一样），点的脚本还没返回时关 2：
    /// 脚本返回以后适配器什么都不写（不写“官方入口命中”，不再等页面变化 1 秒、不写“已点击官方入口”），不整页加载、不聚焦 2；
    /// 2 在脚本返回时释放（不等那 1 秒，也不等脚本的时限）。
    func testARealInPageNewChatIsCutShortByTheClose() async throws {
        let rig = make()
        rig.realAdapter = true
        let refs = selectedTwo(rig)
        let html = """
        <html><body><button data-testid="create-new-chat-button"
          onclick="const end = Date.now() + 400; while (Date.now() < end) {} window.clicks = (window.clicks || 0) + 1">新对话</button></body></html>
        """
        if let tab = refs.tab { await rig.loadPage(tab, html) }
        XCTAssertEqual(refs.web?.url, chat)
        let started = Date()
        rig.tabs.newChat()
        try await waitUntil { rig.newChatAsked == ["2"] }
        try await pause(0.1)
        let mark = rig.mark()
        close(refs, in: rig)
        try await waitUntil(3) { refs.allReleased }
        let held = Date().timeIntervalSince(started)
        XCTAssertTrue(refs.allReleased)
        XCTAssertLessThan(held, 0.9, "脚本返回时释放，不等页面变化的 1 秒")
        try await pause(1.2)
        let lines = rig.lines(since: mark)
        XCTAssertEqual(lines.filter { $0.contains("【标签2】") }, ["[tabs] 关闭（剩 1 个） 【标签2】", "[web] 关闭网页：停止加载 【标签2】"])
        XCTAssertTrue(lines.contains("页面里新对话 2 返回"))
        XCTAssertNil(rig.loads["2"])
        XCTAssertEqual(rig.focused, [])
    }

    /// 2 打开一个本地网页，真的证据采集（TabEvidenceTarget）做“测量”实验：网页里的测量脚本要 2 秒（时限 4 秒）。
    /// 开始 0.3 秒后关 2：测量脚本返回前 2 还在（测量那一步拿着它），返回后马上释放（不等 4 秒的时限）；
    /// 测量结果、实验记录都不写，适配器不写日志。写一行“没有做完”：测量这一步先读媒体状态再跑脚本，
    /// 分不清关闭时在等哪一个，只说结果丢弃。
    func testARealMeasurementHoldsTheClosedTabOnlyUntilItsScriptReturns() async throws {
        let rig = make()
        rig.realAdapter = true
        let refs = selectedTwo(rig)
        if let tab = refs.tab { await rig.loadPage(tab, "<html><body><p>x</p></body></html>") }
        XCTAssertEqual(refs.web?.url, chat)
        let measured = rig.diagnostics.mediaMeasurement, experiments = rig.diagnostics.experiments
        let started = Date()
        let task = Task { await rig.tabs.runExperiment(.measure) }
        try await pause(0.3)
        let mark = rig.mark()
        close(refs, in: rig)
        try await pause(0.9)
        XCTAssertTrue(refs.noneReleased, "测量脚本还没返回（2 秒）")
        try await waitUntil(4) { refs.allReleased }
        let held = Date().timeIntervalSince(started)
        XCTAssertTrue(refs.allReleased)
        XCTAssertGreaterThan(held, 1.8)
        XCTAssertLessThan(held, 3.0, "脚本返回时释放，不等 4 秒的时限")
        await task.value
        XCTAssertEqual(rig.diagnostics.mediaMeasurement, measured)
        XCTAssertEqual(rig.diagnostics.experiments, experiments)
        XCTAssertEqual(rig.lines(since: mark).filter { $0.contains("【标签2】") },
                       ["[tabs] 关闭（剩 1 个） 【标签2】", "[web] 关闭网页：停止加载 【标签2】",
                        "[diag] 媒体实验“测量”没有做完：标签页在“测量速率”这一步关闭，这一步的结果丢弃 【标签2】"])
    }
}

/// 证据采集和实验的每一步：记下是哪个标签页的哪一步，等 delay 秒再返回。不持有标签页。
@MainActor
private final class SlowEvidenceSteps {
    var list: [String] = []
}

@MainActor
private struct SlowEvidence: EvidenceTarget {
    let name: String
    let steps: SlowEvidenceSteps
    let delay: Double

    private func step(_ what: String) async {
        steps.list.append("\(what) \(name)")
        try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
        steps.list.append("\(what) \(name) 返回")
    }

    func probe() async { await step("probe") }
    func readAloudEvidence() async -> String { await step("readAloud"); return "{}" }
    func measureMedia() async -> String { await step("measure"); return "测量" }
    func webMediaState() async -> String { await step("mediaState"); return "none" }
    func experimentSetRate(_ rate: Double) async -> String { await step("setRate"); return "set=ok" }
    func setAllMediaPlaybackSuspended(_ suspended: Bool) async -> String { await step("suspend"); return "ok" }
    func pauseAllMediaPlayback() async -> String { await step("pause"); return "ok" }
}
