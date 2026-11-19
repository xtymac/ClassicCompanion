import Foundation
import CompanionCore

/// 一个聊天标签页自己的东西：网页运行时、适配器、页面加载状态，以及原来放在 AppDelegate 上、只属于这一页的两样：
/// 上次的页面路径（lastPath）和排着的聚焦输入框任务（focusTask）。
/// 这里只放东西，不做事：正式运行时用 make(id:diagnostics:settings:) 建（启动时的那个在 AppDelegate 里），
/// 测试也可以把建好的运行时和适配器交给 init；lastPath 和 focusTask 由 ChatTabs 的 urlChanged、focusInputSoon 改，
/// 和它们原来在 AppDelegate 里时一样。
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
    /// 排着的聚焦输入框任务。再次请求聚焦时先取消它；关闭标签页时也取消（ChatTabs.close(_:)）。
    var focusTask: Task<Void, Never>?

    /// 这个标签页的日志带的标签：就是它的运行时的（正式运行时是 id；测试里单独建的运行时不带，是 nil）。
    /// ChatTabs 为这个标签页写日志时用它（见 TabLog）。
    var logTag: TabID? { runtime.log.tab }

    /// 正式运行时建一个标签页：先建网页运行时（不自己看网络：网络状态由 ChatTabs 登记到全应用共用的那个上），
    /// 再建适配器，两者写的日志都带上标识 id 的标签。启动时的那个由 AppDelegate 这样建；以后新增的也这样建
    /// （交给 ChatTabs.add(_:)，标识由它从列表里发）。
    static func make(id: TabID, diagnostics: Diagnostics, settings: AppSettings) -> ChatTab {
        let runtime = WebRuntime(diagnostics: diagnostics, settings: settings, watchesNetwork: false, tab: id)
        let adapter = ChatGPTAdapter(webView: runtime.webView, diagnostics: diagnostics, settings: settings, tab: id)
        return ChatTab(id: id, runtime: runtime, adapter: adapter)
    }

    /// 运行时和适配器由调用方建好再交进来：建立顺序（运行时 → 适配器）留在调用方（正式运行是 make）。
    /// 运行时登记到网络状态由 ChatTabs 做（启动时的那个在 ChatTabs.init，之后的在 add）。
    /// 两者的日志要么都带这个标签页的标签，要么都不带（测试里单独建的），不能带别的标签页的。
    init(id: TabID, runtime: WebRuntime, adapter: ChatGPTAdapter, page: PageLoadState = PageLoadState()) {
        precondition(runtime.log.tab == adapter.log.tab && (runtime.log.tab == nil || runtime.log.tab == id),
                     "运行时和适配器的日志标签要是这个标签页的（或者都不带）")
        self.id = id
        self.runtime = runtime
        self.adapter = adapter
        self.page = page
    }
}
