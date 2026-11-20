import Foundation

/// ⌘ 点击、⇧⌘ 点击聊天链接，在新标签页打开（3.12）。只做决定，不碰 AppKit / WebKit，不写日志：
/// 网页运行时（WebRuntime 的导航判断和新窗口请求）把导航动作的事实交进来问 opening(url:linkActivated:command:shift:)；
/// 标签页那边（ChatTabs.openLink(_:from:_:)）把这一刻的情形交进来问 refusal(_:)；新标签页放在哪由 TabList.insert(rightOf:) 定（D12）。
///
/// 什么算（opening）：
/// - 点的是链接（WebKit 的 linkActivated），并且按着 ⌘。这就是原来“交给默认浏览器”的那一支的条件，没有改。
///   ⇧ 决定切不切过去：⌘ 在后台打开，⇧⌘ 打开并切换过去。⌥、⌃ 不看（原来也不看）。
/// - 只接受聊天页面（opensInTab(_:)）：https、主站 chatgpt.com 本身（NavigationPolicy 的主站，不含子域名），路径是首页 /、
///   对话 /c/…、GPT /g/…（含 GPT 里的对话和项目页）；query 和 fragment 不看。
///   和后退功能分支里的 NavigationPolicy.isChatPage 是同一条规则（那个分支还没合进来：合进来以后改用它，只留一条）。
/// - 别的都不在这里，照原来的路走：认证页、about: / blob: / data:、主站的其他路径（/gpts、/library、分享页、/auth/… 等）、
///   子域名、http、外部链接。⌘ 点击它们和原来一样交给默认浏览器。导航分类（NavigationPolicy.classify）不变。
///
/// 打不打开（refusal）：见 refusal(_:)。不打开时网页那边看到的和打开时一样是“导航取消”：这一页不跳转，也不交给浏览器。
public enum ChatLinkClick {
    /// 这次点击要的是什么。
    public enum Opening: Equatable, Sendable {
        /// ⌘：在后台打开，不切换过去。
        case background
        /// ⇧⌘：打开并切换过去。
        case foreground
    }

    /// 不打开的原因（按 refusal(_:) 看的先后）。
    public enum Refusal: Equatable, Sendable {
        /// 点击来自不是选中的标签页：不显示的页面上没有真实的点击，只可能是网页自己的脚本。不打开（保守的读法）。
        case sourceNotSelected
        /// 窗口没有显示（隐藏、最小化）：真实的点击不会发生。不打开，也不找回窗口。
        case windowNotShown
        /// 有应用级的模态框（和按键一样，这时不做标签页的事）。
        case appModal
        /// 启动画面还在（和新增标签页一样，计划 4.3）。
        case launchScreen
        /// 已到上限：显示到上限的提示（和按键、菜单的是同一个）。
        case atCapacity
    }

    /// 点击这一刻的情形（ChatTabs 给出）。
    public struct Situation: Equatable, Sendable {
        /// 点击来自选中的标签页（窗口显示着它）。
        public var sourceSelected: Bool
        /// 窗口显示着：可见、没有最小化。
        public var windowShown: Bool
        /// 有应用级的模态框（NSApp.modalWindow）。
        public var appModal: Bool
        /// 启动画面还在（ChatTabs.isLaunchScreenUp）。
        public var launchScreenUp: Bool
        /// 已到上限（TabList.isFull）。
        public var atCapacity: Bool

        public init(sourceSelected: Bool = true, windowShown: Bool = true, appModal: Bool = false,
                    launchScreenUp: Bool = false, atCapacity: Bool = false) {
            self.sourceSelected = sourceSelected
            self.windowShown = windowShown
            self.appModal = appModal
            self.launchScreenUp = launchScreenUp
            self.atCapacity = atCapacity
        }
    }

    /// 这次导航是不是在新标签页打开的 ⌘ 点击；不是（照原来的路走）时是 nil。
    /// - url：导航要去的地址；linkActivated：WebKit 说是点链接（navigationType == .linkActivated）；
    ///   command、shift：导航动作带着的修饰键（modifierFlags）。
    public static func opening(url: URL?, linkActivated: Bool, command: Bool, shift: Bool) -> Opening? {
        guard linkActivated, command, opensInTab(url) else { return nil }
        return shift ? .foreground : .background
    }

    /// ⌘ 点击时在新标签页打开的地址：主站的聊天页面（首页 /、对话 /c/…、GPT /g/…），只认 https 和主站本身。
    public static func opensInTab(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), NavigationPolicy.chatHosts.contains(host) else { return false }
        guard let first = url.path.split(separator: "/").first else { return true }
        return first == "c" || first == "g"
    }

    /// 这一刻不打开的原因；打开时是 nil。按这个先后看：
    /// 1. 点击不来自选中的标签页；2. 窗口没有显示；3. 有应用级的模态框——这三样说明这不是用户在显示着的那一页上的点击，
    ///    不提示（第 2 样也不找回窗口：点链接不该把隐藏的窗口叫出来）。
    /// 4. 启动画面还在（不提示，和新增标签页一样）；5. 已到上限（提示）。两样都有时按启动画面算，和新增标签页一样。
    public static func refusal(_ situation: Situation) -> Refusal? {
        if !situation.sourceSelected { return .sourceNotSelected }
        if !situation.windowShown { return .windowNotShown }
        if situation.appModal { return .appModal }
        if situation.launchScreenUp { return .launchScreen }
        if situation.atCapacity { return .atCapacity }
        return nil
    }
}
