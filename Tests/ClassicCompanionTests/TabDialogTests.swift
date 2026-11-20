import AppKit
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 网页的对话框归所属的标签页（3.9）：提示框、确认框、文件选择。
/// - 选中的标签页的：马上显示，和原来一样，不写日志（只有一个标签页时总是这样）；
/// - 不选中的：排在它自己身上，什么都不显示，前台不变，写一行；它被选中、窗口显示它以后，在之后的一轮里按到达的先后
///   一次显示一个（显示前再看它还是不是选中的；不等补排版、第一次加载的遮挡），写一行；
/// - 排着、放出来还没显示、显示着时关闭：按取消回答（提示框结束、确认框 false、文件选择 nil），显示着的叫它收起；
/// - 关闭以后来的：马上按取消回答，不写日志（3.1）；
/// - 不选中的标签页要开弹窗：不开。
/// - 标签页开着的弹窗（窗口在屏幕上）的对话框属于弹窗：马上显示，不跟着标签页排着；关闭标签页时照样取消。
/// - prompt() 不支持：哪里调用都马上得到 null（没有实现那个代理方法）。
/// 每个请求 WebKit 的回调正好调用一次：两种核对——像 WebKit 那样调用带回调的代理方法（经 WKUIDelegate 协议），数回调；
/// 真的网页（本地 html，不联网、不放进窗口）里调用 alert()、confirm()、点文件输入框，看网页拿到的回答、接着往下跑。
/// 真的显示（模态框、文件选择面板）换成记录（DialogDesk），测试不弹模态框、不开面板、不开窗口。
/// 标签页按正式的建法建（TabCloseRig，日志带标签），每个都在发出请求之前换上记录。
@MainActor
final class TabDialogTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!

    private func make() -> TabCloseRig {
        let name = "TabDialogTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabCloseRig(defaults: UserDefaults(suiteName: name)!)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        return rig
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await pause(0.01) }
    }

    /// 和网页的对话框有关的行：[web]（排着、显示、关闭）和不开弹窗的那一行。
    private func dialogLines(_ rig: TabCloseRig, since mark: Int) -> [String] {
        rig.lines(since: mark).filter { $0.hasPrefix("[web]") || $0.contains("弹窗") }
    }

    private func evaluate(_ tab: ChatTab, _ js: String) async throws -> String {
        let value = try await tab.runtime.webView.evaluateJavaScript(js, in: nil, contentWorld: .page)
        return "\(value ?? "nil")"
    }

    /// 网页里 js 的结果。网页停着等对话框的回答时脚本要等回答以后才跑：最多等 seconds 秒，到时还没返回就是 nil，不卡住测试。
    private func pageValue(_ tab: ChatTab, _ js: String, within seconds: Double = 1) async throws -> String? {
        var result: String?
        var done = false
        let web = tab.runtime.webView
        Task {
            result = (try? await web.evaluateJavaScript(js, in: nil, contentWorld: .page)).map { "\($0)" }
            done = true
        }
        try await waitUntil(seconds) { done }
        return result
    }

    /// 等到网页里 js 的结果是 expected，最多 3 秒。
    private func waitForPage(_ tab: ChatTab, _ js: String, _ expected: String) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if try await pageValue(tab, js, within: max(0.05, deadline.timeIntervalSinceNow)) == expected { return }
            try await pause(0.02)
        }
    }

    // MARK: - 像 WebKit 那样调用代理

    /// 一个真的 frame（主机是 chatgpt.com）和一份真的文件选择参数（可以多选），从一个不属于任何标签页的网页视图拿：
    /// 本地 html，点它的文件输入框（网页视图跑的脚本算用户操作），frame 是发出文件选择请求的那个。还有打开它时的导航动作。
    private func capture() async throws -> Captured {
        let catcher = Catcher()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        web.navigationDelegate = catcher
        web.uiDelegate = catcher
        web.loadHTMLString("<html><body><input type=file id=f multiple></body></html>", baseURL: chat)
        try await waitUntil(5) { web.url == chat && !web.isLoading && catcher.action != nil }
        _ = try await web.evaluateJavaScript("document.getElementById('f').click(); 0")
        try await waitUntil(5) { catcher.parameters != nil }
        return Captured(frame: try XCTUnwrap(catcher.frame), parameters: try XCTUnwrap(catcher.parameters),
                        action: try XCTUnwrap(catcher.action), web: web, catcher: catcher)
    }

    /// 像 WebKit 那样调用带回调的那一种代理方法：回调每调用一次，answers 里记一条（“提示框结束”“确认框 true”“文件选择 nil”）。
    /// 带回调的那一种是 Swift 转接到 async 方法上的，连着调几次时到达运行时的先后不一定（实测：连着调的三个有时倒过来），
    /// 所以要核对先后的地方，等上一个到了（排着、显示或回答了）再调下一个。同样，关闭时一起取消的几个，回调的先后也不一定
    /// （实测有时倒过来），只核对各一次；一个接一个显示的，回调在显示完的那一刻调用，先后是定的。回调实测在主线程上调用。
    private func askAlert(_ tab: ChatTab, _ message: String, _ c: Captured, _ answers: Answers) {
        let delegate: any WKUIDelegate = tab.runtime
        delegate.webView?(tab.runtime.webView, runJavaScriptAlertPanelWithMessage: message, initiatedByFrame: c.frame) {
            answers.list.append("提示框结束")
        }
    }

    private func askConfirm(_ tab: ChatTab, _ message: String, _ c: Captured, _ answers: Answers) {
        let delegate: any WKUIDelegate = tab.runtime
        delegate.webView?(tab.runtime.webView, runJavaScriptConfirmPanelWithMessage: message, initiatedByFrame: c.frame) {
            answers.list.append("确认框 \($0)")
        }
    }

    private func askOpenPanel(_ tab: ChatTab, _ c: Captured, _ answers: Answers) {
        let delegate: any WKUIDelegate = tab.runtime
        delegate.webView?(tab.runtime.webView, runOpenPanelWith: c.parameters, initiatedByFrame: c.frame) { urls in
            answers.list.append("文件选择 \(urls.map { $0.map(\.lastPathComponent).joined(separator: ",") } ?? "nil")")
        }
    }

    // MARK: - 选中的标签页：马上显示，和原来一样

    /// 只有一个标签页（它就是选中的）：三种都马上显示（显示时什么都没排着），网页拿到用户的回答，WebKit 的回调各一次；
    /// 不写任何日志。真的网页里的 alert、confirm 也一样：网页接着往下跑，拿到确认框的回答。
    /// 测试里的窗口从不显示：窗口没显示时选中的标签页照样马上显示（规则不看窗口，原来也不看）。
    func testTheSelectedTabShowsItsDialogsAtOnceWithoutALine() async throws {
        let rig = make()
        XCTAssertFalse(rig.controller.window?.isVisible ?? true, "窗口没显示")
        let c = try await capture()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.files = [URL(fileURLWithPath: "/tmp/选的文件.txt")]
        desk.onPresent = { _ in XCTAssertEqual(rig.first.runtime.heldDialogCount, 0, "显示时什么都没排着") }
        let answers = Answers()
        let mark = rig.mark()

        askAlert(rig.first, "提示 A", c, answers)
        try await waitUntil { answers.list.count == 1 }
        askConfirm(rig.first, "确认 B", c, answers)
        try await waitUntil { answers.list.count == 2 }
        askOpenPanel(rig.first, c, answers)
        try await waitUntil { answers.list.count == 3 }
        try await pause(0.2)
        XCTAssertEqual(desk.presented, ["1 提示框 chatgpt.com 提示 A", "1 确认框 chatgpt.com 确认 B",
                                        "1 文件选择 多选=true 文件夹=false"])
        XCTAssertEqual(answers.list, ["提示框结束", "确认框 true", "文件选择 选的文件.txt"])
        XCTAssertEqual(rig.lines(since: mark), [], "马上显示不写日志，和原来一样")

        await rig.loadPage(rig.first, "<html><body>x</body></html>")
        desk.confirmAnswer = false
        let pageMark = rig.mark()
        _ = try await evaluate(rig.first, "setTimeout(() => { alert('页面提示'); window.answer = confirm('页面确认') }, 0); 0")
        try await waitUntil { desk.presented.count == 5 }
        try await waitForPage(rig.first, "String(window.answer)", "false")
        let answer = try await pageValue(rig.first, "String(window.answer)")
        XCTAssertEqual(answer, "false", "网页拿到用户的回答")
        XCTAssertEqual(Array(desk.presented.suffix(2)), ["1 提示框 chatgpt.com 页面提示", "1 确认框 chatgpt.com 页面确认"])
        XCTAssertEqual(rig.lines(since: pageMark), [])
    }

    // MARK: - 不选中的标签页：排着，选中时显示

    /// 1 选中，2 在后台。2 的网页弹提示框：不显示，排在 2 上（一个），写一行带 2 的标签；窗口不变；2 的网页停着等回答。
    /// 这时 1 的对话框照样马上显示。选中 2：select 返回时还没显示（在之后的一轮里），之后显示、写一行；网页接着往下跑。
    func testABackgroundTabHoldsItsDialogUntilItIsSelected() async throws {
        let rig = make()
        let c = try await capture()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.install(on: b, "2")
        await rig.loadPage(b, "<html><body>x</body></html>")
        let window = rig.windowState()
        let mark = rig.mark()

        _ = try await evaluate(b, "setTimeout(() => { alert('后台提示'); window.after = 1 }, 0); 0")
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        try await pause(0.2)
        XCTAssertEqual(b.runtime.heldDialogCount, 1)
        XCTAssertEqual(desk.presented, [], "不显示")
        XCTAssertEqual(rig.lines(since: mark), ["[web] 网页的提示框排着等显示（排着 1 个） 【标签2】"])
        XCTAssertEqual(rig.windowState(), window, "前台不变")
        let blocked = try await pageValue(b, "1", within: 0.3)
        XCTAssertNil(blocked, "2 的网页停着等回答：脚本不返回")
        await rig.loadPage(rig.first, "<html><body>y</body></html>")
        let foreground = try await pageValue(rig.first, "String(1 + 1)")
        XCTAssertEqual(foreground, "2", "2 停着时 1 的网页照样跑")

        let answers = Answers()
        askAlert(rig.first, "前台提示", c, answers)
        try await waitUntil { answers.list.count == 1 }
        XCTAssertEqual(desk.presented, ["1 提示框 chatgpt.com 前台提示"], "选中的标签页照样马上显示")

        var shownOn: [String] = []
        desk.onPresent = { _ in
            shownOn.append("选中=\(rig.tabs.selected === b) 窗口显示它=\(rig.controller.webView === b.runtime.webView)")
        }
        let selectMark = rig.mark()
        rig.tabs.select(b)
        XCTAssertEqual(desk.presented.count, 1, "select 返回时还没显示")
        XCTAssertEqual(b.runtime.heldDialogCount, 0, "已经放出来")
        try await waitUntil { desk.presented.count == 2 }
        XCTAssertEqual(desk.presented.last, "2 提示框 chatgpt.com 后台提示")
        XCTAssertEqual(shownOn, ["选中=true 窗口显示它=true"], "显示的那一刻 2 是选中的、窗口显示着它")
        XCTAssertEqual(rig.lines(since: selectMark).filter { $0.hasPrefix("[tabs]") || $0.hasPrefix("[web]") },
                       ["[tabs] 选中 【标签2】", "[web] 显示排着的提示框（还排着 0 个） 【标签2】"])
        try await waitForPage(b, "String(window.after)", "1")
        let after = try await pageValue(b, "String(window.after)")
        XCTAssertEqual(after, "1", "网页接着往下跑")
    }

    /// 2 在后台排着三个：文件选择、确认框、提示框（按这个先后到达）。选中 2：先只显示文件选择；它还开着时不显示别的，
    /// 这时 2 又来一个提示框，排在最后。回答一个，显示下一个，WebKit 按先后各拿到一次回答。日志：排着 1、2、3 个，
    /// 显示时还排着 2、1；后来的那个排着 3 个；之后还排着 1、0。
    func testHeldDialogsAreShownInArrivalOrderOneAtATime() async throws {
        let rig = make()
        let c = try await capture()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: b, "2")
        desk.answersAtOnce = false
        let answers = Answers()
        let mark = rig.mark()

        askOpenPanel(b, c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        askConfirm(b, "确认一", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 2 }
        askAlert(b, "提示二", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 3 }

        rig.tabs.select(b)
        try await waitUntil { desk.presented.count == 1 }
        try await pause(0.2)
        XCTAssertEqual(desk.presented, ["2 文件选择 多选=true 文件夹=false"], "一次一个")
        askAlert(b, "提示三", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 3 }
        try await pause(0.1)
        XCTAssertEqual(desk.presented.count, 1, "后来的排在后面，不马上显示")

        desk.answer(.files([URL(fileURLWithPath: "/tmp/甲.txt")]))
        try await waitUntil { desk.presented.count == 2 }
        try await pause(0.1)
        XCTAssertEqual(desk.presented.last, "2 确认框 chatgpt.com 确认一")
        desk.answer(.confirmed(false))
        try await waitUntil { desk.presented.count == 3 }
        try await pause(0.1)
        XCTAssertEqual(desk.presented.last, "2 提示框 chatgpt.com 提示二")
        desk.answer(.done)
        try await waitUntil { desk.presented.count == 4 }
        XCTAssertEqual(desk.presented.last, "2 提示框 chatgpt.com 提示三")
        desk.answer(.done)
        try await waitUntil { answers.list.count == 4 }
        try await pause(0.3)
        XCTAssertEqual(answers.list, ["文件选择 甲.txt", "确认框 false", "提示框结束", "提示框结束"], "按先后，各一次")
        XCTAssertEqual(b.runtime.heldDialogCount, 0)
        XCTAssertEqual(dialogLines(rig, since: mark), [
            "[web] 网页的文件选择排着等显示（排着 1 个） 【标签2】",
            "[web] 网页的确认框排着等显示（排着 2 个） 【标签2】",
            "[web] 网页的提示框排着等显示（排着 3 个） 【标签2】",
            "[web] 显示排着的文件选择（还排着 2 个） 【标签2】",
            "[web] 网页的提示框排着等显示（排着 3 个） 【标签2】",
            "[web] 显示排着的确认框（还排着 2 个） 【标签2】",
            "[web] 显示排着的提示框（还排着 1 个） 【标签2】",
            "[web] 显示排着的提示框（还排着 0 个） 【标签2】",
        ])
    }

    /// A → B → A：2 排着两个（确认框、提示框）。同一轮里选中 2 又选中 1：放出来的那个到显示时 2 已经不是选中的，
    /// 放回最前面，什么都不显示、不写“显示”那一行，先后不变。再选中 2：按原来的先后显示。
    /// 同一轮里 2 → 1 → 2：放出来的只显示一次。
    func testSwitchingAwayBeforeAHeldDialogIsShownKeepsItHeldInOrder() async throws {
        let rig = make()
        let c = try await capture()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.install(on: b, "2")
        let answers = Answers()
        askConfirm(b, "先", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        askAlert(b, "后", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 2 }
        let mark = rig.mark()

        rig.tabs.select(b)
        rig.tabs.select(rig.first)
        try await pause(0.3)
        XCTAssertEqual(desk.presented, [])
        XCTAssertEqual(b.runtime.heldDialogCount, 2, "放回去了")
        XCTAssertEqual(answers.list, [])
        XCTAssertEqual(dialogLines(rig, since: mark), [])

        rig.tabs.select(b)
        rig.tabs.select(rig.first)
        rig.tabs.select(b)
        try await waitUntil { answers.list.count == 2 }
        try await pause(0.3)
        XCTAssertEqual(desk.presented, ["2 确认框 chatgpt.com 先", "2 提示框 chatgpt.com 后"], "按原来的先后，各一次")
        XCTAssertEqual(answers.list, ["确认框 true", "提示框结束"])
        XCTAssertEqual(dialogLines(rig, since: mark), ["[web] 显示排着的确认框（还排着 1 个） 【标签2】",
                                                       "[web] 显示排着的提示框（还排着 0 个） 【标签2】"])
    }

    /// 2 放出来的文件选择还开着（不是模态的）时切换到 1：它不收起，回答照样给 2；这时 2 又来一个提示框：排着（2 不是选中的），
    /// 文件选择回答以后也不放出来。再选中 2 才显示。
    func testSwitchingAwayWhileAHeldOpenPanelIsUpLeavesItWithItsTab() async throws {
        let rig = make()
        let c = try await capture()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.install(on: b, "2")
        desk.answersAtOnce = false
        let answers = Answers()
        askOpenPanel(b, c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        rig.tabs.select(b)
        try await waitUntil { desk.presented.count == 1 }

        rig.tabs.select(rig.first)
        askAlert(b, "又来", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        XCTAssertEqual(desk.dismissed, [], "不收起")
        desk.answer(.files([URL(fileURLWithPath: "/tmp/乙.txt")]))
        try await waitUntil { answers.list.count == 1 }
        try await pause(0.3)
        XCTAssertEqual(answers.list, ["文件选择 乙.txt"], "回答给 2")
        XCTAssertEqual(desk.presented.count, 1, "2 不是选中的，不放出来")
        XCTAssertEqual(b.runtime.heldDialogCount, 1)

        rig.tabs.select(b)
        try await waitUntil { desk.presented.count == 2 }
        desk.answer(.done)
        try await waitUntil { answers.list.count == 2 }
        XCTAssertEqual(desk.presented.last, "2 提示框 chatgpt.com 又来")
        XCTAssertEqual(answers.list, ["文件选择 乙.txt", "提示框结束"])
    }

    /// 放出来的不等补排版：2 显示过、藏起以后窗口变大，2 排着一个提示框。选中 2：要补排版（排版脚本的结果不送回，一直在补），
    /// 提示框照样在之后的一轮里显示。
    func testAHeldDialogIsShownWithoutWaitingForTheCatchUpLayout() async throws {
        let rig = make()
        let c = try await capture()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.install(on: b, "2")
        rig.tabs.select(b)
        rig.tabs.select(rig.first)
        rig.grow()
        let answers = Answers()
        askAlert(b, "补排版时", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 1 }

        rig.tabs.select(b)
        XCTAssertTrue(rig.controller.isCatchingUp, "在补排版")
        try await waitUntil { desk.presented.count == 1 }
        XCTAssertTrue(rig.controller.isCatchingUp, "还在补排版时就显示了")
        XCTAssertEqual(desk.presented, ["2 提示框 chatgpt.com 补排版时"])
        try await waitUntil { answers.list.count == 1 }
        XCTAssertEqual(answers.list, ["提示框结束"])
    }

    // MARK: - 新增、重新打开的标签页

    /// 新增的标签页（newTab，还盖着第一次加载的遮挡）和重新打开的标签页（reopenClosedTab）接线一样：
    /// 不选中时排着，选中时显示，不等遮挡。
    func testNewAndReopenedTabsFollowTheSameRule() async throws {
        let rig = make()
        let c = try await capture()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        let answers = Answers()

        let new = try XCTUnwrap(rig.tabs.newTab())
        desk.install(on: new, "2")
        rig.tabs.select(rig.first)
        askConfirm(new, "新的", c, answers)
        try await waitUntil { new.runtime.heldDialogCount == 1 }
        XCTAssertEqual(desk.presented, [])
        rig.tabs.select(new)
        XCTAssertTrue(new.page.isCovered, "第一次加载的遮挡还盖着")
        try await waitUntil { answers.list.count == 1 }
        XCTAssertEqual(desk.presented, ["2 确认框 chatgpt.com 新的"], "不等遮挡")

        new.runtime.onURLChange?(chat)
        rig.tabs.closeTab(new)
        let reopened = try XCTUnwrap(rig.tabs.reopenClosedTab())
        desk.install(on: reopened, "3")
        rig.tabs.select(rig.first)
        askOpenPanel(reopened, c, answers)
        try await waitUntil { reopened.runtime.heldDialogCount == 1 }
        try await pause(0.1)
        XCTAssertEqual(desk.presented.count, 1)
        rig.tabs.select(reopened)
        try await waitUntil { answers.list.count == 2 }
        XCTAssertEqual(desk.presented.last, "3 文件选择 多选=true 文件夹=false")
        XCTAssertEqual(answers.list, ["确认框 true", "文件选择 nil"])
    }

    // MARK: - 关闭

    /// 关不选中的 2，它排着三个（网页里真的 confirm、提示框、文件选择）：都不显示，按取消回答，各一次
    /// （网页的 confirm 拿到 false 并接着往下跑）；关闭那一行写上种类和个数，排着的不再写别的行；之后也不再回答。
    func testClosingABackgroundTabCancelsEachHeldDialogOnce() async throws {
        let rig = make()
        let c = try await capture()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.install(on: b, "2")
        await rig.loadPage(b, "<html><body>x</body></html>")
        let answers = Answers()
        _ = try await evaluate(b, "setTimeout(() => { window.answer = confirm('网页确认') }, 0); 0")
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        askAlert(b, "提示", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 2 }
        askOpenPanel(b, c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 3 }
        let window = rig.windowState()
        let mark = rig.mark()

        rig.tabs.closeTab(b)
        XCTAssertEqual(b.runtime.heldDialogCount, 0)
        XCTAssertEqual(dialogLines(rig, since: mark),
                       ["[web] 关闭网页：停止加载，网页的对话框按取消处理（提示框 1 个、确认框 1 个、文件选择 1 个） 【标签2】"])
        try await waitUntil { answers.list.count == 2 }
        try await waitForPage(b, "String(window.answer)", "false")
        try await pause(0.3)
        XCTAssertEqual(answers.list.sorted(), ["提示框结束", "文件选择 nil"].sorted(), "各一次（一起取消的几个回调的先后不一定）")
        let answer = try await pageValue(b, "String(window.answer)")
        XCTAssertEqual(answer, "false", "网页的 confirm 按取消")
        XCTAssertEqual(desk.presented, [], "都不显示")
        XCTAssertEqual(rig.windowState(), window)
        XCTAssertEqual(dialogLines(rig, since: mark).count, 1, "之后不再写")
    }

    /// 关选中的标签页（先切换到邻居再收尾）：
    /// - 2 刚放出来、还没显示（同一轮里选中 2 又关掉它）：不显示，确认框按取消回答一次；关闭那一行算上它；
    /// - 2 是选中的，它的文件选择正开着（马上显示的）：关掉 2 时叫它收起；之后面板哪怕给了文件，网页拿到的也是 nil。
    /// 邻居（1）的对话框不受影响，照样马上显示。
    func testClosingTheSelectedTabCancelsItsReleasedAndShownDialogs() async throws {
        let rig = make()
        let c = try await capture()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        let answers = Answers()

        let b = rig.add()
        desk.install(on: b, "2")
        askConfirm(b, "放出来的", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        let mark = rig.mark()
        rig.tabs.select(b)
        rig.tabs.closeTab(b)
        XCTAssertEqual(dialogLines(rig, since: mark),
                       ["[web] 关闭网页：停止加载，网页的对话框按取消处理（确认框 1 个） 【标签2】"])
        try await waitUntil { answers.list.count == 1 }
        try await pause(0.3)
        XCTAssertEqual(answers.list, ["确认框 false"])
        XCTAssertEqual(desk.presented, [], "没显示")
        XCTAssertTrue(rig.tabs.selected === rig.first)

        let d = rig.add()
        desk.install(on: d, "3")
        desk.answersAtOnce = false
        rig.tabs.select(d)
        askOpenPanel(d, c, answers)
        try await waitUntil { desk.presented.count == 1 }
        XCTAssertEqual(d.runtime.heldDialogCount, 0, "选中的马上显示")
        let closeMark = rig.mark()
        rig.tabs.closeTab(d)
        XCTAssertEqual(desk.dismissed, ["3 文件选择 多选=true 文件夹=false"], "叫它收起")
        XCTAssertEqual(dialogLines(rig, since: closeMark),
                       ["[web] 关闭网页：停止加载，网页的对话框按取消处理（文件选择 1 个） 【标签3】"])
        desk.answer(.files([URL(fileURLWithPath: "/tmp/丙.txt")]))
        try await waitUntil { answers.list.count == 2 }
        try await pause(0.3)
        XCTAssertEqual(answers.list, ["确认框 false", "文件选择 nil"], "关闭以后给了文件也按取消，各一次")

        desk.answersAtOnce = true
        askAlert(rig.first, "邻居", c, answers)
        try await waitUntil { answers.list.count == 3 }
        XCTAssertEqual(desk.presented.last, "1 提示框 chatgpt.com 邻居")
    }

    /// 显示着的提示框、确认框（模态框，测试里用不回答的记录代替）这时页面关闭了：模态框收不起，等用户点掉；
    /// 点了“好”确认框也按取消（false），提示框结束，各一次。
    func testAModalShownWhenItsPageClosesIsAnsweredAsCancelledOnce() async throws {
        let rig = make()
        let c = try await capture()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.answersAtOnce = false
        let answers = Answers()
        let b = rig.add()
        desk.install(on: b, "2")
        rig.tabs.select(b)
        askConfirm(b, "开着的", c, answers)
        try await waitUntil { desk.presented.count == 1 }
        let mark = rig.mark()

        rig.tabs.closeTab(b)
        XCTAssertEqual(dialogLines(rig, since: mark),
                       ["[web] 关闭网页：停止加载，网页的对话框按取消处理（确认框 1 个） 【标签2】"])
        try await pause(0.2)
        XCTAssertEqual(answers.list, [], "模态框收不起：还等着用户")
        desk.answer(.confirmed(true))
        try await waitUntil { answers.list.count == 1 }
        try await pause(0.3)
        XCTAssertEqual(answers.list, ["确认框 false"])

        let d = rig.add()
        desk.install(on: d, "3")
        rig.tabs.select(d)
        askAlert(d, "开着的提示", c, answers)
        try await waitUntil { desk.presented.count == 2 }
        rig.tabs.closeTab(d)
        desk.answer(.done)
        try await waitUntil { answers.list.count == 2 }
        try await pause(0.3)
        XCTAssertEqual(answers.list, ["确认框 false", "提示框结束"])
    }

    /// 排着、放出来、正显示着（确认框，等用户回答）时关掉 2，2 后面还排着一个提示框：关闭那一行显示着的确认框只算一次，
    /// 排着的提示框也算上；排着的马上按取消，显示着的等用户点掉以后按取消（false），各一次；排着的不再显示。
    func testClosingWhileAReleasedDialogIsShownCountsItOnce() async throws {
        let rig = make()
        let c = try await capture()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.install(on: b, "2")
        desk.answersAtOnce = false
        let answers = Answers()
        askConfirm(b, "放出来显示着", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        askAlert(b, "还排着", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 2 }
        rig.tabs.select(b)
        try await waitUntil { desk.presented.count == 1 }
        XCTAssertEqual(b.runtime.heldDialogCount, 1)
        let mark = rig.mark()

        rig.tabs.closeTab(b)
        XCTAssertEqual(dialogLines(rig, since: mark),
                       ["[web] 关闭网页：停止加载，网页的对话框按取消处理（提示框 1 个、确认框 1 个） 【标签2】"])
        XCTAssertEqual(desk.dismissed, ["2 确认框 chatgpt.com 放出来显示着"])
        try await waitUntil { answers.list.count == 1 }
        XCTAssertEqual(answers.list, ["提示框结束"], "排着的马上按取消")
        desk.answer(.confirmed(true))
        try await waitUntil { answers.list.count == 2 }
        try await pause(0.3)
        XCTAssertEqual(answers.list, ["提示框结束", "确认框 false"], "各一次")
        XCTAssertEqual(desk.presented, ["2 确认框 chatgpt.com 放出来显示着"], "排着的不再显示")
        XCTAssertEqual(dialogLines(rig, since: mark).count, 1)
    }

    // MARK: - 关显示着的标签页：先取消它的对话框，再处理邻居（用户 11-20 的裁定）

    /// 2 选中：它放出来的提示框正显示着（等用户），后面还排着一个确认框；邻居 1 排着一个确认框（1 不选中时来的）。关 2：
    /// - 切换到 1 的途中（记下 1 的对话地址那一刻：select 的这一步在放出 1 排着的对话框之前）：2 的对话框已经按取消处理——
    ///   排着的拿走了、显示着的叫它收起了，这时还一个都没回答；1 的还排着；
    /// - 之后的几轮里：2 排着的确认框先按取消回答（false），1 的确认框才显示；
    /// - 2 显示着的提示框等用户点掉以后按取消回答（结束）。收起只叫一次，每个回调各一次，关闭那一行照样写上种类和个数。
    /// 旧的顺序（先切换、再关闭）在那一刻 2 还没取消，1 的确认框先显示。
    func testClosingTheSelectedTabCancelsItsDialogsBeforeTheNeighboursAreReleased() async throws {
        let rig = make()
        let c = try await capture()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.install(on: b, "2")
        desk.answersAtOnce = false
        let answers = Answers()
        desk.onPresent = { answers.list.append("显示 \($0)") }
        // 切回 1 时记下它的对话地址：select 在放出 1 排着的对话框之前调用这个替身，测试在那一刻看一眼。
        rig.first.runtime.onURLChange?(chat)
        askAlert(b, "放出来显示着", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        rig.tabs.select(b)
        try await waitUntil { desk.presented.count == 1 }
        askConfirm(b, "还排着", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        askConfirm(rig.first, "邻居的", c, answers)
        try await waitUntil { rig.first.runtime.heldDialogCount == 1 }
        XCTAssertEqual(answers.list, ["显示 2 提示框 chatgpt.com 放出来显示着"])
        let mark = rig.mark()
        var atRelease: [String] = []
        rig.onStub = { what in
            guard what == "记下对话地址" else { return }
            atRelease.append("2 已取消=\(b.runtime.dialogsCancelled) 2 排着=\(b.runtime.heldDialogCount) 收起=\(desk.dismissed) "
                             + "1 排着=\(rig.first.runtime.heldDialogCount) 回答=\(answers.list.count)")
        }

        rig.tabs.closeTab(b)
        rig.onStub = nil
        XCTAssertEqual(atRelease, ["2 已取消=true 2 排着=0 收起=[\"2 提示框 chatgpt.com 放出来显示着\"] 1 排着=1 回答=1"])
        try await waitUntil { answers.list.count == 3 }
        try await pause(0.2)
        XCTAssertEqual(answers.list, ["显示 2 提示框 chatgpt.com 放出来显示着", "确认框 false", "显示 1 确认框 chatgpt.com 邻居的"],
                       "2 的回答先于 1 的显示")
        desk.answer(.done)
        try await waitUntil { answers.list.count == 4 }
        desk.answer(.confirmed(true))
        try await waitUntil { answers.list.count == 5 }
        try await pause(0.3)
        XCTAssertEqual(Array(answers.list.suffix(2)), ["提示框结束", "确认框 true"], "2 的提示框按取消结束；1 的拿到用户的回答")
        XCTAssertEqual(answers.list.count, 5, "各一次")
        XCTAssertEqual(desk.dismissed, ["2 提示框 chatgpt.com 放出来显示着"], "收起只叫一次")
        XCTAssertEqual(dialogLines(rig, since: mark), [
            "[web] 关闭网页：停止加载，网页的对话框按取消处理（提示框 1 个、确认框 1 个） 【标签2】",
            "[web] 显示排着的确认框（还排着 0 个） 【标签1】",
        ])
    }

    /// 1、2、3，3 在最右（关掉后选左边的 2）。3 排着一个确认框，邻居 2 排着一个提示框。同一轮里选中 3（放出它的确认框，
    /// 还没显示）又关掉 3：3 的确认框按取消回答一次，不显示，不放回去排着；2 的提示框在它之后才显示。关闭那一行算上放出来的那一个。
    func testAReleasedButNotYetShownDialogOfTheClosingTabIsCancelledBeforeTheNeighboursIsShown() async throws {
        let rig = make()
        let c = try await capture()
        let left = rig.add(), b = rig.add()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.install(on: left, "2")
        desk.install(on: b, "3")
        let answers = Answers()
        desk.onPresent = { answers.list.append("显示 \($0)") }
        askConfirm(b, "放出来的", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        askAlert(left, "邻居的", c, answers)
        try await waitUntil { left.runtime.heldDialogCount == 1 }
        let mark = rig.mark()

        rig.tabs.select(b)
        XCTAssertEqual(b.runtime.heldDialogCount, 0, "放出来了，还没显示")
        rig.tabs.closeTab(b)
        XCTAssertTrue(rig.tabs.selected === left)
        try await waitUntil { answers.list.count == 3 }
        try await pause(0.3)
        XCTAssertEqual(answers.list, ["确认框 false", "显示 2 提示框 chatgpt.com 邻居的", "提示框结束"])
        XCTAssertEqual(b.runtime.heldDialogCount, 0, "没有放回去排着")
        XCTAssertFalse(desk.presented.contains { $0.hasPrefix("3 ") }, "\(desk.presented)")
        XCTAssertEqual(dialogLines(rig, since: mark), ["[web] 关闭网页：停止加载，网页的对话框按取消处理（确认框 1 个） 【标签3】",
                                                       "[web] 显示排着的提示框（还排着 0 个） 【标签2】"])
    }

    /// 取消点之后、关闭之前（WebRuntime.cancelDialogs() 之后还没 close()；closeTab 里这两步之间是切换到邻居）：
    /// - 放出来还没显示的那一个醒来时这一页已经不是选中的、也没有关闭：按取消回答（false），不放回去排着、不显示、不写日志；
    /// - 这一页再来的提示框、确认框、文件选择（再选中它也一样）：马上按取消回答，不排着、不显示、不写日志；
    /// - 之后关闭：不再回答，关闭那一行写的是取消那一刻的种类和个数，只写一次。
    func testAfterTheCancelPointEveryRequestOfThePageIsAnsweredAsCancelledOnce() async throws {
        let rig = make()
        let c = try await capture()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.install(on: b, "2")
        let answers = Answers()
        askConfirm(b, "放出来的", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        let mark = rig.mark()

        rig.tabs.select(b)
        b.runtime.cancelDialogs()
        rig.tabs.select(rig.first)
        XCTAssertTrue(b.runtime.dialogsCancelled)
        XCTAssertFalse(b.runtime.isClosed)
        try await waitUntil { answers.list.count == 1 }
        try await pause(0.3)
        XCTAssertEqual(answers.list, ["确认框 false"])
        XCTAssertEqual(b.runtime.heldDialogCount, 0, "不放回去排着")
        rig.tabs.select(b)
        try await pause(0.2)
        XCTAssertEqual(desk.presented, [], "再选中也不显示")

        askAlert(b, "取消以后", c, answers)
        try await waitUntil { answers.list.count == 2 }
        askConfirm(b, "取消以后", c, answers)
        try await waitUntil { answers.list.count == 3 }
        askOpenPanel(b, c, answers)
        try await waitUntil { answers.list.count == 4 }
        try await pause(0.2)
        XCTAssertEqual(answers.list, ["确认框 false", "提示框结束", "确认框 false", "文件选择 nil"])
        XCTAssertEqual(desk.presented, [])
        XCTAssertEqual(b.runtime.heldDialogCount, 0)
        XCTAssertEqual(dialogLines(rig, since: mark), [], "取消、取消以后来的都不写日志")

        rig.tabs.select(rig.first)
        rig.tabs.closeTab(b)
        try await pause(0.2)
        XCTAssertEqual(answers.list.count, 4, "关闭时不再回答")
        XCTAssertEqual(dialogLines(rig, since: mark), ["[web] 关闭网页：停止加载，网页的对话框按取消处理（确认框 1 个） 【标签2】"])
    }

    /// 取消点那一刻显示着的文件选择（2 选中，马上显示的，开着）：取消时叫它收起；还没关闭时面板给了文件，网页拿到的也是 nil，
    /// 一次。之后关闭不再叫它收起、不再回答。
    func testAPanelShownAtTheCancelPointIsAnsweredAsCancelledBeforeTheClose() async throws {
        let rig = make()
        let c = try await capture()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: b, "2")
        desk.answersAtOnce = false
        let answers = Answers()
        rig.tabs.select(b)
        askOpenPanel(b, c, answers)
        try await waitUntil { desk.presented.count == 1 }

        b.runtime.cancelDialogs()
        XCTAssertEqual(desk.dismissed, ["2 文件选择 多选=true 文件夹=false"])
        XCTAssertFalse(b.runtime.isClosed)
        desk.answer(.files([URL(fileURLWithPath: "/tmp/丁.txt")]))
        try await waitUntil { answers.list.count == 1 }
        XCTAssertEqual(answers.list, ["文件选择 nil"], "还没关闭也按取消")
        rig.tabs.closeTab(b)
        try await pause(0.2)
        XCTAssertEqual(desk.dismissed.count, 1, "关闭时不再收起")
        XCTAssertEqual(answers.list, ["文件选择 nil"], "各一次")
    }

    /// 关闭以后来的（3.1 的规则不变）：三种都马上按取消回答，各一次，不显示、不写日志、不排着。
    func testRequestsAfterCloseAreCancelledAtOnceWithoutALine() async throws {
        let rig = make()
        let c = try await capture()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: b, "2")
        rig.tabs.closeTab(b)
        let mark = rig.mark()
        let answers = Answers()
        askAlert(b, "关闭以后", c, answers)
        try await waitUntil { answers.list.count == 1 }
        askConfirm(b, "关闭以后", c, answers)
        try await waitUntil { answers.list.count == 2 }
        askOpenPanel(b, c, answers)
        try await waitUntil { answers.list.count == 3 }
        try await pause(0.3)
        XCTAssertEqual(answers.list, ["提示框结束", "确认框 false", "文件选择 nil"])
        XCTAssertEqual(desk.presented, [])
        XCTAssertEqual(b.runtime.heldDialogCount, 0)
        XCTAssertEqual(rig.lines(since: mark), [])
    }

    // MARK: - 一直弹提示框的网页、上限

    /// 后台的网页一直弹提示框（一个接一个 50 次）：一次只排着一个（网页的脚本停着等回答），只写一行；文件输入框再点也只排着一个
    /// （WebKit 一个网页一次只发一个）。关掉它：排着的按取消，网页接着跑完（后面的提示框关闭以后来，马上按取消、不写日志），
    /// 之后标签页、运行时、网页视图都释放。
    func testAPageThatKeepsAlertingInTheBackgroundHoldsOneAtATimeAndStillCloses() async throws {
        let rig = make()
        let desk = DialogDesk()
        weak var released: ChatTab?
        weak var runtime: WebRuntime?
        weak var web: WKWebView?
        let mark: Int
        do {
            let b = rig.add()
            desk.install(on: b, "2")
            await rig.loadPage(b, "<html><body><input type=file id=f></body></html>")
            _ = try await evaluate(b, "setTimeout(() => { for (let i = 0; i < 50; i++) { alert('一直弹 ' + i); window.count = i + 1 } }, 0); 0")
            try await waitUntil { b.runtime.heldDialogCount == 1 }
            try await pause(0.5)
            XCTAssertEqual(b.runtime.heldDialogCount, 1, "一次只排着一个")
            mark = rig.mark()
            released = b
            runtime = b.runtime
            web = b.runtime.webView
            rig.tabs.closeTab(b)
        }
        try await waitUntil(5) { released == nil && runtime == nil && web == nil }
        XCTAssertNil(released)
        XCTAssertNil(runtime)
        XCTAssertNil(web)
        XCTAssertEqual(desk.presented, [])
        XCTAssertEqual(dialogLines(rig, since: mark),
                       ["[web] 关闭网页：停止加载，网页的对话框按取消处理（提示框 1 个） 【标签2】"])
    }

    /// 文件输入框，后台的 2：点一次，排着；选中 2 显示、选了文件，网页拿到它（日志里没有文件名和路径）。
    /// 再回到后台点两次（第二次时第一次还排着）：WebKit 只发一次，只排着一个；关掉 2，那一个按取消。
    /// （实测：第一次还排着时网页又点一次，之后给第一次的回答网页不再理会——这是 WebKit 的做法，回调照样只调用一次。）
    func testABackgroundPageAsksForOneFilePanelAtATime() async throws {
        let rig = make()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.install(on: b, "2")
        let file = URL(fileURLWithPath: #filePath)
        desk.files = [file]
        await rig.loadPage(b, "<html><body><input type=file id=f>"
                           + "<script>document.getElementById('f').onchange = e => { window.picked = e.target.files.length }</script></body></html>")
        _ = try await evaluate(b, "document.getElementById('f').click(); 0")
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        try await pause(0.2)
        XCTAssertEqual(desk.presented, [])

        rig.tabs.select(b)
        try await waitForPage(b, "String(window.picked)", "1")
        let picked = try await pageValue(b, "String(window.picked)")
        XCTAssertEqual(picked, "1", "网页拿到选的文件")
        XCTAssertEqual(desk.presented, ["2 文件选择 多选=false 文件夹=false"])
        XCTAssertFalse(rig.allLines(since: 0).contains { $0.contains(file.lastPathComponent) || $0.contains(file.path) },
                       "日志里没有文件名和路径")

        rig.tabs.select(rig.first)
        _ = try await evaluate(b, "document.getElementById('f').click(); 0")
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        _ = try await evaluate(b, "document.getElementById('f').click(); 0")
        try await pause(0.3)
        XCTAssertEqual(b.runtime.heldDialogCount, 1, "只排着一个")
        let mark = rig.mark()
        rig.tabs.closeTab(b)
        XCTAssertEqual(dialogLines(rig, since: mark),
                       ["[web] 关闭网页：停止加载，网页的对话框按取消处理（文件选择 1 个） 【标签2】"])
        XCTAssertEqual(desk.presented.count, 1)
    }

    // MARK: - 日志里没有网页的文字

    /// 排着、显示、关闭时取消的几行里都只有种类和个数：网页给的文字（提示框、确认框的正文）和文件名都不进日志。
    func testNoDialogTextOrFileNameReachesTheLog() async throws {
        let rig = make()
        let c = try await capture()
        let b = rig.add(), d = rig.add()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.install(on: b, "2")
        desk.install(on: d, "3")
        desk.files = [URL(fileURLWithPath: "/tmp/机密文件名-7q.txt")]
        let answers = Answers()
        askAlert(rig.first, "机密正文-1x", c, answers)
        try await waitUntil { answers.list.count == 1 }
        askAlert(b, "机密正文-2y", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        askConfirm(b, "机密正文-3z", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 2 }
        askOpenPanel(b, c, answers)
        askConfirm(d, "机密正文-4w", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 3 && d.runtime.heldDialogCount == 1 }
        rig.tabs.select(b)
        try await waitUntil { answers.list.count == 4 }
        rig.tabs.closeTab(d)
        try await waitUntil { answers.list.count == 5 }
        let all = rig.allLines(since: 0)
        for secret in ["机密正文", "机密文件名", "/tmp/"] {
            XCTAssertFalse(all.contains { $0.contains(secret) }, "\(secret)：\(all)")
        }
        XCTAssertTrue(all.contains("[web] 网页的提示框排着等显示（排着 1 个） 【标签2】"), "\(all)")
    }

    // MARK: - 弹窗

    /// tab 开着的一个弹窗：真的网页视图，代理是 tab 的运行时（和 createWebViewWith 开的一样），放进一个从不显示的窗口，
    /// 记作 tab 的弹窗（adoptPopupForTesting）；打开本地 html（对话地址，不联网），里面有一个文件输入框。
    /// 窗口在不在屏幕上由 screen 定（替身：测试里的窗口从不显示）。
    private func popup(on tab: ChatTab, _ screen: PopupScreen) async throws -> (web: WKWebView, window: NSWindow) {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: tab.runtime.webView.configuration)
        web.navigationDelegate = tab.runtime
        web.uiDelegate = tab.runtime
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = web
        tab.runtime.adoptPopupForTesting(window)
        tab.runtime.popupWindowIsOnScreen = { [weak window] shown in shown === window && screen.on }
        web.loadHTMLString("<html><body><input type=file id=f></body></html>", baseURL: chat)
        try await waitUntil(5) { web.url == chat && !web.isLoading }
        XCTAssertEqual(web.url, chat)
        return (web, window)
    }

    /// 弹窗的网页里 js 的结果（和 pageValue 一样，最多等 seconds 秒，没返回就是 nil）。
    private func popupValue(_ web: WKWebView, _ js: String, within seconds: Double = 1) async throws -> String? {
        var result: String?
        var done = false
        Task {
            result = (try? await web.evaluateJavaScript(js, in: nil, contentWorld: .page)).map { "\($0)" }
            done = true
        }
        try await waitUntil(seconds) { done }
        return result
    }

    /// 不选中的 2 开着的弹窗，窗口在屏幕上：弹窗的网页里的提示框、确认框、文件选择都马上显示（不排着，不等 2 被选中），
    /// 网页拿到回答接着往下跑；每个写一行（只有种类，带 2 的标签）。2 自己的网页的对话框照原来排着，
    /// 弹窗的不排在它后面。弹窗的窗口不在屏幕上（藏起、最小化）：和 2 自己的一样排着，2 被选中时显示。
    func testAPopupOnScreenShowsItsDialogsAtOnceWhileItsTabIsInTheBackground() async throws {
        let rig = make()
        let c = try await capture()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.install(on: b, "2")
        let screen = PopupScreen()
        let (web, _) = try await popup(on: b, screen)
        XCTAssertFalse(b.runtime.isSelectedTab())
        let answers = Answers()
        askAlert(b, "2 自己的", c, answers)
        try await waitUntil { b.runtime.heldDialogCount == 1 }
        let mark = rig.mark()

        _ = try await popupValue(web,
            "setTimeout(() => { alert('弹窗提示'); window.r = String(confirm('弹窗确认')); }, 0); 0")
        try await waitUntil { desk.presented.count == 2 }
        // 网页停着等回答时脚本不返回：不等它（规则坏了时测试不卡住）。
        _ = try await popupValue(web, "document.getElementById('f').click(); 0")
        try await waitUntil { desk.presented.count == 3 }
        let r = try await popupValue(web, "String(window.r)")
        XCTAssertEqual(r, "true", "弹窗的网页拿到确认框的回答")
        XCTAssertEqual(desk.presented, ["2 提示框 chatgpt.com 弹窗提示", "2 确认框 chatgpt.com 弹窗确认",
                                        "2 文件选择 多选=false 文件夹=false"])
        XCTAssertEqual(b.runtime.heldDialogCount, 1, "2 自己的还排着，弹窗的没排在它后面")
        XCTAssertEqual(answers.list, [])
        XCTAssertEqual(dialogLines(rig, since: mark), [
            "[web] 弹窗的提示框：弹窗在屏幕上，马上显示（标签页不显示） 【标签2】",
            "[web] 弹窗的确认框：弹窗在屏幕上，马上显示（标签页不显示） 【标签2】",
            "[web] 弹窗的文件选择：弹窗在屏幕上，马上显示（标签页不显示） 【标签2】",
        ])

        screen.on = false
        let hidden = rig.mark()
        _ = try await popupValue(web, "setTimeout(() => { alert('藏起时'); window.after = 1; }, 0); 0")
        try await waitUntil { b.runtime.heldDialogCount == 2 }
        try await pause(0.2)
        XCTAssertEqual(desk.presented.count, 3, "窗口不在屏幕上：排着")
        XCTAssertEqual(dialogLines(rig, since: hidden), ["[web] 网页的提示框排着等显示（排着 2 个） 【标签2】"])

        rig.tabs.select(b)
        try await waitUntil { desk.presented.count == 5 }
        XCTAssertEqual(Array(desk.presented.suffix(2)), ["2 提示框 chatgpt.com 2 自己的", "2 提示框 chatgpt.com 藏起时"],
                       "2 被选中时按到达的先后显示")
        try await waitUntil { answers.list.count == 1 }
        let after = try await popupValue(web, "String(window.after)")
        XCTAssertEqual(after, "1")
    }

    /// 选中的 1 开着的弹窗、窗口在屏幕上：弹窗的对话框马上显示，不写日志（和原来一样）。
    func testAPopupOnScreenOfTheSelectedTabShowsItsDialogsAtOnceWithoutALine() async throws {
        let rig = make()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        let (web, _) = try await popup(on: rig.first, PopupScreen())
        let mark = rig.mark()
        _ = try await popupValue(web, "setTimeout(() => { alert('弹窗提示') }, 0); 0")
        try await waitUntil { desk.presented.count == 1 }
        XCTAssertEqual(desk.presented, ["1 提示框 chatgpt.com 弹窗提示"])
        XCTAssertEqual(dialogLines(rig, since: mark), [])
    }

    /// 弹窗的对话框显示着（等用户回答）时关闭它的标签页 2：叫它收起，测试之后给的回答不算，网页拿到取消（确认框 false），
    /// 正好一次；关闭那一行写上取消的种类和个数、关掉 1 个弹窗；弹窗的窗口关掉了。关闭以后弹窗再来的马上按取消回答、不显示。
    func testClosingTheTabCancelsItsPopupsShownDialogAndClosesThePopup() async throws {
        let rig = make()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: b, "2")
        desk.answersAtOnce = false
        let (web, window) = try await popup(on: b, PopupScreen())
        var closed = 0
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                              queue: nil) { _ in MainActor.assumeIsolated { closed += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = try await popupValue(web, "setTimeout(() => { window.r = String(confirm('弹窗确认')); }, 0); 0")
        try await waitUntil { desk.presented.count == 1 }
        let mark = rig.mark()

        rig.tabs.closeTab(b)
        XCTAssertEqual(desk.dismissed, ["2 确认框 chatgpt.com 弹窗确认"])
        XCTAssertEqual(closed, 1, "弹窗的窗口关掉了")
        desk.answer(.confirmed(true))
        var r: String?
        let deadline = Date().addingTimeInterval(3)
        while r != "false", Date() < deadline {
            r = try await popupValue(web, "String(window.r)", within: 0.2)
            try await pause(0.02)
        }
        XCTAssertEqual(r, "false", "按取消回答")
        XCTAssertEqual(dialogLines(rig, since: mark),
                       ["[web] 关闭网页：停止加载，关掉 1 个弹窗，网页的对话框按取消处理（确认框 1 个） 【标签2】"])

        desk.answersAtOnce = true
        _ = try await popupValue(web, "setTimeout(() => { window.s = String(confirm('关闭以后')); }, 0); 0")
        var s: String?
        while s != "false", Date() < deadline.addingTimeInterval(2) {
            s = try await popupValue(web, "String(window.s)", within: 0.2)
            try await pause(0.02)
        }
        XCTAssertEqual(s, "false")
        XCTAssertEqual(desk.presented.count, 1, "关闭以后不显示")
    }

    /// 标签页换到后台时，它开着的弹窗照旧开着（不关），对话框跟着弹窗的窗口走（见上面）；换回来也一样。
    /// 只有关闭这个标签页时才关掉。
    func testAPopupStaysOpenWhenItsTabGoesToTheBackground() async throws {
        let rig = make()
        let b = rig.add()
        let (_, window) = try await popup(on: rig.first, PopupScreen())
        var closed = 0
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                              queue: nil) { _ in MainActor.assumeIsolated { closed += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        rig.tabs.select(b)
        rig.tabs.select(rig.first)
        rig.tabs.select(b)
        XCTAssertEqual(closed, 0)
        let mark = rig.mark()
        rig.tabs.closeTab(rig.first)
        XCTAssertEqual(closed, 1)
        XCTAssertTrue(rig.lines(since: mark).contains("[web] 关闭网页：停止加载，关掉 1 个弹窗 【标签1】"), "\(rig.lines(since: mark))")
    }

    // MARK: - prompt（不支持）

    /// 网页要求输入文字（prompt()）不支持：运行时没有实现那个代理方法（WebKit 当作点了“取消”）。真的网页里调用 prompt()：
    /// 选中的 1、不选中的 2、2 开着的弹窗（窗口在屏幕上）、关闭以后的 2，网页都在 1 秒内拿到 null，接着往下跑；
    /// 什么都不显示、不排着、不写日志。
    func testPromptIsAnsweredAsCancelledAtOnceEverywhere() async throws {
        let rig = make()
        let b = rig.add()
        let desk = DialogDesk()
        desk.install(on: rig.first, "1")
        desk.install(on: b, "2")
        let selector = NSSelectorFromString("webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:")
        XCTAssertFalse(rig.first.runtime.responds(to: selector), "没有实现：WebKit 不调用代理")
        await rig.loadPage(rig.first, "<html><body>x</body></html>")
        await rig.loadPage(b, "<html><body>x</body></html>")
        let (popupWeb, _) = try await popup(on: b, PopupScreen())
        let js = "String(prompt('输入', '默认')) + ' 之后'"
        let mark = rig.mark()

        let selected = try await pageValue(rig.first, js)
        let background = try await pageValue(b, js)
        let inPopup = try await popupValue(popupWeb, js)
        XCTAssertEqual(selected, "null 之后", "选中的")
        XCTAssertEqual(background, "null 之后", "不选中的")
        XCTAssertEqual(inPopup, "null 之后", "弹窗")
        XCTAssertEqual(b.runtime.heldDialogCount, 0)

        rig.tabs.closeTab(b)
        let closed = try await pageValue(b, js)
        XCTAssertEqual(closed, "null 之后", "关闭以后")
        let closedPopup = try await popupValue(popupWeb, js)
        XCTAssertEqual(closedPopup, "null 之后", "关闭以后的弹窗")
        XCTAssertEqual(desk.presented, [])
        XCTAssertEqual(dialogLines(rig, since: mark), ["[web] 关闭网页：停止加载，关掉 1 个弹窗 【标签2】"])
    }

    /// 不选中的标签页要开弹窗（聊天地址，原来会开一个登录弹窗那样的窗口）：不开，返回 nil，应用的窗口数不变，
    /// 写一行（带它的标签，没有地址）。选中的那条路会真的开窗口，这里不走。
    func testABackgroundTabsPopupIsNotOpened() async throws {
        let rig = make()
        let c = try await capture()
        let b = rig.add()
        XCTAssertEqual(NavigationPolicy.classify(c.action.request.url), .chat)
        // 接线坏了（2 被当成选中的）时下面会走真的开窗口那条路：先停下，测试不开窗口。
        guard !b.runtime.isSelectedTab() else { return XCTFail("2 不是选中的，运行时却认为是") }
        let windows = NSApplication.shared.windows.count
        let mark = rig.mark()
        let popup = b.runtime.webView(b.runtime.webView, createWebViewWith: WKWebViewConfiguration(), for: c.action,
                                      windowFeatures: WKWindowFeatures())
        XCTAssertNil(popup)
        XCTAssertEqual(NSApplication.shared.windows.count, windows)
        XCTAssertEqual(rig.lines(since: mark), ["[nav] 不显示的标签页要开弹窗：不开 【标签2】"])
    }
}

// MARK: - 替身

/// 测试里弹窗的窗口在不在屏幕上（替身）。
@MainActor
private final class PopupScreen {
    var on = true
}

/// 回调被调用的记录。
@MainActor
private final class Answers {
    var list: [String] = []
}

/// 真的 frame、文件选择参数和导航动作，连同拿它们的网页视图（拿着到测试结束）。
@MainActor
private struct Captured {
    let frame: WKFrameInfo
    let parameters: WKOpenPanelParameters
    let action: WKNavigationAction
    let web: WKWebView
    let catcher: Catcher
}

/// 记下导航动作（放行）和文件选择参数、发出它的 frame（马上按取消回答）。
@MainActor
private final class Catcher: NSObject, WKNavigationDelegate, WKUIDelegate {
    var action: WKNavigationAction?
    var parameters: WKOpenPanelParameters?
    var frame: WKFrameInfo?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        action = navigationAction
        return .allow
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        self.parameters = parameters
        self.frame = frame
        return nil
    }
}

/// 代替真的显示（模态框、文件选择面板）：记下显示了什么（“2 提示框 主机 正文”），按设定马上回答，或等测试回答（answer(_:)）。
/// 页面关闭时叫它收起（dismiss）：只记下来（dismissed），回答仍由测试给——这样核对关闭以后不管给了什么都按取消。
@MainActor
private final class DialogDesk {
    enum Answer: Sendable {
        case done, confirmed(Bool), files([URL]?)
    }

    private(set) var presented: [String] = []
    private(set) var dismissed: [String] = []
    /// 显示着、等测试回答的，按显示的先后。
    private var open: [CheckedContinuation<Answer, Never>] = []
    var answersAtOnce = true
    var confirmAnswer = true
    var files: [URL]?
    /// 显示的那一刻调用（测试看那一刻的样子）。
    var onPresent: ((String) -> Void)?

    func install(on tab: ChatTab, _ name: String) {
        tab.runtime.presentAlert = { [weak self] host, message, shown in
            _ = await self?.show("\(name) 提示框 \(host) \(message)", shown, .done)
        }
        tab.runtime.presentConfirm = { [weak self] host, message, shown in
            guard let self else { return false }
            guard case .confirmed(let value) = await self.show("\(name) 确认框 \(host) \(message)", shown,
                                                               .confirmed(self.confirmAnswer)) else { return false }
            return value
        }
        tab.runtime.presentOpenPanel = { [weak self] multiple, directories, shown in
            guard let self else { return nil }
            guard case .files(let urls) = await self.show("\(name) 文件选择 多选=\(multiple) 文件夹=\(directories)", shown,
                                                          .files(self.files)) else { return nil }
            return urls
        }
    }

    private func show(_ line: String, _ shown: ShownDialog, _ now: Answer) async -> Answer {
        presented.append(line)
        onPresent?(line)
        shown.dismiss = { [weak self] in self?.dismissed.append(line) }
        if answersAtOnce { return now }
        return await withCheckedContinuation { open.append($0) }
    }

    /// 回答最早显示、还开着的那一个。
    func answer(_ answer: Answer) {
        guard !open.isEmpty else { return XCTFail("没有开着的") }
        open.removeFirst().resume(returning: answer)
    }
}
