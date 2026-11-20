import Foundation
import CompanionCore

/// 一个聊天标签页自己的东西：网页运行时、适配器、页面加载状态，以及原来放在 AppDelegate 上、只属于这一页的两样：
/// 上次的页面路径（lastPath）和排着的聚焦输入框任务（focusTask）。
/// 这里只放东西，不做事：正式运行时用 make(id:diagnostics:settings:) 建（启动时的那个在 AppDelegate 里），
/// 测试也可以把建好的运行时和适配器交给 init；lastPath 和 focusTask 由 ChatTabs 的 urlChanged、focusInputSoon 改，
/// 和它们原来在 AppDelegate 里时一样。阅读位置要用的几样（url、mainFrameCommits、pendingReadingRestore）也由 ChatTabs 改。
/// 应用里现在只有一个（启动时建的那个）。标题以后再加。排好版的大小不在这里：它跟着藏起的网页视图记在窗口里
/// （ChatWindowController.hideInContainer，和把它固定在离开时大小的约束在一起），再显示时窗口拿它决定要不要补排版。
@MainActor
final class ChatTab {
    /// 由 TabList 发放（TabID 只能从那里来）。
    let id: TabID
    let runtime: WebRuntime
    let adapter: ChatGPTAdapter
    /// 这一页加载到哪一步了。窗口显示这一页时，ChatWindowController.page 就是它。
    /// 建标签页时建，带这个标签页的日志标签（和运行时、适配器的一样，见 init）。
    let page: PageLoadState
    /// 上次的页面路径（主机加路径，不含 query）。只有路径变了才算换了页面。
    var lastPath: String?
    /// 排着的聚焦输入框任务。再次请求聚焦时先取消它；关闭标签页时也取消（ChatTabs.close(_:)）。
    var focusTask: Task<Void, Never>?
    /// 这一页现在的地址：运行时最近一次报的（含 query），ChatTabs.urlChanged 记。阅读位置的连续性规则拿它和记下时的比。
    var url: URL?
    /// 这一页的主框架提交过几次（每次提交，网页里就换了一份文档），ChatTabs 在运行时报提交时加一。
    /// 阅读位置的连续性规则用它看记下以后有没有提交过。
    var mainFrameCommits = 0
    /// 排版变化前记下的阅读位置，到该放回时这一页不是选中的：留在这里，等它再显示并按当前大小排好版
    /// （ChatTabs.tabShownAndLaidOut(_:)）再放回。一页最多一个（新的顶掉旧的，旧的丢弃）。
    /// 连续性规则说丢弃时（这一页在后台换了页面、提交过）当场丢弃并清掉网页里的；关闭标签页时丢掉（不碰网页）。
    var pendingReadingRestore: ReadingHold?
    /// 上一次读到的这一页的网页媒体状态（每秒读选中的那一页，ChatTabs.mediaTick()；只用来写“变了”的日志）。
    /// 每页一份：切换标签页后第一次读到的和换上来的这一页自己上次的比，不和换走的那一页的比。
    var mediaState = "none"

    /// 这个标签页的日志带的标签：就是它的运行时的（正式运行时是 id；测试里单独建的运行时不带，是 nil）。
    /// ChatTabs 为这个标签页写日志时用它（见 TabLog）。
    var logTag: TabID? { runtime.log.tab }

    /// 正式运行时建一个标签页：先建网页运行时（不自己看网络：网络状态由 ChatTabs 登记到全应用共用的那个上），
    /// 再建适配器，两者写的日志都带上标识 id 的标签。启动时的那个由 AppDelegate 这样建；新增的（ChatTabs.newTab()）也这样建：
    /// AppDelegate 把同一个建法交给 ChatTabs（makeTab），标识由 ChatTabs.add(_:) 从列表里发。
    static func make(id: TabID, diagnostics: Diagnostics, settings: AppSettings) -> ChatTab {
        let runtime = WebRuntime(diagnostics: diagnostics, settings: settings, watchesNetwork: false, tab: id)
        let adapter = ChatGPTAdapter(webView: runtime.webView, diagnostics: diagnostics, settings: settings, tab: id)
        return ChatTab(id: id, runtime: runtime, adapter: adapter)
    }

    /// 运行时和适配器由调用方建好再交进来：建立顺序（运行时 → 适配器）留在调用方（正式运行是 make）。
    /// 运行时登记到网络状态由 ChatTabs 做（启动时的那个在 ChatTabs.init，之后的在 add）。
    /// 两者的日志要么都带这个标签页的标签，要么都不带（测试里单独建的），不能带别的标签页的。
    /// 页面状态在这里建，带同一个标签（PageLoadState.logTag）：窗口给不显示的页面写的行也带这个标签页的标签。
    init(id: TabID, runtime: WebRuntime, adapter: ChatGPTAdapter) {
        precondition(runtime.log.tab == adapter.log.tab && (runtime.log.tab == nil || runtime.log.tab == id),
                     "运行时和适配器的日志标签要是这个标签页的（或者都不带）")
        self.id = id
        self.runtime = runtime
        self.adapter = adapter
        page = PageLoadState(logTag: runtime.log.tab)
    }
}
