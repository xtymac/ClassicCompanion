import AppKit
import Network
import WebKit
import CompanionCore

/// WKWebView 运行时：持久化数据存储、导航策略、弹窗、文件选择、下载与受限消息桥。
/// 本类不读取任何 Cookie / Token / 网站数据内容。
@MainActor
final class WebRuntime: NSObject {
    static let homeURL = URL(string: "https://chatgpt.com/")!

    let webView: CompanionWebView
    private let diagnostics: Diagnostics
    private let settings: AppSettings
    private var observations: [NSKeyValueObservation] = []
    private var popupWindows: [NSWindow] = []

    /// 主框架 URL 变化（含 SPA pushState）
    var onURLChange: ((URL?) -> Void)?
    /// 主框架加载完成
    var onMainFrameLoaded: (() -> Void)?
    /// 主框架加载失败
    var onLoadFailed: (() -> Void)?
    /// 网页请求隐藏窗口（Esc）
    var onEscapeRequest: (() -> Void)?

    /// 加载失败、窗口里没有页面时的恢复（2026-11-11 开机白屏）。见 LoadRecovery。
    private var recovery: LoadRecovery
    private var retryTimer: DispatchWorkItem?
    private var pathMonitor: NWPathMonitor?
    /// 窗口里“无法连接”提示的状态。
    private(set) var loadProblem: LoadRecovery.Status = .hidden
    var onLoadProblemChange: ((LoadRecovery.Status) -> Void)?
    /// 实际发出主框架加载。正式运行是 webView.load；测试换成记录，免得真的联网。
    var loadRequest: @MainActor (URLRequest) -> Void = { _ in }
    /// 主框架是否还在加载（webView.isLoading）。测试可以替换。
    var mainFrameIsLoading: @MainActor () -> Bool = { false }
    /// 窗口里提交过页面。之前一直是空白（首次加载还没完成、失败或被取消），不靠 webView.url 判断。
    private var pageCommitted = false
    /// 最后一次由应用发出的主框架地址（只记允许重试的 https 地址）。窗口还空着时 ⌘R 重新加载它。
    private var lastRequestedURL: URL?

    /// 消息桥白名单
    private static let allowedMessageTypes: Set<String> = ["escape"]

    init(diagnostics: Diagnostics, settings: AppSettings,
         recovery: LoadRecovery = LoadRecovery(), watchesNetwork: Bool = true) {
        self.diagnostics = diagnostics
        self.settings = settings
        self.recovery = recovery

        let config = WKWebViewConfiguration()
        // 持久化网站数据存储（WebKit 管理，位于 ~/Library/WebKit/<bundle id>）
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let companionWebView = CompanionWebView(frame: .zero, configuration: config)
        companionWebView.blockAccessibility = !settings.allowPageAccessibility
        companionWebView.onAccessibilityRequest = { [diagnostics] request, allowed in
            diagnostics.log("ax", "首次收到无障碍请求 \(request) 放行=\(allowed)")
        }
        diagnostics.log("ax", "允许其他应用读取网页内容=\(settings.allowPageAccessibility) VoiceOver=\(NSWorkspace.shared.isVoiceOverEnabled)")
        webView = companionWebView
        super.init()
        loadRequest = { [weak self] request in _ = self?.webView.load(request) }
        mainFrameIsLoading = { [weak self] in self?.webView.isLoading ?? false }
        if watchesNetwork { startNetworkMonitor() }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.pageZoom = settings.pageZoom
        // Safari Web Inspector 只在开发版打开。发布版关闭：Safari 开发菜单不能连上已登录的 ChatGPT 页面
        // （发布回归 2026-11-08，用户选“收起两项”）。装好后看诊断日志里的“网页检查器”。
        #if DEBUG
        webView.isInspectable = true
        #else
        webView.isInspectable = false
        #endif
        diagnostics.log("web", "网页检查器：\(webView.isInspectable ? "开" : "关")")
        // 不设 underPageBackgroundColor：设了就固定住，WebKit 不再报出页面底色，顶部一条的浅深色就跟不上 ChatGPT（0044 实测）。
        // 它也不是切换时那块空白的来源（2309 排查：改成红色，空白不变）。

        diagnostics.dataStoreIsPersistent = config.websiteDataStore.isPersistent
        // 不设置 customUserAgent：不伪造浏览器身份
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
            MainActor.assumeIsolated {
                if let ua = value as? String { self?.diagnostics.userAgent = ua }
            }
        }

        // 消息桥只在隔离世界注册：网页自身脚本无法向其发送消息
        config.userContentController.add(WeakMessageHandler(self), contentWorld: .defaultClient, name: "cc")
        applyEnhancementScripts()

        observations.append(webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.onURLChange?(webView.url) }
        })
    }

    /// 根据设置注入或移除网页增强脚本（下次页面加载生效）
    func applyEnhancementScripts() {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        // Remove the installed listener too when enhancements are disabled.
        webView.evaluateJavaScript("window.__ccRemoveEscape?.(); window.__ccRemoveQuickHide?.()", in: nil, in: .defaultClient) { _ in }
        // 此脚本还负责输入法 Esc 和光标保护，不随“Esc 隐藏窗口”开关停用；是否隐藏由原生 escape 消息处理时判断。
        guard settings.webEnhancements else { return }
        let script = WKUserScript(source: AdapterScripts.escapeUserScript,
                                  injectionTime: .atDocumentEnd,
                                  forMainFrameOnly: true,
                                  in: .defaultClient)
        ucc.addUserScript(script)
        ucc.addUserScript(WKUserScript(source: AdapterScripts.quickHideUserScript, injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: true, in: .defaultClient))
        // 已加载的页面立即生效
        webView.evaluateJavaScript(AdapterScripts.escapeUserScript, in: nil, in: .defaultClient) { _ in }
        webView.evaluateJavaScript(AdapterScripts.quickHideUserScript, in: nil, in: .defaultClient) { _ in }
    }

    /// 0217 实测：真实页面中 Esc 脚本不存在（探针 esc=null）。atDocumentEnd 用户脚本可能错过替换脚本时已在进行的加载
    /// （启动和模式切换都会重装脚本）。每次主框架加载完成后再注入一次（脚本可重复注入），并记录是否就位；失败只记脚本自身的异常。
    private func ensureEscapeScript() {
        guard settings.webEnhancements else { return }
        // 小窗藏按钮的样式同理：每次加载完成后再注入一次（可重复注入）。
        webView.evaluateJavaScript(AdapterScripts.quickHideUserScript + "\n!!document.getElementById('cc-quick-hide')",
                                   in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                if case .success(let value) = result { self?.diagnostics.log("esc", "小窗藏按钮样式就位=\((value as? Bool) == true)") }
            }
        }
        webView.evaluateJavaScript(AdapterScripts.escapeUserScript + "\ntypeof window.__ccRemoveEscape", in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let value):
                    self?.diagnostics.log("esc", "Esc 脚本就位=\((value as? String) == "function")")
                case .failure(let error):
                    let e = error as NSError
                    let message = (e.userInfo["WKJavaScriptExceptionMessage"] as? String).map { String($0.prefix(120)) } ?? "-"
                    self?.diagnostics.log("esc", "Esc 脚本注入失败 \(e.domain)#\(e.code) \(message)")
                }
            }
        }
    }

    func setPageZoom(_ zoom: Double) {
        guard webView.pageZoom != zoom else { return }
        holdReadingPosition()
        webView.pageZoom = zoom
        restoreReadingPosition()
        diagnostics.log("zoom", "页面缩放 \(Int(zoom * 100))%")
    }

    /// 排版变化前记下正在读的内容，变化后放回原处。
    /// 切模式前留下当前画面。不等下一次屏幕更新：网页忙的时候也要马上拿到。
    func snapshotPage(_ done: @escaping @MainActor (NSImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        webView.takeSnapshot(with: config) { image, _ in
            MainActor.assumeIsolated { done(image) }
        }
    }

    /// 网页已经改成目标大小后调用，画好时回调。没有回调的情况由调用方的时限兜底。
    func prepareLayout(size: NSSize, done: @escaping @MainActor () -> Void) {
        let width = Self.cssWidth(points: size.width, zoom: webView.pageZoom)
        let started = Date()
        webView.callAsyncJavaScript(AdapterScripts.layoutReadyScript, arguments: ["width": width], in: nil, in: .defaultClient) { [diagnostics] result in
            // 共计减去三段，是脚本开始之前的等待（网页忙或消息排队）。
            if case .success(let value) = result, let steps = value as? [String: Any] {
                let ms = { (key: String) in (steps[key] as? NSNumber)?.intValue ?? -1 }
                diagnostics.log("window", "网页排版分段：共 \(Int(Date().timeIntervalSince(started) * 1000))ms 到宽度 \(ms("match"))ms "
                                + "排版 \(ms("layout"))ms 放回 \(ms("restore"))ms 可滚动高度 \(ms("height"))")
            }
            done()
        }
    }

    nonisolated static func cssWidth(points: CGFloat, zoom: Double) -> Int {
        Int((points / zoom).rounded())
    }

    func holdReadingPosition() {
        webView.evaluateJavaScript("window.__ccReadingHold?.save(); 0", in: nil, in: .defaultClient) { _ in }
    }

    func restoreReadingPosition() {
        webView.evaluateJavaScript("window.__ccReadingHold?.restore(); 0", in: nil, in: .defaultClient) { _ in }
    }

    func setPageAccessibilityAllowed(_ allowed: Bool) {
        webView.blockAccessibility = !allowed
        diagnostics.log("ax", "允许其他应用读取网页内容=\(allowed)")
    }

    func load(_ url: URL) {
        diagnostics.log("nav", "加载 \(Redactor.describe(url))")
        if LoadRecovery.isRetryable(url) { lastRequestedURL = url }
        loadRequest(URLRequest(url: url))
    }

    func newChat() {
        load(Self.homeURL)
    }

    /// ⌘R、窗口里的“重新加载”、网页内容进程终止后都走这里。
    /// 窗口里没有页面时 reload() 不会重新请求（2026-11-11 实测），所以显式 load：有失败地址就加载它；
    /// 首次加载还没完成或被取消时，重新加载最后请求的地址。
    func reload() {
        if let url = recovery.manualReload() {
            retryTimer?.cancel()
            retryTimer = nil
            diagnostics.log("nav", "重新加载失败的地址")
            load(url)
            publishLoadProblem()
            return
        }
        if !pageCommitted, let url = lastRequestedURL {
            diagnostics.log("nav", "还没有页面，重新加载请求的地址")
            load(url)
            return
        }
        webView.stopLoading()
        webView.reload()
    }

    /// 窗口从隐藏唤醒、或已可见的窗口被叫到前面时：页面还没加载成功、还在等自动重试，就提前试一次（算一次自动重试）。
    /// 切换小窗／完整窗口不算：用户没有离开，来回切几次也不该把次数用完。
    func windowShown(_ kind: Diagnostics.ShowKind = .wake) {
        guard kind != .modeSwitch else { return }
        handle(recovery.windowShown(), trigger: "窗口显示")
    }

    /// 只有从断网变成在线才触发重试；断网期间不发请求。
    func networkChanged(online: Bool) {
        if online != recovery.online { diagnostics.log("net", online ? "网络可用" : "网络不可用") }
        handle(recovery.networkChanged(online: online), trigger: "网络恢复")
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            MainActor.assumeIsolated { self?.networkChanged(online: online) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private func retryTimerFired() {
        retryTimer = nil
        handle(recovery.retryTimerFired(), trigger: "定时")
    }

    /// 同一时间最多一个定时器：排新的或马上重试时，先取消旧的。
    private func handle(_ action: LoadRecovery.Action, trigger: String) {
        switch action {
        case .none:
            break
        case .retry(let url):
            retryTimer?.cancel()
            retryTimer = nil
            diagnostics.log("nav", "自动重试（\(trigger)）第 \(recovery.autoRetries) 次")
            load(url)
        case .schedule(let delay):
            retryTimer?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.retryTimerFired() }
            }
            retryTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            diagnostics.log("nav", "\(String(format: "%g", delay)) 秒后自动重试")
        }
        publishLoadProblem()
    }

    /// 窗口里有页面了（主框架已提交或加载完成）：收起提示，取消排着的重试。
    private func pageArrived() {
        pageCommitted = true
        retryTimer?.cancel()
        retryTimer = nil
        recovery.loadSucceeded()
        publishLoadProblem()
    }

    private func publishLoadProblem() {
        let status = recovery.status
        guard status != loadProblem else { return }
        loadProblem = status
        diagnostics.log("nav", "无法连接提示：\(status)")
        onLoadProblemChange?(status)
    }

    private func openExternally(_ url: URL) {
        diagnostics.log("nav", "外部链接交给默认浏览器：\(Redactor.describe(url))")
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 导航策略

extension WebRuntime: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        // 子框架（例如 Cloudflare 验证 iframe）由网页自行管理
        guard let frame = navigationAction.targetFrame, frame.isMainFrame else { return (.allow, preferences) }

        let url = navigationAction.request.url
        let kind = NavigationPolicy.classify(url)
        let userOpensElsewhere = navigationAction.navigationType == .linkActivated &&
            navigationAction.modifierFlags.contains(.command)

        switch kind {
        case .chat, .auth:
            if userOpensElsewhere, let url {
                openExternally(url)
                return (.cancel, preferences)
            }
            if webView === self.webView, kind == .auth {
                diagnostics.log("nav", "认证跳转：\(Redactor.describe(url))")
            }
            return (.allow, preferences)
        case .external:
            if let url { openExternally(url) }
            return (.cancel, preferences)
        case .blocked:
            diagnostics.log("nav", "已阻止导航：\(Redactor.describe(url))")
            return (.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        recovery.navigationStarted()
        publishLoadProblem()
    }

    /// 页面一提交就收起“无法连接”提示，不等整页加载完。
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        pageArrived()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        diagnostics.log("nav", "加载完成 \(Redactor.describe(webView.url))")
        guard webView === self.webView else { return }
        pageArrived()
        ensureEscapeScript()
        onMainFrameLoaded?()
        // 无正文的渲染自检：只取数量
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let size = self.webView.frame.size
                let js = "JSON.stringify({rs: document.readyState, els: document.getElementsByTagName('*').length, vis: document.visibilityState})"
                self.webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { result in
                    MainActor.assumeIsolated {
                        let summary = (try? result.get()) as? String ?? "error"
                        self.diagnostics.log("render", "自检 frame=\(Int(size.width))x\(Int(size.height)) \(summary)")
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logNavError(error, webView: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        logNavError(error, webView: webView)
    }

    private func logNavError(_ error: Error, webView: WKWebView) {
        let ns = error as NSError
        // NSURLErrorCancelled（-999）与 WebKit 框架中断（102）是正常的导航取消，不算加载故障。
        if ns.code == NSURLErrorCancelled || (ns.domain == "WebKitErrorDomain" && ns.code == 102) {
            // 被新的加载顶掉时 isLoading 仍为 true，交给新的加载；什么都没在加载时，空白窗口回到等待，不一直显示“正在重新连接”。
            if webView === self.webView, !mainFrameIsLoading() {
                handle(recovery.navigationCancelled(), trigger: "导航取消")
            }
            return
        }
        diagnostics.log("nav", "加载失败 \(ns.domain)#\(ns.code) @ \(Redactor.describe(webView.url))")
        guard webView === self.webView else { return }
        // 还没提交过页面就是空白窗口（首次加载失败时 webView.url 也是 nil）；提交过的页面失败后仍留在窗口里。
        let hasPage = pageCommitted
        let failingURL = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        handle(recovery.loadFailed(url: failingURL, domain: ns.domain, code: ns.code, hasPage: hasPage),
                trigger: "加载失败")
        onLoadFailed?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        diagnostics.log("web", "网页内容进程终止，重新加载")
        if webView === self.webView { reload() } else { webView.reload() }
    }
}

// MARK: - 下载（保存到 ~/Downloads，仅在用户点击网页下载时发生）

extension WebRuntime: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = dir.appendingPathComponent(suggestedFilename)
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) \(i)" + (ext.isEmpty ? "" : ".\(ext)"))
            i += 1
        }
        diagnostics.log("download", "开始下载（文件名已省略）")
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        diagnostics.log("download", "下载完成")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let ns = error as NSError
        diagnostics.log("download", "下载失败 \(ns.domain)#\(ns.code)")
    }
}

// MARK: - UI 代理：新窗口、文件选择、JS 对话框、媒体权限

extension WebRuntime: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        let kind = NavigationPolicy.classify(url)
        if kind == .external, let url {
            openExternally(url)
            return nil
        }
        if kind == .blocked { return nil }
        // 认证等弹窗：使用 WebKit 提供的 configuration 以保留 window.opener 关系
        diagnostics.log("nav", "打开弹窗：\(Redactor.describe(url))")
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = L10n.string("window.popup")
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popupWindows.append(window)
        return popup
    }

    /// 切换界面语言后，已经开着的弹窗也换标题。
    func retitlePopups() {
        popupWindows.forEach { $0.title = L10n.string("window.popup") }
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let idx = popupWindows.firstIndex(where: { $0.contentView === webView }) {
            popupWindows[idx].close()
            popupWindows.remove(at: idx)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        // 仅响应网页上的用户操作；不会自动上传任何文件
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let response = await panel.begin()
        return response == .OK ? panel.urls : nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        // 按钮写明，否则用系统语言，和手动选的界面语言不一致。网页给的文字原样显示。
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        // Phase 0 不开启麦克风/摄像头（实时 Voice Chat 属于 P1）
        diagnostics.log("media", "已拒绝媒体采集请求（Phase 0 不启用）")
        return .deny
    }
}

// MARK: - 消息桥（限制来源、frame、类型、参数）

extension WebRuntime: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView,
              message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == "chatgpt.com",
              let body = message.body as? [String: Any],
              body.count == 1,
              let type = body["type"] as? String,
              Self.allowedMessageTypes.contains(type) else {
            diagnostics.log("bridge", "已拒绝不符合约束的消息")
            return
        }
        switch type {
        case "escape":
            guard settings.webEnhancements, settings.escapeHidesWindow else { return }
            onEscapeRequest?()
        default:
            break
        }
    }
}

/// 避免 WKUserContentController 强引用造成循环
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}
