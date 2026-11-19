import Foundation
import CompanionCore

/// 标签页和窗口之间的接线：把每个标签页的网页运行时的回调接到窗口上（wire(_:)），加上换页面（urlChanged）和聚焦输入框
/// （focusInputSoon）。原来都写在 AppDelegate 里，搬过来是为了能在不建 AppDelegate、不开应用的测试里核对这些顺序
/// （LaunchWiringTests、TabEventOwnershipTests）：冷启动看起来对不对就靠它们。
/// 对选中的标签页做的操作（新对话、⌘R、窗口显示后、排版变化前后的阅读位置、每秒的媒体状态、证据采集和媒体实验）
/// 和改设置时每个标签页都要跟着改的几样也在这里，AppDelegate 只调用。
///
/// 这里有一组标签页（tabs，按从左到右）和选中的那个（selected）。顺序、选中项和标识都由 list（TabList）决定。
/// 应用里现在仍只有启动时的那一个，它就是选中的、窗口显示着的。还没有标签栏，也没有切换的入口
/// （换网页视图、把页面状态投到窗口、采用颜色都留到下一阶段）。
///
/// 规则：事件属于发出它的标签页，接线时就绑定那个标签页，处理时明确传着它，不在中途拿“现在选中的”来代替。
/// - 标签页自己的状态（页面加载状态、lastPath、适配器的代号、它自己的日志）不管选没选中都照常改。
/// - 窗口和全应用的事（隐藏窗口、聚焦输入框、记下可恢复的对话地址）只在它是选中的标签页时做。
///   页面加载状态的窗口部分由 ChatWindowController 判断（只有显示着的页面动窗口），这里不重复判断。
/// - 排着的任务（80ms 后聚焦、0.8 秒后记媒体状态）带着排下它的标签页（weak），到点时它不再是对的对象就不做。
/// 操作也一样：对选中的标签页做的操作在开始这一刻取选中的那个，之后一直明确传着它，等过之后（await、定时、窗口的下一个回调）
/// 不再回来读“现在选中的”。等完先看它还在不在这组里，不在就不做；会被更新的请求取代的（聚焦）还看代号。
/// 后台的事从不改前台。设置（网页增强、页面缩放、网页无障碍、弹窗标题）每个标签页都改。
/// 每个标签页的运行时在这组里时都登记在共用的网络状态上（NetworkStatus 只通知，重试与否由各页自己的恢复规则决定），
/// 离开这组时去掉（tabLeft(_:)）。关闭标签页的收尾见 close(_:)：先让它的运行时和页面状态进入关闭态，再拿掉。
/// 这里写的某个标签页的日志（页面变化、媒体状态、实验）带那个标签页的标签（TabLog，见 log(_:_:_:)）；窗口的日志不带。
/// 选中的标签页和窗口显示着的页面要一致：应用里只有一个标签页，建窗口时传的就是它的 page；测试用 selectForTesting 两边一起设。
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
    /// 窗口是不是 key 窗口（加载完成时据此决定要不要聚焦）。就是 windowController.isKey；
    /// 只有测试换它：测试不显示窗口，窗口不会成为 key 窗口。
    var windowIsKey: @MainActor () -> Bool
    /// 记下、放回阅读位置：就是运行时的 holdReadingPosition()、restoreReadingPosition()。
    /// 只有测试换它们：网页里没有页面，看不到效果，换成记录才看得出给了哪个标签页。
    var holdReadingPosition: @MainActor (WebRuntime) -> Void = { $0.holdReadingPosition() }
    var restoreReadingPosition: @MainActor (WebRuntime) -> Void = { $0.restoreReadingPosition() }
    /// 证据采集和媒体实验对一个标签页做的事交给谁。就是 TabEvidenceTarget(tab:)（它的适配器和网页视图）；
    /// 只有测试换它：真的步骤要真实页面，换成记录才能在步骤之间换选中的标签页、看每一步对哪个标签页做。
    var evidenceTarget: @MainActor (ChatTab) -> any EvidenceTarget = { TabEvidenceTarget(tab: $0) }
    /// 聚焦请求的代号，每次 focusInputSoon(for:) 加一（不管是哪个标签页的）。窗口里只有一个键盘焦点，
    /// 最新的请求说了算：排着的聚焦到点时代号变了就不做，哪怕它的标签页又被选中了（选中 A → B → A）。
    private var focusGeneration = 0
    /// 上一次读到的网页媒体状态（每秒读一次，只用来写“变了”的日志）。原来在 AppDelegate 上。
    private let media = WebMediaMonitor()
    /// 排版变化前记下阅读位置、还没放回的，按记下的先后。见 holdReadingPositionForLayout()。
    private var readingHolds: [ReadingHold] = []

    /// list：启动时的列表，只有 tab 一个、并且选中它（tab 的标识就是从它来的）。
    /// 窗口在这之前已经用 tab 的网页视图和 page 建好：所以选中的标签页和窗口显示着的页面一开始就一致。
    /// 提示里的“重新加载”、窗口显示后、排版变化前后、切模式时的快照和排版是窗口的，在这里接一次（各自对选中的标签页做，
    /// 见 reloadSelectedTab()、windowDidShow(_:)、holdReadingPositionForLayout()、restoreReadingPositionAfterLayout()），
    /// wire(_:) 不再改它们。
    /// tab 的运行时在这里登记到 network。原来 AppDelegate 在建好运行时之后马上登记；那时和这里之间都在同一轮里同步执行，
    /// 网络状态的第一次报告要等回到主队列才到，登记时还不知道状态，什么都不补发，所以挪到这里看不出差别。
    init(list: TabList, tab: ChatTab, windowController: ChatWindowController, diagnostics: Diagnostics,
         network: NetworkStatus,
         hideWindow: @escaping @MainActor (String) -> Void,
         focusInput: @escaping @MainActor (ChatGPTAdapter) async -> String,
         saveLastConversation: @escaping @MainActor (URL) -> Void,
         mediaState: @escaping @MainActor (ChatGPTAdapter) async -> String,
         openNewChat: @escaping @MainActor (ChatGPTAdapter) async -> Bool) {
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
        windowIsKey = { windowController.isKey }
        windowController.onReloadRequest = { [weak self] in self?.reloadSelectedTab() }
        windowController.onDidShow = { [weak self] kind in self?.windowDidShow(kind) }
        windowController.onWillChangeLayout = { [weak self] in self?.holdReadingPositionForLayout() }
        windowController.onDidChangeLayout = { [weak self] in self?.restoreReadingPositionAfterLayout() }
        // 切模式时的快照和按目标大小排版：窗口这一刻显示着的页面，也就是这一刻选中的标签页。
        windowController.onSnapshotPage = { [weak self] done in
            guard let self else { return done(nil) }
            self.selected.runtime.snapshotPage(done)
        }
        windowController.onPrepareLayout = { [weak self] size, done in
            guard let self else { return done() }
            self.selected.runtime.prepareLayout(size: size, done: done)
        }
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

    /// 加一个标签页：放在最右，不选中，接好线，登记到网络状态。标识从 list 来，先发标识再由 make 用它建标签页
    /// （正式运行是 ChatTab.make：运行时和适配器建的时候就知道自己的标识，日志从第一行起带标签）。
    /// 已到上限时返回 nil，什么都不加，也不调用 make。应用里现在没有地方调用（还没有新增标签页的入口），
    /// 测试用它加一个从不显示的标签页。
    func add(_ make: (TabID) -> ChatTab) -> ChatTab? {
        guard case .added(let id) = list.append(select: false) else { return nil }
        let tab = make(id)
        precondition(tab.id == id, "新标签页要用这次发的标识")
        tabs.append(tab)
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

    /// 标签页离开这组时：从共用的网络状态上去掉，之后的网络变化不再送给它。close(_:) 和测试的 removeForTesting(_:) 调用。
    private func tabLeft(_ tab: ChatTab) {
        network.remove(tab.runtime)
    }

    // MARK: - 关闭标签页的收尾

    /// 关闭标签页 tab 的收尾：之后它的任何事件、通知和计时都不再起作用，这组不再持有它（别处也不持有时，它连同运行时、
    /// 页面状态和网页视图一起释放）。应用里现在还没有关闭标签页的入口（没有按键、菜单、标签栏），只有测试调用。
    ///
    /// 前提：tab 不是选中的（窗口显示的不是它）。关选中的标签页要先把选中项和窗口换到别的标签页，那是切换标签页的入口（以后做），
    /// 这里不选下一个、不换网页视图、不投别的页面的状态。只有一个标签页时它就是选中的，所以也不能关（⌘W 隐藏窗口，不释放）。
    /// tab 已经不在这组里（关过了，或者不是这组的）：什么都不做，所以关两遍是安全的。
    ///
    /// 顺序：先进入关闭态，再收尾。
    /// 1. 运行时关闭（WebRuntime.close()）：不再自己发起加载、不再排重试，排着的重试取消，停止加载，回调断开，弹窗关掉。
    /// 2. 页面状态关闭（ChatWindowController.pageClosed(_:)）：带这个页面的入口和它排着的兜底、颜色回调都不再起作用。
    /// 3. 排着的聚焦任务取消（到点本来也因为它不是选中的而不做，这里让它马上结束、不再等）。
    /// 4. 从列表（list）和 tabs 里一起拿掉，两者始终一一对应。不记入最近关闭（⇧⌘T 记哪个地址是重新打开的任务）。
    /// 5. 从共用的网络状态上去掉（tabLeft）。
    ///
    /// 不取消的：进行中的新对话、证据采集和媒体实验、每秒的媒体状态和页面变化后的媒体日志。它们在下一次 holds 检查处停下
    /// （不加载、不聚焦、不写诊断；运行时已关闭，加载也发不出去）；在这之前还拿着这个标签页，所以释放要等它们正在等的那一步
    /// 网页脚本返回或超时。排版前记下的阅读位置留在 readingHolds 里（记下和放回按先后一一配对，不能拿掉一条），
    /// 放回时因为它不在这组里而作废。
    func close(_ tab: ChatTab) {
        guard holds(tab) else { return }
        precondition(!isSelected(tab), "关选中的标签页要先切换到别的标签页（切换入口以后做）")
        tab.runtime.close()
        windowController.pageClosed(tab.page)
        tab.focusTask?.cancel()
        tab.focusTask = nil
        let result = list.close(tab.id, url: nil)
        precondition(result == .closed(selectionChanged: false), "不选中的标签页从列表里拿掉，选中项不变")
        tabs.removeAll { $0 === tab }
        tabLeft(tab)
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
        // 结束启动画面和加载完成都带着这个标签页的页面交给窗口：窗口只在它显示着时动（规则在 ChatWindowController 里）。
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
        tab.runtime.onMainFrameCommitted = { [weak self] in self?.windowController.pageDidCommit(page) }
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
    private func urlChanged(_ url: URL?, for tab: ChatTab) {
        guard holds(tab) else { return }
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
        // 记录导航时网页媒体状态，用于验证“切换对话后官方朗读是否停止”（不主动干预）。
        // 读的是这个标签页的适配器；到点时它已经释放或不在这组标签页里就不记。
        if previous != nil {
            Task { [weak self, weak tab] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, let tab, self.holds(tab) else { return }
                self.log(tab, "media", "页面变化后 0.8s WebKit 媒体状态=\(await self.mediaState(tab.adapter))")
            }
        }
    }

    /// 聚焦选中的标签页的输入框：窗口级的请求，选中的标签页在调用这一刻读。
    func focusInputSoon() {
        focusInputSoon(for: selected)
    }

    /// 80ms 后聚焦 tab 的输入框。先取消 tab 排着的那次。
    /// 到点时只有 tab 还是选中的、并且这还是最新的一次聚焦请求（代号没变）才聚焦；tab 已经释放也不做。
    func focusInputSoon(for tab: ChatTab) {
        tab.focusTask?.cancel()
        focusGeneration += 1
        let generation = focusGeneration
        tab.focusTask = Task { [weak self, weak tab] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, let tab, !Task.isCancelled, self.isSelected(tab), self.focusGeneration == generation else { return }
            let result = await self.focusInput(tab.adapter)
            self.diagnostics.recordInputFocus(result)
        }
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
    /// 整页加载给它（它不选中也加载：是它自己的页面，不动前台）；聚焦也请求给它，到点时它不是选中的就不聚焦（focusInputSoon(for:)）。
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
    /// 读完时它已经不在这组里就都不做（不显示、不写日志、不改记下的状态）：读到的是一个已经不在的标签页，
    /// 下一秒就读到选中的那个。
    func mediaTick() {
        let tab = selected
        Task { [weak self] in
            guard let self else { return }
            let state = await self.mediaState(tab.adapter)
            guard self.holds(tab) else { return }
            self.diagnostics.webMediaState = state
            if state != self.media.state {
                self.log(tab, "media", "WebKit 媒体状态 \(self.media.state) → \(state)（窗口可见=\(self.windowController.window?.isVisible ?? false)）")
                self.media.state = state
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

    /// 一次排版变化前记下阅读位置的标签页，和它那时的导航代号。代号用适配器的 generation：路径每变一次加一（urlChanged），
    /// 换走又换回同一个地址也看得出来，lastPath 看不出。不持有标签页。
    private struct ReadingHold {
        weak var tab: ChatTab?
        let navigation: Int
    }

    /// 窗口大小要变（切模式、拖边）之前：记下这一刻选中的标签页的阅读位置，并记住是它。
    /// 记下的按先后排着，放回时取最近的一条（后进先出）：两次排版变化可以套着（拖边途中按切换键：拖边记下、切换记下、
    /// 切换放回、拖边放回）。窗口的三处调用都是先记下再放回、一一成对，所以每次放回都有它的那一条。
    private func holdReadingPositionForLayout() {
        let tab = selected
        readingHolds.append(ReadingHold(tab: tab, navigation: tab.adapter.generation))
        holdReadingPosition(tab.runtime)
    }

    /// 变完之后：放回给记下它的那个标签页，不是这时选中的。
    /// - 那个标签页已经不在这组里（拿掉、释放）：这次放回作废。
    /// - 它这时不是选中的、并且这期间换过页面：作废，不把旧对话的位置放到别的对话上。
    /// - 它还是选中的：照原来放回，换过页面也放回（一个标签页时就是原来的行为）。网页里的脚本自己不放回已经不在页面上的内容；
    ///   新对话拿到对话地址（/ → /c/…）时还是同一个对话，作废反而丢掉这次放回，网页里记下的位置也一直不放手。
    private func restoreReadingPositionAfterLayout() {
        guard let hold = readingHolds.popLast(), let tab = hold.tab, holds(tab) else { return }
        guard isSelected(tab) || tab.adapter.generation == hold.navigation else { return }
        restoreReadingPosition(tab.runtime)
    }

    // MARK: - 设置：每个标签页都改

    /// 网页增强脚本（设置里的“网页增强”“Esc 隐藏窗口”）：每个标签页都重新装，从左到右。
    func applyEnhancementScripts() {
        tabs.forEach { $0.runtime.applyEnhancementScripts() }
    }

    /// 页面缩放：每个标签页都改。
    func setPageZoom(_ zoom: Double) {
        tabs.forEach { $0.runtime.setPageZoom(zoom) }
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
    /// 别的都不做：不换网页视图（不调用 replaceWebView）、不把页面状态投到窗口、不采用颜色、不聚焦、不写日志。
    /// 真正切换标签页的入口留到下一阶段。
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
