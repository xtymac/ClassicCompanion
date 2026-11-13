import AppKit
import SwiftUI
import CompanionCore

/// 设置分三页（用户 2026-11-10）：通用、快捷键、高级。顺序就是窗口工具栏里的顺序。
/// 每页显示什么由 sections 决定，SettingsPaneView 照着画，测试也照着核对每个选项的去处。
enum SettingsPane: Int, CaseIterable {
    case general, shortcuts, advanced

    func title(in language: AppLanguage? = nil) -> String {
        switch self {
        case .general: L10n.string("settings.pane.general", in: language)
        case .shortcuts: L10n.string("settings.pane.shortcuts", in: language)
        case .advanced: L10n.string("settings.pane.advanced", in: language)
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .advanced: "gearshape.2"
        }
    }

    /// 每页分几组，组内按顺序显示。
    var sections: [[SettingsItem]] {
        switch self {
        case .general: [[.appLanguage, .pageZoom], [.restoreLastConversation, .focusInputOnShow, .escapeHidesWindow],
                        [.automaticUpdateChecks]]
        case .shortcuts: [[.wakeShortcut, .modeShortcut]]
        case .advanced: [[.webEnhancements], [.allowPageAccessibility], [.diagnostics]]
        }
    }

    var items: [SettingsItem] { sections.flatMap { $0 } }
}

/// 设置里每一个能改或能点的项目。存储键沿用原来的，不改名、不改默认值。
enum SettingsItem: CaseIterable {
    case appLanguage, pageZoom, restoreLastConversation, focusInputOnShow, escapeHidesWindow, automaticUpdateChecks
    case wakeShortcut, modeShortcut
    case webEnhancements, allowPageAccessibility, diagnostics

    var storageKeys: [String] {
        switch self {
        case .appLanguage: [LanguagePreference.defaultsKey]
        case .pageZoom: ["pageZoom"]
        case .restoreLastConversation: ["restoreLastConversation"]
        case .focusInputOnShow: ["focusInputOnShow"]
        case .escapeHidesWindow: ["escapeHidesWindow"]
        // Sparkle 自己保存（首次询问的回答和这个开关是同一个值），不在 AppSettings 里。
        case .automaticUpdateChecks: ["SUEnableAutomaticChecks"]
        case .wakeShortcut: ["hotKeyCode", "hotKeyModifiers"]
        case .modeShortcut: ["modeKeyCode", "modeKeyModifiers"]
        case .webEnhancements: ["webEnhancements"]
        case .allowPageAccessibility: ["allowPageAccessibility"]
        case .diagnostics: []
        }
    }

    /// 只在网页增强开着时起作用（ChatGPTAdapter、WebRuntime 里都先看网页增强）。
    var requiresWebEnhancements: Bool { self == .focusInputOnShow || self == .escapeHidesWindow }

    /// 不可用时只是灰掉，存着的值不动，重新打开网页增强后原样生效。
    @MainActor func isAvailable(in settings: AppSettings) -> Bool {
        !requiresWebEnhancements || settings.webEnhancements
    }
}

/// 设置窗口的大小。不再按整张表单的高度定：每页都放得下的固定首选高度，屏幕矮时只缩内容区，内容区自己滚动。
enum SettingsWindowLayout {
    /// 各语言里最长的一行（日文的快捷键名称加“恢复默认”）也不截断；宽度不随语言和页面变，切换时窗口不跳。
    static let width: CGFloat = 500
    /// 四种语言里最高的一页（“了解更多”收起时）也不用滚动。SettingsLayoutTests 逐页核对。
    /// 通用页加了“更新”一组（英文、日文 425 pt；发现新版本时再多一行“查看更新…”，480 pt），从 400 调到 480。
    static let contentHeight: CGFloat = 480
    /// 再矮的屏幕也留出能用的高度。
    static let minimumContentHeight: CGFloat = 220
    /// 窗口上下各留一点空。
    static let screenMargin: CGFloat = 40

    /// chrome：标题栏加工具栏的高度。
    static func contentHeight(screenVisibleHeight: CGFloat, chrome: CGFloat) -> CGFloat {
        max(minimumContentHeight, min(contentHeight, screenVisibleHeight - chrome - screenMargin))
    }
}

/// 窗口工具栏里的三页切换（系统原生的偏好设置样式）。窗口标题保持“Classic Companion 设置”，不换成页面名。
@MainActor
final class SettingsTabsController: NSTabViewController {
    /// 离开某一页时调用。离开快捷键页要结束录制：页面看不见了，按键不能再被录走。
    var onLeavePane: (SettingsPane) -> Void = { _ in }
    private var shownPane = SettingsPane.general

    init(makePane: (SettingsPane) -> NSViewController) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = false
        transitionOptions = []
        for pane in SettingsPane.allCases {
            let item = NSTabViewItem(viewController: makePane(pane))
            // 工具栏用它当项目标识，必须是字符串（数字会在窗口显示工具栏时崩溃）。
            item.identifier = "settings.pane.\(pane)"
            item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil)
            addTabViewItem(item)
        }
        relabel()
        // 先建好视图，选页面时才会经过 tabView(_:didSelect:)。
        _ = view
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var selectedPane: SettingsPane {
        get { SettingsPane(rawValue: selectedTabViewItemIndex) ?? .general }
        set { selectedTabViewItemIndex = newValue.rawValue }
    }

    /// 切换界面语言时调用：只换页面名，当前页面和页面里正在改的内容不动。
    func relabel() {
        for (item, pane) in zip(tabViewItems, SettingsPane.allCases) {
            item.label = pane.title()
        }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        let now = selectedPane
        guard now != shownPane else { return }
        let left = shownPane
        shownPane = now
        onLeavePane(left)
    }

    /// 设置窗口：系统偏好设置样式的工具栏，标题“Classic Companion 设置”。
    static func makeWindow(_ tabs: SettingsTabsController) -> NSWindow {
        let window = NSWindow(contentViewController: tabs)
        window.title = L10n.string("window.settings")
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        return window
    }

    /// 内容区用固定的首选大小；屏幕放不下时只缩内容区（页面自己滚动），工具栏始终在。大小变了返回 true。
    @discardableResult
    static func fit(_ window: NSWindow, screenVisibleHeight: CGFloat) -> Bool {
        guard let content = window.contentView else { return false }
        let chrome = window.frame.height - content.frame.height
        let size = NSSize(width: SettingsWindowLayout.width,
                          height: SettingsWindowLayout.contentHeight(screenVisibleHeight: screenVisibleHeight, chrome: chrome))
        for item in (window.contentViewController as? NSTabViewController)?.tabViewItems ?? [] {
            item.viewController?.preferredContentSize = size
        }
        guard content.frame.size != size else { return false }
        window.setContentSize(size)
        return true
    }
}

struct SettingsPaneView: View {
    let pane: SettingsPane
    @ObservedObject var settings: AppSettings
    @ObservedObject var diagnostics: Diagnostics
    @ObservedObject var updates: UpdateStatus
    @ObservedObject var hotKeyRecorder: HotKeyRecorderModel
    @ObservedObject var modeKeyRecorder: HotKeyRecorderModel
    let onShowDiagnostics: () -> Void
    @ObservedObject private var languages = LanguageController.shared
    /// “了解更多”默认收起。切换语言时保留展开状态。
    @State private var showsAssistiveDetails = false

    var body: some View {
        Form {
            ForEach(Array(pane.sections.enumerated()), id: \.offset) { _, items in
                if let header = header(for: items) {
                    Section {
                        rows(items)
                    } header: {
                        Text(header)
                    }
                } else if let footer = footer(for: items) {
                    Section {
                        rows(items)
                    } footer: {
                        Text(footer)
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Section { rows(items) }
                }
            }
        }
        .formStyle(.grouped)
        .environment(\.locale, languages.locale)
        .frame(width: SettingsWindowLayout.width)
        .frame(maxHeight: .infinity)
        // 切到别的窗口或应用时结束录制，旧键回来。离开这一页、关闭设置窗口由 AppDelegate 处理。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            guard pane == .shortcuts else { return }
            hotKeyRecorder.focusLost()
            modeKeyRecorder.focusLost()
        }
    }

    private func rows(_ items: [SettingsItem]) -> some View {
        ForEach(items, id: \.self) { row($0) }
    }

    /// 只有“更新”一组带标题（用户要求的分组名）；其他组保持原样。
    private func header(for items: [SettingsItem]) -> String? {
        items.contains(.automaticUpdateChecks) ? L10n.string("settings.section.updates") : nil
    }

    private func footer(for items: [SettingsItem]) -> String? {
        if items.contains(.wakeShortcut) { return L10n.string("settings.shortcut.footer") }
        if items.contains(where: { !$0.isAvailable(in: settings) }) { return L10n.string("settings.web.dependencyNote") }
        return nil
    }

    @ViewBuilder private func row(_ item: SettingsItem) -> some View {
        switch item {
        case .appLanguage:
            // 放在第一页最前面：界面看不懂的人也要找得到。语言名总是用它自己的语言写。
            Picker(selection: $languages.preference) {
                ForEach(LanguagePreference.allCases, id: \.self) { Text($0.title(in: languages.language)).tag($0) }
            } label: {
                Text(L10n.string("settings.appLanguage"))
                Text(L10n.string("settings.language.note"))
            }
        case .pageZoom:
            Picker(selection: $settings.pageZoom) {
                ForEach(PageZoom.levels, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
            } label: {
                Text(L10n.string("settings.pageZoom"))
                Text(L10n.string("settings.pageZoom.note"))
            }
        case .restoreLastConversation:
            Toggle(L10n.string("settings.session.restore"), isOn: $settings.restoreLastConversation)
        case .focusInputOnShow:
            dependentToggle(L10n.string("settings.web.focus"), isOn: $settings.focusInputOnShow, item: item)
        case .escapeHidesWindow:
            dependentToggle(L10n.string("settings.web.escape"), isOn: $settings.escapeHidesWindow, item: item)
        case .automaticUpdateChecks:
            // 直接读写 Sparkle 的 automaticallyChecksForUpdates：首次询问的回答、这里的开关和菜单是同一个值。
            Toggle(isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.setAutomaticChecks($0) })) {
                Text(L10n.string("settings.updates.automatic"))
                Text(L10n.string(updates.isAvailable ? "settings.updates.note" : "settings.updates.unavailable"))
            }
            .disabled(!updates.isAvailable)
            if let version = updates.pendingVersion {
                LabeledContent {
                    Button(L10n.string("settings.updates.show")) { updates.checkForUpdates() }
                } label: {
                    Text(L10n.format("settings.updates.available", version))
                }
            }
        case .wakeShortcut:
            hotKeyRow(L10n.string("settings.shortcut.wake"), model: hotKeyRecorder, combo: settings.hotKey,
                      name: L10n.string("settings.shortcut.wakeName"), isDefault: settings.hotKey == .standard, note: wakeNote)
        case .modeShortcut:
            hotKeyRow(L10n.string("settings.shortcut.mode"), model: modeKeyRecorder, combo: settings.modeKey,
                      name: L10n.string("settings.shortcut.modeName"), isDefault: settings.modeKey == .modeStandard, note: modeNote)
        case .webEnhancements:
            Toggle(isOn: $settings.webEnhancements) {
                Text(L10n.string("settings.web.enable"))
                Text(L10n.string("settings.web.note"))
            }
        case .allowPageAccessibility:
            Toggle(isOn: $settings.allowPageAccessibility) {
                Text(L10n.string("settings.assistive.allow"))
                Text(L10n.string("settings.assistive.purpose"))
            }
            // 性能影响和重启要求收在这里，不常驻。用按钮而不是 DisclosureGroup：
            // 实机上表单里的 DisclosureGroup 没有读屏能按的动作，键盘焦点环也画到了卡片外面。
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    showsAssistiveDetails.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showsAssistiveDetails ? 90 : 0))
                            .accessibilityHidden(true)
                        Text(L10n.string("settings.assistive.learnMore"))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(L10n.string(showsAssistiveDetails ? "settings.assistive.expanded" : "settings.assistive.collapsed"))
                if showsAssistiveDetails {
                    Text(L10n.string("settings.assistive.details"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .diagnostics:
            LabeledContent {
                Button(L10n.string("settings.diagnostics.open"), action: onShowDiagnostics)
            } label: {
                Text(L10n.string("settings.section.diagnostics"))
                Text(L10n.string("settings.diagnostics.note"))
            }
        }
    }

    /// 网页增强关着时灰掉，值不动；读屏也会读到原因。
    private func dependentToggle(_ title: String, isOn: Binding<Bool>, item: SettingsItem) -> some View {
        let available = item.isAvailable(in: settings)
        // 标签也换成次要色：只靠开关本身变灰，在窗口不在前台时看不出区别（预览探针实测两者亮度相同）。
        return Toggle(isOn: isOn) {
            Text(title).foregroundStyle(available ? .primary : .secondary)
        }
            .disabled(!available)
            .accessibilityHint(available ? "" : L10n.string("settings.web.requiredHint"))
    }

    /// 每行下面一直有一行字（错误、提示或这一行的说明），内容变化时高度基本不跳。
    private func hotKeyRow(_ title: String, model: HotKeyRecorderModel, combo: HotKeyCombo, name: String,
                           isDefault: Bool, note: HotKeyNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    HotKeyField(model: model, combo: combo, name: name)
                    Button(L10n.string("settings.shortcut.reset")) { model.reset() }
                        .disabled(isDefault)
                }
            }
            Text(note.text.string())
                .font(.caption)
                .foregroundStyle(note.tone.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var wakeNote: HotKeyNote {
        // 只有唤醒键向系统注册。录制时暂停注册，不算失败。
        let failed = diagnostics.hotKeyRegistration != noErr
        let recording = hotKeyRecorder.recording || modeKeyRecorder.recording
        return HotKeyNote.make(message: hotKeyRecorder.message, notice: hotKeyRecorder.notice,
                               recording: hotKeyRecorder.recording,
                               registrationError: failed && !recording ? GlobalHotKey.statusText(diagnostics.hotKeyRegistration) : nil,
                               idle: HotKeyNote.wakeIdle)
    }

    private var modeNote: HotKeyNote {
        HotKeyNote.make(message: modeKeyRecorder.message, notice: modeKeyRecorder.notice,
                        recording: modeKeyRecorder.recording, registrationError: nil, idle: HotKeyNote.modeIdle)
    }
}

private extension HotKeyNote.Tone {
    /// 橙色：改成功了，但别的应用也会打开。红色只用于没改成功。
    var color: Color {
        switch self {
        case .normal: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
