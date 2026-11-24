import Combine
import CompanionCore

/// 标签栏要显示的东西（4.2）：从左到右每个标签页的标识、显示的标题、是不是选中的；要不要显示标签栏；末尾 ＋ 的样子。
/// 只放东西、不做决定：ChatTabs 在这组标签页变了（加进来、切换、关掉、重新打开、⌘ 点击链接打开）和某一页的标题或加载中
/// 变了的时候照 TabBarRules 算好交进来（update(items:newTabButton:)，见 ChatTabs.refreshTabBar()），标签栏的视图只读它。
/// 标题是对话内容：只给标签栏显示，不写日志、不进诊断报告、不当窗口标题。Item 的文字描述（"\(item)"）也不带标题。
@MainActor
final class TabBarModel: ObservableObject {
    struct Item: Identifiable, Equatable, CustomStringConvertible {
        let id: TabID
        /// 标签上显示的标题（TabBarRules.displayTitle 的结果）。nil：显示本地化的“新聊天”（tabs.untitled）。
        let title: String?
        let isSelected: Bool

        var description: String { "标签\(id.rawValue)\(isSelected ? "（选中）" : "")" }
    }

    /// 从左到右，和 ChatTabs.tabs 一样的顺序。
    @Published private(set) var items: [Item] = []
    /// 显示标签栏（TabBarRules.showsBar：多于一个标签页）。
    @Published private(set) var isShown = false
    /// 末尾 ＋ 的样子（TabBarRules.newTabButton(in:)）。
    @Published private(set) var newTabButton = TabBarRules.NewTabButton(dimmed: false, clickable: true, explainsLimit: false)

    /// 标签栏上的点按交给谁（4.5）：点标签、点标签上的 × 或用中键点标签（TabBarHost）、点 ＋。ChatTabs 建好时接上（ChatTabs.init：select(id:)、
    /// closeTab(id:)、newTabFromBar()）；没接上时点了什么都不做。视图（TabBarView）只调用它们，不自己做决定。
    var onSelect: (@MainActor (TabID) -> Void)?
    var onClose: (@MainActor (TabID) -> Void)?
    var onNewTab: (@MainActor () -> Void)?

    /// 换成新的一份。和现在一样的不改（不发变化）。
    func update(items: [Item], newTabButton: TabBarRules.NewTabButton) {
        if self.items != items { self.items = items }
        let shown = TabBarRules.showsBar(tabCount: items.count)
        if isShown != shown { isShown = shown }
        if self.newTabButton != newTabButton { self.newTabButton = newTabButton }
    }
}
