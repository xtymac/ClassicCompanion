import AppKit
import SwiftUI
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 中键点标签关掉它（TabBarHost）。窗口是 TabCloseRig 的从不显示的窗口（有标签栏）；事件只建出来，不发给系统：
/// 照窗口分发鼠标事件的办法，先在窗口里找这一点上的视图（hitTest），再直接交给它（otherMouseDown/Up(with:)）。
/// 不经过 NSWindow.sendEvent 和应用的事件监视，不显示窗口、不动鼠标。真的鼠标（中键的按下和松开是不是送到这里、
/// SwiftUI 会不会先拿走）只能上屏试。
@MainActor
final class TabMiddleClickTests: XCTestCase {
    private func make() throws -> TabCloseRig {
        let name = "TabMiddleClickTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabCloseRig(defaults: try XCTUnwrap(UserDefaults(suiteName: name)), tabBar: true)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        return rig
    }

    /// 窗口里的标签栏（已经排好版）。
    private func host(_ rig: TabCloseRig) throws -> TabBarHost {
        let content = try XCTUnwrap(rig.controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let host = try XCTUnwrap(content.subviews.compactMap { $0 as? TabBarHost }.first)
        XCTAssertFalse(host.isHidden)
        return host
    }

    /// 第 index 个标签（从 0 数）胶囊里的一点（标签栏的坐标）：dx 是从它左边量的横向位置，默认正中。
    private func tabPoint(_ host: TabBarHost, _ index: Int, dx: Double? = nil) -> NSPoint {
        let count = host.rootView.model.items.count
        let width = TabBarRules.tabWidth(availableWidth: host.bounds.width, tabCount: count)
        let left = TabBarRules.sideMargin + Double(index) * (width + TabBarRules.gap)
        return NSPoint(x: left + (dx ?? width / 2), y: host.bounds.midY)
    }

    /// 建一个鼠标事件（不发出去）：位置是标签栏上的 point，键是 button。
    private func event(_ type: NSEvent.EventType, button: Int, at point: NSPoint, in host: TabBarHost) throws -> NSEvent {
        let window = try XCTUnwrap(host.window)
        let location = host.convert(point, to: nil)
        let base = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 0)?.cgEvent)
        base.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        let event = try XCTUnwrap(NSEvent(cgEvent: base))
        XCTAssertEqual(event.type, type)
        XCTAssertEqual(event.buttonNumber, button)
        XCTAssertEqual(event.locationInWindow, location)
        return event
    }

    /// 窗口里这一点（窗口坐标）上的视图，和窗口分发鼠标事件时找的一样。
    private func hitView(_ window: NSWindow, _ location: NSPoint) throws -> NSView {
        let content = try XCTUnwrap(window.contentView)
        return try XCTUnwrap(content.hitTest(try XCTUnwrap(content.superview).convert(location, from: nil)))
    }

    /// 在 down 按下、拖到 up、在 up 松开：每一下都交给窗口在那一点上找到的视图（落在标签栏上的都在标签栏里）。
    private func press(_ host: TabBarHost, button: Int = 2, down: NSPoint, up: NSPoint? = nil) throws {
        let window = try XCTUnwrap(host.window)
        let steps: [(NSEvent.EventType, NSPoint)] = [(.otherMouseDown, down), (.otherMouseDragged, up ?? down),
                                                     (.otherMouseUp, up ?? down)]
        for (type, point) in steps {
            let event = try event(type, button: button, at: point, in: host)
            let target = try hitView(window, event.locationInWindow)
            XCTAssertTrue(target.isDescendant(of: host), "\(type.rawValue) 落在标签栏上")
            switch type {
            case .otherMouseDown: target.otherMouseDown(with: event)
            case .otherMouseDragged: target.otherMouseDragged(with: event)
            default: target.otherMouseUp(with: event)
            }
        }
    }

    /// 三个标签页，选中第 3 个。中键点不选中的第 2 个、再点选中的第 3 个，和点 × 走同一条路：两个窗口一个用中键、一个点 ×，
    /// 日志、剩下的标签页、选中的、标签栏都一样。不选中的那个关掉时不先选中它（没有“选中 【标签2】”这一行）。
    func testAMiddleClickClosesTheTabLikeItsCloseButton() throws {
        let middle = try make(), cross = try make()
        for rig in [middle, cross] {
            _ = rig.add()
            rig.tabs.select(rig.add())
        }
        let host = try host(middle)
        var log: [[String]] = []
        for rig in [middle, cross] {
            let mark = rig.mark()
            if rig === middle {
                try press(host, down: tabPoint(host, 1))
            } else {
                rig.tabs.tabBar.onClose?(rig.tabs.tabs[1].id)
            }
            log.append(rig.lines(since: mark))
            XCTAssertEqual(rig.tabs.tabs.map(\.id.rawValue), [1, 3])
            XCTAssertEqual(rig.tabs.selected.id.rawValue, 3, "选中的不变，也没有先选中第 2 个")
        }
        XCTAssertEqual(log[0], ["[tabs] 关闭（剩 2 个） 【标签2】", "[web] 关闭网页：停止加载 【标签2】"])
        XCTAssertEqual(log[0], log[1])

        log = []
        for rig in [middle, cross] {
            let mark = rig.mark()
            if rig === middle {
                try press(host, down: tabPoint(host, 1, dx: 2))
            } else {
                rig.tabs.tabBar.onClose?(rig.tabs.tabs[1].id)
            }
            log.append(rig.lines(since: mark))
            XCTAssertEqual(rig.tabs.tabs.map(\.id.rawValue), [1])
            XCTAssertEqual(rig.tabs.selected.id.rawValue, 1)
            XCTAssertFalse(rig.controller.isTabBarVisible, "剩一个：标签栏藏起")
        }
        XCTAssertEqual(log[0].first, "[tabs] 关闭（剩 1 个） 【标签3】")
        XCTAssertTrue(log[0].contains("[tabs] 选中 【标签1】"))
        XCTAssertEqual(log[0], log[1])
        XCTAssertEqual(middle.tabs.tabBar.items, cross.tabs.tabBar.items)
    }

    /// 什么都不做（不关、不选中、不写日志）：按下和松开不在同一个标签上（换到别的标签、拖到间距上）；按在 ＋、标签之间的间距、
    /// 左边的边距、＋ 右边的空白、胶囊上下空出来的地方；别的键（左右键之外的 3、4 号键）在标签上按下松开。
    func testOtherPlacesAndOtherButtonsDoNothing() throws {
        let rig = try make()
        _ = rig.add()
        rig.tabs.select(rig.add())
        let host = try host(rig)
        let width = TabBarRules.tabWidth(availableWidth: host.bounds.width, tabCount: 3)
        let afterTabs = TabBarRules.sideMargin + 3 * width + 3 * TabBarRules.gap
        let gapX = TabBarRules.sideMargin + width + TabBarRules.gap / 2
        let mid = host.bounds.midY, above = host.bounds.midY + TabBarView.capsuleHeight / 2 + 1.5
        let below = host.bounds.midY - TabBarView.capsuleHeight / 2 - 1.5
        let ids = rig.tabs.tabs.map(\.id), items = rig.tabs.tabBar.items
        let mark = rig.mark()

        try press(host, down: tabPoint(host, 0), up: tabPoint(host, 1))
        try press(host, down: tabPoint(host, 2), up: NSPoint(x: gapX, y: mid))
        for point in [NSPoint(x: afterTabs + TabBarRules.newTabButtonWidth / 2, y: mid), NSPoint(x: gapX, y: mid),
                      NSPoint(x: TabBarRules.sideMargin / 2, y: mid),
                      NSPoint(x: afterTabs + TabBarRules.newTabButtonWidth + 5, y: mid),
                      NSPoint(x: tabPoint(host, 0).x, y: above), NSPoint(x: tabPoint(host, 0).x, y: below)] {
            XCTAssertNil(host.tab(at: point), "\(point)")
            try press(host, down: point)
        }
        for button in [3, 4] {
            try press(host, button: button, down: tabPoint(host, 0))
        }
        XCTAssertEqual(rig.lines(since: mark), [])
        XCTAssertEqual(rig.tabs.tabs.map(\.id), ids)
        XCTAssertEqual(rig.tabs.tabBar.items, items)
        XCTAssertEqual(rig.tabs.selected.id.rawValue, 3)
    }

    /// 别的东西不受影响：窗口的侧键处理放过中键（只管 3、4），所以中键照样到它落下的地方；网页区域里的一点找到的视图
    /// 不在标签栏里（中键照旧交给网页）；顶部一条上的一点也不在标签栏里。
    func testThePageAndTheSideButtonsAreUnaffected() throws {
        let rig = try make()
        rig.tabs.select(rig.add())
        let host = try host(rig)
        let window = try XCTUnwrap(rig.controller.window)
        for type in [NSEvent.EventType.otherMouseDown, .otherMouseDragged, .otherMouseUp] {
            XCTAssertFalse(rig.controller.handleHistoryMouse(type: type, button: 2, windowNumber: window.windowNumber))
        }
        let content = try XCTUnwrap(window.contentView)
        let web = rig.controller.webAreaFrame
        let inPage = try hitView(window, content.convert(NSPoint(x: web.midX, y: web.midY), to: nil))
        XCTAssertFalse(inPage.isDescendant(of: host))
        XCTAssertTrue(inPage.isDescendant(of: rig.tabs.selected.runtime.webView), "网页区域里是显示着的网页")
        let bar = host.frame.maxY + WebBar.height / 2
        let onTopBar = try hitView(window, content.convert(NSPoint(x: host.frame.midX, y: bar), to: nil))
        XCTAssertFalse(onTopBar.isDescendant(of: host))
    }

    /// 标签栏用的位置和 SwiftUI 真的排出来的一样（只量 NSHostingView，不建窗口）：480 宽、4 个标签，每个标题那一块
    /// （标签左边留 10 点、右边 × 那一块 26 点）的正中、胶囊的左右两头都找得到这个标签，胶囊外面一点（间距、边距）找不到。
    func testTheHitAreaMatchesTheLaidOutTabs() throws {
        let name = "TabMiddleClickTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let appearance = PageAppearance(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        var list = TabList()
        var ids = [list.selected]
        for _ in 0..<3 {
            guard case .added(let id) = list.append(select: false) else { return XCTFail("加不进去") }
            ids.append(id)
        }
        let model = TabBarModel()
        model.update(items: ids.enumerated().map { TabBarModel.Item(id: $1, title: nil, isSelected: $0 == 0) },
                     newTabButton: TabBarRules.NewTabButton(dimmed: false, clickable: true, explainsLimit: false))
        let box = MiddleClickFramesBox()
        let host = TabBarHost(rootView: TabBarView(model: model, appearance: appearance, onTitleFrames: { box.frames = $0 }))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: TabBarView.height)
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while box.frames.count < ids.count, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(Set(box.frames.keys), Set(ids))
        for id in ids {
            let title = try XCTUnwrap(box.frames[id])
            let left = title.minX - 10, right = title.maxX + 26
            XCTAssertEqual(host.tab(at: NSPoint(x: title.midX, y: title.midY)), id)
            XCTAssertEqual(host.tab(at: NSPoint(x: left + 1, y: title.midY)), id)
            XCTAssertEqual(host.tab(at: NSPoint(x: right - 1, y: title.midY)), id)
            XCTAssertNil(host.tab(at: NSPoint(x: left - 1, y: title.midY)))
            XCTAssertNil(host.tab(at: NSPoint(x: right + 1, y: title.midY)))
        }
    }
}

@MainActor
private final class MiddleClickFramesBox {
    var frames: [TabID: CGRect] = [:]
}
