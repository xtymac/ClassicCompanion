import AppKit
import CompanionCore

/// 一个页面加载到哪一步了。这里只放状态：什么时候改、怎么用，规则都还在 ChatWindowController 里。
/// 现在窗口只有一份（ChatWindowController.page），换网页视图时不跟着换。
@MainActor
final class PageLoadState {
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
    var colorBeforeFirstLoad: NSColor?
}
