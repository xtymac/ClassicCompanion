import Foundation

/// 标签页的标识：`TabList` 按顺序发放的序号，从 1 开始，关闭后不再复用（重新打开的标签页拿新的）。
/// 只是序号，不含标题和地址。
public struct TabID: Hashable, Sendable {
    public let rawValue: Int
}

/// 聊天标签页列表：顺序、选中项、上限和最近关闭的记录。只做决定，调用方按返回值建立、切换、释放网页视图。
/// 不碰 AppKit / WebKit，不写日志，不持久化：退出应用即清空。
///
/// - 列表里至少有一个标签页，总有一个选中项。开始时只有启动时的那一个。
/// - 上限默认 4 个（可用性决定，不是内存上限）。到上限时新增和重新打开都被拒绝，调用方显示上限提示。
/// - 新增放在最右。⌘ 点击、⇧⌘ 点击聊天链接打开的放在来源标签页的紧右边（D12，`insert(rightOf:)`）。
/// - 关闭选中的标签页后选右边的邻居，没有就选左边。
/// - 只剩一个标签页时不关闭，由调用方处理（⌘W 隐藏窗口，不释放该页）。
/// - 上一个 / 下一个到头绕回；⌘1–⌘4 选第 N 个，⌘9 选最后一个。
/// - 关闭时只记普通对话地址和位置（见 `RecentlyClosedTabs`）；⇧⌘T 先打开最近关闭的那条，放回原位置并选中。
/// - 不记标题：标题是对话内容，只显示在标签栏上。
///
/// 启动画面还在时不能新增标签页，这由调用方判断，不在这里。
public struct TabList: Equatable, Sendable {
    public enum AddResult: Equatable, Sendable {
        /// 已加在最右。调用方为它建网页视图。
        case added(TabID)
        /// 已到上限，列表不变。
        case atCapacity
    }

    public enum CloseResult: Equatable, Sendable {
        /// 已从列表移除。`selectionChanged` 为真时关的是选中项，`selected` 已换成邻居，调用方要切换显示。
        case closed(selectionChanged: Bool)
        /// 只剩这一个标签页：列表不变，也不记入最近关闭。由调用方处理（⌘W 隐藏窗口，不释放该页）。
        case onlyTab
        /// 不在列表里（例如已经关过）：什么都不做。
        case notFound
    }

    public enum ReopenResult: Equatable, Sendable {
        /// 已放回（`reopen()` 同时选中）。调用方新建网页视图加载 `url`（是重新加载，不是原样找回）。
        case reopened(TabID, url: URL)
        /// 已到上限：不打开，这条记录不消耗。
        case atCapacity
        /// 没有可以重新打开的记录。
        case nothingToReopen
    }

    public static let defaultCapacity = 4

    public let capacity: Int
    /// 从左到右。
    public private(set) var tabs: [TabID]
    public private(set) var selected: TabID
    public private(set) var recentlyClosed: RecentlyClosedTabs
    private var nextID: Int

    public init(capacity: Int = TabList.defaultCapacity,
                recentlyClosedLimit: Int = RecentlyClosedTabs.defaultLimit) {
        precondition(capacity >= 1, "至少要能放一个标签页")
        self.capacity = capacity
        let first = TabID(rawValue: 1)
        tabs = [first]
        selected = first
        recentlyClosed = RecentlyClosedTabs(limit: recentlyClosedLimit)
        nextID = 2
    }

    public var isFull: Bool { tabs.count >= capacity }

    private var selectedIndex: Int {
        guard let index = tabs.firstIndex(of: selected) else { preconditionFailure("选中项不在列表里") }
        return index
    }

    // MARK: 新增

    /// ⌘T（`select: true`）：加在最右并选中。`select: false`：加在最右、选中项不变（ChatTabs 新增标签页时用：
    /// 先放进来，再经自己的切换入口选中）。⌘ 点击链接打开的不放这里，见 `insert(rightOf:)`。
    public mutating func append(select: Bool = true) -> AddResult {
        guard !isFull else { return .atCapacity }
        return .added(insert(at: tabs.count, select: select))
    }

    /// ⌘ 点击、⇧⌘ 点击聊天链接打开的标签页（D12）：放在来源 `source`（点击所在的标签页）的紧右边，不放最右；选中项不变。
    /// ⌘ 就这样留在后台；⇧⌘ 由调用方之后经自己的切换入口选中它（ChatTabs.select(_:)），这里从不选中。
    /// 从同一个标签页连着 ⌘ 点击几次，每个新的都紧挨着来源，先开的被往右挤（最新的离来源最近）。放在哪只有这一条规则。
    /// 已到上限时是 `.atCapacity`，列表不变。`source` 不在列表里（已经关了）时是 nil，列表不变、不发标识。
    public mutating func insert(rightOf source: TabID) -> AddResult? {
        guard let index = tabs.firstIndex(of: source) else { return nil }
        guard !isFull else { return .atCapacity }
        return .added(insert(at: index + 1, select: false))
    }

    private mutating func insert(at index: Int, select: Bool) -> TabID {
        let id = TabID(rawValue: nextID)
        nextID += 1
        tabs.insert(id, at: index)
        if select { selected = id }
        return id
    }

    // MARK: 关闭

    /// 关闭 `id`。`url` 是它此刻的地址：普通对话地址连同关闭时的位置记入最近关闭，别的不记。
    /// 关的是选中项时选右边的邻居，没有就选左边。
    /// 关的不是选中项（例如标签栏上的关闭按钮）时选中项不变：计划只写了前一种，这里取不打扰当前标签页的读法。
    /// 关闭后选哪个只有一条规则，见 `selectionAfterClosing(_:)`。
    public mutating func close(_ id: TabID, url: URL?) -> CloseResult {
        guard let index = tabs.firstIndex(of: id) else { return .notFound }
        guard let next = selectionAfterClosing(id) else { return .onlyTab }
        tabs.remove(at: index)
        recentlyClosed.record(url: url, index: index)
        guard id == selected else { return .closed(selectionChanged: false) }
        selected = next
        return .closed(selectionChanged: true)
    }

    /// 关闭 `id` 以后选中的是哪一个，列表不改：关的是选中项时是右边的邻居，没有就左边；关的不是选中项时还是现在的选中项。
    /// 只剩这一个、或 `id` 不在列表里（`close` 不关）时是 nil。`close` 用的就是这里的规则。
    /// 调用方要先切换到下一个、再关闭时用（关闭显示着的标签页：先让窗口换上邻居，选中项一直指着还在的标签页，再关它）。
    public func selectionAfterClosing(_ id: TabID) -> TabID? {
        guard let index = tabs.firstIndex(of: id), tabs.count > 1 else { return nil }
        guard id == selected else { return selected }
        return index + 1 < tabs.count ? tabs[index + 1] : tabs[index - 1]
    }

    // MARK: 选哪一个（不改列表）。下面的选择和按键的决定（TabKeys.keyAction）都用这几个，“哪一个”只有一条规则。
    // 调用方要经自己的切换入口选中时用（ChatTabs.select(_:)：先改选中项，窗口再跟着换）。

    /// ⌃Tab、⇧⌘]：下一个，最右之后回到最左。只有一个标签页时就是选中的那个。
    public var nextTab: TabID {
        tabs[(selectedIndex + 1) % tabs.count]
    }

    /// ⌃⇧Tab、⇧⌘[：上一个，最左之前回到最右。只有一个标签页时就是选中的那个。
    public var previousTab: TabID {
        tabs[(selectedIndex - 1 + tabs.count) % tabs.count]
    }

    /// ⌘1–⌘4：从左数第 `position` 个（1 起）。没有这个标签页时是 nil：计划没写，取什么都不做的读法（不改选最后一个）。
    public func tab(atPosition position: Int) -> TabID? {
        guard (1...tabs.count).contains(position) else { return nil }
        return tabs[position - 1]
    }

    /// ⌘9：最后一个（最右）。
    public var lastTab: TabID {
        tabs[tabs.count - 1]
    }

    // MARK: 选择。返回值是选中项有没有变，没变时调用方什么都不用做。

    /// 点击标签栏里的标签页。不在列表里或已经选中时不变。
    public mutating func select(_ id: TabID) -> Bool {
        guard tabs.contains(id), id != selected else { return false }
        selected = id
        return true
    }

    /// 选下一个（nextTab）。只有一个标签页时不变。
    public mutating func selectNext() -> Bool {
        select(nextTab)
    }

    /// 选上一个（previousTab）。只有一个标签页时不变。
    public mutating func selectPrevious() -> Bool {
        select(previousTab)
    }

    /// 选从左数第 `position` 个（tab(atPosition:)）。没有这个标签页时不变。
    public mutating func select(position: Int) -> Bool {
        guard let id = tab(atPosition: position) else { return false }
        return select(id)
    }

    /// 选最后一个（lastTab）。
    public mutating func selectLast() -> Bool {
        select(lastTab)
    }

    // MARK: 重新打开

    /// ⇧⌘T：取最近关闭的一条，新建标签页（新的标识）放回关闭时的位置并选中（`select: true`）；
    /// 那个位置已经不存在（标签页比当时少）就放在最右。连按按关闭的倒序逐个打开。放在哪只有这一条规则。
    /// 已到上限时不打开，这条记录留着。
    /// 没有记录时一律返回 `.nothingToReopen`，即使已到上限：计划说没有记录时按键不响应，这里取不显示上限提示的读法。
    /// `select: false`：放回原位置、消耗这条记录，选中项不变。ChatTabs 用它：先把新标签页放进来，再经自己的切换入口选中它
    /// （和关闭时先切换、再拿掉一样：选中项只在窗口跟着换的那一步改，不会已经指着新的、窗口却还显示着别的）。
    public mutating func reopen(select: Bool = true) -> ReopenResult {
        guard let entry = recentlyClosed.latest else { return .nothingToReopen }
        guard !isFull else { return .atCapacity }
        recentlyClosed.removeLatest()
        let id = insert(at: min(entry.index, tabs.count), select: select)
        return .reopened(id, url: entry.url)
    }
}

/// 最近关闭的标签页。只在内存里，最多 `limit` 条，超出丢最旧的。
///
/// 只记普通对话地址：`NavigationPolicy.restorableConversationURL` 认可的 /c/… 或 /g/…/c/…，去掉查询参数和片段
/// （和 `lastConversationURL` 用同一个判断）。新对话页、登录页等没有对话地址的页不记，关闭后不能重新打开。
/// 查询参数里带临时聊天参数的地址不管路径都不记（`NavigationPolicy.isTemporaryChat`）。
/// 同一个地址关闭几次就记几次，不去重。不记标题。地址里有对话 id，要写日志时经过 `Redactor`。
public struct RecentlyClosedTabs: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let url: URL
        /// 关闭时从左数的位置（0 起）。之后的新增、关闭不改它。
        public let index: Int
    }

    public static let defaultLimit = 10

    public let limit: Int
    /// 最旧的在前，最近关闭的在最后。
    public private(set) var entries: [Entry] = []

    init(limit: Int = RecentlyClosedTabs.defaultLimit) {
        precondition(limit >= 1, "至少要能记一条")
        self.limit = limit
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// 下一次 ⇧⌘T 打开的那条。
    public var latest: Entry? { entries.last }

    /// 不是普通对话地址时不记，返回 false。
    @discardableResult
    mutating func record(url: URL?, index: Int) -> Bool {
        guard let url = NavigationPolicy.restorableConversationURL(url) else { return false }
        entries.append(Entry(url: url, index: index))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        return true
    }

    @discardableResult
    mutating func removeLatest() -> Entry? {
        entries.popLast()
    }
}
