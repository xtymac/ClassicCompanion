import Foundation
import CompanionCore

/// 一个聊天标签页自己的东西：网页运行时、适配器、页面加载状态，以及原来放在 AppDelegate 上、只属于这一页的两样：
/// 上次的页面路径（lastPath）和排着的聚焦输入框任务（focusTask）。
/// 这里只放东西，不做事：启动时的那个在 AppDelegate 里建，之后的由 ChatTabs.add 建；lastPath 和 focusTask
/// 由 ChatTabs 的 urlChanged、focusInputSoon 改，和它们原来在 AppDelegate 里时一样。
/// 应用里现在只有一个（启动时建的那个）。标题和排好版的大小以后再加。
@MainActor
final class ChatTab {
    /// 由 TabList 发放（TabID 只能从那里来）。
    let id: TabID
    let runtime: WebRuntime
    let adapter: ChatGPTAdapter
    /// 这一页加载到哪一步了。窗口显示这一页时，ChatWindowController.page 就是它。
    let page: PageLoadState
    /// 上次的页面路径（主机加路径，不含 query）。只有路径变了才算换了页面。
    var lastPath: String?
    /// 排着的聚焦输入框任务。再次请求聚焦时先取消它。
    var focusTask: Task<Void, Never>?

    /// 运行时和适配器由调用方建好再交进来：建立顺序（网络状态 → 运行时 → 适配器）留在调用方。
    /// 运行时登记到网络状态由 ChatTabs 做（启动时的那个在 ChatTabs.init，之后的在 add）。
    init(id: TabID, runtime: WebRuntime, adapter: ChatGPTAdapter, page: PageLoadState = PageLoadState()) {
        self.id = id
        self.runtime = runtime
        self.adapter = adapter
        self.page = page
    }
}
