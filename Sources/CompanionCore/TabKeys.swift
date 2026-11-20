import Foundation

/// 标签页的按键（3.10）：按下的是不是标签页的键（match），是的话这一刻该做什么（keyAction）。
/// 只做决定，不碰 AppKit、不写日志：窗口的按键监视把按键的事实交进来，ChatTabs 照返回的做
/// （切换只经 ChatTabs.select(_:)，选哪一个问 TabList 的 nextTab、previousTab、tab(atPosition:)、lastTab）。
///
/// 键：
/// - ⌘T 新增标签页；⇧⌘T 重新打开最近关闭的；⌘W 关闭选中的（只有一个时和原来一样隐藏窗口）；
///   ⇧⌘W 隐藏窗口、标签页都留着（和左上角的 × 一样）。
/// - ⌃Tab、⇧⌘] 下一个；⌃⇧Tab、⇧⌘[ 上一个；到头绕回。
/// - ⌘1–⌘4 第 1–4 个；⌘9 最后一个。⌘5–⌘8、⌘0 不是（上限 4 个，不会有第 5 个），照原来交给网页。
///   主键盘最上面一排的数字键和小键盘的 1–4、9 都算（用户 11-20 定）；小键盘的 5–8、0 不算。
///
/// 怎么认（match）：修饰键要正好（大写锁定不算；带着 fn、帮助键这些别的标志就不是，见 Modifiers.other）。
/// - 字母（⌘T ⇧⌘T ⌘W ⇧⌘W）按字符，和原来的 ⌘W 一样：不计修饰键的字符（NSEvent.charactersIgnoringModifiers，
///   它保留 ⇧ 的效果）的小写。键盘布局把这个字符放在哪个键上就是哪个键（Dvorak 等跟着布局走）。
/// - 数字（⌘1–⌘4、⌘9）按键位（用户 11-20 定）：主键盘最上面一排 1、2、3、4、9 那几个键（键码见 digitKeyCodes，
///   ANSI 和 ISO 键盘上是同一组键码），不管这个布局在那里打出什么字符——法文 AZERTY 上不按 ⇧ 是“&”“é”…，也是 ⌘1、⌘2…。
///   只认键位：别的键打出数字字符时（有的布局把数字放在别处）不算，交给网页。修饰键是纯 ⌘（要按 ⇧ 才打得出数字的布局，
///   ⇧⌘ 加这些键也不算）。
///   小键盘的 1–4、9（键码见 keypadDigitKeyCodes）也一样：小键盘的按键带着“小键盘”标志（Modifiers.numericPad），
///   只有这几个键容许它；别的键带着它就不是（和原来一样）。
/// - ⇧⌘] ⇧⌘[ 按字符（用户 11-20 定：不改成按键位）：按着 ⇧ 时字符多半是“}”“{”（美式等），也认“]”“[”（要按 ⇧ 才打得出
///   方括号的布局）。方括号要按 ⌥ 才打得出的布局（德文等）上按不出来（不认带 ⌥ 的，也不把别的键位当成方括号），
///   用 ⌃Tab、⌃⇧Tab。
/// - Tab 键按键码（48）认：按着 ⇧ 时它的字符变成反向制表（0x19），按键码认不受影响；Tab 键在所有布局上都是同一个键。
public enum TabKeys {
    /// Tab 键的键码（kVK_Tab）。
    public static let tabKeyCode: UInt16 = 48

    /// 主键盘最上面一排的数字键：键码 → 数字（kVK_ANSI_1–kVK_ANSI_4、kVK_ANSI_9；TabKeyTests 和 Carbon 的常量核对）。
    public static let digitKeyCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 25: 9]

    /// 小键盘的数字键：键码 → 数字（kVK_ANSI_Keypad1–kVK_ANSI_Keypad4、kVK_ANSI_Keypad9；TabKeyTests 核对）。
    public static let keypadDigitKeyCodes: [UInt16: Int] = [83: 1, 84: 2, 85: 3, 86: 4, 92: 9]

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
        /// 别的修饰标志（fn、帮助键）。和原来的 ⌘W 一样：带着它就不是标签页的键。
        public static let other = Modifiers(rawValue: 1 << 4)
        /// 小键盘的标志（NSEvent 的 numericPad：小键盘的键、方向键带着它）。只有小键盘的 1–4、9 容许它，别的键带着它就不是
        /// （和原来算作 other 一样）。
        public static let numericPad = Modifiers(rawValue: 1 << 5)
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
    /// - characters：不计修饰键的字符（charactersIgnoringModifiers），比较时取小写。数字键不看它。
    /// - keyCode：键码，用来认 Tab 键和数字键（键位）。
    /// 键名写进日志：小键盘的写成“⌘1（小键盘）”，和主键盘的分得开。
    public static func match(characters: String?, keyCode: UInt16, modifiers: Modifiers) -> Match? {
        if keyCode == tabKeyCode {
            if modifiers == [.control] { return Match(.next, "⌃Tab") }
            if modifiers == [.control, .shift] { return Match(.previous, "⌃⇧Tab") }
            return nil
        }
        if let digit = digitKeyCodes[keyCode] {
            guard modifiers == [.command] else { return nil }
            return Match(digit == 9 ? .last : .position(digit), "⌘\(digit)")
        }
        if let digit = keypadDigitKeyCodes[keyCode] {
            guard modifiers == [.command, .numericPad] || modifiers == [.command] else { return nil }
            return Match(digit == 9 ? .last : .position(digit), "⌘\(digit)（小键盘）")
        }
        guard let key = characters?.lowercased() else { return nil }
        if modifiers == [.command] {
            switch key {
            case "t": return Match(.newTab, "⌘T")
            case "w": return Match(.closeTab, "⌘W")
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
    /// 4. 新增、重新打开、关闭、隐藏窗口：照做。做不了（启动画面还在、到上限、没有记录）由入口自己写一行（到上限时还有提示），按键照样吃掉
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
