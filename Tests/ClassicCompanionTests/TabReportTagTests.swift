import AppKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 诊断报告（Diagnostics.report(build:)）里说某一个页面的那几行带上那个标签页的标签：页面能力那一段的开头、最近一次回答提取、
/// WebKit 媒体状态、结构证据、速率测量、每一条实验记录。标签是开始读、开始采集这一刻绑定的那个标签页的（不是写进来时选中的）；
/// 那个标签页之后关闭了，那一行留着、写“已关闭的标签N”，不去掉、不标成别的标签页。只有创建序号，没有标题、地址。
/// 用 TabCloseRig（正式的建法，日志带标签）；证据和实验的步骤换成记录（TaggedEvidence），页面能力用真的适配器探测
/// （网页视图没有地址：不是聊天页面，不跑脚本）。窗口从不显示。
@MainActor
final class TabReportTagTests: XCTestCase {
    private func make() -> TabCloseRig {
        let name = "TabReportTagTests-\(UUID().uuidString)"
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

    /// 报告里 [页面能力] 和 [官方 Read Aloud 证据] 两段（到 [Gate C 计数] 之前），检查时间、实验记录的时间换成“…”。
    private func pageLines(_ diagnostics: Diagnostics) -> [String] {
        let report = diagnostics.report(build: "test").components(separatedBy: "\n")
        guard let start = report.firstIndex(where: { $0.hasPrefix("[页面能力]") }),
              let end = report.firstIndex(where: { $0.hasPrefix("[Gate C 计数]") }) else { return [] }
        return report[start..<end].filter { !$0.isEmpty }.map {
            $0.replacingOccurrences(of: #"检查于 \d\S+"#, with: "检查于 …", options: .regularExpression)
                .replacingOccurrences(of: #"^    \d\d:\d\d:\d\d "#, with: "    … ", options: .regularExpression)
        }
    }

    /// 标签 2 选中时开始采集证据，第一步里换成选中标签 1：页面能力、结构、测量都标标签 2。
    /// 选中标签 1 时开始读媒体状态，读的时候换成选中标签 2：媒体状态标标签 1。
    /// 选中标签 2 时开始实验，第一步里换成标签 1：实验记录标标签 2；之后选中标签 1 时的实验标标签 1。
    func testEachLineCarriesTheTabBoundWhenItsReadStarted() async throws {
        let rig = make()
        let one = rig.first
        let two = rig.add()
        rig.tabs.select(two)
        let switchTo = Box<ChatTab?>(one)
        rig.tabs.evidenceTarget = { [weak rig] tab in
            TaggedEvidence(tab: tab) {
                guard let rig, let next = switchTo.value else { return }
                rig.tabs.selectForTesting(next)
            }
        }
        await rig.tabs.collectEvidence(measure: true)
        XCTAssertTrue(rig.tabs.isSelected(one), "采集的第一步里换了选中的")

        rig.delays["media"] = 0.15
        rig.tabs.mediaTick()
        try await waitUntil { !rig.mediaRead.isEmpty }
        rig.tabs.selectForTesting(two)
        try await waitUntil { rig.diagnostics.webMediaState != "unknown" }

        switchTo.value = one
        await rig.tabs.runExperiment(.pauseAll)
        switchTo.value = nil
        await rig.tabs.runExperiment(.setRate(1.5))

        XCTAssertEqual(pageLines(rig.diagnostics), [
            "[页面能力] 检查于 … 【标签2】",
            "  页面类型=none 位置=<nil>",
            "  输入框=false 已聚焦=false 消息数=0 助手消息数=0",
            "  生成中=false 弹层=false 登录按钮可见=false",
            "  最近一次回答提取=未执行",
            "  选择器命中=-",
            "[官方 Read Aloud 证据]",
            "  WebKit 媒体状态=媒体1 【标签1】",
            "  结构=证据 2 【标签2】",
            "  速率测量=测量 2 【标签2】",
            "  实验记录:",
            "    … WebKit pauseAllMediaPlayback → 状态 媒体态 2 【标签2】",
            "    … DOM playbackRate=1.5：速率 1 【标签1】",
        ])
    }

    /// 写下那几行的标签页之后关闭了：那几行留着，标签写“已关闭的标签N”；别的标签页的照常。之后新加的标签页是新的序号。
    /// 采集进行到一半时关闭：已经写下的（页面能力）留着、标已关闭，剩下的不再写（照原来的规则）。
    func testLinesOfAClosedTabStayAndSayTheTabIsClosed() async throws {
        let rig = make()
        let one = rig.first
        let two = rig.add()
        rig.tabs.select(two)
        rig.tabs.evidenceTarget = { tab in TaggedEvidence(tab: tab) {} }
        await rig.tabs.collectEvidence(measure: true)
        await rig.tabs.runExperiment(.pauseAll)
        rig.tabs.select(one)
        await rig.tabs.runExperiment(.setRate(1.5))
        rig.tabs.close(two)

        XCTAssertEqual(pageLines(rig.diagnostics).filter { $0.contains("标签") }, [
            "[页面能力] 检查于 … 【已关闭的标签2】",
            "  结构=证据 2 【已关闭的标签2】",
            "  速率测量=测量 2 【已关闭的标签2】",
            "    … WebKit pauseAllMediaPlayback → 状态 媒体态 2 【已关闭的标签2】",
            "    … DOM playbackRate=1.5：速率 1 【标签1】",
        ])

        // 标签 3 采集到一半（页面能力写下以后）被关掉：页面能力标已关闭的标签 3，结构和测量还是标签 2 的那次（也已关闭）。
        let three = rig.add()
        rig.tabs.select(three)
        rig.tabs.evidenceTarget = { [weak rig, weak one] tab in
            TaggedEvidence(tab: tab) { [weak tab] in
                guard let rig, let one, let tab else { return }
                rig.tabs.select(one)
                rig.tabs.close(tab)
            }
        }
        await rig.tabs.collectEvidence(measure: true)
        XCTAssertFalse(rig.tabs.holds(three))
        XCTAssertEqual(pageLines(rig.diagnostics).filter { $0.contains("标签") }, [
            "[页面能力] 检查于 … 【已关闭的标签3】",
            "  结构=证据 2 【已关闭的标签2】",
            "  速率测量=测量 2 【已关闭的标签2】",
            "    … WebKit pauseAllMediaPlayback → 状态 媒体态 2 【已关闭的标签2】",
            "    … DOM playbackRate=1.5：速率 1 【标签1】",
        ])
    }

    /// 每次探测写下的是这个标签页的一份完整快照：不留上一次（别的标签页）探测的计数和选择器命中；
    /// 最近一次回答提取是另外记的，留着、标它自己的标签页。
    func testAProbeWritesAWholeSnapshotOfItsOwnTab() async throws {
        let rig = make()
        let two = rig.add()
        var earlier = Diagnostics.PageCapabilities()
        earlier.pageKind = "chat"
        earlier.messageCount = 7
        earlier.assistantCount = 3
        earlier.inputFound = true
        earlier.selectorHits = "input=0/1"
        earlier.lastExtraction = "ok：文本块 2，提示 0，5ms"
        earlier.tab = rig.first.id
        earlier.extractionTab = rig.first.id
        rig.diagnostics.capabilities = earlier

        await two.adapter.probe()
        let c = rig.diagnostics.capabilities
        XCTAssertEqual(c.tab, two.id)
        XCTAssertEqual(c.pageKind, "none")
        XCTAssertEqual(c.messageCount, 0)
        XCTAssertEqual(c.assistantCount, 0)
        XCTAssertFalse(c.inputFound)
        XCTAssertEqual(c.selectorHits, "-")
        XCTAssertNotNil(c.checkedAt)
        XCTAssertEqual(c.lastExtraction, earlier.lastExtraction)
        XCTAssertEqual(c.extractionTab, rig.first.id)
        XCTAssertEqual(Array(pageLines(rig.diagnostics).prefix(5)), [
            "[页面能力] 检查于 … 【标签2】",
            "  页面类型=none 位置=<nil>",
            "  输入框=false 已聚焦=false 消息数=0 助手消息数=0",
            "  生成中=false 弹层=false 登录按钮可见=false",
            "  最近一次回答提取=ok：文本块 2，提示 0，5ms 【标签1】",
        ])
    }

    /// 真的网页（本地 html，地址是一个对话地址，不联网、不放进窗口）：标签 2 的适配器探测和提取回答，页面能力那一段和
    /// 最近一次回答提取都标标签 2；报告里没有对话 id（位置经 Redactor）。关闭以后再提取，最近一次回答提取不变
    /// （原来关闭的适配器会写“超时/脚本失败”）。
    func testARealProbeAndExtractionOnAChatPageCarryTheirTab() async throws {
        let rig = make()
        let two = rig.add()
        let web = two.runtime.webView
        let chat = URL(string: "https://chatgpt.com/c/abc123def")!
        web.loadHTMLString("<html><body><main>x</main></body></html>", baseURL: chat)
        try await waitUntil(5) { web.url == chat && !web.isLoading }
        XCTAssertEqual(web.url, chat)

        await two.adapter.probe()
        _ = await two.adapter.extractLatestAnswer()
        let c = rig.diagnostics.capabilities
        XCTAssertEqual(c.pageKind, "chat")
        XCTAssertEqual(c.tab, two.id)
        XCTAssertEqual(c.extractionTab, two.id)
        XCTAssertNotEqual(c.lastExtraction, "未执行")
        let lines = pageLines(rig.diagnostics)
        XCTAssertEqual(lines.first, "[页面能力] 检查于 … 【标签2】")
        XCTAssertTrue(lines.contains { $0.hasPrefix("  最近一次回答提取=") && $0.hasSuffix(" 【标签2】") }, "\(lines)")
        XCTAssertFalse(rig.diagnostics.report(build: "test").contains("abc123def"), "没有对话 id")

        let extraction = c.lastExtraction
        two.adapter.close()
        _ = await two.adapter.extractLatestAnswer()
        XCTAssertEqual(rig.diagnostics.capabilities.lastExtraction, extraction, "关闭以后不写")
    }

    /// 没有标签的（测试里单独建的适配器、还没写过的）一字不差照原来：不带标签。
    func testUntaggedLinesAreUnchanged() {
        let diagnostics = Diagnostics()
        diagnostics.recordExperiment("测量：x")
        XCTAssertEqual(pageLines(diagnostics), [
            "[页面能力] 检查于 -",
            "  页面类型=unknown 位置=<nil>",
            "  输入框=false 已聚焦=false 消息数=0 助手消息数=0",
            "  生成中=false 弹层=false 登录按钮可见=false",
            "  最近一次回答提取=未执行",
            "  选择器命中=-",
            "[官方 Read Aloud 证据]",
            "  WebKit 媒体状态=unknown",
            "  结构=未采集",
            "  速率测量=未测量",
            "  实验记录:",
            "    … 测量：x",
        ])
        XCTAssertEqual(diagnostics.reportTag(nil), "")
        diagnostics.tabClosed(nil)
    }

    /// 实验记录最多留 50 条：去掉最早的那条时它的标签也一起去掉，留下的每条还是自己的标签。
    func testTrimmedExperimentsKeepTheirOwnTags() {
        let diagnostics = Diagnostics()
        var list = TabList()
        guard case .added(let two) = list.append(select: false) else { return XCTFail("加得进") }
        let one = list.selected
        for i in 0..<53 { diagnostics.recordExperiment("第 \(i) 条", tab: i.isMultiple(of: 2) ? one : two) }
        let lines = pageLines(diagnostics).filter { $0.hasPrefix("    … ") }
        XCTAssertEqual(lines.count, 50)
        XCTAssertEqual(lines.first, "    … 第 3 条 【标签2】")
        XCTAssertEqual(lines.last, "    … 第 52 条 【标签1】")
        for line in lines {
            let n = Int(line.split(separator: " ")[2])!
            XCTAssertTrue(line.hasSuffix(n.isMultiple(of: 2) ? "【标签1】" : "【标签2】"), line)
        }
    }
}

@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// 证据和实验的步骤换成记录：页面能力用这个标签页真的适配器探测，别的步骤返回带它序号的字样。
/// 第一步（探测、暂停、挂起）做完调用 onFirstStep（测试在这里换选中的、关闭标签页）。
@MainActor
private struct TaggedEvidence: EvidenceTarget {
    let tab: ChatTab
    let onFirstStep: @MainActor () -> Void

    init(tab: ChatTab, onFirstStep: @escaping @MainActor () -> Void) {
        self.tab = tab
        self.onFirstStep = onFirstStep
    }

    private var n: Int { tab.id.rawValue }
    func probe() async {
        await tab.adapter.probe()
        onFirstStep()
    }
    func readAloudEvidence() async -> String { "证据 \(n)" }
    func measureMedia() async -> String { "测量 \(n)" }
    func webMediaState() async -> String { "媒体态 \(n)" }
    func experimentSetRate(_ rate: Double) async -> String {
        onFirstStep()
        return "速率 \(n)"
    }
    func setAllMediaPlaybackSuspended(_ suspended: Bool) async { onFirstStep() }
    func pauseAllMediaPlayback() async { onFirstStep() }
}
