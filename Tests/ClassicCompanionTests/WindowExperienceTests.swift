import AppKit
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// ⌘M、启动画面、完整窗口大小和页面缩放。实际系统行为要在真实安装包上验证，这里不能代替。
final class WindowExperienceTests: XCTestCase {
    @MainActor private func makeController() -> ChatWindowController {
        let controller = ChatWindowController(webView: WKWebView(), toolbar: EmptyView(), diagnostics: Diagnostics())
        addTeardownBlock { @MainActor in controller.window?.orderOut(nil) }
        return controller
    }

    private func makeDefaults() -> UserDefaults {
        let name = "WindowExperienceTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    // MARK: - 切换动画

    /// 用户选了 C（2026-11-08）：小窗和完整窗口之间的动画从系统给的 0.19 秒缩到约 0.1 秒。仍然有动画，不是直接跳。
    @MainActor func testModeSwitchAnimationTakesAboutATenthOfASecond() throws {
        let window = try XCTUnwrap(makeController().window)
        window.setFrame(NSRect(x: 100, y: 300, width: 640, height: 720), display: false)
        let full = NSRect(x: 100, y: 120, width: 1280, height: 900)
        XCTAssertLessThanOrEqual(window.animationResizeTime(full), 0.1 + 0.0001)
        XCTAssertGreaterThan(window.animationResizeTime(full), 0)
    }

    // MARK: - ⌘M

    /// ⌘M 后应用仍在前台却没有窗口：已激活的应用再用 ⌘Tab 切入不会有任何通知。
    @MainActor func testMiniaturizingTheChatWindowIsReported() {
        let controller = makeController()
        var reports = 0
        controller.onDidMiniaturize = { reports += 1 }
        controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
        XCTAssertEqual(reports, 1)
    }

    // MARK: - 启动画面，没有隐私遮罩（用户 2026-11-07：“按你的建议，全部移除”）

    /// 小窗和完整窗口都直接显示官方网页，任何时候都不盖住。
    @MainActor func testThePageIsShownInBothModes() {
        let controller = makeController()
        controller.show(mode: .quick)
        XCTAssertFalse(controller.isShowingLaunchScreen)
        controller.show(mode: .full)
        XCTAssertFalse(controller.isShowingLaunchScreen)
    }

    @MainActor func testLaunchScreenShowsUntilThePageLoads() {
        let controller = makeController()
        controller.beginLaunchScreen()
        controller.show(mode: .quick)
        XCTAssertTrue(controller.isShowingLaunchScreen, "网页加载前显示启动画面，不露出空白")
        controller.endLaunchScreen("网页已加载")
        XCTAssertFalse(controller.isShowingLaunchScreen)
    }

    /// 加载很慢或失败时也不能一直挡着：到时限就露出网页本身（官方页面自己显示加载或错误）。
    @MainActor func testLaunchScreenGivesWayAfterTheLimit() {
        let controller = makeController()
        controller.launchScreenLimit = 0.05
        controller.beginLaunchScreen()
        let deadline = Date().addingTimeInterval(2)
        while controller.isShowingLaunchScreen, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(controller.isShowingLaunchScreen)
    }

    /// 焦点不在网页时按 Esc 隐藏窗口。原来遮罩显示时 Esc 会改去关闭被遮住的弹层。
    @MainActor func testWindowEscapeHidesTheWindow() throws {
        let controller = makeController()
        controller.show(mode: .quick)
        let window = try XCTUnwrap(controller.window as? ChatWindow)
        XCTAssertTrue(window.isVisible)
        window.onCancel?()
        XCTAssertFalse(window.isVisible)
    }

    // MARK: - 完整窗口大小

    @MainActor func testFullWindowDefaultSize() {
        XCTAssertEqual(ChatWindowController.fullSize, NSSize(width: 1280, height: 900))
    }

    func testFullWindowSizeIsRemembered() {
        let store = FullWindowSizeStore(defaults: makeDefaults(), minimumWidth: 900)
        XCTAssertNil(store.size)
        store.remember(NSSize(width: 1500, height: 1000))
        XCTAssertEqual(store.size, NSSize(width: 1500, height: 1000))
    }

    /// 完整模式可以缩到 900 以下，但下次切到完整模式不该得到这么小的窗口。
    func testNarrowFullWindowIsNotRemembered() {
        let store = FullWindowSizeStore(defaults: makeDefaults(), minimumWidth: 900)
        store.remember(NSSize(width: 1500, height: 1000))
        store.remember(NSSize(width: 700, height: 600))
        XCTAssertEqual(store.size, NSSize(width: 1500, height: 1000))
    }

    @MainActor func testResizingFullWindowByHandIsRemembered() {
        let controller = makeController()
        controller.fullSizes = FullWindowSizeStore(defaults: makeDefaults(), minimumWidth: 900)
        controller.show(mode: .full)
        let window = controller.window!
        controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification))
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1000, height: 700)), display: false)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
        XCTAssertEqual(controller.fullSizes.size, NSSize(width: 1000, height: 700))
    }

    /// 切模式的缩放动画也会发 live resize 通知。它不是手动调整，小屏收窄后的尺寸尤其不能被记住。
    @MainActor func testSwitchingToFullIsNotRememberedAsManualResize() {
        let controller = makeController()
        controller.fullSizes = FullWindowSizeStore(defaults: makeDefaults(), minimumWidth: 900)
        controller.show(mode: .quick)
        controller.show(mode: .full)
        XCTAssertEqual(controller.window?.frame.width, ChatWindowController.fullSize.width)
        XCTAssertNil(controller.fullSizes.size)
    }

    @MainActor func testResizingQuickWindowIsNotRememberedAsFullSize() {
        let controller = makeController()
        controller.fullSizes = FullWindowSizeStore(defaults: makeDefaults(), minimumWidth: 900)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
        XCTAssertNil(controller.fullSizes.size)
    }

    /// 靠近屏幕边缘的小窗切到完整窗口时会被推开，切回来不能留在被推开的位置。
    @MainActor func testReturningFromFullRestoresQuickPosition() throws {
        let controller = makeController()
        controller.show(mode: .quick)
        let window = try XCTUnwrap(controller.window)
        let visible = try XCTUnwrap(window.screen).visibleFrame
        let origin = NSPoint(x: visible.minX + 10, y: visible.maxY - window.frame.height - 10)
        window.setFrameOrigin(origin)
        controller.show(mode: .full)
        controller.show(mode: .quick)
        XCTAssertEqual(window.frame.origin, origin)
    }

    // MARK: - 找回最小化或隐藏的窗口

    /// 用户反馈（2026-11-07）：隐藏后找回，窗口不在原来的位置。
    /// xctest 不运行 NSApp，窗口不能真正最小化，那条路径由下面的判定测试和真实应用覆盖。
    @MainActor func testRevealingAHiddenFullWindowKeepsItsPosition() throws {
        let (controller, window) = try quickWindowAwayFromEdges()
        controller.show(mode: .full)
        let moved = try cornerOrigin(of: window)
        window.setFrameOrigin(moved)
        controller.hide(reason: "测试")
        controller.reveal()
        XCTAssertEqual(window.frame.origin, moved)
    }

    /// 快捷键唤醒走记住的位置，⌘M 不经过 hide()，要在最小化前记下。
    @MainActor func testMinimizingRemembersTheQuickPosition() throws {
        let (controller, window) = try quickWindowAwayFromEdges()
        let moved = try cornerOrigin(of: window)
        window.setFrameOrigin(moved)
        controller.windowWillMiniaturize(Notification(name: NSWindow.willMiniaturizeNotification))
        window.orderOut(nil)
        window.setFrameOrigin(NSPoint(x: moved.x + 50, y: moved.y + 50))
        controller.show(mode: .quick)
        XCTAssertEqual(window.frame.origin, moved)
    }

    func testRevealKeepsAMinimizedWindowWhereverTheMouseIs() {
        for mode in [ChatWindowController.Mode.quick, .full] {
            XCTAssertTrue(ChatWindowController.keepsPositionOnReveal(mode: mode, miniaturized: true, onTargetScreen: false))
        }
    }

    func testRevealMovesAHiddenFullWindowToTheMouseScreen() {
        XCTAssertTrue(ChatWindowController.keepsPositionOnReveal(mode: .full, miniaturized: false, onTargetScreen: true))
        XCTAssertFalse(ChatWindowController.keepsPositionOnReveal(mode: .full, miniaturized: false, onTargetScreen: false))
    }

    func testRevealPlacesAHiddenQuickWindowByTheRememberedPosition() {
        XCTAssertFalse(ChatWindowController.keepsPositionOnReveal(mode: .quick, miniaturized: false, onTargetScreen: true))
    }

    /// 屏幕左下角附近：不是任何默认位置，也不是记住的位置。
    @MainActor private func cornerOrigin(of window: NSWindow) throws -> NSPoint {
        let visible = try XCTUnwrap(window.screen).visibleFrame
        return NSPoint(x: visible.minX + 23, y: visible.minY + 17)
    }

    // MARK: - 唤醒快捷键保持上次模式（用户 2026-11-14：默认“保持上次模式”，不设时限）

    /// 完整窗口隐藏后按唤醒键：仍是完整窗口，大小和位置不变（同一块屏幕）。改动前这里会变回小窗。
    @MainActor func testHotKeyWakeKeepsTheFullWindowByDefault() throws {
        let (controller, window) = try quickWindowAwayFromEdges()
        controller.show(mode: .full)
        let moved = try cornerOrigin(of: window)
        window.setFrameOrigin(moved)
        let full = window.frame
        controller.hide(reason: "唤醒快捷键")
        controller.toggle(wake: .keepLast)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(controller.mode, .full)
        XCTAssertEqual(window.frame, full)
    }

    @MainActor func testHotKeyWakeKeepsTheQuickWindow() throws {
        let (controller, window) = try quickWindowAwayFromEdges()
        let before = window.frame
        controller.hide(reason: "唤醒快捷键")
        controller.toggle(wake: .keepLast)
        XCTAssertEqual(controller.mode, .quick)
        XCTAssertEqual(window.frame, before)
    }

    /// 每个隐藏入口都一样：Esc、⌘W、顶部和红色关闭按钮、网页 Esc 都走 hide()，不改模式。
    @MainActor func testEveryHideEntryKeepsTheFullWindowForTheHotKey() throws {
        let entries: [(String, @MainActor (ChatWindowController, NSWindow) -> Void)] = [
            ("唤醒快捷键", { c, _ in c.hide(reason: "唤醒快捷键") }),
            ("⌘W", { c, _ in c.hide(reason: "⌘W") }),
            ("窗口 Esc", { _, w in w.makeFirstResponder(nil); w.cancelOperation(nil) }),   // 焦点不在网页时
            ("网页 Esc", { c, _ in c.hide(reason: "网页 Esc") }),
            ("顶部关闭按钮", { c, _ in c.hide(reason: "顶部关闭按钮") }),
            ("红色关闭按钮", { c, w in XCTAssertFalse(c.windowShouldClose(w)) }),
        ]
        for (name, hide) in entries {
            let (controller, window) = try quickWindowAwayFromEdges()
            controller.show(mode: .full)
            let full = window.frame
            hide(controller, window)
            XCTAssertFalse(window.isVisible, name)
            controller.toggle(wake: .keepLast)
            XCTAssertEqual(controller.mode, .full, name)
            XCTAssertEqual(window.frame.size, full.size, name)
            controller.hide(reason: "测试")
        }
    }

    /// 选“总是小窗”：完整窗口隐藏后按唤醒键回到小窗，放在记住的小窗位置；改回来后又保持完整窗口。
    @MainActor func testAlwaysQuickReturnsToQuickAndSwitchingBackKeepsFull() throws {
        let (controller, window) = try quickWindowAwayFromEdges()
        let quick = window.frame
        controller.show(mode: .full)
        controller.hide(reason: "唤醒快捷键")
        controller.toggle(wake: .alwaysQuick)
        XCTAssertEqual(controller.mode, .quick)
        XCTAssertEqual(window.frame, quick)
        controller.show(mode: .full)
        controller.hide(reason: "唤醒快捷键")
        controller.toggle(wake: .keepLast)
        XCTAssertEqual(controller.mode, .full)
    }

    /// 窗口还在动画、网页还在排版时就隐藏：按用户最后一次的选择叫出来。
    @MainActor func testHidingMidSwitchWakesInTheChosenMode() throws {
        let (controller, window, _, page) = try switchFixture()
        controller.show(mode: .full)              // 网页还没排好，窗口还没动
        controller.hide(reason: "唤醒快捷键")
        controller.toggle(wake: .keepLast)
        XCTAssertEqual(controller.mode, .full)
        XCTAssertEqual(window.frame.size, ChatWindowController.fullSize)
        XCTAssertFalse(controller.isShowingFrozenPage)
        page.finishLayout.forEach { $0() }        // 网页晚到的回答不再改窗口
        XCTAssertEqual(window.frame.size, ChatWindowController.fullSize)
        controller.show(mode: .quick)             // 又切回小窗，还没缩小就隐藏
        controller.hide(reason: "⌘W")
        controller.toggle(wake: .keepLast)
        XCTAssertEqual(controller.mode, .quick)
        XCTAssertEqual(window.frame.size, ChatWindowController.quickSize)
    }

    // MARK: - 放大缩小时窗口不位移

    private func topLeft(_ frame: NSRect) -> NSPoint { NSPoint(x: frame.minX, y: frame.maxY) }

    /// 小窗放在离屏幕左上角不远处，完整窗口向右下放大时放得下。
    @MainActor private func quickWindowAwayFromEdges() throws -> (ChatWindowController, NSWindow) {
        let controller = makeController()
        controller.fullSizes = FullWindowSizeStore(defaults: makeDefaults(), minimumWidth: 900)
        controller.show(mode: .quick)
        let window = try XCTUnwrap(controller.window)
        let visible = try XCTUnwrap(window.screen).visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.minX + 40, y: visible.maxY - 40 - window.frame.height))
        return (controller, window)
    }

    // MARK: - 切模式不露出空白

    /// 用户：放大缩小的时候窗口内容会有一些空白。录屏：窗口到位后网页还要约 0.4 秒才画出新排版，
    /// 新露出的区域是 WebKit 自己画的底色（红色实验：改网页底色、窗口背景或下层视图都不影响它）。
    @MainActor private final class PageStub {
        var image: NSImage? = NSImage(size: NSSize(width: 10, height: 10))
        var requested: [NSSize] = []
        var finishLayout: [@MainActor () -> Void] = []
    }

    @MainActor private func switchFixture() throws -> (ChatWindowController, NSWindow, WKWebView, PageStub) {
        let web = WKWebView()
        // 工具栏要有固有高度：没有高度时布局引擎可以任意分配它和网页的高度，算出来的边框高度是错的。
        let toolbar = Color.clear.frame(height: 40)
        let controller = ChatWindowController(webView: web, toolbar: toolbar, diagnostics: Diagnostics())
        addTeardownBlock { @MainActor in controller.window?.orderOut(nil) }
        controller.fullSizes = FullWindowSizeStore(defaults: makeDefaults(), minimumWidth: 900)
        controller.show(mode: .quick)
        let window = try XCTUnwrap(controller.window)
        let visible = try XCTUnwrap(window.screen).visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.minX + 40, y: visible.maxY - 40 - window.frame.height))
        window.contentView?.layoutSubtreeIfNeeded()
        let page = PageStub()
        controller.onSnapshotPage = { done in done(page.image) }
        controller.onPrepareLayout = { size, done in
            page.requested.append(size)
            page.finishLayout.append(done)
        }
        return (controller, window, web, page)
    }

    /// 网页是否贴着窗口内容区的右边和下边：切换结束后不能留下临时的固定大小。
    @MainActor private func assertWebFollowsWindow(_ web: WKWebView, _ window: NSWindow, line: UInt = #line) throws {
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(web.frame.maxX, content.bounds.maxX, line: line)
        XCTAssertEqual(web.frame.minY, content.bounds.minY, line: line)
    }

    /// 用户（1442）选了“窗口先动”：按下后窗口立刻变大小，网页随后排好。
    /// 网页排好之前，旧画面和页面底色盖着整个网页区域，不露出 WebKit 自己画的那块比页面亮的空白。
    @MainActor func testWindowGrowsRightAwayWhileThePageCatchesUp() throws {
        let (controller, window, web, page) = try switchFixture()
        controller.show(mode: .full)
        XCTAssertEqual(window.frame.size, ChatWindowController.fullSize, "不等网页，窗口先到位")
        XCTAssertEqual(controller.mode, .full)
        XCTAssertTrue(controller.isShowingFrozenPage, "网页还没排好，继续盖着")
        XCTAssertEqual(page.requested.first?.width, ChatWindowController.fullSize.width)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(web.frame.width, ChatWindowController.fullSize.width, "网页已按目标大小排版")
        let cover = try XCTUnwrap(controller.frozenPageFrame)
        XCTAssertTrue(cover.contains(web.frame), "新露出的区域也盖着")
        XCTAssertEqual(controller.frozenPageBackground, window.backgroundColor, "盖着的底色就是页面底色")
        page.finishLayout[0]()
        XCTAssertEqual(window.frame.size, ChatWindowController.fullSize)
        XCTAssertFalse(controller.isShowingFrozenPage)
        try assertWebFollowsWindow(web, window)
    }

    @MainActor func testPageAskedForTheRoomInsideTheWindow() throws {
        let (controller, window, web, page) = try switchFixture()
        let chrome = window.frame.height - web.frame.height
        controller.show(mode: .full)
        XCTAssertEqual(page.requested.first?.height, ChatWindowController.fullSize.height - chrome)
    }

    /// 放大时一开始就露出新排版，缩小时旧画面留到窗口缩好：两个方向都不露出网页以外的区域。
    @MainActor private func frozenDuringResize(of window: NSWindow, _ controller: ChatWindowController, while body: () -> Void) -> [Bool] {
        nonisolated(unsafe) var seen: [Bool] = []
        nonisolated(unsafe) let watched = controller
        // 通知在主线程同步发出：动画期间 setFrame 不返回。
        let token = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: nil) { _ in
            MainActor.assumeIsolated { seen.append(watched.isShowingFrozenPage) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        body()
        return seen
    }

    @MainActor func testGrowingKeepsThePageCoveredDuringTheAnimation() throws {
        let (controller, window, _, _) = try switchFixture()
        let seen = frozenDuringResize(of: window, controller) { controller.show(mode: .full) }
        XCTAssertFalse(seen.isEmpty)
        XCTAssertFalse(seen.contains(false), "放大途中网页还没排好，一直盖着")
    }

    @MainActor func testShrinkingRightAwayKeepsTheOldPictureUntilThePageIsReady() throws {
        let (controller, window, web, page) = try switchFixture()
        controller.show(mode: .full)
        page.finishLayout[0]()
        let chrome = window.frame.height - web.frame.height
        let seen = frozenDuringResize(of: window, controller) { controller.show(mode: .quick) }
        XCTAssertFalse(seen.isEmpty)
        XCTAssertFalse(seen.contains(false), "缩小途中不能拿掉旧画面")
        XCTAssertEqual(window.frame.size, ChatWindowController.quickSize, "不等网页，窗口先到位")
        XCTAssertEqual(page.requested.last?.height, ChatWindowController.quickSize.height - chrome)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(web.frame.width, ChatWindowController.quickSize.width)
        XCTAssertTrue(controller.isShowingFrozenPage, "网页还没排好：旧画面继续盖着")
        page.finishLayout[1]()
        XCTAssertFalse(controller.isShowingFrozenPage)
        try assertWebFollowsWindow(web, window)
    }

    /// 快照要留下切换前的画面：通知模式变化之后，工具条等界面就开始变化。
    @MainActor func testSnapshotIsRequestedBeforeTheModeIsAnnounced() throws {
        let (controller, _, _, page) = try switchFixture()
        var order: [String] = []
        controller.onWillChangeLayout = { order.append("保存阅读位置") }
        controller.onSnapshotPage = { done in
            order.append("快照")
            done(page.image)
        }
        controller.onWillShow = { _ in order.append("模式") }
        controller.show(mode: .full)
        XCTAssertEqual(order, ["保存阅读位置", "快照", "模式"])
    }

    @MainActor func testLateSnapshotStillStartsTheLayout() throws {
        let (controller, _, _, page) = try switchFixture()
        var deliver: (@MainActor (NSImage?) -> Void)?
        controller.onSnapshotPage = { deliver = $0 }
        let quick = try XCTUnwrap(controller.window).frame
        controller.show(mode: .full)
        XCTAssertTrue(page.requested.isEmpty, "旧画面盖上之前网页不能变大小")
        XCTAssertEqual(controller.window?.frame, quick, "快照拍下之前窗口也不能动")
        XCTAssertFalse(controller.isShowingFrozenPage)
        deliver?(page.image)
        XCTAssertEqual(page.requested.count, 1)
        XCTAssertTrue(controller.isShowingFrozenPage)
        XCTAssertEqual(controller.window?.frame.size, ChatWindowController.fullSize)
    }

    /// 阅读位置要等网页排好再放回：窗口先到位时网页还是旧排版。
    @MainActor func testReadingPositionComesBackAfterThePageIsReady() throws {
        let (controller, _, _, page) = try switchFixture()
        var restored = 0
        controller.onDidChangeLayout = { restored += 1 }
        controller.show(mode: .full)
        XCTAssertEqual(restored, 0)
        page.finishLayout[0]()
        XCTAssertEqual(restored, 1)
    }

    /// 网页很忙时不能让窗口一直不动：到时限就按原来的方式切换。
    @MainActor func testPageThatNeverAnswersStillSwitches() throws {
        let (controller, window, web, _) = try switchFixture()
        controller.layoutWaitLimit = 0.05
        controller.show(mode: .full)
        let deadline = Date().addingTimeInterval(2)
        while controller.isShowingFrozenPage, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(window.frame.size, ChatWindowController.fullSize)
        XCTAssertFalse(controller.isShowingFrozenPage, "到时限就拿掉旧画面")
        try assertWebFollowsWindow(web, window)
    }

    /// 2209 实测：启动后第一次切换，真实页面约 1.1 秒才排好，0.7 秒时限到后退回旧行为，空白又露出来。
    @MainActor func testWaitLimitCoversTheFirstSwitchAfterLaunch() {
        XCTAssertGreaterThanOrEqual(makeController().layoutWaitLimit, 1.5)
    }

    @MainActor func testSnapshotThatNeverArrivesStillSwitches() throws {
        let (controller, window, _, page) = try switchFixture()
        controller.layoutWaitLimit = 0.05
        controller.onSnapshotPage = { _ in }
        controller.show(mode: .full)
        let deadline = Date().addingTimeInterval(2)
        while window.frame.width != ChatWindowController.fullSize.width, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(window.frame.size, ChatWindowController.fullSize)
        XCTAssertTrue(page.requested.isEmpty)
    }

    @MainActor func testFailedSnapshotSwitchesStraightAway() throws {
        let (controller, window, web, page) = try switchFixture()
        page.image = nil
        controller.show(mode: .full)
        XCTAssertEqual(window.frame.size, ChatWindowController.fullSize)
        XCTAssertTrue(page.requested.isEmpty)
        XCTAssertFalse(controller.isShowingFrozenPage)
        try assertWebFollowsWindow(web, window)
    }

    @MainActor func testHidingDuringTheWaitEndsTheSwitch() throws {
        let (controller, window, web, page) = try switchFixture()
        controller.show(mode: .full)
        controller.hide(reason: "测试")
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.frame.size, ChatWindowController.fullSize)
        XCTAssertFalse(controller.isShowingFrozenPage)
        try assertWebFollowsWindow(web, window)
        page.finishLayout[0]()   // 网页晚到的回答不能再弹出或移动窗口
        XCTAssertFalse(window.isVisible)
    }

    /// 还没缩小就隐藏时，不能把完整窗口当成小窗位置记下来。
    @MainActor func testHidingWhileShrinkingRemembersTheQuickWindow() throws {
        let (controller, window, _, page) = try switchFixture()
        controller.show(mode: .full)
        page.finishLayout[0]()
        let before = topLeft(window.frame)
        controller.show(mode: .quick)
        controller.hide(reason: "测试")
        controller.show(mode: nil)
        XCTAssertEqual(window.frame.size, ChatWindowController.quickSize)
        XCTAssertEqual(topLeft(window.frame), before)
    }

    /// 快照还没拍好时窗口还没动，这时再按不算数（几十毫秒）。
    @MainActor func testSecondSwitchBeforeTheWindowMovesIsIgnored() throws {
        let (controller, _, _, page) = try switchFixture()
        controller.onSnapshotPage = { _ in }
        controller.toggleMode()
        XCTAssertEqual(controller.mode, .full)
        controller.toggleMode()
        XCTAssertEqual(controller.mode, .full, "窗口还没动之前再按不算数")
        XCTAssertTrue(page.requested.isEmpty)
    }

    /// 窗口已经到位、网页还在排版时，用户看到的是已经切换好的窗口：再按就切回去，不能没反应。
    @MainActor func testSwitchingBackWhileThePageCatchesUpWorks() throws {
        let (controller, window, web, page) = try switchFixture()
        controller.toggleMode()
        XCTAssertEqual(window.frame.size, ChatWindowController.fullSize)
        controller.toggleMode()
        XCTAssertEqual(controller.mode, .quick)
        XCTAssertEqual(window.frame.size, ChatWindowController.quickSize)
        XCTAssertEqual(page.requested.count, 2)
        page.finishLayout[1]()
        XCTAssertFalse(controller.isShowingFrozenPage)
        try assertWebFollowsWindow(web, window)
    }

    /// 快捷键唤醒不走 toggleMode：先结束上一次切换，再开始新的。
    @MainActor func testShowDuringTheWaitFinishesTheFirstSwitch() throws {
        let (controller, window, web, page) = try switchFixture()
        controller.show(mode: .full)
        controller.show(mode: .quick)
        XCTAssertEqual(window.frame.size, ChatWindowController.quickSize)
        XCTAssertEqual(page.requested.count, 2)
        page.finishLayout[0]()   // 上一次网页晚到的回答不能结束这一次
        XCTAssertTrue(controller.isShowingFrozenPage)
        page.finishLayout[1]()
        XCTAssertFalse(controller.isShowingFrozenPage)
        try assertWebFollowsWindow(web, window)
    }

    @MainActor func testGrabbingTheWindowEdgeDuringTheWaitEndsTheSwitch() throws {
        let (controller, window, web, _) = try switchFixture()
        controller.show(mode: .full)
        controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification))
        XCTAssertEqual(window.frame.size, ChatWindowController.fullSize)
        XCTAssertFalse(controller.isShowingFrozenPage)
        try assertWebFollowsWindow(web, window)
    }

    /// 关闭增强或还没接上网页时，行为和以前相同。
    @MainActor func testWithoutThePageHooksTheWindowSwitchesAtOnce() throws {
        let (controller, window, _, _) = try switchFixture()
        controller.onSnapshotPage = nil
        controller.show(mode: .full)
        XCTAssertEqual(window.frame.size, ChatWindowController.fullSize)
    }

    /// 用户：完整模式放大和缩小的时候会出现位移。标题栏和红绿灯应该留在原处。
    @MainActor func testGrowingToFullKeepsTopLeft() throws {
        let (controller, window) = try quickWindowAwayFromEdges()
        let before = topLeft(window.frame)
        controller.show(mode: .full)
        XCTAssertEqual(window.frame.width, ChatWindowController.fullSize.width)
        XCTAssertEqual(topLeft(window.frame), before)
    }

    @MainActor func testShrinkingToQuickKeepsTopLeftWithoutMoving() throws {
        let (controller, window) = try quickWindowAwayFromEdges()
        let before = topLeft(window.frame)
        controller.show(mode: .full)
        controller.show(mode: .quick)
        XCTAssertEqual(topLeft(window.frame), before)
        XCTAssertEqual(window.frame.size, ChatWindowController.quickSize)
    }

    /// 用户拖动过完整窗口，缩小时不能跳回小窗的旧位置。
    @MainActor func testShrinkingAfterMovingFullWindowStaysWhereTheUserPutIt() throws {
        let (controller, window) = try quickWindowAwayFromEdges()
        controller.show(mode: .full)
        window.setFrameOrigin(NSPoint(x: window.frame.minX + 60, y: window.frame.minY - 30))
        let moved = topLeft(window.frame)
        controller.show(mode: .quick)
        XCTAssertEqual(topLeft(window.frame), moved)
    }

    /// 小窗拖宽进入完整模式后缩小，同样不能跳走。
    @MainActor func testShrinkingAfterDraggingQuickWideStaysInPlace() throws {
        let (controller, window) = try quickWindowAwayFromEdges()
        controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification))
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 950, height: 720)), display: false)
        controller.enterFullIfDraggedWide()
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
        XCTAssertEqual(controller.mode, .full)
        let before = topLeft(window.frame)
        controller.show(mode: .quick)
        XCTAssertEqual(topLeft(window.frame), before)
    }

    /// 放不下时才推开，而且一次到位：窗口不能先动到屏幕外再跳回来。
    @MainActor func testGrowingNearScreenEdgeNeverLeavesTheScreen() throws {
        let (controller, window) = try quickWindowAwayFromEdges()
        let visible = try XCTUnwrap(window.screen).visibleFrame
        let origin = NSPoint(x: visible.maxX - window.frame.width - 10, y: visible.minY + 10)
        window.setFrameOrigin(origin)
        var frames: [NSRect] = []
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: nil) { _ in
            MainActor.assumeIsolated { frames.append(window.frame) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.show(mode: .full)
        XCTAssertFalse(frames.isEmpty)
        for frame in frames { XCTAssertTrue(visible.contains(frame), "\(frame) 超出 \(visible)") }

        controller.show(mode: .quick)
        XCTAssertEqual(window.frame.origin, origin, "没移动过就回到原来的位置")
    }

    // MARK: - 窗口大小变化时保持阅读位置

    /// 实测：小窗 → 完整窗口 → 小窗一个来回，对话跳走约半屏。必须在网页开始变化之前记下位置。
    @MainActor func testSwitchingModesHoldsReadingPositionAroundTheResize() throws {
        let (controller, window) = try quickWindowAwayFromEdges()
        var events: [String] = []
        controller.onWillChangeLayout = { events.append("hold \(Int(window.frame.width))") }
        controller.onWillShow = { _ in events.append("willShow") }
        controller.onDidChangeLayout = { events.append("restore \(Int(window.frame.width))") }
        controller.show(mode: .full)
        XCTAssertEqual(events, ["hold 640", "willShow", "restore 1280"])
    }

    @MainActor func testHiddenModeSwitchDoesNotHoldReadingPosition() throws {
        let (controller, window) = try quickWindowAwayFromEdges()
        window.orderOut(nil)
        var holds = 0
        controller.onWillChangeLayout = { holds += 1 }
        controller.show(mode: .full)
        XCTAssertEqual(holds, 0)
    }

    @MainActor func testShowingWithoutModeChangeDoesNotHoldReadingPosition() throws {
        let (controller, _) = try quickWindowAwayFromEdges()
        var holds = 0
        controller.onWillChangeLayout = { holds += 1 }
        controller.show(mode: .quick)
        controller.show(mode: nil)
        XCTAssertEqual(holds, 0)
    }

    @MainActor func testResizingByHandHoldsReadingPosition() throws {
        let (controller, _) = try quickWindowAwayFromEdges()
        var events: [String] = []
        controller.onWillChangeLayout = { events.append("hold") }
        controller.onDidChangeLayout = { events.append("restore") }
        controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification))
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
        XCTAssertEqual(events, ["hold", "restore"])
    }

    // MARK: - 页面缩放

    @MainActor func testWebViewStartsAtSavedZoom() {
        let settings = AppSettings()
        let saved = settings.pageZoom
        addTeardownBlock { @MainActor in settings.pageZoom = saved }
        settings.pageZoom = 1.25
        XCTAssertEqual(WebRuntime(diagnostics: Diagnostics(), settings: settings).webView.pageZoom, 1.25)
    }

    @MainActor func testChangingZoomUpdatesTheWebView() {
        let settings = AppSettings()
        let saved = settings.pageZoom
        addTeardownBlock { @MainActor in settings.pageZoom = saved }
        let web = WebRuntime(diagnostics: Diagnostics(), settings: settings)
        web.setPageZoom(1.5)
        XCTAssertEqual(web.webView.pageZoom, 1.5)
    }
}
