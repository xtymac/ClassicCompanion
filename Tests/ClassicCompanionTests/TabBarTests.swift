import AppKit
import SwiftUI
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 标签栏（阶段 4，最小的一版）：窗口里的位置和显示、藏起时的阅读位置，点按交给 ChatTabs，× 的位置一直留着。
/// 窗口测试用 TabCloseRig 的从不显示的窗口（像 AppDelegate 那样给它标签栏，个数变了时按模型显示或藏起）；
/// 排版测试只量 NSHostingView，不建窗口。不显示窗口、不动鼠标键盘。样子、悬停、真的点按、出现消失时闪不闪只能上屏看。
@MainActor
final class TabBarTests: XCTestCase {
    private func make(tabBar: Bool) throws -> TabCloseRig {
        let name = "TabBarTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabCloseRig(defaults: try XCTUnwrap(UserDefaults(suiteName: name)), tabBar: tabBar)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        return rig
    }

    private func barLines(_ rig: TabCloseRig, since mark: Int) -> [String] {
        rig.lines(since: mark).filter { $0.hasPrefix("[window] 标签栏") }
    }

    /// 只有一个标签页：标签栏藏着，网页区域和没有标签栏的窗口完全一样（就在顶部一条下面）；提示还在最上层。
    func testWithOneTabTheBarIsHiddenAndThePageKeepsItsPlace() throws {
        let plain = try make(tabBar: false), rig = try make(tabBar: true)
        let content = try XCTUnwrap(rig.controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(rig.tabs.tabBar.isShown)
        XCTAssertFalse(rig.controller.isTabBarVisible)
        XCTAssertFalse(plain.controller.isTabBarVisible)
        XCTAssertEqual(rig.controller.webAreaFrame, plain.controller.webAreaFrame)
        XCTAssertEqual(rig.controller.webAreaFrame,
                       NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - WebBar.height))
        XCTAssertTrue(content.subviews.last === rig.controller.hints.host)
    }

    /// 1 → 2：窗口大小不变，网页区域上沿往下 32 点（变矮 32 点），阅读位置记下、放回各一次（都是显示着的那一页）；
    /// 2 → 1：回到原来的位置，也是各一次。各写一行。提示一直在最上层。
    func testASecondTabMakesThePage32PointsShorterAndTheLastCloseGivesItBack() throws {
        let rig = try make(tabBar: true)
        let calls = rig.recordReadingPosition()
        let window = try XCTUnwrap(rig.controller.window)
        let content = try XCTUnwrap(window.contentView)
        let frame = window.frame, before = rig.controller.webAreaFrame
        let mark = rig.mark()

        let b = try XCTUnwrap(rig.tabs.newTab())
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(rig.controller.isTabBarVisible)
        let shorter = rig.controller.webAreaFrame
        XCTAssertEqual(shorter, NSRect(x: before.minX, y: before.minY, width: before.width, height: before.height - 32))
        XCTAssertEqual(rig.controller.webView.frame.size, shorter.size, "换上来的那一页铺满变矮的网页区域")
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(calls.list, ["记下 1（显示着）", "放回 1（显示着）"])
        XCTAssertEqual(barLines(rig, since: mark), ["[window] 标签栏：显示"])
        XCTAssertTrue(content.subviews.last === rig.controller.hints.host)

        rig.tabs.closeTab(b)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(rig.controller.isTabBarVisible)
        XCTAssertEqual(rig.controller.webAreaFrame, before)
        XCTAssertEqual(rig.controller.webView.frame.size, before.size)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(calls.list, ["记下 1（显示着）", "放回 1（显示着）", "记下 1（显示着）", "放回 1（显示着）"])
        XCTAssertEqual(barLines(rig, since: mark), ["[window] 标签栏：显示", "[window] 标签栏：藏起"])
        XCTAssertTrue(content.subviews.last === rig.controller.hints.host)
    }

    /// 点按（视图调用的就是模型上的这几个回调）：点标签选中它；点 × 关掉它（不显示的也能关）；点 ＋ 和 ⌘T 一样新增；
    /// 到上限时点 ＋ 显示到上限的提示、不新增；有模态框时点 ＋ 什么都不做。键盘焦点一直在显示着的网页里。
    func testClicksSelectCloseAndAddAndLeaveTheFocusInThePage() throws {
        let rig = try make(tabBar: true)
        let bar = rig.tabs.tabBar
        let window = try XCTUnwrap(rig.controller.window)
        let b = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertTrue(window.firstResponder === b.runtime.webView)

        bar.onSelect?(rig.first.id)
        XCTAssertTrue(rig.tabs.selected === rig.first)
        XCTAssertEqual(bar.items.map(\.isSelected), [true, false])
        XCTAssertTrue(window.firstResponder === rig.first.runtime.webView)

        bar.onClose?(b.id)
        XCTAssertEqual(rig.tabs.tabs.map(\.id), [rig.first.id], "不显示的那一页关掉了")
        XCTAssertTrue(rig.tabs.selected === rig.first)
        XCTAssertFalse(rig.controller.isTabBarVisible)
        XCTAssertTrue(window.firstResponder === rig.first.runtime.webView)

        bar.onNewTab?()
        XCTAssertEqual(rig.tabs.tabs.count, 2)
        XCTAssertFalse(rig.tabs.selected === rig.first, "新的那一页选中了")
        XCTAssertTrue(window.firstResponder === rig.tabs.selected.runtime.webView)

        rig.controller.isAppModal = { true }
        var mark = rig.mark()
        bar.onNewTab?()
        XCTAssertEqual(rig.tabs.tabs.count, 2)
        XCTAssertEqual(rig.lines(since: mark), [], "有模态框：点的那一刻再看，什么都不做")
        rig.controller.isAppModal = { false }

        bar.onNewTab?()
        bar.onNewTab?()
        XCTAssertTrue(rig.tabs.list.isFull)
        XCTAssertTrue(bar.newTabButton.dimmed)
        let full = rig.tabs.tabs.map(\.id), selected = rig.tabs.selected
        mark = rig.mark()
        bar.onNewTab?()
        XCTAssertEqual(rig.tabs.tabs.map(\.id), full)
        XCTAssertTrue(rig.tabs.selected === selected)
        XCTAssertEqual(rig.limitHints, 1)
        XCTAssertEqual(rig.lines(since: mark), ["[tabs] 不新增标签页：已到上限（4 个）", "[hint] 显示 到上限（4 个）的提示"])
        XCTAssertTrue(window.firstResponder === selected.runtime.webView)
    }

    /// 只量 NSHostingView（不建窗口）：480 宽、4 个标签时标签栏 32 点高；鼠标在不在标签上（× 显示、藏起），
    /// 每个标题那一块的位置都一样，选中的（× 一直显示）和不选中的一样宽：× 的位置一直留着。宿主视图不当第一响应者。
    func testTheTitleKeepsItsPlaceWhenTheCloseButtonShows() throws {
        let name = "TabBarTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let appearance = PageAppearance(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        var list = TabList()
        var ids = [list.selected]
        for _ in 0..<3 {
            guard case .added(let id) = list.append(select: false) else { return XCTFail("加不进去") }
            ids.append(id)
        }
        let model = TabBarModel()
        model.update(items: ids.enumerated().map { index, id in
            TabBarModel.Item(id: id, title: index == 2 ? nil : String(repeating: "A long tab title ", count: 3),
                             isSelected: index == 0)
        }, newTabButton: TabBarRules.NewTabButton(dimmed: false, clickable: true, explainsLimit: false))

        func titleFrames(hovered: TabID?) throws -> [TabID: CGRect] {
            let box = FramesBox()
            let view = TabBarView(model: model, appearance: appearance, hovered: hovered, onTitleFrames: { box.frames = $0 })
            let host = TabBarHost(rootView: view)
            XCTAssertFalse(host.acceptsFirstResponder)
            XCTAssertEqual(host.fittingSize.height, TabBarView.height)
            host.frame = NSRect(x: 0, y: 0, width: 480, height: TabBarView.height)
            host.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(2)
            while box.frames.count < ids.count, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            return box.frames
        }

        let resting = try titleFrames(hovered: nil)
        let hovering = try titleFrames(hovered: ids[1])
        XCTAssertEqual(Set(resting.keys), Set(ids))
        XCTAssertEqual(resting, hovering)
        // 103.5 宽的标签：左边留 10 点，右边 × 那一块 26 点（4 + 16 + 6）。
        let tab = TabBarRules.tabWidth(availableWidth: 480, tabCount: 4)
        for id in ids {
            let frame = try XCTUnwrap(resting[id])
            XCTAssertEqual(frame.width, tab - 10 - 26, accuracy: 0.5, "\(id)")
            XCTAssertEqual(frame.height, TabBarView.capsuleHeight, accuracy: 0.5, "\(id)")
        }
    }
}

@MainActor
private final class FramesBox {
    var frames: [TabID: CGRect] = [:]
}
