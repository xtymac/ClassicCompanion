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
    private var web: WebRuntime!
    private var adapter: ChatGPTAdapter!
    private let media = WebMediaMonitor()
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
    private var lastPath: String?
    private var focusTask: Task<Void, Never>?
    #if DEBUG
    private var debugDriver: DebugDriver?   // TEMPORARY investigation hook，只在开发版
    #endif

    static var build: String { AppInfo.current.summary }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        diagnostics.log("app", "启动 构建 \(Self.build)")
        diagnostics.log("app", "界面语言 \(languages.language.rawValue)（设置：\(languages.preference.rawValue)，系统：\(Locale.preferredLanguages.prefix(3).joined(separator: ","))）")

        web = WebRuntime(diagnostics: diagnostics, settings: settings)
        adapter = ChatGPTAdapter(webView: web.webView, diagnostics: diagnostics, settings: settings)
        // 系统 TTS（SpeechController）已退出正式路径：1.2 版要求使用官方 Read Aloud，不实例化、不回退。

        let bar = WebBar(onClose: { [weak self] in self?.windowController.hide(reason: "顶部关闭按钮") },
                         onNewChat: { [weak self] in self?.newChat() },
                         onToggleMode: { [weak self] in self?.windowController.toggleMode() },
                         onDoubleClick: { [weak self] in self?.barDoubleClicked() },
                         onBarPress: { [weak self] count, moved in
                             self?.diagnostics.log("window", "顶部按下：第 \(count) 下\(moved ? "，拖动了窗口" : "")")
                         },
                         state: toolbarState, appearance: pageAppearance)
        windowController = ChatWindowController(webView: web.webView, toolbar: bar, diagnostics: diagnostics,
                                                appearance: pageAppearance)
        windowController.onWillShow = { [weak self] mode in self?.toolbarState.quick = mode == .quick }
        windowController.onDidMiniaturize = { [weak self] in self?.releaseForegroundIfWindowless() }
        windowController.onWillChangeLayout = { [weak self] in self?.web.holdReadingPosition() }
        windowController.onDidChangeLayout = { [weak self] in self?.web.restoreReadingPosition() }
        windowController.onSnapshotPage = { [weak self] done in
            guard let self else { return done(nil) }
            self.web.snapshotPage(done)
        }
        windowController.onPrepareLayout = { [weak self] size, done in
            guard let self else { return done() }
            self.web.prepareLayout(size: size, done: done)
        }
        windowController.onDidShow = { [weak self] kind in
            self?.focusInputSoon()
            self?.web.windowShown(kind)
        }

        web.onURLChange = { [weak self] url in self?.urlChanged(url) }
        web.onEscapeRequest = { [weak self] in self?.windowController.hide(reason: "网页 Esc") }
        // 页面加载完成时结束启动画面；若窗口在前台，再尝试聚焦一次（唤醒时页面可能尚未就绪）
        web.onMainFrameLoaded = { [weak self] in
            guard let self else { return }
            self.windowController.endLaunchScreen("网页已加载")
            // 网页第一次加载完成才恢复跟随页面底色；加载失败、启动画面到时限都不恢复，等之后哪次加载完成。
            self.windowController.pageDidFinishLoading()
            if self.windowController.isKey { self.focusInputSoon() }
        }
        // 加载失败时结束启动画面。WebKit 不显示错误页：首次加载失败时窗口里没有页面，
        // 由 WebRuntime 自动重试（退避、限次、断网不发请求），窗口盖“无法连接”提示，⌘R 和提示里的按钮显式加载失败的地址
        // （2026-11-11 开机白屏）。
        web.onLoadFailed = { [weak self] in self?.windowController.endLaunchScreen("加载失败") }
        web.onLoadProblemChange = { [weak self] status in self?.windowController.showLoadProblem(status) }
        windowController.onReloadRequest = { [weak self] in self?.web.reload() }
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
            debugDriver = DebugDriver(windowController: windowController, webView: web.webView)
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
        web.load(start)
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
        }.store(in: &cancellables)
        Publishers.CombineLatest(settings.$webEnhancements, settings.$escapeHidesWindow)
            .dropFirst()
            .sink { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.web.applyEnhancementScripts()
                }
            }.store(in: &cancellables)
        settings.$pageZoom.dropFirst().removeDuplicates().sink { [weak self] zoom in
            DispatchQueue.main.async { self?.web.setPageZoom(zoom) }
        }.store(in: &cancellables)
        settings.$allowPageAccessibility.dropFirst().removeDuplicates().sink { [weak self] allowed in
            DispatchQueue.main.async { self?.web.setPageAccessibilityAllowed(allowed) }
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
            self.web.retitlePopups()
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

    private func urlChanged(_ url: URL?) {
        if let restorable = NavigationPolicy.restorableConversationURL(url) {
            settings.lastConversationURL = restorable
        }
        // 仅路径变化视为切换页面（忽略 query 变化）
        let path = url.map { "\($0.host ?? "")\($0.path)" }
        guard path != lastPath else { return }
        let previous = lastPath
        lastPath = path
        adapter.invalidate()
        diagnostics.log("nav", "页面变化 \(Redactor.describe(url))")
        // 记录导航时网页媒体状态，用于验证“切换对话后官方朗读是否停止”（不主动干预）
        if previous != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self else { return }
                self.diagnostics.log("media", "页面变化后 0.8s WebKit 媒体状态=\(await self.adapter.webMediaState())")
            }
        }
    }

    private func focusInputSoon() {
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            let result = await self.adapter.focusInput()
            self.diagnostics.recordInputFocus(result)
        }
    }

    // MARK: - 网页媒体监视与证据采集

    /// 每秒读取 WebKit 媒体播放状态（公开 API），仅显示，不控制。
    private func startMediaMonitor() {
        mediaTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    let state = await self.adapter.webMediaState()
                    self.diagnostics.webMediaState = state
                    if state != self.media.state {
                        self.diagnostics.log("media", "WebKit 媒体状态 \(self.media.state) → \(state)（窗口可见=\(self.windowController.window?.isVisible ?? false)）")
                        self.media.state = state
                    }
                }
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

    func collectEvidence(measure: Bool) async {
        await adapter.probe()
        diagnostics.readAloudEvidence = await adapter.readAloudEvidence()
        if measure { diagnostics.mediaMeasurement = await adapter.measureMedia() }
        diagnostics.writeReportFile(build: Self.build)
    }

    func runExperiment(_ kind: ExperimentKind) async {
        let wv = web.webView
        switch kind {
        case .suspendAll:
            await wv.setAllMediaPlaybackSuspended(true)
            diagnostics.recordExperiment("WebKit setAllMediaPlaybackSuspended(true) → 状态 \(await adapter.webMediaState())")
        case .resumeAll:
            await wv.setAllMediaPlaybackSuspended(false)
            diagnostics.recordExperiment("WebKit setAllMediaPlaybackSuspended(false) → 状态 \(await adapter.webMediaState())")
        case .pauseAll:
            await wv.pauseAllMediaPlayback()
            diagnostics.recordExperiment("WebKit pauseAllMediaPlayback → 状态 \(await adapter.webMediaState())")
        case .setRate(let r):
            diagnostics.recordExperiment("DOM playbackRate=\(r)：\(await adapter.experimentSetRate(r))")
        case .measure:
            diagnostics.mediaMeasurement = await adapter.measureMedia()
            diagnostics.recordExperiment("测量：\(diagnostics.mediaMeasurement)")
        }
        diagnostics.writeReportFile(build: Self.build)
    }

    // MARK: - 菜单

    private func buildMainMenu() {
        let built = Self.makeMainMenu(modeKey: settings.modeKey)
        modeMenuItem = built.modeItem
        checkForUpdatesMenuItem = built.updatesItem
        built.updatesItem.badge = updates.status.pendingVersion.map { _ in NSMenuItemBadge(string: L10n.string("menu.updateBadge")) }
        NSApp.mainMenu = built.menu
        NSApp.windowsMenu = built.windowMenu
    }

    /// 主菜单。切换语言时整份重建；动作和快捷键不随语言变（LocalizationTests 核对各语言一致）。
    static func makeMainMenu(modeKey: HotKeyCombo, language: AppLanguage = L10n.language)
        -> (menu: NSMenu, modeItem: NSMenuItem, windowMenu: NSMenu, updatesItem: NSMenuItem) {
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
        let modeEquivalent = modeKey.menuKeyEquivalent
        let modeItem = fileMenu.addItem(withTitle: t("menu.toggleMode"), action: #selector(AppDelegate.toggleMode), keyEquivalent: modeEquivalent?.key ?? "")
        modeItem.keyEquivalentModifierMask = modeEquivalent?.modifiers ?? []
        fileMenu.addItem(withTitle: t("menu.reload"), action: #selector(AppDelegate.reloadPage), keyEquivalent: "r")
        fileMenu.addItem(withTitle: t("menu.closeWindow"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        windowMenu.addItem(withTitle: t("menu.bringAllToFront"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return (main, modeItem, windowMenu, updatesItem)
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
    @objc private func newChat() {
        Task { [weak self] in
            guard let self else { return }
            guard await self.adapter.openNewChatInPage() else { self.web.newChat(); return }
            self.focusInputSoon()
        }
    }
    @objc private func reloadPage() { web.reload() }
    @objc private func checkForUpdates() { updates.checkForUpdates() }

    /// “检查更新…”跟随 Sparkle 的 canCheckForUpdates（等确认安装时也可用，用来叫回确认窗口）；
    /// 没有更新配置的构建里灰掉。其余菜单项照旧可用。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
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
