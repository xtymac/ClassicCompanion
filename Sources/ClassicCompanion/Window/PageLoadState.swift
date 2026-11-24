import AppKit
import CompanionCore

/// 一个页面加载到哪一步了，包括它第一次加载的遮挡（启动画面或新标签页的遮挡）。这里只放状态：什么时候改、怎么用，规则都还在 ChatWindowController 里。
/// 窗口显示其中一个（ChatWindowController.page）。切换标签页时（ChatWindowController.display(_:webView:)）连同网页视图一起换，
/// 换上来的页面的这些状态投到窗口上。事件带着它属于的页面交给窗口：
/// 先改那个页面自己的这些状态，只有它显示着时窗口才跟着变；不显示的页面的事件只改它自己的状态。
@MainActor
final class PageLoadState {
    /// 第一次加载的遮挡是哪一种。两种的规则、时限、上限相同（同一套，在 ChatWindowController 里），样子不同：
    /// - launch：启动画面，启动时的那个页面用（图标、应用名、小进度圈）。
    /// - newTab：新标签页的遮挡（只有页面底色和小进度圈，没有图标和应用名）。它另外在页面开始显示时就撤，不等加载完成
    ///   （ChatWindowController.pageDidReportColor(_:_:)，用户 11-21 定）；日志那一行带它的标签。
    enum CoverKind { case launch, newTab }

    /// 这个页面属于哪个标签页：它的日志带的标签（TabLog）。正式运行时每个页面都有（ChatTab 建页面时给它的运行时的标签，
    /// 就是标签页的标识）；测试里单独建的页面、单独建的运行时的页面没有（nil）。窗口用它给不显示的页面写行（见
    /// ChatWindowController.endLaunchScreen(_:for:)）。
    let logTag: TabID?

    init(logTag: TabID? = nil) {
        self.logTag = logTag
    }

    /// 主框架提交过（窗口里有页面）。
    var hasCommittedPage = false
    /// 主框架已提交、还没加载完成。
    var awaitingFinish = false
    /// “无法连接”提示正在显示的状态，.hidden 是没显示。窗口的提示（内容和那一层显不显示）只照它投出来，
    /// 见 ChatWindowController.applyNotice()。
    /// 留到加载完成时（noticeAwaitsLoad）：WebRuntime 已经说可以收起，这里仍是收起前的状态，提示照样显示。
    /// 淡出时：这里已是 .hidden、提示那层已藏起，盖在上面淡出的是另一层（窗口的动画，不算页面状态）。
    var notice: LoadRecovery.Status = .hidden
    /// 提示收到“可以收起”时网页刚提交、还没画出来：留到加载完成再淡出。
    var noticeAwaitsLoad = false
    /// 每次提交和加载完成时加一。提交后的兜底只在代号没变时生效。
    var commitGeneration = 0
    /// 启动保护：从启动画面出现到网页第一次加载完成，不采用 WebKit 报的页面底色。这段时间顶部一条、启动画面、
    /// 窗口底色和“无法连接”提示保持启动时的颜色（上次记下的页面颜色，没有就跟随系统），也不保存。
    /// 2026-11-14 冷启动复现：深色启动画面在网页提交前变浅，加载完成后才变回深色。按日志时间推算，那时报出的浅色
    /// 还不是 ChatGPT 页面的颜色；这是推断，日志没有记下颜色数值。
    /// 加载失败和启动画面到时限都不解除：那时窗口里可能还没有页面。之后哪一次加载完成都会解除。
    var holdsPageColor = false
    /// 解除启动保护时 WebKit 报着的颜色。它在加载完成前就有了，可能还是临时颜色：先不采用，等页面颜色变化；
    /// 到 pageColorSettleLimit 还没变，再按当前颜色采用（页面本来就是这个颜色）。
    /// 只给显示着的页面设：窗口只观察显示着的网页视图，等颜色变化和到时限采用都是窗口的事。
    /// 还没等完就被换走的页面留着它，再显示时重新等（ChatWindowController.showPageColor(of:)）。
    var colorBeforeFirstLoad: NSColor?
    /// 不显示时解除启动保护的时刻（窗口没有替它等颜色）。换上它显示时用一次就清掉：离这时还不到 pageColorSettleLimit，
    /// 就照刚解除时一样等完剩下的时间（ChatWindowController.showPageColor(of:)）。
    var releasedWhileHidden: Date?
    /// 第一次加载已经完成（之后一直是 true）。在这之前页面报的底色可能是加载完成前的临时颜色，不能采用（见 holdsPageColor）。
    /// 和 colorAtLastFinish 一起看：那个颜色本身可以是 nil，靠它分清“还没加载完成过”和“加载完成时没有报颜色”。
    var hasFinishedFirstLoad = false
    /// 最近一次加载完成时这个页面报的底色（调用方带进来的网页视图 underPageBackgroundColor，nil 是 WebKit 没有报颜色）。
    /// 每个页面加载完成时都记，和 hasFinishedFirstLoad 一起写。窗口只观察显示着的网页视图，不显示的页面的颜色只有这一份记录。
    /// 切换到这个页面时，它不显示时刚解除启动保护（releasedWhileHidden）的话，拿它当“加载完成前的颜色”等变化。
    var colorAtLastFinish: NSColor?

    // 第一次加载的遮挡（启动画面、新标签页的遮挡）：这个页面自己的那一份。开始、到时限、到上限、提交后兜底、加载完成和失败
    // 结束它的规则在 ChatWindowController 里（beginLaunchScreen()、beginNewTabCover(for:)、endLaunchScreen(_:for:)），
    // 不管页面显不显示都照常改这几项；窗口的遮挡那层只照显示着的页面的 isCovered 和 coverKind 显示（applyCover(_:)）。
    // 不显示的页面的遮挡变了，窗口上什么都不变。

    /// 遮挡还盖着：开始了、还没结束。
    var isCovered = false
    /// 遮挡是哪一种。每次开始遮挡时设，结束以后留着（结束时淡出的那层照它）。没开始过时是 launch（窗口那层原来的样子）。
    var coverKind = CoverKind.launch
    /// 到时限时网页还没提交，遮挡继续盖着，等加载完成、加载失败、提交后兜底或上限。
    var coverAwaitsCommit = false
    /// 每次开始遮挡加一。遮挡的时限和上限只在还是排下它们的那一次时起作用。
    var coverGeneration = 0
    /// 这一次遮挡开始的时刻（结束时日志里的耗时从这里算）。
    var coverStarted = Date()

    // 等对话内容（只有带对话地址打开的新标签页：⇧⌘T 重新打开、⌘ 点击和 ⇧⌘ 点击对话链接）。ChatGPT 是单页应用：
    // 网页提交、报出底色、加载完成时出来的还只是外壳（看起来就是空的新聊天页），对话内容随后才取来、排出来。
    // 这种遮挡不在外壳出来时撤，等对话内容出来（ChatWindowController.conversationDidShow(_:)）；规则都在 ChatWindowController 里。

    /// 这一次遮挡等对话内容。开始遮挡时定（beginNewTabCover(for:awaitingContent:)），结束时清掉。
    var coverAwaitsContent = false
    /// 该等对话内容的那段时限了：外壳已经出来（原来这时就撤），或者不显示时到了别的兜底（时限、上限）。
    /// 显示着时马上开始等（contentWaitLimit），不显示时等它显示时再开始。
    var contentWaitDue = false
    /// 等对话内容的那段时限正在走（只在显示着时开始）。
    var contentWaitRunning = false
    /// 每次开始等对话内容的时限、每次开始遮挡加一。时限到点时只在还是排下它的那一次时起作用。
    var contentWaitGeneration = 0

    /// 这个页面已经关闭（关闭标签页）。只由 ChatWindowController.pageClosed(_:) 设，不会改回。
    /// 关了以后它的事件和它排着的回调都不起作用：上面这些状态停在关闭那一刻，窗口也不因它而变（规则在 ChatWindowController 里）。
    var isClosed = false
}
