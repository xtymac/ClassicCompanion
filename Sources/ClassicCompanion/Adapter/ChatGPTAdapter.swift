import Foundation
import WebKit
import CompanionCore

/// 已定位回答的引用。页面导航后由 generation 失效。
struct AnswerRef: Equatable {
    let generation: Int
    let path: String
    let ids: String
}

enum ExtractionResult {
    case ok(AnswerRef, [AnswerBlock])
    /// 无法朗读：附带给用户看的原因
    case unavailable(String)
}

enum VerifyResult {
    case same
    case changed
    case unknown
}

/// ChatGPT 网页适配器。所有 DOM 操作经此类进行；失败时返回明确状态，不做猜测性操作。
/// 不提供 submitMessage：Phase 0 发送完全由官方网页处理。
@MainActor
final class ChatGPTAdapter {
    private weak var webView: WKWebView?
    private let diagnostics: Diagnostics
    private let settings: AppSettings
    /// 每次主框架 URL 变化递增，使旧引用与进行中的调用失效
    private(set) var generation = 0
    private let timeout: TimeInterval = 2.5
    private var openingNewChat = false

    init(webView: WKWebView, diagnostics: Diagnostics, settings: AppSettings) {
        self.webView = webView
        self.diagnostics = diagnostics
        self.settings = settings
    }

    func invalidate() {
        generation += 1
    }

    var isEnabled: Bool { settings.webEnhancements }

    private var onChatPage: Bool {
        guard let url = webView?.url else { return false }
        return NavigationPolicy.classify(url) == .chat && url.host == "chatgpt.com"
    }

    // MARK: - 能力

    func probe() async {
        guard isEnabled, onChatPage else {
            diagnostics.capabilities.pageKind = onChatPage ? "chat（网页增强已关闭）" : pageKindDescription()
            diagnostics.capabilities.location = Redactor.describe(webView?.url)
            diagnostics.capabilities.checkedAt = Date()
            return
        }
        guard let json = await run(AdapterScripts.probe),
              let obj = decode(json) else {
            diagnostics.capabilities.pageKind = "chat（探测失败/超时）"
            return
        }
        var c = diagnostics.capabilities
        c.pageKind = "chat"
        c.location = Redactor.describe(webView?.url)
        c.inputFound = obj["inputFound"] as? Bool ?? false
        c.inputFocused = obj["inputFocused"] as? Bool ?? false
        c.messageCount = obj["messageCount"] as? Int ?? 0
        c.assistantCount = obj["assistantCount"] as? Int ?? 0
        c.streaming = obj["streaming"] as? Bool ?? false
        c.overlayOpen = obj["overlayOpen"] as? Bool ?? false
        c.loginButtonVisible = obj["loginButtonVisible"] as? Bool ?? false
        if let hits = obj["hits"] as? [String: String] {
            c.selectorHits = hits.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        c.checkedAt = Date()
        diagnostics.capabilities = c
    }

    private func pageKindDescription() -> String {
        switch NavigationPolicy.classify(webView?.url) {
        case .chat: "chat"
        case .auth: "auth（认证页面，适配器不介入）"
        case .external: "external"
        case .blocked: "none"
        }
    }

    /// 返回结果代码（用于 Gate C 统计），不抢占登录框或弹窗焦点。
    func focusInput() async -> String {
        guard isEnabled, settings.focusInputOnShow else { return "disabled" }
        guard onChatPage else { return "not-chat-page" }
        guard let json = await run(AdapterScripts.focusInput), let obj = decode(json) else { return "timeout" }
        return obj["reason"] as? String ?? "unknown"
    }

    /// 只有确定没有点击官方入口时才返回 false，允许调用方整页加载。
    /// 点击后的慢切换、脚本超时或页面变化都不能补一次加载，否则会清掉新会话的草稿。
    func openNewChatInPage() async -> Bool {
        guard !openingNewChat else { return true }
        guard isEnabled, onChatPage else { return false }
        guard webView?.url?.path != "/" else {
            diagnostics.log("nav", "新建对话：已在新对话页")
            return true
        }
        openingNewChat = true
        defer { openingNewChat = false }
        let gen = generation
        guard let json = await run(AdapterScripts.newChat), let obj = decode(json) else {
            diagnostics.log("nav", "新建对话：点击结果未知，保留当前页面")
            return true
        }
        guard gen == generation else { return true }
        diagnostics.log("nav", "新建对话 官方入口命中=\(obj["hits"] as? [Int] ?? [])")
        guard let clicked = obj["clicked"] as? Bool else { return true }
        guard clicked else { return false }
        for _ in 0..<10 {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return true }
            guard gen == generation else { return true }
            if webView?.url?.path == "/" {
                diagnostics.log("nav", "新建对话：页内切换")
                return true
            }
        }
        diagnostics.log("nav", "新建对话：已点击官方入口，保留页内切换，不追加整页加载")
        return true
    }

    func extractLatestAnswer() async -> ExtractionResult {
        guard isEnabled else { return .unavailable("网页增强已关闭") }
        guard onChatPage else { return .unavailable("当前不是聊天页面") }
        let gen = generation
        let started = Date()
        guard let json = await run(AdapterScripts.extract), let obj = decode(json) else {
            diagnostics.capabilities.lastExtraction = "超时/脚本失败"
            return .unavailable("无法读取页面（超时）")
        }
        guard gen == generation else { return .unavailable("页面已切换，请重试") }
        let status = obj["status"] as? String ?? "?"
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch status {
        case "ok":
            guard let path = obj["path"] as? String, let ids = obj["ids"] as? String,
                  let raw = obj["blocks"] as? [[String: Any]] else {
                diagnostics.capabilities.lastExtraction = "格式错误"
                return .unavailable("无法识别回答结构")
            }
            let blocks: [AnswerBlock] = raw.compactMap { b in
                guard let kind = (b["kind"] as? String).flatMap(AnswerBlock.Kind.init(rawValue:)),
                      let text = b["text"] as? String else { return nil }
                return AnswerBlock(kind: kind, text: text)
            }
            let notices = blocks.filter { $0.kind == .notice }.count
            // 只记录块数量与耗时，不记录正文
            diagnostics.capabilities.lastExtraction = "ok：文本块 \(blocks.count - notices)，提示 \(notices)，\(ms)ms"
            diagnostics.log("adapter", "回答提取 ok：文本块 \(blocks.count - notices)，提示 \(notices)，\(ms)ms")
            return .ok(AnswerRef(generation: gen, path: path, ids: ids), blocks)
        default:
            let reason = obj["reason"] as? String
            diagnostics.capabilities.lastExtraction = status + (reason.map { "(\($0))" } ?? "")
            diagnostics.log("adapter", "回答提取未完成：\(status)\(reason.map { "(\($0))" } ?? "")")
            return .unavailable(Self.describe(status: status, reason: reason))
        }
    }

    func verify(_ ref: AnswerRef) async -> VerifyResult {
        guard ref.generation == generation else { return .changed }
        guard isEnabled, onChatPage else { return .changed }
        guard let json = await run(AdapterScripts.verify), let obj = decode(json) else { return .unknown }
        guard ref.generation == generation else { return .changed }
        switch obj["status"] as? String {
        case "ok":
            return (obj["path"] as? String == ref.path && obj["ids"] as? String == ref.ids) ? .same : .changed
        case "streaming", "awaiting-answer", "no-messages":
            // 新的生成开始（例如重新生成）或对话被清空
            return .changed
        default:
            return .unknown
        }
    }

    static func describe(status: String, reason: String?) -> String {
        switch status {
        case "no-messages": "当前对话没有回答"
        case "awaiting-answer": "最新消息尚无回答"
        case "streaming": "回答仍在生成中"
        case "unrecognized": "无法可靠定位回答（\(reason ?? "unknown")），已禁用朗读"
        default: "无法朗读（\(status)）"
        }
    }

    // MARK: - 官方 Read Aloud 证据（只读，脱敏）

    /// 采集登录迹象、朗读入口与媒体状态。结果为脱敏 JSON 摘要（无正文）。
    func readAloudEvidence() async -> String {
        guard onChatPage else { return "{\"status\":\"not-chat-page\",\"page\":\"\(pageKindDescription())\"}" }
        let native = await webMediaState()
        guard let json = await run(AdapterScripts.readAloudProbe) else { return "{\"status\":\"timeout\",\"webkitMedia\":\"\(native)\"}" }
        return "{\"webkitMedia\":\"\(native)\",\"dom\":\(json)}"
    }

    /// 两次采样 currentTime，测量 DOM 媒体元素实际播放速率。
    func measureMedia() async -> String {
        guard onChatPage else { return "not-chat-page" }
        let native = await webMediaState()
        let json = await run(AdapterScripts.measureMedia, timeout: 4) ?? "timeout"
        return "webkitMedia=\(native) \(json)"
    }

    /// 【实验】为唯一正在播放的 DOM 媒体元素设置标准 playbackRate，随后测量实际速率。
    func experimentSetRate(_ rate: Double) async -> String {
        let allowed: Set<Double> = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        guard allowed.contains(rate), onChatPage else { return "rejected" }
        let set = await run(AdapterScripts.setMediaRate, arguments: ["rate": rate]) ?? "timeout"
        let measured = await measureMedia()
        return "set=\(set) measured=\(measured)"
    }

    /// WebKit 层面的媒体播放状态（覆盖未挂载到 DOM 的媒体；不涉及页面内部对象）
    func webMediaState() async -> String {
        guard let webView else { return "no-webview" }
        switch await webView.requestMediaPlaybackState() {
        case .none: return "none"
        case .playing: return "playing"
        case .paused: return "paused"
        case .suspended: return "suspended"
        @unknown default: return "unknown"
        }
    }

    // MARK: - 执行

    /// 在隔离世界执行脚本，结果统一为 JSON 字符串；超时返回 nil。
    private func run(_ body: String, arguments: [String: Any] = [:], timeout: TimeInterval? = nil) async -> String? {
        guard let webView else { return nil }
        let timeout = timeout ?? self.timeout
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            var finished = false
            let finish: @MainActor (String?) -> Void = { value in
                guard !finished else { return }
                finished = true
                cont.resume(returning: value)
            }
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .defaultClient) { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let value): finish(value as? String)
                    case .failure(let error):
                        let ns = error as NSError
                        self.diagnostics.log("adapter", "脚本错误 \(ns.domain)#\(ns.code)")
                        finish(nil)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated {
                    if !finished { self.diagnostics.log("adapter", "脚本超时") }
                    finish(nil)
                }
            }
        }
    }

    private func decode(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
