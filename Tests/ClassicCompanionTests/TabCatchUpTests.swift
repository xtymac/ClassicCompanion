import AppKit
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 切换标签页时的补排版（3.5），窗口这一边（ChatWindowController.display(_:webView:beforeCatchUp:laidOut:)）。
/// 一个窗口和三个页面 p0、p1、p2（网页视图 w0、w1、w2），开始时显示 p0。切模式和补排版共用的排版（onPrepareLayout）、
/// 切模式的快照都换成手动送回，排版前后的回调、每次显示的 beforeCatchUp 和 laidOut 都按先后记下。核对：
/// - 要不要补：离开时排好版的大小、缩放和现在一样就不补，当场说排好（laidOut 正好一次）；不一样、或离开时还没排好（正在切模式
///   或补排版）就补；从没显示过的不补；排版没接上的不补。
/// - 怎么补：先 beforeCatchUp（那时换上来的网页视图还藏着、还是离开时的大小），再放上来，盖上窗口此刻的页面底色（不带图片，
///   在网页上面、提示和第一次加载的遮挡下面），网页视图已经显示、在窗口里、是现在的大小时才让它排版；排好或到时限才揭开、说排好。
/// - 先结束：切模式、拖边开始时先结束补排版（算排好，在排版前的回调之前）；又换了显示的页面：作废，不说排好。
///   迟到的排版完成和时限只对它们那一次起作用，切模式和补排版互不结束。
/// - 和第一次加载的遮挡同时有：各管各的，谁先结束都行。
/// 不显示窗口：网页不会真的排版，排好由测试送回。屏幕上的样子（那块的颜色、有没有闪）这里看不到。
@MainActor
final class TabCatchUpTests: XCTestCase {
    private func make() -> CatchUpRig {
        let name = "TabCatchUpTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = CatchUpRig(defaults: UserDefaults(suiteName: name)!)
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

    // MARK: - 要不要补

    /// 第一次显示（w1 从没在窗口里）、换回大小和缩放都没变的 w0：不补排版，当场说排好，各一次；不要排版、不盖、不写日志。
    /// 换下去时记下它排好版的大小和缩放。
    func testNoCatchUpWhenSizeAndZoomAreUnchanged() throws {
        let rig = make()
        rig.display(1)
        XCTAssertEqual(rig.events, ["排好 p1"])
        XCTAssertEqual(rig.controller.hiddenLayout(of: rig.views[0]), .laidOut(rig.containerSize, 1))
        rig.display(0)
        XCTAssertEqual(rig.events, ["排好 p1", "排好 p0"])
        XCTAssertFalse(rig.controller.isCatchingUp)
        XCTAssertNil(rig.controller.catchUpCoverView)
        XCTAssertTrue(rig.prepares.isEmpty)
        XCTAssertEqual(rig.lines, [])
        XCTAssertNil(rig.controller.hiddenLayout(of: rig.views[0]), "显示着的不算藏着")
        XCTAssertEqual(rig.controller.hiddenLayout(of: rig.views[1]), .laidOut(rig.containerSize, 1))
    }

    /// 藏着时窗口变大了：再显示 w0 时先 beforeCatchUp（w0 还藏着、还是离开时的大小），再放上来盖上页面底色，
    /// w0 已经显示、在窗口里、是现在的大小时才要排版（交的是现在的容器大小）。排好之前不说排好；排好时拿掉那块、说排好一次。
    /// 那块：窗口此刻的页面底色（换上来的页面已经稳定的颜色马上采用，那块就是它），在网页上面、提示和遮挡下面，铺满网页的位置。
    func testAChangedSizeIsCaughtUpUnderThePageColourFirst() throws {
        let rig = make()
        rig.load(0, reporting: CatchUpRig.pageBlack)
        rig.load(1, reporting: CatchUpRig.white)
        rig.display(1)
        let left = rig.views[0].frame.size
        rig.grow()
        rig.display(0)
        XCTAssertEqual(rig.events, ["排好 p1", "补排版前 p0 藏着=true 大小=\(CatchUpRig.text(left))"])
        XCTAssertTrue(rig.controller.isCatchingUp)
        let cover = try XCTUnwrap(rig.controller.catchUpCoverView)
        XCTAssertTrue(PageAppearance.sameColor(rig.controller.catchUpCoverBackground, CatchUpRig.pageBlack), "换上来的页面的颜色")
        XCTAssertTrue(PageAppearance.sameColor(rig.controller.catchUpCoverBackground, rig.controller.window?.backgroundColor))
        XCTAssertFalse(cover.isAccessibilityElement())
        XCTAssertEqual(rig.prepares.map(\.size), [rig.containerSize])
        XCTAssertNotEqual(rig.containerSize, left)
        XCTAssertEqual(rig.prepareStates, ["显示=true 在窗口里=true 大小对=true"])
        rig.layout()
        XCTAssertEqual(cover.frame, rig.views[0].superview?.frame, "铺满网页的位置")
        let order = try rig.layerOrder(cover)
        XCTAssertTrue(order.web < order.cover && order.cover < order.notice && order.notice < order.launch,
                      "网页 < 那块 < 提示 < 遮挡：\(order)")
        XCTAssertEqual(rig.catchUpLines, ["[window] 补排版：大小和离开时不同，盖上页面底色等网页排好"])

        rig.prepares[0].done()
        XCTAssertFalse(rig.controller.isCatchingUp)
        XCTAssertNil(cover.superview, "揭开")
        XCTAssertEqual(rig.events.last, "排好 p0")
        XCTAssertEqual(rig.events.filter { $0 == "排好 p0" }.count, 1)
        XCTAssertEqual(rig.catchUpLines.last, "[window] 补排版结束：网页排好（…ms）")
        rig.prepares[0].done()
        XCTAssertEqual(rig.events.filter { $0 == "排好 p0" }.count, 1, "再送一遍排好什么都不做")
        XCTAssertEqual(rig.catchUpLines.count, 2)
    }

    /// 藏着时页面缩放变了（大小没变）：再显示时补排版。
    func testAZoomChangedWhileHiddenIsCaughtUp() {
        let rig = make()
        rig.display(1)
        rig.views[0].pageZoom = 1.25
        rig.display(0)
        XCTAssertTrue(rig.controller.isCatchingUp)
        XCTAssertEqual(rig.catchUpLines, ["[window] 补排版：缩放和离开时不同，盖上页面底色等网页排好"])
        rig.prepares[0].done()
        XCTAssertEqual(rig.events.last, "排好 p0")
        XCTAssertEqual(rig.controller.hiddenLayout(of: rig.views[1]), .laidOut(rig.containerSize, 1))
    }

    /// 排版没接上（切模式也就直接切换）：大小变了也不补，不调 beforeCatchUp，当场说排好。
    func testWithoutTheLayoutHookThereIsNoCatchUp() {
        let rig = make()
        rig.controller.onPrepareLayout = nil
        rig.display(1)
        rig.grow()
        rig.display(0)
        XCTAssertEqual(rig.events, ["排好 p1", "排好 p0"])
        XCTAssertFalse(rig.controller.isCatchingUp)
        XCTAssertEqual(rig.lines, [])
    }

    /// 第一次显示的页面（从没在窗口里，网页视图是别的大小）：不补，哪怕它没有第一次加载的遮挡。
    func testAPageShownForTheFirstTimeIsNotCaughtUp() {
        let rig = make()
        let page = PageLoadState(), web = WKWebView(frame: NSRect(x: 0, y: 0, width: 123, height: 45))
        var laidOut = 0, held = 0
        rig.controller.display(page, webView: web, beforeCatchUp: { held += 1 }, laidOut: { laidOut += 1 })
        XCTAssertEqual(laidOut, 1)
        XCTAssertEqual(held, 0)
        XCTAssertFalse(rig.controller.isCatchingUp)
    }

    // MARK: - 时限、作废

    /// 一直没排好：到时限揭开、说排好（算排好，和切模式一样）。之后迟到的排好什么都不做。
    func testTheTimeLimitCountsAsLaidOut() async throws {
        let rig = make()
        rig.controller.layoutWaitLimit = 0.2
        rig.display(1)
        rig.grow()
        rig.display(0)
        let cover = try XCTUnwrap(rig.controller.catchUpCoverView)
        try await pause(0.1)
        XCTAssertTrue(rig.controller.isCatchingUp)
        try await waitUntil { !rig.controller.isCatchingUp }
        XCTAssertNil(cover.superview)
        XCTAssertEqual(rig.events.last, "排好 p0")
        XCTAssertEqual(rig.catchUpLines.last, "[window] 补排版结束：超过时限（…ms）")
        rig.prepares[0].done()
        XCTAssertEqual(rig.events.filter { $0 == "排好 p0" }.count, 1)
    }

    /// A → B → A：p0 补排版还没完就换上 p1：那一次作废（拿掉那块、不说排好，写一行），p0 记作“离开时还没排好”；
    /// 再换回 p0：大小没变也补。第一次的排好、时限迟到时都不结束第二次，第二次排好时才说排好，p0 一共只说一次。
    func testSwitchingAwayDropsTheCatchUpAndTheNextShowCatchesUpAgain() async throws {
        let rig = make()
        rig.controller.layoutWaitLimit = 0.3
        rig.display(1)
        rig.grow()
        rig.display(0)
        let first = try XCTUnwrap(rig.controller.catchUpCoverView)
        let started = Date()
        try await pause(0.15)
        rig.display(1)
        XCTAssertNil(first.superview)
        XCTAssertFalse(rig.controller.isCatchingUp, "p1 离开时排好了，大小没变：不补")
        XCTAssertEqual(rig.controller.hiddenLayout(of: rig.views[0]), .unknown)
        XCTAssertEqual(rig.catchUpLines.last, "[window] 补排版结束：换了显示的页面（…ms）")
        XCTAssertFalse(rig.events.contains("排好 p0"), "作废的那次不说排好")

        rig.display(0)
        XCTAssertTrue(rig.controller.isCatchingUp)
        XCTAssertEqual(rig.catchUpLines.last, "[window] 补排版：离开时还没排好，盖上页面底色等网页排好")
        XCTAssertEqual(rig.prepares.count, 2)
        rig.prepares[0].done()
        XCTAssertTrue(rig.controller.isCatchingUp, "第一次迟到的排好不结束第二次")
        try await pause(max(0, 0.4 - Date().timeIntervalSince(started)))
        XCTAssertTrue(rig.controller.isCatchingUp, "第一次的时限到了也不结束第二次")
        XCTAssertFalse(rig.events.contains("排好 p0"))
        rig.prepares[1].done()
        XCTAssertFalse(rig.controller.isCatchingUp)
        XCTAssertEqual(rig.events.filter { $0 == "排好 p0" }.count, 1)
    }

    // MARK: - 和切模式

    /// 切模式进行中（快照到了、网页在排版）换上 p1：切模式先结束，p0 记作“离开时还没排好”；换回 p0 时大小一样也补。
    /// 切模式迟到的排版完成不结束这次补排版；补排版的排好照常结束它。
    func testDisplayDuringAModeSwitchLeavesTheOutgoingPageUnlaidOut() throws {
        let rig = make()
        rig.controller.beginLayoutChangeForTesting(to: rig.biggerFrame())
        rig.snapshots[0](NSImage(size: NSSize(width: 10, height: 10)))
        rig.display(1)
        XCTAssertEqual(rig.controller.hiddenLayout(of: rig.views[0]), .unknown)
        XCTAssertFalse(rig.controller.isCatchingUp, "p1 第一次显示：不补")
        rig.display(0)
        XCTAssertTrue(rig.controller.isCatchingUp)
        XCTAssertEqual(rig.catchUpLines, ["[window] 补排版：离开时还没排好，盖上页面底色等网页排好"])
        rig.prepares[0].done()
        XCTAssertTrue(rig.controller.isCatchingUp, "切模式迟到的排版完成不结束补排版")
        rig.prepares[1].done()
        XCTAssertFalse(rig.controller.isCatchingUp)
        XCTAssertEqual(rig.events.filter { $0.hasPrefix("排好") }, ["排好 p1", "排好 p0"])
    }

    /// 补排版中开始切模式：先结束补排版（算排好，在“排版前”之前说排好），那块拿掉；切模式照常进行，
    /// 补排版迟到的排好不结束切模式。拖边开始时也一样先结束。
    func testAModeSwitchOrAnEdgeDragEndsARunningCatchUpFirst() throws {
        let rig = make()
        rig.display(1)
        rig.grow()
        rig.display(0)
        let cover = try XCTUnwrap(rig.controller.catchUpCoverView)
        rig.controller.beginLayoutChangeForTesting(to: rig.biggerFrame())
        XCTAssertNil(cover.superview)
        XCTAssertFalse(rig.controller.isCatchingUp)
        XCTAssertEqual(Array(rig.events.suffix(2)), ["排好 p0", "排版前"])
        XCTAssertEqual(rig.catchUpLines.last, "[window] 补排版结束：显示窗口或切模式（…ms）")
        rig.snapshots[0](NSImage(size: NSSize(width: 10, height: 10)))
        XCTAssertTrue(rig.controller.isChangingLayout)
        rig.prepares[0].done()
        XCTAssertTrue(rig.controller.isChangingLayout, "补排版迟到的排好不结束切模式")
        rig.prepares[1].done()
        XCTAssertFalse(rig.controller.isChangingLayout)
        XCTAssertEqual(rig.events.filter { $0 == "排好 p0" }.count, 1)

        rig.display(1)
        rig.grow()
        rig.display(0)
        XCTAssertTrue(rig.controller.isCatchingUp)
        let window = try XCTUnwrap(rig.controller.window)
        rig.controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        XCTAssertFalse(rig.controller.isCatchingUp)
        XCTAssertEqual(Array(rig.events.suffix(2)), ["排好 p0", "排版前"])
        XCTAssertEqual(rig.catchUpLines.last, "[window] 补排版结束：拖边（…ms）")
        rig.controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        XCTAssertEqual(rig.events.last, "排版后")
    }

    /// 补排版中换网页视图（同一个页面，只有测试用）：和切模式一样先结束补排版，算排好。
    func testReplacingTheWebViewEndsARunningCatchUpFirst() throws {
        let rig = make()
        rig.display(1)
        rig.grow()
        rig.display(0)
        let cover = try XCTUnwrap(rig.controller.catchUpCoverView)
        rig.controller.replaceWebView(with: WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        XCTAssertFalse(rig.controller.isCatchingUp)
        XCTAssertNil(cover.superview)
        XCTAssertEqual(rig.events.last, "排好 p0")
        XCTAssertEqual(rig.catchUpLines.last, "[window] 补排版结束：换网页视图（…ms）")
        rig.prepares[0].done()
        XCTAssertEqual(rig.events.filter { $0 == "排好 p0" }.count, 1)
    }

    // MARK: - 和第一次加载的遮挡

    /// 盖着新标签页的遮挡、又要补排版的页面：两样都有（遮挡在上面）。遮挡先结束：淡出那层下面还是那块，补排版照常；
    /// 补排版先结束：遮挡还盖着。各自写自己的行。
    func testAFirstLoadCoverAndACatchUpRunSideBySide() throws {
        for coverEndsFirst in [true, false] {
            let rig = make()
            rig.display(1)
            rig.controller.beginNewTabCover(for: rig.pages[0])
            rig.grow()
            rig.display(0)
            XCTAssertEqual(rig.controller.shownCoverKind, .newTab, "遮挡先结束=\(coverEndsFirst)")
            XCTAssertTrue(rig.controller.isCatchingUp)
            let cover = try XCTUnwrap(rig.controller.catchUpCoverView)
            if coverEndsFirst {
                rig.controller.endLaunchScreen("网页已加载", for: rig.pages[0])
                XCTAssertNil(rig.controller.shownCoverKind)
                let fade = try XCTUnwrap(rig.controller.launchFadeView)
                XCTAssertTrue(rig.controller.isCatchingUp, "遮挡结束不结束补排版")
                let order = try rig.layerOrder(cover)
                let fadeIndex = try XCTUnwrap(rig.contentView.subviews.firstIndex { $0 === fade })
                XCTAssertLessThan(order.cover, fadeIndex, "淡出那层下面还是那块")
                rig.prepares[0].done()
                XCTAssertFalse(rig.controller.isCatchingUp)
            } else {
                rig.prepares[0].done()
                XCTAssertFalse(rig.controller.isCatchingUp)
                XCTAssertEqual(rig.controller.shownCoverKind, .newTab, "补排版结束不结束遮挡")
                XCTAssertTrue(rig.pages[0].isCovered)
                rig.controller.endLaunchScreen("网页已加载", for: rig.pages[0])
                XCTAssertNil(rig.controller.shownCoverKind)
            }
            XCTAssertEqual(rig.events.filter { $0 == "排好 p0" }.count, 1)
            XCTAssertEqual(rig.lines.filter { $0.hasPrefix("[launch]") }, ["[launch] 启动画面结束：网页已加载（…ms） 【标签1】"])
        }
    }

    // MARK: - 颜色

    /// 补排版中采用了新的页面颜色（换上来的页面又在加载，颜色稳定 150ms 再采用）：那块跟着变成窗口此刻的颜色。
    func testTheCoverFollowsAColourAdoptedDuringTheCatchUp() async throws {
        let rig = make()
        rig.load(0, reporting: CatchUpRig.pageBlack)
        rig.load(1, reporting: CatchUpRig.white)
        rig.display(1)
        rig.grow()
        rig.controller.pageDidCommit(rig.pages[0])
        rig.display(0)
        XCTAssertTrue(PageAppearance.sameColor(rig.controller.catchUpCoverBackground, CatchUpRig.white), "先是窗口原来的颜色")
        try await waitUntil { PageAppearance.sameColor(rig.appearance.background, CatchUpRig.pageBlack) }
        XCTAssertTrue(rig.controller.isCatchingUp)
        XCTAssertTrue(PageAppearance.sameColor(rig.controller.catchUpCoverBackground, CatchUpRig.pageBlack), "跟着换")
    }
}

/// 一个窗口和三个页面（各自的网页视图，带标签 1、2、3）。开始时显示 p0。记下的页面颜色是 savedDark，网页视图开始时都报着 blankDark。
/// 排版（补排版、切模式共用）和快照手动送回；排版前后、每次显示的 beforeCatchUp 和 laidOut 按先后记在 events 里。
@MainActor
private final class CatchUpRig {
    static let savedDark = NSColor(srgbRed: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x0E / 255.0, alpha: 1)
    static let blankDark = NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)
    static let pageBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    let diagnostics = Diagnostics()
    let appearance: PageAppearance
    let views: [WKWebView]
    let pages: [PageLoadState]
    let controller: ChatWindowController
    /// 每次要排版：交给的大小，和手动送回的完成。
    var prepares: [(size: NSSize, done: () -> Void)] = []
    /// 每次要排版时显示着的网页视图的样子。
    var prepareStates: [String] = []
    var snapshots: [(NSImage?) -> Void] = []
    /// “补排版前 pN …”“排好 pN”“排版前”“排版后”，按先后。
    var events: [String] = []

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
        controller.layoutWaitLimit = 60
        controller.onSnapshotPage = { [weak self] done in self?.snapshots.append(done) }
        controller.onPrepareLayout = { [weak self] size, done in
            guard let self else { return }
            let web = self.controller.webView
            self.prepareStates.append("显示=\(!web.isHidden) 在窗口里=\(web.window != nil && web.superview === self.views[0].superview) "
                                      + "大小对=\(web.frame.size == size)")
            self.prepares.append((size, done))
        }
        controller.onWillChangeLayout = { [weak self] in self?.events.append("排版前") }
        controller.onDidChangeLayout = { [weak self] in self?.events.append("排版后") }
    }

    func display(_ i: Int) {
        controller.display(pages[i], webView: views[i],
                           beforeCatchUp: { [self] in
                               events.append("补排版前 p\(i) 藏着=\(views[i].isHidden) 大小=\(Self.text(views[i].frame.size))")
                           },
                           laidOut: { [weak self] in self?.events.append("排好 p\(i)") })
    }

    /// 页面 i 提交、遮挡结束、加载完成（报 color），和接线的顺序一样。
    func load(_ i: Int, reporting color: NSColor) {
        views[i].underPageBackgroundColor = color
        controller.pageDidCommit(pages[i])
        controller.endLaunchScreen("网页已加载", for: pages[i])
        controller.pageDidFinishLoading(pages[i], reportedColor: color)
    }

    var contentView: NSView { controller.window!.contentView! }

    func layout() {
        contentView.layoutSubtreeIfNeeded()
    }

    /// 网页的位置（webContainer）现在的大小。
    var containerSize: NSSize {
        layout()
        return views[0].superview!.bounds.size
    }

    /// 窗口变大一些（像藏着时切过模式），当场排版。
    func grow() {
        controller.window!.setFrame(biggerFrame(), display: false)
        layout()
    }

    func biggerFrame() -> NSRect {
        var frame = controller.window!.frame
        frame.size.width += 100
        frame.size.height += 60
        return frame
    }

    /// 内容视图里各层的先后：网页的位置、补排版的那块、提示那层、遮挡那层（初始化时加的那个）。
    func layerOrder(_ cover: NSView) throws -> (web: Int, cover: Int, notice: Int, launch: Int) {
        let subviews = contentView.subviews
        let web = try XCTUnwrap(subviews.firstIndex { $0 === views[0].superview })
        let mine = try XCTUnwrap(subviews.firstIndex { $0 === cover })
        let notice = try XCTUnwrap(subviews.firstIndex { $0 is NSHostingView<LoadProblemView> })
        let launch = try XCTUnwrap(subviews.firstIndex { $0 is NSHostingView<LaunchScreen> })
        return (web, mine, notice, launch)
    }

    /// 窗口写的日志，去掉跟着真实输入写的，毫秒数换成“…”。
    var lines: [String] {
        diagnostics.entries.filter { !LiveInputLogLines.excludes($0) }
            .map { "[\($0.category)] \($0.message)" }
            .map { $0.replacingOccurrences(of: #"（\d+ms）"#, with: "（…ms）", options: .regularExpression) }
    }

    /// 补排版写的行。
    var catchUpLines: [String] {
        lines.filter { $0.hasPrefix("[window] 补排版") }
    }

    static func text(_ size: NSSize) -> String {
        "\(Int(size.width))×\(Int(size.height))"
    }
}

/// 切换标签页时的补排版（3.5），经真正的切换入口 ChatTabs.select(_:)。三个标签页，正式运行时的建法（ChatTab.make，标签 1、2、3），
/// t1 是启动时的那个。记下、放回、丢弃阅读位置和排版（补排版、切模式共用）换成记录，排版手动送回。核对：
/// - 换上来的标签页按现在的窗口大小排好版时（不补就在 select 里，要补就在补排版结束时）才处理它留着的阅读位置，每次显示正好一次，
///   只给那时还选中的它；补排版没结束就又切换走：留着的继续留着，下一次排好版时放回。
/// - 补排版前（网页视图还藏着、还是离开时的大小）记下它的阅读位置；已经留着一次的不再记。
/// - 发给每一页的设置：藏着的也收到；只有缩放让它再显示时补排版。留着阅读位置的标签页改缩放时运行时不自己记下、放回
///   （3.2 记下的问题：那样会用掉网页里留着的那份记录）。
/// - 关闭补排版被作废的标签页：它迟到的排好、时限什么都不做，标签页照常释放。
@MainActor
final class TabCatchUpSelectTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!

    private func make() -> CatchUpTabs {
        let name = "TabCatchUpSelectTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = CatchUpTabs(defaults: UserDefaults(suiteName: name)!)
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

    /// t1 留着一次阅读位置（拖边开始时记下，拖边途中切换到 t2，拖边结束时 t1 不选中），窗口大小没变：t1 离开时排好了版。
    private func pendingWithoutResize(_ rig: CatchUpTabs) throws {
        let window = try XCTUnwrap(rig.controller.window)
        rig.controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        rig.tabs.select(rig.t[1])
        rig.controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
    }

    // MARK: - 什么时候放回

    /// 大小没变的标签页：在 select 里当场放回它留着的那次（和 3.4 一样），不补排版。
    func testATabShownAtItsOldSizeRestoresItsPendingPositionWithinSelect() throws {
        let rig = make()
        rig.t[0].runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        try pendingWithoutResize(rig)
        XCTAssertEqual(rig.t[0].pendingReadingRestore?.token, 1)
        XCTAssertEqual(rig.controller.hiddenLayout(of: rig.t[0].runtime.webView), .laidOut(rig.containerSize, 1))
        rig.tabs.select(rig.t[0])
        XCTAssertFalse(rig.controller.isCatchingUp)
        XCTAssertTrue(rig.prepared.isEmpty)
        XCTAssertEqual(calls.list, ["记下 1（显示着）", "放回 1（显示着）"])
        XCTAssertEqual(calls.tokens, [1, 1])
    }

    /// 藏着时窗口变大：切回 t1 时先在它变大小之前记下（藏着、离开时的大小），补排版排好之后才放回那一次，写一行。
    /// 排好之前不放回；那时 select 早已返回（聚焦、记下对话地址照常在 select 里）。
    func testACatchUpHoldsThePositionBeforeTheResizeAndRestoresItAfter() throws {
        let rig = make()
        rig.t[0].runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        rig.tabs.select(rig.t[1])
        let left = rig.t[0].runtime.webView.frame.size
        rig.grow()
        let mark = rig.mark(), saved = rig.saved.count
        rig.tabs.select(rig.t[0])
        XCTAssertEqual(calls.list, ["记下 1（藏着 \(CatchUpRig.text(left))）"])
        XCTAssertEqual(rig.prepared, ["1 显示=true 大小=\(CatchUpRig.text(rig.containerSize))"])
        XCTAssertEqual(rig.saved.dropFirst(saved), [chat], "记下对话地址照常在 select 里")
        XCTAssertNotNil(rig.t[0].pendingReadingRestore)

        rig.prepares[0]()
        XCTAssertEqual(calls.list, ["记下 1（藏着 \(CatchUpRig.text(left))）", "放回 1（显示着）"])
        XCTAssertEqual(calls.tokens, [1, 1])
        XCTAssertNil(rig.t[0].pendingReadingRestore)
        XCTAssertEqual(rig.lines(since: mark), [
            "[tabs] 选中 【标签1】",
            "[window] 补排版：大小和离开时不同，盖上页面底色等网页排好",
            "[window] 补排版结束：网页排好（…ms）",
            "[reading] 阅读位置：这一页又显示并排好版，放回留着的位置 【标签1】",
        ])
    }

    /// 已经留着一次的（切模式中切换走、切模式被先结束）：补排版前不再记，排好后放回留着的那一次（离开前记下的）。
    func testACatchUpKeepsAnOlderPendingPositionInsteadOfHoldingAgain() {
        let rig = make()
        rig.t[0].runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        rig.controller.beginLayoutChangeForTesting(to: rig.biggerFrame())
        rig.snapshots[0](NSImage(size: NSSize(width: 10, height: 10)))
        rig.tabs.select(rig.t[1])
        XCTAssertEqual(rig.t[0].pendingReadingRestore?.token, 1)
        rig.tabs.select(rig.t[0])
        XCTAssertTrue(rig.controller.isCatchingUp, "切模式被先结束，t1 离开时还没排好")
        XCTAssertEqual(calls.list, ["记下 1（显示着）"], "不再记")
        rig.prepares.last!()
        XCTAssertEqual(calls.list, ["记下 1（显示着）", "放回 1（显示着）"])
        XCTAssertEqual(calls.tokens, [1, 1])
    }

    /// 到时限也算排好：放回。
    func testATimeLimitCountsAsLaidOutForTheTab() async throws {
        let rig = make()
        rig.controller.layoutWaitLimit = 0.2
        let calls = rig.recordReadingPosition()
        rig.tabs.select(rig.t[1])
        rig.grow()
        rig.tabs.select(rig.t[0])
        XCTAssertEqual(calls.list, ["记下 1（藏着 \(CatchUpRig.text(rig.firstSize))）"])
        try await waitUntil { calls.list.count == 2 }
        XCTAssertEqual(calls.list.last, "放回 1（显示着）")
        XCTAssertFalse(rig.controller.isCatchingUp)
    }

    // MARK: - 补排版中切换

    /// t1、t2 都藏着时窗口变大（显示着的是 t3）。t1 补排版中切换到 t2（t2 也要补，有它自己的）：t1 留着的那次继续留着、
    /// 不放回；t2 补排版前记下它自己的，排好时放回 t2 的。t1 那次迟到的排好什么都不做。
    /// A → B → A 很快（t1 离开时还没排好：大小没变也补；t1 的补排版还没完就切到 t2 又切回来）：不再记，
    /// 第一次迟到的排好不放回，最后一次排好时放回 t1 原来那一次，一共一次。
    func testSwitchingAwayDuringACatchUpLeavesThePositionPendingAndTheNextTabGetsItsOwn() {
        let rig = make()
        let calls = rig.recordReadingPosition()
        rig.tabs.select(rig.t[1])
        rig.tabs.select(rig.t[2])
        rig.grow()
        rig.tabs.select(rig.t[0])
        rig.tabs.select(rig.t[1])
        XCTAssertEqual(rig.prepared.map { String($0.prefix(1)) }, ["1", "2"])
        XCTAssertEqual(rig.t[0].pendingReadingRestore?.token, 1, "t1 的继续留着")
        XCTAssertFalse(rig.t[0].pendingReadingRestore?.isSettled ?? true)
        XCTAssertEqual(rig.t[1].pendingReadingRestore?.token, 2, "t2 补排版前记下的")
        let held = ["记下 1（藏着 \(CatchUpRig.text(rig.firstSize))）", "记下 2（藏着 \(CatchUpRig.text(rig.firstSize))）"]
        rig.prepares[0]()
        XCTAssertEqual(calls.list, held, "t1 迟到的排好不放回")
        XCTAssertTrue(rig.controller.isCatchingUp, "也不结束 t2 的")
        rig.prepares[1]()
        XCTAssertFalse(rig.controller.isCatchingUp)
        XCTAssertEqual(calls.list, held + ["放回 2（显示着）"])
        XCTAssertEqual(calls.tokens.last, 2)
        XCTAssertNotNil(rig.t[0].pendingReadingRestore, "t1 的还留着")

        rig.tabs.select(rig.t[0])
        rig.tabs.select(rig.t[1])
        XCTAssertFalse(rig.controller.isCatchingUp, "t2 离开时排好了，大小没变：不补")
        rig.tabs.select(rig.t[0])
        XCTAssertEqual(rig.prepared.map { String($0.prefix(1)) }, ["1", "2", "1", "1"])
        let before = calls.list
        rig.prepares[2]()
        XCTAssertEqual(calls.list, before, "换走前的那次迟到的排好不放回")
        XCTAssertTrue(rig.controller.isCatchingUp)
        rig.prepares[3]()
        XCTAssertEqual(calls.list, before + ["放回 1（显示着）"])
        XCTAssertEqual(calls.tokens.last, 1, "t1 原来那一次")
        XCTAssertEqual(calls.list.filter { $0.hasPrefix("记下") }.count, 2, "再显示时都没有再记")
        XCTAssertNil(rig.t[0].pendingReadingRestore)
    }

    /// 补排版中开始切模式：先放回留着的那次（补排版算排好），再记下切模式的那一次；切模式结束时放回那一次。
    func testAModeSwitchDuringACatchUpRestoresThePendingPositionFirst() {
        let rig = make()
        let calls = rig.recordReadingPosition()
        rig.tabs.select(rig.t[1])
        rig.grow()
        rig.tabs.select(rig.t[0])
        rig.controller.beginLayoutChangeForTesting(to: rig.biggerFrame())
        XCTAssertFalse(rig.controller.isCatchingUp)
        XCTAssertEqual(calls.list, ["记下 1（藏着 \(CatchUpRig.text(rig.firstSize))）", "放回 1（显示着）", "记下 1（显示着）"])
        rig.snapshots[0](NSImage(size: NSSize(width: 10, height: 10)))
        rig.prepares.last!()
        XCTAssertEqual(calls.list.last, "放回 1（显示着）")
        XCTAssertEqual(calls.tokens, [1, 1, 2, 2])
    }

    // MARK: - 关闭

    /// t2 补排版中切换走（作废）、再关闭 t2：它迟到的排好和时限什么都不做（不放回、不写日志、不动 t1），t2 照常释放。
    func testClosingATabWhoseCatchUpWasDroppedLeavesItsLateCallbacksHarmless() async throws {
        let rig = make()
        rig.controller.layoutWaitLimit = 0.25
        let calls = rig.recordReadingPosition()
        weak var released: ChatTab?
        var done: (() -> Void)?
        autoreleasepool {
            let d = rig.t[1]
            released = d
            rig.tabs.select(d)
            rig.tabs.select(rig.t[0])
            rig.grow()
            rig.tabs.select(d)
            XCTAssertTrue(rig.controller.isCatchingUp)
            done = rig.prepares.last
            rig.tabs.select(rig.t[0])
            rig.tabs.close(d)
            rig.forget(d)
        }
        let mark = rig.mark()
        let list = calls.list
        done?()
        try await pause(0.4)
        XCTAssertEqual(calls.list, list)
        XCTAssertEqual(rig.lines(since: mark), [], "不放回、不写日志")
        XCTAssertFalse(rig.controller.isCatchingUp)
        try await waitUntil(5) { released == nil }
        XCTAssertNil(released, "补排版作废的标签页照常释放")
    }

    // MARK: - 发给每一页的设置

    /// 藏着的 t1 收到网页无障碍、网页增强、弹窗标题：这些不改排版，切回来不补。改页面缩放：t1 也改，切回来补排版（原因是缩放）。
    /// t1 没有留着的阅读位置时改缩放照原来的做法（运行时自己记下、放回）。
    func testSettingsReachAHiddenTabAndOnlyTheZoomCatchesItUp() throws {
        let rig = make()
        let t1 = rig.t[0]
        rig.tabs.select(rig.t[1])
        rig.tabs.setPageAccessibilityAllowed(true)
        XCTAssertFalse(t1.runtime.webView.blockAccessibility)
        rig.settings.webEnhancements = false
        rig.tabs.applyEnhancementScripts()
        XCTAssertEqual(t1.runtime.webView.configuration.userContentController.userScripts.count, 0)
        rig.tabs.select(t1)
        XCTAssertFalse(rig.controller.isCatchingUp, "不改排版的设置：不补")

        rig.tabs.select(rig.t[1])
        let holds = t1.runtime.readingHolds
        rig.tabs.setPageZoom(1.25)
        XCTAssertEqual(t1.runtime.webView.pageZoom, 1.25)
        XCTAssertEqual(t1.runtime.readingHolds, holds + 1, "没有留着的：运行时照原来记下、放回")
        let mark = rig.mark()
        rig.tabs.select(t1)
        XCTAssertTrue(rig.controller.isCatchingUp)
        XCTAssertEqual(rig.lines(since: mark).filter { $0.hasPrefix("[window]") },
                       ["[window] 补排版：缩放和离开时不同，盖上页面底色等网页排好"])
    }

    /// 留着阅读位置的 t1（不显示）改缩放：只改缩放，运行时不自己记下、放回（不会用掉网页里留着的那份）；留着的那次还在。
    /// 选中的 t2、从没显示过的 t3 没有留着的：照原来的做法。切回 t1 补排版（缩放变了），不再记，排好后放回留着的那次。
    func testAZoomForATabWithAPendingPositionLeavesThePagesRecordAlone() throws {
        let rig = make()
        rig.t[0].runtime.onURLChange?(chat)
        let calls = rig.recordReadingPosition()
        try pendingWithoutResize(rig)
        let pending = try XCTUnwrap(rig.t[0].pendingReadingRestore)
        let holds = rig.t.map(\.runtime.readingHolds)
        let mark = rig.mark()
        rig.tabs.setPageZoom(1.25)
        XCTAssertEqual(rig.t.map(\.runtime.webView.pageZoom), [1.25, 1.25, 1.25])
        XCTAssertEqual(rig.t.map(\.runtime.readingHolds), [holds[0], holds[1] + 1, holds[2] + 1])
        XCTAssertTrue(rig.t[0].pendingReadingRestore === pending)
        XCTAssertFalse(pending.isSettled)
        XCTAssertEqual(rig.lines(since: mark), ["[zoom] 页面缩放 125% 【标签1】", "[zoom] 页面缩放 125% 【标签2】",
                                                "[zoom] 页面缩放 125% 【标签3】"])

        rig.tabs.select(rig.t[0])
        XCTAssertTrue(rig.controller.isCatchingUp)
        XCTAssertEqual(rig.lines(since: mark).filter { $0.hasPrefix("[window]") },
                       ["[window] 补排版：缩放和离开时不同，盖上页面底色等网页排好"])
        XCTAssertEqual(calls.list, ["记下 1（显示着）"], "不再记")
        rig.prepares.last!()
        XCTAssertEqual(calls.list, ["记下 1（显示着）", "放回 1（显示着）"])
        XCTAssertEqual(calls.tokens, [pending.token, pending.token])
    }

    /// 显示着、还在补排版的 t1（留着补排版前记下的那次）改缩放：运行时也不自己记下、放回。
    func testAZoomDuringACatchUpLeavesThePendingPositionAlone() {
        let rig = make()
        let calls = rig.recordReadingPosition()
        rig.tabs.select(rig.t[1])
        rig.grow()
        rig.tabs.select(rig.t[0])
        let holds = rig.t[0].runtime.readingHolds
        rig.tabs.setPageZoom(1.5)
        XCTAssertEqual(rig.t[0].runtime.readingHolds, holds)
        XCTAssertEqual(rig.t[0].runtime.webView.pageZoom, 1.5)
        rig.prepares.last!()
        XCTAssertEqual(calls.list.last, "放回 1（显示着）")
    }
}

/// 三个标签页、一个窗口和接线，正式运行时的建法（ChatTab.make，日志带标签）。t[0] 是启动时的那个（标签 1）。
/// 排版（补排版、切模式共用）和快照手动送回；记下、放回、丢弃阅读位置换成记录。
@MainActor
private final class CatchUpTabs {
    let settings: AppSettings
    let diagnostics = Diagnostics()
    let controller: ChatWindowController
    let network = NetworkStatus(startsMonitor: false)
    private(set) var tabs: ChatTabs!
    /// 测试持有的标签页（forget(_:) 以后不再持有那一个）。
    private(set) var t: [ChatTab] = []
    private(set) var saved: [URL] = []
    var snapshots: [(NSImage?) -> Void] = []
    var prepares: [() -> Void] = []
    /// 每次排版交给的是哪个标签页、那时它的网页视图显示没有、交的大小（和容器一样时写容器的大小）。
    var prepared: [String] = []
    /// 启动时的网页视图大小（窗口变大之前）。
    private(set) var firstSize = NSSize.zero

    init(defaults: UserDefaults) {
        settings = AppSettings(defaults: defaults)
        let list = TabList()
        let first = Self.pinColour(ChatTab.make(id: list.selected, diagnostics: diagnostics, settings: settings))
        first.runtime.loadRequest = { _ in }
        controller = ChatWindowController(webView: first.runtime.webView, toolbar: EmptyView(), diagnostics: diagnostics,
                                          appearance: PageAppearance(defaults: defaults), page: first.page)
        controller.pageColorSettleLimit = 60
        controller.layoutWaitLimit = 60
        tabs = ChatTabs(list: list, tab: first, windowController: controller, diagnostics: diagnostics, network: network,
                        hideWindow: { _ in }, focusInput: { _ in "TabCatchUpSelectTests" },
                        saveLastConversation: { [weak self] url in self?.saved.append(url) },
                        mediaState: { _ in "none" }, openNewChat: { _ in true })
        tabs.wire(first)
        t = [first, add(), add()]
        controller.onSnapshotPage = { [weak self] done in self?.snapshots.append(done) }
        controller.onPrepareLayout = { [weak self] size, done in
            guard let self else { return }
            let tab = self.tabs.selected, web = tab.runtime.webView
            self.prepared.append("\(tab.id.rawValue) 显示=\(!web.isHidden && web.window != nil) 大小=\(CatchUpRig.text(size))")
            self.prepares.append(done)
        }
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        firstSize = first.runtime.webView.frame.size
    }

    /// 网页视图建好就设上页面底色（白色），这一组测试就和这个测试进程的外观无关。原因见 NewTabEntryTests.swift 里
    /// NewTabRig.pinColour(_:)：深色外观下，放进窗口的空白网页视图过一会儿会自己报出白色，窗口采用、写一行“页面底色：浅色”。
    private static func pinColour(_ tab: ChatTab) -> ChatTab {
        tab.runtime.webView.underPageBackgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        return tab
    }

    func add() -> ChatTab {
        let tab = tabs.add { Self.pinColour(ChatTab.make(id: $0, diagnostics: diagnostics, settings: settings)) }!
        tab.runtime.loadRequest = { _ in }
        return tab
    }

    /// 不再持有 tab（它关闭以后，看它能不能释放）。
    func forget(_ tab: ChatTab) {
        t.removeAll { $0 === tab }
    }

    func name(_ runtime: WebRuntime) -> String {
        tabs.tabs.first { $0.runtime === runtime }.map { "\($0.id.rawValue)" } ?? "?"
    }

    /// 记下、放回、丢弃阅读位置换成记录：“记下 1（藏着 宽×高）”“记下 1（显示着）”“放回 1（显示着）”“丢弃 1”，和各自的编号。
    func recordReadingPosition() -> ReadingRecord {
        let calls = ReadingRecord()
        tabs.holdReadingPosition = { [weak self] runtime in
            calls.issued += 1
            let web = runtime.webView
            let state = web.isHidden ? "藏着 \(CatchUpRig.text(web.frame.size))" : "显示着"
            calls.list.append("记下 \(self?.name(runtime) ?? "?")（\(state)）")
            calls.tokens.append(calls.issued)
            return calls.issued
        }
        tabs.restoreReadingPosition = { [weak self] runtime, token, _ in
            let shown = self?.controller.webView === runtime.webView && !runtime.webView.isHidden
            calls.list.append("放回 \(self?.name(runtime) ?? "?")（\(shown ? "显示着" : "没显示")）")
            calls.tokens.append(token)
        }
        tabs.discardReadingPosition = { [weak self] runtime, token in
            calls.list.append("丢弃 \(self?.name(runtime) ?? "?")")
            calls.tokens.append(token)
        }
        return calls
    }

    var containerSize: NSSize {
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        return controller.webView.superview!.bounds.size
    }

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

    func mark() -> Int {
        diagnostics.entries.count
    }

    /// mark 之后写的日志，去掉跟着真实输入写的、运行时自己异步写的 [esc]、[render]，毫秒数换成“…”。
    func lines(since mark: Int) -> [String] {
        diagnostics.entries.dropFirst(mark).filter { !LiveInputLogLines.excludes($0) }
            .map { "[\($0.category)] \($0.message)" }
            .filter { !$0.hasPrefix("[esc]") && !$0.hasPrefix("[render]") }
            .map { $0.replacingOccurrences(of: #"（\d+ms）"#, with: "（…ms）", options: .regularExpression) }
    }
}

@MainActor
private final class ReadingRecord {
    var list: [String] = []
    var tokens: [Int] = []
    var issued = 0
}
