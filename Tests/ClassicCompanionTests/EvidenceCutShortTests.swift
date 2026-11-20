import AppKit
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 证据采集、媒体实验做到一半，开始时的那个标签页关闭了（PageEvidence）：写一行“[diag] …没有做完…”，每次采集、实验正好一行，
/// 带那个标签页的标签，没有标题、地址、内容。这一行分清“这一步的结果因关闭丢弃了”和关于那一步本身确实知道的：
/// 网页脚本没有取消（返回、出错或超时以后才丢弃）；媒体请求返回 "closed" 时是关闭让它马上结束、请求没有撤回；
/// 分不清的只说结果丢弃。从不说“已取消”。做完了的不写。
/// 用 TabCloseRig（窗口从不显示）；步骤换成替身（ClosingEvidence），在指定的那一步里经 closeTab 关闭标签页、返回指定的结果。
/// 最后一条用真的适配器和本地网页（不联网），核对探测那一步真的要等脚本返回。
@MainActor
final class EvidenceCutShortTests: XCTestCase {
    private func make() -> TabCloseRig {
        let name = "EvidenceCutShortTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabCloseRig(defaults: UserDefaults(suiteName: name)!)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        return rig
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private let discarded = "这一步的结果丢弃"
    private let scriptNote = "；网页脚本没有取消，是它返回、出错或超时以后丢弃的"
    private let mediaNote = "；关闭时马上不再等 WebKit 回答，已交给 WebKit 的请求没有撤回"

    /// 加一个标签页 2 并选中，替身在 closeAt 那一步里关闭它（closeTab：先换到标签 1）、返回 value。
    private func makeTwo(closeAt step: String?, value: String = "closed") -> (TabCloseRig, EvidenceScript) {
        let rig = make()
        let two = rig.add()
        rig.tabs.select(two)
        let script = EvidenceScript()
        script.closeAt = step
        script.value = value
        script.close = { [weak rig, weak two] in
            guard let rig, let two else { return }
            rig.tabs.closeTab(two)
        }
        rig.tabs.evidenceTarget = { tab in ClosingEvidence(script: script, tab: tab) }
        return (rig, script)
    }

    private func cutShortLines(_ rig: TabCloseRig, since mark: Int) -> [String] {
        rig.lines(since: mark).filter { $0.contains("没有做完") }
    }

    /// 每种采集、实验，在每一步关闭：正好一行（不管后面跳过了几步），说的是哪一步、结果丢弃；
    /// 探测（网页脚本）加“网页脚本没有取消”；媒体请求返回 "closed" 的加“关闭时马上不再等…没有撤回”，返回别的不加；
    /// 先后等媒体请求和脚本的（结构、测量、设置速度）只说结果丢弃。之后的步骤都没做。
    func testEachCutShortCaptureWritesOneLineThatSaysOnlyWhatIsKnown() async {
        typealias Run = @MainActor (ChatTabs) async -> Void
        let collect: Run = { await $0.collectEvidence(measure: true) }
        let collectOnly: Run = { await $0.collectEvidence(measure: false) }
        let suspend: Run = { await $0.runExperiment(.suspendAll) }
        let resume: Run = { await $0.runExperiment(.resumeAll) }
        let pause: Run = { await $0.runExperiment(.pauseAll) }
        let setRate: Run = { await $0.runExperiment(.setRate(1.5)) }
        let measure: Run = { await $0.runExperiment(.measure) }
        let evidence = "证据采集没有做完：标签页在"
        let suspendAll = "媒体实验“WebKit setAllMediaPlaybackSuspended(true)”没有做完：标签页在"
        let resumeAll = "媒体实验“WebKit setAllMediaPlaybackSuspended(false)”没有做完：标签页在"
        let pauseAll = "媒体实验“WebKit pauseAllMediaPlayback”没有做完：标签页在"
        let cases: [(String, Run, String, String, [String], String)] = [
            ("采集：探测", collect, "probe", "", ["probe"], evidence + "“探测页面能力”这一步关闭，" + discarded + scriptNote),
            ("采集：结构", collect, "readAloudEvidence", "{}", ["probe", "readAloudEvidence"],
             evidence + "“读朗读结构”这一步关闭，" + discarded),
            ("采集：测量", collect, "measureMedia", "closed", ["probe", "readAloudEvidence", "measureMedia"],
             evidence + "“测量速率”这一步关闭，" + discarded),
            ("只采集：结构", collectOnly, "readAloudEvidence", "closed", ["probe", "readAloudEvidence"],
             evidence + "“读朗读结构”这一步关闭，" + discarded),
            ("挂起：挂起 closed", suspend, "suspend", "closed", ["suspend"], suspendAll + "“全部挂起”这一步关闭，" + discarded + mediaNote),
            ("挂起：挂起 ok", suspend, "suspend", "ok", ["suspend"], suspendAll + "“全部挂起”这一步关闭，" + discarded),
            ("挂起：读状态 closed", suspend, "webMediaState", "closed", ["suspend", "webMediaState"],
             suspendAll + "“读媒体状态”这一步关闭，" + discarded + mediaNote),
            ("挂起：读状态 playing", suspend, "webMediaState", "playing", ["suspend", "webMediaState"],
             suspendAll + "“读媒体状态”这一步关闭，" + discarded),
            ("恢复：恢复 closed", resume, "resume", "closed", ["resume"], resumeAll + "“全部恢复”这一步关闭，" + discarded + mediaNote),
            ("恢复：读状态 timeout", resume, "webMediaState", "timeout", ["resume", "webMediaState"],
             resumeAll + "“读媒体状态”这一步关闭，" + discarded),
            ("暂停：暂停 closed", pause, "pauseAll", "closed", ["pauseAll"], pauseAll + "“全部暂停”这一步关闭，" + discarded + mediaNote),
            ("暂停：读状态 closed", pause, "webMediaState", "closed", ["pauseAll", "webMediaState"],
             pauseAll + "“读媒体状态”这一步关闭，" + discarded + mediaNote),
            ("设置速度", setRate, "setRate", "closed", ["setRate"],
             "媒体实验“DOM playbackRate=1.5”没有做完：标签页在“设置播放速度并测量”这一步关闭，" + discarded),
            ("测量", measure, "measureMedia", "closed", ["measureMedia"],
             "媒体实验“测量”没有做完：标签页在“测量速率”这一步关闭，" + discarded),
        ]
        for (name, run, step, value, steps, line) in cases {
            let (rig, script) = makeTwo(closeAt: step, value: value)
            let evidence = rig.diagnostics.readAloudEvidence, measured = rig.diagnostics.mediaMeasurement
            let experiments = rig.diagnostics.experiments
            let mark = rig.mark()
            await run(rig.tabs)
            XCTAssertEqual(script.steps, steps, name)
            XCTAssertEqual(cutShortLines(rig, since: mark), ["[diag] \(line) 【标签2】"], name)
            XCTAssertEqual(rig.diagnostics.mediaMeasurement, measured, name)
            XCTAssertEqual(rig.diagnostics.experiments, experiments, name)
            if step != "measureMedia" { XCTAssertEqual(rig.diagnostics.readAloudEvidence, evidence, name) }
        }
    }

    /// 做完了的（标签页一直在）：采集（测量、不测量）和每种实验都不写“没有做完”，结果照常写进诊断。
    func testACaptureThatFinishesWritesNoSuchLine() async {
        let runs: [(String, @MainActor (ChatTabs) async -> Void)] = [
            ("采集", { await $0.collectEvidence(measure: true) }),
            ("只采集", { await $0.collectEvidence(measure: false) }),
            ("挂起", { await $0.runExperiment(.suspendAll) }),
            ("恢复", { await $0.runExperiment(.resumeAll) }),
            ("暂停", { await $0.runExperiment(.pauseAll) }),
            ("设置速度", { await $0.runExperiment(.setRate(1.5)) }),
            ("测量", { await $0.runExperiment(.measure) }),
        ]
        let (rig, _) = makeTwo(closeAt: nil)
        let mark = rig.mark()
        for (_, run) in runs { await run(rig.tabs) }
        XCTAssertEqual(cutShortLines(rig, since: mark), [])
        XCTAssertEqual(rig.diagnostics.readAloudEvidence, "{}")
        XCTAssertEqual(rig.diagnostics.experiments.count, 5)
    }

    /// 调用方之后写的报告（这里只生成，不写文件）：关闭前写下的页面能力标“已关闭的标签2”，被丢弃的那一步（结构）和之后的
    /// （测量）不在报告里（还是原来的“未采集”“未测量”，不带标签），最近日志里有“没有做完”那一行，在关闭那一行之后。
    func testTheReportWrittenAfterwardsShowsTheLineAndNothingFromTheDiscardedSteps() async {
        let (rig, _) = makeTwo(closeAt: "readAloudEvidence")
        await rig.tabs.collectEvidence(measure: true)
        let report = rig.diagnostics.report(build: "test").components(separatedBy: "\n")
        XCTAssertTrue(report.contains { $0.hasPrefix("[页面能力] 检查于 ") && $0.hasSuffix(" 【已关闭的标签2】") }, "\(report)")
        XCTAssertTrue(report.contains("  结构=未采集"))
        XCTAssertTrue(report.contains("  速率测量=未测量"))
        let log = Array(report.drop { $0 != "[最近日志]" })
        let closed = log.firstIndex { $0.hasSuffix("[tabs] 关闭（剩 1 个） 【标签2】") }
        let cutShort = log.firstIndex {
            $0.hasSuffix("[diag] 证据采集没有做完：标签页在“读朗读结构”这一步关闭，这一步的结果丢弃 【标签2】")
        }
        XCTAssertNotNil(closed)
        XCTAssertNotNil(cutShort)
        if let closed, let cutShort { XCTAssertLessThan(closed, cutShort) }
        XCTAssertEqual(log.filter { $0.contains("没有做完") }.count, 1)
    }

    /// 真的适配器、本地网页（不联网，窗口不显示）：网页忙 2 秒时开始采集，探测脚本排在后面；开始后 0.3 秒关闭。
    /// 探测那一步等到网页不忙、脚本返回才返回（关闭没有让它马上结束），这时写的那一行说“网页脚本没有取消”；页面能力不写。
    func testARealProbeCutShortByACloseEndsOnlyWhenItsScriptDoes() async throws {
        let rig = make()
        let two = rig.add()
        rig.tabs.select(two)
        await rig.loadPage(two, "<html><body><main>x</main></body></html>")
        let web = two.runtime.webView
        XCTAssertEqual(web.url, URL(string: "https://chatgpt.com/c/abc"))
        let capabilities = rig.diagnostics.capabilities
        _ = try await web.evaluateJavaScript("setTimeout(() => { const end = Date.now() + 2000; while (Date.now() < end) {} }, 0); 0")
        try await pause(0.1)
        let task = Task { await rig.tabs.collectEvidence(measure: true) }
        try await pause(0.3)
        let mark = rig.mark()
        rig.tabs.closeTab(two)
        let closedAt = Date()
        await task.value
        XCTAssertGreaterThan(Date().timeIntervalSince(closedAt), 0.5, "探测那一步等脚本返回，不是关闭时马上结束")
        XCTAssertEqual(rig.lines(since: mark).filter { $0.contains("【标签2】") }, [
            "[tabs] 关闭（剩 1 个） 【标签2】",
            "[web] 关闭网页：停止加载 【标签2】",
            "[diag] 证据采集没有做完：标签页在“探测页面能力”这一步关闭，" + discarded + scriptNote + " 【标签2】",
        ])
        XCTAssertEqual(rig.diagnostics.capabilities, capabilities, "探测结果不写")
    }
}

/// 替身的步骤记录和设定：在 closeAt 那一步里调用 close（关闭标签页），那一步返回 value。
@MainActor
private final class EvidenceScript {
    var steps: [String] = []
    var closeAt: String?
    var value = "closed"
    var close: @MainActor () -> Void = {}
}

/// 证据和实验的步骤换成替身：每一步记下名字、让出去一下，到 closeAt 那一步关闭标签页并返回 value，别的返回固定的结果。
/// 探测用这个标签页真的适配器（网页视图没有地址：不是聊天页面，不跑脚本，马上写一份快照）。
@MainActor
private struct ClosingEvidence: EvidenceTarget {
    let script: EvidenceScript
    let tab: ChatTab

    private func step(_ name: String, _ normal: String) async -> String {
        script.steps.append(name)
        await Task.yield()
        guard name == script.closeAt else { return normal }
        script.close()
        return script.value
    }

    func probe() async {
        await tab.adapter.probe()
        _ = await step("probe", "")
    }
    func readAloudEvidence() async -> String { await step("readAloudEvidence", "{}") }
    func measureMedia() async -> String { await step("measureMedia", "测量") }
    func webMediaState() async -> String { await step("webMediaState", "paused") }
    func experimentSetRate(_ rate: Double) async -> String { await step("setRate", "set=ok") }
    func setAllMediaPlaybackSuspended(_ suspended: Bool) async -> String { await step(suspended ? "suspend" : "resume", "ok") }
    func pauseAllMediaPlayback() async -> String { await step("pauseAll", "ok") }
}
