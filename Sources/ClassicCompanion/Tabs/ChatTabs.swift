import AppKit
import CompanionCore

/// 标签页和窗口之间的接线：把每个标签页的网页运行时的回调接到窗口上（wire(_:)），加上换页面（urlChanged）和聚焦输入框
/// （focusInputSoon）。原来都写在 AppDelegate 里，搬过来是为了能在不建 AppDelegate、不开应用的测试里核对这些顺序
/// （LaunchWiringTests、TabEventOwnershipTests）：冷启动看起来对不对就靠它们。
/// 对选中的标签页做的操作（新对话、⌘R、窗口显示后、排版变化前后的阅读位置、每秒的媒体状态、证据采集和媒体实验）
/// 和改设置时每个标签页都要跟着改的几样也在这里，AppDelegate 只调用。
///
/// 这里有一组标签页（tabs，按从左到右）和选中的那个（selected）。顺序、选中项和标识都由 list（TabList）决定。
/// 换选中的只经 select(_:)（切换标签页：先改选中项，再让窗口显示它，再做跟着它的事）。新增标签页只经 newTab()，
/// 关闭标签页只经 closeTab(_:)（closeSelectedTab()），重新打开最近关闭的只经 reopenClosedTab()。
/// 开始时只有启动时的那一个，它就是选中的、窗口显示着的。应用里调用这些入口的只有按键（3.10，handleKey(_:_:)：⌘T、⇧⌘T、
/// ⌘W、⇧⌘W、切换的键）；还没有标签栏和菜单（3.11、阶段 4）。不按这些键时一直只有启动时的那一个，和原来一样。
///
/// 规则：事件属于发出它的标签页，接线时就绑定那个标签页，处理时明确传着它，不在中途拿“现在选中的”来代替。
/// - 标签页自己的状态（页面加载状态、lastPath、适配器的代号、它自己的日志）不管选没选中都照常改。
/// - 窗口和全应用的事（隐藏窗口、聚焦输入框、记下可恢复的对话地址）只在它是选中的标签页时做。
///   页面加载状态的窗口部分由 ChatWindowController 判断（只有显示着的页面动窗口），这里不重复判断。
/// - 排着的任务（80ms 后聚焦、0.8 秒后记媒体状态）带着排下它的标签页（weak），到点时它不再是对的对象就不做。
/// - 网页的对话框（提示框、确认框、文件选择）：选中的标签页的马上显示；别的标签页的排在它自己身上，等它被选中再显示
///   （select(_:)），它关闭时按取消处理（WebRuntime.cancelDialogs()；关显示着的那一页时在切换到邻居之前，见 closeTab(_:)）。
///   别的标签页要开新窗口（登录等弹窗）：不开（用户 11-20 定：切回那一页再点一次）。
///   文件选择不是模态的：开着时切换走，它不收起，结果照样给发出它的那一页（用户 11-20 定）。
/// 操作也一样：对选中的标签页做的操作在开始这一刻取选中的那个，之后一直明确传着它，等过之后（await、定时、窗口的下一个回调）
/// 不再回来读“现在选中的”。等完先看它还在不在这组里，不在就不做；会被更新的请求取代的（聚焦）还看代号。
/// 后台的事从不改前台。设置（网页增强、页面缩放、网页无障碍、弹窗标题）每个标签页都改。
/// 每个标签页的运行时在这组里时都登记在共用的网络状态上（NetworkStatus 只通知，重试与否由各页自己的恢复规则决定），
/// 离开这组时去掉（tabLeft(_:)）。关闭标签页的收尾见 close(_:)：先让它的运行时、适配器和页面状态进入关闭态，再拿掉。
/// 这里写的某个标签页的日志（页面变化、媒体状态、实验）带那个标签页的标签（TabLog，见 log(_:_:_:)）；窗口的日志不带
/// （例外：不显示的页面的遮挡结束时窗口写的那一行带那一页的标签，见 ChatWindowController.endLaunchScreen(_:for:)）。
/// 选中的标签页和窗口显示着的页面要一致：启动时建窗口传的就是启动的那个标签页的 page；之后 select(_:) 两边一起换
/// （测试另有 selectForTesting，只换这两样）。
///
/// 要用到的 AppDelegate 的东西由 AppDelegate 交进来（正式运行时的做法写在各项旁边），测试换成记录。
@MainActor
final class ChatTabs {
    /// 顺序、选中项、上限，和标识的来源（TabID 只能由 TabList 发放）。tabs 和它一一对应、顺序相同。
    private(set) var list: TabList
    /// 从左到右，和 list.tabs 一样的顺序。
    private(set) var tabs: [ChatTab]
    private let windowController: ChatWindowController
    private let diagnostics: Diagnostics
    /// 全应用共用的网络状态。这组里的每个标签页的运行时都登记在上面。
    private let network: NetworkStatus
    /// 隐藏窗口，参数是写进日志的原因。AppDelegate：windowController.hide(reason:)。
    private let hideWindow: @MainActor (String) -> Void
    /// 聚焦官方输入框，返回结果代码。AppDelegate：适配器的 focusInput()。
    private let focusInput: @MainActor (ChatGPTAdapter) async -> String
    /// 记下可以恢复的对话地址。AppDelegate：settings.lastConversationURL。
    private let saveLastConversation: @MainActor (URL) -> Void
    /// 网页媒体状态，只写日志。AppDelegate：适配器的 webMediaState()。
    private let mediaState: @MainActor (ChatGPTAdapter) async -> String
    /// 在页面里点官方的“新对话”入口，确定没点到时返回 false（调用方再整页加载）。AppDelegate：适配器的 openNewChatInPage()。
    /// 它要在真实页面里跑脚本，所以交进来：测试换成记录，并且能在它等着的时候换选中的标签页。
    private let openNewChat: @MainActor (ChatGPTAdapter) async -> Bool
    /// 新增标签页（newTab()）时用标识建一个标签页。AppDelegate：建启动时的那个标签页用的同一个建法（ChatTab.make，
    /// 同一份诊断和设置），所以新的那一页建的时候就照现在的设置（页面缩放、网页增强、网页无障碍）。
    /// 测试换成同样的建法再让加载请求不发出去。不新增标签页的测试可以不交（nil）；没交就调用 newTab() 是用错了（断言）。
    private let makeTab: (@MainActor (TabID) -> ChatTab)?
    /// 找回窗口（D9：窗口没显示时新增标签页，先找回窗口再新增）。AppDelegate：windowController.reveal()
    /// （点 Dock、⌘Tab 找回窗口的同一个入口，保持现在的模式）。测试换成记录：测试不显示窗口。
    /// 和 makeTab 一样，不新增标签页的测试可以不交；没交就调用 newTab() 是用错了（断言）。
    private let revealWindow: (@MainActor () -> Void)?
    /// 窗口是不是 key 窗口（加载完成时据此决定要不要聚焦）。就是 windowController.isKey；
    /// 只有测试换它：测试不显示窗口，窗口不会成为 key 窗口。
    var windowIsKey: @MainActor () -> Bool
    /// 窗口显示着：可见，并且没有最小化到 Dock（新增标签页时据此决定要不要先找回窗口）。就是窗口的 isVisible、isMiniaturized；
    /// 只有测试换它：测试不显示窗口，窗口总是不可见。
    var windowIsVisible: @MainActor () -> Bool
    /// 到上限还要新增标签页时的提示音（阶段 3 的占位，D8：以后换成“最多打开 4 个标签页”的提示）。就是 NSSound.beep()；
    /// 只有测试换它：测试不出声。
    var beep: @MainActor () -> Void = { NSSound.beep() }
    /// 记下、放回、丢弃阅读位置：就是运行时的 holdReadingPosition()（返回这一次的编号）、
    /// restoreReadingPosition(_:confirmingContinuation:)（编号、要不要网页确认）、discardReadingPosition(_:)（编号）。
    /// 只有测试换它们：网页里没有页面，看不到效果，换成记录才看得出给了哪个标签页、哪一次。
    var holdReadingPosition: @MainActor (WebRuntime) -> Int = { $0.holdReadingPosition() }
    var restoreReadingPosition: @MainActor (WebRuntime, Int, Bool) -> Void = {
        $0.restoreReadingPosition($1, confirmingContinuation: $2)
    }
    var discardReadingPosition: @MainActor (WebRuntime, Int) -> Void = { $0.discardReadingPosition($1) }
    /// 证据采集和媒体实验对一个标签页做的事交给谁。就是 TabEvidenceTarget(tab:)（它的适配器和网页视图）；
    /// 只有测试换它：真的步骤要真实页面，换成记录才能在步骤之间换选中的标签页、看每一步对哪个标签页做。
    var evidenceTarget: @MainActor (ChatTab) -> any EvidenceTarget = { TabEvidenceTarget(tab: $0) }
    /// 聚焦请求的代号，每次 focusInputSoon(for:) 请求聚焦、每次切换标签页（select(_:)）都加一（不管是哪个标签页的）。
    /// 窗口里只有一个键盘焦点，最新的请求说了算：排着的聚焦到点时代号变了就不做，哪怕它的标签页又被选中了（选中 A → B → A）。
    private var focusGeneration = 0
    /// 排版变化前记下阅读位置、窗口还没说排版结束的，按记下的先后（和窗口的前后两个回调一一配对）。
    /// 其中已经丢弃的（isSettled）留在原位、到时什么都不做。见 holdReadingPositionForLayout()。
    private var readingHolds: [ReadingHold] = []

    /// list：启动时的列表，只有 tab 一个、并且选中它（tab 的标识就是从它来的）。
    /// 窗口在这之前已经用 tab 的网页视图和 page 建好：所以选中的标签页和窗口显示着的页面一开始就一致。
    /// 提示里的“重新加载”、窗口显示后、排版变化前后、切模式时的快照和排版是窗口的，在这里接一次（各自对选中的标签页做，
    /// 见 reloadSelectedTab()、windowDidShow(_:)、holdReadingPositionForLayout()、restoreReadingPositionAfterLayout()），
    /// wire(_:) 不再改它们。
    /// tab 的运行时在这里登记到 network。原来 AppDelegate 在建好运行时之后马上登记；那时和这里之间都在同一轮里同步执行，
    /// 网络状态的第一次报告要等回到主队列才到，登记时还不知道状态，什么都不补发，所以挪到这里看不出差别。
    /// makeTab、revealWindow 只有新增标签页（newTab()）用，见各自的说明。
    init(list: TabList, tab: ChatTab, windowController: ChatWindowController, diagnostics: Diagnostics,
         network: NetworkStatus,
         hideWindow: @escaping @MainActor (String) -> Void,
         focusInput: @escaping @MainActor (ChatGPTAdapter) async -> String,
         saveLastConversation: @escaping @MainActor (URL) -> Void,
         mediaState: @escaping @MainActor (ChatGPTAdapter) async -> String,
         openNewChat: @escaping @MainActor (ChatGPTAdapter) async -> Bool,
         makeTab: (@MainActor (TabID) -> ChatTab)? = nil,
         revealWindow: (@MainActor () -> Void)? = nil) {
        precondition(list.tabs == [tab.id] && list.selected == tab.id, "启动时只有这一个标签页，并且选中它")
        self.list = list
        tabs = [tab]
        self.windowController = windowController
        self.diagnostics = diagnostics
        self.network = network
        self.hideWindow = hideWindow
        self.focusInput = focusInput
        self.saveLastConversation = saveLastConversation
        self.mediaState = mediaState
        self.openNewChat = openNewChat
        self.makeTab = makeTab
        self.revealWindow = revealWindow
        windowIsKey = { windowController.isKey }
        windowIsVisible = { windowController.window.map { $0.isVisible && !$0.isMiniaturized } ?? false }
        windowController.onReloadRequest = { [weak self] in self?.reloadSelectedTab() }
        windowController.onDidShow = { [weak self] kind in self?.windowDidShow(kind) }
        windowController.onWillChangeLayout = { [weak self] in self?.holdReadingPositionForLayout() }
        windowController.onDidChangeLayout = { [weak self] in self?.restoreReadingPositionAfterLayout() }
        // 切模式时的快照和按目标大小排版：窗口这一刻显示着的页面，也就是这一刻选中的标签页。
        // 切换标签页后的补排版也用这个排版（窗口在显示换上来的页面以后调用，那时选中的已经是它）。
        windowController.onSnapshotPage = { [weak self] done in
            guard let self else { return done(nil) }
            self.selected.runtime.snapshotPage(done)
        }
        windowController.onPrepareLayout = { [weak self] size, done in
            guard let self else { return done() }
            self.selected.runtime.prepareLayout(size: size, done: done)
        }
        // 标签页的键（含 ⌘W）：窗口的按键监视认出来以后交给这里（handleKey(_:_:)）。
        windowController.onTabKey = { [weak self] key, context in self?.handleKey(key, context) ?? false }
        network.add(tab.runtime)
    }

    /// 选中的标签页。
    var selected: ChatTab {
        guard let tab = tabs.first(where: { $0.id == list.selected }) else { preconditionFailure("选中项不在标签页里") }
        return tab
    }

    /// tab 是不是选中的那个（按对象比，不只比标识）。
    func isSelected(_ tab: ChatTab) -> Bool {
        selected === tab
    }

    /// tab 还在这组标签页里。
    func holds(_ tab: ChatTab) -> Bool {
        tabs.contains { $0 === tab }
    }

    /// 启动画面还在：这组里有页面的启动画面（启动时的那种遮挡）还盖着，到时限后还在等提交也算
    /// （ChatWindowController.coversWithLaunchScreen(_:)）。只有启动时的那个标签页会有：启动画面只在启动时开始一次
    /// （beginLaunchScreen()）。新标签页的遮挡不算，窗口那层显不显示也不看（看的是页面自己的遮挡状态）。
    /// 计划 4.3“启动画面还在的时候不能新增标签页”：新增标签页的入口 newTab() 在它为 true 时不加
    /// （以后的菜单置灰、按键不响应也看它）。
    var isLaunchScreenUp: Bool {
        tabs.contains { windowController.coversWithLaunchScreen($0.page) }
    }

    /// 加一个标签页：放在最右，不选中，接好线，登记到网络状态。标识从 list 来，先发标识再由 make 用它建标签页
    /// （正式运行是 ChatTab.make：运行时和适配器建的时候就知道自己的标识，日志从第一行起带标签）。
    /// 已到上限时返回 nil，什么都不加，也不调用 make。新增标签页的入口 newTab() 经它加（建法是 makeTab）；
    /// 测试也用它加一个从不显示的标签页。
    func add(_ make: (TabID) -> ChatTab) -> ChatTab? {
        guard case .added(let id) = list.append(select: false) else { return nil }
        return adopt(id, make)
    }

    /// list 刚放进去、不选中的标识 id：用 make 建标签页，放进 tabs 里和 list 一样的位置，接好线，登记到网络状态。
    /// 加在最右（add(_:)）和放回原位置（reinsertClosedTab(_:)）都经这里：放在哪由 list 定，tabs 照抄 list 的位置，
    /// 两者顺序总是一样。make 运行的那一会儿 list 已经有它、tabs 还没有；这时这里的代码都不运行（make 只建标签页）。
    private func adopt(_ id: TabID, _ make: (TabID) -> ChatTab) -> ChatTab {
        let tab = make(id)
        precondition(tab.id == id, "新标签页要用这次发的标识")
        guard let index = list.tabs.firstIndex(of: id) else { preconditionFailure("list 里刚放进去的标识") }
        tabs.insert(tab, at: index)
        wire(tab)
        // 接好线再登记：已经知道网络状态时马上补发给它（断网时加进来的页面也等得到“网络恢复”），
        // 补发引起的变化照常到它自己的页面状态。
        network.add(tab.runtime)
        return tab
    }

    /// 测试用：运行时和适配器已经建好（日志不带标签），加成一个标签页。别的和 add(_:) 一样。
    func add(runtime: WebRuntime, adapter: ChatGPTAdapter) -> ChatTab? {
        add { ChatTab(id: $0, runtime: runtime, adapter: adapter) }
    }

    /// 写标签页 tab 的事：写进这组的诊断（和原来一样），行末带 tab 的标签（它的运行时带标签时，见 ChatTab.logTag）。
    private func log(_ tab: ChatTab, _ category: String, _ message: String) {
        TabLog(diagnostics: diagnostics, tab: tab.logTag)(category, message)
    }

    /// 写这组的事，不属于哪一个标签页（不新增标签页、先找回窗口）：不带标签。
    private func logGroup(_ category: String, _ message: String) {
        TabLog(diagnostics: diagnostics, tab: nil)(category, message)
    }

    /// 标签页离开这组时：从共用的网络状态上去掉，之后的网络变化不再送给它。close(_:) 和测试的 removeForTesting(_:) 调用。
    private func tabLeft(_ tab: ChatTab) {
        network.remove(tab.runtime)
    }

    // MARK: - 关闭标签页

    /// 关闭标签页 tab（3.7）。应用里经 closeSelectedTab() 由 ⌘W 调用（3.10）；菜单在 3.11、标签栏在阶段 4 接上。
    ///
    /// - tab 不在这组里（关过了、不是这组的）：什么都不做（不隐藏窗口、不写日志），所以关两遍是安全的。
    /// - 只有一个标签页（它就是选中的）：不关、不释放，页面留着；和原来的 ⌘W 一样隐藏窗口（hideWindow("⌘W")，
    ///   窗口写的就是原来 ⌘W 的那一行“隐藏：⌘W”），不写别的日志，也不记入最近关闭（它没关）。
    /// - 多个标签页：先写一行“[tabs] 关闭（剩 N 个）”（带 tab 的标签，N 是关闭以后的个数；没有地址和标题），然后
    ///   - tab 不是选中的：收尾（close(_:)）。选中项、窗口都不变。
    ///   - tab 是选中的（窗口显示着它）：
    ///     1. 下一个选中谁问 TabList（list.selectionAfterClosing(_:)：右边的邻居，没有就左边），这时列表还不改。
    ///     2. 先取消 tab 的网页对话框（WebRuntime.cancelDialogs()，用户 11-20 的裁定：先取消旧页面的对话框请求，再处理邻居）：
    ///        排着的、放出来还没显示的、显示着的都按取消回答（提示框结束、确认框 false、文件选择收起并给 nil），各正好一次；
    ///        之后 tab 再来的对话框也马上按取消回答、不显示。这时 tab 还是选中的、还没关闭：放出来还没显示的那一个醒来时
    ///        tab 已经不是选中的，看到已经按取消处理，按取消回答，不会放回去排着。下一步换上的邻居排着的对话框在这之后才放出来，
    ///        所以 tab 的回答先于邻居的对话框显示（被继续的任务按先后在之后的几轮里跑）。取消的种类和个数仍写在第 5 步关闭那一行。
    ///     3. tab 记下的阅读位置都作废（dropReadingPositions(of:)）：下一步结束进行中的切模式时，它那次不会被留到“再显示”
    ///        （它不会再显示），也不碰它的网页。
    ///     4. 切换到下一个（select(_:)）：选中项先改成还在的那一页；窗口换上那一页，投上那一页自己的遮挡、提示和颜色
    ///        （tab 的启动画面或新标签页的遮挡不会留在窗口上；还在淡出的那层去掉），tab 的补排版作废（不调用它的 laidOut），
    ///        进行中的切模式结束，tab 的网页视图换下去、藏在窗口里。聚焦和记下的对话地址（lastConversationURL）跟着那一页，
    ///        邻居排着的对话框放出来，都由 select 做，这里不另外做。
    ///     5. 收尾（close(_:)）：这时 tab 已经不是选中的，和关不选中的一样，其中把它的网页视图从窗口里拿出来；
    ///        运行时关闭时对话框已经取消过，不再取消，关闭那一行照样写上第 2 步取消的种类和个数。
    ///   tab 不是选中的：对话框由收尾时运行时关闭（WebRuntime.close()）取消，顺序和以前一样（窗口不换，没有邻居要处理）。
    ///   两种都在收尾时记入最近关闭（close(_:) 第 7 步）：地址是 tab 这时的地址，位置是它这时在列表里的位置
    ///   （切换只改选中项，不改位置）。
    ///   为什么先切换再关：list 和 tabs 只在收尾时一起改一次，切换只改选中项，所以任何时候两者一一对应，选中项也总指着
    ///   tabs 里还在的那一页（selected 不会落空）；切换用的就是平常的 select，不另写一份显示别的页面的做法。
    ///   如果先让 TabList 关掉（它在一步里拿掉并改选中项），窗口那时还显示着 tab，select 又因为邻居已经是选中的而什么都不做。
    func closeTab(_ tab: ChatTab) {
        guard holds(tab) else { return }
        guard tabs.count > 1 else {
            hideWindow("⌘W")
            return
        }
        log(tab, "tabs", "关闭（剩 \(tabs.count - 1) 个）")
        if isSelected(tab) {
            guard let nextID = list.selectionAfterClosing(tab.id), let next = tabs.first(where: { $0.id == nextID }) else {
                preconditionFailure("多于一个标签页时关选中的，TabList 给出还在的下一个")
            }
            tab.runtime.cancelDialogs()
            dropReadingPositions(of: tab)
            select(next)
        }
        close(tab)
    }

    /// 关闭选中的标签页（⌘W，handleKey(_:_:)）：closeTab(_:) 按下这一刻选中的那个。
    func closeSelectedTab() {
        closeTab(selected)
    }

    /// 关闭标签页 tab 的收尾：之后它的任何事件、通知和计时都不再起作用，这组不再持有它（别处也不持有时，它连同运行时、
    /// 适配器、页面状态和网页视图一起释放）。入口是 closeTab(_:)；测试也直接调用。
    ///
    /// 前提：tab 不是选中的（窗口显示的不是它）。关选中的标签页由 closeTab(_:) 先切换到别的标签页，这里不选下一个、
    /// 不换网页视图、不投别的页面的状态。只有一个标签页时它就是选中的，所以也不能关（closeTab：⌘W 隐藏窗口，不释放）。
    /// tab 已经不在这组里（关过了，或者不是这组的）：什么都不做，所以关两遍是安全的。这里不写 [tabs] 那一行（closeTab 写）。
    ///
    /// 顺序：先进入关闭态，再收尾。
    /// 1. 运行时关闭（WebRuntime.close()）：不再自己发起加载、不再排重试，排着的重试取消，停止加载，回调断开，停掉地址观察和
    ///    消息桥，弹窗关掉；排着的网页对话框不再显示、显示着的文件选择收起，都按取消回答网页（关显示着的标签页时 closeTab
    ///    在切换之前已经取消过，这里不再做）；之后迟到的导航事件、网页脚本的回调都不做事、不写日志。
    /// 2. 适配器关闭（ChatGPTAdapter.close()）：不再在网页里跑脚本、不再读媒体状态，进行中的脚本返回或超时以后不写日志、
    ///    不写诊断。
    /// 3. 页面状态关闭（ChatWindowController.pageClosed(_:)）：带这个页面的入口和它排着的兜底、颜色回调、遮挡的时限和上限
    ///    都不再起作用，也不能再显示。
    /// 4. 它的网页视图显示过、换下去后藏在窗口里的，从窗口里拿出来（ChatWindowController.removeHiddenWebView(_:)）：
    ///    窗口不再持有它。
    /// 5. 排着的聚焦任务取消（到点本来也因为它不是选中的而不做，这里让它马上结束、不再等）。
    /// 6. 它记下的阅读位置都作废（dropReadingPositions(of:)，不碰网页）。
    /// 7. 从列表（list）和 tabs 里一起拿掉，两者始终一一对应。拿掉时列表记入最近关闭（TabList.close(_:url:)）：
    ///    地址是 tab 在收尾开始那一刻的地址（tab.url，运行时最近一次报的；第 1 步停止加载之前取），是普通对话地址
    ///    （NavigationPolicy.restorableConversationURL）才记，去掉查询参数，连同它这时的位置；新对话页、登录页、
    ///    还没有地址的都不记。只在内存里，最多 10 条，不去重。这里不写地址（只有 closeTab 那一行，没有地址）。
    /// 8. 从共用的网络状态上去掉（tabLeft）。
    ///
    /// 不取消的（没有取消的办法）：进行中的新对话、证据采集和媒体实验、每秒的媒体状态、页面变化后的媒体日志、正在等页面结果的聚焦。
    /// 它们正在等的那一步返回后在 holds 检查处停下（不加载、不聚焦、不写诊断和日志）；适配器已经关闭，剩下的步骤也不再碰网页。
    /// 在那一步返回之前它们还拿着这个标签页，所以释放要等那一步返回或超时（正式运行时由适配器的脚本时限兜底）。
    /// 补排版：只有显示着的标签页会补排版，tab 不选中，它显示时开始的那次在切换走时已经作废（窗口不再调用它的 laidOut），
    /// 迟到的排版完成和时限也不再做事（窗口按那一次的身份核对）。
    func close(_ tab: ChatTab) {
        guard holds(tab) else { return }
        precondition(!isSelected(tab), "关选中的标签页要先切换到别的标签页（closeTab(_:)）")
        let address = tab.url
        tab.runtime.close()
        tab.adapter.close()
        windowController.pageClosed(tab.page)
        windowController.removeHiddenWebView(tab.runtime.webView)
        tab.focusTask?.cancel()
        tab.focusTask = nil
        dropReadingPositions(of: tab)
        let result = list.close(tab.id, url: address)
        precondition(result == .closed(selectionChanged: false), "不选中的标签页从列表里拿掉，选中项不变")
        tabs.removeAll { $0 === tab }
        tabLeft(tab)
    }

    /// 关闭 tab 时它记下的阅读位置都作废：留着等再显示的那一次（pendingReadingRestore）拿掉；排版中记下的（readingHolds 里
    /// 它的那几条）标成已结束、留在原位（记下和放回按先后一一配对，不能拿掉一条），到时什么都不做。
    /// 都不碰网页（它要关闭了，网页随标签页一起释放）、不写日志。
    private func dropReadingPositions(of tab: ChatTab) {
        tab.pendingReadingRestore?.isSettled = true
        tab.pendingReadingRestore = nil
        for hold in readingHolds where hold.tab === tab {
            hold.isSettled = true
        }
    }

    /// 把标签页 tab 的网页运行时的回调接到窗口上。启动时 AppDelegate 在原来接这些的地方调用，add(_:) 也调用。
    /// 每个闭包都绑定这个 tab（weak：闭包挂在 tab 的运行时上，强引用会成环），事件按它处理。
    /// page 和 webView 是 tab 的常量（let），接线时取和回调时取是同一个对象；闭包持有它们不成环（它们不持有运行时）。
    func wire(_ tab: ChatTab) {
        let page = tab.page, webView = tab.runtime.webView
        tab.runtime.onURLChange = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.urlChanged(url, for: tab)
        }
        // 隐藏窗口是窗口的事：只有选中的标签页的 Esc 才隐藏。
        tab.runtime.onEscapeRequest = { [weak self, weak tab] in
            guard let self, let tab, self.isSelected(tab) else { return }
            self.hideWindow("网页 Esc")
        }
        // 页面加载完成时结束启动画面；若窗口在前台，再尝试聚焦一次（唤醒时页面可能尚未就绪）。
        // 结束启动画面和加载完成都带着这个标签页的页面交给窗口：遮挡（启动画面）是这个页面自己的，不显示时也照常结束；
        // 窗口只在它显示着时动（规则在 ChatWindowController 里）。
        // 聚焦只给选中的标签页。
        tab.runtime.onMainFrameLoaded = { [weak self, weak tab] in
            guard let self else { return }
            self.windowController.endLaunchScreen("网页已加载", for: page)
            // 网页第一次加载完成才恢复跟随页面底色；加载失败、启动画面到时限都不恢复，等之后哪次加载完成。
            // 报的颜色是这个标签页的网页视图此刻报的（不显示的标签页只记在它的页面状态里）。
            self.windowController.pageDidFinishLoading(page, reportedColor: webView.underPageBackgroundColor)
            if let tab, self.isSelected(tab), self.windowIsKey() { self.focusInputSoon(for: tab) }
        }
        // 加载失败时结束启动画面。WebKit 不显示错误页：首次加载失败时窗口里没有页面，
        // 由 WebRuntime 自动重试（退避、限次、断网不发请求），窗口盖“无法连接”提示，⌘R 和提示里的按钮显式加载失败的地址
        // （2026-11-11 开机白屏）。
        tab.runtime.onLoadFailed = { [weak self] in self?.windowController.endLaunchScreen("加载失败", for: page) }
        tab.runtime.onLoadProblemChange = { [weak self] status in self?.windowController.showLoadProblem(status, for: page) }
        // 提交时先告诉窗口：到时限后还在的启动画面和留着的提示要等加载完成（或提交后 1 秒）再撤。
        // 再记下这一页提交过：网页里换了一份文档，之前记下的阅读位置都不再属于它（mainFrameCommitted(_:)）。
        tab.runtime.onMainFrameCommitted = { [weak self, weak tab] in
            guard let self else { return }
            self.windowController.pageDidCommit(page)
            if let tab { self.mainFrameCommitted(tab) }
        }
        // 网页的对话框（提示框、确认框、文件选择）和新窗口按“它是不是选中的标签页”：是就和原来一样马上显示、照常开；
        // 不是就把对话框排在它自己身上，等它被选中再显示（select(_:) 最后放出来），新窗口不开（规则在 WebRuntime 的
        // WKUIDelegate 那一段）。这一组或 tab 已经释放：当作不是选中的（排着，关闭时按取消处理）。
        tab.runtime.isSelectedTab = { [weak self, weak tab] in
            guard let self, let tab else { return false }
            return self.isSelected(tab)
        }
    }

    /// ⌘R 和提示里的“重新加载”（窗口的按钮）：按下这一刻选中的标签页重新加载。提示显示的是窗口显示着的页面的状态，
    /// 那就是选中的标签页。
    func reloadSelectedTab() {
        selected.runtime.reload()
    }

    /// 标签页 tab 的地址变了。路径、适配器、“页面变化”日志和 0.8 秒后的媒体日志都是这个标签页的，不管选没选中
    /// （两行日志都带它的标签）；记下可恢复的对话地址跟着选中的标签页，只有它是选中的才记。
    /// tab 已经不在这组里（关闭或拿掉了）就什么都不做：不改它的路径和适配器代号，不写日志。
    /// 关闭时运行时已经断开这个回调（WebRuntime.close()），这里是这组自己的规则，拿掉而没关闭的（removeForTesting）也一样。
    /// 路径变了：这一页还没放回的阅读位置按连续性规则再看一遍（readingPageChanged(_:)，选没选中都一样）。
    private func urlChanged(_ url: URL?, for tab: ChatTab) {
        guard holds(tab) else { return }
        tab.url = url
        if isSelected(tab), let restorable = NavigationPolicy.restorableConversationURL(url) {
            saveLastConversation(restorable)
        }
        // 仅路径变化视为切换页面（忽略 query 变化）
        let path = url.map { "\($0.host ?? "")\($0.path)" }
        guard path != tab.lastPath else { return }
        let previous = tab.lastPath
        tab.lastPath = path
        tab.adapter.invalidate()
        log(tab, "nav", "页面变化 \(Redactor.describe(url))")
        readingPageChanged(tab)
        // 记录导航时网页媒体状态，用于验证“切换对话后官方朗读是否停止”（不主动干预）。
        // 读的是这个标签页的适配器；到点时它已经释放或不在这组标签页里就不读，读完时它已经不在这组里（读的时候关闭了）就不记。
        if previous != nil {
            Task { [weak self, weak tab] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, let tab, self.holds(tab) else { return }
                let state = await self.mediaState(tab.adapter)
                guard self.holds(tab) else { return }
                self.log(tab, "media", "页面变化后 0.8s WebKit 媒体状态=\(state)")
            }
        }
    }

    /// 聚焦选中的标签页的输入框：窗口级的请求，选中的标签页在调用这一刻读。
    func focusInputSoon() {
        focusInputSoon(for: selected)
    }

    /// 80ms 后聚焦 tab 的输入框。先取消 tab 排着的那次。
    /// 到点时只有 tab 还是选中的、并且这还是最新的一次聚焦请求（代号没变）才聚焦；tab 已经释放也不做。
    /// 请求时 tab 就不是选中的（例如新对话等页面结果时切换了标签页）：不算一次请求，什么都不做——不然它会把代号加一，
    /// 取消切换时给换上来的那一页排下的聚焦，结果哪一页都不聚焦。
    /// 聚焦的结果记进诊断；等页面结果时 tab 关闭了（不在这组里）就不记。
    func focusInputSoon(for tab: ChatTab) {
        guard isSelected(tab) else { return }
        tab.focusTask?.cancel()
        focusGeneration += 1
        let generation = focusGeneration
        tab.focusTask = Task { [weak self, weak tab] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, let tab, !Task.isCancelled, self.isSelected(tab), self.focusGeneration == generation else { return }
            let result = await self.focusInput(tab.adapter)
            guard self.holds(tab) else { return }
            self.diagnostics.recordInputFocus(result)
        }
    }

    // MARK: - 切换标签页

    /// 切换到标签页 tab：它成为选中的、窗口显示它。tab 已经是选中的、不在这组里（没加进来、关闭了、拿掉了）：什么都不做。
    /// 新增标签页（newTab()）经这里换上新的那一页；关闭显示着的标签页（closeTab(_:)）先经这里换上邻居；
    /// 切换的键（⌃Tab ⌃⇧Tab ⇧⌘] ⇧⌘[ ⌘1–⌘4 ⌘9，handleKey(_:_:)）直接经这里换。
    ///
    /// 顺序：
    /// 1. 先改选中项（list）。窗口在下一步结束进行中的切模式时说“排版结束”，那时选中的已经是 tab：
    ///    换下去的那一页排版前记下的阅读位置留在它自己身上（D2），不放回到正要藏起的那一页。
    /// 2. 写一行“选中”（带 tab 的标签，没有地址和标题）：之后窗口不带标签的行就能对上是哪一页。
    /// 3. 窗口显示 tab 的页面和网页视图，并投上它的状态（ChatWindowController.display(_:webView:beforeCatchUp:laidOut:)：
    ///    遮挡、提示、颜色；换下去的网页视图藏起、固定在离开时的大小；淡出层去掉；键盘焦点交给 tab 的网页视图）。
    ///    tab 的网页视图离开时排好版的大小或缩放和现在不同时，窗口先盖住它补排版：在它变大小之前记下它的阅读位置
    ///    （holdBeforeCatchUp(_:)），补排版结束时再告诉这里（laidOut）。
    ///    tab 按现在的窗口大小排好版时（不用补排版就在窗口显示它的最后一步，要补就在补排版结束时；每次显示正好一次）：
    ///    它留着的阅读位置这时放回或丢弃（tabShownAndLaidOut(_:)）。补排版还没结束就又切换走了：这一次不算，留着的继续留着，
    ///    等它下一次显示并排好版。
    /// 4. 聚焦（D5，和唤醒一样）：之前排着的聚焦都作废（代号加一：A → B → A 时 A 换走前排下的那次也不再聚焦）；
    ///    窗口是 key 窗口才给 tab 排一次（focusInputSoon(for:)，80ms 后）。
    /// 5. 可恢复的对话地址跟着选中的：tab 现在的地址是可以恢复的对话就记下；不是就不改（还留着之前记下的）。
    /// 6. tab 不显示时排着的网页对话框（提示框、确认框、文件选择）放出来（WebRuntime.showHeldDialogs()）：
    ///    在这一轮之后（select 和调用它的 closeTab、newTab 先做完）按到达的先后一次显示一个，每一个显示之前再看 tab 还是不是
    ///    选中的、关没关闭（又切换走了就接着排着，等下一次选中）。
    ///    不等补排版（laidOut），也不等第一次加载的遮挡：排着的提示框、确认框让 tab 的网页停着等回答，补排版要在网页里跑的
    ///    排版脚本、第一次加载都要等回答以后才走得动，等它们只会等到时限（补排版 1.5 秒，遮挡 10／30 秒）；
    ///    选中的标签页自己的对话框在遮挡、补排版时也是马上显示的（原来就这样）。
    /// 不改的：tab 和换下去的那一页自己的状态（页面加载状态、路径、媒体状态、排着的任务）；进行中的、开始时绑定了某一页的操作
    /// （新对话、读媒体状态、证据采集、媒体实验）照样只对它们那一页做；换下去的那一页之后的事件只改它自己的状态。
    /// 换下去的那一页正显示着的对话框（文件选择不是模态的，换的时候可能还开着）不收起，回答照样给它；它之后的对话框排着。
    func select(_ tab: ChatTab) {
        guard holds(tab), !isSelected(tab) else { return }
        _ = list.select(tab.id)
        log(tab, "tabs", "选中")
        windowController.display(tab.page, webView: tab.runtime.webView,
                                 beforeCatchUp: { holdBeforeCatchUp(tab) },
                                 laidOut: { [weak self, weak tab] in
                                     guard let self, let tab else { return }
                                     self.tabShownAndLaidOut(tab)
                                 })
        focusGeneration += 1
        if windowIsKey() { focusInputSoon(for: tab) }
        if let restorable = NavigationPolicy.restorableConversationURL(tab.url) { saveLastConversation(restorable) }
        tab.runtime.showHeldDialogs()
    }

    /// 换上来的 tab 要补排版：窗口在它的网页视图还藏着、还是离开时的大小时调用（排版变化之前）。
    /// tab 没有留着的阅读位置：这时记下一次，留在它上面（pendingReadingRestore），补排版结束、它排好版时和别的留着的一样
    /// 放回（tabShownAndLaidOut(_:)，照连续性规则）；补排版没结束就又切换走了，也和别的留着的一样继续留着。
    /// 已经留着一次（离开前切模式记下、离开时还没放回的；或者上一次补排版没结束就切换走了）：不再记——
    /// 留着的那次是它离开后第一次排版变化之前的位置（计划 4.2），后来的那次只会是已经变过的位置。
    /// 不写日志（平常的记下也不写）；放回时写“又显示并排好版”那一行。
    private func holdBeforeCatchUp(_ tab: ChatTab) {
        guard tab.pendingReadingRestore == nil else { return }
        tab.pendingReadingRestore = ReadingHold(tab: tab, token: holdReadingPosition(tab.runtime))
    }

    // MARK: - 新增标签页

    /// 新增标签页：加一个新对话的标签页，放在最右，切换过去。返回加进来的那一个；不新增时返回 nil。
    /// 应用里由 ⌘T 调用（3.10，handleKey(_:_:)）；菜单在 3.11 接上。
    ///
    /// 不新增（列表、选中项、窗口都不变，不找回窗口，不建网页；只写一行“[tabs] 不新增标签页：…”，不带标签）：
    /// - 启动画面还在（isLaunchScreenUp，计划 4.3）：别的什么都不做。新标签页的遮挡不算，还盖着也能再新增。
    /// - 已到上限（list.isFull，上限由 TabList 定）：响一声提示音（beep）。这是阶段 3 的占位（D8），
    ///   以后换成“最多打开 4 个标签页”的提示。
    /// 两样都有时按启动画面算（不响）。
    ///
    /// 顺序：
    /// 1. 窗口没显示（隐藏、最小化，windowIsVisible）：写一行，先找回窗口（revealWindow，D9），窗口照常显示这时选中的那一页
    ///    （窗口显示后的聚焦、提前重试也照常给它），再往下做。窗口显示着就不找回。
    /// 2. 加一个标签页（add(_:)，建法是 makeTab：和启动时的那个一样，建的时候就照现在的设置；接好线、登记到网络状态），
    ///    放在最右，不选中，窗口不变。写一行“新增”（带它的标签，有现在的个数，没有地址）。
    /// 3. 它的页面开始新标签页的遮挡（ChatWindowController.beginNewTabCover(for:)）。这时它不显示：只改它自己的状态
    ///    （盖着、样子、计时、启动保护），窗口一点不变、不写窗口的行。
    /// 4. 它开始加载新对话页（WebRuntime.newChat()，和“新对话”整页加载的是同一个地址）。在遮挡之后：第一次加载从一开始
    ///    就有遮挡盖着，加载的结果（提交、完成、失败）都能结束它，和启动时先盖启动画面、再加载一样。它不选中也照常加载：
    ///    是它自己的页面。
    /// 5. 切换过去（select(_:)）。遮挡这时已经属于它：窗口在换上它的网页视图的同一步里投上它的遮挡（display 里），
    ///    没有它的空白网页显示着、遮挡还没盖上的时候；也不会像给显示着的页面开始遮挡那样动窗口的启动保护、写窗口的
    ///    “启动保护”那一行。它从没在窗口里显示过，不补排版（第一次加载有自己的遮挡）。
    ///    聚焦（窗口是 key 窗口才聚焦它，之前排着的作废）、记下可恢复的对话地址、阅读位置都由 select 照常做，这里不另外做。
    /// 这条路和重新打开（reopenClosedTab()）共用（open(_:place:line:)），只有放在哪、加载什么、日志的说法不同。
    @discardableResult
    func newTab() -> ChatTab? {
        open("新增", place: { make in add(make).map { ($0, nil) } }) { _ in "新增（现在 \(tabs.count) 个）" }
    }

    /// 新增（newTab()）和重新打开（reopenClosedTab()）共用的一条路，规则写在 newTab() 上：
    /// 不打开（启动画面还在 → 写一行；已到上限 → 响一声、写一行）→ 窗口没显示就先找回 → 放进来（place）→ 写一行（line）→
    /// 它的页面开始新标签页的遮挡 → 加载（place 给的地址；nil 是新对话页，WebRuntime.newChat()）→ 切换过去（select(_:)）。
    /// 返回放进来的那一个；不打开时返回 nil。
    /// - verb：日志里怎么说这件事（“新增”“重新打开”），不打开和先找回窗口的那几行用它。
    /// - place：用 makeTab 建一个标签页放进这组（list 和 tabs 一起改、不选中、接好线、登记到网络状态），返回它和要加载的地址。
    ///   前面看过没到上限，所以总能放进来；放不进来是用错了（断言）。
    /// - line：放进来以后写的那一行（带它的标签，没有地址）。
    private func open(_ verb: String, place: ((TabID) -> ChatTab) -> (tab: ChatTab, url: URL?)?,
                      line: (ChatTab) -> String) -> ChatTab? {
        guard let makeTab, let revealWindow else { preconditionFailure("\(verb)标签页要有建法和找回窗口（AppDelegate 交进来）") }
        guard !isLaunchScreenUp else {
            logGroup("tabs", "不\(verb)标签页：启动画面还在")
            return nil
        }
        guard !list.isFull else {
            beep()
            logGroup("tabs", "不\(verb)标签页：已到上限（\(list.capacity) 个）")
            return nil
        }
        if !windowIsVisible() {
            logGroup("tabs", "\(verb)标签页：窗口没有显示，先找回窗口")
            revealWindow()
        }
        guard let (tab, url) = place(makeTab) else { preconditionFailure("上面看过没到上限，找回窗口不加标签页、不动记录") }
        log(tab, "tabs", line(tab))
        windowController.beginNewTabCover(for: tab.page)
        if let url { tab.runtime.load(url) } else { tab.runtime.newChat() }
        select(tab)
        return tab
    }

    // MARK: - 重新打开最近关闭的标签页

    /// 有可以重新打开的记录（最近关闭的普通对话，见 TabList.recentlyClosed）。以后菜单项置灰看它（3.11）；
    /// 到上限、启动画面还在另外看（list.isFull、isLaunchScreenUp），这里不算进去。
    /// ⇧⌘T 不看它：没有记录时也交给 reopenClosedTab()（写一行“没有记录”），按键照样吃掉（D13、D17）。
    var canReopenClosedTab: Bool {
        !list.recentlyClosed.isEmpty
    }

    /// 重新打开最近关闭的标签页（⇧⌘T，handleKey(_:_:)）：取最近关闭的那一条，新建一个标签页加载那个地址，放回它关闭时的位置
    /// （那个位置已经没有了就放最右，规则在 TabList.reopen(select:)），切换过去。连着调用按关闭的倒序逐个打开。
    /// 返回打开的那一个；不打开时返回 nil。应用里由 ⇧⌘T 调用（3.10）；菜单在 3.11 接上。
    /// 是重新加载这个地址，不是原样找回：新的标识、运行时、适配器、页面状态和网页视图，关掉的那个标签页不再用
    /// （它已经关闭、释放）；未发送的草稿和关闭前的页面现场都不在。
    ///
    /// 不打开（列表、记录、选中项、窗口都不变，不找回窗口，不建网页；只写一行“[tabs] 不重新打开标签页：…”，不带标签）：
    /// - 没有记录（canReopenClosedTab 为 false）：别的什么都不做，不响。先看这一条：没有记录时也不说启动画面、上限
    ///   （和 TabList.reopen() 没有记录时不算到上限一样）。以后菜单项置灰、按键不响应；这一行只用来在诊断里看出“按了没反应”的原因。
    /// - 启动画面还在：和 newTab() 一样，别的什么都不做；记录留着。
    /// - 已到上限：和 newTab() 一样响一声（D8 的占位，以后换成上限提示）；不打开，记录留着（不消耗）。
    ///
    /// 打开的顺序和 newTab() 完全相同（同一条路 open(_:place:line:)，同一个建法 makeTab）：
    /// 窗口没显示（隐藏、最小化）就写一行、先找回窗口 → 消耗这条记录，新建的标签页放回原位置，不选中，接好线、登记到网络状态
    /// （reinsertClosedTab(_:)）→ 写一行“重新打开（第 k 个，现在 N 个，还有 M 条记录）”（带它的标签，没有地址）→
    /// 它的页面开始新标签页的遮挡 → 加载记下的地址（WebRuntime.load(_:)，“[nav] 加载”那一行照常经 Redactor，没有对话 id）→
    /// 切换过去（select(_:)）。
    /// 它是新的网页视图，第一次显示：不补排版，没有留着的阅读位置（第一次加载由遮挡盖着）。聚焦（窗口是 key 窗口才聚焦）、
    /// 记下可恢复的对话地址都由 select 照常做：这时它还没有地址（tab.url 是 nil），记下的不改；加载后报出对话地址时
    /// 按平常的规则（urlChanged，它是选中的就记）。
    @discardableResult
    func reopenClosedTab() -> ChatTab? {
        guard canReopenClosedTab else {
            logGroup("tabs", "不重新打开标签页：没有记录")
            return nil
        }
        return open("重新打开", place: reinsertClosedTab) { tab in
            let position = (tabs.firstIndex { $0 === tab } ?? 0) + 1
            return "重新打开（第 \(position) 个，现在 \(tabs.count) 个，还有 \(list.recentlyClosed.entries.count) 条记录）"
        }
    }

    /// 取最近关闭的那条，用 make 建一个新的标签页放回记下的位置（list.reopen(select: false)：消耗这条记录、放回原位置或最右、
    /// 不选中），tabs 放在同一个位置（adopt(_:_:)）。返回它和要加载的地址。没有记录、已到上限时什么都不放，返回 nil（记录留着）。
    private func reinsertClosedTab(_ make: (TabID) -> ChatTab) -> (tab: ChatTab, url: URL?)? {
        guard case .reopened(let id, let url) = list.reopen(select: false) else { return nil }
        return (adopt(id, make), url)
    }

    // MARK: - 按键（3.10）

    /// 标签页的键（窗口的按键监视认出来的 key，和这一刻的情形 context，见 ChatWindowController.handleKeyDown(_:)）。
    /// 返回 true：由这里处理，按键吃掉，不再交给菜单、输入法和网页。做什么由 TabKeys.keyAction(_:_:list:) 按这一刻的 list 定
    /// （规则写在那里：别的窗口、模态框、用户自己的键放过，重复按键吃掉不做），这里只照做：
    /// - pass：返回 false，按键照原来的路走（窗口接着看切换键，再交给菜单和网页）。
    /// - swallow：吃掉，什么都不做；不是重复按键时写一行“[keys] 标签页按键 X：没有可切换到的标签页，按键不交给网页”。
    /// - 别的：先写一行“[keys] 标签页按键 X”（只有键名），再调用入口：⌘T newTab()、⇧⌘T reopenClosedTab()、
    ///   ⌘W closeSelectedTab()、⇧⌘W hideWindow("⇧⌘W")（和左上角的 × 一样隐藏窗口，标签页都留着；原因不同）、
    ///   切换 select(_:)（要切换到的那一个是 keyAction 问 list 得来的）。入口做不了（启动画面还在、到上限、没有记录）时
    ///   由入口自己响一声、写一行，按键照样吃掉。
    ///   只有一个标签页时的 ⌘W 不写这一行：和原来按 ⌘W 一样，只有窗口那一行“[window] 隐藏：⌘W”。
    func handleKey(_ key: TabKeys.Match, _ context: TabKeys.Context) -> Bool {
        let action = TabKeys.keyAction(key.command, context, list: list)
        switch action {
        case .pass:
            return false
        case .swallow:
            if !context.isRepeat { logGroup("keys", "标签页按键 \(key.name)：没有可切换到的标签页，按键不交给网页") }
            return true
        case .closeTab where tabs.count == 1:
            break
        default:
            logGroup("keys", "标签页按键 \(key.name)")
        }
        switch action {
        case .newTab: newTab()
        case .reopenClosedTab: reopenClosedTab()
        case .closeTab: closeSelectedTab()
        case .hideWindow: hideWindow("⇧⌘W")
        case .select(let id):
            guard let tab = tabs.first(where: { $0.id == id }) else { preconditionFailure("TabList 给出的是这组里的标签页") }
            select(tab)
        case .pass, .swallow: break
        }
        return true
    }

    // MARK: - 对选中的标签页做的操作

    /// 窗口显示后（窗口的 onDidShow）：聚焦和提前重试都给这一刻选中的标签页。
    /// 不显示的标签页不提前重试：用户看到的只有选中的那个，后台的页面按自己的退避和网络恢复重试。
    private func windowDidShow(_ kind: Diagnostics.ShowKind) {
        let tab = selected
        focusInputSoon(for: tab)
        tab.runtime.windowShown(kind)
    }

    /// 新对话（菜单、⌘N、顶部的按钮）：对按下这一刻选中的标签页做。先试页面里官方的入口，确定没点到时整页加载新对话页。
    /// 等页面里的结果时选中的可能换了、这个标签页也可能被拿掉：之后只对它做，它已经不在这组里就什么都不做。
    /// 整页加载给它（它不选中也加载：是它自己的页面，不动前台）；聚焦也请求给它，它这时或到点时不是选中的就不聚焦（focusInputSoon(for:)）。
    func newChat() {
        let tab = selected
        Task { [weak self] in
            guard let self else { return }
            let inPage = await self.openNewChat(tab.adapter)
            guard self.holds(tab) else { return }
            guard inPage else { tab.runtime.newChat(); return }
            self.focusInputSoon(for: tab)
        }
    }

    /// 每秒一次（AppDelegate 的定时器）：读选中的标签页的网页媒体状态，只显示、写日志，不控制。
    /// 这一次读哪个标签页在调用这一刻定下，读完显示和写日志的也是它，读的时候换了选中的也不跟着换。
    /// “变了”是和这一页自己上次读到的比（ChatTab.mediaState）：切换标签页后不会写出“换走的那一页的状态 → 这一页的状态”。
    /// 读完时它已经不在这组里就都不做（不显示、不写日志、不改记下的状态）：读到的是一个已经不在的标签页，
    /// 下一秒就读到选中的那个。
    func mediaTick() {
        let tab = selected
        Task { [weak self] in
            guard let self else { return }
            let state = await self.mediaState(tab.adapter)
            guard self.holds(tab) else { return }
            self.diagnostics.webMediaState = state
            if state != tab.mediaState {
                self.log(tab, "media", "WebKit 媒体状态 \(tab.mediaState) → \(state)（窗口可见=\(self.windowController.window?.isVisible ?? false)）")
                tab.mediaState = state
            }
        }
    }

    /// 采集证据（诊断窗口、命令行通知）：对开始这一刻选中的标签页做，每一步都对它做，中途换了选中的也不跟着换；
    /// 它不在这组里了就不再往下做。写报告文件由调用方在这之后做。
    func collectEvidence(measure: Bool) async {
        let tab = selected
        await PageEvidence.collect(from: evidenceTarget(tab), measure: measure, into: diagnostics) { self.holds(tab) }
    }

    /// 媒体实验（诊断窗口）：和采集证据一样，对开始这一刻选中的标签页做；日志里的实验行带它的标签。
    /// 写报告文件由调用方在这之后做。
    func runExperiment(_ kind: ExperimentKind) async {
        let tab = selected
        await PageEvidence.runExperiment(kind, on: evidenceTarget(tab), diagnostics: diagnostics, tab: tab.logTag) {
            self.holds(tab)
        }
    }

    // MARK: - 排版变化前后的阅读位置

    // 窗口大小变（切模式、拖边）之前记下选中的标签页的阅读位置（网页里，带编号），变完之后放回给记下它的那一页。
    // 放不放回看连续性规则（ReadingContinuity，用户 11-20 的 D1）：记下的还属于那一页现在显示的内容才放回，
    // 不属于就丢弃，并让网页丢掉那一次记下的（按编号，不动更新的），选没选中都一样。
    // - 规则在每次放回前看，那一页每换一次页面（urlChanged）、每提交一次（mainFrameCommitted）也看：哪一次说丢弃就当场丢弃，
    //   之后换回原来的对话也不再放回。
    // - 新对话页一步拿到对话地址（/ → /c/<id>）：地址分不清是不是同一个对话，放回时请网页确认，确认不了网页自己丢掉那一次。
    // - 该放回时那一页不是选中的（D2）：不马上放回，也不丢，留在那一页上（ChatTab.pendingReadingRestore），
    //   等它再显示并排好版时由 tabShownAndLaidOut(_:) 放回；留着期间规则说丢弃就丢弃。
    // - 关闭标签页时它记下的都作废（dropReadingPositions(of:)，不碰网页、不写日志）；关的是显示着的那一页时，在切换到下一页之前
    //   作废，切换时结束的切模式不会把它那次留到“再显示”。
    // 平常（没换页面）放回、丢弃都不写日志；丢弃、留着、留着的放回各写一行带标签的日志（只有原因，没有地址和内容）。

    /// 窗口大小要变（切模式、拖边）之前：记下这一刻选中的标签页的阅读位置，并记住是它、是哪一次（编号）、那时的样子。
    /// 记下的按先后排着，放回时取最近的一条（后进先出）：两次排版变化可以套着（拖边途中按切换键：拖边记下、切换记下、
    /// 切换放回、拖边放回）。窗口的三处调用都是先记下再放回、一一成对，所以每次放回都有它的那一条。
    private func holdReadingPositionForLayout() {
        let tab = selected
        let token = holdReadingPosition(tab.runtime)
        readingHolds.append(ReadingHold(tab: tab, token: token))
    }

    /// 变完之后：交给记下它的那一页，不是这时选中的。
    /// - 已经丢弃过（换页面、提交时规则说丢弃）、那一页关闭时作废了：什么都不做。
    /// - 那一页已经不在这组里（关闭、拿掉、释放）：作废，不碰它的网页。
    /// - 规则说丢弃：丢弃，网页里也丢掉这一次。
    /// - 那一页不是选中的：留到它再显示并排好版（keepPending(_:on:)）。
    /// - 是选中的：放回（新对话页拿到对话地址的要网页确认）。只有一个标签页时它总是选中的。
    private func restoreReadingPositionAfterLayout() {
        guard let hold = readingHolds.popLast(), !hold.isSettled, let tab = hold.tab, holds(tab) else { return }
        let verdict = hold.continuity(on: tab)
        if case .discard(let reason) = verdict { return discard(hold, on: tab, Self.text(reason)) }
        guard isSelected(tab) else { return keepPending(hold, on: tab) }
        put(hold, backOn: tab, verdict)
    }

    /// 切换标签页（select(_:)）在 tab 按现在的窗口大小排好版时调用（窗口的 laidOut：不用补排版时在窗口显示它的最后一步，
    /// 要补排版时在补排版结束时）：tab 又显示了（是选中的、窗口显示的是它的网页视图），并且已经按现在的窗口大小排好版
    /// （要补排版的排完了、到时限了、或者被切模式、拖边、隐藏窗口先结束了；或者大小和缩放都没变不用排）。
    /// 它有留着的阅读位置（pendingReadingRestore）就在这时按规则放回或丢弃；没有就什么都不做。
    /// tab 不是选中的（不在这组里的也不会是选中的）：什么都不做，留着的继续留着。
    func tabShownAndLaidOut(_ tab: ChatTab) {
        guard isSelected(tab), let hold = tab.pendingReadingRestore else { return }
        tab.pendingReadingRestore = nil
        let verdict = hold.continuity(on: tab)
        if case .discard(let reason) = verdict { return discard(hold, on: tab, Self.text(reason)) }
        log(tab, "reading", "阅读位置：这一页又显示并排好版，放回留着的位置")
        put(hold, backOn: tab, verdict)
    }

    /// tab 换了页面或提交了：它还没放回的（排版中的和留着的）按规则再看一遍，说丢弃的当场丢弃。
    private func readingPageChanged(_ tab: ChatTab) {
        var live = readingHolds.filter { !$0.isSettled && $0.tab === tab }
        if let pending = tab.pendingReadingRestore { live.append(pending) }
        for hold in live {
            if case .discard(let reason) = hold.continuity(on: tab) { discard(hold, on: tab, Self.text(reason)) }
        }
    }

    /// tab 的主框架提交了（新的一份文档）。不在这组里的不管。
    private func mainFrameCommitted(_ tab: ChatTab) {
        guard holds(tab) else { return }
        tab.mainFrameCommits += 1
        readingPageChanged(tab)
    }

    /// 放回 hold：带编号交给网页，规则要网页确认的带上确认。之后这一次就结束了。
    private func put(_ hold: ReadingHold, backOn tab: ChatTab, _ verdict: ReadingContinuity.Verdict) {
        hold.isSettled = true
        restoreReadingPosition(tab.runtime, hold.token, verdict == .confirmOnPage)
    }

    /// 丢弃 hold：网页里按编号丢掉那一次（不动别的编号），留着的也拿掉。之后这一次就结束了。
    private func discard(_ hold: ReadingHold, on tab: ChatTab, _ why: String) {
        hold.isSettled = true
        if tab.pendingReadingRestore === hold { tab.pendingReadingRestore = nil }
        discardReadingPosition(tab.runtime, hold.token)
        log(tab, "reading", "阅读位置：丢弃排版前记下的位置（\(why)）")
    }

    /// 该放回时 tab 不是选中的：留在它上面，等它再显示并排好版（tabShownAndLaidOut(_:)）。
    /// 一页只留一个：已经留着一个时，留更新的那次（编号大的），旧的丢弃。
    private func keepPending(_ hold: ReadingHold, on tab: ChatTab) {
        if let kept = tab.pendingReadingRestore {
            guard kept.token < hold.token else { return discard(hold, on: tab, "这一页留着更新的一次") }
            discard(kept, on: tab, "这一页有了更新的一次")
        }
        tab.pendingReadingRestore = hold
        log(tab, "reading", "阅读位置：这一页没有显示，记下的位置留到它再显示并排好版时放回")
    }

    /// 丢弃的原因写进日志的样子。
    private static func text(_ reason: ReadingContinuity.Reason) -> String {
        switch reason {
        case .reloaded: "页面重新加载过"
        case .unknownAddress: "不知道记下时或现在的地址"
        case .otherConversation: "换了对话"
        case .leftConversation: "从对话到了新对话页"
        case .otherNewChat: "换了新对话页"
        case .notOneStep: "新对话页之后换了不止一次页面"
        case .otherSpace: "新对话页到了别的空间的对话"
        case .notChatPage: "不是聊天页面"
        }
    }

    // MARK: - 设置：每个标签页都改

    /// 网页增强脚本（设置里的“网页增强”“Esc 隐藏窗口”）：每个标签页都重新装，从左到右。
    func applyEnhancementScripts() {
        tabs.forEach { $0.runtime.applyEnhancementScripts() }
    }

    /// 页面缩放：每个标签页都改（藏着的也改；再显示时缩放和离开时不同，窗口先补排版）。
    /// 阅读位置：一般由运行时自己在改缩放前后记下、马上放回（WebRuntime.setPageZoom(_:keepingReadingPosition:)，原来的做法，
    /// 只有一个标签页时总是这样）。留着阅读位置等再显示并排好版的标签页（不显示的；或显示着、还在补排版的）例外：只改缩放，
    /// 不自己记下、放回——网页里那份记录是它和留着的那次共用的，马上放回会在 1.1 秒后放手，之后放回留着的那次就找不到了
    /// （3.2 记下的问题）。留着的那次在它排好版时照常放回（tabShownAndLaidOut(_:)）。
    func setPageZoom(_ zoom: Double) {
        tabs.forEach { $0.runtime.setPageZoom(zoom, keepingReadingPosition: $0.pendingReadingRestore == nil) }
    }

    /// 允许其他应用读取网页内容：每个标签页都改。
    func setPageAccessibilityAllowed(_ allowed: Bool) {
        tabs.forEach { $0.runtime.setPageAccessibilityAllowed(allowed) }
    }

    /// 切换界面语言后：每个标签页开着的弹窗都换标题。
    func retitlePopups() {
        tabs.forEach { $0.runtime.retitlePopups() }
    }

    #if DEBUG
    /// 只给测试用（调试版才有）：把 tab 记作选中的，并让窗口把 tab 的页面当作显示着的，两边保持一致。
    /// 别的都不做：不换网页视图、不把页面状态投到窗口、不采用颜色、不聚焦、不记地址、不放回阅读位置、不写日志。
    /// 切换标签页的入口是 select(_:)；这个只用来单独验证一处规则（事件和排着的任务按所属页处理），不带切换时的那些事。
    func selectForTesting(_ tab: ChatTab) {
        precondition(holds(tab), "只能选这组里的标签页")
        _ = list.select(tab.id)
        windowController.setDisplayedPageForTesting(tab.page)
    }

    /// 只给测试用：把不选中的 tab 从这组里拿掉（列表里也关掉，不记最近关闭），再从网络状态上去掉（tabLeft(_:)）。
    /// 别的都不做：不停它的加载、不拆它的回调、不取消它排着的任务。用来验证排着的任务到点时只靠 holds 检查就不再对它起作用。
    /// 关闭标签页的收尾是 close(_:)。
    func removeForTesting(_ tab: ChatTab) {
        precondition(holds(tab) && !isSelected(tab), "只拿掉这组里不选中的标签页")
        _ = list.close(tab.id, url: nil)
        tabs.removeAll { $0 === tab }
        tabLeft(tab)
    }
    #endif
}
