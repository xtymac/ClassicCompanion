import WebKit
import CompanionCore

/// 证据采集和媒体实验（诊断窗口的按钮、命令行通知）对一个标签页做的几样：读它的适配器、动它的网页视图的媒体播放。
/// 只读或只做实验，脱敏。正式运行是 TabEvidenceTarget；抽成协议是为了不开网页也能核对每一步都对开始时的那个标签页做
/// （测试换成记录）。
@MainActor
protocol EvidenceTarget {
    func probe() async
    func readAloudEvidence() async -> String
    func measureMedia() async -> String
    func webMediaState() async -> String
    func experimentSetRate(_ rate: Double) async -> String
    func setAllMediaPlaybackSuspended(_ suspended: Bool) async
    func pauseAllMediaPlayback() async
}

/// 正式运行：标签页 tab 的适配器和网页视图。
@MainActor
struct TabEvidenceTarget: EvidenceTarget {
    let tab: ChatTab

    func probe() async { await tab.adapter.probe() }
    func readAloudEvidence() async -> String { await tab.adapter.readAloudEvidence() }
    func measureMedia() async -> String { await tab.adapter.measureMedia() }
    func webMediaState() async -> String { await tab.adapter.webMediaState() }
    func experimentSetRate(_ rate: Double) async -> String { await tab.adapter.experimentSetRate(rate) }
    func setAllMediaPlaybackSuspended(_ suspended: Bool) async { await tab.runtime.webView.setAllMediaPlaybackSuspended(suspended) }
    func pauseAllMediaPlayback() async { await tab.runtime.webView.pauseAllMediaPlayback() }
}

/// 证据采集和媒体实验的步骤，原来写在 AppDelegate 里，步骤和顺序不变。
/// target 是开始时绑定的那个标签页的（ChatTabs 传开始这一刻选中的那个），每一步都对它做。
/// 每次等完先问 isHeld：那个标签页已经不在这组里就不再往下做，已经写进诊断的留着。写报告文件由调用方在之后做。
/// tab 是那个标签页的标识：写进诊断的结构证据、速率测量、实验记录都记下它（报告里那一行带它的标签，见 Diagnostics.reportTag），
/// 实验那一行日志也带上它的标签（nil 不带，见 Diagnostics.recordExperiment）。
@MainActor
enum PageEvidence {
    static func collect(from target: some EvidenceTarget, measure: Bool, into diagnostics: Diagnostics,
                        tab: TabID?, isHeld: () -> Bool) async {
        await target.probe()
        guard isHeld() else { return }
        let evidence = await target.readAloudEvidence()
        guard isHeld() else { return }
        diagnostics.recordReadAloudEvidence(evidence, tab: tab)
        guard measure else { return }
        let measured = await target.measureMedia()
        guard isHeld() else { return }
        diagnostics.recordMediaMeasurement(measured, tab: tab)
    }

    static func runExperiment(_ kind: ExperimentKind, on target: some EvidenceTarget, diagnostics: Diagnostics,
                              tab: TabID?, isHeld: () -> Bool) async {
        switch kind {
        case .suspendAll:
            await target.setAllMediaPlaybackSuspended(true)
            guard isHeld() else { return }
            let state = await target.webMediaState()
            guard isHeld() else { return }
            diagnostics.recordExperiment("WebKit setAllMediaPlaybackSuspended(true) → 状态 \(state)", tab: tab)
        case .resumeAll:
            await target.setAllMediaPlaybackSuspended(false)
            guard isHeld() else { return }
            let state = await target.webMediaState()
            guard isHeld() else { return }
            diagnostics.recordExperiment("WebKit setAllMediaPlaybackSuspended(false) → 状态 \(state)", tab: tab)
        case .pauseAll:
            await target.pauseAllMediaPlayback()
            guard isHeld() else { return }
            let state = await target.webMediaState()
            guard isHeld() else { return }
            diagnostics.recordExperiment("WebKit pauseAllMediaPlayback → 状态 \(state)", tab: tab)
        case .setRate(let r):
            let result = await target.experimentSetRate(r)
            guard isHeld() else { return }
            diagnostics.recordExperiment("DOM playbackRate=\(r)：\(result)", tab: tab)
        case .measure:
            let measured = await target.measureMedia()
            guard isHeld() else { return }
            diagnostics.recordMediaMeasurement(measured, tab: tab)
            diagnostics.recordExperiment("测量：\(diagnostics.mediaMeasurement)", tab: tab)
        }
    }
}
