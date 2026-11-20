import AppKit
import SwiftUI
import WebKit
import CompanionCore

/// 用 NSPanel 只为了 orderIntoActiveSpace；其余行为和普通窗口一样。
final class ChatWindow: NSPanel {
    /// 由控制器设置：非网页焦点时的 Esc 处理（网页焦点下的 Esc 由适配脚本判断）
    var onCancel: (() -> Void)?

    /// 网页获得焦点时，Esc 是否隐藏窗口由适配脚本判断（可识别 IME 组合与网页弹层），这里不处理。
    /// 指向窗口里当前显示的网页视图（不是放网页的容器），换网页视图时由控制器跟着换，见 display(_:webView:)、replaceWebView。
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

/// 单窗口，窗口里一次显示一个 WebView（切换标签页时换成那一页的，见 display(_:webView:beforeCatchUp:laidOut:)；
/// 不显示的标签页的网页视图藏在容器里，见 hiddenWebViews）。Quick / Full 通过调整同一窗口尺寸切换，不迁移 WebView。
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
    /// 窗口里当前显示的网页视图。只经 display(_:webView:)（切换标签页）和 replaceWebView 换。
    private(set) var webView: WKWebView
    /// 网页在窗口里占的位置（顶部一条下面的整块区域）。显示着的网页视图放在里面铺满；
    /// 窗口里的约束、启动画面、提示、旧画面和切换时的固定大小都对着它，不直接对着网页视图。
    /// 切换标签页时换下去的网页视图也留在里面，藏着、固定在离开时的大小（见 display(_:webView:)）。
    private let webContainer: NSView
    /// 显示着的网页视图铺满 webContainer 的四条约束（换下去时要停掉它们）。
    private var webFill: [NSLayoutConstraint]
    /// 藏在 webContainer 里的网页视图（切换标签页时换下去的；在后台打开的标签页加载前放进来的，见 addHiddenWebView(_:)）：
    /// 把它固定在离开时（放进来时）的位置、大小的约束，和它那时排好版的大小、缩放。
    /// 再显示时、关闭标签页时（removeHiddenWebView(_:)）拿掉。容器持有这些网页视图，直到它们再显示或被拿出来。
    private var hiddenWebViews: [ObjectIdentifier: HiddenWebView] = [:]
    private let diagnostics: Diagnostics
    private var previousApp: NSRunningApplication?
    private var screenObserver: Any?
    private var activationObserver: Any?
    private var closeKeyMonitor: Any?
    private var historyMouseMonitor: Any?

    /// 后退、前进的目标页面（⌘[ ⌘] 和鼠标侧键用）。每次按键或按下侧键时调用一次，之后只对返回的页面操作；
    /// 以后有标签页时返回这一刻选中的那一页。见 HistoryNavigation。
    var historyPage: (() -> (any HistoryPage)?)?

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
    /// 窗口里显示着的页面加载到哪一步了（提交、加载完成、“无法连接”提示的状态和留着的提示、启动保护的颜色、
    /// 第一次加载的遮挡），见 PageLoadState。
    /// 规则都在这个类里。事件带着它属于的页面进来（pageDidCommit(_:)、pageDidFinishLoading(_:reportedColor:)、
    /// showLoadProblem(_:for:)、endLaunchScreen(_:for:)）：先改那个页面自己的状态，只有它就是这里的 page 时才动窗口
    /// （提示那层、淡出、启动画面、颜色、写窗口的日志）。不带页面的旧入口就是对 page 调用。
    /// 已经关闭的页面（pageClosed(_:)）的事件和排着的回调什么都不做。
    /// 换显示的页面只经 display(_:webView:)（切换标签页，连同它的网页视图一起换，并把它的状态投到窗口上）。
    private(set) var page: PageLoadState
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
    /// 网页很忙时不能让窗口一直不动：到时限就直接切换。切换标签页后的补排版（catchUp）也最多等这么久。
    var layoutWaitLimit: TimeInterval = 1.5
    private var layoutChange: LayoutChange?
    /// 进行中的补排版（切换标签页时换上来的网页视图离开时的大小或缩放和现在不同，见 display(_:webView:beforeCatchUp:laidOut:)）。
    private var catchUp: CatchUp?
    /// 有一次补排版在进行（测试和诊断用）。
    var isCatchingUp: Bool { catchUp != nil }
    /// 补排版时盖着网页的那块（测试用），没在补排版时是 nil。
    var catchUpCoverView: NSView? { catchUp?.cover }
    /// 那块的底色（测试用）。
    var catchUpCoverBackground: NSColor? { catchUp?.cover.fill }
    private var frozenPage: NSView?
    var isShowingFrozenPage: Bool { frozenPage != nil }
    /// 盖着网页的那块（旧画面加页面底色）的位置和底色，测试和诊断用。
    var frozenPageFrame: NSRect? { frozenPage?.frame }
    var frozenPageBackground: NSColor? { (frozenPage as? FrozenPageView)?.fill }
    private let webEdges: [NSLayoutConstraint]
    private var webPin: [NSLayoutConstraint] = []
    /// 只在页面第一次加载完之前盖着（启动时的启动画面、以后新标签页的遮挡），免得先露出一片空白。不是隐私遮罩，网页从不被挡住。
    /// 两种遮挡用这同一层，只换样子（LaunchScreen.kind）。盖不盖、什么样子只照显示着的页面的遮挡状态
    /// （page.isCovered、page.coverKind）改（applyCover(_:)），别处不直接改。
    private let launchCover: NSHostingView<LaunchScreen>
    /// 加载失败、窗口里没有页面时盖在网页上的“无法连接”提示。有页面时从不显示。
    /// 这一层和它的内容（loadProblem）都只照显示着的页面的 notice 改（applyNotice(_:)），别处不直接改。
    private let loadProblemCover: NSHostingView<LoadProblemView>
    private let loadProblem: LoadProblemModel
    /// 提示里的“重新加载”。
    var onReloadRequest: (() -> Void)? {
        get { loadProblem.onReload }
        set { loadProblem.onReload = newValue ?? {} }
    }
    /// 正在显示的提示（测试和诊断用），没显示是 nil。
    var shownLoadProblem: LoadRecovery.Status? { page.notice == .hidden ? nil : page.notice }
    /// 窗口里的提示（3.11：到上限、第一次有多个标签页），属于窗口、不属于哪个标签页。规则和位置见 TabHintPresenter。
    /// 它的视图加在窗口内容的最上层（网页区域上方正中）。
    let hints: TabHintPresenter
    /// 提示收起后正在淡出的那层，淡出完就没了（测试用）。
    private weak var loadProblemFade: NSHostingView<LoadProblemView>?
    var loadProblemFadeView: NSHostingView<LoadProblemView>? { loadProblemFade }
    /// 页面底色，顶部一条和启动画面跟着它变浅或变深。
    let appearance: PageAppearance
    private let bar: NSView
    private var backgroundObservation: NSKeyValueObservation?
    private var pendingBackground: DispatchWorkItem?
    /// 进入和解除启动保护、换网页视图、换显示的页面时加一。排着队的颜色更新只在代号没变时生效，旧回调不会把临时颜色采用或保存。
    private var pageColorGeneration = 0
    /// 解除启动保护后，加载完成前就有的颜色最多等多久。复现里真实颜色在加载完成后约 24–68 ms 报出（按日志时间推算）。
    var pageColorSettleLimit: TimeInterval = 1
    /// 启动画面结束后正在淡出的那层，淡出完就没了。
    private weak var launchFade: NSHostingView<LaunchScreen>?
    /// 正在淡出的那层（测试用）。
    var launchFadeView: NSHostingView<LaunchScreen>? { launchFade }
    /// 启动保护是否还在（测试和诊断用）。
    var isHoldingPageColor: Bool { page.holdsPageColor }
    /// 顶部一条和启动画面用的外观（测试用）。
    var chromeAppearance: NSAppearance? { bar.appearance }
    /// 小窗和完整窗口切换键，跟随设置。
    var modeKey = HotKeyCombo.modeStandard
    /// 唤醒键，跟随设置（AppDelegate）。只用来让标签页的键让给它（userHotKeyTakes(_:)）：它是全局快捷键，注册着时按键
    /// 先被系统拿走、到不了这里；注册失败、录制时暂停注册的时候才会到。nil：没有交进来（测试）。
    var wakeKey: HotKeyCombo?
    /// 标签页的键（含 ⌘W，见 TabKeys）交给谁：ChatTabs.handleKey(_:_:)，ChatTabs 建好时接上。返回 true 表示处理了，按键吃掉。
    /// 没接上（只建窗口的测试）时这些键都照原来交给菜单和网页。
    var onTabKey: ((TabKeys.Match, TabKeys.Context) -> Bool)?
    /// 有没有应用级的模态框（提示框等 runModal）。就是 NSApp.modalWindow；只有测试换它。
    var isAppModal: @MainActor () -> Bool = { NSApplication.shared.modalWindow != nil }

    init(webView: WKWebView, toolbar: some View, diagnostics: Diagnostics, appearance: PageAppearance = PageAppearance(),
         page: PageLoadState = PageLoadState()) {
        self.webView = webView
        self.diagnostics = diagnostics
        self.appearance = appearance
        self.page = page
        // 样子和盖不盖都从页面的遮挡状态开始（新页面没有遮挡、样子是启动画面，和这里原来的初值一样）。
        launchCover = NSHostingView(rootView: LaunchScreen(appearance: appearance, kind: page.coverKind))
        let problem = LoadProblemModel()
        // 提示从页面的状态开始（默认 .hidden，和这里原来的初值一样），之后只经 applyNotice(_:) 改。
        problem.status = page.notice
        loadProblem = problem
        loadProblemCover = NSHostingView(rootView: LoadProblemView(model: problem, appearance: appearance))
        // 不让 SwiftUI 的尺寸变成约束：长文字挤窄后折成很多行，最小高度会把窗口撑到 858 以上（藏着也一样，1159 窗口测试）。
        // 大小只跟着网页所在位置（webContainer）的四条边。
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
        hints = TabHintPresenter(windowShowsContent: { [weak window] in
            guard let window else { return false }
            return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }, log: { [diagnostics] in diagnostics.log("hint", $0) })

        let bar = NSHostingView(rootView: toolbar)
        self.bar = bar
        // 这一条自己占住标题栏的位置，不再让出标题栏的高度。
        bar.safeAreaRegions = []
        bar.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        let webContainer = NSView()
        self.webContainer = webContainer
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(webView)
        let container = NSView()
        container.addSubview(bar)
        container.addSubview(webContainer)
        // 提示在网页之上、启动画面之下：启动画面结束后才露出来。
        loadProblemCover.translatesAutoresizingMaskIntoConstraints = false
        loadProblemCover.isHidden = page.notice == .hidden
        container.addSubview(loadProblemCover)
        launchCover.translatesAutoresizingMaskIntoConstraints = false
        // 启动画面从页面的遮挡状态开始（新页面没有遮挡，和这里原来的初值一样），之后只经 applyCover(_:) 改。
        launchCover.isHidden = !page.isCovered
        container.addSubview(launchCover)
        // 提示在所有遮挡之上（最后加；之后加的淡出层、补排版的遮挡都放在指定的层的旁边，不会盖到它上面）。
        let hint = hints.host
        container.addSubview(hint)
        let edges = [webContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                     webContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor)]
        webEdges = edges
        let fill = Self.fill(webView, in: webContainer)
        webFill = fill
        NSLayoutConstraint.activate(edges + [
            // 顶部一条占住原来的标题栏位置，按钮在里面。
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webContainer.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        ] + fill + [
            launchCover.topAnchor.constraint(equalTo: webContainer.topAnchor),
            launchCover.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            launchCover.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            launchCover.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            loadProblemCover.topAnchor.constraint(equalTo: webContainer.topAnchor),
            loadProblemCover.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            loadProblemCover.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            loadProblemCover.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            hint.topAnchor.constraint(equalTo: webContainer.topAnchor, constant: 10),
            hint.centerXAnchor.constraint(equalTo: webContainer.centerXAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: webContainer.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: webContainer.trailingAnchor, constant: -12),
        ])
        window.contentView = container
        window.webView = webView

        super.init(window: window)
        window.delegate = self
        window.onCancel = { [weak self] in self?.hide(reason: "窗口 Esc（焦点不在网页）") }
        window.center()

        applyAppearance()
        observePageBackground(of: webView)

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

        // ⌘W、标签页的键、切换键在原生层处理，与浏览器一致：网页无法拦截。只在本窗口里处理，其余按键原样交给网页。
        // 规则在 handleKeyDown(_:)；这里只取出按键的事实交过去。
        closeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let press = KeyPress(event)
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(press) ?? false }
            return handled ? nil : event
        }

        // 鼠标侧键在原生层处理：按下、拖动、松开都不交给 WebKit 和网页，按一下只走一次（见 HistoryNavigation.mouseAction）。
        historyMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseDragged, .otherMouseUp]) { [weak self] event in
            let type = event.type, button = event.buttonNumber, number = event.windowNumber
            let consumed = MainActor.assumeIsolated {
                self?.handleHistoryMouse(type: type, button: button, windowNumber: number) ?? false
            }
            return consumed ? nil : event
        }
    }

    // MARK: - 后退、前进（⌘[ ⌘]、鼠标侧键）

    /// 按键对应的后退、前进方向（纯 ⌘[ / ⌘]）。用户设的切换键和它相同时返回 nil：用户的设置优先，按键只当切换键
    /// （唤醒键是全局快捷键，系统先拿走，按键到不了这里）。
    func historyShortcut(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> HistoryDirection? {
        let pressed = HotKeyCombo(keyCode: UInt32(keyCode), carbonModifiers: HotKeyCombo.carbonModifiers(from: flags))
        guard pressed != modeKey else { return nil }
        return HistoryNavigation.direction(characters: characters, flags: flags)
    }

    /// ⌘[ ⌘]。返回 true 表示由这里处理，按键不再交给输入法和网页（规则见 HistoryNavigation.keyAction）：
    /// 本窗口里的按键总是吃掉，能往这个方向走时走一次；走不了（菜单项也是灰的）、按住不放的重复按键时什么都不做。
    /// 别的窗口里的按键原样放过。重复按键不解析目标页面。
    func handleHistoryKey(_ direction: HistoryDirection, isRepeat: Bool, windowNumber: Int) -> Bool {
        let inChatWindow = window.map { $0.windowNumber == windowNumber && $0.attachedSheet == nil } ?? false
        let page = inChatWindow && !isRepeat ? historyPage?() : nil
        let source = HistoryNavigation.shortcutName(direction)
        switch HistoryNavigation.keyAction(direction, inChatWindow: inChatWindow, isRepeat: isRepeat,
                                           canGo: page?.canGo(direction) ?? false) {
        case .pass:
            return false
        case .swallow:
            if !isRepeat { diagnostics.log("nav", "\(direction.logName)（\(source)）：没有可去的页面，按键不交给网页") }
            return true
        case .navigate(let direction):
            page?.go(direction, source: source)
            return true
        }
    }

    /// 鼠标侧键。返回 true 表示吃掉这个事件（不交给 WebKit 和网页）。只管本窗口里的事件，登录弹窗等别的窗口原样放过。
    /// 没有目标（登录弹窗等别的窗口是 key 窗口）或没有可去的页面时也吃掉，什么都不做。
    func handleHistoryMouse(type: NSEvent.EventType, button: Int, windowNumber: Int) -> Bool {
        let action = HistoryNavigation.mouseAction(type: type, button: button)
        guard action != .pass, let window, window.windowNumber == windowNumber, window.attachedSheet == nil else { return false }
        if case .navigate(let direction) = action, let page = historyPage?() {
            page.go(direction, source: "鼠标侧键")
        }
        return true
    }

    /// 本应用收到的一次按下（按键监视调用；测试直接调用）。返回 true：由这里处理，按键吃掉，不再交给菜单、输入法和网页。
    /// 按这个顺序：
    /// 1. 诊断，和原来一样，不管是哪个窗口、处理不处理都先写：Phase 0 的“⌘⇧ / ⌃⌘ 组合到达”那一行；Esc 到达那一行。
    /// 2. 标签页的键（KeyPress.tabKey：⌘T ⇧⌘T ⌘W ⇧⌘W ⌃Tab ⌃⇧Tab ⇧⌘] ⇧⌘[ ⌘1–⌘4 ⌘9，数字按键位、含小键盘）：连同这一刻的情形交给 onTabKey
    ///    （ChatTabs.handleKey(_:_:)，做什么由 TabKeys.keyAction 定）。情形：按键是不是本窗口的、窗口上有没有表单
    ///    （和原来 ⌘W 的条件一样）、有没有应用级模态框、这个组合是不是用户自己的切换键或唤醒键、是不是重复按键。
    ///    它说处理了就吃掉。放在切换键前面：⌘W 原来就先于切换键；别的标签页的键和用户的键相同时 keyAction 放过，
    ///    下一步照常当切换键。
    /// 3. 本窗口（没有表单）里的切换键：切换模式，吃掉（和原来一样）。
    /// 4. ⌘[ ⌘]（不是用户的切换键时）：交给 handleHistoryKey，本窗口里总是吃掉。
    /// 5. 别的（Esc 等）：交给网页。Esc 由网页自己关闭弹层，或按设置请求隐藏窗口。
    /// 输入法：按键先到这里、再到输入法。组词时（有未确认的文字）按标签页的键照样处理、吃掉，未确认的文字留在原来的那一页
    /// （和原来组词时按 ⌘W 隐藏窗口一样；原生的 hasMarkedText 组词时仍是 false，见 logEscape，这里不看它）。
    func handleKeyDown(_ press: KeyPress) -> Bool {
        let mode = modeKey == press.combo
        // Phase 0 诊断：记录到达本应用的 ⌘⇧ / ⌃⌘ 组合（只有键码与该键字符，不含输入内容），用于判断快捷键是否被其他应用占用。
        let flags = press.flags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), flags.contains(.shift) || flags.contains(.control) {
            let ours = window?.windowNumber == press.windowNumber
            diagnostics.log("keys", "\(flags.contains(.control) ? "⌃⌘" : "⌘⇧") 组合到达 keyCode=\(press.keyCode) 字符=\(press.characters ?? "") 本窗口=\(ours) 匹配切换=\(mode)")
        }
        if press.isPlainEscape { logEscape(windowNumber: press.windowNumber) }
        let inChatWindow = window.map { $0.windowNumber == press.windowNumber && $0.attachedSheet == nil } ?? false
        if let key = press.tabKey, let onTabKey {
            let context = TabKeys.Context(inChatWindow: inChatWindow, appModal: isAppModal(),
                                          takenByUserHotKey: userHotKeyTakes(press), isRepeat: press.isRepeat)
            if onTabKey(key, context) { return true }
        }
        if mode, inChatWindow {
            // 官方预览等弹层持有焦点时，网页会先拿到菜单快捷键；原生层处理，网页无法拦截。
            diagnostics.log("window", "\(modeKey.label) 切换模式")
            toggleMode()
            return true
        }
        // ⌘[ ⌘] 和 ⌘W、切换键一样在原生层处理：输入框有焦点时网页也拦不住；本窗口里总是吃掉，走不了时什么都不做。
        // 用户设的切换键和它相同时只当切换键（historyShortcut 返回 nil）。
        if let history = historyShortcut(keyCode: press.keyCode, characters: press.characters, flags: press.flags) {
            return handleHistoryKey(history, isRepeat: press.isRepeat, windowNumber: press.windowNumber)
        }
        return false
    }

    /// 这次按下的组合（按键位和修饰键）就是用户自己设的切换键或唤醒键：标签页的键让给它（TabKeys.keyAction 的第 2 条）。
    func userHotKeyTakes(_ press: KeyPress) -> Bool {
        press.combo == modeKey || press.combo == wakeKey
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

    /// 下面三个只是对一个按键事件问 KeyPress（按键监视用的同一套认法），留给测试。
    nonisolated static func isPlainEscape(_ event: NSEvent) -> Bool {
        KeyPress(event).isPlainEscape
    }

    /// 按键位匹配，和录制时一致。
    nonisolated static func isModeShortcut(_ event: NSEvent, combo: HotKeyCombo) -> Bool {
        KeyPress(event).combo == combo
    }

    /// 纯 ⌘W（大写锁定不算）。
    nonisolated static func isCloseShortcut(_ event: NSEvent) -> Bool {
        KeyPress(event).tabKey?.command == .closeTab
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isKey: Bool { window?.isKeyWindow ?? false }

    /// 窗口盖着第一次加载的遮挡（启动画面或新标签页的遮挡，哪一种见 shownCoverKind）。
    /// 不是“启动画面还在”（新标签页的入口看的是 ChatTabs.isLaunchScreenUp）。
    var isShowingLaunchScreen: Bool { !launchCover.isHidden }

    /// 窗口盖着的遮挡是哪一种的样子，没盖着是 nil（测试和诊断用）。
    var shownCoverKind: PageLoadState.CoverKind? { launchCover.isHidden ? nil : launchCover.rootView.kind }

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
        finishCatchUp("显示窗口或切模式")
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
        hints.windowMayBeOnScreen()
        if modeChanged, window.isVisible, layoutChange == nil { refreshInputMethodPosition() }
        logPlacement("显示后")
        logActivationState(after: 0.35)
    }

    /// 组词时切换窗口大小，候选框会留在原地（K14 实测，中文、日文相同）：通知输入法重新读取光标位置。
    /// 网页重新排版比窗口慢，排版完成后再通知几次。
    /// 每次到点都取那时显示的网页视图：候选框跟的是屏幕上那一页的光标；中途换过网页视图时，旧网页已经不在窗口里、
    /// 焦点也交走了，通知它没有用；通知新网页只是让输入法多读一次它的光标位置。
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
    /// “在 WebView 内”按到点时显示的网页视图算：要回答的是焦点在不在用户看到的那一页里；中途换过网页视图时焦点已跟着交过去。
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
        finishCatchUp("隐藏窗口")
        diagnostics.log("window", "隐藏：\(reason)")
        rememberQuickPosition()
        window.orderOut(nil)
        hints.windowHidden()
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

    /// 跟着 WebRuntime.loadProblem 变（显示着的页面）。
    func showLoadProblem(_ status: LoadRecovery.Status) {
        showLoadProblem(status, for: page)
    }

    /// 页面 p 的“无法连接”状态变了。
    /// “可以收起”在提交时就来了，那时网页还没画出来，收起会露出空白白色（2026-11-15 对照）：
    /// 网页已提交、还没加载完成时先留着（内容停在收起前的状态），加载完成时淡出；提交后 pageRevealLimit 还没加载完成就收起。
    /// p 的状态总是照这条规则改；日志和窗口的提示只在 p 是显示着的页面时动。不显示的页面的提示状态变了，窗口上什么都不变。
    /// p 已经关闭：什么都不做（带页的入口都这样，见 pageClosed(_:)）。
    func showLoadProblem(_ status: LoadRecovery.Status, for p: PageLoadState) {
        guard !p.isClosed else { return }
        if status == .hidden, p.notice != .hidden, p.awaitingFinish {
            if p === page, !p.noticeAwaitsLoad { diagnostics.log("nav", "无法连接提示：网页已提交，留到加载完成") }
            p.noticeAwaitsLoad = true
            return
        }
        p.noticeAwaitsLoad = false
        p.notice = status
        if p === page { applyNotice(p) }
    }

    /// 把页面 p 的提示状态投到窗口的提示上：先改提示内容，再改那一层显不显示（和原来各处的顺序一样）。
    /// 只对显示着的页面调用（调用的地方先判断 p === page），每次改了它的 notice 之后、换上它显示时（display(_:webView:)）都调用；
    /// 只写这两样，不记日志、不碰淡出那层和别的状态。
    private func applyNotice(_ p: PageLoadState) {
        loadProblem.status = p.notice
        loadProblemCover.isHidden = p.notice == .hidden
    }

    // MARK: - 第一次加载的遮挡（启动画面、新标签页的遮挡）
    //
    // 遮挡是每个页面自己的（PageLoadState 的 isCovered、coverKind、coverAwaitsCommit、coverGeneration、coverStarted），
    // 两种遮挡（启动画面、新标签页的遮挡）只是样子不同，规则只有这一套：
    // 开始（beginCover(for:kind:)）、到时限（coverLimitReached(for:)）、结束（endLaunchScreen(_:for:)：加载完成、加载失败、
    // 到时限时已提交、到时限后提交兜底、到上限）。时限和上限两种都用 launchScreenLimit、launchScreenCap、pageRevealLimit。
    // 页面显不显示都照这套规则改它自己的遮挡状态，时限和上限到点也照常；
    // 窗口只在页面显示着时跟着动：遮挡那层和它的样子（applyCover(_:)）、淡出、启动保护的窗口部分、窗口的日志（不带标签，
    // 两种遮挡写的行一样）。不显示的页面的遮挡变了，窗口上什么都不变；只在它的遮挡结束时写一行带它的标签的日志
    // （见 endLaunchScreen(_:for:)）。它再显示时，窗口照它那时的状态显示，计时还是它自己开始时排下的
    // （切换的入口 display(_:webView:) 投上去，不重新开始）。
    // 关闭的页面（pageClosed(_:)）不开始遮挡，它的事件和排着的时限、上限都不再改它的遮挡，也不动窗口。
    // 遮挡的计时只弱引用页面：页面释放了，它的遮挡和计时一起作废；窗口显示着的页面由窗口持有，不会在显示时释放。

    /// 启动时（AppDelegate）：显示着的页面开始遮挡（启动画面），窗口盖上启动画面。
    func beginLaunchScreen() {
        beginCover(for: page, kind: .launch)
    }

    /// 新标签页：页面 p 开始第一次加载的遮挡，样子是新标签页的（页面底色加小进度圈，没有图标和应用名）。
    /// 规则、时限、上限和启动画面完全相同（beginCover(for:kind:)）。
    /// 用法（ChatTabs.newTab()、reopenClosedTab()、openLink(_:from:_:)）：建好标签页、还没显示时对它的页面调用，再开始加载；
    /// 要显示它时切换的入口（ChatTabs.select(_:)）把它的遮挡投到窗口上（⌘ 点击在后台打开的可能一直不显示，遮挡只在它自己的状态里结束）。
    /// p 不显示时窗口一点不变（遮挡那层和样子、启动保护的窗口部分、日志），p 的启动保护和计时照常开始；
    /// p 显示着时和启动画面一样马上盖上，样子是新标签页的。p 已经关闭时什么都不做。
    /// 应用里调用这几个入口的是 ⌘T、⇧⌘T（3.10，ChatTabs.handleKey(_:_:)）、菜单（3.11，TabMenus）和 ⌘ 点击聊天链接（3.12）。
    func beginNewTabCover(for p: PageLoadState) {
        beginCover(for: p, kind: .newTab)
    }

    /// 页面 p 开始第一次加载的遮挡（kind 那种样子）：p 的遮挡状态重新开始（代号加一、记下样子和开始的时刻、不在等提交），
    /// p 进入启动保护，排下这一次的时限和上限。p 显示着时窗口盖上遮挡（applyCover(_:)，那一种的样子）。
    /// 时限和上限属于 p 的这一次遮挡：到点时 p 已经释放、或 p 之后又开始过一次（p.coverGeneration 变了），都不做事；
    /// 到点时不去看显示着的是哪个页面（是不是显示着只决定窗口动不动，见 coverLimitReached(for:)、endLaunchScreen(_:for:)）。
    /// p 已经关闭时什么都不做。
    private func beginCover(for p: PageLoadState, kind: PageLoadState.CoverKind) {
        guard !p.isClosed else { return }
        p.coverGeneration += 1
        let generation = p.coverGeneration
        p.isCovered = true
        p.coverKind = kind
        if p === page { applyCover(p) }
        p.coverStarted = Date()
        p.coverAwaitsCommit = false
        holdPageColor(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + launchScreenLimit) { [weak self, weak p] in
            MainActor.assumeIsolated {
                guard let self, let p, p.coverGeneration == generation else { return }
                self.coverLimitReached(for: p)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + launchScreenCap) { [weak self, weak p] in
            MainActor.assumeIsolated {
                guard let self, let p, p.coverGeneration == generation else { return }
                self.endLaunchScreen("超过上限", for: p)
            }
        }
    }

    /// 页面 p 的遮挡还盖着、p 没有关闭。结束遮挡和到时限后继续盖着都先看它：没有遮挡的页面（没开始过、已经结束）
    /// 和关闭的页面的事件、回调不改任何遮挡。看的只是 p 自己：别的页面的遮挡不会因为 p 的事件或计时而变。
    private func isCovering(_ p: PageLoadState) -> Bool {
        p.isCovered && !p.isClosed
    }

    /// 页面 p 的启动画面（启动时的那种遮挡）还盖着、p 没有关闭。到时限后还在等提交也算；新标签页的遮挡不算。
    /// “启动画面还在时不能新增标签页”看的就是它，见 ChatTabs.isLaunchScreenUp。
    func coversWithLaunchScreen(_ p: PageLoadState) -> Bool {
        isCovering(p) && p.coverKind == .launch
    }

    /// 到时限：p 已经提交就照原来结束；还没提交就继续盖着，等加载完成、失败、提交后兜底或上限。
    /// 继续盖着这件事记在 p 自己的状态里（p.coverAwaitsCommit）；日志只在 p 显示着时写。
    private func coverLimitReached(for p: PageLoadState) {
        guard isCovering(p) else { return }
        guard !p.hasCommittedPage else { return endLaunchScreen("超过时限", for: p) }
        p.coverAwaitsCommit = true
        guard p === page else { return }
        diagnostics.log("launch", "启动画面到时限：网页还没提交，继续显示（等加载完成、失败、提交后 \(Int(pageRevealLimit * 1000))ms，"
                        + "最多到 \(Int(launchScreenCap)) 秒）")
    }

    /// 显示着的页面加载完、加载失败时调用（测试用；应用里由 ChatTabs.wire(_:) 接到带页的 endLaunchScreen(_:for:)）。
    func endLaunchScreen(_ outcome: String) {
        endLaunchScreen(outcome, for: page)
    }

    /// 页面 p 加载完、加载失败、到时限（已提交）、提交后兜底或到上限时调用。p 的这一次遮挡结束，之后不再出现。
    /// 只在 p 的遮挡还盖着、p 没有关闭时起作用；p 没有遮挡时什么都不做。p 自己的遮挡状态显不显示都照样结束。
    /// p 显示着：窗口写日志（两种遮挡都是原来那一行，不带标签）、撤掉遮挡、淡出。
    /// p 不显示：窗口不动，只写一行带 p 的标签的日志（哪一种、原因和耗时，没有地址）；p 没有标签（只在测试里单独建）时不写，
    /// 分不出是哪一页的行不写。
    /// 启动保护不在这里解除，见 pageDidFinishLoading(_:reportedColor:)。
    func endLaunchScreen(_ outcome: String, for p: PageLoadState) {
        guard isCovering(p) else { return }
        let elapsed = Int(Date().timeIntervalSince(p.coverStarted) * 1000)
        if p === page {
            diagnostics.log("launch", "启动画面结束：\(outcome)（\(elapsed)ms）")
        } else if let tag = p.logTag {
            let kind = p.coverKind == .launch ? "启动时" : "新标签页"
            TabLog(diagnostics: diagnostics, tab: tag)("launch", "不显示的页面的遮挡结束（\(kind)）：\(outcome)（\(elapsed)ms）")
        }
        p.coverAwaitsCommit = false
        p.isCovered = false
        guard p === page else { return }
        applyCover(p)
        fadeOutLaunchScreen()
    }

    /// 把页面 p 的遮挡状态投到窗口的遮挡那层上：先换成它那一种的样子（和那层现在的不同时才换），再盖着就显示、没有就藏起。
    /// 只对显示着的页面调用（调用的地方先判断 p === page），每次改了它的 isCovered 之后、换上它显示时（display(_:webView:)）都调用；
    /// 只写这两样，不记日志、不碰淡出那层和别的状态。
    private func applyCover(_ p: PageLoadState) {
        if launchCover.rootView.kind != p.coverKind {
            launchCover.rootView = LaunchScreen(appearance: appearance, kind: p.coverKind)
        }
        launchCover.isHidden = !p.isCovered
    }

    /// 显示着的页面的主框架提交时调用（测试用；应用里由 ChatTabs.wire(_:) 在运行时报提交时调用带页的 pageDidCommit(_:)）。
    func pageDidCommit() {
        pageDidCommit(page)
    }

    /// 页面 p 的主框架提交了。提交后 pageRevealLimit 还没加载完成：p 到时限后还在的遮挡结束，留着的提示收起。
    /// 兜底属于 p 的这次提交：到点时 p 已经释放、已经关闭、或又提交、加载完成过（代号变了），都不做事；
    /// 到点时不去看显示着的是哪个页面。p 已经关闭时什么都不做。
    func pageDidCommit(_ p: PageLoadState) {
        guard !p.isClosed else { return }
        p.hasCommittedPage = true
        p.awaitingFinish = true
        p.commitGeneration += 1
        let generation = p.commitGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + pageRevealLimit) { [weak self, weak p] in
            MainActor.assumeIsolated {
                guard let self, let p, !p.isClosed, p.commitGeneration == generation, p.awaitingFinish else { return }
                self.pageRevealLimitReached(for: p)
            }
        }
    }

    /// 页面 p 提交后 pageRevealLimit 还没加载完成。p 的遮挡在到时限后等提交的话结束（p 显示着时窗口才撤启动画面）；
    /// p 留着的提示总是在 p 的状态里收起，窗口的提示和日志只在 p 显示着时动。
    private func pageRevealLimitReached(for p: PageLoadState) {
        let waited = "提交后 \(Int(pageRevealLimit * 1000))ms 还没加载完成"
        if p.coverAwaitsCommit { endLaunchScreen(waited, for: p) }
        if p.noticeAwaitsLoad {
            if p === page { diagnostics.log("nav", "无法连接提示：\(waited)，收起") }
            p.noticeAwaitsLoad = false
            p.notice = .hidden
            if p === page { applyNotice(p) }
        }
    }

    /// 网页可能还没画出第一帧：盖一层同样的画面淡出（同一种样子：新标签页的遮挡淡出时也没有图标和应用名）。遮挡本身已经结束。
    /// 这层的底色和文字、图标用同一个外观，都固定在遮挡结束那一刻：淡出途中页面颜色变了也不跟着换。
    private func fadeOutLaunchScreen() {
        guard let container = launchCover.superview else { return }
        let look = launchCover.effectiveAppearance
        let fade = NSHostingView(rootView: LaunchScreen(appearance: appearance, kind: launchCover.rootView.kind,
                                                        fixedBackground: fixedFill(look)))
        fade.appearance = look
        fade.frame = launchCover.frame
        fade.autoresizingMask = [.width, .height]
        container.addSubview(fade, positioned: .above, relativeTo: launchCover)
        launchFade = fade
        fadeAway(fade)
    }

    /// 加载完成时收起留着的提示：和启动画面一样盖一层同样的提示淡出，内容（收起前的状态 shown）、底色和外观固定在这一刻。
    /// 显示着的页面的提示状态和提示那层已经收起（调用的地方先做），这里只加淡出那层。
    private func fadeOutLoadProblem(showing shown: LoadRecovery.Status) {
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

    /// 页面 p 进入启动保护（p 自己的状态）。p 显示着时窗口的颜色也停下来：已经排着队的颜色更新作废——取消，并且换代号，
    /// 万一已经出队也不生效。
    private func holdPageColor(_ p: PageLoadState) {
        p.holdsPageColor = true
        p.colorBeforeFirstLoad = nil
        guard p === page else { return }
        pageColorGeneration += 1
        pendingBackground?.cancel()
        pendingBackground = nil
        diagnostics.log("appearance", "启动保护：网页加载完成前不跟随页面底色（保持\(Self.shade(appearance.background))）")
    }

    /// 显示着的页面加载完成时调用（测试用；应用里由 ChatTabs.wire(_:) 每次加载完成调用带页的
    /// pageDidFinishLoading(_:reportedColor:)）。报的颜色是显示着的网页视图此刻报的。
    func pageDidFinishLoading() {
        pageDidFinishLoading(page, reportedColor: webView.underPageBackgroundColor)
    }

    /// 页面 p 加载完成。reportedColor：p 的网页视图此刻报的底色（窗口只观察显示着的网页视图，所以由调用方带进来）。
    /// p 自己的状态总是改：不再等加载完成、代号加一、记下第一次加载已完成和这次报的颜色（hasFinishedFirstLoad、colorAtLastFinish）、
    /// 留着的提示收起、启动保护解除。窗口只在 p 显示着时动：提示淡出、写日志、颜色代号、等颜色变化。
    /// 启动保护只有还在时起作用。解除时报的颜色不马上采用：它可能还是加载完成前的临时颜色。页面颜色变了再按原来的规则采用；
    /// 一直不变就在 pageColorSettleLimit 后按它采用。
    /// 不显示的页面解除启动保护时只改它自己的状态：不换窗口的颜色代号、不取消排着队的颜色更新、不影响显示着的页面的等待；
    /// 它报的颜色只记在 colorAtLastFinish，再记下解除的时刻（releasedWhileHidden）：窗口没有替它等颜色，
    /// 换上它时（display(_:webView:)）按这两样决定还要不要等，见 showPageColor(of:)。
    /// p 已经关闭时什么都不做。
    func pageDidFinishLoading(_ p: PageLoadState, reportedColor: NSColor?) {
        guard !p.isClosed else { return }
        p.awaitingFinish = false
        p.commitGeneration += 1
        p.hasFinishedFirstLoad = true
        p.colorAtLastFinish = reportedColor
        if p.noticeAwaitsLoad {
            p.noticeAwaitsLoad = false
            if p === page { diagnostics.log("nav", "无法连接提示：加载完成，淡出") }
            let shown = p.notice
            p.notice = .hidden
            if p === page {
                applyNotice(p)
                fadeOutLoadProblem(showing: shown)
            }
        }
        guard p.holdsPageColor else { return }
        p.holdsPageColor = false
        guard p === page else {
            p.releasedWhileHidden = Date()
            return
        }
        pageColorGeneration += 1
        p.colorBeforeFirstLoad = reportedColor
        diagnostics.log("appearance", "启动保护解除：加载完成时报的是\(Self.shade(reportedColor))，等页面颜色变化再采用")
        awaitPageColor(p, within: pageColorSettleLimit)
    }

    /// 显示着的页面 p 的“加载完成前的颜色”（colorBeforeFirstLoad）可能还是临时的：等它变化再采用，最多等 delay，
    /// 到点还没变就按当前颜色采用；同时马上按平常的规则看一次（150ms 后它已经和那个颜色不同就采用）。
    /// 解除启动保护时（等 pageColorSettleLimit）和换上一个还有没等完的颜色的页面时（showPageColor(of:)）调用。
    private func awaitPageColor(_ p: PageLoadState, within delay: TimeInterval) {
        let generation = pageColorGeneration
        // 这次颜色等待属于 p 和窗口此刻的颜色代号：到点时 p 已经释放、关闭或不再显示，或者窗口的颜色代号（pageColorGeneration）变了
        // （显示着的页面进入或解除启动保护、换网页视图、换显示的页面），都不起作用。
        // 故意不跟 p 的加载代号（commitGeneration）绑在一起：加载完成后不久又提交（例如重定向）不能取消这次颜色等待。
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak p] in
            MainActor.assumeIsolated {
                guard let self, let p, !p.isClosed, p === self.page, self.pageColorGeneration == generation,
                      p.colorBeforeFirstLoad != nil else { return }
                p.colorBeforeFirstLoad = nil
                self.diagnostics.log("appearance", "加载完成后 \(Int(self.pageColorSettleLimit * 1000))ms 页面颜色没有变，按当前颜色采用")
                self.pageBackgroundChanged(for: p)
            }
        }
        pageBackgroundChanged(for: p)
    }

    /// 显示着的页面 p 的底色可能变了（网页视图报了新颜色，或者上面的等待到点）。只对显示着、没有关闭的页面起作用。
    private func pageBackgroundChanged(for p: PageLoadState) {
        guard p === page, !p.isClosed else { return }
        if p.holdsPageColor {
            diagnostics.log("appearance", "启动保护中：页面底色报为\(Self.shade(webView.underPageBackgroundColor))，不采用")
            return
        }
        pendingBackground?.cancel()
        let generation = pageColorGeneration
        // 这次更新属于 p 和报颜色的那个网页视图：p 已经释放、关闭或不再显示时不起作用；换网页视图时取消并换代号，
        // 到点时不会去读换上来的网页。
        let work = DispatchWorkItem { [weak self, weak p] in
            MainActor.assumeIsolated {
                guard let self, let p, !p.isClosed, p === self.page, self.pageColorGeneration == generation,
                      !p.holdsPageColor else { return }
                let color = self.webView.underPageBackgroundColor
                if let before = p.colorBeforeFirstLoad {
                    // 还是加载完成前就有的颜色：不采用，也不保存。
                    guard !PageAppearance.sameColor(color, before) else { return }
                    p.colorBeforeFirstLoad = nil
                }
                self.adoptPageColor(color)
            }
        }
        pendingBackground = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 采用页面颜色：记下（下次启动用），深浅变了写一行，顶部一条、遮挡、提示和窗口底色跟着变。
    private func adoptPageColor(_ color: NSColor?) {
        let wasDark = appearance.isDark
        appearance.update(color)
        if appearance.isDark != wasDark {
            diagnostics.log("appearance", "页面底色：\(appearance.isDark == true ? "深色" : "浅色")")
        }
        applyAppearance()
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
        hints.host.appearance = appearance.nsAppearance
        // 窗口底色和网页一致：切换、调整大小时新露出的地方不闪白。
        window?.backgroundColor = appearance.background ?? .windowBackgroundColor
        // 补排版时盖着网页的那块是窗口此刻的页面底色：补排版中采用了新颜色（换上来的页面的颜色等到了），它跟着换。
        if let cover = catchUp?.cover {
            cover.fill = window?.backgroundColor ?? .windowBackgroundColor
            cover.needsDisplay = true
        }
    }

    // MARK: - 页面关闭

    /// 页面 p 关闭了（关闭标签页时由 ChatTabs.close(_:) 调用，在它的网页运行时关闭之后）。从此 p 是关闭的（p.isClosed，不会改回）：
    /// - 带页的入口（showLoadProblem(_:for:)、pageDidCommit(_:)、pageDidFinishLoading(_:reportedColor:)、
    ///   endLaunchScreen(_:for:)）对 p 什么都不做，不改 p 的状态，也不动窗口；
    /// - p 排着的回调（提交后兜底、颜色等待、150ms 颜色更新）到点时什么都不做，p 的遮挡（启动画面）的时限和上限也不再改它
    ///   （p 的遮挡停在关闭时：还盖着的就一直算盖着，但它只是 p 的状态，不会结束、也不会挡住别的页面的遮挡）；
    /// - p 不再开始遮挡；
    /// - p 的网页视图报的颜色不再采用。
    /// p 的其余状态停在这一刻。关两遍和关一个从没显示过的页面都可以。这里不写日志（运行时关闭时写了一行）。
    /// p 是显示着的页面时也照这样做：窗口停在关闭时的样子，不会再因 p 而变（启动画面还盖着的就一直盖着，直到换上别的页面）。
    /// 换上哪个页面显示、它的提示、遮挡和颜色，是切换标签页的入口 display(_:webView:) 的事：照换上来的页面自己的状态投，
    /// 和关闭的页面无关。关闭的页面不能再换上来。正式的关闭入口 ChatTabs.closeTab(_:) 关显示着的标签页时先切换到邻居
    /// （display 换上邻居的页面，投邻居自己的遮挡、提示和颜色），再收尾（ChatTabs.close(_:)，只关不选中、不显示的标签页），
    /// 所以关闭时 p 已经不显示；它的网页视图藏在容器里，由 removeHiddenWebView(_:) 拿出来。
    func pageClosed(_ p: PageLoadState) {
        p.isClosed = true
    }

    /// 快照还没拍好、窗口还没动时再按不算数。窗口已经到位、网页还在排版时可以切回去：用户看到的已经是切换好的窗口。
    func toggleMode() {
        guard layoutChange?.windowPlaced ?? true else { return }
        show(mode: mode == .quick ? .full : .quick)
    }

    // MARK: - 切换显示的页面（切换标签页）

    /// 切换标签页的入口（ChatTabs.select(_:) 调用，选中项已经先改好）：窗口改为显示页面 p 和它的网页视图 newWebView，
    /// 并把 p 自己的状态投到窗口上；newWebView 离开时排好版的大小或缩放和现在不同，先盖住、等它按现在的大小排好再揭开（补排版）。
    /// p 已经是显示着的页面、或已经关闭（关闭的页面不再显示：它的状态停在关闭时，投上来窗口就停住了）：什么都不做，
    /// beforeCatchUp 和 laidOut 都不调用。
    ///
    /// 没有 replaceWebView 那个“页面加载状态已停下来”的前提：状态是每个页面自己的，跟着页面一起换，
    /// 所以换到、换走还盖着遮挡、还在加载、有提示、在等颜色的页面都是正常的。剩下的前提只有两条：p 没有关闭（上面）；
    /// newWebView 就是 p 的网页视图（窗口分不出来，由调用方保证：ChatTab 的 page 和运行时的网页视图都是常量）。
    ///
    /// 两个回调都属于这一次显示：
    /// - beforeCatchUp：要补排版时调用一次，在 newWebView 还藏着、还是离开时的大小时（第 4 步里、放上来之前），
    ///   调用方在这时记下它的阅读位置（排版变化之前）。不补排版就不调用。
    /// - laidOut：p 按现在的窗口大小排好版时调用，每次显示正好一次：不用补排版就在最后一步当场调用；要补排版就在补排版结束时
    ///   （网页排好、到时限、或者窗口要变大小、隐藏而先结束它，见 finishCatchUp(_:)）。补排版还没结束就又换了显示的页面
    ///   （再调用这里），这一次就作废，laidOut 不再调用：p 已经不显示了。
    ///
    /// 顺序：
    /// 1. 记下换下去的页面这时是不是已经排好版：没有在切模式、也没有在补排版（这两样在下一步先结束，那时它的排版还没等完）。
    /// 2. 进行中的切模式先结束（和隐藏、显示、拖边一样）。结束时窗口说“排版结束”（onDidChangeLayout）：选中项已经先改了，
    ///    所以换下去的那一页排版前记下的阅读位置留在它自己身上，等它再显示（不会放回到正要藏起的那一页）。
    ///    之后这次切模式的快照、排版完成和时限回调晚到都不起作用（layoutChange 已经不是它们那次）。
    ///    进行中的补排版（换下去的页面的）作废：拿掉盖着的那块，不调用它的 laidOut；它迟到的排版完成和时限都不起作用。
    /// 3. 还在淡出的那层（启动画面的、提示的）是换下去的页面的：马上拿掉（D7），不盖在换上来的页面上。
    ///    排着的颜色更新作废（取消，颜色代号加一）：换下去的页面排下的 150ms 更新和颜色等待到点时都不起作用。
    /// 4. 换网页视图：先看 newWebView 要不要补排版（catchUpReason(for:)），要的话调用 beforeCatchUp。
    ///    再把 newWebView 放进容器铺满、显示，键盘焦点交给它，Esc 判断和页面底色观察跟着换。
    ///    换下去的网页视图留在容器里藏起，固定在离开时的大小（D3）：之后窗口变大小它也不重新排版；不拆掉，网页内容留着。
    ///    同时记下它离开时排好版的大小和缩放（第 1 步说没排好的记作不知道），再显示时拿来比。
    /// 5. 显示的页面换成 p，p 的遮挡（applyCover，不重新开始，计时还是它自己开始时排下的）和提示（applyNotice）投上来。
    ///    换下去的页面的遮挡、提示、颜色等待都留在它自己的状态里；它之后的事件和迟到的回调只改它自己的状态，不动窗口。
    /// 6. 颜色（D4）：见 showPageColor(of:)。
    /// 7. 要补排版：开始补排版（beginCatchUp(_:laidOut:)：盖上窗口此刻的页面底色，newWebView 已经显示、在窗口里，
    ///    这时才让网页按现在的大小排版，等它排好）。不用：当场调用 laidOut。
    /// 不补排版时这里不写日志（切换的那一行由 ChatTabs.select(_:) 写；结束切模式、采用颜色照常写它们自己的行）；
    /// 补排版的开始和结束各写一行（窗口的行，不带标签）。
    func display(_ p: PageLoadState, webView newWebView: WKWebView,
                 beforeCatchUp: () -> Void = {}, laidOut: @escaping @MainActor () -> Void = {}) {
        guard p !== page, !p.isClosed else { return }
        let outgoingLaidOut = layoutChange == nil && catchUp == nil
        finishLayoutChange(animated: false)
        dropCatchUp()
        dropFades()
        dropQueuedPageColor()
        var reason: String?
        // newWebView 已经显示着：只在测试的接缝把显示的页面单独换过（setDisplayedPageForTesting）时会这样，不用换网页视图。
        if newWebView !== webView {
            // 先把还没做的排版做完，离开时的大小才是它现在真正的大小，现在的容器大小也是真的。
            webContainer.layoutSubtreeIfNeeded()
            let old = webView, oldFill = webFill, leaveSize = old.frame.size
            reason = catchUpReason(for: newWebView)
            if reason != nil { beforeCatchUp() }
            putOnDisplay(newWebView)
            // 要在藏起旧网页之前交：藏起含第一响应者的视图时 AppKit 会把焦点交给别处。
            window?.makeFirstResponder(newWebView)
            hideInContainer(old, fill: oldFill, size: leaveSize,
                            laidOut: outgoingLaidOut ? LaidOut(size: leaveSize, zoom: old.pageZoom) : nil)
        }
        page = p
        applyCover(p)
        applyNotice(p)
        showPageColor(of: p)
        if let reason {
            beginCatchUp(reason, laidOut: laidOut)
        } else {
            laidOut()
        }
    }

    /// 换上来的网页视图 view 要不要补排版；要的话返回原因（写日志用），不要是 nil。
    /// - 切模式的排版没接上（onPrepareLayout 是 nil，切模式也就直接切换）：没法等，不补。
    /// - 从没在这个窗口里显示过（不在藏着的里面：新标签页第一次显示）：不补。它的第一次加载有自己的遮挡（新标签页的遮挡），
    ///   那块盖到加载完成；补排版不和那块遮挡掺在一起。
    ///   例外是在后台打开的标签页（⌘ 点击链接）：它加载前就按当时的大小藏进了容器（addHiddenWebView(_:)），
    ///   第一次显示时和别的藏着的一样比；要补时补排版那块和它第一次加载的遮挡同时在，各按自己的规则结束。
    /// - 离开时没排好（那时正在切模式或补排版，被这次切换先结束了）：补，哪怕大小没变。
    /// - 离开时排好版的大小和现在的容器大小不同（藏着时切过模式、拖过边）：补。
    /// - 缩放和离开时不同（藏着时改了页面缩放，缩放每页都改）：补。
    /// 别的发给每一页的设置（网页增强、网页无障碍、弹窗标题）不改网页排版的大小，不算。
    private func catchUpReason(for view: WKWebView) -> String? {
        guard onPrepareLayout != nil, let hidden = hiddenWebViews[ObjectIdentifier(view)] else { return nil }
        guard let laidOut = hidden.laidOut else { return "离开时还没排好" }
        if laidOut.size != webContainer.bounds.size { return "大小和离开时不同" }
        if laidOut.zoom != view.pageZoom { return "缩放和离开时不同" }
        return nil
    }

    // MARK: - 补排版（切换标签页时）
    //
    // 换上来的网页视图离开时排好版的大小或缩放和现在不同时：先盖住，让它按现在的大小排好，再揭开（计划 4.2）。
    // 用的是切模式那一套：同一个排版入口（onPrepareLayout，网页里的 layoutReadyScript：等窗口宽度到位，画两帧，放回阅读位置，
    // 再画两帧）、同一个时限（layoutWaitLimit，到时限就揭开）、同一种身份核对（每一次是一个新对象，回调到点时不是 catchUp
    // 这一次就什么都不做）。和切模式不同的只有两样：窗口不动；盖的不是旧画面，是一块窗口此刻的页面底色（计划“补排版时盖页面底色”：
    // 换上来的页面在这个大小上没有画过，旧画面是别的页面的；不加图标、不加进度圈，通常只有一两百毫秒）。
    // 那块放在网页上面、提示和第一次加载的遮挡下面：页面的“无法连接”提示和第一次加载的遮挡照样看得见；两者互不影响，
    // 各自按自己的规则结束（遮挡先结束时，淡出那层下面还是这块；这块先结束时，遮挡还盖着）。
    // 网页排版要等 requestAnimationFrame，网页视图藏着时它不走：所以补排版在网页视图已经显示、放进窗口以后才开始。
    // 进行中的补排版遇到别的排版变化先结束（算排好，调用 laidOut）：显示窗口或切模式（show(mode:)）、隐藏窗口、拖边、
    // 换网页视图，和进行中的切模式一样。又换了显示的页面：作废（dropCatchUp()），不调用 laidOut。

    /// 开始补排版：盖上那块，排下时限，再让网页按现在的容器大小排版。只在 display 的最后一步调用（那时页面颜色已经定了）。
    private func beginCatchUp(_ reason: String, laidOut: @escaping @MainActor () -> Void) {
        guard let prepare = onPrepareLayout, let container = webContainer.superview else { return laidOut() }
        let cover = FrozenPageView()
        cover.fill = window?.backgroundColor ?? .windowBackgroundColor
        cover.setAccessibilityElement(false)
        cover.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cover, positioned: .above, relativeTo: webContainer)
        NSLayoutConstraint.activate(Self.fill(cover, in: webContainer))
        let change = CatchUp(cover: cover, laidOut: laidOut)
        catchUp = change
        diagnostics.log("window", "补排版：\(reason)，盖上页面底色等网页排好")
        // 换上来的网页视图马上变成现在的大小（不等下一轮排版），网页早一点知道新大小。
        container.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + layoutWaitLimit) { [weak self, weak change] in
            MainActor.assumeIsolated {
                guard let self, let change, self.catchUp === change else { return }
                self.finishCatchUp("超过时限")
            }
        }
        prepare(webContainer.bounds.size) { [weak self, weak change] in
            guard let self, let change, self.catchUp === change else { return }
            self.finishCatchUp("网页排好")
        }
    }

    /// 补排版结束、算排好了（网页排好、到时限，或者窗口要变大小、隐藏而先结束）：拿掉那块，写一行，调用这次显示的 laidOut。
    /// 没有在补排版时什么都不做。
    private func finishCatchUp(_ outcome: String) {
        guard let change = endCatchUp(outcome) else { return }
        change.laidOut()
    }

    /// 又换了显示的页面：进行中的补排版作废，拿掉那块，写一行，不调用 laidOut（那一页已经不显示）。
    private func dropCatchUp() {
        _ = endCatchUp("换了显示的页面")
    }

    private func endCatchUp(_ outcome: String) -> CatchUp? {
        guard let change = catchUp else { return nil }
        catchUp = nil
        change.cover.removeFromSuperview()
        diagnostics.log("window", "补排版结束：\(outcome)（\(Int(Date().timeIntervalSince(change.started) * 1000))ms）")
        return change
    }

    /// 换上来的页面 p 的颜色（D4，display(_:webView:) 的最后一步；颜色代号已经加过一）。用的都是原来的规则：
    /// - p 在启动保护里，或第一次加载还没完成：窗口的颜色不动（顶部一条、窗口底色、遮挡的底色还是上一个页面采用的）。
    ///   之后它报的颜色照启动保护不采用，到它第一次加载完成（pageDidFinishLoading(_:reportedColor:)）再照原来的等待。
    /// - p 有没等完的“加载完成前的颜色”（colorBeforeFirstLoad：它显示着解除启动保护、还在等颜色变化时被换走了）：
    ///   重新等一次（awaitPageColor，最多 pageColorSettleLimit）。
    /// - p 不显示时解除了启动保护（releasedWhileHidden）、离那时还不到 pageColorSettleLimit：窗口没有替它等过，
    ///   加载完成时它报的颜色（colorAtLastFinish）可能还是临时的：照刚解除时一样等，只等剩下的时间。
    ///   已经过了这么久：原来的等待这时也早就按当前颜色采用了，当作已经稳定。
    /// - p 已提交、还没加载完成（又在加载）：它此刻的颜色可能是导航中的临时颜色，照平常的规则稳定 150ms 再采用。
    /// - 其余（第一次加载完成过、颜色已经稳定）：马上采用它此刻报的颜色。
    private func showPageColor(of p: PageLoadState) {
        let releasedWhileHidden = p.releasedWhileHidden
        p.releasedWhileHidden = nil
        if p.holdsPageColor || !p.hasFinishedFirstLoad { return }
        if p.colorBeforeFirstLoad != nil { return awaitPageColor(p, within: pageColorSettleLimit) }
        if let released = releasedWhileHidden {
            let left = pageColorSettleLimit - Date().timeIntervalSince(released)
            if left > 0 {
                p.colorBeforeFirstLoad = p.colorAtLastFinish
                return awaitPageColor(p, within: left)
            }
        }
        if p.awaitingFinish { return pageBackgroundChanged(for: p) }
        adoptPageColor(webView.underPageBackgroundColor)
    }

    /// 换下去的页面还在淡出的那层（启动画面的、提示的）马上拿掉（D7）。
    private func dropFades() {
        launchFade?.removeFromSuperview()
        launchFade = nil
        loadProblemFade?.removeFromSuperview()
        loadProblemFade = nil
    }

    /// 排着队的页面颜色更新作废：取消，并把 pageColorGeneration 加一（和进入启动保护同一个办法），
    /// 所以已经排下的 150ms 更新和颜色等待到点时都不生效。
    private func dropQueuedPageColor() {
        pendingBackground?.cancel()
        pendingBackground = nil
        pageColorGeneration += 1
    }

    /// 让 newWebView 成为窗口显示的网页视图：放进容器（藏在里面的先去掉固定大小的约束）铺满、显示出来，
    /// ChatWindow.webView（Esc 判断）和页面底色观察跟着换（先停掉旧的，旧网页之后报什么都不起作用）。
    /// 不碰键盘焦点和换下去的网页视图（它还铺满、还显示着），由调用方处理。
    private func putOnDisplay(_ newWebView: WKWebView) {
        backgroundObservation?.invalidate()
        backgroundObservation = nil
        if let hidden = hiddenWebViews.removeValue(forKey: ObjectIdentifier(newWebView)) {
            NSLayoutConstraint.deactivate(hidden.fixed)
        }
        if newWebView.superview !== webContainer {
            newWebView.translatesAutoresizingMaskIntoConstraints = false
            webContainer.addSubview(newWebView)
        }
        let fill = Self.fill(newWebView, in: webContainer)
        NSLayoutConstraint.activate(fill)
        webFill = fill
        newWebView.isHidden = false
        webView = newWebView
        (window as? ChatWindow)?.webView = newWebView
        observePageBackground(of: newWebView)
    }

    /// 换下去的网页视图（D3）：留在容器里藏起，不拿掉（网页内容留着、不重建；藏起以后 WebKit 会不会放慢它，要真实页面看），
    /// 固定在离开时的位置和大小 size：之后窗口变大小它也不跟着重新排版。再显示时（putOnDisplay）回到铺满。
    /// laidOut 是这一页的排版大小（每页一份，3.5）：离开时排好版的大小和缩放；离开时还没排好（正在切模式或补排版）是 nil。
    /// 再显示时拿它和那时的容器大小、缩放比，决定要不要先盖住补排版（catchUpReason(for:)）。
    private func hideInContainer(_ view: WKWebView, fill: [NSLayoutConstraint], size: NSSize, laidOut: LaidOut?) {
        NSLayoutConstraint.deactivate(fill)
        let fixed = [view.topAnchor.constraint(equalTo: webContainer.topAnchor),
                     view.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
                     view.widthAnchor.constraint(equalToConstant: size.width),
                     view.heightAnchor.constraint(equalToConstant: size.height)]
        NSLayoutConstraint.activate(fixed)
        hiddenWebViews[ObjectIdentifier(view)] = HiddenWebView(fixed: fixed, laidOut: laidOut)
        view.isHidden = true
    }

    /// 在后台打开的标签页（⌘ 点击链接，ChatTabs.openLink(_:from:_:)）还没加载、从没显示过的网页视图 view：放进容器、藏起，
    /// 和切换走的网页视图一样（D3，hideInContainer）固定在容器现在的大小，并记作按这个大小和它现在的缩放排好了版。
    /// 为什么（3.5 记下的缺口）：不放进来，它在窗口外面没有大小，第一次加载就在零大小或别的大小上排版，第一次显示时
    /// 又因为“从没显示过”不补排版。放进来以后它从第一次加载起就在窗口里、按窗口现在的大小排版；第一次显示（display）时
    /// 和别的藏着的网页视图一样拿它比：之后窗口变过大小或改过缩放就补排版，没变就不补。
    /// 正在切模式（容器固定在目标大小、网页还没排好）：记作“不知道”，第一次显示时补排版（和切模式中换下去的一样）。
    /// view 已经在容器里（显示着的、藏着的）：什么都不做。不改显示的页面、显示的网页视图、键盘焦点、页面底色的观察，不写日志。
    /// 之后：第一次显示时 display 把它放上来（putOnDisplay 拿掉固定大小的约束）；关闭时 removeHiddenWebView(_:) 拿出来。
    func addHiddenWebView(_ view: WKWebView) {
        guard view !== webView, hiddenWebViews[ObjectIdentifier(view)] == nil else { return }
        // 先把还没做的排版做完，容器现在的大小才是真的（和 display 换网页视图之前一样）。
        webContainer.superview?.layoutSubtreeIfNeeded()
        let size = webContainer.bounds.size
        // 先藏起再放进去：放进去的那一刻它在显示着的网页视图上面。
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(view)
        hideInContainer(view, fill: [], size: size,
                        laidOut: layoutChange == nil ? LaidOut(size: size, zoom: view.pageZoom) : nil)
        // 马上变成这个大小（不等下一轮排版）：开始加载时它已经是窗口的大小。
        webContainer.layoutSubtreeIfNeeded()
    }

    /// 关闭标签页时（ChatTabs.close(_:)）：view 藏在容器里（它的页面显示过、又换下去了；或者在后台打开、加载前放进来的，
    /// addHiddenWebView(_:)）就拿出来，窗口不再持有它，标签页放手后它就能释放。从没显示过、也不是在后台打开的不在容器里；
    /// 显示着的那个不算藏着（关闭显示着的标签页时 ChatTabs.closeTab(_:) 先换上邻居，它就藏进了容器）：什么都不做。
    func removeHiddenWebView(_ view: WKWebView) {
        guard let hidden = hiddenWebViews.removeValue(forKey: ObjectIdentifier(view)) else { return }
        NSLayoutConstraint.deactivate(hidden.fixed)
        view.removeFromSuperview()
    }

    // MARK: - 换网页视图（同一个页面）

    /// 换掉窗口里显示的网页视图，显示的页面不换。应用里没有地方调用（切换标签页用 display(_:webView:)，页面和网页视图一起换）；
    /// 测试用它核对换网页视图的那几样。
    ///
    /// 跟着换的：webContainer 里的视图和铺满它的约束（旧网页视图连同它的约束从容器里拿掉，这里不再持有它）、
    /// ChatWindow.webView（Esc 判断）、页面底色观察（先停掉旧的，旧网页之后报什么都不起作用）、
    /// 键盘焦点（原来在旧网页里才交给新网页，不在就不动）。
    ///
    /// 进行中的模式切换先结束，和隐藏、显示、拖边一样：快照和排版都是旧网页的，
    /// 晚到的快照、排版完成和时限回调因为 layoutChange 已经不是它们那次而不起作用。
    /// 进行中的补排版也先结束（算排好），理由一样。
    ///
    /// 显示的页面（page）不跟着换，它的加载状态不保存、不恢复、不重设，换过之后就当作新网页视图的。
    /// 所以前提是换的时候这些状态都已经停下来（pageStateIsSettled）；没停下来时记一行日志，调试版断言。
    /// （切换标签页没有这个前提：那时状态跟着页面一起换，见 display(_:webView:)。）
    /// 只动排着队的页面颜色更新：取消，并把 pageColorGeneration 加一（和进入启动保护同一个办法），
    /// 所以旧网页排下的 150ms 更新和加载完成后的等待到点时都不生效，不会把旧网页的颜色、也不会把新网页的颜色当成这次的结果。
    /// 新网页此刻报着的颜色不马上采用：顶部一条和窗口底色保持原样，等新网页的颜色变化。
    func replaceWebView(with newWebView: WKWebView) {
        guard newWebView !== webView else { return }
        finishLayoutChange(animated: false)
        finishCatchUp("换网页视图")
        let settled = pageStateIsSettled
        if !settled {
            diagnostics.log("window", "换网页视图时页面加载状态还没停下来：状态仍按窗口一份算，可能不属于新网页")
        }
        assert(settled, "换网页视图的前提：页面加载状态已经停下来（见 replaceWebView）")
        let old = webView
        let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: old) ?? false
        dropQueuedPageColor()
        putOnDisplay(newWebView)
        // 要在拿掉旧网页之前交：拿掉第一响应者时 AppKit 会把焦点交给窗口本身。
        if hadFocus { window?.makeFirstResponder(newWebView) }
        old.removeFromSuperview()
        diagnostics.log("window", "换网页视图：焦点\(hadFocus ? "在旧网页里，交给新网页" : "不在网页里，没动")")
    }

    /// 换网页视图（replaceWebView，同一个页面）的前提：没有启动画面和启动保护、没有在等加载完成前的颜色、
    /// 不在“已提交、还没加载完成”中、没有显示或留着“无法连接”提示。
    private var pageStateIsSettled: Bool {
        !isShowingLaunchScreen && !page.coverAwaitsCommit && !page.holdsPageColor && page.colorBeforeFirstLoad == nil
            && !page.awaitingFinish && !page.noticeAwaitsLoad && page.notice == .hidden
    }

    #if DEBUG
    /// 只给测试用（调试版才有）：把窗口当作显示着的页面换成 p，别的什么都不做——不投 p 的遮挡和提示、不动颜色、
    /// 不换网页视图、不换颜色代号、不写日志。这不是切换页面的入口（那是 display(_:webView:)，它一定连带换颜色代号、
    /// 投遮挡和提示、去掉淡出层），只用来单独验证一处保护：换走再换回来、而颜色代号没变时，排着的回调仍只对排下它的页面起作用；
    /// 不显示的页面的事件和计时只改它自己的状态；只有显示着的页面能开始启动画面（beginLaunchScreen()）时，让别的页面开始一次。
    /// 所以换过以后窗口的启动画面和提示可能还是换走的那个页面的样子。
    func setDisplayedPageForTesting(_ p: PageLoadState) {
        page = p
    }

    /// 只给测试用（调试版才有）：窗口不显示也开始一次切模式的排版变化，和显示着的窗口按切换键时一样走
    /// （排版变化前的回调、快照、拍好后窗口到 frame、网页排好或到时限才结束），只是不改模式、不显示窗口。
    /// 用来验证切换标签页时进行中的那次怎么结束、它迟到的快照和排版回调不动之后的那次。快照和排版没接上时什么都不做。
    /// 和 show(mode:) 一样，开始之前先结束进行中的补排版（算排好）。
    func beginLayoutChangeForTesting(to frame: NSRect) {
        guard onSnapshotPage != nil, onPrepareLayout != nil else { return }
        finishCatchUp("显示窗口或切模式")
        onWillChangeLayout?()
        guard let change = beginLayoutChange() else { return }
        change.frame = frame
        continueLayoutChange(change)
    }

    /// 有一次切模式的排版变化在进行（测试用）。
    var isChangingLayout: Bool { layoutChange != nil }

    /// 藏在容器里的网页视图离开时排好版的情况（测试用）。
    enum HiddenLayout: Equatable {
        /// 离开时按这个大小和缩放排好了版。
        case laidOut(NSSize, CGFloat)
        /// 离开时正在切模式或补排版，不知道排好没有。
        case unknown
    }

    /// view 藏在容器里时它离开时排好版的情况；不藏在这里（从没显示过、正显示着、拿出来了）是 nil（测试用）。
    func hiddenLayout(of view: WKWebView) -> HiddenLayout? {
        guard let hidden = hiddenWebViews[ObjectIdentifier(view)] else { return nil }
        return hidden.laidOut.map { .laidOut($0.size, $0.zoom) } ?? .unknown
    }
    #endif

    /// 网页视图铺满 webContainer 的四条约束。
    private static func fill(_ view: NSView, in place: NSView) -> [NSLayoutConstraint] {
        [view.topAnchor.constraint(equalTo: place.topAnchor),
         view.leadingAnchor.constraint(equalTo: place.leadingAnchor),
         view.trailingAnchor.constraint(equalTo: place.trailingAnchor),
         view.bottomAnchor.constraint(equalTo: place.bottomAnchor)]
    }

    /// 页面换底色（ChatGPT 切换浅色、深色）时跟着变。导航刚开始时 WebKit 会短暂报出默认白色，
    /// 稳定 150ms 再采用，免得每次加载都闪一下浅色。启动时另有启动保护，见 holdsPageColor。
    /// 只观察当前显示的网页视图：先停掉之前的观察。所以报颜色的就是显示着的页面（page）。
    private func observePageBackground(of view: WKWebView) {
        backgroundObservation?.invalidate()
        backgroundObservation = view.observe(\.underPageBackgroundColor) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pageBackgroundChanged(for: self.page)
            }
        }
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
        let size = NSSize(width: frame.width, height: frame.height - (window.frame.height - webContainer.frame.height))
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

    /// 网页排好或到时限时调用；隐藏、再次显示、开始拖动边缘和换网页视图时也调用：先结束这次切换，窗口和网页都和模式一致。
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
        guard let container = webContainer.superview, let window else { return }
        let old = webContainer.frame
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
        webPin = [webContainer.widthAnchor.constraint(equalToConstant: size.width),
                  webContainer.heightAnchor.constraint(equalToConstant: size.height)]
        NSLayoutConstraint.activate(webPin)
        webContainer.superview?.layoutSubtreeIfNeeded()
    }

    private func unpinWeb() {
        guard !webPin.isEmpty else { return }
        NSLayoutConstraint.deactivate(webPin)
        webPin = []
        NSLayoutConstraint.activate(webEdges)
        webContainer.superview?.layoutSubtreeIfNeeded()
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
        if resizingByHand {
            finishLayoutChange(animated: false)
            finishCatchUp("拖边")
        }
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
        hints.windowHidden()
        onDidMiniaturize?()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        hints.windowMayBeOnScreen()
    }

    /// 被别的窗口完全挡住、又露出来：还没记下显示过的提示从这一刻重新等（TabHintPresenter）。
    func windowDidChangeOcclusionState(_ notification: Notification) {
        hints.windowMayBeOnScreen()
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

/// 一次进行中的补排版（切换标签页时换上来的网页视图按现在的大小排版）：盖着网页的那块、开始的时刻，和排好时要调用的 laidOut。
@MainActor private final class CatchUp {
    let started = Date()
    /// 盖着网页的那块：窗口此刻的页面底色，没有图片。
    let cover: FrozenPageView
    /// 排好（或到时限、被先结束）时调用一次；作废时（又换了显示的页面）不调用。
    let laidOut: @MainActor () -> Void

    init(cover: FrozenPageView, laidOut: @escaping @MainActor () -> Void) {
        self.cover = cover
        self.laidOut = laidOut
    }
}

/// 藏在容器里的一个网页视图：把它固定在离开时的位置、大小的约束，和它离开时排好版的大小、缩放（离开时没排好是 nil）。
private struct HiddenWebView {
    let fixed: [NSLayoutConstraint]
    let laidOut: LaidOut?
}

/// 网页视图排好版时的大小（点）和页面缩放。两样都一样，网页里的排版（CSS 像素的视口）才一样。
private struct LaidOut {
    let size: NSSize
    let zoom: CGFloat
}

/// 切换时盖在网页上的旧画面，图片以外的部分是页面底色。只是一张图，点击穿过去。
/// 补排版时盖的那块也是它，没有图片，只有页面底色。
private final class FrozenPageView: NSImageView {
    var fill: NSColor = .windowBackgroundColor

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}
