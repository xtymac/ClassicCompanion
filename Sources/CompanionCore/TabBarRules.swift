import Foundation

/// 标签栏（阶段 4）的纯规则：标签上显示什么标题、要不要显示标签栏、每个标签多宽、末尾的 ＋ 看起来什么样。
/// 只做决定，不碰 AppKit / SwiftUI，不写日志。
/// ＋ 能不能点、要不要写上上限的说明和菜单项一起在 TabMenuRules（.tabBarNewTab）；这里只把它换成按钮的样子（newTabButton(in:)）。
///
/// 标题是对话内容：这里只决定显示什么。调用方只把结果交给标签栏，不写日志、不进诊断报告、不当窗口标题。
public enum TabBarRules {
    // MARK: - 标题

    /// 网站自己的通用标题。新对话页、还没起名的对话报的是不是它，M1 时核对（只比较是否等于它，不记标题内容）。
    public static let genericSiteTitle = "ChatGPT"

    /// 标签上显示的标题；nil 是显示本地化的“新聊天”。
    /// - 网页还在加载（isLoading）：nil。加载中报的标题可能是空的或上一页的（Q5：要不要改成保留上一个标题，上屏看过再定）。
    /// - 没有标题、空的、只有空白：nil。
    /// - 去掉首尾空白以后正好是 “ChatGPT”：nil。只比相等：“ChatGPT - x” 是真标题，照样显示。
    /// - 别的：去掉首尾空白以后的标题。
    public static func displayTitle(pageTitle: String?, isLoading: Bool) -> String? {
        guard !isLoading, let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title != genericSiteTitle else { return nil }
        return title
    }

    // MARK: - 显示和宽度

    /// 多于一个标签页才显示标签栏（计划：只有一个标签页时不显示）。
    public static func showsBar(tabCount: Int) -> Bool {
        tabCount > 1
    }

    /// 标签栏左右两边各留的边距（点）。
    public static let sideMargin: Double = 12
    /// 相邻两个标签之间、最后一个标签和 ＋ 之间的间距（点）。
    public static let gap: Double = 4
    /// 末尾 ＋ 按钮的宽度（点）。
    public static let newTabButtonWidth: Double = 26

    /// 每个标签的宽度（标签一样宽，平分可用的宽度）。availableWidth 是标签栏的整个宽度（含两边边距）。
    /// 宽度 = (availableWidth − 2 × sideMargin − (tabCount − 1) × gap − gap − newTabButtonWidth) ÷ tabCount。
    /// 480 宽、4 个标签：(480 − 24 − 12 − 4 − 26) ÷ 4 = 103.5。
    /// 不小于 0（窗口再窄也不给负数）；tabCount 小于 1 时是 0。
    public static func tabWidth(availableWidth: Double, tabCount: Int) -> Double {
        guard tabCount >= 1 else { return 0 }
        let count = Double(tabCount)
        let fixed = 2 * sideMargin + (count - 1) * gap + gap + newTabButtonWidth
        return max(0, (availableWidth - fixed) / count)
    }

    // MARK: - ＋

    /// 标签栏末尾的 ＋ 这一刻的样子。
    public struct NewTabButton: Hashable, Sendable {
        /// 看起来不可用（置灰）：点不了，或者已到上限（还能点，点了显示到上限的提示）。
        public var dimmed: Bool
        /// 能点。
        public var clickable: Bool
        /// 带上“最多打开 N 个标签页”的说明（悬停提示、读屏）。
        public var explainsLimit: Bool

        public init(dimmed: Bool, clickable: Bool, explainsLimit: Bool) {
            self.dimmed = dimmed
            self.clickable = clickable
            self.explainsLimit = explainsLimit
        }
    }

    /// ＋ 在 state 下的样子：能不能点、写不写上限的说明照 TabMenuRules.look(.tabBarNewTab, in:)；
    /// 点不了或者写着上限的说明时置灰。
    public static func newTabButton(in state: TabMenuRules.State) -> NewTabButton {
        let look = TabMenuRules.look(.tabBarNewTab, in: state)
        return NewTabButton(dimmed: !look.enabled || look.explainsLimit, clickable: look.enabled,
                            explainsLimit: look.explainsLimit)
    }
}
