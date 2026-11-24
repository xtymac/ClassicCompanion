import AppKit
import SwiftUI
import Combine
import CompanionCore

@main
enum ClassicCompanionMain {
    @MainActor static func main() {
        if SingleInstance.handOffToRunningInstance() { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let settings = AppSettings()
    private let languages = LanguageController.shared
    private let diagnostics = Diagnostics()
    /// 标签页（顺序、选中项和标识的列表 TabList 也在这里）、它们的运行时回调怎么接到窗口上，和换页面、聚焦输入框。见 ChatTabs。
    /// 启动时有一个标签页，之后由按键、菜单和 ⌘ 点击链接经 ChatTabs 增减。对选中的标签页做的操作（新对话、⌘R、媒体状态、证据采集）和设置的改动都经它，
    /// 在操作开始时取选中的那个；这里不再另外留着一个标签页。
    private var chatTabs: ChatTabs!
    /// 标签页的菜单项（3.11）：文件菜单、窗口菜单、菜单栏图标的菜单里的那几项，和左上角 × 的提示里的键。见 TabMenus。
    private var tabMenus: TabMenus!
    private let toolbarState = ToolbarState()
    private let pageAppearance = PageAppearance()
    private var mediaTimer: Timer?
    private var windowController: ChatWindowController!
    private let hotKey = GlobalHotKey()
    private lazy var hotKeyRecorder = HotKeyRecorderModel(
        taken: { [weak self] in self.map { [$0.settings.modeKey: LocalizedText("purpose.toggleMode")] } ?? [:] },
        apply: { [weak self] in self?.changeHotKey(to: $0) },
        onPause: { [weak self] in self?.hotKey.unregister() },
        onResume: { [weak self] in self?.registerHotKey() },
        log: { [weak self] in self?.diagnostics.log("hotkey", $0) },
        grab: { [weak self] modifiers in
            guard let self else { return }
            if let modifiers {
                let count = self.hotKey.registerTemporary(HotKeyCombo.grabCandidates(carbonModifiers: modifiers))
                self.diagnostics.log("hotkey", "录制临时登记 \(HotKeyCombo.symbols(modifiers)) 加 \(count) 个键")
            } else {
                self.hotKey.unregisterTemporary()
            }
        },
        otherAppWindows: OtherAppWindows.onScreen)
    /// 切换键不是全局快捷键，但录制时也要暂停唤醒键：不然按到唤醒键会隐藏窗口，“两行相同”的提示也出不来。
    private lazy var modeKeyRecorder: HotKeyRecorderModel = {
        let model = HotKeyRecorderModel(
            defaultCombo: .modeStandard,
            taken: { [weak self] in self.map { [$0.settings.hotKey: LocalizedText("purpose.wake")] } ?? [:] },
            apply: { [weak self] in self?.changeModeKey(to: $0) },
            onPause: { [weak self] in self?.hotKey.unregister() },
            onResume: { [weak self] in self?.registerHotKey() },
            log: { [weak self] in self?.diagnostics.log("hotkey", "切换键\($0)") })
        HotKeyRecorderModel.makeExclusive(hotKeyRecorder, model)
        return model
    }()
    private var modeMenuItem: NSMenuItem?
    private var checkForUpdatesMenuItem: NSMenuItem?
    /// 应用内更新（Sparkle）。见 Updates/UpdateController.swift 和 docs/updates.md。
    private var updates: UpdateController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var trialNotesWindow: NSWindow?
    private var firstShowDone = false
    private var cancellables: Set<AnyCancellable> = []
    #if DEBUG
    private var debugDriver: DebugDriver?   // TEMPORARY investigation hook，只在开发版
    #endif

    static var build: String { AppInfo.current.summary }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 放在最前面：要在 Sparkle 启动、网页加载、窗口显示写入设置之前判断（DockIconRefresh.earlierVersionKeys）。
        let launch = DockIconRefresh.recordLaunch(defaults: .standard, build: AppInfo.current.build)
        NSApp.setActivationPolicy(.regular)
        diagnostics.log("app", "启动 构建 \(Self.build)")
        if case .updated(let from) = launch {
            let icon = DockIconRefresh.bundleIcon()
            if let icon { NSApp.applicationIconImage = icon }
            diagnostics.log("app", "更新后第一次启动（上次构建 \(from ?? "未记录")）：Dock 图标\(icon == nil ? "没找到应用包里的图标，不设" : "设为应用包里的图标")")
        }
        diagnostics.log("app", "界面语言 \(languages.language.rawValue)（设置：\(languages.preference.rawValue)，系统：\(Locale.preferredLanguages.prefix(3).joined(separator: ","))）")

        // 网络状态由全应用共用的一个监视送给运行时；运行时自己不再开监视。运行时由 chatTabs 登记（见 ChatTabs.init）。
        let network = NetworkStatus()
        // 标签页列表开始时只有启动时的那一个；它的标识从这里来（TabID 只能由 TabList 发放）。列表随后交给 chatTabs。
        // 先建列表再建运行时：运行时和适配器建的时候就要知道标识，日志从第一行起带它的标签（TabLog）。建列表不写日志、不做别的事。
        let tabList = TabList()
        // 建一个标签页：启动时的那个和之后新增的（ChatTabs.newTab()，用下面交给 chatTabs 的这同一个）都这样建，
        // 同一份诊断和设置。
        let makeTab: @MainActor (TabID) -> ChatTab = { [diagnostics, settings] id in
            ChatTab.make(id: id, diagnostics: diagnostics, settings: settings)
        }
        let launchTab = makeTab(tabList.selected)
        // 系统 TTS（SpeechController）已退出正式路径：1.2 版要求使用官方 Read Aloud，不实例化、不回退。

        let bar = WebBar(onClose: { [weak self] in self?.windowController.hide(reason: "顶部关闭按钮") },
                         onNewChat: { [weak self] in self?.newChat() },
                         onToggleMode: { [weak self] in self?.windowController.toggleMode() },
                         onDoubleClick: { [weak self] in self?.barDoubleClicked() },
                         onBarPress: { [weak self] count, moved in
                             self?.diagnostics.log("window", "顶部按下：第 \(count) 下\(moved ? "，拖动了窗口" : "")")
                         },
                         onBack: { [weak self] in
                             self?.goInHistory(.back, eventWindow: self?.windowController?.window, source: "顶部返回箭头")
                         },
                         state: toolbarState, appearance: pageAppearance)
        // 标签栏（阶段 4）：窗口里的视图和 chatTabs 用同一个模型；点按由 chatTabs 接到模型上（ChatTabs.init）。
        let tabBarModel = TabBarModel()
        windowController = ChatWindowController(webView: launchTab.runtime.webView, toolbar: bar, diagnostics: diagnostics,
                                                appearance: pageAppearance, page: launchTab.page,
                                                tabBar: TabBarView(model: tabBarModel, appearance: pageAppearance))
        // ⌘[ ⌘] 和鼠标侧键由聊天窗口处理（只管它自己的事件），目标页面在按下时解析一次（这一刻选中的标签页）。
        windowController.historyPage = { [weak self] in self?.historyPage(eventWindow: self?.windowController?.window) }
        windowController.onWillShow = { [weak self] mode in self?.toolbarState.quick = mode == .quick }
        windowController.onDidMiniaturize = { [weak self] in self?.releaseForegroundIfWindowless() }

        // 窗口的回调里对选中的标签页做的（提示里的“重新加载”、窗口显示后、排版变化前后的阅读位置、切模式时的快照和排版）
        // 和网页运行时的回调（地址变化、Esc、加载完成、加载失败、提示变化、提交）接到窗口上，
        // 还是在这里，内容见 ChatTabs.init 和 ChatTabs.wire(_:)。
        chatTabs = ChatTabs(list: tabList, tab: launchTab, windowController: windowController, diagnostics: diagnostics,
                            network: network,
                            hideWindow: { [weak self] reason in self?.windowController.hide(reason: reason) },
                            focusInput: { adapter in await adapter.focusInput() },
                            saveLastConversation: { [weak self] url in self?.settings.lastConversationURL = url },
                            mediaState: { adapter in await adapter.webMediaState() },
                            openNewChat: { adapter in await adapter.openNewChatInPage() },
                            makeTab: makeTab,
                            revealWindow: { [weak self] in self?.windowController.reveal() },
                            tabBar: tabBarModel)
        chatTabs.wire(launchTab)
        // 顶部返回箭头跟着选中的标签页（ChatTabs.onBackButtonChange：它的历史变了、换了选中的标签页）。
        chatTabs.onBackButtonChange = { [weak self] shows, page in self?.backButtonChanged(shows, page: page) }
        // 第一次有多个标签页的提示显示过没有，存在设置里（每次安装一次）。提示的文字也给读屏播报。
        chatTabs.tipRecord = settings
        windowController.hints.announce = { text in
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        tabMenus = TabMenus(tabs: chatTabs, chatWindow: windowController.window, diagnostics: diagnostics, toolbar: toolbarState)
        tabMenus.userHotKeys = { [weak self] in self.map { [$0.settings.hotKey, $0.settings.modeKey] } ?? [] }
        // 标签页的个数变了：菜单项和左上角 × 的提示跟着改；多于一个标签页时显示标签栏（模型这时已经是新的）。
        chatTabs.onTabsChanged = { [weak self] in
            guard let self else { return }
            self.tabMenus.refresh()
            self.windowController.setTabBarVisible(self.chatTabs.tabBar.isShown)
        }
        updates = UpdateController(diagnostics: diagnostics)

        buildMainMenu()
        buildStatusItem()
        bindSettings()
        bindLanguage()
        registerHotKey()
        startMediaMonitor()
        listenForEvidenceRequests()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugDriver") {
            debugDriver = DebugDriver(windowController: windowController)
        }
        #endif

        // Phase 0 对照测试（M6 X2）：冷启动直接 Full。
        // 开启：defaults write local.classiccompanion.ClassicCompanion phase0LaunchFull -bool true（默认关闭）
        let launchFull = UserDefaults.standard.bool(forKey: "phase0LaunchFull")
        diagnostics.launchMode = launchFull ? "phase0LaunchFull（冷启动直接 Full）" : "默认（Quick）"
        if launchFull {
            windowController.defaultShowMode = .full
            diagnostics.log("app", "Phase 0 对照启动：直接 Full")
        }

        let start = (settings.restoreLastConversation ? settings.lastConversationURL : nil) ?? WebRuntime.homeURL
        windowController.beginLaunchScreen()
        launchTab.runtime.load(start)
        // 首次显示放到下一轮 run loop，确保激活在应用完成启动之后发生
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.windowController.show(mode: self.windowController.defaultShowMode)
            self.firstShowDone = true
            // 聊天窗口先出来：第二次启动时 Sparkle 的标准询问出现在它上面。
            self.updates.start()
        }
    }

    /// 点 Dock、从 Finder 再次打开。已由这里处理，不需要系统再做默认动作。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController.reveal()
        return false
    }

    /// ⌘Tab 切入不发 reopen：应用已激活却没有窗口时，这里找回聊天窗口。
    /// 等一轮 run loop：系统恢复隐藏的应用时，窗口可能晚于这条通知出现。
    func applicationDidBecomeActive(_ notification: Notification) {
        guard firstShowDone else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.isActive, NSApp.modalWindow == nil, !self.hasOpenWindow else { return }
            self.windowController.reveal()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            // 关闭设置时结束录制、清掉两行的提示，旧键回来。
            hotKeyRecorder.leave()
            modeKeyRecorder.leave()
        }
        releaseForegroundIfWindowless()
    }

    /// 关掉最后一个辅助窗口、或把聊天窗口最小化之后，应用还在前台却没有窗口。
    /// 这时 ⌘Tab 切不回来：应用已经激活，系统不会再通知。把前台交回去，下次切入才能找回窗口。
    private func releaseForegroundIfWindowless() {
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.isActive, NSApp.modalWindow == nil, !self.hasOpenWindow else { return }
            self.windowController.returnForeground()
        }
    }

    /// 能接收键盘的可见窗口。这样会排除菜单栏图标自身的窗口，并包含登录弹窗。
    private var hasOpenWindow: Bool {
        NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.canBecomeKey }
    }

    /// 有准备好、还没确认的更新时，先取消安装再退出：退出时绝不自动安装。其余情况照常退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updates?.terminationReply { NSApp.reply(toApplicationShouldTerminate: true) } ?? .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        mediaTimer?.invalidate()
        hotKey.unregister()
        windowController.rememberQuickPosition()
    }

    // MARK: - 行为

    private func registerHotKey() {
        let combo = settings.hotKey
        let status = hotKey.register(keyCode: combo.keyCode, modifiers: combo.carbonModifiers)
        diagnostics.hotKeyRegistration = status
        diagnostics.log("hotkey", "\(combo.label)：\(GlobalHotKey.describe(status))")
        if status != noErr {
            let alert = NSAlert()
            alert.messageText = L10n.format("alert.hotkeyFailed.title", combo.label)
            alert.informativeText = L10n.format("alert.hotkeyFailed.body", GlobalHotKey.statusText(status).string())
            alert.addButton(withTitle: L10n.string("common.ok"))
            alert.runModal()
        }
        hotKey.onTemporaryPressed = { [weak self] combo in self?.hotKeyRecorder.grabbed(combo) }
        hotKey.onPressed = { [weak self] in
            guard let self else { return }
            self.diagnostics.recordHotKey()
            self.windowController.toggle(wake: self.settings.wakeWindowMode)
        }
    }

    /// 换唤醒键，失败时留在原来的键上。返回要在设置里显示的错误。
    private func changeHotKey(to combo: HotKeyCombo) -> LocalizedText? {
        var status = noErr
        let result = HotKeyCombo.apply(combo, over: settings.hotKey) { candidate in
            status = hotKey.register(keyCode: candidate.keyCode, modifiers: candidate.carbonModifiers)
            return status
        }
        settings.hotKey = result.active
        diagnostics.hotKeyRegistration = status
        // 日志保持中文，和以前的记录一致；设置里按界面语言显示。
        diagnostics.log("hotkey", result.error?.string(in: .simplifiedChinese) ?? "\(combo.label)：\(GlobalHotKey.describe(status))")
        return result.error
    }

    /// 切换键只在本应用里生效，不用注册。录制时暂停的唤醒键在这里装回去。
    private func changeModeKey(to combo: HotKeyCombo) -> LocalizedText? {
        settings.modeKey = combo
        diagnostics.log("hotkey", "切换键改为 \(combo.label)")
        registerHotKey()
        return nil
    }

    private func bindSettings() {
        settings.$modeKey.removeDuplicates().sink { [weak self] combo in
            guard let self else { return }
            self.windowController.modeKey = combo
            self.toolbarState.modeKeyLabel = combo.label
            if let item = self.modeMenuItem {
                let equivalent = combo.menuKeyEquivalent
                item.keyEquivalent = equivalent?.key ?? ""
                item.keyEquivalentModifierMask = equivalent?.modifiers ?? []
            }
            // 标签页的菜单项和它相同时不显示快捷键（TabMenus）。sink 在设置改之前调用：等改完再看。
            DispatchQueue.main.async { self.tabMenus.refresh() }
        }.store(in: &cancellables)
        // 唤醒键也交给窗口：标签页的键和它相同时让给它（ChatWindowController.userHotKeyTakes(_:)）。菜单也一样（TabMenus）。
        settings.$hotKey.removeDuplicates().sink { [weak self] combo in
            self?.windowController.wakeKey = combo
            DispatchQueue.main.async { self?.tabMenus.refresh() }
        }.store(in: &cancellables)
        // 网页增强、页面缩放、网页无障碍：每个标签页都改（ChatTabs）。
        Publishers.CombineLatest(settings.$webEnhancements, settings.$escapeHidesWindow)
            .dropFirst()
            .sink { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.chatTabs.applyEnhancementScripts()
                }
            }.store(in: &cancellables)
        settings.$pageZoom.dropFirst().removeDuplicates().sink { [weak self] zoom in
            DispatchQueue.main.async { self?.chatTabs.setPageZoom(zoom) }
        }.store(in: &cancellables)
        settings.$allowPageAccessibility.dropFirst().removeDuplicates().sink { [weak self] allowed in
            DispatchQueue.main.async { self?.chatTabs.setPageAccessibilityAllowed(allowed) }
        }.store(in: &cancellables)
        // 定时检查发现新版本：“检查更新…”旁边加角标（温和提醒，不弹窗）。
        updates.status.$pendingVersion.removeDuplicates().sink { [weak self] version in
            self?.checkForUpdatesMenuItem?.badge = version.map { _ in NSMenuItemBadge(string: L10n.string("menu.updateBadge")) }
        }.store(in: &cancellables)
    }

    /// 切换界面语言：菜单整份重建，开着的窗口换标题。SwiftUI 界面自己观察 LanguageController 重新显示。
    /// 不重启、不重新加载网页，设置窗口里正在改的值都已存进 AppSettings，不受影响。
    private func bindLanguage() {
        languages.$language.dropFirst().removeDuplicates().sink { [weak self] language in
            guard let self else { return }
            self.diagnostics.log("app", "界面语言改为 \(language.rawValue)（设置：\(self.languages.preference.rawValue)）")
            self.buildMainMenu()
            self.retitleWindows()
            self.chatTabs.retitlePopups()
            self.updates.retitle()
        }.store(in: &cancellables)
    }

    private func retitleWindows() {
        settingsWindow?.title = L10n.string("window.settings")
        (settingsWindow?.contentViewController as? SettingsTabsController)?.relabel()
        aboutWindow?.title = L10n.string("menu.about")
        trialNotesWindow?.title = L10n.string("window.trialNotes")
        diagnosticsWindow?.title = L10n.string("window.diagnostics")
    }

    // MARK: - 后退、前进

    /// 后退、前进的目标页面：这次操作的窗口（key 窗口；没有 key 窗口时是 eventWindow，菜单没有）是聊天窗口时是它的页面，
    /// 登录弹窗、设置等其他窗口在前面时没有目标（见 HistoryNavigation.commandWindow、target）。
    /// 每次操作开始时调用一次，之后只对返回的页面操作：聊天窗口的页面是这一刻选中的标签页（ChatTabs.historyPage(commandWindow:)）。
    private func historyPage(eventWindow: NSWindow? = nil) -> WebRuntime? {
        let window = HistoryNavigation.commandWindow(keyWindow: NSApp.keyWindow, eventWindow: eventWindow)
        return chatTabs?.historyPage(commandWindow: window)
    }

    /// 菜单和顶部返回箭头都从这里走（⌘[ ⌘] 和鼠标侧键由聊天窗口处理，见 ChatWindowController）。
    private func goInHistory(_ direction: HistoryDirection, eventWindow: NSWindow? = nil, source: String) {
        guard let page = historyPage(eventWindow: eventWindow) else {
            diagnostics.log("nav", "\(direction.logName)（\(source)）：前面不是聊天窗口，不操作")
            return
        }
        page.go(direction, source: source)
    }

    /// 顶部返回箭头只在选中的标签页不是聊天页面、并且能后退时显示（ChatTabs.onBackButtonChange 交来）。
    private func backButtonChanged(_ shows: Bool, page: WebRuntime) {
        guard shows != toolbarState.showsBack else { return }
        toolbarState.showsBack = shows
        diagnostics.log("nav", "顶部返回箭头\(shows ? "显示" : "收起")：\(Redactor.describe(page.webView.url))")
    }

    // MARK: - 网页媒体监视与证据采集

    /// 每秒读取 WebKit 媒体播放状态（公开 API），仅显示，不控制。每次读这一刻选中的标签页，见 ChatTabs.mediaTick()。
    private func startMediaMonitor() {
        mediaTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.chatTabs.mediaTick()
            }
        }
    }

    /// 本机分布式通知触发脱敏证据采集并写入报告文件（供验证时由命令行触发；只读，不控制网页）。
    private func listenForEvidenceRequests() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.classiccompanion.collectEvidence"), object: nil, queue: .main
        ) { [weak self] note in
            let request = note.object as? String
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.collectEvidence(measure: request == "measure") }
            }
        }
    }

    /// 对开始这一刻选中的标签页采集，每一步都对它做（ChatTabs.collectEvidence(measure:)），然后写报告文件。
    func collectEvidence(measure: Bool) async {
        await chatTabs.collectEvidence(measure: measure)
        diagnostics.writeReportFile(build: Self.build)
    }

    /// 对开始这一刻选中的标签页做实验（ChatTabs.runExperiment(_:)，步骤见 PageEvidence），然后写报告文件。
    func runExperiment(_ kind: ExperimentKind) async {
        await chatTabs.runExperiment(kind)
        diagnostics.writeReportFile(build: Self.build)
    }

    // MARK: - 菜单

    private func buildMainMenu() {
        let built = Self.makeMainMenu(modeKey: settings.modeKey)
        modeMenuItem = built.modeItem
        checkForUpdatesMenuItem = built.updatesItem
        tabMenus.attach(built.tabItems)
        built.updatesItem.badge = updates.status.pendingVersion.map { _ in NSMenuItemBadge(string: L10n.string("menu.updateBadge")) }
        NSApp.mainMenu = built.menu
        NSApp.windowsMenu = built.windowMenu
    }

    /// 主菜单。切换语言时整份重建；动作和快捷键不随语言变（LocalizationTests 核对各语言一致）。
    /// 标签页的项（3.11）建成单个标签页时的样子（关闭标签页、关闭窗口 ⇧⌘W 藏着，不带快捷键：⌘W 只在原来那一项上），
    /// 目标、显示与否、快捷键之后由 TabMenus 改。
    static func makeMainMenu(modeKey: HotKeyCombo, language: AppLanguage = L10n.language)
        -> (menu: NSMenu, modeItem: NSMenuItem, windowMenu: NSMenu, updatesItem: NSMenuItem, tabItems: TabMenus.Items) {
        let t = { (key: String) in L10n.string(key, in: language) }
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: t("menu.about"), action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        let updatesItem = appMenu.addItem(withTitle: t("menu.checkForUpdates"), action: #selector(AppDelegate.checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: t("menu.settings"), action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: t("menu.diagnostics"), action: #selector(AppDelegate.showDiagnostics), keyEquivalent: "d").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: t("menu.hideApp"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: t("menu.hideOthers"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: t("menu.showAll"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: t("menu.file"))
        fileMenu.addItem(withTitle: t("menu.newChat"), action: #selector(AppDelegate.newChat), keyEquivalent: "n")
        let newTab = fileMenu.addItem(withTitle: t("menu.newTab"), action: #selector(TabMenus.newTab(_:)), keyEquivalent: "t")
        let reopenTab = fileMenu.addItem(withTitle: t("menu.reopenClosedTab"), action: #selector(TabMenus.reopenClosedTab(_:)),
                                         keyEquivalent: "t")
        reopenTab.keyEquivalentModifierMask = [.command, .shift]
        let modeEquivalent = modeKey.menuKeyEquivalent
        let modeItem = fileMenu.addItem(withTitle: t("menu.toggleMode"), action: #selector(AppDelegate.toggleMode), keyEquivalent: modeEquivalent?.key ?? "")
        modeItem.keyEquivalentModifierMask = modeEquivalent?.modifiers ?? []
        // 动作名不用 goBack:，那是 WKWebView 自己的动作：响应链会先找到网页（包括登录弹窗），不经过 historyPage。
        fileMenu.addItem(withTitle: t("menu.back"), action: #selector(AppDelegate.historyBack),
                         keyEquivalent: HistoryNavigation.menuKey(.back))
        fileMenu.addItem(withTitle: t("menu.forward"), action: #selector(AppDelegate.historyForward),
                         keyEquivalent: HistoryNavigation.menuKey(.forward))
        fileMenu.addItem(withTitle: t("menu.reload"), action: #selector(AppDelegate.reloadPage), keyEquivalent: "r")
        fileMenu.addItem(withTitle: t("menu.restartAudio"), action: #selector(AppDelegate.restartAudio), keyEquivalent: "")
        let closeWindow = fileMenu.addItem(withTitle: t("menu.closeWindow"), action: #selector(NSWindow.performClose(_:)),
                                           keyEquivalent: "w")
        // 多个标签页、聊天窗口在前面时代替上一项（TabMenuRules）。快捷键（⌘W、⇧⌘W）那时由 TabMenus 加上：同一个快捷键
        // 只能在一项上，主菜单里几项相同时 AppKit 只让先登记的那一项显示、接这个键。
        let closeTab = fileMenu.addItem(withTitle: t("menu.closeTab"), action: #selector(TabMenus.closeTab(_:)), keyEquivalent: "")
        closeTab.isHidden = true
        let hideKeepingTabs = fileMenu.addItem(withTitle: t("menu.closeWindow"), action: #selector(TabMenus.hideWindowKeepingTabs(_:)),
                                               keyEquivalent: "")
        hideKeepingTabs.isHidden = true
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Edit 菜单：使 ⌘C/⌘V/⌘A/⌘Z 在 WKWebView 中可用（菜单栏不显示时快捷键仍生效）
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: t("menu.edit"))
        editMenu.addItem(withTitle: t("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: t("menu.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: t("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: t("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: t("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: t("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: t("menu.view"))
        viewMenu.addItem(withTitle: t("menu.zoomIn"), action: #selector(AppDelegate.zoomIn), keyEquivalent: "+")
        // 美式键盘的 + 要按 Shift，直接按 ⌘= 也要能放大。
        let zoomInWithoutShift = viewMenu.addItem(withTitle: t("menu.zoomIn"), action: #selector(AppDelegate.zoomIn), keyEquivalent: "=")
        zoomInWithoutShift.isHidden = true
        zoomInWithoutShift.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(withTitle: t("menu.zoomOut"), action: #selector(AppDelegate.zoomOut), keyEquivalent: "-")
        viewMenu.addItem(withTitle: t("menu.actualSize"), action: #selector(AppDelegate.zoomToActualSize), keyEquivalent: "0")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: t("menu.window"))
        windowMenu.addItem(withTitle: t("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: t("menu.zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let nextTab = windowMenu.addItem(withTitle: t("menu.showNextTab"), action: #selector(TabMenus.showNextTab(_:)), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        let previousTab = windowMenu.addItem(withTitle: t("menu.showPreviousTab"), action: #selector(TabMenus.showPreviousTab(_:)),
                                             keyEquivalent: "\t")
        previousTab.keyEquivalentModifierMask = [.control, .shift]
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: t("menu.bringAllToFront"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        let tabItems = TabMenus.Items(newTab: newTab, reopenClosedTab: reopenTab, closeWindow: closeWindow, closeTab: closeTab,
                                      hideWindowKeepingTabs: hideKeepingTabs, nextTab: nextTab, previousTab: previousTab)
        return (main, modeItem, windowMenu, updatesItem, tabItems)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // 名称以 Template 结尾的资源由系统按菜单栏明暗着色。未打包运行时没有该资源，退回系统符号。
        let icon = NSImage(named: "MenuBarIconTemplate")
            ?? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Classic Companion")
        icon?.isTemplate = true
        icon?.accessibilityDescription = "Classic Companion"
        statusItem.button?.image = icon
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// 每次打开菜单栏菜单时按当前语言重建。
    func menuNeedsUpdate(_ menu: NSMenu) {
        Self.fillStatusMenu(menu, pendingUpdate: updates.status.pendingVersion)
        // “新建标签页”的目标是 TabMenus（先接上，下面就不改它的目标）。
        tabMenus.attachStatus(menu)
        for item in menu.items where item.target == nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }

    /// 菜单栏菜单。和主菜单相同的功能用相同的键，字一样。
    /// pendingUpdate：定时检查发现、还没看过的新版本。有的话最上面多一项，点了打开 Sparkle 的更新窗口。
    static func fillStatusMenu(_ menu: NSMenu, language: AppLanguage = L10n.language, pendingUpdate: String? = nil) {
        let t = { (key: String) in L10n.string(key, in: language) }
        menu.removeAllItems()
        if let pendingUpdate {
            menu.addItem(withTitle: L10n.format("menu.updateAvailable", in: language, pendingUpdate),
                         action: #selector(AppDelegate.checkForUpdates), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: t("menu.showQuick"), action: #selector(AppDelegate.showQuick), keyEquivalent: "")
        menu.addItem(withTitle: t("menu.openFull"), action: #selector(AppDelegate.showFull), keyEquivalent: "")
        menu.addItem(withTitle: t("menu.newChat"), action: #selector(AppDelegate.newChat), keyEquivalent: "")
        menu.addItem(withTitle: t("menu.newTab"), action: #selector(TabMenus.statusNewTab(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        // 决策 A：朗读只在网页内通过官方按钮开始和停止；菜单不显示播放状态（K11）
        menu.addItem(withTitle: t("menu.settings"), action: #selector(AppDelegate.showSettings), keyEquivalent: "")
        menu.addItem(withTitle: t("menu.diagnostics"), action: #selector(AppDelegate.showDiagnostics), keyEquivalent: "")
        menu.addItem(withTitle: t("menu.about"), action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    @objc private func zoomIn() { settings.pageZoom = PageZoom.zoomedIn(from: settings.pageZoom) }
    @objc private func zoomOut() { settings.pageZoom = PageZoom.zoomedOut(from: settings.pageZoom) }
    @objc private func zoomToActualSize() { settings.pageZoom = PageZoom.actualSize }
    @objc private func showQuick() { windowController.show(mode: .quick) }
    @objc private func showFull() { windowController.show(mode: .full) }
    @objc private func toggleMode() { windowController.toggleMode() }
    private func barDoubleClicked() {
        let action = BarDoubleClick.current
        diagnostics.log("window", "双击顶部：\(action)")
        switch action {
        case .toggleMode: windowController.toggleMode()
        case .minimize: windowController.window?.performMiniaturize(nil)
        case .none: break
        }
    }
    /// ⌘N、文件菜单、顶部的按钮、菜单栏图标的菜单：开在新标签页；开不了（到上限、启动画面还在）时对按下这一刻选中的标签页，
    /// 见 ChatTabs.newChat()。
    @objc private func newChat() { chatTabs.newChat() }
    /// ⌘R：按下这一刻选中的标签页。
    @objc private func reloadPage() { chatTabs.reloadSelectedTab() }
    /// 朗读没有声音时手动用（issue #16）。找不到媒体进程时响一声，窗口和页面不动。
    /// 媒体进程是全应用的网页视图共用的一个（推断：WebKit 的 GPU 进程每个应用一个），所以从按下这一刻选中的标签页找它；
    /// 结束以后所有标签页正在放的声音都会停。
    @objc private func restartAudio() { if !chatTabs.selected.runtime.restartMediaProcess() { NSSound.beep() } }
    /// 菜单作用于 key 窗口：聊天窗口在前面时是它的页面，登录弹窗等窗口在前面时没有目标（菜单项是灰的）。
    @objc private func historyBack() { goInHistory(.back, source: "菜单") }
    @objc private func historyForward() { goInHistory(.forward, source: "菜单") }
    @objc private func checkForUpdates() { updates.checkForUpdates() }

    /// 菜单项“后退”“前进”对应的方向，其他菜单项是 nil。
    static func historyDirection(of action: Selector?) -> HistoryDirection? {
        if action == #selector(AppDelegate.historyBack) { return .back }
        if action == #selector(AppDelegate.historyForward) { return .forward }
        return nil
    }

    /// “检查更新…”跟随 Sparkle 的 canCheckForUpdates（等确认安装时也可用，用来叫回确认窗口）；
    /// 没有更新配置的构建里灰掉。“后退”“前进”跟随 key 窗口那一页的 canGoBack / canGoForward，
    /// 登录弹窗等其他窗口在前面时灰掉。其余菜单项照旧可用。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let direction = Self.historyDirection(of: menuItem.action) {
            return HistoryNavigation.isAvailable(direction, on: historyPage())
        }
        guard menuItem.action == #selector(checkForUpdates) else { return true }
        guard let status = updates?.status else { return false }
        return status.canCheck || status.awaitingInstallDecision
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let tabs = SettingsTabsController { [unowned self] pane in
                let host = NSHostingController(rootView: SettingsPaneView(
                    pane: pane, settings: settings, diagnostics: diagnostics, updates: updates.status,
                    hotKeyRecorder: hotKeyRecorder, modeKeyRecorder: modeKeyRecorder,
                    onShowDiagnostics: { [weak self] in self?.showDiagnostics() }))
                // 大小由窗口定（fitSettingsToScreen），页面内容不去撑窗口。
                host.sizingOptions = []
                return host
            }
            tabs.onLeavePane = { [weak self] pane in
                guard let self, pane == .shortcuts else { return }
                self.hotKeyRecorder.cancel("离开快捷键页")
                self.modeKeyRecorder.cancel("离开快捷键页")
            }
            let w = SettingsTabsController.makeWindow(tabs)
            w.delegate = self
            settingsWindow = w
        }
        ChatWindowController.forceActivate()
        fitSettingsToScreen()
        settingsWindow?.center()
        // center() 可能把窗口放到另一块屏幕上，按那块屏幕再算一次。
        if fitSettingsToScreen() { settingsWindow?.center() }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// 设置窗口用固定的首选大小；所在屏幕放不下时只缩内容区。高度变了返回 true。
    @discardableResult
    private func fitSettingsToScreen() -> Bool {
        guard let window = settingsWindow, let screen = window.screen ?? NSScreen.main else { return false }
        return SettingsTabsController.fit(window, screenVisibleHeight: screen.visibleFrame.height)
    }

    /// 拖到另一块屏幕时按那块屏幕的高度重新限制。
    func windowDidChangeScreen(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        fitSettingsToScreen()
    }

    @objc private func showAbout() {
        if aboutWindow == nil {
            let view = AboutView(info: .current,
                                 onShowTrialNotes: { [weak self] in self?.showTrialNotes() },
                                 onShowDiagnostics: { [weak self] in self?.showDiagnostics() })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = L10n.string("menu.about")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            aboutWindow = w
        }
        ChatWindowController.forceActivate()
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    private func showTrialNotes() {
        if trialNotesWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: TrialNotesView()))
            w.title = L10n.string("window.trialNotes")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            trialNotesWindow = w
        }
        ChatWindowController.forceActivate()
        trialNotesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showDiagnostics() {
        if diagnosticsWindow == nil {
            let view = DiagnosticsView(diagnostics: diagnostics, build: Self.build,
                                       onCollect: { [weak self] in
                                           guard let self else { return }
                                           Task { await self.collectEvidence(measure: false) }
                                       },
                                       onExperiment: { [weak self] kind in
                                           guard let self else { return }
                                           Task { await self.runExperiment(kind) }
                                       })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = L10n.string("window.diagnostics")
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            diagnosticsWindow = w
        }
        Task { await collectEvidence(measure: false) }
        ChatWindowController.forceActivate()
        diagnosticsWindow?.makeKeyAndOrderFront(nil)
    }
}

enum ExperimentKind {
    case suspendAll, resumeAll, pauseAll, measure
    case setRate(Double)
}

/// 网页媒体状态（来自 WKWebView.requestMediaPlaybackState），仅用于诊断日志。
/// 无法区分来源，且挂起再恢复后可能显示 playing 但实际无声（K11），不得作为界面上的播放状态。
@MainActor
final class WebMediaMonitor: ObservableObject {
    @Published var state = "none"

    static func label(_ s: String) -> String {
        switch s {
        case "none": "无"
        case "playing": "播放中"
        case "paused": "已暂停"
        case "suspended": "已挂起"
        default: "未知"
        }
    }
}
