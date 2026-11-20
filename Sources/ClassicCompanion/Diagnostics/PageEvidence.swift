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
    /// 返回 "ok"、"timeout" 或 "closed"（等的时候关闭了，见 ChatGPTAdapter.mediaRequest(_:)），下面一个也一样。
    func setAllMediaPlaybackSuspended(_ suspended: Bool) async -> String
    func pauseAllMediaPlayback() async -> String
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
    /// 暂停、挂起经适配器（有时限、关闭以后不做，见 ChatGPTAdapter.mediaRequest(_:)），不直接等网页视图。
    func setAllMediaPlaybackSuspended(_ suspended: Bool) async -> String { await tab.adapter.setAllMediaPlaybackSuspended(suspended) }
    func pauseAllMediaPlayback() async -> String { await tab.adapter.pauseAllMediaPlayback() }
}

/// 证据采集和媒体实验的步骤，原来写在 AppDelegate 里，步骤和顺序不变。
/// target 是开始时绑定的那个标签页的（ChatTabs 传开始这一刻选中的那个），每一步都对它做。
/// 每次等完先问 isHeld：那个标签页已经不在这组里就不再往下做，已经写进诊断的留着，写一行“没有做完”（stopped）。
/// 写报告文件由调用方在之后做（报告的最近日志里有这一行）。
/// tab 是那个标签页的标识：写进诊断的结构证据、速率测量、实验记录都记下它（报告里那一行带它的标签，见 Diagnostics.reportTag），
/// 实验那一行日志、“没有做完”那一行也带上它的标签（nil 不带，见 Diagnostics.recordExperiment、TabLog）。
@MainActor
enum PageEvidence {
    static func collect(from target: some EvidenceTarget, measure: Bool, into diagnostics: Diagnostics,
                        tab: TabID?, isHeld: () -> Bool) async {
        let stop = Stop(what: "证据采集", diagnostics: diagnostics, tab: tab)
        await target.probe()
        guard isHeld() else { return stop(at: .script("探测页面能力")) }
        let evidence = await target.readAloudEvidence()
        guard isHeld() else { return stop(at: .mixed("读朗读结构")) }
        diagnostics.recordReadAloudEvidence(evidence, tab: tab)
        guard measure else { return }
        let measured = await target.measureMedia()
        guard isHeld() else { return stop(at: .mixed("测量速率")) }
        diagnostics.recordMediaMeasurement(measured, tab: tab)
    }

    static func runExperiment(_ kind: ExperimentKind, on target: some EvidenceTarget, diagnostics: Diagnostics,
                              tab: TabID?, isHeld: () -> Bool) async {
        let stop = Stop(what: "媒体实验“\(name(of: kind))”", diagnostics: diagnostics, tab: tab)
        switch kind {
        case .suspendAll:
            let done = await target.setAllMediaPlaybackSuspended(true)
            guard isHeld() else { return stop(at: .media("全部挂起", done)) }
            let state = await target.webMediaState()
            guard isHeld() else { return stop(at: .media("读媒体状态", state)) }
            diagnostics.recordExperiment("WebKit setAllMediaPlaybackSuspended(true) → 状态 \(state)", tab: tab)
        case .resumeAll:
            let done = await target.setAllMediaPlaybackSuspended(false)
            guard isHeld() else { return stop(at: .media("全部恢复", done)) }
            let state = await target.webMediaState()
            guard isHeld() else { return stop(at: .media("读媒体状态", state)) }
            diagnostics.recordExperiment("WebKit setAllMediaPlaybackSuspended(false) → 状态 \(state)", tab: tab)
        case .pauseAll:
            let done = await target.pauseAllMediaPlayback()
            guard isHeld() else { return stop(at: .media("全部暂停", done)) }
            let state = await target.webMediaState()
            guard isHeld() else { return stop(at: .media("读媒体状态", state)) }
            diagnostics.recordExperiment("WebKit pauseAllMediaPlayback → 状态 \(state)", tab: tab)
        case .setRate(let r):
            let result = await target.experimentSetRate(r)
            guard isHeld() else { return stop(at: .mixed("设置播放速度并测量")) }
            diagnostics.recordExperiment("DOM playbackRate=\(r)：\(result)", tab: tab)
        case .measure:
            let measured = await target.measureMedia()
            guard isHeld() else { return stop(at: .mixed("测量速率")) }
            diagnostics.recordMediaMeasurement(measured, tab: tab)
            diagnostics.recordExperiment("测量：\(diagnostics.mediaMeasurement)", tab: tab)
        }
    }

    /// “没有做完”那一行里说的实验名字，和它做完时实验记录开头的写法一样。
    private static func name(of kind: ExperimentKind) -> String {
        switch kind {
        case .suspendAll: "WebKit setAllMediaPlaybackSuspended(true)"
        case .resumeAll: "WebKit setAllMediaPlaybackSuspended(false)"
        case .pauseAll: "WebKit pauseAllMediaPlayback"
        case .setRate(let r): "DOM playbackRate=\(r)"
        case .measure: "测量"
        }
    }

    /// 标签页关闭时在等的那一步：名字，和正式运行（TabEvidenceTarget → 适配器）里这一步等的是什么。
    private enum Step: Equatable {
        /// 只等一个网页脚本（探测页面能力，ChatGPTAdapter.probe()）。
        case script(String)
        /// 只等一个 WebKit 的媒体请求（全部挂起、恢复、暂停，读媒体状态），带这一步返回的结果。
        case media(String, String)
        /// 先后等媒体请求和网页脚本（读朗读结构、测量速率、设置播放速度并测量）。
        case mixed(String)
    }

    /// 一次采集或实验没有做完：开始时的那个标签页在等某一步时关闭了（等完问 isHeld，它已经不在这组里）。
    /// 写一行日志（“[diag] …”，带那个标签页的标签，没有标题、地址、内容）：做的是什么、在哪一步、这一步的结果丢弃了。
    /// 关于那一步本身只说确实知道的，不说“已取消”（关闭取消不了已经开始的脚本，也撤回不了已经交给 WebKit 的请求）：
    /// - 网页脚本：关闭不取消它（ChatGPTAdapter.close()），这一步要等它返回、出错或超时才返回，结果是那以后丢弃的。
    /// - 媒体请求，这一步返回的是 "closed"：是关闭让它马上结束的，不再等 WebKit 回答（ChatGPTAdapter.mediaRequest(_:)）；
    ///   已经交给 WebKit 的请求没有撤回，WebKit 做没做不知道。
    /// - 媒体请求返回的是别的（WebKit 在关闭生效之前已经回答、或到了时限），或者分不清在等哪一个（mixed）：只说结果丢弃。
    /// 每次采集、实验最多写一次：每一步等完都问，第一次问出不在了就写这一行并结束，之后的步骤都不做；做完了不写。
    @MainActor
    private struct Stop {
        let what: String
        let diagnostics: Diagnostics
        let tab: TabID?

        func callAsFunction(at step: Step) {
            TabLog(diagnostics: diagnostics, tab: tab)("diag", Self.line(what, at: step))
        }

        static func line(_ what: String, at step: Step) -> String {
            let name: String
            switch step {
            case .script(let n), .media(let n, _), .mixed(let n): name = n
            }
            let discarded = "\(what)没有做完：标签页在“\(name)”这一步关闭，这一步的结果丢弃"
            switch step {
            case .script: return discarded + "；网页脚本没有取消，是它返回、出错或超时以后丢弃的"
            case .media(_, "closed"): return discarded + "；关闭时马上不再等 WebKit 回答，已交给 WebKit 的请求没有撤回"
            case .media, .mixed: return discarded
            }
        }
    }
}
