import AppKit
import CompanionCore

/// 后退、前进的方向。
enum HistoryDirection: Equatable, Sendable {
    case back, forward

    /// 日志用，日志保持中文。
    var logName: String { self == .back ? "后退" : "前进" }
}

/// 后退、前进作用的那一页。现在只有 WebRuntime（聊天窗口的网页）；以后有标签页时，每个标签页一个。
/// 只走这一页自己的 WKWebView 历史：跨文档的条目照常经过 WebRuntime 的导航策略，不放宽、不绕开。
@MainActor
protocol HistoryPage: AnyObject {
    func canGo(_ direction: HistoryDirection) -> Bool
    /// 发出了导航返回 true；这个方向没有页面时什么都不做，返回 false。
    @discardableResult func go(_ direction: HistoryDirection, source: String) -> Bool
}

/// 后退、前进的规则：目标页面、菜单项、顶部返回箭头、⌘[ ⌘] 和鼠标侧键。不碰窗口和网页，可以单独测试。
///
/// 入口有四个：菜单（⌘[ ⌘] 也显示在这里）、聊天窗口里的 ⌘[ ⌘]、鼠标侧键、顶部的返回箭头。
/// 每次操作开始时解析一次目标页面（target），之后只对它操作，不在途中再去找别的页面。
/// 以后有标签页时，target 的 page 换成“这一刻选中的那一页”，其余不用改。
enum HistoryNavigation {
    /// 这次操作算哪个窗口的：应用的 key 窗口；应用不在前台、没有 key 窗口时，是事件所在的窗口
    /// （鼠标侧键按在聊天窗口上，顶部箭头就在聊天窗口里；菜单没有事件窗口）。
    /// 所以登录弹窗是 key 窗口时，鼠标停在聊天窗口上按侧键、点箭头也不会动聊天窗口的页面：
    /// 弹窗保留了和主窗口的 window.opener 关系，登录途中主窗口换页可能打断登录（推断，没有实测）。
    static func commandWindow(keyWindow: AnyObject?, eventWindow: AnyObject?) -> AnyObject? {
        keyWindow ?? eventWindow
    }

    /// 操作作用的页面：操作的窗口（commandWindow）是聊天窗口时是它的页面。登录弹窗、设置、诊断等窗口在前面时
    /// 没有目标：菜单项灰掉，什么都不做——主窗口的页面不动，弹窗自己的历史也不动（弹窗里是登录流程的跳转，要退出就关掉弹窗）。
    static func target<Page: AnyObject>(for window: AnyObject?, chatWindow: AnyObject?, page: Page?) -> Page? {
        guard let window, let chatWindow, window === chatWindow else { return nil }
        return page
    }

    /// 菜单项“后退”“前进”可用：有目标页面，并且那一页能往这个方向走（canGoBack / canGoForward）。
    @MainActor
    static func isAvailable(_ direction: HistoryDirection, on page: (any HistoryPage)?) -> Bool {
        page?.canGo(direction) ?? false
    }

    /// 顶部返回箭头：当前页面不是聊天页面（NavigationPolicy.isChatPage），并且能后退时才显示。
    /// 聊天页面上不显示，顶部一条和以前完全一样。
    static func showsBackButton(url: URL?, canGoBack: Bool) -> Bool {
        canGoBack && !NavigationPolicy.isChatPage(url)
    }

    /// 菜单里的快捷键：⌘[ 后退，⌘] 前进。
    static func menuKey(_ direction: HistoryDirection) -> String {
        direction == .back ? "[" : "]"
    }

    /// 快捷键的写法，和录制时的保留表（HotKeyCapture）一样。
    static func shortcutName(_ direction: HistoryDirection) -> String {
        "⌘" + menuKey(direction)
    }

    /// 按键是不是 ⌘[ / ⌘]：只认纯 ⌘，按字符匹配（和菜单、⌘W 一样，换键盘布局也对得上）。
    /// 带 ⇧ ⌥ ⌃ 的、不带 ⌘ 的 [ ] 都不算：打字、输入法用 [ ] 翻候选或输入「」都照常交给网页。
    static func direction(characters: String?, flags: NSEvent.ModifierFlags) -> HistoryDirection? {
        guard flags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command else { return nil }
        switch characters {
        case "[": return .back
        case "]": return .forward
        default: return nil
        }
    }

    /// ⌘[ ⌘] 和鼠标侧键怎么处理（keyAction、mouseAction）。
    enum EventAction: Equatable {
        /// 走一次。
        case navigate(HistoryDirection)
        /// 吃掉，什么都不做：不再交给 WebKit、输入法和网页。
        case swallow
        /// 原样放过。
        case pass
    }

    /// ⌘[ ⌘]（方向见 direction(characters:flags:)）。⌘[ ⌘] 是应用的后退、前进快捷键：聊天窗口里的按键总是由应用处理，
    /// 不交给网页——这一页能往这个方向走时走一次；走不了（菜单项是灰的）或者是按住不放的重复按键时吃掉，什么都不做。
    /// 这样同一个快捷键不会因为能不能后退，有时后退、有时变成网页里的别的功能。
    /// 别的窗口（登录弹窗、设置、关于、诊断等）里的按键原样放过，和以前一样。
    /// 不看输入法组词状态（原生层读不到，见 ChatWindowController.logEscape），和 ⌘W、切换键一样：
    /// 吃掉的按键输入法和网页都收不到，输入框里正在组的字原样留着，不会被确认或取消（按事件流程推断，没有用真实输入法实测）。
    /// 能走时照样走一次，不管输入框里有没有正在组的字。
    static func keyAction(_ direction: HistoryDirection, inChatWindow: Bool, isRepeat: Bool, canGo: Bool) -> EventAction {
        guard inChatWindow else { return .pass }
        guard !isRepeat, canGo else { return .swallow }
        return .navigate(direction)
    }

    /// 鼠标侧键：buttonNumber 3 后退，4 前进（macOS 从 0 数，左 0 右 1 中 2）。
    /// 按下时走一次；同一个侧键的拖动和松开吃掉；其他按键原样放过。
    /// 按下、拖动、松开都不交给 WebKit 和网页，所以不管它们自己会不会处理侧键，按一下只有这一次导航。
    static func mouseAction(type: NSEvent.EventType, button: Int) -> EventAction {
        let direction: HistoryDirection
        switch button {
        case 3: direction = .back
        case 4: direction = .forward
        default: return .pass
        }
        switch type {
        case .otherMouseDown: return .navigate(direction)
        case .otherMouseDragged, .otherMouseUp: return .swallow
        default: return .pass
        }
    }
}
