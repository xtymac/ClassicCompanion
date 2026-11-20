import AppKit
import Combine
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 诊断窗口（DiagnosticsView）里说某一个页面的那几样——页面能力的“页面”一行、WebKit 媒体状态、结构、速率测量、最近 6 条实验记录——
/// 前面带上它是哪个标签页的：写下它时绑定的那个（Diagnostics 记下的），不随现在选中的变；那个标签页关闭了说“已关闭的”。
/// 只有创建序号，没有标题、地址。四种语言用各自表里说标签页的词。
/// 核对的是窗口照着显示的文字（DiagnosticsView.pageTexts）和窗口重画靠的通知（objectWillChange）；不建、不显示诊断窗口。
/// 用到标签页的几条用 TabCloseRig（它的聊天窗口从不显示），证据和实验的步骤换成替身（LabelEvidence）。
@MainActor
final class DiagnosticsTabLabelTests: XCTestCase {
    private func make() -> TabCloseRig {
        let name = "DiagnosticsTabLabelTests-\(UUID().uuidString)"
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
        while !condition(), Date() < deadline { try await pause(0.02) }
    }

    /// 标签 1 和标签 2 的标识（TabList 发的，和正式运行一样）。
    private func twoTabs() -> (TabID, TabID) {
        var list = TabList()
        let one = list.selected
        guard case .added(let two) = list.append(select: false) else { fatalError("加得进") }
        return (one, two)
    }

    /// 每样带它自己的标签页；关闭的那个说“已关闭的”。四种语言，用各自表里说标签页的词（简体“标签页”、繁体“分頁”、日文“タブ”、
    /// 英文“Tab”），前面一个标签、后面原来的文字一字不差。
    func testEachResultShowsItsOwnTabInEveryLanguage() {
        let d = Diagnostics()
        let (one, two) = twoTabs()
        var c = Diagnostics.PageCapabilities()
        c.pageKind = "chat"
        c.location = "chatgpt.com/c/<id>"
        c.tab = two
        d.capabilities = c
        d.recordWebMediaState("playing", tab: one)
        d.recordReadAloudEvidence("{\"dom\":1}", tab: two)
        d.recordMediaMeasurement("rate=1.5", tab: one)
        d.recordExperiment("测量：x", tab: two)
        d.recordExperiment("测量：y", tab: one)
        d.recordExperiment("测量：z")
        d.tabClosed(two)

        let labels: [(AppLanguage, open: String, closed: String)] = [
            (.english, "[Tab 1] ", "[Closed tab 2] "),
            (.japanese, "【タブ 1】", "【閉じたタブ 2】"),
            (.simplifiedChinese, "【标签页 1】", "【已关闭的标签页 2】"),
            (.traditionalChinese, "【分頁 1】", "【已關閉的分頁 2】"),
        ]
        for (language, open, closed) in labels {
            let texts = DiagnosticsView.pageTexts(d, in: language)
            XCTAssertEqual(texts, DiagnosticsView.PageTexts(
                page: closed + "chat · chatgpt.com/c/<id>",
                media: open + L10n.format("diag.readAloud.media", in: language, "playing"),
                structure: closed + L10n.format("diag.readAloud.structure", in: language, "{\"dom\":1}"),
                rate: open + L10n.format("diag.readAloud.rate", in: language, "rate=1.5"),
                experiments: [closed + d.experiments[0], open + d.experiments[1], d.experiments[2]]), "\(language)")
        }
    }

    /// 没有标签的（还没写过、测试里单独建的适配器写的）照原样，不带标签。
    func testUntaggedResultsAreShownAsBefore() {
        let d = Diagnostics()
        d.recordExperiment("测量：x")
        let texts = DiagnosticsView.pageTexts(d, in: .simplifiedChinese)
        XCTAssertEqual(texts, DiagnosticsView.PageTexts(
            page: "unknown · <nil>",
            media: L10n.format("diag.readAloud.media", in: .simplifiedChinese, "unknown"),
            structure: "结构：未采集",
            rate: "速率测量：未测量",
            experiments: [d.experiments[0]]))
    }

    /// 标签 2 选中时采集证据、做实验、读媒体状态：每样都标标签 2。换成选中标签 1，窗口的文字一字不变（不跟着标成 1）。
    /// 窗口开着时关闭标签 2：每样改说“已关闭的标签页 2”，没有一样标成选中的标签 1。
    /// 关闭时标签 2 正在读媒体状态，读完的结果到达：不写进诊断（照原来的规则），窗口仍是关闭前那次、说已关闭的 2。
    /// 之后真有标签 2 的结果写进来（任何还会写的路），也说已关闭的 2，不标成选中的 1。标签 1 自己的新结果标 1。
    func testAResultKeepsItsTabAcrossSelectionAndSaysClosedOnceItsTabCloses() async throws {
        let rig = make()
        let d = rig.diagnostics
        let one = rig.first
        let two = rig.add()
        rig.tabs.select(two)
        rig.tabs.evidenceTarget = { tab in LabelEvidence(tab: tab) }
        await rig.tabs.collectEvidence(measure: true)
        await rig.tabs.runExperiment(.pauseAll)
        rig.tabs.mediaTick()
        try await waitUntil { d.webMediaState == "媒体2" }
        XCTAssertEqual(d.webMediaState, "媒体2")

        let zh = AppLanguage.simplifiedChinese
        let shown = DiagnosticsView.pageTexts(d, in: zh)
        for text in [shown.page, shown.media, shown.structure, shown.rate] + shown.experiments {
            XCTAssertTrue(text.hasPrefix("【标签页 2】"), text)
        }
        rig.tabs.select(one)
        XCTAssertEqual(DiagnosticsView.pageTexts(d, in: zh), shown, "换了选中的，窗口里的标签不变")

        // 标签 2 再选中、开始读媒体状态（0.3 秒才回来），读的时候关闭它（关闭显示着的：先换到标签 1）。
        rig.tabs.select(two)
        rig.delays["media"] = 0.3
        let reads = rig.mediaRead.count
        rig.tabs.mediaTick()
        try await waitUntil { rig.mediaRead.count == reads + 1 }
        rig.tabs.closeTab(two)
        XCTAssertTrue(rig.tabs.isSelected(one))
        func closedTwo(_ text: String) -> String { text.replacingOccurrences(of: "【标签页 2】", with: "【已关闭的标签页 2】") }
        let closed = DiagnosticsView.PageTexts(page: closedTwo(shown.page), media: closedTwo(shown.media),
                                               structure: closedTwo(shown.structure), rate: closedTwo(shown.rate),
                                               experiments: shown.experiments.map(closedTwo))
        XCTAssertEqual(DiagnosticsView.pageTexts(d, in: zh), closed, "关闭以后马上说已关闭的")
        try await pause(0.5)
        XCTAssertEqual(d.webMediaState, "媒体2", "关闭以后到达的结果不写")
        XCTAssertEqual(DiagnosticsView.pageTexts(d, in: zh), closed, "不标成选中的标签 1")

        d.recordExperiment("迟到的结果", tab: two.id)
        XCTAssertEqual(DiagnosticsView.pageTexts(d, in: zh).experiments.last, "【已关闭的标签页 2】" + d.experiments.last!)

        rig.delays["media"] = 0
        await rig.tabs.runExperiment(.setRate(1.5))
        XCTAssertEqual(DiagnosticsView.pageTexts(d, in: zh).experiments.last, "【标签页 1】" + d.experiments.last!)
        XCTAssertEqual(DiagnosticsView.pageTexts(d, in: zh).experiments.dropLast(2), closed.experiments[...],
                       "之前的几条不变")
    }

    /// 窗口靠 objectWillChange 重画（@ObservedObject）。关闭标签页时只有“已关闭的”那一样变：也要发出通知，开着的窗口才会改说已关闭的。
    /// 没有标签的（nil）不记，不发。
    func testClosingATabTellsAnOpenWindowToRedraw() {
        let d = Diagnostics()
        let (_, two) = twoTabs()
        d.recordReadAloudEvidence("{}", tab: two)
        let before = DiagnosticsView.pageTexts(d, in: .english).structure
        var changes = 0
        let watch = d.objectWillChange.sink { changes += 1 }
        d.tabClosed(two)
        XCTAssertEqual(changes, 1, "关闭标签页要通知窗口重画")
        XCTAssertEqual(before, "[Tab 2] Structure: {}")
        XCTAssertEqual(DiagnosticsView.pageTexts(d, in: .english).structure, "[Closed tab 2] Structure: {}")
        d.tabClosed(nil)
        XCTAssertEqual(changes, 1)
        withExtendedLifetime(watch) {}
    }

    /// 实验记录最多留 50 条，去掉最早的那条时它的标签页一起去掉。窗口显示的最近 6 条，每条的标签页和报告里同一条的一样
    /// （开着的、已关闭的都对得上）。每 3 条一条标签 2（不是隔一条）：错开 44 条（最早的 6 个标签页配最近的 6 条）对不上。
    func testTrimmedExperimentsKeepTheirTabsInTheWindowAsInTheReport() {
        let d = Diagnostics()
        let (one, two) = twoTabs()
        for i in 0..<53 { d.recordExperiment("第 \(i) 条", tab: i.isMultiple(of: 3) ? two : one) }
        d.tabClosed(two)
        XCTAssertEqual(d.experiments.count, 50)
        XCTAssertEqual(d.experimentTabs.count, 50)

        let window = DiagnosticsView.pageTexts(d, in: .simplifiedChinese).experiments
        let report = d.report(build: "test").components(separatedBy: "\n").filter { $0.hasPrefix("    ") && $0.contains(" 第 ") }
        XCTAssertEqual(report.count, 50)
        XCTAssertEqual(window.count, 6)
        for (offset, (shown, reported)) in zip(window, report.suffix(6)).enumerated() {
            let record = d.experiments[44 + offset]
            let n = 47 + offset
            XCTAssertTrue(record.hasSuffix(" 第 \(n) 条"), record)
            if n.isMultiple(of: 3) {
                XCTAssertEqual(shown, "【已关闭的标签页 2】" + record)
                XCTAssertEqual(reported, "    \(record) 【已关闭的标签2】")
            } else {
                XCTAssertEqual(shown, "【标签页 1】" + record)
                XCTAssertEqual(reported, "    \(record) 【标签1】")
            }
        }
    }
}

/// 证据和实验的步骤换成替身：页面能力用这个标签页真的适配器探测（网页视图没有地址：不是聊天页面，不跑脚本），
/// 别的步骤马上返回带它序号的字样。
@MainActor
private struct LabelEvidence: EvidenceTarget {
    let tab: ChatTab

    private var n: Int { tab.id.rawValue }
    func probe() async { await tab.adapter.probe() }
    func readAloudEvidence() async -> String { "证据 \(n)" }
    func measureMedia() async -> String { "测量 \(n)" }
    func webMediaState() async -> String { "媒体态 \(n)" }
    func experimentSetRate(_ rate: Double) async -> String { "速率 \(n)" }
    func setAllMediaPlaybackSuspended(_ suspended: Bool) async -> String { "ok" }
    func pauseAllMediaPlayback() async -> String { "ok" }
}
