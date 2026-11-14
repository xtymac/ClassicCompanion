import AppKit
import SwiftUI
import WebKit
import CompanionCore

/// 用 NSPanel 只为了 orderIntoActiveSpace；其余行为和普通窗口一样。
final class ChatWindow: NSPanel {
    /// 由控制器设置：非网页焦点时的 Esc 处理（网页焦点下的 Esc 由适配脚本判断）
    var onCancel: (() -> Void)?

    /// 网页获得焦点时，Esc 是否隐藏窗口由适配脚本判断（可识别 IME 组合与网页弹层），这里不处理
    weak var webView: NSView?

    override func cancelOperation(_ sender: Any?) {
        if let webView, let responder = firstResponder as? NSView, responder.isDescendant(of: webView) {
            return
        }
        onCancel?()
    }

    /// 面板默认不能成为主窗口。
    override var canBecomeMain: Bool { true }

    /// 小窗和完整窗口之间的动画最多 0.1 秒（系统按大小算约 0.19 秒）。用户在 1347 上选的（2026-11-08）。
    /// 只有切换模式用带动画的 setFrame；动画前等网页排版的那段时间不在这里。
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        min(super.animationResizeTime(newFrame), 0.1)
    }

    /// 不显示红黄绿三个按钮：关闭、新建、切换都在顶部那一条里（参考用户给的按钮布局，2026-11-08）。
    /// 改样式（唤醒时临时加 nonactivatingPanel）可能重建标题栏，所以每次都重新藏。
    override var styleMask: NSWindow.StyleMask {
        didSet { hideSystemButtons() }
    }

    func hideSystemButtons() {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
    }

    /// 普通应用的窗口进不了其他应用的全屏 Space：激活时系统会把窗口搬到别的屏幕，单屏时可能离开全屏。
    /// 先以不激活应用的面板放进当前 Space，下一轮 run loop 再恢复普通样式并激活，窗口留在原地。
    /// 不能在同一轮激活：进入全屏后的第一次唤醒每次都会被搬走，第二次才正常（2026-11-05 实测）。
    func orderIntoActiveSpace(thenActivate activate: @escaping @MainActor () -> Void) {
        styleMask.insert(.nonactivatingPanel)
        makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.styleMask.remove(.nonactivatingPanel)
                if self.isVisible { activate() }
            }
        }
    }
}

/// 单窗口、单 WebView。Quick / Full 通过调整同一窗口尺寸切换，不迁移 WebView。
@MainActor
final class ChatWindowController: NSWindowController, NSWindowDelegate {
    enum Mode { case quick, full }

    static let quickSize = NSSize(width: 640, height: 720)
    static let fullSize = NSSize(width: 1280, height: 900)
    /// 把小窗拉到这个宽度就切到完整模式，不等松手（用户决定，2026-11-05）。
    static let fullModeDragWidth: CGFloat = 900

    private(set) var mode: Mode = .quick
    private var dragStartedInQuick = false
    private var resizingForMode = false
    private var resizingByHand = false
    /// 切到完整窗口或放好它时的左上角。切回小窗时还在这里，说明用户没有移动过它。
    private var fullTopLeftWhenPlaced: NSPoint?
    private let webView: WKWebView
    private let diagnostics: Diagnostics
    private var previousApp: NSRunningApplication?
    private var screenObserver: Any?
    private var activationObserver: Any?
    private var closeKeyMonitor: Any?

    /// 窗口显示后调用（用于聚焦官方输入框；加载恢复按显示方式决定是否提前重试）
    var onDidShow: ((Diagnostics.ShowKind) -> Void)?
    /// Runs before the window is exposed or resized.
    var onWillShow: ((Mode) -> Void)?
    private let quickPlacements = QuickPlacementStore(defaults: .standard)
    var fullSizes = FullWindowSizeStore(defaults: .standard, minimumWidth: ChatWindowController.fullModeDragWidth)
    /// 启动画面最长显示时间。到时就露出网页本身，官方页面自己显示加载或错误。
    /// 2026-11-15 起只在网页已经提交（窗口里有页面）时这样：还没提交时露出的只是空白网页区（白色），
    /// 启动画面继续显示，直到加载完成、加载失败、提交后 pageRevealLimit，或 launchScreenCap。
    var launchScreenLimit: TimeInterval = 10
    /// 从启动画面出现起最多显示多久（用户 2026-11-15 定为 30 秒）。到了照原来的方式结束，不一直挡着。
    var launchScreenCap: TimeInterval = 30
    /// 遮挡（到时限后还在的启动画面、“无法连接”提示）在提交后最多再留多久。一直没有加载完成（例如子资源卡住）时，
    /// 到时就撤，不一直挡着已经能用的页面。和颜色兜底取同一个值。
    var pageRevealLimit: TimeInterval = 1
    /// 到时限时网页还没提交，启动画面继续显示中。
    private var launchAwaitsPage = false
    /// 主框架提交过（窗口里有页面）。
    private var hasCommittedPage = false
    /// 主框架已提交、还没加载完成。
    private var awaitingFinish = false
    /// 提示收到“可以收起”时网页刚提交、还没画出来：留到加载完成再淡出。
    private var noticeAwaitsLoad = false
    /// 每次提交和加载完成时加一。提交后的兜底只在代号没变时生效。
    private var commitGeneration = 0
    private var launchStarted = Date()
    private var lastDragLog = Date.distantPast
    /// 窗口已最小化到 Dock。
    var onDidMiniaturize: (() -> Void)?
    /// 窗口大小要变、网页会重新排版：前后各调用一次，用来保持阅读位置。
    var onWillChangeLayout: (() -> Void)?
    var onDidChangeLayout: (() -> Void)?
    /// 切模式时先让网页在目标大小上排好版，再动窗口。窗口先到位时网页要约 0.4 秒才跟上（20261106.2011 录屏），
    /// 这段时间新露出的区域是 WebKit 自己画的底色，公开接口改不了它的颜色。
    /// 两个都接上才生效，否则窗口直接切换。
    var onSnapshotPage: ((@escaping @MainActor (NSImage?) -> Void) -> Void)?
    var onPrepareLayout: ((NSSize, @escaping @MainActor () -> Void) -> Void)?
    /// 网页很忙时不能让窗口一直不动：到时限就直接切换。
    var layoutWaitLimit: TimeInterval = 1.5
    private var layoutChange: LayoutChange?
    private var frozenPage: NSView?
    var isShowingFrozenPage: Bool { frozenPage != nil }
    /// 盖着网页的那块（旧画面加页面底色）的位置和底色，测试和诊断用。
    var frozenPageFrame: NSRect? { frozenPage?.frame }
    var frozenPageBackground: NSColor? { (frozenPage as? FrozenPageView)?.fill }
    private let webEdges: [NSLayoutConstraint]
    private var webPin: [NSLayoutConstraint] = []
    /// 只在启动时、网页加载完之前盖着，免得先露出一片空白。不是隐私遮罩，网页从不被挡住。
    private let launchCover: NSHostingView<LaunchScreen>
    /// 加载失败、窗口里没有页面时盖在网页上的“无法连接”提示。有页面时从不显示。
    private let loadProblemCover: NSHostingView<LoadProblemView>
    private let loadProblem: LoadProblemModel
    /// 提示里的“重新加载”。
    var onReloadRequest: (() -> Void)? {
        get { loadProblem.onReload }
        set { loadProblem.onReload = newValue ?? {} }
    }
    /// 正在显示的提示（测试和诊断用），没显示是 nil。
    var shownLoadProblem: LoadRecovery.Status? { loadProblemCover.isHidden ? nil : loadProblem.status }
    /// 提示收起后正在淡出的那层，淡出完就没了（测试用）。
    private weak var loadProblemFade: NSHostingView<LoadProblemView>?
    var loadProblemFadeView: NSHostingView<LoadProblemView>? { loadProblemFade }
    /// 页面底色，顶部一条和启动画面跟着它变浅或变深。
    let appearance: PageAppearance
    private let bar: NSView
    private var backgroundObservation: NSKeyValueObservation?
    private var pendingBackground: DispatchWorkItem?
    /// 启动保护：从启动画面出现到网页第一次加载完成，不采用 WebKit 报的页面底色。这段时间顶部一条、启动画面、
    /// 窗口底色和“无法连接”提示保持启动时的颜色（上次记下的页面颜色，没有就跟随系统），也不保存。
    /// 2026-11-14 冷启动复现：深色启动画面在网页提交前变浅，加载完成后才变回深色。按日志时间推算，那时报出的浅色
    /// 还不是 ChatGPT 页面的颜色；这是推断，日志没有记下颜色数值。
    /// 加载失败和启动画面到时限都不解除：那时窗口里可能还没有页面。之后哪一次加载完成都会解除。
    private var holdsPageColor = false
    /// 解除启动保护时 WebKit 报着的颜色。它在加载完成前就有了，可能还是临时颜色：先不采用，等页面颜色变化；
    /// 到 pageColorSettleLimit 还没变，再按当前颜色采用（页面本来就是这个颜色）。
    private var colorBeforeFirstLoad: NSColor?
    /// 进入和解除启动保护时加一。排着队的颜色更新只在代号没变时生效，旧回调不会把临时颜色采用或保存。
    private var pageColorGeneration = 0
    /// 解除启动保护后，加载完成前就有的颜色最多等多久。复现里真实颜色在加载完成后约 24–68 ms 报出（按日志时间推算）。
    var pageColorSettleLimit: TimeInterval = 1
    /// 启动画面结束后正在淡出的那层，淡出完就没了。
    private weak var launchFade: NSHostingView<LaunchScreen>?
    /// 正在淡出的那层（测试用）。
    var launchFadeView: NSHostingView<LaunchScreen>? { launchFade }
    /// 启动保护是否还在（测试和诊断用）。
    var isHoldingPageColor: Bool { holdsPageColor }
    /// 顶部一条和启动画面用的外观（测试用）。
    var chromeAppearance: NSAppearance? { bar.appearance }
    /// 小窗和完整窗口切换键，跟随设置。
    var modeKey = HotKeyCombo.modeStandard

    init(webView: WKWebView, toolbar: some View, diagnostics: Diagnostics, appearance: PageAppearance = PageAppearance()) {
        self.webView = webView
        self.diagnostics = diagnostics
        self.appearance = appearance
        launchCover = NSHostingView(rootView: LaunchScreen(appearance: appearance))
        let problem = LoadProblemModel()
        loadProblem = problem
        loadProblemCover = NSHostingView(rootView: LoadProblemView(model: problem, appearance: appearance))
        // 不让 SwiftUI 的尺寸变成约束：长文字挤窄后折成很多行，最小高度会把窗口撑到 858 以上（藏着也一样，1159 窗口测试）。
        // 大小只跟着网页的四条边。
        loadProblemCover.sizingOptions = []
        let window = ChatWindow(contentRect: NSRect(origin: .zero, size: Self.quickSize),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        window.title = "Classic Companion"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.hideSystemButtons()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 360)
        // 跟随当前桌面出现；可显示在全屏应用之上（需实测）
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.tabbingMode = .disallowed
        window.hidesOnDeactivate = false

        let bar = NSHostingView(rootView: toolbar)
        self.bar = bar
        // 这一条自己占住标题栏的位置，不再让出标题栏的高度。
        bar.safeAreaRegions = []
        bar.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(bar)
        container.addSubview(webView)
        // 提示在网页之上、启动画面之下：启动画面结束后才露出来。
        loadProblemCover.translatesAutoresizingMaskIntoConstraints = false
        loadProblemCover.isHidden = true
        container.addSubview(loadProblemCover)
        launchCover.translatesAutoresizingMaskIntoConstraints = false
        launchCover.isHidden = true
        container.addSubview(launchCover)
        let edges = [webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                     webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)]
        webEdges = edges
        NSLayoutConstraint.activate(edges + [
            // 顶部一条占住原来的标题栏位置，按钮在里面。
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            launchCover.topAnchor.constraint(equalTo: webView.topAnchor),
            launchCover.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            launchCover.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            launchCover.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            loadProblemCover.topAnchor.constraint(equalTo: webView.topAnchor),
            loadProblemCover.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            loadProblemCover.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            loadProblemCover.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
        ])
        window.contentView = container
        window.webView = webView

        super.init(window: window)
        window.delegate = self
        window.onCancel = { [weak self] in self?.hide(reason: "窗口 Esc（焦点不在网页）") }
        window.center()

        applyAppearance()
        // 页面换底色（ChatGPT 切换浅色、深色）时跟着变。导航刚开始时 WebKit 会短暂报出默认白色，
        // 稳定 150ms 再采用，免得每次加载都闪一下浅色。启动时另有启动保护，见 holdsPageColor。
        backgroundObservation = webView.observe(\.underPageBackgroundColor) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.pageBackgroundChanged() }
        }

        // 显示器变化后确保窗口仍在可见范围内
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        // 隐藏后回到哪个应用：⌘Tab、点 Dock 切入时不经过 show()，所以跟踪系统的激活记录。
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
                self?.previousApp = NSRunningApplication(processIdentifier: pid)
            }
        }

        // ⌘W 在原生层处理，与浏览器一致：网页无法拦截。只匹配本窗口、只匹配纯 ⌘W，其余按键原样交给网页。
        closeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let close = Self.isCloseShortcut(event), escape = Self.isPlainEscape(event)
            let pressed = HotKeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: HotKeyCombo.carbonModifiers(from: event.modifierFlags))
            let mode = MainActor.assumeIsolated { self?.modeKey == pressed }
            // Phase 0 诊断：记录到达本应用的 ⌘⇧ / ⌃⌘ 组合（只有键码与该键字符，不含输入内容），用于判断快捷键是否被其他应用占用。
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command), flags.contains(.shift) || flags.contains(.control) {
                let keyCode = event.keyCode, chars = event.charactersIgnoringModifiers ?? "", number = event.windowNumber
                MainActor.assumeIsolated {
                    let ours = self?.window?.windowNumber == number
                    self?.diagnostics.log("keys", "\(flags.contains(.control) ? "⌃⌘" : "⌘⇧") 组合到达 keyCode=\(keyCode) 字符=\(chars) 本窗口=\(ours) 匹配切换=\(mode)")
                }
            }
            if escape {
                let number = event.windowNumber
                MainActor.assumeIsolated { self?.logEscape(windowNumber: number) }
            }
            guard close || escape || mode else { return event }
            let target = event.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, window.windowNumber == target, window.attachedSheet == nil else { return false }
                if close {
                    self.hide(reason: "⌘W")
                    return true
                }
                if mode {
                    // 官方预览等弹层持有焦点时，网页会先拿到菜单快捷键；原生层处理，网页无法拦截。
                    self.diagnostics.log("window", "\(self.modeKey.label) 切换模式")
                    self.toggleMode()
                    return true
                }
                // Esc 交给网页：网页自己关闭弹层，或按设置请求隐藏窗口。
                return false
            }
            return handled ? nil : event
        }
    }

    /// Phase 0 诊断：Esc 到达时的模式；150ms 后再记一次窗口是否仍可见，判断这次 Esc 由谁处理。
    /// 输入法组词状态以网页侧 compositionstart/end 记录为准：原生 hasMarkedText 在 0219 实测中组词期间仍为 false，已移除。
    private func logEscape(windowNumber: Int) {
        guard let window, window.windowNumber == windowNumber else { return }
        diagnostics.log("keys", "Esc 到达 模式=\(mode == .quick ? "Quick" : "Full")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.diagnostics.log("keys", "Esc 后 150ms 窗口可见=\(window.isVisible)")
            }
        }
    }

    nonisolated static func isPlainEscape(_ event: NSEvent) -> Bool {
        event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function]).isEmpty
    }

    /// 按键位匹配，和录制时一致。
    nonisolated static func isModeShortcut(_ event: NSEvent, combo: HotKeyCombo) -> Bool {
        UInt32(event.keyCode) == combo.keyCode &&
            HotKeyCombo.carbonModifiers(from: event.modifierFlags) == combo.carbonModifiers
    }

    nonisolated static func isCloseShortcut(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command &&
            event.charactersIgnoringModifiers?.lowercased() == "w"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isKey: Bool { window?.isKeyWindow ?? false }

    var isShowingLaunchScreen: Bool { !launchCover.isHidden }

    var isShownAndActive: Bool {
        guard let window else { return false }
        return window.isVisible && window.isKeyWindow && NSApp.isActive && !window.isMiniaturized
    }

    /// 启动时和“总是小窗”时唤醒快捷键使用的模式。默认 Quick；Phase 0 对照测试（phase0LaunchFull）时为 Full。
    var defaultShowMode: Mode = .quick

    /// 唤醒快捷键。setting 在按下时读取，改设置不动当前窗口。
    func toggle(wake setting: WakeWindowMode) {
        isShownAndActive ? hide(reason: "唤醒快捷键")
            : show(mode: Self.hotKeyWakeMode(setting, last: mode, defaultMode: defaultShowMode))
    }

    /// 唤醒快捷键传给 show(mode:) 的模式。没有时限，判断里也没有时间。
    /// 保持上次模式：小窗照旧放到这块屏幕记住的位置；完整窗口返回 nil，和 Dock、⌘Tab 找回一样放置（同一块屏幕上留在原处），
    /// 仍经过 show()，唤醒后聚焦输入框等照旧。总是小窗：改动之前的行为。
    /// 隐藏途中还在切换的，hide() 已先做完切换，last 就是用户最后选的模式。
    nonisolated static func hotKeyWakeMode(_ setting: WakeWindowMode, last: Mode, defaultMode: Mode) -> Mode? {
        switch setting {
        case .alwaysQuick: defaultMode
        case .keepLast: last == .full ? nil : last
        }
    }

    enum RevealAction { case none, activate, restore }

    nonisolated static func revealAction(visible: Bool, miniaturized: Bool, shownAndActive: Bool) -> RevealAction {
        if !visible || miniaturized { return .restore }
        return shownAndActive ? .none : .activate
    }

    /// Dock、Finder 再次打开、⌘Tab：找回现有窗口。保持当前模式，不碰网页。可见和最小化的窗口留在原处；
    /// 隐藏窗口出现在鼠标所在屏幕，见 keepsPositionOnReveal。唤醒快捷键在“保持上次模式”下找回完整窗口用同样的放置规则。
    func reveal() {
        guard let window else { return }
        switch Self.revealAction(visible: window.isVisible, miniaturized: window.isMiniaturized, shownAndActive: isShownAndActive) {
        case .none: break
        case .restore: show(mode: nil)
        case .activate:
            diagnostics.recordShow(.activate, previousApp: nil)
            bringToFrontInActiveSpace(window)
        }
    }

    /// 已在当前 Space 的可见窗口直接激活：改样式对正在显示的窗口没有好处。
    private func bringToFrontInActiveSpace(_ window: NSWindow) {
        let bringToFront: @MainActor () -> Void = { [weak window] in
            guard let window else { return }
            // 协作式 NSApp.activate() 在实测中被系统拒绝（appActive=false），快捷键唤醒后键盘输入仍发往原应用。
            // 改用旧 API 显式请求激活；效果以 [focus] 日志为准。
            Self.forceActivate()
            window.makeKeyAndOrderFront(nil)
            // 系统拒绝激活时（例如从终端启动）至少让窗口可见
            window.orderFrontRegardless()
        }
        if let chatWindow = window as? ChatWindow, !window.isVisible || !window.isOnActiveSpace {
            chatWindow.orderIntoActiveSpace(thenActivate: bringToFront)
        } else {
            bringToFront()
        }
    }

    func show(mode newMode: Mode?) {
        guard let window else { return }
        finishLayoutChange(animated: false)
        rememberQuickPosition()
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        // 只有“隐藏 → 可见”算唤醒，这样才能和隐藏次数配对。
        let kind: Diagnostics.ShowKind = !window.isVisible ? .wake : isShownAndActive ? .modeSwitch : .activate
        diagnostics.recordShow(kind, previousApp: front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                               ? nil : front?.bundleIdentifier)

        let modeChanged = newMode != nil && newMode != mode
        // 要在 onWillShow 之前：界面从那里就开始变化。
        let layoutWillChange = modeChanged && window.isVisible
        if layoutWillChange { onWillChangeLayout?() }
        // 同样要在 onWillShow 之前：快照留下的是切换前的画面。
        let change = layoutWillChange ? beginLayoutChange() : nil
        onWillShow?(newMode ?? mode)
        let screen = Self.screenForShow(modeChanged: modeChanged, windowVisible: window.isVisible,
                                        current: window.screen, underMouse: Self.screenUnderMouse())
        // newMode 为空：reveal() 找回现有窗口，或唤醒快捷键在“保持上次模式”下找回完整窗口。
        let restoringMinimized = newMode == nil && window.isMiniaturized
        let staysInPlace = newMode == nil && Self.keepsPositionOnReveal(
            mode: mode, miniaturized: window.isMiniaturized, onTargetScreen: window.screen.map { $0 == screen } ?? false)
        let needsPlacing = !modeChanged && !staysInPlace
            && (!window.isVisible || !(window.screen.map { $0 == screen } ?? false))
        let placed = { [weak self] in
            guard let self else { return }
            if !restoringMinimized { self.clampToVisibleScreen(preferred: screen) }
            if modeChanged || needsPlacing {
                self.fullTopLeftWhenPlaced = self.mode == .full ? Self.topLeft(window.frame) : nil
            }
        }
        if let newMode, modeChanged {
            mode = newMode
            let frame = modeFrame(newMode == .quick ? Self.quickSize : fullSizes.size ?? Self.fullSize, on: screen)
            if let change {
                change.frame = frame
                change.placed = placed
                continueLayoutChange(change)
            } else {
                layoutChange = nil
                setModeFrame(frame, animate: window.isVisible)
                placed()
                if layoutWillChange { onDidChangeLayout?() }
            }
        } else {
            // 每次从隐藏状态唤醒时出现在鼠标所在屏幕
            if needsPlacing { place(window, on: screen) }
            placed()
        }

        if window.isMiniaturized { window.deminiaturize(nil) }
        bringToFrontInActiveSpace(window)
        window.makeFirstResponder(webView)
        onDidShow?(kind)
        if modeChanged, window.isVisible, layoutChange == nil { refreshInputMethodPosition() }
        logPlacement("显示后")
        logActivationState(after: 0.35)
    }

    /// 组词时切换窗口大小，候选框会留在原地（K14 实测，中文、日文相同）：通知输入法重新读取光标位置。
    /// 网页重新排版比窗口慢，排版完成后再通知几次。
    private func refreshInputMethodPosition() {
        diagnostics.log("ime", "切换模式后请求输入法重新定位 上下文=\(webView.inputContext != nil)")
        for delay in [0, 0.15, 0.4, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.webView.inputContext?.invalidateCharacterCoordinates() }
            }
        }
    }

    @available(macOS, deprecated: 14.0)
    private static func forceActivateDeprecated() { NSApp.activate(ignoringOtherApps: true) }
    static func forceActivate() { forceActivateDeprecated() }

    /// 唤醒后记录原生焦点状态：应用是否激活、窗口是否为 key、第一响应者是否在 WebView 内、前台应用。
    private func logActivationState(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                // 这段时间内又被隐藏时，下面读到的不是这次激活的结果。
                guard let self, let window = self.window, window.isVisible else { return }
                let fr = window.firstResponder
                let inWeb = (fr as? NSView).map { $0 === self.webView || $0.isDescendant(of: self.webView) } ?? false
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
                self.diagnostics.log("focus", "唤醒+\(Int(delay * 1000))ms appActive=\(NSApp.isActive) windowKey=\(window.isKeyWindow) firstResponderInWeb=\(inWeb) frontmost=\(front)")
            }
        }
    }

    func hide(reason: String) {
        guard let window, window.isVisible else { return }
        finishLayoutChange(animated: false)
        diagnostics.log("window", "隐藏：\(reason)")
        rememberQuickPosition()
        window.orderOut(nil)
        diagnostics.recordHide()
        let target = previousApp
        returnForeground()
        // 记录焦点是否回到原应用
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let target, !target.isTerminated else { return }
                // 0.4 秒内又被唤醒时前台本来就是本应用，这次量不出来，不计入成功或失败。
                guard self.window?.isVisible != true else { return }
                let ok = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
                self.diagnostics.recordFocusRestore(ok: ok)
                if !ok {
                    self.diagnostics.log("window", "隐藏后焦点未回到原应用")
                    // 普通应用留在前台又没有窗口时，⌘Tab 切不回来，交给系统选下一个应用。
                    if NSApp.isActive, NSApp.keyWindow == nil { NSApp.hide(nil) }
                }
            }
        }
    }

    /// 前台交回之前的应用；没有可交的应用时隐藏本应用，由系统选下一个。
    func returnForeground() {
        if let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        } else {
            NSApp.hide(nil)
        }
    }

    /// 跟着 WebRuntime.loadProblem 变。
    /// “可以收起”在提交时就来了，那时网页还没画出来，收起会露出空白白色（2026-11-15 对照）：
    /// 网页已提交、还没加载完成时先留着（内容停在收起前的状态），加载完成时淡出；提交后 pageRevealLimit 还没加载完成就收起。
    func showLoadProblem(_ status: LoadRecovery.Status) {
        if status == .hidden, !loadProblemCover.isHidden, awaitingFinish {
            if !noticeAwaitsLoad { diagnostics.log("nav", "无法连接提示：网页已提交，留到加载完成") }
            noticeAwaitsLoad = true
            return
        }
        noticeAwaitsLoad = false
        loadProblem.status = status
        loadProblemCover.isHidden = status == .hidden
    }

    func beginLaunchScreen() {
        launchCover.isHidden = false
        launchStarted = Date()
        launchAwaitsPage = false
        holdPageColor()
        DispatchQueue.main.asyncAfter(deadline: .now() + launchScreenLimit) { [weak self] in
            MainActor.assumeIsolated { self?.launchScreenLimitReached() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + launchScreenCap) { [weak self] in
            MainActor.assumeIsolated { self?.endLaunchScreen("超过上限") }
        }
    }

    /// 到时限：网页已经提交就照原来结束；还没提交就继续显示，等加载完成、失败、提交后兜底或上限。
    private func launchScreenLimitReached() {
        guard isShowingLaunchScreen else { return }
        guard !hasCommittedPage else { return endLaunchScreen("超过时限") }
        launchAwaitsPage = true
        diagnostics.log("launch", "启动画面到时限：网页还没提交，继续显示（等加载完成、失败、提交后 \(Int(pageRevealLimit * 1000))ms，"
                        + "最多到 \(Int(launchScreenCap)) 秒）")
    }

    /// 网页加载完、加载失败、到时限（已提交）、提交后兜底或到上限时调用。之后不再出现。
    /// 启动保护不在这里解除，见 pageDidFinishLoading()。
    func endLaunchScreen(_ outcome: String) {
        guard isShowingLaunchScreen else { return }
        diagnostics.log("launch", "启动画面结束：\(outcome)（\(Int(Date().timeIntervalSince(launchStarted) * 1000))ms）")
        launchAwaitsPage = false
        launchCover.isHidden = true
        fadeOutLaunchScreen()
    }

    /// 主框架提交时调用（AppDelegate.onMainFrameCommitted，在“提示可以收起”之前）。
    /// 提交后 pageRevealLimit 还没加载完成：到时限后还在的启动画面结束，留着的提示收起。
    func pageDidCommit() {
        hasCommittedPage = true
        awaitingFinish = true
        commitGeneration += 1
        let generation = commitGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + pageRevealLimit) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.commitGeneration == generation, self.awaitingFinish else { return }
                let waited = "提交后 \(Int(self.pageRevealLimit * 1000))ms 还没加载完成"
                if self.launchAwaitsPage { self.endLaunchScreen(waited) }
                if self.noticeAwaitsLoad {
                    self.diagnostics.log("nav", "无法连接提示：\(waited)，收起")
                    self.noticeAwaitsLoad = false
                    self.loadProblem.status = .hidden
                    self.loadProblemCover.isHidden = true
                }
            }
        }
    }

    /// 网页可能还没画出第一帧：盖一层同样的画面淡出。启动画面本身已经结束。
    /// 这层的底色和文字、图标用同一个外观，都固定在启动画面结束那一刻：淡出途中页面颜色变了也不跟着换。
    private func fadeOutLaunchScreen() {
        guard let container = launchCover.superview else { return }
        let look = launchCover.effectiveAppearance
        let fade = NSHostingView(rootView: LaunchScreen(appearance: appearance, fixedBackground: fixedFill(look)))
        fade.appearance = look
        fade.frame = launchCover.frame
        fade.autoresizingMask = [.width, .height]
        container.addSubview(fade, positioned: .above, relativeTo: launchCover)
        launchFade = fade
        fadeAway(fade)
    }

    /// 加载完成时收起留着的提示：和启动画面一样盖一层同样的提示淡出，内容、底色和外观固定在这一刻。
    private func fadeOutLoadProblem() {
        let shown = loadProblem.status
        loadProblem.status = .hidden
        loadProblemCover.isHidden = true
        guard let container = loadProblemCover.superview else { return }
        let look = loadProblemCover.effectiveAppearance
        let frozen = LoadProblemModel()
        frozen.status = shown
        let fade = NSHostingView(rootView: LoadProblemView(model: frozen, appearance: appearance, fixedBackground: fixedFill(look)))
        fade.sizingOptions = []
        fade.appearance = look
        fade.frame = loadProblemCover.frame
        fade.autoresizingMask = [.width, .height]
        container.addSubview(fade, positioned: .above, relativeTo: loadProblemCover)
        loadProblemFade = fade
        fadeAway(fade)
    }

    /// 遮挡淡出用的固定底色：记下的页面颜色；没有记下时启动画面和提示跟随系统，把系统颜色按这一刻的外观换成固定颜色。
    private func fixedFill(_ look: NSAppearance) -> NSColor? {
        var fill = appearance.background
        if fill == nil {
            look.performAsCurrentDrawingAppearance { fill = NSColor.textBackgroundColor.usingColorSpace(.sRGB) }
        }
        return fill
    }

    private func fadeAway(_ view: NSView) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            view.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { view.removeFromSuperview() }
        }
    }

    /// 进入启动保护。已经排着队的颜色更新作废：取消，并且换代号，万一已经出队也不生效。
    private func holdPageColor() {
        holdsPageColor = true
        colorBeforeFirstLoad = nil
        pageColorGeneration += 1
        pendingBackground?.cancel()
        pendingBackground = nil
        diagnostics.log("appearance", "启动保护：网页加载完成前不跟随页面底色（保持\(Self.shade(appearance.background))）")
    }

    /// 网页加载完成时调用（AppDelegate.onMainFrameLoaded，每次都调用，只有启动保护还在时起作用）。
    /// 解除时 WebKit 报着的颜色不马上采用：它可能还是加载完成前的临时颜色。页面颜色变了再按原来的规则采用；
    /// 一直不变就在 pageColorSettleLimit 后按它采用。
    func pageDidFinishLoading() {
        awaitingFinish = false
        commitGeneration += 1
        if noticeAwaitsLoad {
            noticeAwaitsLoad = false
            diagnostics.log("nav", "无法连接提示：加载完成，淡出")
            fadeOutLoadProblem()
        }
        guard holdsPageColor else { return }
        holdsPageColor = false
        pageColorGeneration += 1
        let generation = pageColorGeneration
        let current = webView.underPageBackgroundColor
        colorBeforeFirstLoad = current
        diagnostics.log("appearance", "启动保护解除：加载完成时报的是\(Self.shade(current))，等页面颜色变化再采用")
        DispatchQueue.main.asyncAfter(deadline: .now() + pageColorSettleLimit) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pageColorGeneration == generation, self.colorBeforeFirstLoad != nil else { return }
                self.colorBeforeFirstLoad = nil
                self.diagnostics.log("appearance", "加载完成后 \(Int(self.pageColorSettleLimit * 1000))ms 页面颜色没有变，按当前颜色采用")
                self.pageBackgroundChanged()
            }
        }
        pageBackgroundChanged()
    }

    private func pageBackgroundChanged() {
        if holdsPageColor {
            diagnostics.log("appearance", "启动保护中：页面底色报为\(Self.shade(webView.underPageBackgroundColor))，不采用")
            return
        }
        pendingBackground?.cancel()
        let generation = pageColorGeneration
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pageColorGeneration == generation, !self.holdsPageColor else { return }
                let color = self.webView.underPageBackgroundColor
                if let before = self.colorBeforeFirstLoad {
                    // 还是加载完成前就有的颜色：不采用，也不保存。
                    guard !PageAppearance.sameColor(color, before) else { return }
                    self.colorBeforeFirstLoad = nil
                }
                let wasDark = self.appearance.isDark
                self.appearance.update(color)
                if self.appearance.isDark != wasDark {
                    self.diagnostics.log("appearance", "页面底色：\(self.appearance.isDark == true ? "深色" : "浅色")")
                }
                self.applyAppearance()
            }
        }
        pendingBackground = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 日志里只写深浅，不写颜色值。
    private static func shade(_ color: NSColor?) -> String {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return "系统颜色" }
        guard rgb.alphaComponent > 0.5 else { return "透明" }
        return PageAppearance.isDark(rgb) ? "深色" : "浅色"
    }

    /// 只改原生控件；网页和窗口本身不设外观，ChatGPT 选“系统”时网页仍跟随 macOS。
    private func applyAppearance() {
        bar.appearance = appearance.nsAppearance
        launchCover.appearance = appearance.nsAppearance
        loadProblemCover.appearance = appearance.nsAppearance
        // 窗口底色和网页一致：切换、调整大小时新露出的地方不闪白。
        window?.backgroundColor = appearance.background ?? .windowBackgroundColor
    }

    /// 快照还没拍好、窗口还没动时再按不算数。窗口已经到位、网页还在排版时可以切回去：用户看到的已经是切换好的窗口。
    func toggleMode() {
        guard layoutChange?.windowPlaced ?? true else { return }
        show(mode: mode == .quick ? .full : .quick)
    }

    // MARK: - 布局

    /// 窗口已显示时切模式留在原屏幕。其余情况跟随鼠标：有三块屏幕时，鼠标常常不在窗口所在的那块上。
    nonisolated static func screenForShow<Screen>(modeChanged: Bool, windowVisible: Bool, current: Screen?, underMouse: Screen) -> Screen {
        modeChanged && windowVisible ? current ?? underMouse : underMouse
    }

    /// Dock、⌘Tab、再次打开找回窗口时是否留在原处。最小化的窗口交给系统放回原位，鼠标在别的屏幕也不动。
    /// 隐藏的完整窗口在同一块屏幕上留在隐藏时的位置。小窗按每块屏幕记住的位置。
    nonisolated static func keepsPositionOnReveal(mode: Mode, miniaturized: Bool, onTargetScreen: Bool) -> Bool {
        miniaturized || (mode == .full && onTargetScreen)
    }

    private static func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func place(_ window: NSWindow, on screen: NSScreen) {
        let size = window.frame.size
        window.setFrame(NSRect(origin: wakeOrigin(size: size, on: screen), size: size), display: false)
    }

    /// 小窗：这块屏幕上次的位置；没有记录、已不可见或完整窗口：水平居中、屏幕高度约 66% 处。
    private func wakeOrigin(size: NSSize, on screen: NSScreen) -> NSPoint {
        let vf = screen.visibleFrame
        let fallback = NSPoint(x: vf.midX - size.width / 2, y: vf.minY + (vf.height - size.height) * 0.66)
        guard mode == .quick else { return fallback }
        let remembered = rememberedQuickOrigin(size: size, on: screen)
        diagnostics.log("window", "小窗位置：\(remembered == nil ? "默认" : "上次")")
        return remembered ?? fallback
    }

    private func rememberedQuickOrigin(size: NSSize, on screen: NSScreen) -> NSPoint? {
        Self.displayUUID(screen)
            .flatMap { quickPlacements.placement(forScreen: $0) }?
            .origin(size: size, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    /// 记下小窗当前位置。隐藏、最小化、切到完整窗口、移到别的屏幕和退出前调用。
    func rememberQuickPosition() {
        // 切换途中窗口还是完整窗口的大小，不能当成小窗记下来。
        guard mode == .quick, layoutChange == nil, let window, window.isVisible, let screen = window.screen,
              let id = Self.displayUUID(screen) else { return }
        quickPlacements.save(QuickPlacement(frame: window.frame, screenFrame: screen.frame), forScreen: id)
    }

    private static func displayUUID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func modeFrame(_ size: NSSize, on screen: NSScreen) -> NSRect {
        guard let window else { return .zero }
        let vf = screen.visibleFrame
        let w = min(size.width, vf.width), h = min(size.height, vf.height)
        // 左上角不动，窗口只向右下放大，标题栏和红绿灯留在原处。
        let topLeft = Self.topLeft(window.frame)
        var frame = NSRect(x: topLeft.x, y: topLeft.y - h, width: w, height: h)
        if !window.isVisible || window.screen != screen {
            frame.origin = wakeOrigin(size: frame.size, on: screen)
        } else if mode == .quick, topLeft == fullTopLeftWhenPlaced,
                  let remembered = rememberedQuickOrigin(size: frame.size, on: screen) {
            // 放不下时完整窗口会把小窗推开。用户没移动过它，就回到小窗原来的位置；移动过就留在新位置。
            frame.origin = remembered
        }
        // 动画前就算好放得下的位置，否则窗口会先动到屏幕外再跳回来。
        return Self.fitted(frame, in: vf)
    }

    private func setModeFrame(_ frame: NSRect, animate: Bool) {
        resizingForMode = true
        defer { resizingForMode = false }
        window?.setFrame(frame, display: true, animate: animate)
    }

    // MARK: - 切模式：窗口先动，网页随后排好

    // 2309 起是“网页排好再动窗口”，按下后要等 0.3–1 秒（真实日志）。用户在 1442 上选了“窗口先动”（2026-11-08）：
    // 快照拍好后窗口立刻到位，网页在旧画面和页面底色下面按新大小排版，排好再拿掉。
    // 盖着的部分不露出 WebKit 自己画的那块比页面亮的底色（2011 的空白就是它）。

    private func beginLayoutChange() -> LayoutChange? {
        guard let snapshot = onSnapshotPage, onPrepareLayout != nil else { return nil }
        let change = LayoutChange()
        layoutChange = change
        snapshot { [weak self, weak change] image in
            guard let self, let change, self.layoutChange === change else { return }
            self.diagnostics.log("window", "切换模式：快照 \(Int(Date().timeIntervalSince(change.started) * 1000))ms")
            change.snapshot = image
            change.snapshotArrived = true
            self.continueLayoutChange(change)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + layoutWaitLimit) { [weak self, weak change] in
            MainActor.assumeIsolated {
                guard let self, let change, self.layoutChange === change else { return }
                self.diagnostics.log("window", "网页排版超过时限，拿掉旧画面")
                self.finishLayoutChange()
            }
        }
        return change
    }

    /// 要等快照和目标位置都到齐：快照要拍在窗口和网页变大小之前。
    private func continueLayoutChange(_ change: LayoutChange) {
        guard layoutChange === change, change.snapshotArrived, let frame = change.frame,
              let window, let prepare = onPrepareLayout else { return }
        guard let image = change.snapshot else { return finishLayoutChange() }
        let size = NSSize(width: frame.width, height: frame.height - (window.frame.height - webView.frame.height))
        freezePage(image, covering: size)
        pinWeb(to: size)
        prepare(size) { [weak self, weak change] in
            guard let self, let change, self.layoutChange === change else { return }
            self.finishLayoutChange()
        }
        guard layoutChange === change else { return }
        placeWindow(for: change, animated: true)
    }

    private func placeWindow(for change: LayoutChange, animated: Bool) {
        guard !change.windowPlaced, let window, let frame = change.frame else { return }
        change.windowPlaced = true
        diagnostics.log("window", "切换模式：窗口到位 \(Int(Date().timeIntervalSince(change.started) * 1000))ms 动画=\(animated && window.isVisible)")
        setModeFrame(frame, animate: animated && window.isVisible)
        change.placed?()
        if window.isVisible { refreshInputMethodPosition() }
    }

    /// 网页排好或到时限时调用；隐藏、再次显示和开始拖动边缘时也调用：先结束这次切换，窗口和网页都和模式一致。
    private func finishLayoutChange(animated: Bool = true) {
        guard let change = layoutChange else { return }
        layoutChange = nil
        guard change.frame != nil else { return }
        // 快照没到或失败时窗口还没动。
        placeWindow(for: change, animated: animated)
        unpinWeb()
        unfreezePage()
        diagnostics.log("window", "切换模式：网页排好 \(Int(Date().timeIntervalSince(change.started) * 1000))ms")
        onDidChangeLayout?()
    }

    /// 盖住网页的整块区域（切换前后两种大小里大的那个）：左上是旧画面，其余是页面底色（窗口底色就是页面底色）。
    private func freezePage(_ image: NSImage, covering target: NSSize) {
        guard let container = webView.superview, let window else { return }
        let old = webView.frame
        let size = NSSize(width: max(old.width, target.width), height: max(old.height, target.height))
        let view = FrozenPageView(frame: NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height))
        view.fill = window.backgroundColor
        view.image = image
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignTopLeft
        // 跟左上角走：窗口缩小时只裁掉右下，不缩放。
        view.autoresizingMask = [.maxXMargin, .minYMargin]
        view.setAccessibilityElement(false)
        // 启动画面始终在最上面。
        container.addSubview(view, positioned: .below, relativeTo: launchCover)
        frozenPage = view
    }

    private func unfreezePage() {
        frozenPage?.removeFromSuperview()
        frozenPage = nil
    }

    private func pinWeb(to size: NSSize) {
        NSLayoutConstraint.deactivate(webEdges)
        webPin = [webView.widthAnchor.constraint(equalToConstant: size.width),
                  webView.heightAnchor.constraint(equalToConstant: size.height)]
        NSLayoutConstraint.activate(webPin)
        webView.superview?.layoutSubtreeIfNeeded()
    }

    private func unpinWeb() {
        guard !webPin.isEmpty else { return }
        NSLayoutConstraint.deactivate(webPin)
        webPin = []
        NSLayoutConstraint.activate(webEdges)
        webView.superview?.layoutSubtreeIfNeeded()
    }

    private static func topLeft(_ frame: NSRect) -> NSPoint {
        NSPoint(x: frame.minX, y: frame.maxY)
    }

    /// 这条通知在屏幕数量不变时也会出现（K15，21:29 实测）。它只用于找回够不着的窗口：
    /// 用户正把窗口拖过两块屏幕时，把窗口拉回当前屏幕会让它离开鼠标。
    private func screensChanged() {
        if let window, !Self.titleBarReachable(window.frame, screens: NSScreen.screens.map(\.visibleFrame)) {
            clampToVisibleScreen(preferred: nil)
            diagnostics.log("screen", "窗口标题栏已不在任何屏幕上，已拉回")
        }
        logPlacement("屏幕变化")
        // 系统搬动窗口可能晚于这条通知，1 秒后再记一次最终结果。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.logPlacement("屏幕变化 +1s") }
        }
    }

    /// 标题栏还在某块屏幕上，用户就能自己拖动窗口，不需要程序介入。
    nonisolated static func titleBarReachable(_ frame: NSRect, screens: [NSRect]) -> Bool {
        let titleBar = NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28)
        return screens.contains { $0.intersects(titleBar) }
    }

    /// Phase 0 诊断：窗口在哪块屏幕、是否完整可见。只有屏幕名称和布尔值。
    private func logPlacement(_ event: String) {
        guard let window else { return }
        let inside = NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) }
        diagnostics.log("screen", "\(event) 屏幕数=\(NSScreen.screens.count) 所在=\(window.screen?.localizedName ?? "无") 完全可见=\(inside) 窗口显示中=\(window.isVisible)")
    }

    /// 限制窗口在可用屏幕范围内；显示器断开后可找回。
    func clampToVisibleScreen(preferred: NSScreen?) {
        guard let window else { return }
        let screen = preferred ?? window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let f = Self.fitted(window.frame, in: screen.visibleFrame)
        if f != window.frame { window.setFrame(f, display: window.isVisible) }
    }

    nonisolated static func fitted(_ frame: NSRect, in visible: NSRect) -> NSRect {
        var f = frame
        f.size.width = min(f.width, visible.width)
        f.size.height = min(f.height, visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }

    // MARK: - NSWindowDelegate

    /// Phase 0 诊断（K15）：拖动时鼠标相对窗口左上角的距离。距离变化说明窗口真的离开了鼠标。
    func windowDidMove(_ notification: Notification) {
        guard let window, NSEvent.pressedMouseButtons != 0, Date().timeIntervalSince(lastDragLog) > 0.2 else { return }
        lastDragLog = Date()
        let mouse = NSEvent.mouseLocation, frame = window.frame
        diagnostics.log("drag", "鼠标相对窗口左上 x=\(Int(mouse.x - frame.minX)) y=\(Int(frame.maxY - mouse.y)) 所在=\(window.screen?.localizedName ?? "无")")
    }

    /// 切模式的缩放动画也会走这里；拖动中按 ⌃⌘F 也会改变模式。所以只认从小窗开始的手动拖动。
    func windowWillStartLiveResize(_ notification: Notification) {
        resizingByHand = !resizingForMode
        if resizingByHand { finishLayoutChange(animated: false) }
        dragStartedInQuick = mode == .quick && resizingByHand
        if resizingByHand { onWillChangeLayout?() }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        dragStartedInQuick = false
        if resizingByHand {
            if mode == .full, let window { fullSizes.remember(window.frame.size) }
            onDidChangeLayout?()
        }
        resizingByHand = false
    }

    /// ⌘M 不经过 hide()：快捷键唤醒时要用到这里记下的位置。
    func windowWillMiniaturize(_ notification: Notification) {
        rememberQuickPosition()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        onDidMiniaturize?()
    }

    func windowDidResize(_ notification: Notification) {
        if window?.inLiveResize == true { enterFullIfDraggedWide() }
    }

    /// 拖到 900 当场切换。窗口保持拖到的大小；小窗记下的位置不变，所以不走 show()。
    /// 反方向不自动：同一次拖动退回 900 以下、或完整模式缩小后，都仍是完整模式。
    func enterFullIfDraggedWide() {
        guard dragStartedInQuick, mode == .quick, let window, window.frame.width >= Self.fullModeDragWidth else { return }
        diagnostics.log("window", "拉大小窗，切到完整模式")
        diagnostics.recordShow(.modeSwitch, previousApp: nil)
        onWillShow?(.full)
        mode = .full
        refreshInputMethodPosition()
    }

    /// 关闭窗口 = 隐藏，不退出应用、不销毁 WebView
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide(reason: "关闭按钮")
        return false
    }
}

/// 一次进行中的模式切换：窗口还没动，网页在旧画面下面按目标大小排版。
@MainActor private final class LayoutChange {
    let started = Date()
    var frame: NSRect?
    var placed: (() -> Void)?
    var snapshot: NSImage?
    var snapshotArrived = false
    /// 窗口已经变到目标大小（快照到了就立刻变）。
    var windowPlaced = false
}

/// 切换时盖在网页上的旧画面，图片以外的部分是页面底色。只是一张图，点击穿过去。
private final class FrozenPageView: NSImageView {
    var fill: NSColor = .windowBackgroundColor

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}
