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
    /// 这个适配器写的日志都经过它，和它的网页运行时一样带上标签页的标签（见 TabLog）。
    let log: TabLog
    private let settings: AppSettings
    /// 每次主框架 URL 变化递增，使旧引用与进行中的调用失效
    private(set) var generation = 0
    private let timeout: TimeInterval = 2.5
    private var openingNewChat = false
    /// 已经关闭（close()）。不会改回。
    private(set) var isClosed = false

    /// tab：这个适配器属于哪个标签页，日志带上它的标签。正式运行由 ChatTab.make 传；不传（nil）就不带。
    init(webView: WKWebView, diagnostics: Diagnostics, settings: AppSettings, tab: TabID? = nil) {
        self.webView = webView
        self.diagnostics = diagnostics
        log = TabLog(diagnostics: diagnostics, tab: tab)
        self.settings = settings
    }

    func invalidate() {
        generation += 1
    }

    /// 关闭（关闭标签页时由 ChatTabs.close(_:) 调用，和它的网页运行时一起）。之后：
    /// - 不再在网页里跑脚本（run 直接按没有结果返回），不再向 WebKit 发媒体请求（webMediaState 返回 "closed"，暂停、挂起不做）：
    ///   进行中的多步操作（读朗读证据、测量、实验、页面里的新对话）剩下的步骤不再碰这个网页，马上返回；
    /// - 正在等 WebKit 回答的媒体请求马上按 "closed" 结束（不等回答、不等时限），等它们的调用方马上往下走、不再拿着标签页；
    /// - 进行中的脚本返回、出错或超时都不写日志，探测结果不写进诊断（probe）；
    /// - 页面里的新对话点完入口后不再等页面变化（openNewChatInPage）。
    /// 已经在网页里跑着的脚本不取消（没有取消的办法），它返回或超时以后什么都不做。关两遍没关系。
    func close() {
        isClosed = true
        for waiter in mediaWaiters { finish(waiter, "closed") }
    }

    var isEnabled: Bool { settings.webEnhancements }

    private var onChatPage: Bool {
        guard let url = webView?.url else { return false }
        return NavigationPolicy.classify(url) == .chat && url.host == "chatgpt.com"
    }

    // MARK: - 能力

    /// 关闭以后什么都不做；等脚本时关闭了，结果不写进诊断。
    /// 每次写进诊断的都是这个标签页的一份完整的快照（freshCapabilities）：带上它的标识（报告里那一段带它的标签），
    /// 不是聊天页面、探测失败时也不留上一次探测（可能是别的标签页的）的计数，免得把别的标签页的数和这个标签页的标签写在一起。
    func probe() async {
        guard !isClosed else { return }
        guard isEnabled, onChatPage else {
            diagnostics.capabilities = freshCapabilities(onChatPage ? "chat（网页增强已关闭）" : pageKindDescription())
            return
        }
        let result = await run(AdapterScripts.probe)
        guard !isClosed else { return }
        guard let json = result,
              let obj = decode(json) else {
            diagnostics.capabilities = freshCapabilities("chat（探测失败/超时）")
            return
        }
        var c = freshCapabilities("chat")
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
        diagnostics.capabilities = c
    }

    /// 这一刻这个标签页的一份新的能力快照：页面类型 kind、位置（Redactor）、检查时间、它的标识；别的都是初始值。
    /// 最近一次回答提取另外记（recordExtraction，带它自己的标签页），照原样留着。
    private func freshCapabilities(_ kind: String) -> Diagnostics.PageCapabilities {
        var c = Diagnostics.PageCapabilities()
        c.pageKind = kind
        c.location = Redactor.describe(webView?.url)
        c.checkedAt = Date()
        c.tab = log.tab
        c.lastExtraction = diagnostics.capabilities.lastExtraction
        c.extractionTab = diagnostics.capabilities.extractionTab
        return c
    }

    /// 记下最近一次回答提取的结果（只有块数、耗时、状态，没有正文），连同这个标签页的标识。关闭以后不记。
    private func recordExtraction(_ result: String) {
        guard !isClosed else { return }
        diagnostics.capabilities.lastExtraction = result
        diagnostics.capabilities.extractionTab = log.tab
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
    /// 关闭以后返回 true（不点、不让调用方加载，什么都不写）；等脚本或等页面变化时关闭了，也马上返回 true，不再写日志。
    func openNewChatInPage() async -> Bool {
        guard !isClosed else { return true }
        guard !openingNewChat else { return true }
        guard isEnabled, onChatPage else { return false }
        guard webView?.url?.path != "/" else {
            log("nav", "新建对话：已在新对话页")
            return true
        }
        openingNewChat = true
        defer { openingNewChat = false }
        let gen = generation
        let result = await run(AdapterScripts.newChat)
        guard !isClosed else { return true }
        guard let json = result, let obj = decode(json) else {
            log("nav", "新建对话：点击结果未知，保留当前页面")
            return true
        }
        guard gen == generation else { return true }
        log("nav", "新建对话 官方入口命中=\(obj["hits"] as? [Int] ?? [])")
        guard let clicked = obj["clicked"] as? Bool else { return true }
        guard clicked else { return false }
        for _ in 0..<10 {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return true }
            guard !isClosed, gen == generation else { return true }
            if webView?.url?.path == "/" {
                log("nav", "新建对话：页内切换")
                return true
            }
        }
        log("nav", "新建对话：已点击官方入口，保留页内切换，不追加整页加载")
        return true
    }

    func extractLatestAnswer() async -> ExtractionResult {
        guard isEnabled else { return .unavailable("网页增强已关闭") }
        guard onChatPage else { return .unavailable("当前不是聊天页面") }
        let gen = generation
        let started = Date()
        guard let json = await run(AdapterScripts.extract), let obj = decode(json) else {
            recordExtraction("超时/脚本失败")
            return .unavailable("无法读取页面（超时）")
        }
        guard gen == generation else { return .unavailable("页面已切换，请重试") }
        let status = obj["status"] as? String ?? "?"
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch status {
        case "ok":
            guard let path = obj["path"] as? String, let ids = obj["ids"] as? String,
                  let raw = obj["blocks"] as? [[String: Any]] else {
                recordExtraction("格式错误")
                return .unavailable("无法识别回答结构")
            }
            let blocks: [AnswerBlock] = raw.compactMap { b in
                guard let kind = (b["kind"] as? String).flatMap(AnswerBlock.Kind.init(rawValue:)),
                      let text = b["text"] as? String else { return nil }
                return AnswerBlock(kind: kind, text: text)
            }
            let notices = blocks.filter { $0.kind == .notice }.count
            // 只记录块数量与耗时，不记录正文
            recordExtraction("ok：文本块 \(blocks.count - notices)，提示 \(notices)，\(ms)ms")
            log("adapter", "回答提取 ok：文本块 \(blocks.count - notices)，提示 \(notices)，\(ms)ms")
            return .ok(AnswerRef(generation: gen, path: path, ids: ids), blocks)
        default:
            let reason = obj["reason"] as? String
            recordExtraction(status + (reason.map { "(\($0))" } ?? ""))
            log("adapter", "回答提取未完成：\(status)\(reason.map { "(\($0))" } ?? "")")
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

    /// WebKit 层面的媒体播放状态（覆盖未挂载到 DOM 的媒体；不涉及页面内部对象）。关闭以后不读，返回 "closed"。
    /// 有时限（见 mediaRequest(_:)）：mediaTimeout 秒内 WebKit 没回答返回 "timeout"，等的时候关闭了马上返回 "closed"。
    /// 已经交给 WebKit、还没回答的读状态请求只有一个：那时再读不再交一次，等那一次的回答（各自的时限照算）。
    /// 所以 WebKit 一直不回答时，每秒读一次也只有一个请求在 WebKit 那里等着。
    func webMediaState() async -> String {
        await mediaRequest(.state)
    }

    /// 全部暂停（媒体实验）。有时限，关闭以后不做，同 webMediaState()。返回 "ok"、"timeout" 或 "closed"。
    @discardableResult
    func pauseAllMediaPlayback() async -> String {
        await mediaRequest(.pauseAll)
    }

    /// 全部挂起或恢复（媒体实验）。有时限，关闭以后不做，同 webMediaState()。返回 "ok"、"timeout" 或 "closed"。
    @discardableResult
    func setAllMediaPlaybackSuspended(_ suspended: Bool) async -> String {
        await mediaRequest(.suspendAll(suspended))
    }

    // MARK: - WebKit 的媒体请求（有时限）

    /// 交给 WebKit 的媒体请求：读媒体状态、全部暂停、全部挂起或恢复。
    enum MediaRequest: Equatable {
        case state, pauseAll, suspendAll(Bool)

        var name: String {
            switch self {
            case .state: "读媒体状态"
            case .pauseAll: "全部暂停"
            case .suspendAll(let suspended): suspended ? "全部挂起" : "全部恢复"
            }
        }
    }

    /// 把一个媒体请求交给 WebKit，WebKit 回答时调用 done（读状态时带上状态，别的是 nil）。正式运行就是 WKWebView
    /// 带回调的那三个方法；只有测试换它（换成不回答、或由测试决定什么时候回答的替身）。WebKit 可能一直不回答
    /// （网页进程卡住），所以等的地方都有时限（mediaTimeout）。
    var sendMediaRequest: @MainActor (WKWebView, MediaRequest, @escaping @MainActor (WKMediaPlaybackState?) -> Void) -> Void = {
        web, request, done in
        switch request {
        case .state: web.requestMediaPlaybackState(completionHandler: { done($0) })
        case .pauseAll: web.pauseAllMediaPlayback(completionHandler: { done(nil) })
        case .suspendAll(let suspended): web.setAllMediaPlaybackSuspended(suspended, completionHandler: { done(nil) })
        }
    }
    /// 等 WebKit 回答媒体请求最多多久（秒），到了按 "timeout" 结束、不再等。只有测试换它。
    var mediaTimeout: TimeInterval = 2.5
    /// 正在等回答的调用（每次调用一个），回答、到时限、关闭哪个先到就用哪个结束（finish），结束时拿掉。
    private var mediaWaiters: [MediaWaiter] = []
    /// 有一个读状态的请求已经交给 WebKit、还没回答。
    private var stateRequestPending = false

    /// 交一个媒体请求、等它结束：WebKit 的回答（读状态是状态的名字，别的是 "ok"）、"timeout"（mediaTimeout 秒内没回答）
    /// 或 "closed"（关闭以后，或等的时候关闭了）。每次调用正好结束一次。
    /// 谁拿着什么：等的人（MediaWaiter）只在 mediaWaiters 里；交给 WebKit 的回调和到时限的那一次只弱引用适配器和等的人，
    /// 网页视图只在交出去的那一刻用一下。所以 WebKit 一直不回答，回调也不拿着适配器、网页视图和标签页；
    /// 调用方最多等到时限，关闭时马上不等了。回答迟到（已经到时限、已经关闭）什么都不做。
    private func mediaRequest(_ request: MediaRequest) async -> String {
        guard !isClosed else { return "closed" }
        guard webView != nil else { return "no-webview" }
        return await withCheckedContinuation { continuation in
            let waiter = MediaWaiter(request, continuation)
            mediaWaiters.append(waiter)
            let timeout = mediaTimeout
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, weak waiter] in
                MainActor.assumeIsolated {
                    guard let self, let waiter, self.finish(waiter, "timeout") else { return }
                    if request != .state { self.log("adapter", "WebKit \(request.name)没有在 \(timeout) 秒内回答，不再等") }
                }
            }
            send(request, for: waiter)
        }
    }

    /// 把请求交给 WebKit（同步：网页视图只在这里用一下）。读状态时已经有一个在等：不再交，waiter 等那一个的回答。
    private func send(_ request: MediaRequest, for waiter: MediaWaiter) {
        guard let webView else {
            finish(waiter, "no-webview")
            return
        }
        if request == .state {
            guard !stateRequestPending else { return }
            stateRequestPending = true
        }
        sendMediaRequest(webView, request) { [weak self, weak waiter] state in
            guard let self, !self.isClosed else { return }
            guard request == .state else {
                if let waiter { self.finish(waiter, "ok") }
                return
            }
            self.stateRequestPending = false
            let value = Self.describe(state)
            for waiting in self.mediaWaiters where waiting.request == .state { self.finish(waiting, value) }
        }
    }

    /// 结束一个还在等的调用（返回 value）。已经结束过的不再结束，返回 false。
    @discardableResult
    private func finish(_ waiter: MediaWaiter, _ value: String) -> Bool {
        guard let index = mediaWaiters.firstIndex(where: { $0 === waiter }) else { return false }
        mediaWaiters.remove(at: index)
        waiter.continuation.resume(returning: value)
        return true
    }

    private static func describe(_ state: WKMediaPlaybackState?) -> String {
        guard let state else { return "unknown" }
        switch state {
        case .none: return "none"
        case .playing: return "playing"
        case .paused: return "paused"
        case .suspended: return "suspended"
        @unknown default: return "unknown"
        }
    }

    /// 测试看：正在等回答的媒体请求有几个。
    var pendingMediaRequests: Int { mediaWaiters.count }

    // MARK: - 执行

    /// 在隔离世界执行脚本，结果统一为 JSON 字符串；超时返回 nil。关闭以后不执行，直接返回 nil。
    /// 脚本出错、超时写一行日志；那时已经关闭就不写（网页视图释放以后，WebKit 等网页不忙了才让还没返回的脚本出错，
    /// 实测 WKErrorDomain#5，那时适配器早已关闭）。
    /// 到时限的那一次和脚本的回调都只弱引用适配器：脚本早就返回了，适配器不用等到时限才能释放；到了时限脚本还没回来
    /// （网页一直忙），适配器也不用等它回来。
    private func run(_ body: String, arguments: [String: Any] = [:], timeout: TimeInterval? = nil) async -> String? {
        guard !isClosed, let webView else { return nil }
        let timeout = timeout ?? self.timeout
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            var finished = false
            let finish: @MainActor (String?) -> Void = { value in
                guard !finished else { return }
                finished = true
                cont.resume(returning: value)
            }
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .defaultClient) { [weak self] result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let value): finish(value as? String)
                    case .failure(let error):
                        let ns = error as NSError
                        if let self, !self.isClosed { self.log("adapter", "脚本错误 \(ns.domain)#\(ns.code)") }
                        finish(nil)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    if !finished, let self, !self.isClosed { self.log("adapter", "脚本超时") }
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

/// 一次媒体请求的调用方在等的（ChatGPTAdapter.mediaRequest(_:)）：由适配器的 finish 结束，正好一次。
@MainActor
private final class MediaWaiter {
    let request: ChatGPTAdapter.MediaRequest
    let continuation: CheckedContinuation<String, Never>

    init(_ request: ChatGPTAdapter.MediaRequest, _ continuation: CheckedContinuation<String, Never>) {
        self.request = request
        self.continuation = continuation
    }
}
