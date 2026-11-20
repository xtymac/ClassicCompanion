import AppKit
import Combine
import CompanionCore
import SwiftUI
import WebKit
import XCTest
@testable import ClassicCompanion

/// 切换标签页时窗口这一边（ChatWindowController.display(_:webView:)）：窗口改为显示另一个页面和它的网页视图，
/// 并把那个页面自己的状态投到窗口上。三个页面 p0、p1、p2（各自的网页视图 w0、w1、w2，带标签 1、2、3），开始时显示 p0。
/// 核对：
/// - 网页视图：换上来的铺满、显示、拿到键盘焦点，Esc 判断和颜色观察跟着换；换下去的留在容器里藏起，固定在离开时的大小（D3），
///   之后窗口变大小它不变；再换上来时回到铺满。已经显示着的、关闭的页面换不上来。藏着的网页视图只有 removeHiddenWebView(_:)
///   拿出来，拿出来以后就能释放。
/// - 遮挡和提示：照换上来的页面自己的状态投（两种遮挡、到时限还在等提交、结束了的；失败的提示、留到加载完成的提示），
///   计时不重新开始，不写日志。还在淡出的那层（启动画面的、提示的）马上去掉（D7）。
/// - 颜色（D4）：第一次加载完成、颜色已经稳定的马上采用；刚解除启动保护（显示着时没等完、或不显示时刚解除）的照原来的等待；
///   又在加载的照平常的 150ms；第一次加载还没完成（包括启动保护中）的不动。换走的页面迟到的颜色回调什么都不做，A → B → A 也一样。
/// - 进行中的切模式：先结束（结束的那一刻显示的还是换走的页面），之后它迟到的快照、排版和时限都不起作用，也不结束之后的那一次。
/// WebKit 报的页面颜色和 LaunchColourTests 一样直接设 underPageBackgroundColor 来模拟。这些测试不显示窗口。
/// 在屏幕上才看得出来的（换的那一下有没有闪、藏起的网页视图在屏幕上真的不画、真的键盘焦点）这里看不到。
@MainActor
final class TabDisplayTests: XCTestCase {
    private func make() -> DisplayRig {
        let name = "TabDisplayTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = DisplayRig(defaults: UserDefaults(suiteName: name)!)
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

    // MARK: - 网页视图（D3）

    /// 换上 p1：显示的页面和网页视图都是 p1 的，w1 放进容器铺满、显示，Esc 判断看 w1；w0 还在容器里，藏起，大小是离开时的。
    /// 再换上 p2：w0、w1 都藏着。窗口不写日志。
    func testDisplayMakesThePageAndItsWebViewTheShownOnes() throws {
        let rig = make()
        let place = try XCTUnwrap(rig.views[0].superview)
        rig.layout()
        let size0 = rig.views[0].frame.size
        XCTAssertFalse(size0 == .zero)

        rig.display(1)
        rig.layout()
        XCTAssertTrue(rig.controller.page === rig.pages[1])
        XCTAssertTrue(rig.controller.webView === rig.views[1])
        XCTAssertTrue(try rig.chatWindow().webView === rig.views[1], "Esc 判断看换上来的网页视图")
        XCTAssertTrue(rig.views[1].superview === place)
        XCTAssertFalse(rig.views[1].isHidden)
        XCTAssertEqual(rig.views[1].frame, place.bounds, "铺满容器")
        XCTAssertTrue(rig.views[0].superview === place, "换下去的还在容器里")
        XCTAssertTrue(rig.views[0].isHidden)
        XCTAssertEqual(rig.views[0].frame.size, size0, "大小是离开时的")

        rig.display(2)
        rig.layout()
        XCTAssertTrue(rig.controller.webView === rig.views[2])
        XCTAssertEqual(rig.views[2].frame, place.bounds)
        XCTAssertTrue(rig.views[0].isHidden)
        XCTAssertTrue(rig.views[1].isHidden)
        XCTAssertTrue(rig.views[1].superview === place)
        XCTAssertEqual(rig.lines, [], "换显示的页面本身不写日志")
    }

    /// 藏着的网页视图固定在离开时的大小：窗口变大以后显示着的跟着变，藏着的不变。换回来时回到铺满（现在的大小），
    /// 换下去的那个固定在它离开时（变大以后）的大小。
    func testAHiddenWebViewKeepsItsLeaveSizeWhileTheWindowChanges() throws {
        let rig = make()
        let window = try XCTUnwrap(rig.controller.window)
        let place = try XCTUnwrap(rig.views[0].superview)
        rig.layout()
        let size0 = rig.views[0].frame.size
        rig.display(1)
        var frame = window.frame
        frame.size.width += 120
        frame.size.height += 80
        window.setFrame(frame, display: false)
        rig.layout()
        XCTAssertEqual(rig.views[1].frame, place.bounds, "显示着的跟着窗口变")
        XCTAssertNotEqual(place.bounds.size, size0)
        XCTAssertEqual(rig.views[0].frame.size, size0, "藏着的不变")
        let size1 = rig.views[1].frame.size

        XCTAssertEqual(DisplayRig.fixedSize(rig.views[0]), size0, "藏着时固定在离开时的大小")
        rig.display(0)
        rig.layout()
        XCTAssertFalse(rig.views[0].isHidden)
        XCTAssertEqual(rig.views[0].frame, place.bounds, "换回来铺满现在的大小")
        XCTAssertNil(DisplayRig.fixedSize(rig.views[0]), "固定大小的约束拿掉了（不靠 AppKit 在冲突里丢掉一条）")
        XCTAssertTrue(rig.views[1].isHidden)
        XCTAssertEqual(rig.views[1].frame.size, size1)
        XCTAssertEqual(DisplayRig.fixedSize(rig.views[1]), size1)

        frame.size.width -= 200
        window.setFrame(frame, display: false)
        rig.layout()
        XCTAssertEqual(rig.views[0].frame, place.bounds)
        XCTAssertEqual(rig.views[1].frame.size, size1, "藏着的还是离开时的大小")
    }

    /// 窗口刚变大小就换页面：离开时的大小是变大小以后的（现在的容器大小），不是变之前的。
    /// （不显示的窗口变大小时 AppKit 当场排版，这里造不出“还没排版”的情形，所以 display 里先排版的那一步单独看不出来。）
    func testTheLeaveSizeFollowsAResizeRightBeforeTheSwitch() throws {
        let rig = make()
        let window = try XCTUnwrap(rig.controller.window)
        let place = try XCTUnwrap(rig.views[0].superview)
        rig.layout()
        let before = rig.views[0].frame.size
        var frame = window.frame
        frame.size.width += 120
        frame.size.height += 40
        window.setFrame(frame, display: false)
        rig.display(1)
        rig.layout()
        XCTAssertNotEqual(place.bounds.size, before)
        XCTAssertEqual(rig.views[0].frame.size, place.bounds.size)
    }

    /// 键盘焦点交给换上来的网页视图（焦点原来不在网页里也交）；换回来再交回去。
    func testTheShownWebViewGetsTheKeyboardFocus() throws {
        let rig = make()
        let window = try XCTUnwrap(rig.controller.window)
        window.makeFirstResponder(nil)
        rig.display(1)
        XCTAssertTrue(window.firstResponder === rig.views[1])
        rig.display(0)
        XCTAssertTrue(window.firstResponder === rig.views[0])
    }

    /// 已经显示着的页面、关闭的页面：什么都不做——不换网页视图、不投状态、排着的颜色更新照常生效。
    func testDisplayingTheShownPageOrAClosedPageDoesNothing() async throws {
        let rig = make()
        rig.controller.showLoadProblem(.waiting, for: rig.pages[2])
        rig.controller.beginNewTabCover(for: rig.pages[2])
        rig.controller.pageClosed(rig.pages[2])
        rig.views[0].underPageBackgroundColor = DisplayRig.white
        let before = rig.window

        rig.display(0)
        rig.display(2)
        XCTAssertTrue(rig.controller.page === rig.pages[0])
        XCTAssertTrue(rig.controller.webView === rig.views[0])
        XCTAssertNil(rig.views[2].superview, "关闭的页面的网页视图没放进来")
        XCTAssertEqual(rig.window, before)
        try await waitUntil { rig.appearance.background.map { PageAppearance.sameColor($0, DisplayRig.white) } ?? false }
        XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.white), "w0 排着的颜色更新没有作废")
    }

    /// 藏着的网页视图只有 removeHiddenWebView(_:) 拿出来；显示着的、从没显示过的不动。拿出来以后（页面关了、
    /// 外面不再持有）网页视图释放。
    func testAHiddenWebViewIsTakenOutOnlyWhenAskedAndThenLetGo() async throws {
        let rig = make()
        weak var released: WKWebView?
        autoreleasepool {
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let page = PageLoadState()
            released = web
            rig.controller.display(page, webView: web)
            rig.display(0)
            XCTAssertTrue(web.superview === rig.views[0].superview)
            rig.controller.removeHiddenWebView(rig.views[0])
            rig.controller.removeHiddenWebView(rig.views[1])
            XCTAssertTrue(rig.views[0].superview != nil && !rig.views[0].isHidden, "显示着的不拿")
            XCTAssertNil(rig.views[1].superview, "从没显示过的本来就不在里面")
            rig.controller.pageClosed(page)
            rig.controller.removeHiddenWebView(web)
            XCTAssertNil(web.superview)
        }
        try await waitUntil { released == nil }
        XCTAssertNil(released, "窗口不再持有它")
        rig.display(1)
        rig.layout()
        XCTAssertEqual(rig.views[1].frame, rig.views[1].superview?.bounds, "之后照常切换")
    }

    // MARK: - 遮挡、提示（D7）

    /// 每个页面自己的遮挡照它的状态投上来：p1 不显示时开始新标签页的遮挡，p2 显示着时开始启动画面又换走、到时限还在等提交。
    /// 换来换去，窗口那层照显示的页面盖不盖、哪一种样子；页面的遮挡代号和开始时刻不变（计时不重新开始）；不写日志。
    /// p1 不显示时遮挡结束：换上来不盖、也没有淡出那层。
    func testEachPagesCoverIsProjectedWithItsOwnClock() async throws {
        let rig = make()
        rig.controller.launchScreenLimit = 0.1
        rig.controller.launchScreenCap = 60
        rig.controller.beginNewTabCover(for: rig.pages[1])
        rig.display(2)
        rig.controller.beginLaunchScreen()
        rig.display(0)
        XCTAssertFalse(rig.controller.isShowingLaunchScreen)
        try await waitUntil { rig.pages[2].coverAwaitsCommit }
        XCTAssertTrue(rig.pages[2].coverAwaitsCommit, "p2 到时限还没提交，继续盖着")
        let clocks = rig.pages.map { "\($0.coverGeneration) \($0.coverStarted)" }
        let lines = rig.lines

        rig.display(1)
        XCTAssertEqual(rig.controller.shownCoverKind, .newTab)
        rig.display(2)
        XCTAssertEqual(rig.controller.shownCoverKind, .launch)
        rig.display(0)
        XCTAssertNil(rig.controller.shownCoverKind)
        rig.display(2)
        XCTAssertEqual(rig.controller.shownCoverKind, .launch)
        XCTAssertEqual(rig.pages.map { "\($0.coverGeneration) \($0.coverStarted)" }, clocks, "计时不重新开始")
        XCTAssertEqual(rig.lines, lines, "不写日志")

        rig.controller.endLaunchScreen("网页已加载", for: rig.pages[1])
        XCTAssertEqual(rig.lines.last, "[launch] 不显示的页面的遮挡结束（新标签页）：网页已加载（…ms） 【标签2】")
        rig.display(1)
        XCTAssertNil(rig.controller.shownCoverKind)
        XCTAssertNil(rig.controller.launchFadeView, "不显示时结束的遮挡换上来不淡出")
    }

    /// 每个页面自己的提示照它的状态投上来：p1 加载失败在等重试，p2 提交时说可以收起、留到加载完成（还显示着收起前的）。
    /// 换来换去，窗口的提示（状态、那一层、内容）照显示的页面；不写日志。
    func testEachPagesNoticeIsProjected() throws {
        let rig = make()
        rig.controller.showLoadProblem(.waiting, for: rig.pages[1])
        rig.controller.showLoadProblem(.connecting, for: rig.pages[2])
        rig.controller.pageDidCommit(rig.pages[2])
        rig.controller.showLoadProblem(.hidden, for: rig.pages[2])
        XCTAssertTrue(rig.pages[2].noticeAwaitsLoad)
        XCTAssertNil(rig.controller.shownLoadProblem)
        let lines = rig.lines

        rig.display(1)
        XCTAssertEqual(rig.controller.shownLoadProblem, .waiting)
        XCTAssertFalse(rig.noticeCover.isHidden)
        XCTAssertEqual(rig.noticeCover.rootView.model.status, .waiting)
        rig.display(2)
        XCTAssertEqual(rig.controller.shownLoadProblem, .connecting, "留到加载完成的照样显示")
        XCTAssertFalse(rig.noticeCover.isHidden)
        XCTAssertEqual(rig.noticeCover.rootView.model.status, .connecting)
        rig.display(0)
        XCTAssertNil(rig.controller.shownLoadProblem)
        XCTAssertTrue(rig.noticeCover.isHidden)
        XCTAssertEqual(rig.lines, lines)
    }

    /// 换走的页面还在淡出的那层（启动画面的、提示的）马上拿掉，不盖在换上来的页面上（D7）。
    func testARunningFadeIsRemovedAtOnce() throws {
        let rig = make()
        rig.controller.beginLaunchScreen()
        rig.controller.showLoadProblem(.connecting, for: rig.pages[0])
        rig.controller.pageDidCommit(rig.pages[0])
        rig.controller.showLoadProblem(.hidden, for: rig.pages[0])
        rig.controller.endLaunchScreen("网页已加载", for: rig.pages[0])
        rig.controller.pageDidFinishLoading(rig.pages[0], reportedColor: rig.views[0].underPageBackgroundColor)
        let launchFade = try XCTUnwrap(rig.controller.launchFadeView)
        let noticeFade = try XCTUnwrap(rig.controller.loadProblemFadeView)
        XCTAssertNotNil(launchFade.superview)
        XCTAssertNotNil(noticeFade.superview)

        rig.display(1)
        XCTAssertNil(launchFade.superview, "启动画面淡出那层马上拿掉")
        XCTAssertNil(noticeFade.superview, "提示淡出那层马上拿掉")
        XCTAssertNil(rig.controller.launchFadeView)
        XCTAssertNil(rig.controller.loadProblemFadeView)
        XCTAssertFalse(rig.controller.isShowingLaunchScreen)
        XCTAssertNil(rig.controller.shownLoadProblem)
    }

    // MARK: - 颜色（D4）

    /// 第一次加载完成、颜色已经稳定：换上来马上采用它此刻报的颜色（深浅变了写一行），顶部一条和窗口底色跟着变。
    func testAFinishedPageWithASettledColourIsAdoptedAtOnce() throws {
        let rig = make()
        rig.load(1, reporting: DisplayRig.white)
        rig.load(0, reporting: DisplayRig.blankDark)
        XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.savedDark))

        rig.display(1)
        XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.white), "马上采用")
        XCTAssertTrue(PageAppearance.sameColor(rig.controller.window?.backgroundColor, DisplayRig.white))
        XCTAssertEqual(rig.controller.chromeAppearance?.name, .aqua)
        XCTAssertEqual(rig.lines, ["[appearance] 页面底色：浅色"])

        rig.display(0)
        XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.blankDark))
        XCTAssertEqual(rig.controller.chromeAppearance?.name, .darkAqua)
        XCTAssertEqual(rig.lines, ["[appearance] 页面底色：浅色", "[appearance] 页面底色：深色"])
    }

    /// 第一次加载还没完成（只提交了；或者盖着新标签页的遮挡、在启动保护里）：窗口的颜色不动，之后也没有排着的采用。
    /// 启动保护中的页面换上来以后报的颜色照启动保护不采用，加载完成时照原来的等待。
    func testAPageWhoseFirstLoadHasNotFinishedLeavesTheColourAlone() async throws {
        let rig = make()
        rig.controller.pageColorSettleLimit = 0.3
        rig.views[1].underPageBackgroundColor = DisplayRig.white
        rig.views[2].underPageBackgroundColor = DisplayRig.white
        rig.controller.pageDidCommit(rig.pages[1])
        rig.controller.beginNewTabCover(for: rig.pages[2])

        rig.display(1)
        rig.display(2)
        try await pause(0.3)
        XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.savedDark), "颜色不动")
        XCTAssertEqual(rig.lines, [])

        rig.views[2].underPageBackgroundColor = DisplayRig.pageBlack
        XCTAssertEqual(rig.lines, ["[appearance] 启动保护中：页面底色报为深色，不采用"])
        rig.views[2].underPageBackgroundColor = DisplayRig.white
        rig.load(2, reporting: DisplayRig.white)
        XCTAssertEqual(rig.lines.last, "[appearance] 启动保护解除：加载完成时报的是浅色，等页面颜色变化再采用")
        try await waitUntil { rig.lines.last?.hasPrefix("[appearance] 页面底色") ?? false }
        XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.white))
        XCTAssertTrue(rig.lines.contains("[appearance] 加载完成后 300ms 页面颜色没有变，按当前颜色采用"))

        // 规则看的是启动保护本身：第一次加载完成过、又在启动保护里（又盖上了遮挡）的也不动。
        let held = make()
        held.load(1, reporting: DisplayRig.white)
        held.controller.beginNewTabCover(for: held.pages[1])
        held.display(1)
        try await pause(0.3)
        XCTAssertTrue(PageAppearance.sameColor(held.appearance.background, DisplayRig.savedDark), "启动保护中：不动")
    }

    /// 显示着解除启动保护、还在等颜色变化时换走：等待作废（到点时它不显示），等的颜色留着。换回来重新等：
    /// 颜色一直没变就等满再采用；换走期间颜色变了，换回来 150ms 后就采用。
    func testALeftoverColourWaitStartsAgainWhenThePageReturns() async throws {
        for changedMeanwhile in [false, true] {
            let rig = make()
            rig.controller.pageColorSettleLimit = 0.5
            rig.views[1].underPageBackgroundColor = DisplayRig.white
            rig.controller.beginNewTabCover(for: rig.pages[1])
            rig.display(1)
            rig.load(1, reporting: DisplayRig.white)
            XCTAssertNotNil(rig.pages[1].colorBeforeFirstLoad)
            rig.display(0)
            try await pause(0.7)
            XCTAssertFalse(rig.lines.contains { $0.hasPrefix("[appearance] 加载完成后") }, "换走以后等待作废（变了=\(changedMeanwhile)）")
            XCTAssertTrue(PageAppearance.sameColor(rig.pages[1].colorBeforeFirstLoad, DisplayRig.white), "等的颜色留着")
            XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.savedDark))
            if changedMeanwhile { rig.views[1].underPageBackgroundColor = DisplayRig.pageBlack }

            rig.display(1)
            try await pause(0.3)
            if changedMeanwhile {
                XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.pageBlack), "颜色变过：150ms 后采用")
                XCTAssertNil(rig.pages[1].colorBeforeFirstLoad)
                continue
            }
            XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.savedDark), "还是那个颜色：先不采用")
            try await waitUntil { rig.lines.contains { $0.hasPrefix("[appearance] 加载完成后") } }
            XCTAssertEqual(rig.lines.filter { $0.hasPrefix("[appearance] 加载完成后") },
                           ["[appearance] 加载完成后 500ms 页面颜色没有变，按当前颜色采用"])
            try await waitUntil { PageAppearance.sameColor(rig.appearance.background, DisplayRig.white) }
            XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.white))
        }
    }

    /// 不显示时解除启动保护：窗口没替它等过。刚解除就换上来：拿加载完成时报的颜色当“加载完成前的颜色”，等完剩下的时间。
    /// 解除了很久才换上来：当作已经稳定，马上采用。用过一次就清掉。
    func testAPageReleasedWhileHiddenWaitsOutTheRestOfTheSettleTime() async throws {
        let rig = make()
        rig.controller.pageColorSettleLimit = 1
        rig.views[1].underPageBackgroundColor = DisplayRig.white
        rig.controller.beginNewTabCover(for: rig.pages[1])
        rig.load(1, reporting: DisplayRig.white)
        XCTAssertNil(rig.pages[1].colorBeforeFirstLoad, "不显示时解除，不设等的颜色")
        XCTAssertNotNil(rig.pages[1].releasedWhileHidden)
        try await pause(0.5)

        rig.display(1)
        let shown = Date()
        XCTAssertNil(rig.pages[1].releasedWhileHidden, "用过就清掉")
        XCTAssertTrue(PageAppearance.sameColor(rig.pages[1].colorBeforeFirstLoad, DisplayRig.white))
        try await pause(0.25)
        XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.savedDark), "还在等")
        try await pause(max(0, 0.85 - Date().timeIntervalSince(shown)))
        XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.white), "只等剩下的时间（约 0.5 秒）")
        XCTAssertTrue(rig.lines.contains("[appearance] 加载完成后 1000ms 页面颜色没有变，按当前颜色采用"))

        let late = make()
        late.controller.pageColorSettleLimit = 0.2
        late.views[1].underPageBackgroundColor = DisplayRig.white
        late.controller.beginNewTabCover(for: late.pages[1])
        late.load(1, reporting: DisplayRig.white)
        try await pause(0.3)
        late.display(1)
        XCTAssertTrue(PageAppearance.sameColor(late.appearance.background, DisplayRig.white), "解除很久了：马上采用")
        XCTAssertNil(late.pages[1].colorBeforeFirstLoad)
        XCTAssertNil(late.pages[1].releasedWhileHidden)
    }

    /// 第一次加载完成过、现在又在加载（已提交、还没加载完成）：它此刻的颜色可能是导航中的临时颜色，照平常稳定 150ms 再采用。
    func testAPageThatIsLoadingAgainWaitsForItsColourToSettle() async throws {
        let rig = make()
        rig.load(1, reporting: DisplayRig.white)
        rig.controller.pageDidCommit(rig.pages[1])
        rig.display(1)
        XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.savedDark), "不马上采用")
        try await waitUntil { PageAppearance.sameColor(rig.appearance.background, DisplayRig.white) }
        XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.white), "稳定 150ms 后采用")
    }

    /// 换走的页面迟到的颜色回调什么都不做：排着的 150ms 更新作废；换走以后它的网页视图报颜色窗口不看。
    /// A → B → A（150ms 之内换回来）：p0 第一次加载还没完成，换回来颜色不动，换走前排着的那次更新也不再生效；
    /// p0 已经稳定的，换回来马上采用 p0 此刻的颜色。
    func testLateColourCallbacksOfTheOutgoingPageDoNothing() async throws {
        let rig = make()
        rig.load(0, reporting: DisplayRig.blankDark)
        rig.views[0].underPageBackgroundColor = DisplayRig.white
        rig.display(1)
        rig.views[0].underPageBackgroundColor = DisplayRig.pageBlack
        rig.views[0].underPageBackgroundColor = DisplayRig.white
        try await pause(0.3)
        XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.savedDark), "p0 排着的更新作废，之后报的不看")
        XCTAssertEqual(rig.lines, [])

        let roundTrip = make()
        roundTrip.views[0].underPageBackgroundColor = DisplayRig.white
        roundTrip.display(1)
        roundTrip.display(0)
        try await pause(0.3)
        XCTAssertTrue(PageAppearance.sameColor(roundTrip.appearance.background, DisplayRig.savedDark), "A → B → A：换走前排着的那次不生效")
        XCTAssertEqual(roundTrip.lines, [])

        let settled = make()
        settled.load(0, reporting: DisplayRig.blankDark)
        settled.views[0].underPageBackgroundColor = DisplayRig.white
        settled.display(1)
        settled.views[0].underPageBackgroundColor = DisplayRig.pageBlack
        settled.display(0)
        XCTAssertTrue(PageAppearance.sameColor(settled.appearance.background, DisplayRig.pageBlack), "换回来马上采用 p0 此刻的颜色")
        try await pause(0.3)
        XCTAssertTrue(PageAppearance.sameColor(settled.appearance.background, DisplayRig.pageBlack))
    }

    /// A → B → A 时 A 解除启动保护后的等待：换走时作废，换回来重新等。原来那次到点时不起作用（不提前采用、不写两遍）。
    func testASettleWaitFromBeforeTheRoundTripStaysDead() async throws {
        let rig = make()
        rig.controller.pageColorSettleLimit = 0.6
        rig.views[0].underPageBackgroundColor = DisplayRig.white
        rig.controller.beginLaunchScreen()
        rig.load(0, reporting: DisplayRig.white)
        let released = Date()
        rig.display(1)
        try await pause(0.3)
        rig.display(0)
        try await pause(max(0, 0.75 - Date().timeIntervalSince(released)))
        XCTAssertFalse(rig.lines.contains { $0.hasPrefix("[appearance] 加载完成后") }, "原来那次到点不起作用")
        XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.savedDark))
        try await waitUntil { rig.lines.contains { $0.hasPrefix("[appearance] 加载完成后") } }
        try await pause(0.3)
        XCTAssertEqual(rig.lines.filter { $0.hasPrefix("[appearance] 加载完成后") }.count, 1, "重新等的那次到点采用，只一次")
        XCTAssertTrue(PageAppearance.sameColor(rig.appearance.background, DisplayRig.white))
    }

    // MARK: - 进行中的切模式

    /// 快照到了、网页还在排版时换页面：先结束这次切模式（结束的那一刻显示的还是 p0），旧画面拿掉。
    /// 之后它迟到的排版完成什么都不做；p1 显示时开始的下一次也不因为它结束，要等自己的排版完成。
    func testDisplayEndsARunningModeSwitchFirstAndItsLateLayoutDoesNotEndTheNextOne() throws {
        let rig = make()
        let layout = rig.recordLayout()
        let target = rig.biggerFrame()
        rig.controller.beginLayoutChangeForTesting(to: target)
        layout.snapshots[0](NSImage(size: NSSize(width: 10, height: 10)))
        XCTAssertTrue(rig.controller.isShowingFrozenPage)
        XCTAssertEqual(layout.prepares.count, 1)
        XCTAssertEqual(layout.events, ["排版前"])

        rig.display(1)
        XCTAssertEqual(layout.events, ["排版前", "排版后 显示 p0 网页 w0"], "先结束切模式，再换页面")
        XCTAssertFalse(rig.controller.isChangingLayout)
        XCTAssertFalse(rig.controller.isShowingFrozenPage)
        XCTAssertEqual(rig.controller.window?.frame, target, "窗口到位")
        let lines = rig.lines
        layout.prepares[0]()
        XCTAssertEqual(layout.events.count, 2, "迟到的排版完成什么都不做")
        XCTAssertEqual(rig.lines, lines)

        rig.controller.beginLayoutChangeForTesting(to: rig.biggerFrame())
        layout.snapshots[1](NSImage(size: NSSize(width: 10, height: 10)))
        layout.prepares[0]()
        XCTAssertTrue(rig.controller.isChangingLayout, "上一次迟到的排版完成不结束这一次")
        XCTAssertTrue(rig.controller.isShowingFrozenPage)
        layout.prepares[1]()
        XCTAssertFalse(rig.controller.isChangingLayout)
        XCTAssertEqual(layout.events, ["排版前", "排版后 显示 p0 网页 w0", "排版前", "排版后 显示 p1 网页 w1"])
    }

    /// 快照还没到时换页面：先结束这次（窗口到位、说排版结束），之后迟到的快照不盖旧画面，时限到了也不写日志。
    func testALateSnapshotOrTimeLimitOfTheEndedModeSwitchDoesNothing() async throws {
        let rig = make()
        rig.controller.layoutWaitLimit = 0.2
        let layout = rig.recordLayout()
        let target = rig.biggerFrame()
        rig.controller.beginLayoutChangeForTesting(to: target)
        XCTAssertTrue(rig.controller.isChangingLayout)
        rig.display(1)
        XCTAssertEqual(layout.events, ["排版前", "排版后 显示 p0 网页 w0"])
        XCTAssertEqual(rig.controller.window?.frame, target)
        let lines = rig.lines
        layout.snapshots[0](NSImage(size: NSSize(width: 10, height: 10)))
        XCTAssertFalse(rig.controller.isShowingFrozenPage, "迟到的快照不盖旧画面")
        XCTAssertTrue(layout.prepares.isEmpty)
        try await pause(0.35)
        XCTAssertEqual(rig.lines, lines, "时限到了也不写日志")
        XCTAssertEqual(layout.events.count, 2)
    }
}

/// 一次切模式里窗口要的快照、排版（测试手动送回），和排版前后的回调（记下那时显示的页面和网页视图）。
@MainActor
private final class LayoutCalls {
    var snapshots: [(NSImage?) -> Void] = []
    var prepares: [() -> Void] = []
    var events: [String] = []
}

/// 一个窗口和三个页面（各自的网页视图，带标签 1、2、3）。开始时显示 p0。记下的页面颜色是 savedDark，
/// 网页视图开始时都报着 blankDark（之后设的颜色都是真的变化）。解除启动保护后等颜色的时限放长，测试按需要改。
@MainActor
private final class DisplayRig {
    static let savedDark = NSColor(srgbRed: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x0E / 255.0, alpha: 1)
    static let blankDark = NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)
    static let pageBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    let diagnostics = Diagnostics()
    let appearance: PageAppearance
    let views: [WKWebView]
    let pages: [PageLoadState]
    let controller: ChatWindowController

    init(defaults: UserDefaults) {
        let rgb = Self.savedDark.usingColorSpace(.sRGB)!
        defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init), forKey: "pageBackgroundRGB")
        appearance = PageAppearance(defaults: defaults)
        var list = TabList()
        var ids = [list.selected]
        for _ in 0..<2 {
            guard case .added(let id) = list.append(select: false) else { preconditionFailure("加得进") }
            ids.append(id)
        }
        pages = ids.map { PageLoadState(logTag: $0) }
        views = ids.map { _ in
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            web.underPageBackgroundColor = Self.blankDark
            return web
        }
        controller = ChatWindowController(webView: views[0], toolbar: EmptyView(), diagnostics: diagnostics,
                                          appearance: appearance, page: pages[0])
        controller.pageColorSettleLimit = 60
        controller.launchScreenLimit = 60
        controller.launchScreenCap = 60
    }

    func display(_ i: Int) {
        controller.display(pages[i], webView: views[i])
    }

    /// 页面 i 提交、遮挡结束、加载完成（报 color），和接线（ChatTabs.wire(_:)）的顺序一样。网页视图先报着 color。
    func load(_ i: Int, reporting color: NSColor) {
        views[i].underPageBackgroundColor = color
        controller.pageDidCommit(pages[i])
        controller.endLaunchScreen("网页已加载", for: pages[i])
        controller.pageDidFinishLoading(pages[i], reportedColor: color)
    }

    func layout() {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// 网页视图自己身上起作用的固定宽、高约束（藏起时加的）；没有时是 nil。
    static func fixedSize(_ view: NSView) -> NSSize? {
        let fixed = view.constraints.filter { $0.isActive && $0.secondItem == nil && $0.firstItem === view }
        guard let width = fixed.first(where: { $0.firstAttribute == .width }),
              let height = fixed.first(where: { $0.firstAttribute == .height }) else { return nil }
        return NSSize(width: width.constant, height: height.constant)
    }

    func chatWindow() throws -> ChatWindow {
        try XCTUnwrap(controller.window as? ChatWindow)
    }

    /// 窗口写的日志（“[类别] 内容”），去掉跟着真实输入写的（LiveInputLogLines），毫秒数换成“…”。
    var lines: [String] {
        diagnostics.entries.filter { !LiveInputLogLines.excludes($0) }
            .map { "[\($0.category)] \($0.message)" }
            .map { $0.replacingOccurrences(of: #"（\d+ms）"#, with: "（…ms）", options: .regularExpression) }
            .filter { !$0.hasPrefix("[window] 切换模式") }
    }

    var noticeCover: NSHostingView<LoadProblemView> {
        controller.window!.contentView!.subviews.compactMap { $0 as? NSHostingView<LoadProblemView> }.first!
    }

    /// 窗口上看得见的：遮挡、淡出、启动保护、提示、颜色、显示的页面和网页视图。
    var window: String {
        "遮挡=\(controller.shownCoverKind.map { "\($0)" } ?? "无") 启动画面淡出=\(controller.launchFadeView != nil) "
            + "启动保护=\(controller.isHoldingPageColor) 提示=\(controller.shownLoadProblem.map { "\($0)" } ?? "无") "
            + "提示那层藏着=\(noticeCover.isHidden) 提示淡出=\(controller.loadProblemFadeView != nil) "
            + "页面颜色=\(appearance.background.map { "\($0)" } ?? "nil") 窗口底色=\(controller.window?.backgroundColor.map { "\($0)" } ?? "nil") "
            + "显示=\(pages.firstIndex { $0 === controller.page } ?? -1) 网页=\(views.firstIndex { $0 === controller.webView } ?? -1)"
    }

    /// 接上切模式要的快照和排版（手动送回），排版前后的回调记下那时显示的页面和网页视图。
    func recordLayout() -> LayoutCalls {
        let calls = LayoutCalls()
        controller.onSnapshotPage = { done in calls.snapshots.append(done) }
        controller.onPrepareLayout = { _, done in calls.prepares.append(done) }
        controller.onWillChangeLayout = { calls.events.append("排版前") }
        controller.onDidChangeLayout = { [weak self] in
            guard let self else { return }
            let page = self.pages.firstIndex { $0 === self.controller.page } ?? -1
            let web = self.views.firstIndex { $0 === self.controller.webView } ?? -1
            calls.events.append("排版后 显示 p\(page) 网页 w\(web)")
        }
        return calls
    }

    /// 比现在的窗口大一些的位置（切模式的目标）。
    func biggerFrame() -> NSRect {
        var frame = controller.window!.frame
        frame.size.width += 100
        frame.size.height += 60
        return frame
    }
}
