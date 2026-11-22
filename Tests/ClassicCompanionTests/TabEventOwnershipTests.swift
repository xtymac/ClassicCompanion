import AppKit
import Combine
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 事件属于发出它的标签页（ChatTabs.wire(_:)、urlChanged、focusInputSoon）。两个标签页：
/// B 是启动时的那个，选中、窗口显示着（窗口用它的网页视图和 page 建）；A 由 ChatTabs.add 加进来、接好线，从不显示。
/// 核对：
/// - A 的提交、加载完成、加载失败、提示变化只改 A 自己的页面状态，和它显示着时一样；B 和窗口一点不变。
/// - A 的地址变化改 A 自己的路径、适配器代号和日志，不记对话地址；0.8 秒后的媒体日志读 A 的适配器。
/// - 隐藏窗口、聚焦只给选中的标签页；提示里的“重新加载”给按下时选中的标签页。
/// - 排着的聚焦到点时还要是选中的、还要是最新的请求；标签页拿掉或释放后，排着的任务什么都不做。
/// - 对选中的标签页做的操作（10–16）在开始时绑定那个标签页：新对话、窗口显示后提前重试、排版变化前后的阅读位置、
///   每秒的媒体状态、证据采集和媒体实验，中途换了选中的也不跟着换，那个标签页拿掉了就不做；
///   网络变化送到这组里的每个标签页，拿掉的不再收到；设置每个标签页都改。
///   新对话的页面入口、阅读位置、证据采集的步骤要真实页面，交进来的替身记下对哪个标签页做。
///
/// 真的 ChatWindowController（不显示窗口）和两个真的 WebRuntime（不看网络，加载请求各自记下来），
/// 加载、失败、提交、加载完成像 LoadRecoveryWebTests 一样直接调运行时的导航代理。AppDelegate 交进来的几样换成记录。
/// A 的运行时和适配器自己写的日志（加载、失败、重试）记在 A 自己的 Diagnostics 里：共用的 diagnostics 里只有窗口、
/// ChatTabs 和 B 的运行时写的，所以“窗口的日志不变”可以整条比。
/// 选中的标签页和窗口显示着的页面要一致：1–16 换选中的只用 selectForTesting（两边一起设，不换网页视图，切换时的那些事都不做），
/// 单独看每一条按所属页处理的规则；17 经真正的切换入口 select(_:)，看同样的规则在切换以后照样成立。
@MainActor
final class TabEventOwnershipTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!
    private let other = URL(string: "https://chatgpt.com/c/def")!

    /// capacity：新对话的几条用 2（B、A 就到上限），新对话才在选中的标签页里新建（有空位时它开在新标签页，见 NewChatTabTests）。
    private func makeRig(backoffA: [TimeInterval] = [60], capacity: Int = TabList.defaultCapacity) -> TwoTabs {
        let name = "TabEventOwnershipTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TwoTabs(defaults: UserDefaults(suiteName: name)!, backoffA: backoffA, capacity: capacity)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        return rig
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await pause(0.02) }
    }

    /// 窗口、显示着的 B、共用的日志和替身的记录都和 before 一样。
    private func assertUntouched(_ rig: TwoTabs, _ before: TwoTabs.Snapshot, _ step: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let now = rig.snapshot()
        XCTAssertEqual(now.window, before.window, "\(step)：窗口", file: file, line: line)
        XCTAssertEqual(now.displayed, before.displayed, "\(step)：显示着的 B", file: file, line: line)
        XCTAssertEqual(now.lines, before.lines, "\(step)：窗口的日志", file: file, line: line)
        XCTAssertEqual(now.calls, before.calls, "\(step)：隐藏、聚焦、记下地址、读媒体状态", file: file, line: line)
    }

    // MARK: - 两个标签页

    func testTheSelectedTabIsTheDisplayedOneAndTheAddedTabIsNot() {
        let rig = makeRig()
        XCTAssertEqual(rig.tabs.list.tabs, [rig.b.id, rig.a.id])
        XCTAssertEqual(rig.tabs.tabs.map(\.id), rig.tabs.list.tabs)
        XCTAssertTrue(rig.tabs.selected === rig.b)
        XCTAssertTrue(rig.controller.page === rig.tabs.selected.page, "选中的就是显示着的")
        XCTAssertTrue(rig.controller.webView === rig.b.runtime.webView)
        XCTAssertFalse(rig.a.page === rig.b.page)
        XCTAssertFalse(rig.controller.webView === rig.a.runtime.webView, "A 的网页视图不在窗口里")
        XCTAssertTrue(rig.tabs.isSelected(rig.b))
        XCTAssertFalse(rig.tabs.isSelected(rig.a))
    }

    // MARK: 1. A 的加载事件只改 A 的页面

    /// B 的启动画面还在（启动保护中，下面盖着“正在连接”提示），窗口是 key 窗口。A 加载、失败、重新加载、提交、加载完成：
    /// 每一步 A 的页面状态都和另一个窗口里显示着的标签页（ref.b）收到同样事件时一样；B、窗口、窗口的日志、替身都不变。
    /// 最后 B 自己加载完成：启动画面照常结束，照常聚焦 B。
    func testABackgroundTabsLoadEventsChangeOnlyItsOwnPage() async throws {
        let rig = makeRig()
        let ref = makeRig()
        ref.b.runtime.webView.underPageBackgroundColor = TwoTabs.white
        rig.tabs.windowIsKey = { true }
        ref.tabs.windowIsKey = { true }
        rig.controller.beginLaunchScreen()
        rig.b.runtime.onLoadProblemChange?(.connecting)
        XCTAssertTrue(rig.controller.isShowingLaunchScreen)
        XCTAssertTrue(rig.controller.isHoldingPageColor)
        let before = rig.snapshot()
        let a = rig.a
        func step(_ name: String, file: StaticString = #filePath, line: UInt = #line, _ event: (TwoTabs, WebRuntime) -> Void) {
            event(rig, a.runtime)
            event(ref, ref.b.runtime)
            XCTAssertEqual(Fields(a.page), Fields(ref.b.page), "\(name)：A 和显示着时一样", file: file, line: line)
            assertUntouched(rig, before, name, file: file, line: line)
        }

        step("加载") { _, runtime in runtime.load(self.chat) }
        step("第一次加载失败") { rig, runtime in rig.fail(runtime) }
        XCTAssertEqual(Fields(a.page), Fields(notice: .waiting))
        step("重新加载") { _, runtime in runtime.reload() }
        XCTAssertEqual(Fields(a.page), Fields(notice: .connecting))
        step("提交") { rig, runtime in rig.commit(runtime) }
        XCTAssertEqual(Fields(a.page), Fields(committed: true, awaiting: true, generation: 1, notice: .connecting, held: true))
        step("加载完成") { rig, runtime in rig.finish(runtime) }
        XCTAssertEqual(Fields(a.page), Fields(committed: true, generation: 2, finished: true, finishColor: TwoTabs.rgb(TwoTabs.white)),
                       "报的是 A 自己的网页视图的颜色")
        XCTAssertEqual(rig.loadedA, [chat, chat])
        XCTAssertEqual(rig.loadedB, [])
        try await pause(0.3)
        assertUntouched(rig, before, "A 加载完成后 0.3 秒")
        XCTAssertTrue(rig.focused.isEmpty, "A 加载完成不聚焦")

        rig.commit(rig.b.runtime)
        rig.finish(rig.b.runtime)
        XCTAssertFalse(rig.controller.isShowingLaunchScreen, "B 自己的加载完成照常结束启动画面")
        XCTAssertFalse(rig.controller.isHoldingPageColor)
        try await waitUntil { !rig.focused.isEmpty }
        XCTAssertEqual(rig.focused.count, 1)
        XCTAssertTrue(rig.focused.first === rig.b.adapter)
    }

    #if DEBUG
    /// 遮挡是每个页面自己的：A 不显示、盖着它自己的遮挡（先选中 A 开始启动画面，再选回 B），B 显示着、也盖着。
    /// A 的加载失败、或者提交并加载完成（都经 A 的运行时，接线带着 A 的页面交给窗口）：A 的遮挡结束；
    /// 窗口（还盖着 B 的启动画面）、B、窗口的日志和替身都不变，A 加载完成不聚焦。之后 B 自己的加载完成照常结束启动画面。
    func testABackgroundTabsLoadEndsOnlyItsOwnCover() async throws {
        for fails in [true, false] {
            let rig = makeRig()
            rig.tabs.windowIsKey = { true }
            let a = rig.a
            rig.tabs.selectForTesting(a)
            rig.controller.beginLaunchScreen()
            rig.tabs.selectForTesting(rig.b)
            rig.controller.beginLaunchScreen()
            XCTAssertTrue(a.page.isCovered)
            XCTAssertTrue(rig.b.page.isCovered)
            let before = rig.snapshot()
            let coverB = "\(rig.b.page.isCovered) \(rig.b.page.coverAwaitsCommit) \(rig.b.page.coverGeneration) \(rig.b.page.coverStarted)"
            a.runtime.load(chat)
            if fails {
                rig.fail(a.runtime)
            } else {
                rig.commit(a.runtime)
                rig.finish(a.runtime)
            }
            XCTAssertFalse(a.page.isCovered, "A 的遮挡结束（失败=\(fails)）")
            XCTAssertFalse(a.page.coverAwaitsCommit)
            assertUntouched(rig, before, "A 的遮挡结束（失败=\(fails)）")
            XCTAssertEqual("\(rig.b.page.isCovered) \(rig.b.page.coverAwaitsCommit) \(rig.b.page.coverGeneration) \(rig.b.page.coverStarted)",
                           coverB, "B 的遮挡不变（失败=\(fails)）")
            try await pause(0.3)
            assertUntouched(rig, before, "之后 0.3 秒（失败=\(fails)）")
            XCTAssertTrue(rig.focused.isEmpty, "A 加载完成不聚焦（失败=\(fails)）")

            rig.commit(rig.b.runtime)
            rig.finish(rig.b.runtime)
            XCTAssertFalse(rig.controller.isShowingLaunchScreen, "B 自己的加载完成照常结束启动画面（失败=\(fails)）")
            XCTAssertFalse(rig.b.page.isCovered)
            XCTAssertEqual(rig.lines.filter { $0.hasPrefix("[launch]") }, ["[launch] 启动画面结束：网页已加载（…ms）"])
        }
    }
    #endif

    // MARK: 2. A 的地址变化

    /// A 换到对话地址：不记对话地址；A 的路径和适配器代号变，B 的不变。A 第二次换页面后 0.8 秒的媒体日志读 A 的适配器。
    /// B 换到对话地址照常记下。
    func testABackgroundTabsURLChangeStaysWithThatTab() async throws {
        let rig = makeRig()
        let a = rig.a, b = rig.b
        a.runtime.onURLChange?(URL(string: "https://chatgpt.com/c/abc?model=x")!)
        a.runtime.onURLChange?(other)
        XCTAssertEqual(rig.saved, [], "后台标签页的地址不记")
        XCTAssertEqual(a.lastPath, "chatgpt.com/c/def")
        XCTAssertEqual(a.adapter.generation, 2)
        XCTAssertNil(b.lastPath)
        XCTAssertEqual(b.adapter.generation, 0)

        b.runtime.onURLChange?(chat)
        XCTAssertEqual(rig.saved, [chat], "选中的标签页的地址照常记下")
        XCTAssertEqual(b.lastPath, "chatgpt.com/c/abc")
        XCTAssertEqual(b.adapter.generation, 1)
        XCTAssertEqual(a.lastPath, "chatgpt.com/c/def", "B 的不改 A 的")
        XCTAssertEqual(a.adapter.generation, 2)

        let changes = [
            "[nav] 页面变化 https://chatgpt.com/c/<id>?<redacted>",
            "[nav] 页面变化 https://chatgpt.com/c/<id>",
            "记下对话地址 https://chatgpt.com/c/abc",
            "[nav] 页面变化 https://chatgpt.com/c/<id>",
        ]
        XCTAssertEqual(rig.lines, changes)
        try await waitUntil { rig.lines.count > changes.count + 1 }
        try await pause(0.3)
        XCTAssertEqual(rig.lines, changes + ["读网页媒体状态 A", "[media] 页面变化后 0.8s WebKit 媒体状态=媒体A"],
                       "只有 A 第二次换页面要记，读的是 A 的适配器")
        XCTAssertEqual(rig.mediaRead.count, 1)
        XCTAssertTrue(rig.mediaRead.first === a.adapter)
    }

    // MARK: 3. Esc

    func testOnlyTheSelectedTabsEscapeHidesTheWindow() {
        let rig = makeRig()
        rig.a.runtime.onEscapeRequest?()
        XCTAssertEqual(rig.hidden, [], "后台标签页的 Esc 不隐藏窗口")
        rig.b.runtime.onEscapeRequest?()
        XCTAssertEqual(rig.hidden, ["网页 Esc"])
        XCTAssertEqual(rig.lines, ["隐藏窗口：网页 Esc"])
    }

    // MARK: 4. 加载完成时聚焦

    /// 窗口是 key 窗口。A 加载完成：A、B 都不聚焦。B 加载完成：聚焦 B 一次；
    /// B 的聚焦还排着时 A 加载完成，也不取代它（后台标签页不发聚焦请求）。
    func testOnlyTheSelectedTabsLoadFocusesAndABackgroundLoadDoesNotCancelIt() async throws {
        let rig = makeRig()
        rig.tabs.windowIsKey = { true }
        rig.a.runtime.onMainFrameLoaded?()
        try await pause(0.3)
        XCTAssertTrue(rig.focused.isEmpty)

        rig.b.runtime.onMainFrameLoaded?()
        rig.a.runtime.onMainFrameLoaded?()
        try await waitUntil { !rig.focused.isEmpty }
        try await pause(0.3)
        XCTAssertEqual(rig.focused.count, 1)
        XCTAssertTrue(rig.focused.first === rig.b.adapter)
        XCTAssertEqual(rig.lines.filter { $0.hasPrefix("聚焦输入框") }, ["聚焦输入框 B"])
    }

    // MARK: 5. 聚焦请求的代号

    /// 更新的请求取代排着的：B 连着请求两次（第二次走窗口级的 focusInputSoon()，取选中的 B），只聚焦一次。
    func testANewerFocusRequestSupersedesAPendingOne() async throws {
        let rig = makeRig()
        rig.tabs.focusInputSoon(for: rig.b)
        rig.tabs.focusInputSoon()
        try await waitUntil { !rig.focused.isEmpty }
        try await pause(0.3)
        XCTAssertEqual(rig.focused.count, 1)
        XCTAssertTrue(rig.focused.first === rig.b.adapter)
    }

    /// 选中 A → B → A。A 先请求聚焦，B 选中时 B 又请求（更新的请求），再选回 A：A 先前那次到点时什么都不做
    /// （A 又是选中的，但它已被取代）；B 那次到点时 B 不是选中的，也不做。A 不选中时的普通事件照常改 A 自己的状态。
    /// 之后 A 新的请求照常聚焦 A。
    func testAFocusRequestSupersededWhileItsTabWasAwayStaysDead() async throws {
        let rig = makeRig()
        let a = rig.a, b = rig.b
        rig.tabs.selectForTesting(a)
        XCTAssertTrue(rig.controller.page === rig.tabs.selected.page)
        rig.tabs.focusInputSoon(for: a)
        rig.tabs.selectForTesting(b)
        XCTAssertTrue(rig.controller.page === rig.tabs.selected.page)
        rig.tabs.focusInputSoon(for: b)
        a.runtime.onURLChange?(chat)
        XCTAssertEqual(a.lastPath, "chatgpt.com/c/abc", "A 不选中时照常改 A 自己的状态")
        XCTAssertEqual(a.adapter.generation, 1)
        XCTAssertEqual(rig.saved, [])
        rig.tabs.selectForTesting(a)
        XCTAssertTrue(rig.controller.page === rig.tabs.selected.page)
        try await pause(0.3)
        XCTAssertTrue(rig.focused.isEmpty, "A 先前的请求已被取代，B 的请求到点时 B 不是选中的")

        rig.tabs.focusInputSoon(for: a)
        try await waitUntil { !rig.focused.isEmpty }
        try await pause(0.2)
        XCTAssertEqual(rig.focused.count, 1)
        XCTAssertTrue(rig.focused.first === a.adapter, "A 新的请求照常聚焦 A")
    }

    /// B 请求聚焦后、到点之前选中了 A（没有新的请求）：到点时 B 不是选中的，不聚焦。
    func testAPendingFocusForATabNoLongerSelectedDoesNothing() async throws {
        let rig = makeRig()
        rig.tabs.focusInputSoon(for: rig.b)
        rig.tabs.selectForTesting(rig.a)
        XCTAssertTrue(rig.controller.page === rig.tabs.selected.page)
        try await pause(0.3)
        XCTAssertTrue(rig.focused.isEmpty)
    }

    // MARK: 6. A 失败和重试

    /// A 第一次加载失败、到时自动重试、再手动重新加载：加载都只到 A 的运行时，B 一次都没有；窗口的提示、日志不动。
    func testABackgroundTabsFailureAndRetryLoadOnlyThatTab() async throws {
        let rig = makeRig(backoffA: [0.1, 60])
        let a = rig.a
        let before = rig.snapshot()
        a.runtime.load(chat)
        rig.fail(a.runtime)
        XCTAssertEqual(a.page.notice, .waiting)
        try await waitUntil { rig.loadedA.count == 2 }
        XCTAssertEqual(rig.loadedA, [chat, chat], "自动重试加载 A")
        XCTAssertEqual(a.page.notice, .connecting)
        rig.fail(a.runtime)
        a.runtime.reload()
        XCTAssertEqual(rig.loadedA, [chat, chat, chat], "手动重新加载 A")
        XCTAssertEqual(rig.loadedB, [])
        assertUntouched(rig, before, "A 失败和重试")
        XCTAssertNil(rig.controller.shownLoadProblem)
        XCTAssertTrue(rig.diagnosticsA.entries.contains { $0.message.contains("自动重试（定时）第 1 次") })
    }

    // MARK: 7. 提示里的“重新加载”

    /// A 在 B 之后接线。按提示里的“重新加载”：重新加载的是按下时选中的 B，不是最后接线的 A。选中 A 后再按，就是 A。
    func testTheNoticesReloadGoesToTheSelectedTabNotTheLastWiredOne() {
        let rig = makeRig()
        rig.b.runtime.load(chat)
        rig.a.runtime.load(other)
        rig.noticeCover.rootView.model.onReload()
        XCTAssertEqual(rig.loadedB, [chat, chat])
        XCTAssertEqual(rig.loadedA, [other])

        rig.tabs.selectForTesting(rig.a)
        XCTAssertTrue(rig.controller.page === rig.tabs.selected.page)
        rig.noticeCover.rootView.model.onReload()
        XCTAssertEqual(rig.loadedA, [other, other], "按下时读选中的")
        XCTAssertEqual(rig.loadedB, [chat, chat])
    }

    // MARK: 8. 交错的事件

    /// A、B 的事件交错，每一步之后两个页面逐项核对，窗口的提示一直照 B 的。
    func testInterleavedEventsOfTwoTabsKeepEachPageApart() {
        let rig = makeRig()
        let a = rig.a, b = rig.b
        var ea = Fields(), eb = Fields()
        func check(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(Fields(a.page), ea, "\(step)：A", file: file, line: line)
            XCTAssertEqual(Fields(b.page), eb, "\(step)：B", file: file, line: line)
            XCTAssertEqual(rig.controller.shownLoadProblem, eb.notice == .hidden ? nil : eb.notice, "\(step)：窗口的提示照 B",
                           file: file, line: line)
            XCTAssertEqual(rig.noticeCover.rootView.model.status, eb.notice, "\(step)：提示那层照 B", file: file, line: line)
        }

        b.runtime.load(chat)
        a.runtime.load(other)
        check("都开始加载")
        rig.fail(a.runtime, other)
        ea.notice = .waiting
        check("A 失败")
        rig.fail(b.runtime)
        eb.notice = .waiting
        check("B 失败")
        a.runtime.reload()
        ea.notice = .connecting
        check("A 重新加载")
        rig.commit(b.runtime)
        eb.committed = true; eb.awaiting = true; eb.generation = 1; eb.held = true
        check("B 提交：B 的提示留着")
        rig.commit(a.runtime)
        ea.committed = true; ea.awaiting = true; ea.generation = 1; ea.held = true
        check("A 提交：A 的提示留着")
        rig.finish(a.runtime)
        ea.awaiting = false; ea.generation = 2; ea.held = false; ea.notice = .hidden; ea.finished = true
        ea.finishColor = TwoTabs.rgb(TwoTabs.white)
        check("A 加载完成")
        XCTAssertNil(rig.controller.loadProblemFadeView, "A 的提示收起不淡出")
        rig.finish(b.runtime)
        eb.awaiting = false; eb.generation = 2; eb.held = false; eb.notice = .hidden; eb.finished = true
        eb.finishColor = TwoTabs.rgb(TwoTabs.dark)
        check("B 加载完成")
        XCTAssertEqual(rig.controller.loadProblemFadeView?.rootView.model.status, .waiting, "B 的提示淡出")
        rig.commit(a.runtime)
        ea.awaiting = true; ea.generation = 3
        check("A 又提交")
        rig.fail(b.runtime)
        check("B 有页面时失败：提示不变")
        XCTAssertEqual(rig.loadedA, [other, other])
        XCTAssertEqual(rig.loadedB, [chat])
    }

    // MARK: 9. 标签页拿掉、释放之后

    /// A 排着聚焦和 0.8 秒的媒体日志时从这组里拿掉（还没释放）：到点都不做。
    func testPendingWorkOfARemovedTabDoesNothing() async throws {
        let rig = makeRig()
        rig.tabs.windowIsKey = { true }
        let a = rig.a, b = rig.b
        rig.tabs.selectForTesting(a)
        rig.tabs.focusInputSoon(for: a)
        a.runtime.onURLChange?(chat)
        a.runtime.onURLChange?(other)
        rig.tabs.selectForTesting(b)
        rig.tabs.removeForTesting(a)
        XCTAssertFalse(rig.tabs.holds(a))
        XCTAssertEqual(rig.tabs.list.tabs, [b.id])
        XCTAssertTrue(rig.tabs.selected === b)
        XCTAssertTrue(rig.controller.page === b.page)
        try await pause(1.1)
        XCTAssertTrue(rig.focused.isEmpty)
        XCTAssertTrue(rig.mediaRead.isEmpty, "拿掉的标签页不再记媒体状态")
        XCTAssertFalse(rig.lines.contains { $0.hasPrefix("[media]") })
    }

    /// A 排着聚焦和媒体日志时拿掉并释放：排着的任务不持有它，到点什么都不做、不崩溃。
    /// A 的运行时还在（WebKit 可能晚到的回调）：它的回调也什么都不做，只有页面状态交给窗口（窗口不显示它，窗口不变）。
    func testPendingWorkOfAReleasedTabDoesNothing() async throws {
        let rig = makeRig()
        rig.tabs.windowIsKey = { true }
        weak var released: ChatTab?
        do {
            let a = rig.a
            released = a
            rig.tabs.selectForTesting(a)
            rig.tabs.focusInputSoon(for: a)
            a.runtime.onURLChange?(chat)
            a.runtime.onURLChange?(other)
            rig.tabs.selectForTesting(rig.b)
            rig.tabs.removeForTesting(a)
        }
        XCTAssertNil(released, "排着的任务和运行时的回调都不持有标签页")
        let before = rig.snapshot()
        rig.runtimeA.onURLChange?(chat)
        rig.runtimeA.onEscapeRequest?()
        rig.runtimeA.onMainFrameLoaded?()
        rig.runtimeA.onLoadProblemChange?(.waiting)
        rig.runtimeA.onMainFrameCommitted?()
        rig.runtimeA.onLoadFailed?()
        try await pause(1.1)
        assertUntouched(rig, before, "A 释放后")
        XCTAssertTrue(rig.focused.isEmpty)
        XCTAssertTrue(rig.mediaRead.isEmpty)
        XCTAssertTrue(rig.hidden.isEmpty)
    }

    // MARK: - 对选中的标签页做的操作：开始时绑定那个标签页，之后不再读“现在选中的”

    // MARK: 10. 新对话

    // 新对话只在开不了新标签页时在选中的标签页里新建，这几条用上限 2（B、A 就到上限）；有空位时开在新标签页，见 NewChatTabTests。

    /// B 选中时按新对话，马上（新对话的任务还没开始）就选中了 A：页面里的入口问的是 B 的适配器；没点到，整页加载给 B。
    /// A 一次都没有，谁都不聚焦。
    func testNewChatIsBoundToTheTabSelectedWhenPressed() async throws {
        let rig = makeRig(capacity: 2)
        rig.tabs.newChat()
        rig.tabs.selectForTesting(rig.a)
        try await waitUntil { !rig.loadedB.isEmpty }
        try await pause(0.3)
        XCTAssertEqual(rig.newChatAsked.map(rig.name), ["B"])
        XCTAssertEqual(rig.loadedB, [WebRuntime.homeURL])
        XCTAssertEqual(rig.loadedA, [])
        XCTAssertTrue(rig.focused.isEmpty)
    }

    /// 页面里的入口还在等的时候选中了 A。没点到：整页加载给 B（它不选中也加载，是它自己的页面），A 不加载、不聚焦。
    func testNewChatsFollowUpLoadGoesToItsOwnTabAfterTheSelectionMoved() async throws {
        let rig = makeRig(capacity: 2)
        rig.newChatDelay = 0.15
        rig.tabs.newChat()
        try await waitUntil { !rig.newChatAsked.isEmpty }
        rig.tabs.selectForTesting(rig.a)
        try await waitUntil { !rig.loadedB.isEmpty }
        try await pause(0.3)
        XCTAssertEqual(rig.loadedB, [WebRuntime.homeURL])
        XCTAssertEqual(rig.loadedA, [])
        XCTAssertTrue(rig.focused.isEmpty)
        XCTAssertEqual(rig.lines.filter { !$0.hasPrefix("[nav] 加载") },
                       ["[tabs] 新建对话：已到上限（2 个），在当前标签页新建", "页面里新对话 B"])
    }

    /// 页面里点到了：等的时候选中了 A。聚焦请求给 B，到点时 B 不是选中的，不聚焦；A 也不聚焦。谁都不加载。
    /// 对照：不换选中的，同样的新对话聚焦 B。
    func testNewChatInPageFocusesOnlyItsOwnTab() async throws {
        let rig = makeRig(capacity: 2)
        rig.newChatInPage = true
        rig.newChatDelay = 0.15
        rig.tabs.newChat()
        try await waitUntil { !rig.newChatAsked.isEmpty }
        rig.tabs.selectForTesting(rig.a)
        try await pause(0.45)
        XCTAssertTrue(rig.focused.isEmpty, "B 不是选中的了，A 不是这次新对话的")
        XCTAssertEqual(rig.loadedA, [])
        XCTAssertEqual(rig.loadedB, [])

        let control = makeRig(capacity: 2)
        control.newChatInPage = true
        control.newChatDelay = 0.15
        control.tabs.newChat()
        try await waitUntil { !control.focused.isEmpty }
        XCTAssertEqual(control.focused.map(control.name), ["B"])
    }

    /// 页面里的入口还在等的时候 B 被拿掉（先选中 A）：之后什么都不做，不加载、不聚焦，不崩溃。
    func testNewChatForATabRemovedMeanwhileDoesNothing() async throws {
        let rig = makeRig(capacity: 2)
        rig.newChatDelay = 0.15
        rig.tabs.newChat()
        try await waitUntil { !rig.newChatAsked.isEmpty }
        rig.tabs.selectForTesting(rig.a)
        rig.tabs.removeForTesting(rig.b)
        try await pause(0.45)
        XCTAssertEqual(rig.loadedB, [])
        XCTAssertEqual(rig.loadedA, [])
        XCTAssertTrue(rig.focused.isEmpty)
    }

    // MARK: 11. 窗口显示后提前重试

    /// A、B 第一次加载都失败了，窗口里没有页面，都在等自动重试。窗口显示（唤醒）：只有选中的 B 提前重试，A 不发请求；
    /// 切模式不算（和以前一样）。选中 A 后再唤醒：这回只有 A。
    func testWindowShownRetriesOnlyTheSelectedTab() {
        let rig = makeRig()
        rig.b.runtime.load(chat)
        rig.fail(rig.b.runtime)
        rig.a.runtime.load(other)
        rig.fail(rig.a.runtime, other)
        XCTAssertEqual(rig.b.page.notice, .waiting)
        XCTAssertEqual(rig.a.page.notice, .waiting)

        rig.controller.onDidShow?(.wake)
        XCTAssertEqual(rig.loadedB, [chat, chat], "选中的 B 提前重试")
        XCTAssertEqual(rig.loadedA, [other], "A 不显示，不提前重试")
        rig.controller.onDidShow?(.modeSwitch)
        XCTAssertEqual(rig.loadedA, [other])

        rig.tabs.selectForTesting(rig.a)
        rig.controller.onDidShow?(.wake)
        XCTAssertEqual(rig.loadedA, [other, other])
        XCTAssertEqual(rig.loadedB, [chat, chat])
    }

    /// 窗口显示后聚焦这一刻选中的标签页（和提前重试是同一个）。
    func testWindowShownFocusesTheTabSelectedAtThatMoment() async throws {
        let rig = makeRig()
        rig.tabs.selectForTesting(rig.a)
        rig.controller.onDidShow?(.activate)
        try await waitUntil { !rig.focused.isEmpty }
        try await pause(0.2)
        XCTAssertEqual(rig.focused.map(rig.name), ["A"])
    }

    // MARK: 12. 网络状态

    /// 共用的网络状态。B 由 ChatTabs.init 登记，A 由 add 登记；C 是断网之后才加进来的：加进来时补发“断网”。
    /// C 第一次加载失败，断网期间不发请求；网络恢复时 C 照它自己的规则重试，B 已经加载好、A 从没加载，都不加载。
    /// C 拿掉以后（又在等重试）什么都收不到：再断网、恢复，C 不重试、不记日志；A、B 照常收到。
    func testEveryHeldTabHearsTheNetworkAndARemovedOneStopsHearingIt() throws {
        let rig = makeRig()
        rig.b.runtime.load(chat)
        rig.commit(rig.b.runtime)
        rig.finish(rig.b.runtime)
        rig.network.deliver(online: false)
        XCTAssertEqual(rig.netLog(rig.diagnostics), ["网络不可用"], "B 登记了")
        XCTAssertEqual(rig.netLog(rig.diagnosticsA), ["网络不可用"], "A 登记了")

        let diagnosticsC = Diagnostics()
        let runtimeC = WebRuntime(diagnostics: diagnosticsC, settings: rig.settings,
                                  recovery: LoadRecovery(backoff: [60, 60]), watchesNetwork: false)
        let loadsC = URLList()
        runtimeC.loadRequest = { request in loadsC.urls.append(request.url!) }
        let adapterC = ChatGPTAdapter(webView: runtimeC.webView, diagnostics: diagnosticsC, settings: rig.settings)
        let c = try XCTUnwrap(rig.tabs.add(runtime: runtimeC, adapter: adapterC))
        XCTAssertEqual(rig.netLog(diagnosticsC), ["网络不可用"], "加进来时补发")
        runtimeC.load(chat)
        rig.fail(runtimeC)
        XCTAssertEqual(loadsC.urls, [chat], "断网期间不发请求")
        XCTAssertEqual(c.page.notice, .waiting)

        rig.network.deliver(online: true)
        XCTAssertEqual(loadsC.urls, [chat, chat], "C 在等网络恢复：重试一次")
        XCTAssertEqual(c.page.notice, .connecting)
        XCTAssertEqual(rig.loadedB, [chat], "B 已加载好，不重新加载")
        XCTAssertEqual(rig.loadedA, [], "A 没失败过，不加载")
        rig.fail(runtimeC)
        XCTAssertEqual(c.page.notice, .waiting)

        rig.tabs.removeForTesting(c)
        rig.network.deliver(online: false)
        rig.network.deliver(online: true)
        XCTAssertEqual(rig.netLog(diagnosticsC), ["网络不可用", "网络可用"], "拿掉以后什么都收不到")
        XCTAssertEqual(loadsC.urls, [chat, chat], "拿掉以后网络恢复也不重试")
        XCTAssertEqual(rig.netLog(rig.diagnostics), ["网络不可用", "网络可用", "网络不可用", "网络可用"])
        XCTAssertEqual(rig.netLog(rig.diagnosticsA), ["网络不可用", "网络可用", "网络不可用", "网络可用"])
        XCTAssertEqual(rig.network.registeredCount, 2)
    }

    // MARK: 13. 排版变化前后的阅读位置

    /// 记下和放回都交给记下时选中的 B，放回的是那一次的编号。
    func testTheReadingPositionIsRestoredToTheTabThatHeldIt() {
        let rig = makeRig()
        let calls = rig.recordReadingPosition()
        rig.controller.onWillChangeLayout?()
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(calls.list, ["记下 B", "放回 B"])
        XCTAssertEqual(calls.tokens, [1, 1])
    }

    /// A 记下之后选中了 B（D2）：不马上放回，也不丢，留在 A 上（写一行带 A 的日志）；B 什么都不收到，窗口不变。
    /// A → B → A：A 又选中、排好版（tabShownAndLaidOut）时才放回给 A，是那一次的编号；之后再调一次什么都不做。
    /// 没选中时调、对没有留着的标签页调，都什么都不做。
    func testARestoreForATabThatIsNoLongerSelectedWaitsUntilItIsShownAndLaidOut() throws {
        let rig = makeRig()
        rig.a.runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        rig.tabs.selectForTesting(rig.a)
        rig.controller.onWillChangeLayout?()
        rig.tabs.selectForTesting(rig.b)
        let before = rig.snapshot()
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(calls.list, ["记下 A"])
        XCTAssertEqual(rig.a.pendingReadingRestore?.token, 1)
        XCTAssertNil(rig.b.pendingReadingRestore)
        XCTAssertEqual(rig.lines.last, "[reading] 阅读位置：这一页没有显示，记下的位置留到它再显示并排好版时放回")
        let after = rig.snapshot()
        XCTAssertEqual(after.window, before.window)
        XCTAssertEqual(after.displayed, before.displayed)
        XCTAssertEqual(after.calls, before.calls)

        rig.tabs.tabShownAndLaidOut(rig.a)
        rig.tabs.tabShownAndLaidOut(rig.b)
        XCTAssertEqual(calls.list, ["记下 A"], "A 不是选中的：不放回；B 没有留着的")
        XCTAssertNotNil(rig.a.pendingReadingRestore)

        let pending = try XCTUnwrap(rig.a.pendingReadingRestore)
        rig.tabs.selectForTesting(rig.a)
        rig.tabs.tabShownAndLaidOut(rig.a)
        XCTAssertEqual(calls.list, ["记下 A", "放回 A"])
        XCTAssertEqual(calls.tokens, [1, 1])
        XCTAssertNil(rig.a.pendingReadingRestore)
        XCTAssertTrue(pending.isSettled)
        XCTAssertEqual(rig.lines.last, "[reading] 阅读位置：这一页又显示并排好版，放回留着的位置")
        rig.tabs.tabShownAndLaidOut(rig.a)
        XCTAssertEqual(calls.list, ["记下 A", "放回 A"], "只放回一次")
    }

    /// B 记下之后选中了 A，B 在后台换到别的对话：换的那一刻就丢弃（网页里丢掉那一次），排版结束时什么都不做，
    /// 不把旧对话的位置放到别的对话上。只是 query 变了不算换页面：留着，B 再显示并排好版时放回。
    func testARestoreForABackgroundTabThatNavigatedIsDiscarded() {
        let rig = makeRig()
        rig.b.runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        rig.controller.onWillChangeLayout?()
        rig.tabs.selectForTesting(rig.a)
        rig.b.runtime.onURLChange?(other)
        XCTAssertEqual(calls.list, ["记下 B", "丢弃 B"])
        XCTAssertEqual(calls.tokens, [1, 1])
        rig.b.runtime.onURLChange?(URL(string: "https://chatgpt.com/c/ghi")!)
        rig.commit(rig.b.runtime)
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(calls.list, ["记下 B", "丢弃 B"], "丢弃过的那一次之后不再丢第二遍")
        XCTAssertNil(rig.b.pendingReadingRestore)

        rig.tabs.selectForTesting(rig.b)
        rig.controller.onWillChangeLayout?()
        rig.tabs.selectForTesting(rig.a)
        rig.b.runtime.onURLChange?(URL(string: "https://chatgpt.com/c/ghi?model=x")!)
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(calls.list, ["记下 B", "丢弃 B", "记下 B"])
        rig.tabs.selectForTesting(rig.b)
        rig.tabs.tabShownAndLaidOut(rig.b)
        XCTAssertEqual(calls.list, ["记下 B", "丢弃 B", "记下 B", "放回 B"])
        XCTAssertEqual(calls.tokens, [1, 1, 2, 2])
    }

    /// B 记下之后、换回 B 之前，B 换到别的对话又换回原来的对话：换走那一刻就丢弃了，换回来也不再放回。
    func testARestoreForABackgroundTabThatNavigatedAwayAndBackIsDiscarded() {
        let rig = makeRig()
        rig.b.runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        rig.controller.onWillChangeLayout?()
        rig.tabs.selectForTesting(rig.a)
        rig.b.runtime.onURLChange?(other)
        rig.b.runtime.onURLChange?(chat)
        XCTAssertEqual(rig.b.lastPath, "chatgpt.com/c/abc")
        rig.controller.onDidChangeLayout?()
        rig.tabs.selectForTesting(rig.b)
        rig.tabs.tabShownAndLaidOut(rig.b)
        XCTAssertEqual(calls.list, ["记下 B", "丢弃 B"])
    }

    /// B 记下之后选中了 A、B 被拿掉：放回作废，不崩溃。
    func testARestoreForARemovedTabIsDiscarded() {
        let rig = makeRig()
        let calls = rig.recordReadingPosition()
        rig.controller.onWillChangeLayout?()
        rig.tabs.selectForTesting(rig.a)
        rig.tabs.removeForTesting(rig.b)
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(calls.list, ["记下 B"])
        XCTAssertNil(rig.b.pendingReadingRestore, "不在这组里的不留着")
        XCTAssertFalse(rig.lines.contains { $0.contains("阅读位置") })
    }

    /// A 留着阅读位置时被拿掉（没关闭，运行时的回调还接着）：之后它的提交、换页面、再显示都不碰它的网页，也不写日志。
    func testLateEventsOfARemovedTabWithAPendingPositionDoNothing() {
        let rig = makeRig()
        rig.a.runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        makePending(rig, on: rig.a)
        let lines = rig.lines
        let a = rig.a
        rig.tabs.removeForTesting(a)
        rig.commit(rig.runtimeA)
        rig.runtimeA.onURLChange?(other)
        rig.tabs.tabShownAndLaidOut(a)
        XCTAssertEqual(calls.list, ["记下 A"])
        XCTAssertEqual(a.mainFrameCommits, 0)
        XCTAssertEqual(rig.lines.filter { $0.contains("阅读位置") }, lines.filter { $0.contains("阅读位置") })
    }

    /// B 排版中记下（选中的），A 在后台换对话、提交：只看 A 自己的，B 的那一次不受影响，照常放回给 B。
    func testABackgroundTabsNavigationLeavesTheSelectedTabsPositionAlone() {
        let rig = makeRig()
        rig.b.runtime.onURLChange?(chat)
        rig.a.runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        rig.controller.onWillChangeLayout?()
        rig.a.runtime.onURLChange?(other)
        rig.a.runtime.onURLChange?(URL(string: "https://chatgpt.com/c/ghi")!)
        rig.commit(rig.runtimeA)
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(calls.list, ["记下 B", "放回 B"])
        XCTAssertFalse(rig.lines.contains { $0.contains("阅读位置") })
    }

    /// 仍是选中的标签页也按连续性规则（3.2 起；阶段 2 时照样放回，是临时例外）：
    /// B 记下之后从新对话页一步拿到对话地址（/ → /c/…）：放回给 B，但要网页确认（地址分不清是不是同一个对话）；
    /// B 记下之后换到别的对话：换的那一刻丢弃，排版结束时什么都不做。
    func testTheStillSelectedTabFollowsTheContinuityRule() {
        let rig = makeRig()
        rig.b.runtime.onURLChange?(WebRuntime.homeURL)
        let calls = rig.recordReadingPosition()
        rig.controller.onWillChangeLayout?()
        rig.b.runtime.onURLChange?(chat)
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(calls.list, ["记下 B", "放回 B（要网页确认）"])

        rig.controller.onWillChangeLayout?()
        rig.b.runtime.onURLChange?(other)
        XCTAssertEqual(calls.list, ["记下 B", "放回 B（要网页确认）", "记下 B", "丢弃 B"])
        XCTAssertEqual(rig.lines.last, "[reading] 阅读位置：丢弃排版前记下的位置（换了对话）")
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(calls.list, ["记下 B", "放回 B（要网页确认）", "记下 B", "丢弃 B"])
        XCTAssertEqual(calls.tokens, [1, 1, 2, 2])
    }

    /// 套着的两次排版变化（拖边途中按切换键）：记下、记下、放回、放回，后进先出。都在同一个标签页上时，四次都给它
    /// （一个标签页时就是原来的）。中途选中了 A：后记下的那次（A 的）放回给 A；先记下的那次（B 的）到时 B 不是选中的，
    /// 留在 B 上（D2），B 再显示并排好版时放回。
    func testNestedLayoutChangesPairLastInFirstOut() {
        let rig = makeRig()
        let calls = rig.recordReadingPosition()
        rig.controller.onWillChangeLayout?()
        rig.controller.onWillChangeLayout?()
        rig.controller.onDidChangeLayout?()
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(calls.list, ["记下 B", "记下 B", "放回 B", "放回 B"])
        XCTAssertEqual(calls.tokens, [1, 2, 2, 1])

        calls.list = []
        calls.tokens = []
        rig.controller.onWillChangeLayout?()
        rig.tabs.selectForTesting(rig.a)
        rig.controller.onWillChangeLayout?()
        rig.controller.onDidChangeLayout?()
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(calls.list, ["记下 B", "记下 A", "放回 A"])
        XCTAssertEqual(calls.tokens, [3, 4, 4])
        XCTAssertEqual(rig.b.pendingReadingRestore?.token, 3)
        rig.tabs.selectForTesting(rig.b)
        rig.tabs.tabShownAndLaidOut(rig.b)
        XCTAssertEqual(calls.list, ["记下 B", "记下 A", "放回 A", "放回 B"])
        XCTAssertEqual(calls.tokens, [3, 4, 4, 3])
    }

    /// A 记下、留着（不选中）期间在后台换了页面：按规则看。
    /// - 换到别的对话：当场丢弃留着的（网页里按编号丢掉，写一行带 A 的日志），A 再显示也不放回；窗口不变。
    func testAPendingPositionIsDroppedWhenItsTabChangesConversationInTheBackground() {
        let rig = makeRig()
        rig.a.runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        makePending(rig, on: rig.a)
        let before = rig.snapshot()
        rig.a.runtime.onURLChange?(other)
        XCTAssertEqual(calls.list, ["记下 A", "丢弃 A"])
        XCTAssertEqual(calls.tokens, [1, 1])
        XCTAssertNil(rig.a.pendingReadingRestore)
        XCTAssertEqual(rig.lines.last, "[reading] 阅读位置：丢弃排版前记下的位置（换了对话）")
        let after = rig.snapshot()
        XCTAssertEqual(after.window, before.window)
        XCTAssertEqual(after.displayed, before.displayed)
        rig.tabs.selectForTesting(rig.a)
        rig.tabs.tabShownAndLaidOut(rig.a)
        XCTAssertEqual(calls.list, ["记下 A", "丢弃 A"])
    }

    /// - A 的主框架提交了（重新加载、整页导航）：当场丢弃，A 自己的页面状态照常记下提交。
    func testAPendingPositionIsDroppedWhenItsTabCommitsInTheBackground() {
        let rig = makeRig()
        rig.a.runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        makePending(rig, on: rig.a)
        rig.commit(rig.runtimeA)
        XCTAssertEqual(calls.list, ["记下 A", "丢弃 A"])
        XCTAssertNil(rig.a.pendingReadingRestore)
        XCTAssertTrue(rig.a.page.hasCommittedPage, "A 的页面状态照常记下提交")
        XCTAssertEqual(rig.a.mainFrameCommits, 1)
        XCTAssertEqual(rig.b.mainFrameCommits, 0)
        XCTAssertEqual(rig.lines.last, "[reading] 阅读位置：丢弃排版前记下的位置（页面重新加载过）")
    }

    /// - 只变了 query：留着，A 再显示并排好版时放回。
    /// - 新对话页一步拿到对话地址（第一条消息发出后在后台拿到地址）：留着，A 再显示时放回、要网页确认。
    /// - 新对话页换了两次页面到对话：丢弃（不是“拿到地址”那一步）。
    func testAPendingPositionFollowsTheRuleForQueryAndNewChatChanges() {
        let rig = makeRig()
        rig.a.runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        makePending(rig, on: rig.a)
        rig.a.runtime.onURLChange?(URL(string: "https://chatgpt.com/c/abc?model=x")!)
        XCTAssertNotNil(rig.a.pendingReadingRestore)
        rig.tabs.selectForTesting(rig.a)
        rig.tabs.tabShownAndLaidOut(rig.a)
        XCTAssertEqual(calls.list, ["记下 A", "放回 A"])

        calls.list = []
        rig.a.runtime.onURLChange?(WebRuntime.homeURL)
        makePending(rig, on: rig.a)
        rig.a.runtime.onURLChange?(other)
        XCTAssertNotNil(rig.a.pendingReadingRestore, "/ → /c/…：留着，等网页确认")
        rig.tabs.selectForTesting(rig.a)
        rig.tabs.tabShownAndLaidOut(rig.a)
        XCTAssertEqual(calls.list, ["记下 A", "放回 A（要网页确认）"])

        calls.list = []
        rig.a.runtime.onURLChange?(WebRuntime.homeURL)
        makePending(rig, on: rig.a)
        rig.a.runtime.onURLChange?(chat)
        rig.a.runtime.onURLChange?(other)
        XCTAssertEqual(calls.list, ["记下 A", "丢弃 A"])
        XCTAssertNil(rig.a.pendingReadingRestore)
        XCTAssertEqual(rig.lines.last, "[reading] 阅读位置：丢弃排版前记下的位置（新对话页之后换了不止一次页面）")
    }

    /// A 带着留着的阅读位置被关闭：丢掉留着的，不碰 A 的网页（不放回、不丢弃，运行时已经关了），之后什么都不再对它做。
    /// A 在排版中记下、还没结束时被关闭：排版结束时也什么都不做。B 照常。
    func testClosingATabDropsItsPendingAndInFlightPositionsWithoutTouchingItsPage() throws {
        let rig = makeRig()
        rig.a.runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        makePending(rig, on: rig.a)
        let pending = try XCTUnwrap(rig.a.pendingReadingRestore)
        let a = rig.a
        let urlChange = rig.runtimeA.onURLChange
        rig.tabs.close(a)
        XCTAssertNil(a.pendingReadingRestore)
        XCTAssertTrue(pending.isSettled)
        XCTAssertEqual(calls.list, ["记下 A"], "关闭时不碰 A 的网页")
        urlChange?(other)
        rig.tabs.tabShownAndLaidOut(a)
        XCTAssertEqual(calls.list, ["记下 A"], "关闭以后的地址变化、再显示都不做事")

        let rig2 = makeRig()
        let calls2 = rig2.recordReadingPosition()
        rig2.tabs.selectForTesting(rig2.a)
        rig2.controller.onWillChangeLayout?()
        rig2.controller.onWillChangeLayout?()
        rig2.tabs.selectForTesting(rig2.b)
        let a2 = rig2.a
        rig2.tabs.close(a2)
        rig2.controller.onDidChangeLayout?()
        rig2.controller.onDidChangeLayout?()
        XCTAssertEqual(calls2.list, ["记下 A", "记下 A"])
        XCTAssertNil(a2.pendingReadingRestore)

        rig2.controller.onWillChangeLayout?()
        rig2.controller.onDidChangeLayout?()
        XCTAssertEqual(calls2.list, ["记下 A", "记下 A", "记下 B", "放回 B"], "B 照常")
    }

    /// 丢弃只动那一次（编号），不动更新的：
    /// - 套着记下两次、都到 A 不选中时才结束：先结束的是后记下的（编号大），留着；再结束的是先记下的（编号小），丢弃它，
    ///   留着的还是更新的那次。A 再显示时放回更新的那次。
    /// - 已经留着一次时又有更新的一次要留：丢弃旧的，留新的。
    func testDiscardingAnOlderPositionLeavesTheNewerOneAlone() {
        let rig = makeRig()
        rig.a.runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        rig.tabs.selectForTesting(rig.a)
        rig.controller.onWillChangeLayout?()
        rig.controller.onWillChangeLayout?()
        rig.tabs.selectForTesting(rig.b)
        rig.controller.onDidChangeLayout?()
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(calls.list, ["记下 A", "记下 A", "丢弃 A"])
        XCTAssertEqual(calls.tokens, [1, 2, 1])
        XCTAssertEqual(rig.a.pendingReadingRestore?.token, 2)
        XCTAssertEqual(Array(rig.lines.suffix(2)), [
            "[reading] 阅读位置：这一页没有显示，记下的位置留到它再显示并排好版时放回",
            "[reading] 阅读位置：丢弃排版前记下的位置（这一页留着更新的一次）",
        ])

        makePending(rig, on: rig.a)
        XCTAssertEqual(calls.list, ["记下 A", "记下 A", "丢弃 A", "记下 A", "丢弃 A"])
        XCTAssertEqual(calls.tokens, [1, 2, 1, 3, 2])
        XCTAssertEqual(rig.a.pendingReadingRestore?.token, 3)
        XCTAssertTrue(rig.lines.contains("[reading] 阅读位置：丢弃排版前记下的位置（这一页有了更新的一次）"))
        rig.tabs.selectForTesting(rig.a)
        rig.tabs.tabShownAndLaidOut(rig.a)
        XCTAssertEqual(calls.list.last, "放回 A")
        XCTAssertEqual(calls.tokens.last, 3)
    }

    /// 放回和再显示时都自己再按规则看一遍，不只靠换页面时那一次：状态变了而没经过 urlChanged（这里直接改，应用里不会这样）
    /// 也照样丢弃。
    func testRestoreAndShowRecheckTheRuleThemselves() {
        let rig = makeRig()
        rig.b.runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        rig.controller.onWillChangeLayout?()
        rig.b.url = other
        rig.b.adapter.invalidate()
        rig.controller.onDidChangeLayout?()
        XCTAssertEqual(calls.list, ["记下 B", "丢弃 B"])

        calls.list = []
        rig.a.runtime.onURLChange?(chat)
        makePending(rig, on: rig.a)
        rig.a.mainFrameCommits += 1
        rig.tabs.selectForTesting(rig.a)
        rig.tabs.tabShownAndLaidOut(rig.a)
        XCTAssertEqual(calls.list, ["记下 A", "丢弃 A"])
        XCTAssertNil(rig.a.pendingReadingRestore)
    }

    /// 让 tab 记下一次、在它不选中时结束排版：留在它上面。之后选中的是 B。
    private func makePending(_ rig: TwoTabs, on tab: ChatTab) {
        rig.tabs.selectForTesting(tab)
        rig.controller.onWillChangeLayout?()
        rig.tabs.selectForTesting(tab === rig.b ? rig.a : rig.b)
        rig.controller.onDidChangeLayout?()
        rig.tabs.selectForTesting(rig.b)
    }

    // MARK: 14. 设置：每个标签页都改

    /// 页面缩放、网页无障碍、网页增强脚本、弹窗标题：两个标签页的网页视图都改，A 不显示也一样。
    func testSettingsReachEveryTab() {
        let rig = makeRig()
        let a = rig.a, b = rig.b
        rig.tabs.setPageZoom(1.25)
        XCTAssertEqual(b.runtime.webView.pageZoom, 1.25)
        XCTAssertEqual(a.runtime.webView.pageZoom, 1.25)

        rig.tabs.setPageAccessibilityAllowed(true)
        XCTAssertFalse(b.runtime.webView.blockAccessibility)
        XCTAssertFalse(a.runtime.webView.blockAccessibility)
        rig.tabs.setPageAccessibilityAllowed(false)
        XCTAssertTrue(b.runtime.webView.blockAccessibility)
        XCTAssertTrue(a.runtime.webView.blockAccessibility)

        let scripts = { (tab: ChatTab) in tab.runtime.webView.configuration.userContentController.userScripts.count }
        XCTAssertEqual(scripts(b), 2)
        XCTAssertEqual(scripts(a), 2)
        rig.settings.webEnhancements = false
        rig.tabs.applyEnhancementScripts()
        XCTAssertEqual(scripts(b), 0)
        XCTAssertEqual(scripts(a), 0)
        rig.settings.webEnhancements = true
        rig.tabs.applyEnhancementScripts()
        XCTAssertEqual(scripts(b), 2)
        XCTAssertEqual(scripts(a), 2)

        let popups = [b, a].map { tab -> NSWindow in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.title = "旧标题"
            tab.runtime.adoptPopupForTesting(window)
            return window
        }
        rig.tabs.retitlePopups()
        XCTAssertEqual(popups.map(\.title), [L10n.string("window.popup"), L10n.string("window.popup")])
        XCTAssertNotEqual(L10n.string("window.popup"), "旧标题")
    }

    // MARK: 15. 每秒的媒体状态

    /// 读哪个标签页在调用这一刻定下：调用之后马上（读的任务还没开始）选中了 A，读的还是 B。
    /// 这时选中的是 A：再读一次，读的时候选中了 B，读完显示和日志都是 A 读到的。下一次读 B。
    func testEachMediaTickReadsTheTabSelectedWhenItFired() async throws {
        let rig = makeRig()
        rig.tabs.mediaTick()
        rig.tabs.selectForTesting(rig.a)
        try await waitUntil { rig.lines.contains { $0.hasPrefix("[media]") } }
        XCTAssertEqual(rig.mediaRead.map(rig.name), ["B"])
        XCTAssertEqual(rig.diagnostics.webMediaState, "媒体B")

        rig.mediaDelay = 0.15
        rig.tabs.mediaTick()
        try await waitUntil { rig.mediaRead.count == 2 }
        rig.tabs.selectForTesting(rig.b)
        try await waitUntil { rig.lines.filter { $0.hasPrefix("[media]") }.count == 2 }
        XCTAssertEqual(rig.diagnostics.webMediaState, "媒体A", "读的时候换了选中的：还是 A 的")

        rig.mediaDelay = 0
        rig.tabs.mediaTick()
        try await waitUntil { rig.mediaRead.count == 3 }
        try await pause(0.1)
        XCTAssertEqual(rig.mediaRead.map(rig.name), ["B", "A", "B"])
        XCTAssertEqual(rig.diagnostics.webMediaState, "媒体B")
        XCTAssertEqual(rig.lines.filter { $0.hasPrefix("[media]") }, [
            "[media] WebKit 媒体状态 none → 媒体B（窗口可见=false）",
            "[media] WebKit 媒体状态 none → 媒体A（窗口可见=false）",
        ], "每个标签页和它自己上次读到的比：A 第一次读到的从 none 起，B 第二次读到的和上次一样、不写")
    }

    /// 读的时候 B 被拿掉（先选中 A）：读完不显示、不写日志、不改记下的状态。下一次读选中的 A，照常从原来的状态记。
    func testAMediaTickForATabRemovedDuringTheReadIsDropped() async throws {
        let rig = makeRig()
        let shown = rig.diagnostics.webMediaState
        rig.mediaDelay = 0.15
        rig.tabs.mediaTick()
        try await waitUntil { !rig.mediaRead.isEmpty }
        rig.tabs.selectForTesting(rig.a)
        rig.tabs.removeForTesting(rig.b)
        try await pause(0.3)
        XCTAssertEqual(rig.diagnostics.webMediaState, shown)
        XCTAssertFalse(rig.lines.contains { $0.hasPrefix("[media]") })

        rig.mediaDelay = 0
        rig.tabs.mediaTick()
        try await waitUntil { rig.lines.contains { $0.hasPrefix("[media]") } }
        XCTAssertEqual(rig.lines.filter { $0.hasPrefix("[media]") }, ["[media] WebKit 媒体状态 none → 媒体A（窗口可见=false）"])
    }

    // MARK: 16. 证据采集、媒体实验

    /// 在步骤这一层核对（真的步骤要真实页面）：每一步都交给开始时选中的 B；第一步里选中了 A，剩下的步骤还是 B 的。
    /// 采集证据和几种媒体实验都一样（每次开始时选中的是哪个，就一路是哪个）。
    func testEvidenceAndExperimentsStayOnTheTabTheyStartedOn() async {
        let rig = makeRig()
        let steps = EvidenceSteps()
        rig.tabs.evidenceTarget = { [weak rig] tab in EvidenceSpy(name: rig?.name(tab.adapter) ?? "?", steps: steps) }
        steps.onFirstStep = { [weak rig] in rig.map { $0.tabs.selectForTesting($0.a) } }
        await rig.tabs.collectEvidence(measure: true)
        XCTAssertEqual(steps.list, ["B probe", "B readAloudEvidence", "B measureMedia"])
        XCTAssertEqual(rig.diagnostics.readAloudEvidence, "证据 B")
        XCTAssertEqual(rig.diagnostics.mediaMeasurement, "测量 B")

        for (kind, expected) in [(ExperimentKind.suspendAll, ["A suspend true", "A webMediaState"]),
                                 (.pauseAll, ["B pauseAll", "B webMediaState"]),
                                 (.setRate(1.5), ["A setRate 1.5"]),
                                 (.measure, ["B measureMedia"])] {
            steps.list = []
            let other = rig.tabs.isSelected(rig.a) ? rig.b : rig.a
            steps.onFirstStep = { [weak rig] in rig?.tabs.selectForTesting(other) }
            await rig.tabs.runExperiment(kind)
            XCTAssertEqual(steps.list, expected, "\(kind)")
        }
        XCTAssertEqual(rig.diagnostics.experiments.map { String($0.drop { $0 != " " }.dropFirst()) }, [
            "WebKit setAllMediaPlaybackSuspended(true) → 状态 媒体 A",
            "WebKit pauseAllMediaPlayback → 状态 媒体 B",
            "DOM playbackRate=1.5：速率 A",
            "测量：测量 B",
        ])
    }

    /// 第一步里开始时的那个标签页被拿掉（先选中别的）：剩下的步骤都不做，已经写进诊断的不动。
    func testEvidenceStopsWhenItsTabIsRemoved() async {
        let rig = makeRig()
        let steps = EvidenceSteps()
        rig.tabs.evidenceTarget = { [weak rig] tab in EvidenceSpy(name: rig?.name(tab.adapter) ?? "?", steps: steps) }
        rig.tabs.selectForTesting(rig.a)
        steps.onFirstStep = { [weak rig] in
            guard let rig else { return }
            rig.tabs.selectForTesting(rig.b)
            rig.tabs.removeForTesting(rig.a)
        }
        await rig.tabs.collectEvidence(measure: true)
        XCTAssertEqual(steps.list, ["A probe"])
        XCTAssertEqual(rig.diagnostics.readAloudEvidence, Diagnostics.notCollected)
        XCTAssertEqual(rig.diagnostics.mediaMeasurement, Diagnostics.notMeasured)
    }

    /// 正式运行时交给标签页自己的适配器：B 的网页里没有页面，采集的结果是“不是聊天页面”（这几步不跑网页脚本）。
    func testEvidenceUsesTheTabsOwnAdapterByDefault() async {
        let rig = makeRig()
        await rig.tabs.collectEvidence(measure: true)
        XCTAssertTrue(rig.diagnostics.readAloudEvidence.contains("not-chat-page"), rig.diagnostics.readAloudEvidence)
        XCTAssertEqual(rig.diagnostics.mediaMeasurement, "not-chat-page")
    }

    // MARK: - 17. 经真正的切换入口（ChatTabs.select(_:)）

    // 上面的操作换成真正的切换以后照样只对开始时绑定的那一页做；窗口级的（提示里的“重新加载”、窗口显示后、聚焦）
    // 跟着切换过去的那一页。切换本身会聚焦换上来的那一页（窗口是 key 窗口时）、写一行“选中”。

    /// B 选中时按新对话（上限 2：在 B 里新建），页面里的入口还在等时切换到 A（窗口是 key 窗口：切换给 A 排一次聚焦，80ms 后），
    /// 紧接着（A 的聚焦到点之前）入口返回。
    /// 点到了：给 B 的聚焦请求不算数（B 不是选中的），不取消 A 的那次，A 照常聚焦，只聚焦一次。
    /// 没点到：整页加载给 B（它自己的页面），A 不加载；A 照常聚焦。
    func testANewChatKeepsToItsTabAcrossARealSwitch() async throws {
        for inPage in [true, false] {
            let rig = makeRig(capacity: 2)
            rig.tabs.windowIsKey = { true }
            rig.newChatInPage = inPage
            rig.newChatWaits = true
            rig.tabs.newChat()
            try await waitUntil { !rig.newChatAsked.isEmpty }
            rig.tabs.select(rig.a)
            rig.releaseNewChat()
            try await pause(0.3)
            XCTAssertEqual(rig.newChatAsked.map(rig.name), ["B"], "点到=\(inPage)")
            XCTAssertEqual(rig.focused.map(rig.name), ["A"], "只聚焦切换过去的 A（点到=\(inPage)）")
            XCTAssertEqual(rig.loadedA, [], "点到=\(inPage)")
            XCTAssertEqual(rig.loadedB, inPage ? [] : [WebRuntime.homeURL], "点到=\(inPage)")
        }
    }

    /// 读媒体状态的时候切换到 A：读完显示和写日志的还是 B；下一秒读 A，和 A 自己上次的比（none），
    /// 不写成“B 的状态 → A 的状态”。切回 B 再读，和 B 上次的一样，不写。
    func testAMediaTickKeepsToItsTabAcrossARealSwitch() async throws {
        let rig = makeRig()
        rig.mediaDelay = 0.15
        rig.tabs.mediaTick()
        try await waitUntil { !rig.mediaRead.isEmpty }
        rig.tabs.select(rig.a)
        try await waitUntil { rig.lines.contains { $0.hasPrefix("[media]") } }
        XCTAssertEqual(rig.diagnostics.webMediaState, "媒体B")

        rig.mediaDelay = 0
        rig.tabs.mediaTick()
        try await waitUntil { rig.mediaRead.count == 2 }
        try await pause(0.1)
        XCTAssertEqual(rig.diagnostics.webMediaState, "媒体A")
        rig.tabs.select(rig.b)
        rig.tabs.mediaTick()
        try await waitUntil { rig.mediaRead.count == 3 }
        try await pause(0.1)
        XCTAssertEqual(rig.mediaRead.map(rig.name), ["B", "A", "B"])
        XCTAssertEqual(rig.lines.filter { $0.hasPrefix("[media]") }, [
            "[media] WebKit 媒体状态 none → 媒体B（窗口可见=false）",
            "[media] WebKit 媒体状态 none → 媒体A（窗口可见=false）",
        ])
    }

    /// 采集证据和媒体实验的第一步里切换到另一页：剩下的步骤还是开始时那一页的。
    func testEvidenceAndExperimentsKeepToTheirTabAcrossARealSwitch() async {
        let rig = makeRig()
        let steps = EvidenceSteps()
        rig.tabs.evidenceTarget = { [weak rig] tab in EvidenceSpy(name: rig?.name(tab.adapter) ?? "?", steps: steps) }
        steps.onFirstStep = { [weak rig] in rig.map { $0.tabs.select($0.a) } }
        await rig.tabs.collectEvidence(measure: true)
        XCTAssertEqual(steps.list, ["B probe", "B readAloudEvidence", "B measureMedia"])
        XCTAssertTrue(rig.tabs.selected === rig.a)

        steps.list = []
        steps.onFirstStep = { [weak rig] in rig.map { $0.tabs.select($0.b) } }
        await rig.tabs.runExperiment(.suspendAll)
        XCTAssertEqual(steps.list, ["A suspend true", "A webMediaState"])
        XCTAssertTrue(rig.tabs.selected === rig.b)
    }

    /// 切换到 A 以后，窗口级的事都给 A：提示里的“重新加载”、窗口显示后的提前重试和聚焦。B 不再收到。
    func testTheWindowsReloadAndShowFollowARealSwitch() async throws {
        let rig = makeRig()
        rig.b.runtime.load(chat)
        rig.fail(rig.b.runtime)
        rig.a.runtime.load(other)
        rig.fail(rig.a.runtime, other)
        rig.tabs.select(rig.a)
        XCTAssertEqual(rig.controller.shownLoadProblem, .waiting, "A 的提示投上来")

        rig.controller.onDidShow?(.wake)
        XCTAssertEqual(rig.loadedA, [other, other], "A 提前重试")
        XCTAssertEqual(rig.loadedB, [chat])
        rig.noticeCover.rootView.model.onReload()
        XCTAssertEqual(rig.loadedA, [other, other, other])
        XCTAssertEqual(rig.loadedB, [chat])
        try await waitUntil { !rig.focused.isEmpty }
        try await pause(0.2)
        XCTAssertEqual(rig.focused.map(rig.name), ["A"])
    }

    /// 切换到 A 以后，换下去的 B（它的网页视图藏在窗口里）的提交、加载完成、失败、提示、颜色都只改 B 自己的状态：
    /// 窗口（遮挡、提示、颜色、淡出）、A、聚焦、隐藏、记下地址都不变。A 加载完成照常聚焦 A。
    func testTheOutgoingTabsEventsAfterARealSwitchLeaveTheShownTabAlone() async throws {
        let rig = makeRig()
        rig.tabs.windowIsKey = { true }
        rig.controller.beginNewTabCover(for: rig.a.page)
        rig.tabs.select(rig.a)
        XCTAssertEqual(rig.controller.shownCoverKind, .newTab)
        try await waitUntil { !rig.focused.isEmpty }
        try await pause(0.2)
        let window = rig.window, a = Fields(rig.a.page)
        let calls = "隐藏=\(rig.hidden) 聚焦=\(rig.focused.map(rig.name)) 记下=\(rig.saved)"
        // 窗口和切换写的类别（B 的运行时自己写的加载、失败、页面变化的行不算）。
        let windowLines = { rig.lines.filter { line in ["[launch]", "[appearance]", "[window]", "[tabs]"].contains { line.hasPrefix($0) } } }
        let lines = windowLines()

        rig.b.runtime.load(chat)
        rig.fail(rig.b.runtime)
        rig.b.runtime.reload()
        rig.commit(rig.b.runtime)
        rig.b.runtime.webView.underPageBackgroundColor = TwoTabs.white
        rig.finish(rig.b.runtime)
        rig.b.runtime.onURLChange?(chat)
        rig.b.runtime.onEscapeRequest?()
        try await pause(0.3)
        XCTAssertTrue(rig.b.page.hasFinishedFirstLoad, "B 自己的状态照常改")
        XCTAssertEqual(rig.window, window, "窗口不变")
        XCTAssertEqual(Fields(rig.a.page), a, "A 不变")
        XCTAssertEqual("隐藏=\(rig.hidden) 聚焦=\(rig.focused.map(rig.name)) 记下=\(rig.saved)", calls)
        XCTAssertEqual(windowLines(), lines, "窗口不写日志")

        rig.commit(rig.a.runtime)
        rig.finish(rig.a.runtime)
        XCTAssertNil(rig.controller.shownCoverKind, "A 自己的加载完成照常结束它的遮挡")
        try await waitUntil { rig.focused.count == 2 }
        XCTAssertEqual(rig.focused.map(rig.name), ["A", "A"])
    }
}

/// 证据采集、媒体实验的步骤记录（按发生的顺序）。第一步时调用一次 onFirstStep（测试在那里换选中的、拿掉标签页）。
@MainActor
private final class EvidenceSteps {
    var list: [String] = []
    var onFirstStep: (() -> Void)?

    func record(_ step: String) async {
        list.append(step)
        if let first = onFirstStep {
            onFirstStep = nil
            first()
        }
        // 真的让出去一下：后面的步骤在这之后才继续。
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// 一个标签页的证据采集、媒体实验替身：每一步记下“标签页 步骤”，返回带标签页名字的结果。
@MainActor
private struct EvidenceSpy: EvidenceTarget {
    let name: String
    let steps: EvidenceSteps

    func probe() async { await steps.record("\(name) probe") }
    func readAloudEvidence() async -> String {
        await steps.record("\(name) readAloudEvidence")
        return "证据 \(name)"
    }
    func measureMedia() async -> String {
        await steps.record("\(name) measureMedia")
        return "测量 \(name)"
    }
    func webMediaState() async -> String {
        await steps.record("\(name) webMediaState")
        return "媒体 \(name)"
    }
    func experimentSetRate(_ rate: Double) async -> String {
        await steps.record("\(name) setRate \(rate)")
        return "速率 \(name)"
    }
    func setAllMediaPlaybackSuspended(_ suspended: Bool) async -> String {
        await steps.record("\(name) suspend \(suspended)")
        return "ok"
    }
    func pauseAllMediaPlayback() async -> String {
        await steps.record("\(name) pauseAll")
        return "ok"
    }
}

/// 记下、放回、丢弃阅读位置的记录。
@MainActor
private final class ReadingPositionCalls {
    /// 按发生的先后：“记下 B”“放回 A”“放回 A（要网页确认）”“丢弃 B”。
    var list: [String] = []
    /// 和 list 一一对应的编号：记下的是这次发出的编号，放回、丢弃的是交过来的编号。
    var tokens: [Int] = []
    /// 发过几个编号（两个标签页共用一个数，从 1 起）。
    var issued = 0
}

/// 一个运行时发出的加载请求。
@MainActor
private final class URLList {
    var urls: [URL] = []
}

/// 一个页面的全部状态，逐项比较。
private struct Fields: Equatable, CustomStringConvertible {
    var committed = false
    var awaiting = false
    var generation = 0
    var notice: LoadRecovery.Status = .hidden
    var held = false
    var holds = false
    var colorBefore = "nil"
    var finished = false
    var finishColor = "nil"

    init(committed: Bool = false, awaiting: Bool = false, generation: Int = 0, notice: LoadRecovery.Status = .hidden,
         held: Bool = false, holds: Bool = false, colorBefore: String = "nil", finished: Bool = false, finishColor: String = "nil") {
        self.committed = committed
        self.awaiting = awaiting
        self.generation = generation
        self.notice = notice
        self.held = held
        self.holds = holds
        self.colorBefore = colorBefore
        self.finished = finished
        self.finishColor = finishColor
    }

    @MainActor init(_ p: PageLoadState) {
        self.init(committed: p.hasCommittedPage, awaiting: p.awaitingFinish, generation: p.commitGeneration, notice: p.notice,
                  held: p.noticeAwaitsLoad, holds: p.holdsPageColor, colorBefore: TwoTabs.rgb(p.colorBeforeFirstLoad),
                  finished: p.hasFinishedFirstLoad, finishColor: TwoTabs.rgb(p.colorAtLastFinish))
    }

    var description: String {
        "提交=\(committed) 等加载完成=\(awaiting) 代号=\(generation) 提示=\(notice) 留着=\(held) 启动保护=\(holds) "
            + "加载完成前的颜色=\(colorBefore) 第一次加载已完成=\(finished) 加载完成时的颜色=\(finishColor)"
    }
}

/// 两个标签页、一个窗口和接线。B 是启动时的那个（像 AppDelegate 一样建：列表、标签页、窗口、ChatTabs、wire），
/// A 之后由 ChatTabs.add 加进来（在 B 之后接线）。AppDelegate 交给 ChatTabs 的几样换成记录，和共用的日志一起按顺序记在 timeline 里。
/// 这里只弱引用 A：A 由 ChatTabs 持有，拿掉之后能释放。A 的运行时和适配器另外留着（runtimeA），用来送晚到的回调。
@MainActor
private final class TwoTabs {
    static let dark = NSColor(srgbRed: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x0E / 255.0, alpha: 1)
    static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let focusResult = "TabEventOwnershipTests"

    let settings: AppSettings
    /// 窗口、ChatTabs 和 B 的运行时写的日志。
    let diagnostics = Diagnostics()
    /// A 的运行时和适配器自己写的日志。
    let diagnosticsA = Diagnostics()
    let appearance: PageAppearance
    let b: ChatTab
    let runtimeA: WebRuntime
    let adapterA: ChatGPTAdapter
    private weak var addedA: ChatTab?
    let controller: ChatWindowController
    private(set) var tabs: ChatTabs!
    /// 共用的日志（“[类别] 内容”）和替身的调用，按发生的顺序。
    private var timeline: [String] = []
    private(set) var loadedA: [URL] = []
    private(set) var loadedB: [URL] = []
    private(set) var hidden: [String] = []
    private(set) var focused: [ChatGPTAdapter] = []
    private(set) var saved: [URL] = []
    private(set) var mediaRead: [ChatGPTAdapter] = []
    /// 读网页媒体状态的替身等多久再返回（0：马上返回）。等的时候测试可以换选中的、拿掉标签页。
    var mediaDelay: Double = 0
    /// 共用的网络状态，不看真实网络：状态由测试 deliver(online:) 送进来。B 由 ChatTabs.init 登记，A 由 add 登记。
    let network = NetworkStatus(startsMonitor: false)
    /// 页面里的新对话入口：问过哪个标签页的适配器、点到了没有（替身的返回值）、等多久再返回。
    private(set) var newChatAsked: [ChatGPTAdapter] = []
    var newChatInPage = false
    var newChatDelay: Double = 0
    /// 为 true 时页面里的新对话入口一直等着，直到测试调 releaseNewChat()（时机由测试定，不靠计时）。
    var newChatWaits = false
    private var newChatGate: CheckedContinuation<Void, Never>?
    private var watch: AnyCancellable?

    /// 放行等着的页面里的新对话入口。
    func releaseNewChat() {
        newChatGate?.resume()
        newChatGate = nil
    }

    /// capacity：列表的上限（新对话的测试用 2，见 TabEventOwnershipTests.makeRig）。
    init(defaults: UserDefaults, backoffA: [TimeInterval], capacity: Int = TabList.defaultCapacity) {
        settings = AppSettings(defaults: defaults)
        appearance = PageAppearance(defaults: defaults)
        let runtimeB = WebRuntime(diagnostics: diagnostics, settings: settings, recovery: LoadRecovery(backoff: [60]),
                                  watchesNetwork: false)
        // B 报深色、A 报白色：看得出加载完成时记的是哪个网页视图的颜色。窗口建好之前设，窗口不会看到变化。
        runtimeB.webView.underPageBackgroundColor = Self.dark
        let adapterB = ChatGPTAdapter(webView: runtimeB.webView, diagnostics: diagnostics, settings: settings)
        let list = TabList(capacity: capacity)
        b = ChatTab(id: list.selected, runtime: runtimeB, adapter: adapterB)
        controller = ChatWindowController(webView: runtimeB.webView, toolbar: EmptyView(), diagnostics: diagnostics,
                                          appearance: appearance, page: b.page)
        // 解除启动保护后等颜色变化的时限放长：它到点写的日志不在这些测试的时间线里。
        controller.pageColorSettleLimit = 60
        runtimeA = WebRuntime(diagnostics: diagnosticsA, settings: settings, recovery: LoadRecovery(backoff: backoffA),
                              watchesNetwork: false)
        runtimeA.webView.underPageBackgroundColor = Self.white
        adapterA = ChatGPTAdapter(webView: runtimeA.webView, diagnostics: diagnosticsA, settings: settings)
        runtimeB.loadRequest = { [weak self] request in self?.loadedB.append(request.url!) }
        runtimeA.loadRequest = { [weak self] request in self?.loadedA.append(request.url!) }
        tabs = ChatTabs(list: list, tab: b, windowController: controller, diagnostics: diagnostics,
                        network: network,
                        hideWindow: { [weak self] reason in
                            self?.hidden.append(reason)
                            self?.timeline.append("隐藏窗口：\(reason)")
                        },
                        focusInput: { [weak self] adapter in
                            self?.focused.append(adapter)
                            self?.timeline.append("聚焦输入框 \(self?.name(adapter) ?? "?")")
                            return Self.focusResult
                        },
                        saveLastConversation: { [weak self] url in
                            self?.saved.append(url)
                            self?.timeline.append("记下对话地址 \(url.absoluteString)")
                        },
                        mediaState: { [weak self] adapter in
                            self?.mediaRead.append(adapter)
                            let name = self?.name(adapter) ?? "?"
                            self?.timeline.append("读网页媒体状态 \(name)")
                            if let delay = self?.mediaDelay, delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
                            return "媒体\(name)"
                        },
                        openNewChat: { [weak self] adapter in
                            self?.newChatAsked.append(adapter)
                            self?.timeline.append("页面里新对话 \(self?.name(adapter) ?? "?")")
                            if let delay = self?.newChatDelay, delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
                            if self?.newChatWaits == true { await withCheckedContinuation { self?.newChatGate = $0 } }
                            return self?.newChatInPage ?? false
                        })
        watch = diagnostics.$entries.dropFirst().sink { [weak self] entries in
            guard let self, let entry = entries.last, !LiveInputLogLines.excludes(entry) else { return }
            self.timeline.append("[\(entry.category)] \(entry.message)")
        }
        tabs.wire(b)
        addedA = tabs.add(runtime: runtimeA, adapter: adapterA)
    }

    /// 加进来的 A。拿掉并释放之后不能再用。
    var a: ChatTab { addedA! }

    func name(_ adapter: ChatGPTAdapter) -> String {
        adapter === b.adapter ? "B" : adapter === adapterA ? "A" : "?"
    }

    func name(_ runtime: WebRuntime) -> String {
        runtime === b.runtime ? "B" : runtime === runtimeA ? "A" : "?"
    }

    /// 把记下、放回、丢弃阅读位置换成记录（“记下 B”“放回 A”“放回 A（要网页确认）”“丢弃 B”，和各自的编号），返回记录。
    func recordReadingPosition() -> ReadingPositionCalls {
        let calls = ReadingPositionCalls()
        tabs.holdReadingPosition = { [weak self] runtime in
            calls.issued += 1
            calls.list.append("记下 \(self?.name(runtime) ?? "?")")
            calls.tokens.append(calls.issued)
            return calls.issued
        }
        tabs.restoreReadingPosition = { [weak self] runtime, token, confirm in
            calls.list.append("放回 \(self?.name(runtime) ?? "?")" + (confirm ? "（要网页确认）" : ""))
            calls.tokens.append(token)
        }
        tabs.discardReadingPosition = { [weak self] runtime, token in
            calls.list.append("丢弃 \(self?.name(runtime) ?? "?")")
            calls.tokens.append(token)
        }
        return calls
    }

    /// 运行时记在 diagnostics 里的网络日志（“网络可用”“网络不可用”）。
    func netLog(_ diagnostics: Diagnostics) -> [String] {
        diagnostics.entries.filter { $0.category == "net" }.map(\.message)
    }

    // MARK: 运行时的导航代理，和 LoadRecoveryWebTests 一样直接调

    /// 加载 url 失败（-1009）。
    func fail(_ runtime: WebRuntime, _ url: URL = URL(string: "https://chatgpt.com/c/abc")!) {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                            userInfo: [NSURLErrorFailingURLErrorKey: url])
        runtime.webView(runtime.webView, didFailProvisionalNavigation: nil, withError: error)
    }

    func commit(_ runtime: WebRuntime) {
        runtime.webView(runtime.webView, didCommit: nil)
    }

    func finish(_ runtime: WebRuntime) {
        runtime.webView(runtime.webView, didFinish: nil)
    }

    // MARK: 看得见的

    /// 时间线，启动画面结束的毫秒数换成“…”。去掉 B 的运行时加载完成后自己异步写的 [esc]、[render]，它们不归接线管。
    var lines: [String] {
        timeline.filter { !$0.hasPrefix("[esc]") && !$0.hasPrefix("[render]") }
            .map { $0.replacingOccurrences(of: #"（\d+ms）"#, with: "（…ms）", options: .regularExpression) }
    }

    /// 提示那一层：内容视图里第一个 LoadProblemView（初始化时加的；淡出那层加在它上面，排在后面）。
    var noticeCover: NSHostingView<LoadProblemView> {
        controller.window!.contentView!.subviews.compactMap { $0 as? NSHostingView<LoadProblemView> }.first!
    }

    /// 窗口上看得见的：启动画面和它淡出那层、启动保护、提示（状态、那一层、内容、淡出那层）、颜色，和窗口认作显示着的页面。
    var window: String {
        let cover = noticeCover
        return "启动画面=\(controller.isShowingLaunchScreen) 启动画面淡出=\(Self.identity(controller.launchFadeView)) "
            + "启动保护=\(controller.isHoldingPageColor) 提示=\(controller.shownLoadProblem.map { "\($0)" } ?? "无") "
            + "提示那层藏着=\(cover.isHidden) 内容=\(cover.rootView.model.status) "
            + "提示淡出=\(Self.identity(controller.loadProblemFadeView)) 页面颜色=\(Self.rgb(appearance.background)) "
            + "顶部外观=\(controller.chromeAppearance?.name.rawValue ?? "nil") 窗口底色=\(Self.rgb(controller.window?.backgroundColor)) "
            + "显示着=\(controller.page === b.page ? "B" : "不是 B")"
    }

    struct Snapshot {
        let window: String
        let displayed: Fields
        let lines: [String]
        let calls: String
    }

    func snapshot() -> Snapshot {
        Snapshot(window: window, displayed: Fields(b.page), lines: lines,
                 calls: "隐藏=\(hidden) 聚焦=\(focused.map(name)) 记下=\(saved) 读媒体=\(mediaRead.map(name))")
    }

    static func identity(_ view: NSView?) -> String {
        view.map { "\(ObjectIdentifier($0))" } ?? "无"
    }

    /// sRGB 分量，三位小数；没有颜色时写 nil。
    static func rgb(_ color: NSColor?) -> String {
        guard let color else { return "nil" }
        guard let c = color.usingColorSpace(.sRGB) else { return color.description }
        return String(format: "(%.3f, %.3f, %.3f, a %.2f)", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }
}
