import AppKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 新对话（⌘N、文件菜单、顶部的按钮、菜单栏图标的菜单，都经 ChatTabs.newChat()）开在新标签页（用户 11-22 定）：
/// - 有空位：和 ⌘T 同一条路（newTab()），原来选中的那一页不动；
/// - 到上限：不加标签页，照原来在选中的那一页里新建，不提示到上限。
/// 启动画面还在时照原来新建的那一条在 LaunchWiringTests（testNewChatLoadsTheHomePageOrFocusesAfterAnInPageSwitch）。
/// 替身见 TabCloseRig（TabCloseEntryTests.swift）：加载请求只记下来，找回窗口只记一行，不显示窗口。
@MainActor
final class NewChatTabTests: XCTestCase {
    private func make() throws -> TabCloseRig {
        let name = "NewChatTabTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabCloseRig(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
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

    /// 有空位（1–3 个标签页，选中的是最左的 1）：新对话加一个标签页，放在最右、选中、窗口显示它、盖着新标签页的遮挡、
    /// 加载新对话页，窗口是 key 窗口就聚焦它，第一次有多个标签页的提示照常；窗口没显示时先找回窗口（和 ⌘T 一样）。
    /// 原来选中的那一页不动：不问它页面里的入口、不加载、不聚焦，网页视图藏着、不盖遮挡。不提示到上限。
    func testWithRoomNewChatOpensASelectedTabAndLeavesThePreviousTabAlone() async throws {
        for count in 1...3 {
            for visible in [true, false] {
                let label = "\(count) 个，窗口显示着=\(visible)"
                let rig = try make()
                rig.tabs.windowIsVisible = { visible }
                rig.tabs.windowIsKey = { true }
                rig.tabs.tipRecord = MemoryTabTipRecord()
                for _ in 1..<count { _ = rig.add() }
                let previous = rig.tabs.selected
                XCTAssertTrue(previous === rig.first, label)
                let mark = rig.mark()
                rig.tabs.newChat()

                let new = rig.tabs.selected
                let n = count + 1
                XCTAssertEqual(new.id.rawValue, n, label)
                XCTAssertEqual(rig.tabs.list.tabs.map(\.rawValue), Array(1...n), "放在最右：\(label)")
                XCTAssertTrue(rig.controller.page === new.page, label)
                XCTAssertTrue(rig.controller.webView === new.runtime.webView, label)
                XCTAssertEqual(rig.controller.shownCoverKind, .newTab, label)
                XCTAssertEqual(rig.loads["\(n)"], [WebRuntime.homeURL], label)
                XCTAssertEqual(rig.shownHints, [.severalTabs], "第一次有多个标签页的提示，没有到上限的提示：\(label)")
                let reveal = visible ? [] : ["[tabs] 新增标签页：窗口没有显示，先找回窗口", "找回窗口"]
                XCTAssertEqual(rig.lines(since: mark).filter { $0.hasPrefix("[tabs]") || $0 == "找回窗口" },
                               ["[tabs] 新建对话：开在新标签页"] + reveal
                                   + ["[tabs] 新增（现在 \(n) 个） 【标签\(n)】", "[tabs] 选中 【标签\(n)】"], label)

                try await waitUntil { !rig.focused.isEmpty }
                try await pause(0.2)
                XCTAssertEqual(rig.focused, ["\(n)"], "只聚焦新的那一页：\(label)")
                XCTAssertEqual(rig.newChatAsked, [], "不问任何一页页面里的入口：\(label)")
                XCTAssertNil(rig.loads["1"], "原来那一页不加载：\(label)")
                XCTAssertTrue(previous.runtime.webView.isHidden, label)
                XCTAssertFalse(previous.page.isCovered, label)
            }
        }
    }

    /// 到上限（4 个，选中的是 2）：不加标签页，列表和选中项不变；先写一行（带 2 的标签），再照原来问 2 页面里的入口——
    /// 没点到整页加载新对话页、不聚焦；点到了不加载、聚焦 2。不提示到上限、不找回窗口（窗口没显示也不，和原来的新对话一样）。
    func testAtTheLimitNewChatStartsInTheCurrentTabWithoutAHint() async throws {
        for (inPage, visible) in [(false, true), (true, false)] {
            let label = "点到了=\(inPage) 窗口显示着=\(visible)"
            let rig = try make()
            rig.newChatInPage = inPage
            rig.tabs.windowIsVisible = { visible }
            let b = rig.add()
            _ = rig.add()
            _ = rig.add()
            rig.tabs.select(b)
            XCTAssertTrue(rig.tabs.list.isFull, label)
            let list = rig.tabs.list
            let mark = rig.mark()
            rig.tabs.newChat()
            XCTAssertEqual(rig.tabs.list, list, "不加标签页、选中的不变：\(label)")
            XCTAssertTrue(rig.tabs.selected === b, label)

            try await waitUntil { rig.lines(since: mark).contains("页面里新对话 2 返回") }
            try await pause(0.2)
            XCTAssertEqual(rig.newChatAsked, ["2"], label)
            XCTAssertEqual(rig.loads["2"], inPage ? nil : [WebRuntime.homeURL], label)
            XCTAssertEqual(rig.focused, inPage ? ["2"] : [], label)
            XCTAssertEqual(rig.shownHints, [], "不提示到上限：\(label)")
            let after = inPage ? ["聚焦 2"] : ["[nav] 加载 https://chatgpt.com/ 【标签2】", "加载 2 https://chatgpt.com/"]
            XCTAssertEqual(rig.lines(since: mark), [
                "[tabs] 新建对话：已到上限（4 个），在当前标签页新建 【标签2】",
                "页面里新对话 2",
                "页面里新对话 2 返回",
            ] + after, label)
            XCTAssertEqual(rig.tabs.list, list, label)
        }
    }
}
