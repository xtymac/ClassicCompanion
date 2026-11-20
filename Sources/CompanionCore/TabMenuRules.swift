import Foundation

/// 标签页的菜单项（3.11）：每一项这一刻显不显示、能不能点、显不显示快捷键、下面要不要写上“最多打开 N 个标签页”。
/// 只做决定，不碰 AppKit、不写日志：TabMenus 把这一刻的情形（State）交进来，照返回的（Look）改菜单项。
///
/// 规则：
/// - 主菜单里的标签页的项只对聊天窗口起作用：聊天窗口是 key 窗口、上面没有表单（scope 是 chatWindow），并且没有应用级的
///   模态框。别的窗口（设置、关于、诊断、文件选择等）在前面、没有 key 窗口（聊天窗口隐藏着）、有模态框时都置灰，也不显示快捷键
///   （不显示快捷键，菜单就不会在别的窗口里抢这些键：那里的 ⌃Tab 等照原来交给那个窗口）。
/// - 新建标签页、重新打开：另外要启动画面不在、没到上限（重新打开还要有记录）。只因为到了上限而置灰时，下面写上
///   “最多打开 N 个标签页”（explainsLimit）。
/// - 关闭：多个标签页并且对聊天窗口起作用时，原来的“关闭窗口 ⌘W”藏起来，换成“关闭标签页 ⌘W”和“关闭窗口 ⇧⌘W”
///   （隐藏窗口、标签页都留着，和左上角的 × 一样）。别的时候只有原来那一项，和原来一样（D11：设置等窗口里 ⌘W 关那个窗口）；
///   它能不能点照原来交给 AppKit（这里的 enabled 是 true，意思是这里不拦）。
/// - 显示下一个、上一个标签页：多于一个标签页才能点。
/// - 用户自己的唤醒键或切换键就是这一项的组合（takenByUserHotKey）：这一项不显示快捷键（按键照原来给用户的键）；
///   ⌘W 不会是用户的键（录制时不让设），照常显示。
/// - 菜单栏图标的菜单里的“新建标签页”：不看哪个窗口在前面（和那里的“新建对话”一样；窗口没显示时入口先找回窗口，D9），
///   只看模态框、启动画面、上限；没有快捷键。
public enum TabMenuRules {
    public enum Item: CaseIterable, Hashable, Sendable {
        /// 文件 → 新建标签页 ⌘T。
        case newTab
        /// 文件 → 重新打开最近关闭的标签页 ⇧⌘T。
        case reopenClosedTab
        /// 文件 → 关闭窗口 ⌘W：原来那一项（performClose，交给 key 窗口）。
        case closeWindow
        /// 文件 → 关闭标签页 ⌘W：多个标签页时代替上一项。
        case closeTab
        /// 文件 → 关闭窗口 ⇧⌘W：隐藏窗口、标签页都留着；和关闭标签页一起出现。
        case hideWindowKeepingTabs
        /// 窗口 → 显示下一个标签页 ⌃Tab。
        case nextTab
        /// 窗口 → 显示上一个标签页 ⌃⇧Tab。
        case previousTab
        /// 菜单栏图标的菜单 → 新建标签页（没有快捷键）。
        case statusNewTab
    }

    /// 本应用这一刻在前面的窗口。
    public enum Scope: Hashable, Sendable, CaseIterable {
        /// 聊天窗口是 key 窗口，上面没有表单。
        case chatWindow
        /// 别的窗口是 key 窗口（设置、关于、诊断、文件选择、网页的弹窗等），或者聊天窗口上有表单。
        case otherWindow
        /// 没有 key 窗口（聊天窗口隐藏着、应用不在前台）。
        case noWindow
    }

    /// 这一刻的情形。
    public struct State: Hashable, Sendable {
        public var scope: Scope
        /// 有应用级的模态框（NSApp.modalWindow）。
        public var appModal: Bool
        /// 启动画面还在（ChatTabs.isLaunchScreenUp）。
        public var launchScreenUp: Bool
        /// 标签页已到上限（TabList.isFull）。
        public var atLimit: Bool
        /// 有可以重新打开的记录（ChatTabs.canReopenClosedTab）。
        public var canReopen: Bool
        /// 现在有几个标签页。
        public var tabCount: Int
        /// 用户自己的唤醒键或切换键就是这一项的组合的那些项。
        public var takenByUserHotKey: Set<Item>

        public init(scope: Scope, appModal: Bool = false, launchScreenUp: Bool = false, atLimit: Bool = false,
                    canReopen: Bool = false, tabCount: Int = 1, takenByUserHotKey: Set<Item> = []) {
            self.scope = scope
            self.appModal = appModal
            self.launchScreenUp = launchScreenUp
            self.atLimit = atLimit
            self.canReopen = canReopen
            self.tabCount = tabCount
            self.takenByUserHotKey = takenByUserHotKey
        }
    }

    /// 一项这一刻的样子。
    public struct Look: Hashable, Sendable {
        public var visible: Bool
        /// 能不能点。原来那一项“关闭窗口”是 true：这里不拦，照原来交给 AppKit。
        public var enabled: Bool
        public var showsKeyEquivalent: Bool
        /// 下面写上“最多打开 N 个标签页”（只因为到了上限而置灰时）。
        public var explainsLimit: Bool

        public init(visible: Bool, enabled: Bool, showsKeyEquivalent: Bool, explainsLimit: Bool = false) {
            self.visible = visible
            self.enabled = enabled
            self.showsKeyEquivalent = showsKeyEquivalent
            self.explainsLimit = explainsLimit
        }
    }

    public static func look(_ item: Item, in state: State) -> Look {
        let inChat = state.scope == .chatWindow && !state.appModal
        let several = inChat && state.tabCount > 1
        let canOpen = !state.appModal && !state.launchScreenUp && !state.atLimit
        let limitIsTheReason = !state.appModal && !state.launchScreenUp && state.atLimit
        let showsKey = inChat && !state.takenByUserHotKey.contains(item)
        switch item {
        case .newTab:
            return Look(visible: true, enabled: inChat && canOpen, showsKeyEquivalent: showsKey,
                        explainsLimit: inChat && limitIsTheReason)
        case .reopenClosedTab:
            return Look(visible: true, enabled: inChat && canOpen && state.canReopen, showsKeyEquivalent: showsKey,
                        explainsLimit: inChat && limitIsTheReason && state.canReopen)
        case .closeWindow:
            return Look(visible: !several, enabled: true, showsKeyEquivalent: true)
        case .closeTab:
            return Look(visible: several, enabled: several, showsKeyEquivalent: several)
        case .hideWindowKeepingTabs:
            return Look(visible: several, enabled: several, showsKeyEquivalent: several && showsKey)
        case .nextTab, .previousTab:
            return Look(visible: true, enabled: inChat && state.tabCount > 1, showsKeyEquivalent: showsKey)
        case .statusNewTab:
            return Look(visible: true, enabled: canOpen, showsKeyEquivalent: false, explainsLimit: limitIsTheReason)
        }
    }

    /// 左上角 × 的提示里写哪个键：一个标签页是 ⌘W（和原来一样）；多个标签页时 ⌘W 关标签页，× 和 ⇧⌘W 一样隐藏窗口，
    /// 写 ⇧⌘W；⇧⌘W 是用户自己的键时（按它不隐藏窗口）不写键（nil）。
    public static func hideButtonShortcut(tabCount: Int, hideKeyTaken: Bool) -> String? {
        if tabCount <= 1 { return "⌘W" }
        return hideKeyTaken ? nil : "⇧⌘W"
    }
}
