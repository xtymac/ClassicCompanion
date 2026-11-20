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
    /// 这个运行时写的日志都经过它：建的时候给了标签页的标识，每行末尾就带上那个标签页的标签（见 TabLog）。
    /// 弹窗的导航也由这个运行时处理，写的行带的是打开弹窗的那个标签页的标签。
    let log: TabLog
    private let settings: AppSettings
    private var observations: [NSKeyValueObservation] = []
    private var popupWindows: [NSWindow] = []

    /// 主框架 URL 变化（含 SPA pushState）
    var onURLChange: ((URL?) -> Void)?
    /// 主框架加载完成
    var onMainFrameLoaded: (() -> Void)?
    /// 主框架提交时调用，在“提示可以收起”（onLoadProblemChange(.hidden)）之前。
    var onMainFrameCommitted: (() -> Void)?
    /// 主框架加载失败
    var onLoadFailed: (() -> Void)?
    /// 网页请求隐藏窗口（Esc）
    var onEscapeRequest: (() -> Void)?
    /// 地址、能否后退或前进变了（顶部返回箭头跟着变）。
    var onHistoryChange: (() -> Void)?

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
    /// 已经关闭（close()）。之后不再发起任何加载、不再排重试，网页的导航事件和弹窗请求都不理，回调已经断开。不会改回。
    private(set) var isClosed = false
    /// 记下过几次阅读位置，就是最近一次的编号（见 holdReadingPosition()）。测试读它看运行时自己记下过没有。
    private(set) var readingHolds = 0
    /// 排着一次定时自动重试（测试和诊断用）。
    var hasScheduledRetry: Bool { retryTimer != nil }

    /// 消息桥白名单
    private static let allowedMessageTypes: Set<String> = ["escape"]

    /// tab：这个运行时属于哪个标签页，日志带上它的标签。正式运行由 ChatTab.make 传；不传（nil）就不带，
    /// 测试里单独建的运行时就是这样。
    init(diagnostics: Diagnostics, settings: AppSettings,
         recovery: LoadRecovery = LoadRecovery(), watchesNetwork: Bool = true, tab: TabID? = nil) {
        self.diagnostics = diagnostics
        let log = TabLog(diagnostics: diagnostics, tab: tab)
        self.log = log
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
        companionWebView.onAccessibilityRequest = { [log] request, allowed in
            log("ax", "首次收到无障碍请求 \(request) 放行=\(allowed)")
        }
        log("ax", "允许其他应用读取网页内容=\(settings.allowPageAccessibility) VoiceOver=\(NSWorkspace.shared.isVoiceOverEnabled)")
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
        log("web", "网页检查器：\(webView.isInspectable ? "开" : "关")")
        // 不设 underPageBackgroundColor：设了就固定住，WebKit 不再报出页面底色，顶部一条的浅深色就跟不上 ChatGPT（0044 实测）。
        // 它也不是切换时那块空白的来源（2309 排查：改成红色，空白不变）。

        diagnostics.dataStoreIsPersistent = config.websiteDataStore.isPersistent
        // 不设置 customUserAgent：不伪造浏览器身份。读回来时已经关闭（新标签页建好马上关了）就不写诊断。
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
            MainActor.assumeIsolated {
                if let self, !self.isClosed, let ua = value as? String { self.diagnostics.userAgent = ua }
            }
        }

        // 消息桥只在隔离世界注册：网页自身脚本无法向其发送消息
        config.userContentController.add(WeakMessageHandler(self), contentWorld: .defaultClient, name: "cc")
        applyEnhancementScripts()

        observations.append(webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                self?.onURLChange?(webView.url)
                self?.onHistoryChange?()
            }
        })
        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onHistoryChange?() }
        })
        observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onHistoryChange?() }
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
    /// 结果回来时已经关闭就不记（关闭以后这个运行时什么都不写）。
    private func ensureEscapeScript() {
        guard settings.webEnhancements else { return }
        // 小窗藏按钮的样式同理：每次加载完成后再注入一次（可重复注入）。
        webView.evaluateJavaScript(AdapterScripts.quickHideUserScript + "\n!!document.getElementById('cc-quick-hide')",
                                   in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if case .success(let value) = result { self.log("esc", "小窗藏按钮样式就位=\((value as? Bool) == true)") }
            }
        }
        webView.evaluateJavaScript(AdapterScripts.escapeUserScript + "\ntypeof window.__ccRemoveEscape", in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                switch result {
                case .success(let value):
                    self.log("esc", "Esc 脚本就位=\((value as? String) == "function")")
                case .failure(let error):
                    let e = error as NSError
                    let message = (e.userInfo["WKJavaScriptExceptionMessage"] as? String).map { String($0.prefix(120)) } ?? "-"
                    self.log("esc", "Esc 脚本注入失败 \(e.domain)#\(e.code) \(message)")
                }
            }
        }
    }

    /// 改页面缩放（已经是这个缩放时什么都不做）。keepingReadingPosition：改之前记下阅读位置、改完马上放回（原来的做法）；
    /// 为 false 时只改缩放，不碰网页里记下的阅读位置——这一页留着一次等它再显示并排好版时放回的（见 ChatTabs.setPageZoom(_:)）。
    func setPageZoom(_ zoom: Double, keepingReadingPosition: Bool = true) {
        guard webView.pageZoom != zoom else { return }
        let hold = keepingReadingPosition ? holdReadingPosition() : nil
        webView.pageZoom = zoom
        if let hold { restoreReadingPosition(hold) }
        log("zoom", "页面缩放 \(Int(zoom * 100))%")
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
    /// 画好时已经关闭（或运行时已经释放）：不写分段那一行，照样回调（窗口按那一次的身份核对，不会再做事）。
    func prepareLayout(size: NSSize, done: @escaping @MainActor () -> Void) {
        let width = Self.cssWidth(points: size.width, zoom: webView.pageZoom)
        let started = Date()
        webView.callAsyncJavaScript(AdapterScripts.layoutReadyScript, arguments: ["width": width], in: nil, in: .defaultClient) { [weak self, log] result in
            // 共计减去三段，是脚本开始之前的等待（网页忙或消息排队）。
            if self?.isClosed == false, case .success(let value) = result, let steps = value as? [String: Any] {
                let ms = { (key: String) in (steps[key] as? NSNumber)?.intValue ?? -1 }
                log("window", "网页排版分段：共 \(Int(Date().timeIntervalSince(started) * 1000))ms 到宽度 \(ms("match"))ms "
                                + "排版 \(ms("layout"))ms 放回 \(ms("restore"))ms 可滚动高度 \(ms("height"))")
            }
            done()
        }
    }

    nonisolated static func cssWidth(points: CGFloat, zoom: Double) -> Int {
        Int((points / zoom).rounded())
    }

    /// 网页里记下正在读的内容（AdapterScripts 里的 __ccReadingHold），返回这一次的编号：之后按编号放回
    /// （restoreReadingPosition(_:confirmingContinuation:)）或丢弃（discardReadingPosition(_:)），只动这一次记下的。
    /// 编号在这个运行时里从 1 起往上数，不重复。关闭以后不碰网页（编号照发，网页里什么都没记下）。
    @discardableResult
    func holdReadingPosition() -> Int {
        readingHolds += 1
        let token = readingHolds
        guard !isClosed else { return token }
        webView.evaluateJavaScript("window.__ccReadingHold?.save(\(token)); 0", in: nil, in: .defaultClient) { _ in }
        return token
    }

    /// 放回编号 token 那一次记下的阅读位置。
    /// confirmingContinuation：新对话页拿到对话地址时（ReadingContinuity 的 confirmOnPage），先让网页确认记下时看着的
    /// 那段对话还在原处，确认不了网页就丢掉这一次、不放回。确认的结果写一行日志（只有结果，没有内容）。
    /// 关闭以后什么都不做（不碰网页、不写日志）。
    func restoreReadingPosition(_ token: Int, confirmingContinuation: Bool = false) {
        guard !isClosed else { return }
        guard confirmingContinuation else {
            webView.evaluateJavaScript("window.__ccReadingHold?.restore(\(token)); 0", in: nil, in: .defaultClient) { _ in }
            return
        }
        webView.evaluateJavaScript("window.__ccReadingHold?.restore(\(token), true) ?? 'none'",
                                   in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                self.log("reading", Self.confirmationLine((try? result.get()) as? String))
            }
        }
    }

    /// 丢掉编号 token 那一次记下的阅读位置（它已不属于这一页现在显示的内容）：网页里不再留着，之后再记下也不会沿用它。
    /// 同一份记录被更新的编号沿用着时，只去掉这一个编号，不动更新的。关闭以后什么都不做。
    func discardReadingPosition(_ token: Int) {
        guard !isClosed else { return }
        webView.evaluateJavaScript("window.__ccReadingHold?.discard(\(token)); 0", in: nil, in: .defaultClient) { _ in }
    }

    /// 网页确认的结果（__ccReadingHold.restore(编号, true) 的返回值）写成的日志。
    nonisolated static func confirmationLine(_ result: String?) -> String {
        switch result {
        case "restored": "阅读位置：网页确认记下时看着的那段对话还在，放回"
        case "unconfirmed": "阅读位置：网页确认不了还是同一段对话，丢弃"
        default: "阅读位置：网页里已经没有这次记下的位置"
        }
    }

    func setPageAccessibilityAllowed(_ allowed: Bool) {
        webView.blockAccessibility = !allowed
        log("ax", "允许其他应用读取网页内容=\(allowed)")
    }

    /// 应用发出主框架加载都经过这里（自动重试、网络恢复、窗口显示后、⌘R 有失败地址时、新对话）。关闭以后什么都不发。
    func load(_ url: URL) {
        guard !isClosed else { return }
        log("nav", "加载 \(Redactor.describe(url))")
        if LoadRecovery.isRetryable(url) { lastRequestedURL = url }
        loadRequest(URLRequest(url: url))
    }

    func newChat() {
        load(Self.homeURL)
    }

    /// WebKit 媒体（GPU）进程的名字；结束进程前用它核对 pid 确实是媒体进程。
    static let mediaProcessName = "com.apple.WebKit.GPU"

    /// 结束这个应用自己的 WebKit 媒体进程，WebKit 会马上另起一个；页面不重新加载，正在播放的声音会停。
    /// 用途：应用运行期间音频输出设备变过以后，媒体进程可能一直往旧设备送声音（issue #16），重启整个应用能恢复。
    /// 2026-11-23 在独立的测试程序里试过：结束后 2 秒内新进程起来，之后播放正常，网页内容进程不受影响。
    /// 这一步能不能清掉“停在旧设备上”的状态还没有在故障现场验证过。
    /// 媒体进程的 pid 来自 WKWebView 的非公开属性；取不到、或 pid 对不上媒体进程的名字时什么都不做，返回 false。
    @discardableResult
    func restartMediaProcess() -> Bool {
        guard let pid = Self.mediaProcessID(of: webView) else {
            diagnostics.log("media", "重启音频：找不到媒体进程，没有操作")
            return false
        }
        guard kill(pid, SIGKILL) == 0 else {
            diagnostics.log("media", "重启音频：结束媒体进程失败 errno \(errno)")
            return false
        }
        diagnostics.log("media", "重启音频：已结束媒体进程 \(pid)，等 WebKit 重新启动")
        return true
    }

    /// 网页视图的媒体进程 pid；没有媒体进程、系统不提供这个属性、或 pid 不是媒体进程时为 nil。
    static func mediaProcessID(of webView: WKWebView) -> pid_t? {
        let key = "_gpuProcessIdentifier"
        guard webView.responds(to: Selector(key)),
              let pid = (webView.value(forKey: key) as? NSNumber)?.int32Value,
              isMediaProcess(pid: pid, name: processName(pid)) else { return nil }
        return pid
    }

    /// 只认 pid 有效、不是自己、名字是 WebKit 媒体进程的情况。
    static func isMediaProcess(pid: pid_t, name: String?) -> Bool {
        pid > 1 && pid != getpid() && name == mediaProcessName
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// ⌘R、窗口里的“重新加载”、网页内容进程终止后都走这里。
    /// 窗口里没有页面时 reload() 不会重新请求（2026-11-11 实测），所以显式 load：有失败地址就加载它；
    /// 首次加载还没完成或被取消时，重新加载最后请求的地址。关闭以后什么都不做（它也会直接 webView.reload()，不只经过 load）。
    func reload() {
        guard !isClosed else { return }
        if let url = recovery.manualReload() {
            retryTimer?.cancel()
            retryTimer = nil
            log("nav", "重新加载失败的地址")
            load(url)
            publishLoadProblem()
            return
        }
        if !pageCommitted, let url = lastRequestedURL {
            log("nav", "还没有页面，重新加载请求的地址")
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

    /// 只有从断网变成在线才触发重试；断网期间不发请求。关闭以后不理（不记日志、不重试）：
    /// 正式运行时关闭时也从共用的网络状态上去掉了（ChatTabs.close），这里是运行时自己的规则。
    func networkChanged(online: Bool) {
        guard !isClosed else { return }
        if online != recovery.online { log("net", online ? "网络可用" : "网络不可用") }
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
    /// 关闭以后不重试、不排定时器、不改提示（窗口显示后、定时器、加载失败和取消都经过这里）。
    private func handle(_ action: LoadRecovery.Action, trigger: String) {
        guard !isClosed else { return }
        switch action {
        case .none:
            break
        case .retry(let url):
            retryTimer?.cancel()
            retryTimer = nil
            log("nav", "自动重试（\(trigger)）第 \(recovery.autoRetries) 次")
            load(url)
        case .schedule(let delay):
            retryTimer?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.retryTimerFired() }
            }
            retryTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            log("nav", "\(String(format: "%g", delay)) 秒后自动重试")
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
        log("nav", "无法连接提示：\(status)")
        onLoadProblemChange?(status)
    }

    private func openExternally(_ url: URL) {
        log("nav", "外部链接交给默认浏览器：\(Redactor.describe(url))")
        NSWorkspace.shared.open(url)
    }

    // MARK: - 关闭

    /// 关闭这个页面（关闭标签页时由 ChatTabs.close(_:) 调用；入口是 ChatTabs.closeTab(_:)，应用里现在还没有地方调用）。
    /// 先进入关闭态，之后这个运行时自己不再发起任何加载：定时重试、网络变化、窗口显示后、内容进程终止后的重新加载、
    /// ⌘R、新对话都不加载（load、reload、handle 都先看它），网页的导航事件（提交、加载完成、失败、取消）也不再改恢复状态、
    /// 不再转给窗口、不再排计时。所以下面停止加载引起的取消（-999）不会再排一次重试。
    /// 然后：取消排着的重试；停止加载；断开六个回调（接线的闭包持有页面状态，断开后不再驱动它）；
    /// 停掉地址观察和消息桥；关掉这个页面开的弹窗。
    /// 关闭以后网页自己发起的导航、新窗口、提示框、确认框、文件选择、媒体采集也都按取消处理（见各代理方法）；
    /// 记下、放回、丢弃阅读位置也不再碰网页。关闭之前发出、之后才返回的网页脚本（加载完成后的 Esc 脚本、渲染自检、
    /// 排版、确认阅读位置、读浏览器标识）回来时什么都不写。所以关闭以后这个运行时只写关闭的那一行；
    /// 例外是关闭之前已经开始的下载：这里不取消它，运行时还在时下载代理照常写“下载完成/失败”（下载怎么处理还没定，D10）。
    /// 关两遍：第二遍什么都不做。
    /// 不做的：从共用的网络状态上去掉（登记是 ChatTabs 做的，去掉也由它做）；从窗口拿掉网页视图（关的不是显示着的：
    /// ChatTabs.closeTab(_:) 先换上邻居，ChatTabs.close(_:) 再从窗口里拿出来）；取消进行中的网页脚本（没有办法取消：适配器的
    /// 由它自己的关闭态挡住剩下的步骤，ChatTabs 的操作在 holds 检查处停下，见 ChatTabs.close(_:)）；停掉网页里正在播放的声音
    /// （网页视图释放时随网页一起结束；关闭后要不要先显式停掉，等 M1 实测）。
    func close() {
        guard !isClosed else { return }
        isClosed = true
        let hadRetry = retryTimer != nil
        retryTimer?.cancel()
        retryTimer = nil
        webView.stopLoading()
        onURLChange = nil
        onMainFrameLoaded = nil
        onMainFrameCommitted = nil
        onLoadFailed = nil
        onEscapeRequest = nil
        onLoadProblemChange = nil
        observations.forEach { $0.invalidate() }
        observations = []
        pathMonitor?.cancel()
        pathMonitor = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "cc", contentWorld: .defaultClient)
        let popups = popupWindows
        popupWindows = []
        popups.forEach { $0.close() }
        log("web", "关闭网页：停止加载\(hadRetry ? "，取消排着的自动重试" : "")\(popups.isEmpty ? "" : "，关掉 \(popups.count) 个弹窗")")
    }
}

// MARK: - 后退、前进

extension WebRuntime: HistoryPage {
    func canGo(_ direction: HistoryDirection) -> Bool {
        switch direction {
        case .back: webView.canGoBack
        case .forward: webView.canGoForward
        }
    }

    /// 只走这个 WKWebView 自己的历史（goBack / goForward）。跨文档的条目照常经过下面的导航策略（decidePolicyFor），
    /// 这里不放宽、不绕开；网页自己 pushState 出来的同一文档条目由网页处理。日志只写脱敏后的地址类别。
    @discardableResult
    func go(_ direction: HistoryDirection, source: String) -> Bool {
        guard canGo(direction) else {
            diagnostics.log("nav", "\(direction.logName)（\(source)）：没有可去的页面")
            return false
        }
        let list = webView.backForwardList
        let item = direction == .back ? list.backItem : list.forwardItem
        diagnostics.log("nav", "\(direction.logName)（\(source)）→ \(Redactor.describe(item?.url))")
        switch direction {
        case .back: _ = webView.goBack()
        case .forward: _ = webView.goForward()
        }
        return true
    }

    /// 顶部返回箭头是否显示（见 HistoryNavigation.showsBackButton）。
    var showsBackButton: Bool {
        HistoryNavigation.showsBackButton(url: webView.url, canGoBack: canGo(.back))
    }
}

// MARK: - 导航策略

/// 关闭以后（isClosed）：网页自己发起的导航、下载一律取消，导航事件一律不理（不改状态、不写日志、不转给窗口）。
extension WebRuntime: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard !isClosed else { return (.cancel, preferences) }
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        // 子框架（例如 Cloudflare 验证 iframe）由网页自行管理
        guard let frame = navigationAction.targetFrame, frame.isMainFrame else { return (.allow, preferences) }

        let url = navigationAction.request.url
        let kind = NavigationPolicy.classify(url)
        let userOpensElsewhere = navigationAction.navigationType == .linkActivated &&
            navigationAction.modifierFlags.contains(.command)
        // 后退、前进（菜单、⌘[ ⌘]、鼠标侧键、顶部箭头、触控板轻扫）到别的文档时也经过这里，按同样的规则处理。
        // 记一笔，查“按一下走了两次”时用。
        if navigationAction.navigationType == .backForward, webView === self.webView {
            diagnostics.log("nav", "后退/前进导航：\(Redactor.describe(url))（\(kind)）")
        }

        switch kind {
        case .chat, .auth:
            if userOpensElsewhere, let url {
                openExternally(url)
                return (.cancel, preferences)
            }
            if webView === self.webView, kind == .auth {
                log("nav", "认证跳转：\(Redactor.describe(url))")
            }
            return (.allow, preferences)
        case .external:
            if let url { openExternally(url) }
            return (.cancel, preferences)
        case .blocked:
            log("nav", "已阻止导航：\(Redactor.describe(url))")
            return (.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard !isClosed else { return .cancel }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// 右键菜单“下载图像 / 下载链接文件”发起的下载不走上面两个公开回调，WebKit 只通过这个导航代理方法交出来
    /// （WKNavigationDelegatePrivate）。没人接时下载被悄悄丢掉（2026-11-24 实测）。只是响应一个方法名，不调用私有接口。
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreateDownload download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isClosed, webView === self.webView else { return }
        recovery.navigationStarted()
        publishLoadProblem()
    }

    /// 页面一提交就取消重试、记下有页面，并告诉窗口“提示可以收起”。窗口先收到提交，
    /// 会把提示留到加载完成再淡出（2026-11-15：提交时网页还没画出来，立刻收起会露出空白白色）。
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !isClosed, webView === self.webView else { return }
        onMainFrameCommitted?()
        pageArrived()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed else { return }
        log("nav", "加载完成 \(Redactor.describe(webView.url))")
        guard webView === self.webView else { return }
        pageArrived()
        ensureEscapeScript()
        onMainFrameLoaded?()
        // 无正文的渲染自检：只取数量。到点时已经关闭就不做；自检脚本返回时已经关闭也不记。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                let size = self.webView.frame.size
                let js = "JSON.stringify({rs: document.readyState, els: document.getElementsByTagName('*').length, vis: document.visibilityState})"
                self.webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { result in
                    MainActor.assumeIsolated {
                        guard !self.isClosed else { return }
                        let summary = (try? result.get()) as? String ?? "error"
                        self.log("render", "自检 frame=\(Int(size.width))x\(Int(size.height)) \(summary)")
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
        guard !isClosed else { return }
        let ns = error as NSError
        // NSURLErrorCancelled（-999）与 WebKit 框架中断（102）是正常的导航取消，不算加载故障。
        if ns.code == NSURLErrorCancelled || (ns.domain == "WebKitErrorDomain" && ns.code == 102) {
            // 被新的加载顶掉时 isLoading 仍为 true，交给新的加载；什么都没在加载时，空白窗口回到等待，不一直显示“正在重新连接”。
            if webView === self.webView, !mainFrameIsLoading() {
                handle(recovery.navigationCancelled(), trigger: "导航取消")
            }
            return
        }
        log("nav", "加载失败 \(ns.domain)#\(ns.code) @ \(Redactor.describe(webView.url))")
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
        guard !isClosed else { return }
        log("web", "网页内容进程终止，重新加载")
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
        log("download", "开始下载（文件名已省略）")
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        log("download", "下载完成")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let ns = error as NSError
        log("download", "下载失败 \(ns.domain)#\(ns.code)")
    }
}

// MARK: - UI 代理：新窗口、文件选择、JS 对话框、媒体权限

/// 关闭以后（isClosed）：不开新窗口，提示框、确认框、文件选择都按取消处理（不显示），媒体采集照样拒绝、不写日志。
/// 不显示的标签页的这些请求等它被选中再显示，是以后切换标签页的事；这里只管关闭以后。
extension WebRuntime: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !isClosed else { return nil }
        let url = navigationAction.request.url
        // 内嵌图片（data:）：WebKit 不肯把 data: 地址当顶层页面打开，交给它只会得到空白弹窗。
        if let image = ImageDataURL.decode(url) {
            diagnostics.log("nav", "在新窗口打开内嵌图片 \(image.mimeType)")
            openImageViewer(image)
            return nil
        }
        let kind = NavigationPolicy.classify(url)
        if kind == .external, let url {
            openExternally(url)
            return nil
        }
        if kind == .blocked { return nil }
        // 认证等弹窗：使用 WebKit 提供的 configuration 以保留 window.opener 关系
        log("nav", "打开弹窗：\(Redactor.describe(url))")
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        presentPopup(popup, show: true)
        return popup
    }

    private func presentPopup(_ view: WKWebView, show: Bool) {
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = L10n.string("window.popup")
        window.contentView = view
        window.center()
        if show { window.makeKeyAndOrderFront(nil) }
        popupWindows.append(window)
    }

    /// 单独显示一张内嵌图片。和 ChatGPT 页面隔开：不带网站数据，不运行脚本。测试传 show: false，不显示窗口。
    @discardableResult
    func openImageViewer(_ image: ImageDataURL.Payload, show: Bool = true) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let viewer = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: config)
        viewer.navigationDelegate = self
        presentPopup(viewer, show: show)
        viewer.load(image.data, mimeType: image.mimeType, characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
        return viewer
    }

    /// 切换界面语言后，已经开着的弹窗也换标题。
    func retitlePopups() {
        popupWindows.forEach { $0.title = L10n.string("window.popup") }
    }

    #if DEBUG
    /// 只给测试用（调试版才有）：把一个不显示的窗口当作这个运行时开着的弹窗记下。
    /// 真的弹窗要网页来开，开的时候还会显示在屏幕上，测试不能那样做。
    func adoptPopupForTesting(_ window: NSWindow) {
        popupWindows.append(window)
    }
    #endif

    func webViewDidClose(_ webView: WKWebView) {
        if let idx = popupWindows.firstIndex(where: { $0.contentView === webView }) {
            popupWindows[idx].close()
            popupWindows.remove(at: idx)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard !isClosed else { return nil }
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
        guard !isClosed else { return }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        // 按钮写明，否则用系统语言，和手动选的界面语言不一致。网页给的文字原样显示。
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard !isClosed else { return false }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        // Phase 0 不开启麦克风/摄像头（实时 Voice Chat 属于 P1）。关闭以后也拒绝，不写日志。
        guard !isClosed else { return .deny }
        log("media", "已拒绝媒体采集请求（Phase 0 不启用）")
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
            log("bridge", "已拒绝不符合约束的消息")
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
