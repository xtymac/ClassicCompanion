import AppKit
import CompanionCore

/// 标签页的菜单项（3.11）：文件菜单的“新建标签页 ⌘T”“重新打开最近关闭的标签页 ⇧⌘T”“关闭标签页 ⌘W”“关闭窗口 ⇧⌘W”
/// （和原来那一项“关闭窗口 ⌘W”轮换），窗口菜单的“显示下一个标签页 ⌃Tab”“显示上一个标签页 ⌃⇧Tab”，
/// 菜单栏图标的菜单的“新建标签页”。还有左上角 × 的提示里写的键（ToolbarState.hideShortcut）。
///
/// 每一项什么样子（显不显示、能不能点、显不显示快捷键、下面写不写“最多打开 N 个标签页”）由 TabMenuRules 按这一刻的情形定；
/// 这里只取情形（state()）、改菜单项（refresh()）、照做。点了调用 ChatTabs 和按键相同的入口（不经 handleKey）：
/// newTab()、reopenClosedTab()、closeSelectedTab()、hideWindowKeepingTabs(_:)、selectNextTab()、selectPreviousTab()。
/// 每次点写一行“[menu] 菜单 …”（只有项的名字）。点的时候再按这一刻的情形看一遍能不能做（菜单可能是一会儿之前验证的）；
/// 不能做、或者是按住不放的重复按键（快捷键）：写一行，不做。
///
/// 按键在聊天窗口里先由窗口的按键监视处理（TabKeys），到不了菜单；菜单的快捷键只是写在菜单上给人看。别的窗口在前面时
/// 标签页的项不显示快捷键（TabMenuRules），所以菜单也不会在那里接这些键：那里的 ⌘W 照原来关那个窗口（D11），⌃Tab 等照原来。
///
/// 什么时候改菜单项：建主菜单（attach(_:)，切换语言时重建也是）、打开菜单栏图标的菜单（attachStatus(_:)）、标签页的个数变了
/// （ChatTabs.onTabsChanged）、key 窗口变了（通知）、文件菜单和窗口菜单要显示或查快捷键之前（menuNeedsUpdate）、
/// 唤醒键和切换键改了（AppDelegate）、点了以后。
@MainActor
final class TabMenus: NSObject, NSMenuItemValidation, NSMenuDelegate {
    /// 主菜单里的标签页的项（AppDelegate.makeMainMenu 建，attach(_:) 接上）。
    struct Items {
        let newTab: NSMenuItem
        let reopenClosedTab: NSMenuItem
        /// 原来那一项“关闭窗口 ⌘W”（performClose，交给 key 窗口）。不由这里点，只改显示不显示。
        let closeWindow: NSMenuItem
        let closeTab: NSMenuItem
        let hideWindowKeepingTabs: NSMenuItem
        let nextTab: NSMenuItem
        let previousTab: NSMenuItem

        var all: [(TabMenuRules.Item, NSMenuItem)] {
            [(.newTab, newTab), (.reopenClosedTab, reopenClosedTab), (.closeWindow, closeWindow), (.closeTab, closeTab),
             (.hideWindowKeepingTabs, hideWindowKeepingTabs), (.nextTab, nextTab), (.previousTab, previousTab)]
        }
    }

    /// 每一项的快捷键：字符小写、⇧ 写在修饰键里（和 HotKeyCombo.menuKeyEquivalent 一样，好和用户的键比）。
    /// 菜单栏图标的菜单里的那一项没有。
    static let keyEquivalents: [TabMenuRules.Item: (key: String, modifiers: NSEvent.ModifierFlags)] = [
        .newTab: ("t", [.command]),
        .reopenClosedTab: ("t", [.command, .shift]),
        .closeWindow: ("w", [.command]),
        .closeTab: ("w", [.command]),
        .hideWindowKeepingTabs: ("w", [.command, .shift]),
        .nextTab: ("\t", [.control]),
        .previousTab: ("\t", [.control, .shift]),
    ]

    private let tabs: ChatTabs
    private weak var chatWindow: NSWindow?
    private let diagnostics: Diagnostics
    private let toolbar: ToolbarState?
    /// 接上的主菜单的项（测试看）。
    private(set) var items: Items?
    /// 菜单栏图标的菜单里的“新建标签页”（每次打开那个菜单都重建）。
    private(set) weak var statusNewTab: NSMenuItem?

    /// 这一刻的 key 窗口。就是 NSApp.keyWindow；只有测试换它（测试不让窗口成为 key 窗口）。
    var keyWindow: @MainActor () -> NSWindow? = { NSApp.keyWindow }
    /// 有没有应用级的模态框。就是 NSApp.modalWindow；只有测试换它。
    var isAppModal: @MainActor () -> Bool = { NSApp.modalWindow != nil }
    /// 用户自己的唤醒键和切换键。AppDelegate 交进来（settings 的 hotKey、modeKey）；没交时没有。
    var userHotKeys: @MainActor () -> [HotKeyCombo] = { [] }
    /// 现在处理的是不是按住不放的重复按键（菜单的快捷键）。就是 NSApp.currentEvent；只有测试换它。
    var currentEventIsRepeat: @MainActor () -> Bool = {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    init(tabs: ChatTabs, chatWindow: NSWindow?, diagnostics: Diagnostics, toolbar: ToolbarState?) {
        self.tabs = tabs
        self.chatWindow = chatWindow
        self.diagnostics = diagnostics
        self.toolbar = toolbar
        super.init()
        // key 窗口变了：别的窗口在前面时这些项置灰、不显示快捷键（这样的通知注册在对象释放时自己去掉）。
        NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged(_:)),
                                               name: NSWindow.didResignKeyNotification, object: nil)
    }

    @objc private func keyWindowChanged(_ notification: Notification) {
        refresh()
    }

    /// 接上主菜单里的项（建主菜单、切换语言重建以后）：目标是这里，文件菜单和窗口菜单的代理是这里，按这一刻的情形改一遍。
    func attach(_ items: Items) {
        self.items = items
        for (item, menuItem) in items.all where item != .closeWindow {
            menuItem.target = self
        }
        items.newTab.menu?.delegate = self
        items.nextTab.menu?.delegate = self
        refresh()
    }

    /// 接上菜单栏图标的菜单（每次打开时重建以后）：找到“新建标签页”那一项，目标是这里，按这一刻的情形改。
    func attachStatus(_ menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.action == #selector(statusNewTab(_:)) }) else { return }
        item.target = self
        statusNewTab = item
        apply(.statusNewTab, to: item, in: state())
    }

    // MARK: - 情形和样子

    /// 这一刻哪个窗口在前面：聊天窗口是 key 窗口、上面没有表单才算聊天窗口；没有 key 窗口；别的都算别的窗口
    /// （包括聊天窗口还是主窗口、但文件选择等别的窗口是 key 窗口的时候）。
    func scope() -> TabMenuRules.Scope {
        guard let key = keyWindow() else { return .noWindow }
        guard let chatWindow, key === chatWindow, chatWindow.attachedSheet == nil else { return .otherWindow }
        return .chatWindow
    }

    /// 用户的唤醒键、切换键就是哪几项的组合（按菜单的快捷键比：字符和修饰键）。
    func takenByUserHotKey() -> Set<TabMenuRules.Item> {
        let user = userHotKeys().compactMap(\.menuKeyEquivalent)
        var taken: Set<TabMenuRules.Item> = []
        for (item, key) in Self.keyEquivalents where user.contains(where: { $0.key == key.key && $0.modifiers == key.modifiers }) {
            taken.insert(item)
        }
        return taken
    }

    func state() -> TabMenuRules.State {
        TabMenuRules.State(scope: scope(), appModal: isAppModal(), launchScreenUp: tabs.isLaunchScreenUp,
                           atLimit: tabs.list.isFull, canReopen: tabs.canReopenClosedTab, tabCount: tabs.tabs.count,
                           takenByUserHotKey: takenByUserHotKey())
    }

    /// 按这一刻的情形改每一项和左上角 × 的提示。
    func refresh() {
        let state = state()
        if let items {
            for (item, menuItem) in items.all { apply(item, to: menuItem, in: state) }
        }
        if let statusNewTab { apply(.statusNewTab, to: statusNewTab, in: state) }
        toolbar?.hideShortcut = TabMenuRules.hideButtonShortcut(
            tabCount: state.tabCount, hideKeyTaken: state.takenByUserHotKey.contains(.hideWindowKeepingTabs))
    }

    private func apply(_ item: TabMenuRules.Item, to menuItem: NSMenuItem, in state: TabMenuRules.State) {
        let look = TabMenuRules.look(item, in: state)
        menuItem.isHidden = !look.visible
        let key = look.showsKeyEquivalent ? Self.keyEquivalents[item] : nil
        menuItem.keyEquivalent = key?.key ?? ""
        menuItem.keyEquivalentModifierMask = key?.modifiers ?? []
        // 到了上限时（新建、重新打开因此置灰；菜单栏图标的那一项还能点），下面写上原因（提示框里的同一句话）。
        menuItem.subtitle = look.explainsLimit ? TabHint.limit(capacity: tabs.list.capacity).text() : nil
    }

    // MARK: - 验证和点了

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let item = Self.item(for: menuItem.action) else { return false }
        return TabMenuRules.look(item, in: state()).enabled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    static func item(for action: Selector?) -> TabMenuRules.Item? {
        switch action {
        case #selector(newTab(_:)): .newTab
        case #selector(reopenClosedTab(_:)): .reopenClosedTab
        case #selector(closeTab(_:)): .closeTab
        case #selector(hideWindowKeepingTabs(_:)): .hideWindowKeepingTabs
        case #selector(showNextTab(_:)): .nextTab
        case #selector(showPreviousTab(_:)): .previousTab
        case #selector(statusNewTab(_:)): .statusNewTab
        default: nil
        }
    }

    @objc func newTab(_ sender: Any?) {
        perform(.newTab, "新建标签页") { _ = $0.newTab() }
    }

    /// 菜单栏图标的菜单：不管窗口没显示（D9）、最小化、还是显示着但在别的窗口和应用后面，newTab 都先把窗口找回、带到前面
    /// （bringingWindowForward，第 3 阶段之后用户定）；到上限时也能点，同样先带到前面、再显示到上限的提示。
    /// 文件菜单的那一项和 ⌘T 不带到前面（newTab(_:)、TabKeys）。
    @objc func statusNewTab(_ sender: Any?) {
        perform(.statusNewTab, "新建标签页（菜单栏图标）") { _ = $0.newTab(bringingWindowForward: true) }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        perform(.reopenClosedTab, "重新打开最近关闭的标签页") { _ = $0.reopenClosedTab() }
    }

    @objc func closeTab(_ sender: Any?) {
        perform(.closeTab, "关闭标签页") { $0.closeSelectedTab() }
    }

    @objc func hideWindowKeepingTabs(_ sender: Any?) {
        perform(.hideWindowKeepingTabs, "关闭窗口") { $0.hideWindowKeepingTabs("菜单：关闭窗口") }
    }

    @objc func showNextTab(_ sender: Any?) {
        perform(.nextTab, "显示下一个标签页") { $0.selectNextTab() }
    }

    @objc func showPreviousTab(_ sender: Any?) {
        perform(.previousTab, "显示上一个标签页") { $0.selectPreviousTab() }
    }

    private func perform(_ item: TabMenuRules.Item, _ name: String, _ action: (ChatTabs) -> Void) {
        guard !currentEventIsRepeat() else {
            diagnostics.log("menu", "菜单 \(name)：按住不放的重复按键，不做")
            return
        }
        guard TabMenuRules.look(item, in: state()).enabled else {
            diagnostics.log("menu", "菜单 \(name)：现在不能用，不做")
            return
        }
        diagnostics.log("menu", "菜单 \(name)")
        action(tabs)
        refresh()
    }
}
