import Foundation

/// 标签页的按键（3.10）：按下的是不是标签页的键（match），是的话这一刻该做什么（keyAction）。
/// 只做决定，不碰 AppKit、不写日志：窗口的按键监视把按键的事实交进来，ChatTabs 照返回的做
/// （切换只经 ChatTabs.select(_:)，选哪一个问 TabList 的 nextTab、previousTab、tab(atPosition:)、lastTab）。
///
/// 键：
/// - ⌘T 新增标签页；⇧⌘T 重新打开最近关闭的；⌘W 关闭选中的（只有一个时和原来一样隐藏窗口）；
///   ⇧⌘W 隐藏窗口、标签页都留着（和左上角的 × 一样）。
/// - ⌃Tab、⇧⌘] 下一个；⌃⇧Tab、⇧⌘[ 上一个；到头绕回。
/// - ⌘1–⌘4 第 1–4 个；⌘9 最后一个。⌘5–⌘8 不是（上限 4 个，不会有第 5 个），照原来交给网页。
///
/// 怎么认（match）：和原来的 ⌘W 一样，按不计修饰键的字符（NSEvent.charactersIgnoringModifiers，它保留 ⇧ 的效果）的小写、
/// 加上正好的修饰键认；大写锁定不算，带着别的修饰标志（fn、小键盘等，见 Modifiers.other）就不是。
/// - 字母、数字按字符：键盘布局把这个字符放在哪个键上就是哪个键（Dvorak 等和 ⌘W 一样跟着布局走）。
///   数字要不按 ⇧ 就打得出来：⌘1 的字符是“1”才算（法文 AZERTY 上不按 ⇧ 是“&”，就不是 ⌘1，交给网页）。
/// - ⇧⌘] ⇧⌘[：按着 ⇧ 时字符多半是“}”“{”（美式等），也认“]”“[”（要按 ⇧ 才打得出方括号的布局）。
///   方括号要按 ⌥ 才打得出的布局（德文等）上按不出来，用 ⌃Tab、⌃⇧Tab。
/// - Tab 键按键码（48）认：按着 ⇧ 时它的字符变成反向制表（0x19），按键码认不受影响；Tab 键在所有布局上都是同一个键。
public enum TabKeys {
    /// Tab 键的键码（kVK_Tab）。
    public static let tabKeyCode: UInt16 = 48

    /// 键要做的事。
    public enum Command: Hashable, Sendable {
        case newTab
        case reopenClosedTab
        case closeTab
        /// 隐藏窗口、标签页都留着。
        case hideWindow
        case next
        case previous
        /// 从左数第 N 个（1 起）。
        case position(Int)
        case last
    }

    /// 按着的修饰键（大写锁定不算）。
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let option = Modifiers(rawValue: 1 << 3)
        /// 别的修饰标志（fn、小键盘、帮助键）。和原来的 ⌘W 一样：带着它就不是标签页的键。
        public static let other = Modifiers(rawValue: 1 << 4)
    }

    /// 认出来的键：要做的事和写日志用的键名（修饰键按系统菜单的顺序 ⌃⌥⇧⌘，和 HotKeyCombo 一样）。
    public struct Match: Hashable, Sendable {
        public let command: Command
        public let name: String

        public init(_ command: Command, _ name: String) {
            self.command = command
            self.name = name
        }
    }

    /// 按下这个键这一刻的情形（窗口的按键监视给出）。
    public struct Context: Hashable, Sendable {
        /// 按键属于聊天窗口，并且窗口上没有表单（sheet）。别的窗口（设置、诊断、登录弹窗等）的按键都不是。
        public var inChatWindow: Bool
        /// 有应用级的模态框（NSApp.modalWindow）。
        public var appModal: Bool
        /// 这次按下的组合就是用户自己设的唤醒键或切换键（按键位和修饰键比，和录制时一样）。
        public var takenByUserHotKey: Bool
        /// 按住不放的重复按键（NSEvent.isARepeat）。
        public var isRepeat: Bool

        public init(inChatWindow: Bool, appModal: Bool = false, takenByUserHotKey: Bool = false, isRepeat: Bool = false) {
            self.inChatWindow = inChatWindow
            self.appModal = appModal
            self.takenByUserHotKey = takenByUserHotKey
            self.isRepeat = isRepeat
        }
    }

    /// 这一刻做什么。
    public enum Action: Hashable, Sendable {
        case newTab
        case reopenClosedTab
        case closeTab
        case hideWindow
        /// 切换到这一个（ChatTabs.select(_:)）。
        case select(TabID)
        /// 吃掉（不交给输入法和网页），什么都不做。
        case swallow
        /// 不是这里的事：按键照原来的路走（切换键、菜单、网页）。
        case pass
    }

    /// 认按下的键。不是标签页的键时是 nil。
    /// - characters：不计修饰键的字符（charactersIgnoringModifiers），比较时取小写。
    /// - keyCode：键码，只用来认 Tab 键。
    public static func match(characters: String?, keyCode: UInt16, modifiers: Modifiers) -> Match? {
        if keyCode == tabKeyCode {
            if modifiers == [.control] { return Match(.next, "⌃Tab") }
            if modifiers == [.control, .shift] { return Match(.previous, "⌃⇧Tab") }
            return nil
        }
        guard let key = characters?.lowercased() else { return nil }
        if modifiers == [.command] {
            switch key {
            case "t": return Match(.newTab, "⌘T")
            case "w": return Match(.closeTab, "⌘W")
            case "1", "2", "3", "4": return Int(key).map { Match(.position($0), "⌘\(key)") }
            case "9": return Match(.last, "⌘9")
            default: return nil
            }
        }
        if modifiers == [.command, .shift] {
            switch key {
            case "t": return Match(.reopenClosedTab, "⇧⌘T")
            case "w": return Match(.hideWindow, "⇧⌘W")
            case "}", "]": return Match(.next, "⇧⌘]")
            case "{", "[": return Match(.previous, "⇧⌘[")
            default: return nil
            }
        }
        return nil
    }

    /// 认出来的键这一刻做什么。按这个顺序看：
    /// 1. 不在聊天窗口里（别的窗口、窗口上有表单）、或有应用级模态框：pass，和原来一样不拦（D11）。
    /// 2. 用户自己设的唤醒键或切换键就是这个组合：pass，用户的设置优先（按键照原来的路走：切换键切换模式）。
    ///    ⌘W 例外：它原来就先于切换键（录制时也不让设成 ⌘W），关闭照旧。
    /// 3. 按住不放的重复按键：swallow，不重复做（连着关、连着开标签页要一次一次按）。
    /// 4. 新增、重新打开、关闭、隐藏窗口：照做。做不了（启动画面还在、到上限、没有记录）由入口自己响一声或写一行，按键照样吃掉
    ///    （D13、D17：固定的键做不了时也不交给网页）。
    /// 5. 切换：要切换到的那一个问 list（nextTab、previousTab、tab(atPosition:)、lastTab）；没有（⌘3 时只有两个）或就是
    ///    选中的那个（只有一个时的上一个、下一个，⌘1 时已经选中第 1 个）：swallow；不然 select(那一个)。
    public static func keyAction(_ command: Command, _ context: Context, list: TabList) -> Action {
        guard context.inChatWindow, !context.appModal else { return .pass }
        if context.takenByUserHotKey, command != .closeTab { return .pass }
        if context.isRepeat { return .swallow }
        let target: TabID?
        switch command {
        case .newTab: return .newTab
        case .reopenClosedTab: return .reopenClosedTab
        case .closeTab: return .closeTab
        case .hideWindow: return .hideWindow
        case .next: target = list.nextTab
        case .previous: target = list.previousTab
        case .position(let position): target = list.tab(atPosition: position)
        case .last: target = list.lastTab
        }
        guard let target, target != list.selected else { return .swallow }
        return .select(target)
    }
}
