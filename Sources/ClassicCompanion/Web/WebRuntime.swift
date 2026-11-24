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
    /// 网页视图报的页面底色（underPageBackgroundColor）变了，参数是它此刻报的颜色。WebKit 只在颜色真的变了时报；
    /// 显示着的、藏着的网页视图都报。ChatTabs.wire(_:) 接到窗口，只用来让新标签页的遮挡在页面开始显示时就撤
    /// （ChatWindowController.pageDidReportColor(_:_:)）；顶部一条和窗口底色跟不跟页面颜色，仍是窗口自己观察显示着的网页视图。
    var onPageColorChange: ((NSColor?) -> Void)?
    /// 网页标题（WKWebView.title）或者网页在不在加载（isLoading）变了，参数是此刻的两样（标签栏的标题规则两样都看，
    /// TabBarRules.displayTitle）。显示着的、藏着的网页视图都报。ChatTabs.wire(_:) 接到这个标签页的标题和标签栏模型。
    /// 标题是对话内容：这里和接它的地方都不写日志、不写诊断。
    var onTitleChange: ((_ title: String?, _ isLoading: Bool) -> Void)?
    /// ⌘ 点击、⇧⌘ 点击聊天链接（3.12，规则在 ChatLinkClick）：请这个页面所在的标签页那一组在新标签页打开 url。
    /// ChatTabs.wire(_:) 接成 ChatTabs.openLink(_:from:_:)（来源就是这个标签页）。没接上（测试里单独建的运行时）：不打开，写一行。
    /// 不管打不打开，这一页的导航都已经取消（不在这一页打开，也不交给浏览器）。
    var onOpenLinkInTab: ((URL, ChatLinkClick.Opening) -> Void)?
    /// 交给默认浏览器打开（外部链接、⌘ 点击不是聊天页面的链接）。正式运行就是 NSWorkspace.shared.open；
    /// 只有测试换它：测试不能打开浏览器。
    var openInBrowser: @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    /// 把登录等弹窗的窗口显示到前面（makeKeyAndOrderFront）。正式运行就是原来的做法；只有测试换它：测试不能显示窗口。
    var showPopupWindow: @MainActor (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }
    /// 弹窗的窗口在不在屏幕上：可见、没有最小化（isInFront(_:) 看它）。只有测试换它：测试里的弹窗窗口从不显示。
    var popupWindowIsOnScreen: @MainActor (NSWindow) -> Bool = { $0.isVisible && !$0.isMiniaturized }

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

    /// 这个页面是不是选中的标签页（窗口显示着它）。网页的对话框和新窗口看它（见 WKUIDelegate 那一段）。
    /// ChatTabs.wire(_:) 接成“它是选中的标签页”；不接（测试里单独建的运行时）就总是 true：和只有一个页面时一样。
    var isSelectedTab: @MainActor () -> Bool = { true }
    /// 把网页的对话框真的显示出来，返回用户的回答。正式运行就是原来的做法（runAlert、runConfirm、runOpenPanel）；
    /// 只有测试换它们：测试不能弹模态框、开文件选择。只在轮到显示时调用，每个请求最多一次。
    /// 最后一个参数是这一次显示（ShownDialog）：页面在它显示着时关闭，就调用它的 dismiss（文件选择设成收起面板）。
    var presentAlert: @MainActor (_ host: String, _ message: String, _ shown: ShownDialog) async -> Void = { host, message, _ in
        WebRuntime.runAlert(host: host, message: message)
    }
    var presentConfirm: @MainActor (_ host: String, _ message: String, _ shown: ShownDialog) async -> Bool = { host, message, _ in
        WebRuntime.runConfirm(host: host, message: message)
    }
    var presentOpenPanel: @MainActor (_ allowsMultipleSelection: Bool, _ allowsDirectories: Bool,
                                      _ shown: ShownDialog) async -> [URL]? = {
        await WebRuntime.runOpenPanel(allowsMultipleSelection: $0, allowsDirectories: $1, shown: $2)
    }
    /// 排着等显示的网页对话框，按到达的先后。
    private var heldDialogs: [HeldDialog] = []
    /// 排着的里面放出来的那一个：从放出来（showHeldDialogs()）到它显示完。同一时间最多一个，后面的等它显示完再放。
    private var dialogTurn: HeldDialog?
    /// 正在显示的网页对话框（马上显示的和放出来的都算），按开始显示的先后。
    private var shownDialogs: [ShownDialog] = []
    /// 排着等显示的网页对话框有几个（测试和诊断用）。
    var heldDialogCount: Int { heldDialogs.count }
    /// 这一页的网页对话框已经按取消处理（cancelDialogs()）：之后这一页的对话框一律马上按取消回答，不显示、不排着；
    /// 已经放出来、还没显示的，醒来时也按取消回答，不再放回去排着。不会改回。
    /// 关闭（close()）一定先进入它；关闭显示着的标签页时 ChatTabs.closeTab(_:) 在切换到邻居之前就进入（用户 11-20 的裁定：
    /// 先取消旧页面的对话框请求，再处理邻居），那时这一页还没关闭。
    private(set) var dialogsCancelled = false
    /// cancelDialogs() 那一刻按取消处理的种类和个数（“提示框 1 个、文件选择 1 个”，没有就是空的），写进关闭那一行。
    private var cancelledDialogs = ""

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
        observations.append(webView.observe(\.underPageBackgroundColor) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.onPageColorChange?(webView.underPageBackgroundColor) }
        })
        observations.append(webView.observe(\.title) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.onTitleChange?(webView.title, webView.isLoading) }
        })
        observations.append(webView.observe(\.isLoading) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.onTitleChange?(webView.title, webView.isLoading) }
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

    /// 应用发出主框架加载都经过这里（启动、自动重试、网络恢复、窗口显示后、⌘R 有失败地址时、新对话，
    /// 和新标签页的第一次加载：新增、重新打开、⌘ 点击链接）。关闭以后什么都不发。
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
            log("media", "重启音频：找不到媒体进程，没有操作")
            return false
        }
        guard kill(pid, SIGKILL) == 0 else {
            log("media", "重启音频：结束媒体进程失败 errno \(errno)")
            return false
        }
        log("media", "重启音频：已结束媒体进程 \(pid)，等 WebKit 重新启动")
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

    /// 外部链接（不在应用里打开的地址）交给默认浏览器——只在发出它的网页视图 webView 在前面（isInFront(_:)）时。
    /// 不在前面：不交给浏览器，写一行（地址经 Redactor，带标签），调用方照样取消这次导航、不给新窗口。不显示的标签页的网页
    /// 自己跳到外部地址、window.open 外部地址，不会在用户看着别的标签页时突然打开浏览器、把浏览器放到前面。
    /// 选中的标签页（和没接上标签页的运行时，isSelectedTab 总是 true）照原来交给浏览器。
    /// 不显示的标签页的网页什么时候真的这样做（网页自己的跳转、脚本、计时器）这里测不到：真的触发要在 M1 的屏幕检查上看。
    private func openExternally(_ url: URL, from webView: WKWebView) {
        guard isInFront(webView) else {
            let source = webView === self.webView ? "不显示的标签页" : "不显示的标签页的弹窗（窗口不在屏幕上）"
            log("nav", "\(source)要把外部链接交给默认浏览器：不交，取消：\(Redactor.describe(url))")
            return
        }
        log("nav", "外部链接交给默认浏览器：\(Redactor.describe(url))")
        openInBrowser(url)
    }

    /// 发出请求的网页视图 webView 现在是不是在用户眼前（外部链接交不交给浏览器看它）：
    /// - 这一页自己的网页视图：这一页是选中的标签页（isSelectedTab；没接上的运行时总是 true）。
    /// - 这一页开的弹窗，窗口在屏幕上（popupWindowIsOnScreen）：是。弹窗是自己的窗口，切换标签页时不藏起来，
    ///   用户可能正在用它（比如点登录页上的条款链接），所以不跟着标签页选不选中。
    /// - 弹窗的窗口不在屏幕上（关掉了、藏起、最小化）、不认识的网页视图：和这一页一样（isSelectedTab）。
    private func isInFront(_ webView: WKWebView) -> Bool {
        isPopupOnScreen(webView) || isSelectedTab()
    }

    /// webView 是不是这一页开着的弹窗的网页视图，并且弹窗的窗口在屏幕上（popupWindowIsOnScreen）。这一页自己的网页视图不是。
    private func isPopupOnScreen(_ webView: WKWebView) -> Bool {
        guard webView !== self.webView, let window = popupWindows.first(where: { $0.contentView === webView }) else {
            return false
        }
        return popupWindowIsOnScreen(window)
    }

    /// 这次导航是不是在新标签页打开的 ⌘ 点击（3.12）：是这个页面自己的网页视图（不是它开的弹窗：弹窗里的 ⌘ 点击照原来交给
    /// 浏览器），并且 ChatLinkClick 说是（点链接、按着 ⌘、聊天页面；⇧ 决定切不切过去）。不是就是 nil，照原来的路走。
    private func tabOpening(for action: WKNavigationAction, in webView: WKWebView) -> ChatLinkClick.Opening? {
        guard webView === self.webView else { return nil }
        let flags = action.modifierFlags
        return ChatLinkClick.opening(url: action.request.url, linkActivated: action.navigationType == .linkActivated,
                                     command: flags.contains(.command), shift: flags.contains(.shift))
    }

    /// 在新标签页打开 url：交给标签页那一组（onOpenLinkInTab）。打不打开、放在哪由它定，这里不写日志（它写 [tabs] 那一行，
    /// 没有地址）。没接上：不打开，写一行（没有地址）。调用方之后取消这一页的导航（或不给新窗口）。
    private func openInTab(_ url: URL, _ opening: ChatLinkClick.Opening) {
        guard let onOpenLinkInTab else {
            log("nav", "⌘ 点击的聊天链接：没有接上标签页，不打开")
            return
        }
        onOpenLinkInTab(url, opening)
    }

    // MARK: - 关闭

    /// 关闭这个页面（关闭标签页时由 ChatTabs.close(_:) 调用；入口是 ChatTabs.closeTab(_:)，应用里是多于一个标签页时的 ⌘W
    /// 和菜单里的“关闭标签页”）。
    /// 先进入关闭态，之后这个运行时自己不再发起任何加载：定时重试、网络变化、窗口显示后、内容进程终止后的重新加载、
    /// ⌘R、新对话都不加载（load、reload、handle 都先看它），网页的导航事件（提交、加载完成、失败、取消）也不再改恢复状态、
    /// 不再转给窗口、不再排计时。所以下面停止加载引起的取消（-999）不会再排一次重试。
    /// 然后：取消排着的重试；停止加载；断开八个回调（接线的闭包持有页面状态，断开后不再驱动它；含报页面底色的 onPageColorChange、
    /// 报标题的 onTitleChange）和在新标签页打开链接的那一个（onOpenLinkInTab：关闭以后导航判断本来就先取消，这里只是不再拿着它）；
    /// 停掉地址、页面底色、标题和加载中的观察、消息桥；关掉这个页面开的弹窗；网页的对话框按取消处理（cancelDialogs()：排着的不再显示，
    /// 显示着的文件选择收起，每一个都按取消回答 WebKit，各正好一次；关闭显示着的标签页时 ChatTabs 已经先做过，这里不再做）。
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
        onPageColorChange = nil
        onTitleChange = nil
        onOpenLinkInTab = nil
        observations.forEach { $0.invalidate() }
        observations = []
        pathMonitor?.cancel()
        pathMonitor = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "cc", contentWorld: .defaultClient)
        let popups = popupWindows
        popupWindows = []
        popups.forEach { $0.close() }
        // 已经取消过（关闭显示着的标签页时，切换到邻居之前）就不再做，那时取消的种类和个数照样写进这一行。
        cancelDialogs()
        let dialogs = cancelledDialogs
        log("web", "关闭网页：停止加载\(hadRetry ? "，取消排着的自动重试" : "")\(popups.isEmpty ? "" : "，关掉 \(popups.count) 个弹窗")"
                   + (dialogs.isEmpty ? "" : "，网页的对话框按取消处理（\(dialogs)）"))
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
            log("nav", "\(direction.logName)（\(source)）：没有可去的页面")
            return false
        }
        let list = webView.backForwardList
        let item = direction == .back ? list.backItem : list.forwardItem
        log("nav", "\(direction.logName)（\(source)）→ \(Redactor.describe(item?.url))")
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
///
/// 外部链接（外部网站，和 ⌘ 点击不在新标签页打开的链接）交给默认浏览器，只在发出它的网页视图在前面时（openExternally(_:from:)）：
/// 不显示的标签页（和它窗口不在屏幕上的弹窗）要打开外部地址，取消、写一行，不交给浏览器。选中的标签页照原来。
///
/// ⌘ 点击链接（点链接并按着 ⌘，原来整支交给默认浏览器）：这个页面自己的网页视图里点的聊天页面链接（ChatLinkClick）改为
/// 在新标签页打开（3.12：⌘ 在后台，⇧⌘ 切换过去，见 openInTab(_:_:)），这一页的导航取消；打不打开都一样取消
/// （到上限、启动画面还在、点击来自不显示的标签页等不打开时，这一页也不跳转、也不交给浏览器）。别的 ⌘ 点击照原来交给浏览器。
/// 目标是新窗口的链接（target=_blank）：WebKit 先在这里问一次（没有目标 frame，照原来放行），再要新窗口
/// （webView(_:createWebViewWith:for:windowFeatures:)），在那里判断。
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
            log("nav", "后退/前进导航：\(Redactor.describe(url))（\(kind)）")
        }

        switch kind {
        case .chat, .auth:
            if userOpensElsewhere, let url {
                if let opening = tabOpening(for: navigationAction, in: webView) {
                    openInTab(url, opening)
                    return (.cancel, preferences)
                }
                openExternally(url, from: webView)
                return (.cancel, preferences)
            }
            if webView === self.webView, kind == .auth {
                log("nav", "认证跳转：\(Redactor.describe(url))")
            }
            return (.allow, preferences)
        case .external:
            if let url { openExternally(url, from: webView) }
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
                // 回调只弱引用运行时：网页一直忙、脚本一直不回来，也不拿着关闭了的运行时（和它的网页视图）。
                self.webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { [weak self] result in
                    MainActor.assumeIsolated {
                        guard let self, !self.isClosed else { return }
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
/// 对话框按取消处理从 dialogsCancelled 起（关闭一定先进入它；关闭显示着的标签页时更早，在切换到邻居之前）。
///
/// 网页的对话框（提示框、确认框、文件选择）属于发出它的网页视图（WebKit 交来的 webView），按 runDialog(_:from:cancel:present:)
/// 的规则显示。先看是谁发出的：
/// - 这一页开着的弹窗（登录等），弹窗的窗口在屏幕上（popupWindowIsOnScreen）：属于那个弹窗。马上显示，不管这一页是不是选中的，
///   也不排在这一页的队里（不等这一页排着的、放出来的）。弹窗是自己的窗口，切换标签页时不藏起来，用户看得见它、可能正在用它
///   （登录页的确认框不能等到切回那个标签页才出来，弹窗的网页在等回答时一直停着）。这一页不是选中的时写一行（只有种类）。
///   显示的样子和这一页的一样（presentAlert、presentConfirm、presentOpenPanel：应用级模态框、文件选择面板），
///   不挂在弹窗的窗口上（挂上去要换显示的做法，留给以后定）。
/// - 这一页自己的网页视图，和窗口不在屏幕上（藏起、最小化）的弹窗：属于这个标签页，按标签页的规则：
///   - 这一页是选中的（isSelectedTab）、没有排着的：马上显示，和原来一样（只有一个页面时总是这样，窗口隐藏、最小化时也是）。
///   - 不是选中的：排在这一页上（heldDialogs，按到达的先后），什么都不显示，写一行（只有种类和个数）；
///     这一页被选中、窗口显示它以后（ChatTabs.select(_:) 最后调用 showHeldDialogs()）一次放出一个，显示完再放下一个。
/// - 不管是谁发出的：排着时、放出来还没显示时、显示着时这一页的对话框按取消处理了（cancelDialogs()，关闭这个标签页时，
///   和原来一样）：按取消回答（提示框：结束；确认框：false；文件选择：nil）。关闭时它开着的弹窗也一起关掉。
/// 标签页换到后台时，它开着的弹窗照旧开着（不关、不藏，原来就这样，没有改）：登录可能正做到一半，关掉要重新来；
/// 所以弹窗的对话框跟着弹窗的窗口走，不跟着标签页。
/// 每个请求 WebKit 的回调都正好调用一次：代理方法每次调用正好返回一次，返回时由 WebKit 的接口调用回调。
/// 排着的不设上限，个数不会自己一直涨：提示框、确认框让发出它的网页停下等回答，一个网页一次只有一个在等；
/// 文件选择 WebKit 一个网页一次只发一个（两样都有测试实测，TabDialogTests）。一个标签页排着的最多是它的网页和它开着的
/// 每个弹窗各一两个。排着的提示框、确认框让那一页的网页停着，直到选中它或关闭它（关闭时按取消回答，网页接着跑完、随后释放）。
/// 网页要求输入文字（prompt()）：不支持，故意不实现那个代理方法（webView(_:runJavaScriptTextInputPanelWithPrompt:…)）。
/// WebKit 的说明：不实现时当作用户点了“取消”。实测（TabDialogTests 里 prompt 那几条，真的网页）：选中的标签页、不选中的、
/// 它开的弹窗、关闭以后，网页都马上拿到 null 接着往下跑，什么都不显示、不排着、不写日志，也没有等着回答的回调。
/// 要支持时再实现，并按上面对话框的规则走（runDialog）。
///
/// 新窗口（登录等弹窗）：不是选中的标签页要开，不开（返回 nil，写一行）。WebKit 要当场拿到弹窗的网页视图，不能像对话框那样等。
/// 目标是外部地址的新窗口：不开弹窗，交给默认浏览器（openExternally(_:from:)：发出它的网页视图不在前面就不交，写一行）。
/// 例外（3.12）：⌘ 点击目标是新窗口的聊天页面链接，不开弹窗，在新标签页打开（返回 nil），在上面这条之前判断。
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
            openExternally(url, from: webView)
            return nil
        }
        if kind == .blocked { return nil }
        // ⌘ 点击目标是新窗口（target=_blank）的聊天页面链接（3.12）：不开弹窗，在新标签页打开（openInTab），给 WebKit nil
        // （没有新窗口，链接什么都不做）。放在下面“不显示的标签页不开弹窗”之前：点击来自不显示的标签页时由标签页那一组不打开、
        // 写它自己的那一行，不写弹窗那一行。window.open() 不是点链接（WebKit 报 .other），不算，照下面原来的路走。
        if let url, let opening = tabOpening(for: navigationAction, in: webView) {
            openInTab(url, opening)
            return nil
        }
        // 不是选中的标签页：不开。开了就是一个新窗口出现在显示着的那一页上面；网页拿到 null（和弹窗被拦下一样），
        // 用户切回这一页再点一次。不写地址。
        guard isSelectedTab() else {
            log("nav", "不显示的标签页要开弹窗：不开")
            return nil
        }
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
        if show { showPopupWindow(window) }
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
        // 仅响应网页上的用户操作；不会自动上传任何文件
        let multiple = parameters.allowsMultipleSelection, directories = parameters.allowsDirectories
        return await runDialog(.openPanel, from: webView, cancel: nil) { shown in
            await presentOpenPanel(multiple, directories, shown)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await runDialog(.alert, from: webView, cancel: ()) { shown in
            await presentAlert(frame.securityOrigin.host, message, shown)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await runDialog(.confirm, from: webView, cancel: false) { shown in
            await presentConfirm(frame.securityOrigin.host, message, shown)
        }
    }

    // MARK: 网页的对话框：排着、放出来、取消

    /// 网页的一个对话框（webView 发出的）按这一页的规则走一遍，返回给 WebKit 的回答：
    /// - 这一页的对话框已经按取消处理（dialogsCancelled：关闭了，或者正在关闭、还没切换到邻居）：cancel，不显示、不排着、
    ///   不写日志（3.1 的规则）。弹窗发出的也一样。
    /// - 弹窗的窗口在屏幕上、webView 是那个弹窗的（isPopupOnScreen(_:)）：马上显示，不排着；这一页不是选中的时写一行
    ///   “弹窗的…：弹窗在屏幕上，马上显示”（只有种类）。
    /// - 这一页是选中的，没有排着的，也没有放出来还没显示完的：马上显示（present），和原来一样，不写日志。
    /// - 不然排在这一页上（写一行“排着等显示”），等放出来（waitForTurn(_:)）再显示（写一行“显示排着的”）；
    ///   等着时按取消处理了：cancel，不显示。
    /// - 显示着时按取消处理了：cancelDialogs() 调用这一次的 dismiss（能收起的收起），present 返回后按 cancel 回答
    ///   （不管用户选了什么）。
    /// 放出来的那一个显示完，放下一个（showHeldDialogs()）。present 最多调用一次；这个函数每次调用正好返回一次。
    private func runDialog<Answer>(_ kind: WebDialogKind, from webView: WKWebView, cancel: Answer,
                                   present: (ShownDialog) async -> Answer) async -> Answer {
        guard !dialogsCancelled else { return cancel }
        var held: HeldDialog?
        if isPopupOnScreen(webView) {
            if !isSelectedTab() { log("web", "弹窗的\(kind.name)：弹窗在屏幕上，马上显示（标签页不显示）") }
        } else if !isSelectedTab() || !heldDialogs.isEmpty || dialogTurn != nil {
            let waiting = HeldDialog(kind)
            heldDialogs.append(waiting)
            log("web", "网页的\(kind.name)排着等显示（排着 \(heldDialogs.count) 个）")
            guard await waitForTurn(waiting) else { return cancel }
            log("web", "显示排着的\(kind.name)（还排着 \(heldDialogs.count) 个）")
            held = waiting
        }
        let shown = ShownDialog(kind, held: held)
        shownDialogs.append(shown)
        let answer = await present(shown)
        shownDialogs.removeAll { $0 === shown }
        if let held, dialogTurn === held {
            dialogTurn = nil
            showHeldDialogs()
        }
        return dialogsCancelled ? cancel : answer
    }

    /// 排着的 held 等到放出来。返回 true：该显示了（这时它是 dialogTurn，这一页是选中的、对话框没有按取消处理）；
    /// false：按取消处理了（关闭，或正在关闭），按取消回答。
    /// 继续它的只有两处，各正好一次：showHeldDialogs() 放出它（先把它设成 dialogTurn）、cancelDialogs() 取消它
    /// （先进入 dialogsCancelled）。
    /// 放出来以后、真的显示之前（下一轮）：先看按取消处理了没有——关闭显示着的标签页时，放出来的那一个醒来时这一页已经
    /// 不是选中的，要按取消回答，不能当作“又切换走了”放回去排着；没有按取消处理、这一页又不是选中的了（又切换走了）：
    /// 放回最前面接着等，不写日志。
    private func waitForTurn(_ held: HeldDialog) async -> Bool {
        while true {
            await withCheckedContinuation { held.waiting = $0 }
            if dialogsCancelled { return false }
            if isSelectedTab() { return true }
            if dialogTurn === held { dialogTurn = nil }
            heldDialogs.insert(held, at: 0)
        }
    }

    /// 放出排着的第一个：它在之后的一轮里显示（这一轮的切换、关闭先做完），显示之前再看一次这一页还是不是选中的、关没关闭。
    /// 调用的地方：ChatTabs.select(_:) 的最后一步（这一页被选中、窗口显示了它）；放出来的那一个显示完时（runDialog）。
    /// 对话框按取消处理了（关闭、正在关闭）、这一页不是选中的、已经放出一个还没显示完、没有排着的：什么都不做。
    func showHeldDialogs() {
        guard !dialogsCancelled, isSelectedTab(), dialogTurn == nil, !heldDialogs.isEmpty else { return }
        let next = heldDialogs.removeFirst()
        dialogTurn = next
        next.resume()
    }

    /// 这一页的网页对话框都按取消处理，之后来的也是（进入 dialogsCancelled，不会改回）：
    /// 排着的都继续（看到已经按取消处理，按取消回答），放出来还没显示的醒来时也按取消回答（不放回去排着），
    /// 显示着的调用 dismiss（文件选择收起；模态框收不起，用户点掉以后按取消回答）。每一个都正好回答一次。
    /// 只做一次：再调用什么都不做。调用的地方：close()（总是）；ChatTabs.closeTab(_:) 关显示着的标签页时，在切换到邻居之前
    /// （先取消这一页的，邻居排着的对话框才放出来）。不写日志：取消的种类和个数（“提示框 1 个、文件选择 1 个”，只有种类和
    /// 个数，没有网页的文字和文件名）记在 cancelledDialogs，由 close() 写进关闭那一行，只写一次。
    func cancelDialogs() {
        guard !dialogsCancelled else { return }
        dialogsCancelled = true
        let waiting = heldDialogs
        heldDialogs = []
        var kinds = waiting.map(\.kind)
        if let turn = dialogTurn, !shownDialogs.contains(where: { $0.held === turn }) {
            kinds.append(turn.kind)
        }
        kinds += shownDialogs.map(\.kind)
        waiting.forEach { $0.resume() }
        shownDialogs.forEach { $0.dismiss?() }
        cancelledDialogs = WebDialogKind.allCases.compactMap { kind in
            let count = kinds.filter { $0 == kind }.count
            return count == 0 ? nil : "\(kind.name) \(count) 个"
        }.joined(separator: "、")
    }

    /// 原来的提示框：应用级模态框（runModal），标题是网页的主机名，正文是网页给的文字。
    static func runAlert(host: String, message: String) {
        let alert = NSAlert()
        alert.messageText = host
        alert.informativeText = message
        // 按钮写明，否则用系统语言，和手动选的界面语言不一致。网页给的文字原样显示。
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.runModal()
    }

    /// 原来的确认框：应用级模态框，点“好”是 true。
    static func runConfirm(host: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = host
        alert.informativeText = message
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 原来的文件选择：不是模态的面板（begin），选好是选的文件，取消是 nil。页面在它显示着时关闭：收起面板（按取消）。
    static func runOpenPanel(allowsMultipleSelection: Bool, allowsDirectories: Bool, shown: ShownDialog) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = allowsDirectories
        panel.canChooseFiles = true
        shown.dismiss = { panel.cancel(nil) }
        let response = await panel.begin()
        return response == .OK ? panel.urls : nil
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

/// 网页的对话框的种类。日志里只写种类和个数，不写网页给的文字、主机名和文件名。
enum WebDialogKind: CaseIterable {
    case alert, confirm, openPanel

    var name: String {
        switch self {
        case .alert: "提示框"
        case .confirm: "确认框"
        case .openPanel: "文件选择"
        }
    }
}

/// 正在显示的一个网页对话框（WebRuntime 的 presentAlert、presentConfirm、presentOpenPanel 拿到的那一次）。
/// 显示它的一方可以设上 dismiss：页面在它显示着时关闭，WebRuntime 调用它（文件选择设成收起面板）。没设就什么都不做。
@MainActor
final class ShownDialog {
    let kind: WebDialogKind
    /// 显示的是排着、放出来的那一个时是它；马上显示的是 nil。
    fileprivate let held: HeldDialog?
    var dismiss: (() -> Void)?

    fileprivate init(_ kind: WebDialogKind, held: HeldDialog?) {
        self.kind = kind
        self.held = held
    }
}

/// 排着等显示的一个网页对话框：等着的那一刻的续体。放出来（showHeldDialogs()）或按取消处理（cancelDialogs()，关闭时）时继续，
/// 每次等正好继续一次。
@MainActor
fileprivate final class HeldDialog {
    let kind: WebDialogKind
    var waiting: CheckedContinuation<Void, Never>?

    init(_ kind: WebDialogKind) {
        self.kind = kind
    }

    /// 继续等着的那一次，并清掉：同一次不会继续两遍。
    func resume() {
        let continuation = waiting
        waiting = nil
        continuation?.resume()
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
