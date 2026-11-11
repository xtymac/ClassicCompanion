// 【历史探索代码，不在正式路径】1.2 版计划要求朗读使用 ChatGPT 官方 Read Aloud。
// 本类不再被实例化，不作为回退，不继续扩展；保留仅供追溯 Phase 0 第一轮的系统 TTS 测试。
import AVFoundation
import Combine
import WebKit
import CompanionCore

/// 系统 TTS（AVSpeechSynthesizer）朗读控制。
/// - 逐片段排队：暂停/继续由系统提供；语速变更从下一片段生效。
/// - 进度以“片段 i/n”表示文本位置，不伪装成时间进度。
/// - 朗读文本只保存在内存中直到停止，不写入日志或磁盘。
@MainActor
final class SpeechController: NSObject, ObservableObject {
    enum State: Equatable { case idle, preparing, speaking, paused }

    static let engineName = "系统 TTS（AVSpeechSynthesizer）"

    @Published private(set) var state: State = .idle
    @Published private(set) var segmentIndex = 0
    @Published private(set) var segmentCount = 0
    @Published private(set) var skippedCount = 0
    @Published private(set) var statusMessage = ""

    private let synthesizer = AVSpeechSynthesizer()
    private let settings: AppSettings
    private let diagnostics: Diagnostics
    private let adapter: ChatGPTAdapter
    private weak var webView: WKWebView?

    private var segments: [SpeechSegment] = []
    private var currentRef: AnswerRef?
    private var currentUtterance: AVSpeechUtterance?
    private var watchdog: Timer?
    private var voiceCache: [String: AVSpeechSynthesisVoice] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(settings: AppSettings, diagnostics: Diagnostics, adapter: ChatGPTAdapter, webView: WKWebView) {
        self.settings = settings
        self.diagnostics = diagnostics
        self.adapter = adapter
        self.webView = webView
        super.init()
        synthesizer.delegate = self
        settings.$rateLevel.dropFirst().sink { [weak self] level in
            guard let self, self.state != .idle else { return }
            self.statusMessage = "语速已改为「\(level.label)」，从下一片段生效"
        }.store(in: &cancellables)
    }

    // MARK: - 控制

    func readLatestAnswer() async {
        stop(reason: nil)
        state = .preparing
        statusMessage = "正在定位最新回答…"
        switch await adapter.extractLatestAnswer() {
        case .unavailable(let why):
            state = .idle
            statusMessage = why
        case .ok(let ref, let blocks):
            guard ref.generation == adapter.generation else {
                state = .idle
                statusMessage = "页面已切换，请重试"
                return
            }
            let segs = SpeechSegmenter.segments(from: blocks)
            guard !segs.isEmpty else {
                state = .idle
                statusMessage = "回答没有可朗读的文本"
                return
            }
            // 与网页朗读互斥：开始前暂停网页中正在播放的媒体
            await webView?.pauseAllMediaPlayback()
            segments = segs
            currentRef = ref
            segmentIndex = 0
            segmentCount = segs.count
            skippedCount = segs.filter(\.isNotice).count
            state = .speaking
            statusMessage = ""
            diagnostics.log("speech", "开始系统朗读：片段 \(segs.count)，跳过提示 \(skippedCount)，语言 \(Set(segs.map(\.language)).sorted().joined(separator: "/"))")
            startWatchdog()
            speakCurrent()
        }
    }

    func togglePause() {
        switch state {
        case .speaking: pause()
        case .paused: resume()
        default: break
        }
    }

    func pause() {
        guard state == .speaking else { return }
        if synthesizer.pauseSpeaking(at: .word) {
            state = .paused
        }
    }

    func resume() {
        guard state == .paused else { return }
        if synthesizer.continueSpeaking() {
            state = .speaking
        } else {
            // 部分系统版本在片段边界暂停后 continue 会失败：清空队列后从当前片段重新开始
            // （被取消片段的 didFinish 会因 currentUtterance 已替换而被忽略）
            synthesizer.stopSpeaking(at: .immediate)
            speakCurrent()
            state = .speaking
        }
    }

    func stop(reason: String?) {
        let wasActive = state != .idle
        watchdog?.invalidate()
        watchdog = nil
        currentUtterance = nil
        segments = []          // 释放朗读文本
        currentRef = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        state = .idle
        segmentIndex = 0
        segmentCount = 0
        skippedCount = 0
        if let reason {
            statusMessage = reason
            if wasActive { diagnostics.log("speech", "停止：\(reason)") }
        }
    }

    // MARK: - 内部

    private func speakCurrent() {
        guard segmentIndex < segments.count else {
            let total = segmentCount
            stop(reason: nil)
            statusMessage = "朗读完成（共 \(total) 片段）"
            diagnostics.log("speech", "朗读完成")
            return
        }
        let seg = segments[segmentIndex]
        let utterance = AVSpeechUtterance(string: seg.text)
        utterance.voice = voice(for: seg.language)
        utterance.rate = settings.rateLevel.utteranceRate
        utterance.postUtteranceDelay = seg.isNotice ? 0.15 : 0.05
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    private func voice(for language: String) -> AVSpeechSynthesisVoice? {
        if let cached = voiceCache[language] { return cached }
        // 默认使用系统为该语言指定的语音；仅当存在同地区的增强/高级语音时改用它。排除趣味语音。
        let enhanced = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language && $0.quality != .default && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        let best = enhanced ?? AVSpeechSynthesisVoice(language: language)
        if let best {
            voiceCache[language] = best
            diagnostics.log("speech", "语音 \(language) → \(best.language) quality=\(best.quality.rawValue)")
        } else {
            diagnostics.log("speech", "未找到 \(language) 语音，使用系统默认")
        }
        return best
    }

    fileprivate func utteranceFinished(_ utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance, state != .idle else { return }
        segmentIndex += 1
        speakCurrent()
    }

    /// 监视：回答变化（重新生成/切换分支/切换对话）或网页开始播放音频时停止朗读。
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.checkStillValid() }
            }
        }
    }

    private func checkStillValid() async {
        guard state == .speaking || state == .paused, let ref = currentRef else { return }
        if let webView, await webView.requestMediaPlaybackState() == .playing {
            stop(reason: "网页开始播放音频（例如官方朗读），系统朗读已停止")
            return
        }
        switch await adapter.verify(ref) {
        case .changed:
            guard currentRef == ref else { return }
            stop(reason: "回答已变化（切换对话/重新生成/切换分支），朗读已停止")
        case .same, .unknown:
            break
        }
    }

    /// 页面导航（含 SPA 路由变化）时调用
    func pageDidNavigate() {
        if state != .idle {
            stop(reason: "对话已切换，朗读已停止")
        }
    }
}

extension SpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let box = UncheckedBox(utterance)
        Task { @MainActor in self.utteranceFinished(box.value) }
    }
}

/// AVSpeechUtterance 不是 Sendable；只用于把对象身份传回主线程比较，不跨线程修改。
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
