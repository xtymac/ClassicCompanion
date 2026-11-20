import Foundation
import CompanionCore

/// 排版变化（切模式、拖边）前记下的一次阅读位置：哪个标签页、网页里这一次的编号，和判断它还属不属于那一页现在显示的内容时
/// 要用的、记下那一刻的样子（地址、适配器的导航代号、主框架提交计数，见 ReadingContinuity）。
/// 由 ChatTabs 建和处理（见它的“排版变化前后的阅读位置”一节）：排版结束时放回、请网页确认或丢弃；那时那一页不是选中的，
/// 就留在那一页上（ChatTab.pendingReadingRestore），等它再显示并排好版。
@MainActor
final class ReadingHold {
    /// 记下它的标签页。不持有：标签页关闭或拿掉以后，这一次就作废。
    weak var tab: ChatTab?
    /// 网页里这一次记下的编号（WebRuntime.holdReadingPosition() 返回的）。放回和丢弃都按它，不动别的编号。
    let token: Int
    /// 记下时这一页的地址（ChatTab.url）。
    let url: URL?
    /// 记下时适配器的导航代号：路径（主机加路径）每变一次加一（ChatTabs.urlChanged），query 变不算。
    let navigation: Int
    /// 记下时这一页的主框架提交计数（ChatTab.mainFrameCommits）。
    let commits: Int
    /// 已经放回、丢弃，或者标签页关闭了：之后什么都不再做。
    var isSettled = false

    init(tab: ChatTab, token: Int) {
        self.tab = tab
        self.token = token
        url = tab.url
        navigation = tab.adapter.generation
        commits = tab.mainFrameCommits
    }

    /// 按连续性规则，这一次记下的还属不属于 tab（记下它的那一页）现在显示的内容。
    func continuity(on tab: ChatTab) -> ReadingContinuity.Verdict {
        ReadingContinuity.verdict(saved: url, current: tab.url, pathChanges: tab.adapter.generation - navigation,
                                  commits: tab.mainFrameCommits - commits)
    }
}
