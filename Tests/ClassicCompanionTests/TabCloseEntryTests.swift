import AppKit
import Combine
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 关闭标签页的入口（ChatTabs.closeTab(_:)、closeSelectedTab()，3.7，只有接口）。标签页都按正式运行时的建法建
/// （ChatTab.make，日志带标签），窗口是真的 ChatWindowController（不显示），加载请求只记下来。核对：
/// - 只有一个标签页：不关、不释放，和现在的 ⌘W 一样隐藏窗口（同一个原因），别的什么都不做；
/// - 关不选中的：写一行、收尾，选中项和窗口不变；
/// - 关选中的：下一个按 TabList 的规则（右边的邻居，没有就左边）；先切换（选中项先改、窗口换上邻居、聚焦和记下的对话地址
///   跟着邻居），这时列表还没改、它还没关闭、它的网页视图藏在窗口里；再收尾（列表和 tabs 一起改、网页视图从窗口拿出来）；
/// - 关两遍、关不在这组里的：什么都不做；
/// - 启动画面、新标签页的遮挡还盖着时关它：窗口照邻居自己的状态显示，不留下关掉的那一页的遮挡、淡出和颜色等待，
///   它的时限、上限到点也不再动窗口；
/// - 切模式、补排版进行中关显示着的那一页：它记下的阅读位置作废、不碰它的网页，它的补排版作废、迟到的排版完成不做事；
/// - 关掉的那一页的定时重试、网络变化、晚到的导航事件都不再起作用。
/// 进行中的操作（新对话、媒体状态、聚焦、证据采集）和释放的时间见 TabCloseAsyncTests；真的 WebKit 回调见 WebKitAfterCloseTests。
@MainActor
final class TabCloseEntryTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!
    private let other = URL(string: "https://chatgpt.com/c/def")!

    private func make() -> TabCloseRig {
        let name = "TabCloseEntryTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabCloseRig(defaults: UserDefaults(suiteName: name)!)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        return rig
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// 关闭、切换、收尾的那几行（[tabs]、[web]、[reading]），别的窗口行不看。
    private func closingLines(_ rig: TabCloseRig, since mark: Int) -> [String] {
        rig.lines(since: mark).filter { line in ["[tabs]", "[web]", "[reading]"].contains { line.hasPrefix($0) } }
    }

    // MARK: - 只有一个标签页

    /// 只有一个标签页：closeTab 和 closeSelectedTab 都只隐藏窗口，原因是“⌘W”（窗口写的就是现在 ⌘W 的那一行），
    /// 不写别的日志，不关、不释放：运行时、适配器、页面状态都没关，列表、网络登记、窗口、页面状态都不变，
    /// 阅读位置一次都不碰，网页视图还在窗口里，之后照常加载。
    func testClosingTheOnlyTabHidesTheWindowLikeCommandWAndKeepsThePage() throws {
        let rig = make()
        let a = rig.first
        a.runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        let window = rig.windowState(), page = rig.pageState(a.page), list = rig.tabs.list
        let mark = rig.mark()

        rig.tabs.closeTab(a)
        rig.tabs.closeSelectedTab()
        XCTAssertEqual(rig.lines(since: mark), ["隐藏窗口：⌘W", "隐藏窗口：⌘W"])
        XCTAssertTrue(rig.tabs.holds(a))
        XCTAssertTrue(rig.tabs.selected === a)
        XCTAssertEqual(rig.tabs.list, list)
        XCTAssertFalse(a.runtime.isClosed)
        XCTAssertFalse(a.adapter.isClosed)
        XCTAssertFalse(a.page.isClosed)
        XCTAssertEqual(rig.network.registeredCount, 1)
        XCTAssertTrue(rig.controller.webView === a.runtime.webView)
        XCTAssertNotNil(a.runtime.webView.superview)
        XCTAssertEqual(rig.windowState(), window)
        XCTAssertEqual(rig.pageState(a.page), page)
        XCTAssertEqual(calls.list, [])
        XCTAssertEqual(rig.saved, [chat])
        a.runtime.load(other)
        XCTAssertEqual(rig.loads["1"], [other], "页面留着，照常加载")
    }

    /// 隐藏的原因和现在 ⌘W 交给窗口的是同一个：窗口的按键监视写的是 hide(reason: "⌘W")，所以正式运行时
    /// （hideWindow 就是 windowController.hide(reason:)）只有一个标签页时的 closeTab 和现在按 ⌘W 写的是同一行“[window] 隐藏：⌘W”。
    func testTheHideReasonIsTheOneCommandWUsesToday() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let window = try String(contentsOf: root.appendingPathComponent("Sources/ClassicCompanion/Window/ChatWindowController.swift"),
                                encoding: .utf8)
        XCTAssertTrue(window.contains("self.hide(reason: \"⌘W\")"), "⌘W 的按键监视")
        let app = try String(contentsOf: root.appendingPathComponent("Sources/ClassicCompanion/App/AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("hideWindow: { [weak self] reason in self?.windowController.hide(reason: reason) }"))
        let rig = make()
        rig.tabs.closeSelectedTab()
        XCTAssertEqual(rig.hidden, ["⌘W"])
    }

    // MARK: - 关不选中的

    /// 1、2、3，选中 3（2 显示过、藏在窗口里）。关 2：一行“关闭（剩 2 个）”带 2 的标签，然后 2 的运行时写关闭那一行；
    /// 选中项、窗口、聚焦、记下的地址都不变；2 的运行时、适配器、页面状态关闭，网页视图从窗口里拿出来，网络上只剩两个。
    func testClosingABackgroundTabKeepsTheSelectionAndTheWindow() throws {
        let rig = make()
        let b = rig.add(), c = rig.add()
        rig.tabs.select(b)
        rig.tabs.select(c)
        XCTAssertNotNil(b.runtime.webView.superview, "显示过的藏在窗口里")
        let window = rig.windowState(), calls = "聚焦=\(rig.focused) 记下=\(rig.saved) 隐藏=\(rig.hidden)"
        let mark = rig.mark()

        rig.tabs.closeTab(b)
        XCTAssertEqual(rig.lines(since: mark), ["[tabs] 关闭（剩 2 个） 【标签2】", "[web] 关闭网页：停止加载 【标签2】"])
        XCTAssertEqual(rig.tabs.list.tabs.map(\.rawValue), [1, 3])
        XCTAssertEqual(rig.tabs.tabs.map(\.id), rig.tabs.list.tabs)
        XCTAssertTrue(rig.tabs.selected === c)
        XCTAssertEqual(rig.windowState(), window)
        XCTAssertEqual("聚焦=\(rig.focused) 记下=\(rig.saved) 隐藏=\(rig.hidden)", calls)
        XCTAssertTrue(b.runtime.isClosed)
        XCTAssertTrue(b.adapter.isClosed)
        XCTAssertTrue(b.page.isClosed)
        XCTAssertNil(b.runtime.webView.superview)
        XCTAssertEqual(rig.network.registeredCount, 2)
        XCTAssertTrue(rig.tabs.list.recentlyClosed.isEmpty, "不记最近关闭（3.8）")
    }

    // MARK: - 关选中的

    /// 三个标签页，分别选中第 1、2、3 个再关它（closeSelectedTab）：下一个是右边的邻居，最右的那个关掉时是左边的
    /// （TabList 的规则）。日志：关闭（剩 2 个）→ 选中邻居 → 关掉的那一页的运行时写关闭那一行。窗口显示邻居的页面和网页视图，
    /// 关掉的网页视图不在窗口里。再关到只剩一个：最后一次只隐藏窗口。
    func testClosingTheSelectedTabSelectsItsNeighbourByTheListsRule() throws {
        for (chosen, expected) in [(1, 2), (2, 3), (3, 2)] {
            let rig = make()
            let all = [rig.first, rig.add(), rig.add()]
            let closing = all[chosen - 1]
            rig.tabs.select(closing)
            let mark = rig.mark()
            rig.tabs.closeSelectedTab()
            let next = rig.tabs.selected
            XCTAssertEqual(next.id.rawValue, expected, "关第 \(chosen) 个")
            XCTAssertEqual(rig.lines(since: mark), ["[tabs] 关闭（剩 2 个） 【标签\(chosen)】", "[tabs] 选中 【标签\(expected)】",
                                                   "[web] 关闭网页：停止加载 【标签\(chosen)】"], "关第 \(chosen) 个")
            XCTAssertTrue(rig.controller.page === next.page)
            XCTAssertTrue(rig.controller.webView === next.runtime.webView)
            XCTAssertFalse(next.runtime.webView.isHidden)
            XCTAssertNil(closing.runtime.webView.superview)
            XCTAssertTrue(closing.runtime.isClosed && closing.adapter.isClosed && closing.page.isClosed)
            XCTAssertEqual(rig.tabs.tabs.map(\.id), rig.tabs.list.tabs)
            XCTAssertEqual(rig.tabs.list.tabs.count, 2)

            rig.tabs.closeSelectedTab()
            XCTAssertEqual(rig.tabs.list.tabs.count, 1)
            let last = rig.mark()
            rig.tabs.closeSelectedTab()
            XCTAssertEqual(rig.lines(since: last), ["隐藏窗口：⌘W"], "只剩一个")
            XCTAssertEqual(rig.tabs.list.tabs.count, 1)
        }
    }

    /// 顺序：1、2、3，选中 3 再选中 2，窗口变大（3 藏着、还是离开时的大小），关 2 → 换上 3 要补排版。
    /// 补排版前记下 3 的阅读位置时（窗口在换上 3 的途中）、记下 3 的对话地址时（切换的最后一步）看一眼：
    /// 选中项已经是 3，列表还是 1、2、3（tabs 一样），2 还没关闭，它的网页视图还在窗口里——前一刻显示着、后一刻藏起。
    /// 关完以后：列表和 tabs 一起只剩 1、3，2 关闭了，网页视图不在窗口里。选中项从没指向不在 tabs 里的标签页。
    func testTheNeighbourIsSelectedBeforeTheListChangesAndTheClosedWebViewLeavesTheWindowLast() throws {
        let rig = make()
        let calls = rig.recordReadingPosition()
        let b = rig.add(), c = rig.add()
        rig.tabs.select(c)
        c.runtime.onURLChange?(other)
        rig.tabs.select(b)
        rig.grow()
        var seen: [String] = []
        rig.onStub = { [weak rig] what in
            guard let rig else { return }
            let web = b.runtime.webView
            seen.append("\(what)：选中=\(rig.tabs.list.selected.rawValue) 列表=\(rig.tabs.list.tabs.map(\.rawValue)) "
                        + "tabs=\(rig.tabs.tabs.map(\.id.rawValue)) 2关闭=\(b.runtime.isClosed) "
                        + "2的网页在窗口里=\(web.superview != nil) 藏着=\(web.isHidden)")
        }
        rig.tabs.closeTab(b)
        rig.onStub = nil
        XCTAssertEqual(seen, [
            "记下 3：选中=3 列表=[1, 2, 3] tabs=[1, 2, 3] 2关闭=false 2的网页在窗口里=true 藏着=false",
            "记下对话地址：选中=3 列表=[1, 2, 3] tabs=[1, 2, 3] 2关闭=false 2的网页在窗口里=true 藏着=true",
        ])
        XCTAssertEqual(rig.tabs.list.tabs.map(\.rawValue), [1, 3])
        XCTAssertEqual(rig.tabs.tabs.map(\.id), rig.tabs.list.tabs)
        XCTAssertTrue(b.runtime.isClosed)
        XCTAssertNil(b.runtime.webView.superview)
        XCTAssertTrue(rig.controller.isCatchingUp, "3 在补排版")
        try XCTUnwrap(rig.prepares.last)()
        XCTAssertEqual(calls.list.last, "放回 3（显示着）", "3 排好时放回它自己的")
    }

    // MARK: - 跟着邻居的：记下的对话地址、聚焦

    /// 记下的对话地址由切换（select）跟着邻居：邻居在可以恢复的对话上就记它的；邻居在新对话页（不能恢复）就不改，
    /// 留着的还是关掉的那一页的对话（select 现在的规则，这里不另外做）。
    func testTheLastConversationFollowsTheNewlySelectedTab() throws {
        let rig = make()
        rig.first.runtime.onURLChange?(chat)
        let b = rig.add()
        rig.tabs.select(b)
        b.runtime.onURLChange?(other)
        XCTAssertEqual(rig.saved, [chat, other])
        rig.tabs.closeTab(b)
        XCTAssertEqual(rig.saved, [chat, other, chat], "邻居在对话上：记它的")

        let fresh = make()
        fresh.first.runtime.onURLChange?(WebRuntime.homeURL)
        let d = fresh.add()
        fresh.tabs.select(d)
        d.runtime.onURLChange?(other)
        XCTAssertEqual(fresh.saved, [other])
        fresh.tabs.closeTab(d)
        XCTAssertEqual(fresh.saved, [other], "邻居在新对话页：不改，留着的还是关掉的那一页的对话")
    }

    /// 窗口是 key 窗口：关掉的那一页排着的聚焦作废（取消），只聚焦邻居（切换排下的那次）。不是 key 窗口：谁都不聚焦。
    func testFocusFollowsTheNewlySelectedTab() async throws {
        for key in [true, false] {
            let rig = make()
            rig.tabs.windowIsKey = { key }
            let b = rig.add()
            rig.tabs.select(b)
            let pending = b.focusTask
            rig.tabs.closeTab(b)
            XCTAssertNil(b.focusTask)
            XCTAssertEqual(pending?.isCancelled ?? true, true)
            try await pause(0.3)
            XCTAssertEqual(rig.focused, key ? ["1"] : [], "key=\(key)")
        }
    }

    // MARK: - 关两遍、关不在这组里的

    /// 关两遍：第二遍什么都不做（不写日志、不隐藏窗口、列表不变）。关一个不在这组里的：什么都不做，它的运行时也不关；
    /// 只有一个标签页时也不隐藏窗口（先看在不在这组里）。
    func testClosingTwiceOrAStrangerDoesNothing() throws {
        let rig = make()
        let b = rig.add()
        rig.tabs.closeTab(b)
        let list = rig.tabs.list, mark = rig.mark()
        rig.tabs.closeTab(b)
        let stranger = ChatTab.make(id: TabList().selected, diagnostics: Diagnostics(), settings: rig.settings)
        rig.tabs.closeTab(stranger)
        XCTAssertEqual(rig.lines(since: mark), [])
        XCTAssertEqual(rig.hidden, [])
        XCTAssertEqual(rig.tabs.list, list)
        XCTAssertEqual(rig.tabs.tabs.count, 1)
        XCTAssertFalse(stranger.runtime.isClosed)
        XCTAssertFalse(stranger.adapter.isClosed)
        XCTAssertFalse(stranger.page.isClosed)
    }

    // MARK: - 遮挡还盖着时关

    /// 只有启动时的那一个、启动画面还盖着：和现在的 ⌘W 一样只隐藏窗口，启动画面和页面都留着（之后照常由加载结束）。
    func testClosingTheOnlyTabUnderTheLaunchScreenOnlyHides() throws {
        let rig = make()
        rig.controller.beginLaunchScreen()
        let window = rig.windowState(), mark = rig.mark()
        rig.tabs.closeTab(rig.first)
        XCTAssertEqual(rig.lines(since: mark), ["隐藏窗口：⌘W"])
        XCTAssertEqual(rig.windowState(), window)
        XCTAssertTrue(rig.controller.isShowingLaunchScreen)
        XCTAssertTrue(rig.tabs.isLaunchScreenUp)
        XCTAssertFalse(rig.first.page.isClosed)
    }

    /// 启动画面还盖着时关启动的那一页（另一个标签页由 add 加进来：应用里启动画面还在时不能新增，这是测试才有的情况）：
    /// 窗口换上邻居，照邻居自己的状态显示——没有遮挡、没有淡出那层、没有启动保护；启动画面不算还在，可以新增了。
    /// 之后启动画面的时限和上限到点都不再动窗口、不写日志（关掉的页面的遮挡停在关闭时，只是它自己的状态）。
    func testClosingTheLaunchTabUnderTheLaunchScreenShowsTheNeighboursOwnState() async throws {
        let rig = make()
        rig.controller.launchScreenLimit = 0.1
        rig.controller.launchScreenCap = 0.2
        rig.controller.pageRevealLimit = 0.1
        rig.controller.beginLaunchScreen()
        let b = rig.add()
        XCTAssertTrue(rig.tabs.isLaunchScreenUp)
        let mark = rig.mark()
        rig.tabs.closeTab(rig.first)
        XCTAssertTrue(rig.tabs.selected === b)
        XCTAssertFalse(rig.controller.isShowingLaunchScreen)
        XCTAssertNil(rig.controller.shownCoverKind)
        XCTAssertNil(rig.controller.launchFadeView)
        XCTAssertFalse(rig.controller.isHoldingPageColor)
        XCTAssertFalse(rig.tabs.isLaunchScreenUp)
        XCTAssertTrue(rig.first.page.isClosed)
        XCTAssertTrue(rig.first.page.isCovered, "关掉的页面的遮挡停在关闭时")
        let window = rig.windowState(), lines = rig.lines(since: mark)
        XCTAssertEqual(lines, ["[tabs] 关闭（剩 1 个） 【标签1】", "[tabs] 选中 【标签2】", "[web] 关闭网页：停止加载 【标签1】"])
        try await pause(0.4)
        XCTAssertEqual(rig.windowState(), window, "时限、上限到点不动窗口")
        XCTAssertEqual(rig.lines(since: mark), lines, "也不写日志")
        XCTAssertNotNil(rig.tabs.newTab(), "启动画面不算还在")
    }

    /// 新标签页的遮挡还盖着时关它：窗口换上邻居（没有遮挡），它的时限、上限到点不动窗口、不写日志。
    /// 反过来，邻居自己还盖着新标签页的遮挡：关掉显示着的那一页后窗口投的是邻居的遮挡（和它的启动保护）。
    func testClosingANewTabUnderItsCoverShowsTheNeighboursOwnState() async throws {
        let rig = make()
        rig.controller.launchScreenLimit = 0.1
        rig.controller.launchScreenCap = 0.2
        rig.controller.pageRevealLimit = 0.1
        let b = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertEqual(rig.controller.shownCoverKind, .newTab)
        let mark = rig.mark()
        rig.tabs.closeTab(b)
        XCTAssertTrue(rig.controller.page === rig.first.page)
        XCTAssertNil(rig.controller.shownCoverKind)
        XCTAssertFalse(rig.controller.isHoldingPageColor)
        let window = rig.windowState()
        try await pause(0.4)
        XCTAssertEqual(rig.windowState(), window)
        XCTAssertEqual(rig.lines(since: mark), ["[tabs] 关闭（剩 1 个） 【标签2】", "[tabs] 选中 【标签1】",
                                               "[web] 关闭网页：停止加载 【标签2】"])

        let second = make()
        let covered = try XCTUnwrap(second.tabs.newTab())
        second.tabs.select(second.first)
        XCTAssertNil(second.controller.shownCoverKind)
        second.tabs.closeTab(second.first)
        XCTAssertTrue(second.tabs.selected === covered)
        XCTAssertEqual(second.controller.shownCoverKind, .newTab, "邻居自己的遮挡")
        XCTAssertTrue(second.controller.isHoldingPageColor)
    }

    /// 关掉的那一页的遮挡刚结束、还在淡出：淡出那层马上拿掉，不留在邻居上面。
    func testAFadingCoverOfTheClosedTabIsRemoved() throws {
        let rig = make()
        let b = try XCTUnwrap(rig.tabs.newTab())
        b.runtime.webView(b.runtime.webView, didCommit: nil)
        b.runtime.webView(b.runtime.webView, didFinish: nil)
        XCTAssertNotNil(rig.controller.launchFadeView)
        rig.tabs.closeTab(b)
        XCTAssertNil(rig.controller.launchFadeView)
        XCTAssertFalse(rig.controller.isShowingLaunchScreen)
    }

    /// 关掉的那一页第一次加载完成、窗口还在等它的颜色稳定（解除启动保护后的等待）时关它：之后等待到点不再采用颜色、不写日志，
    /// 窗口的颜色停在切换到邻居时的样子。
    func testAColourWaitOfTheClosedTabChangesNothing() async throws {
        let rig = make()
        rig.controller.pageColorSettleLimit = 0.2
        let b = try XCTUnwrap(rig.tabs.newTab())
        b.runtime.webView(b.runtime.webView, didCommit: nil)
        b.runtime.webView(b.runtime.webView, didFinish: nil)
        rig.tabs.closeTab(b)
        let window = rig.windowState(), mark = rig.mark()
        try await pause(0.5)
        XCTAssertEqual(rig.lines(since: mark), [])
        XCTAssertEqual(rig.windowState(), window)
    }

    // MARK: - 阅读位置、补排版

    /// 2 显示着、正在切模式（排版前记下了 2 的阅读位置）时关 2：切换到 1 时结束切模式，2 那次记下的作废——不放回、不丢弃
    /// （都不碰 2 的网页）、不留到“再显示”、不写 [reading]。2 上留着等再显示的那一次（另一个标签页 3）关闭时也作废，不碰网页。
    func testClosingTheSelectedTabDuringAModeSwitchDropsItsReadingPositionWithoutTouchingIt() throws {
        let rig = make()
        let calls = rig.recordReadingPosition()
        let b = rig.add()
        rig.tabs.select(b)
        b.runtime.onURLChange?(chat)
        rig.controller.beginLayoutChangeForTesting(to: rig.biggerFrame())
        try XCTUnwrap(rig.snapshots.first)(NSImage(size: NSSize(width: 10, height: 10)))
        XCTAssertEqual(calls.list, ["记下 2（显示着）"])
        let mark = rig.mark()

        rig.tabs.closeTab(b)
        XCTAssertFalse(rig.controller.isChangingLayout)
        XCTAssertEqual(closingLines(rig, since: mark), ["[tabs] 关闭（剩 1 个） 【标签2】", "[tabs] 选中 【标签1】",
                                                        "[web] 关闭网页：停止加载 【标签2】"])
        XCTAssertFalse(calls.list.contains { $0.hasPrefix("放回 2") || $0.hasPrefix("丢弃 2") }, "\(calls.list)")
        XCTAssertNil(b.pendingReadingRestore)

        // 留着等再显示的那一次。
        let c = rig.add()
        rig.tabs.select(c)
        c.runtime.onURLChange?(other)
        rig.controller.beginLayoutChangeForTesting(to: rig.controller.window!.frame.insetBy(dx: -20, dy: -20))
        try XCTUnwrap(rig.snapshots.last)(NSImage(size: NSSize(width: 10, height: 10)))
        rig.tabs.select(rig.first)
        XCTAssertNotNil(c.pendingReadingRestore)
        let before = calls.list, pending = rig.mark()
        rig.tabs.closeTab(c)
        XCTAssertEqual(calls.list, before, "不碰 3 的网页")
        XCTAssertNil(c.pendingReadingRestore)
        XCTAssertEqual(closingLines(rig, since: pending), ["[tabs] 关闭（剩 1 个） 【标签3】", "[web] 关闭网页：停止加载 【标签3】"])
    }

    /// 2 换上来时要补排版（窗口在它藏着时变大了），补排版还没结束时关 2：补排版作废（写“换了显示的页面”），2 的 laidOut 不调用
    /// （留着的阅读位置不放回），1 照它离开时的大小不用补排版；2 迟到的排版完成什么都不做。
    func testClosingTheSelectedTabWhileItCatchesUpDropsItsCatchUp() throws {
        let rig = make()
        let calls = rig.recordReadingPosition()
        let b = rig.add()
        rig.tabs.select(b)
        rig.tabs.select(rig.first)
        rig.grow()
        rig.tabs.select(b)
        XCTAssertTrue(rig.controller.isCatchingUp)
        XCTAssertEqual(calls.list.count, 1)
        let late = try XCTUnwrap(rig.prepares.last)
        let mark = rig.mark()

        rig.tabs.closeTab(b)
        XCTAssertFalse(rig.controller.isCatchingUp)
        XCTAssertEqual(rig.lines(since: mark), ["[tabs] 关闭（剩 1 个） 【标签2】", "[tabs] 选中 【标签1】",
                                               "[window] 补排版结束：换了显示的页面（…ms）", "[web] 关闭网页：停止加载 【标签2】"])
        XCTAssertNil(b.pendingReadingRestore)
        late()
        XCTAssertEqual(rig.lines(since: mark).count, 4, "迟到的排版完成不做事")
        XCTAssertEqual(calls.list.count, 1, "不放回 2 的")
        XCTAssertTrue(rig.controller.page === rig.first.page)
    }

    // MARK: - 关掉以后的计时、通知、事件

    /// 显示着的 2 第一次加载失败、0.1 秒后自动重试时关它：重试不加载；之后断网又恢复不送给它（1 照常收到）；
    /// 晚到的提交、加载完成、失败都不写日志、不动窗口和 1。
    func testTheClosedTabsRetryNetworkAndLateEventsDoNothing() async throws {
        let rig = make()
        let b = rig.add(backoff: [0.1, 0.1])
        rig.network.deliver(online: true)
        rig.tabs.select(b)
        b.runtime.load(chat)
        rig.fail(b.runtime)
        XCTAssertTrue(b.runtime.hasScheduledRetry)
        rig.tabs.closeTab(b)
        let mark = rig.mark()
        rig.network.deliver(online: false)
        rig.network.deliver(online: true)
        let window = rig.windowState(), first = rig.pageState(rig.first.page)
        b.runtime.webView(b.runtime.webView, didCommit: nil)
        b.runtime.webView(b.runtime.webView, didFinish: nil)
        rig.fail(b.runtime)
        try await pause(0.4)
        XCTAssertEqual(rig.loads["2"], [chat], "关闭以后不再加载")
        XCTAssertFalse(rig.lines(since: mark).contains { $0.contains("【标签2】") }, "\(rig.lines(since: mark))")
        XCTAssertEqual(rig.windowState(), window)
        XCTAssertEqual(rig.pageState(rig.first.page), first)
    }
}

/// 关闭标签页的测试用的一组（TabCloseEntryTests、TabCloseAsyncTests 共用）：启动时的标签页（标签 1）、窗口、ChatTabs，
/// 像 AppDelegate 那样建；之后的标签页（add、newTab）也用正式的建法（ChatTab.make，日志带标签），加载请求只记下来、不发出去。
/// AppDelegate 交进来的几样换成记录：只记标签页的序号，不持有适配器。可以让它们等一会儿再返回（delays），
/// 也可以改成像 AppDelegate 那样调用真的适配器（realAdapter）。共用的日志和替身的调用按发生的先后记在时间线里。
/// 这里只持有启动时的那一个；之后加的只经 ChatTabs 持有，测试自己拿着要用的。
@MainActor
final class TabCloseRig {
    let settings: AppSettings
    let diagnostics = Diagnostics()
    let appearance: PageAppearance
    let first: ChatTab
    let controller: ChatWindowController
    let network = NetworkStatus(startsMonitor: false)
    private(set) var tabs: ChatTabs!
    private var timeline: [String] = []
    /// 适配器、运行时、页面状态 → 标签页的序号（关掉以后也认得出）。
    private var names: [ObjectIdentifier: String] = [:]
    private(set) var loads: [String: [URL]] = [:]
    private(set) var focused: [String] = []
    private(set) var saved: [URL] = []
    private(set) var hidden: [String] = []
    private(set) var mediaRead: [String] = []
    private(set) var newChatAsked: [String] = []
    /// 替身等多久再返回（秒）："focus"、"media"、"newChat"。
    var delays: [String: Double] = [:]
    var newChatInPage = true
    /// 新对话、聚焦、媒体状态改成调用真的适配器（和 AppDelegate 一样）。
    var realAdapter = false
    /// 记下对话地址、记下阅读位置的替身被调用的那一刻再调用它（测试看那一刻的样子）。
    var onStub: ((String) -> Void)?
    var snapshots: [(NSImage?) -> Void] = []
    var prepares: [() -> Void] = []
    private var watch: AnyCancellable?

    init(defaults: UserDefaults) {
        settings = AppSettings(defaults: defaults)
        appearance = PageAppearance(defaults: defaults)
        let list = TabList()
        first = ChatTab.make(id: list.selected, diagnostics: diagnostics, settings: settings)
        Self.fixColour(first)
        controller = ChatWindowController(webView: first.runtime.webView,
                                          toolbar: Color.clear.frame(height: WebBar.height).frame(maxWidth: .infinity),
                                          diagnostics: diagnostics, appearance: appearance, page: first.page)
        controller.pageColorSettleLimit = 60
        controller.layoutWaitLimit = 60
        tabs = ChatTabs(list: list, tab: first, windowController: controller, diagnostics: diagnostics, network: network,
                        hideWindow: { [weak self] reason in
                            self?.hidden.append(reason)
                            self?.timeline.append("隐藏窗口：\(reason)")
                        },
                        focusInput: { [weak self] adapter in
                            guard let self else { return "" }
                            let name = self.name(adapter)
                            self.focused.append(name)
                            self.timeline.append("聚焦 \(name)")
                            if self.realAdapter { return await adapter.focusInput() }
                            await self.wait("focus")
                            return "TabCloseRig-\(name)"
                        },
                        saveLastConversation: { [weak self] url in
                            self?.saved.append(url)
                            self?.timeline.append("记下对话地址 \(url.absoluteString)")
                            self?.onStub?("记下对话地址")
                        },
                        mediaState: { [weak self] adapter in
                            guard let self else { return "" }
                            let name = self.name(adapter)
                            self.mediaRead.append(name)
                            self.timeline.append("读媒体 \(name)")
                            if self.realAdapter { return await adapter.webMediaState() }
                            await self.wait("media")
                            return "媒体\(name)"
                        },
                        openNewChat: { [weak self] adapter in
                            guard let self else { return true }
                            let name = self.name(adapter)
                            self.newChatAsked.append(name)
                            self.timeline.append("页面里新对话 \(name)")
                            let inPage: Bool
                            if self.realAdapter {
                                inPage = await adapter.openNewChatInPage()
                            } else {
                                await self.wait("newChat")
                                inPage = self.newChatInPage
                            }
                            self.timeline.append("页面里新对话 \(name) 返回")
                            return inPage
                        },
                        makeTab: { [weak self] id in self!.build(id) },
                        revealWindow: { [weak self] in self?.timeline.append("找回窗口") })
        tabs.wire(first)
        register(first)
        tabs.windowIsVisible = { true }
        tabs.beep = { [weak self] in self?.timeline.append("提示音") }
        controller.onSnapshotPage = { [weak self] done in self?.snapshots.append(done) }
        controller.onPrepareLayout = { [weak self] _, done in self?.prepares.append(done) }
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        watch = diagnostics.$entries.dropFirst().sink { [weak self] entries in
            guard let self, let entry = entries.last, !LiveInputLogLines.excludes(entry) else { return }
            self.timeline.append("[\(entry.category)] \(entry.message)")
        }
    }

    private func wait(_ key: String) async {
        guard let delay = delays[key], delay > 0 else { return }
        try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
    }

    /// 正式的建法，加载请求只记下来。
    private func build(_ id: TabID) -> ChatTab {
        let tab = ChatTab.make(id: id, diagnostics: diagnostics, settings: settings)
        Self.fixColour(tab)
        register(tab)
        return tab
    }

    /// 网页视图建好时就设上页面底色（白色）。不设的话（实测在系统深色外观下），换上一个从没加载过的网页视图后过一会儿
    /// WebKit 报出页面底色，窗口照常采用、写一行“[appearance] 页面底色：浅色”——那是换上来的那一页自己的事，和关闭无关，
    /// 却会在“关闭以后窗口不变、不写日志”的核对里冒出来。设上以后这一行不再出现。
    private static func fixColour(_ tab: ChatTab) {
        tab.runtime.webView.underPageBackgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }

    /// 记下它的名字，让它的加载请求只记下来。
    private func register(_ tab: ChatTab) {
        let name = "\(tab.id.rawValue)"
        for object in [tab.adapter, tab.runtime, tab.page] as [AnyObject] { names[ObjectIdentifier(object)] = name }
        tab.runtime.loadRequest = { [weak self] request in
            self?.loads[name, default: []].append(request.url!)
            self?.timeline.append("加载 \(name) \(request.url!.absoluteString)")
        }
    }

    /// 加一个标签页（ChatTabs.add，不选中、不显示、不加载）。backoff 不是 nil 时运行时用这个重试间隔（别的和正式的建法一样）。
    func add(backoff: [TimeInterval]? = nil) -> ChatTab {
        tabs.add { id in
            guard let backoff else { return build(id) }
            let runtime = WebRuntime(diagnostics: diagnostics, settings: settings, recovery: LoadRecovery(backoff: backoff),
                                     watchesNetwork: false, tab: id)
            let adapter = ChatGPTAdapter(webView: runtime.webView, diagnostics: diagnostics, settings: settings, tab: id)
            let tab = ChatTab(id: id, runtime: runtime, adapter: adapter)
            Self.fixColour(tab)
            register(tab)
            return tab
        }!
    }

    func name(_ object: AnyObject) -> String {
        names[ObjectIdentifier(object)] ?? "?"
    }

    func mark() -> Int {
        timeline.count
    }

    /// mark 之后的时间线，去掉运行时加载完成后自己异步写的 [esc]、[render]，毫秒数换成“…”。
    func lines(since mark: Int) -> [String] {
        allLines(since: mark).filter { !$0.hasPrefix("[esc]") && !$0.hasPrefix("[render]") }
    }

    /// mark 之后的时间线，什么都不去掉（毫秒数换成“…”）。
    func allLines(since mark: Int) -> [String] {
        timeline.dropFirst(mark)
            .map { $0.replacingOccurrences(of: #"（\d+ms）"#, with: "（…ms）", options: .regularExpression) }
    }

    /// 记下、放回、丢弃阅读位置换成记录：“记下 1（藏着 宽×高）”“记下 1（显示着）”“放回 1（显示着）”“丢弃 1”。
    func recordReadingPosition() -> TabCloseReadingLog {
        let calls = TabCloseReadingLog()
        tabs.holdReadingPosition = { [weak self] runtime in
            calls.issued += 1
            let web = runtime.webView
            let state = web.isHidden ? "藏着 \(Int(web.frame.width))×\(Int(web.frame.height))" : "显示着"
            let name = self?.name(runtime) ?? "?"
            calls.list.append("记下 \(name)（\(state)）")
            self?.onStub?("记下 \(name)")
            return calls.issued
        }
        tabs.restoreReadingPosition = { [weak self] runtime, _, _ in
            let shown = self?.controller.webView === runtime.webView && !runtime.webView.isHidden
            calls.list.append("放回 \(self?.name(runtime) ?? "?")（\(shown ? "显示着" : "没显示")）")
        }
        tabs.discardReadingPosition = { [weak self] runtime, _ in
            calls.list.append("丢弃 \(self?.name(runtime) ?? "?")")
        }
        return calls
    }

    /// 加载失败（-1009），和 LoadRecoveryWebTests 一样直接调导航代理。
    func fail(_ runtime: WebRuntime, _ url: URL = URL(string: "https://chatgpt.com/c/abc")!) {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                            userInfo: [NSURLErrorFailingURLErrorKey: url])
        runtime.webView(runtime.webView, didFailProvisionalNavigation: nil, withError: error)
    }

    /// 让 tab 的网页视图打开本地的 html（地址是 url，不联网），等到加载完成。经过它的运行时（导航代理）和接线，和真的加载一样。
    func loadPage(_ tab: ChatTab, _ html: String, at url: URL = URL(string: "https://chatgpt.com/c/abc")!) async {
        let web = tab.runtime.webView
        web.loadHTMLString(html, baseURL: url)
        let deadline = Date().addingTimeInterval(5)
        while web.url != url || web.isLoading, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// 窗口变大（像切过模式、拖过边）。
    func grow() {
        controller.window!.setFrame(biggerFrame(), display: false)
        controller.window!.contentView!.layoutSubtreeIfNeeded()
    }

    func biggerFrame() -> NSRect {
        var frame = controller.window!.frame
        frame.size.width += 100
        frame.size.height += 60
        return frame
    }

    /// 窗口上看得见的：显示的页面和网页视图、遮挡那层和样子、淡出那层、启动保护、提示和它淡出那层、补排版、切模式、颜色。
    func windowState() -> String {
        "显示=\(name(controller.page)) 网页=\(shownWebView()) 遮挡=\(controller.isShowingLaunchScreen) "
            + "样子=\(controller.shownCoverKind.map { "\($0)" } ?? "无") 淡出=\(Self.identity(controller.launchFadeView)) "
            + "启动保护=\(controller.isHoldingPageColor) 提示=\(controller.shownLoadProblem.map { "\($0)" } ?? "无") "
            + "提示淡出=\(Self.identity(controller.loadProblemFadeView)) 补排版=\(controller.isCatchingUp) "
            + "切模式=\(controller.isChangingLayout) 页面颜色=\(appearance.background.map { "\($0)" } ?? "nil") "
            + "窗口底色=\(controller.window?.backgroundColor.description ?? "nil")"
    }

    private func shownWebView() -> String {
        tabs.tabs.first { $0.runtime.webView === controller.webView }.map { "\($0.id.rawValue)" } ?? "?"
    }

    /// 一个页面自己的状态。
    func pageState(_ p: PageLoadState) -> String {
        "提交=\(p.hasCommittedPage) 等加载完成=\(p.awaitingFinish) 代号=\(p.commitGeneration) 提示=\(p.notice) "
            + "留着=\(p.noticeAwaitsLoad) 启动保护=\(p.holdsPageColor) 第一次加载已完成=\(p.hasFinishedFirstLoad) "
            + "盖着=\(p.isCovered) 样子=\(p.coverKind) 遮挡代号=\(p.coverGeneration) 等提交=\(p.coverAwaitsCommit) 关闭=\(p.isClosed)"
    }

    static func identity(_ view: NSView?) -> String {
        view.map { "\(ObjectIdentifier($0))" } ?? "无"
    }
}

/// 记下、放回、丢弃阅读位置的记录。
@MainActor
final class TabCloseReadingLog {
    var list: [String] = []
    var issued = 0
}
