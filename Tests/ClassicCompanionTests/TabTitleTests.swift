import AppKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 标签页的标题（4.2）：网页的标题经运行时（观察 WKWebView.title）、ChatTabs 到标签栏模型（TabBarModel），照
/// TabBarRules.displayTitle 显示；标题是对话内容，不进诊断日志（也就不进系统日志：只有 Diagnostics.log 写它）、诊断报告和窗口标题。
/// 标签页用 TabCloseRig（正式的建法、从不显示的窗口，加载请求只记下来），网页打开本地 html（loadPage），标题里放一个独一无二的记号。
/// 不显示窗口、不出声。
@MainActor
final class TabTitleTests: XCTestCase {
    private func make() -> TabCloseRig {
        let name = "TabTitleTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabCloseRig(defaults: UserDefaults(suiteName: name)!)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        return rig
    }

    private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func page(_ title: String) -> String {
        "<html><head><title>\(title)</title></head><body><main>x</main></body></html>"
    }

    private func chat(_ id: String) -> URL {
        URL(string: "https://chatgpt.com/c/\(id)")!
    }

    /// 标签栏上 tab 那一项显示的标题（nil：“新聊天”，或者没有这一项）。
    private func shown(_ tab: ChatTab, _ rig: TabCloseRig) -> String? {
        rig.tabs.tabBar.items.first { $0.id == tab.id }?.title
    }

    private func setTitle(_ tab: ChatTab, _ title: String) async throws {
        _ = try await tab.runtime.webView.evaluateJavaScript("document.title = '\(title)'; 0")
    }

    /// 网页标题到标签栏模型：加载、脚本改标题、通用标题和加载中按规则显示“新聊天”；新增、切换、⌘ 点击链接（后台、前台）、
    /// 到上限、关闭（不显示的、显示着的）、重新打开时模型跟着列表走，onTabsChanged 调用时模型已经是新的；关闭以后迟到的标题不改什么。
    /// 一路下来诊断日志、诊断报告里都没有标题的记号，窗口标题一直是 “Classic Companion”。
    func testTitlesReachTheTabBarButNeverTheLogsTheReportOrTheWindowTitle() async throws {
        let rig = make()
        let model = rig.tabs.tabBar
        let marker = "TTLMARK\(UUID().uuidString.prefix(8))"
        func titled(_ name: String) -> String { "\(marker)-\(name)" }
        var changes: [[Int]] = []
        rig.tabs.onTabsChanged = { changes.append([model.items.count, rig.tabs.tabs.count]) }
        let a = rig.first
        XCTAssertEqual(model.items.map(\.id), [a.id])
        XCTAssertFalse(model.isShown)
        XCTAssertNil(shown(a, rig))

        await rig.loadPage(a, page(titled("a")), at: chat("aaa"))
        try await waitUntil { self.shown(a, rig) == titled("a") }
        XCTAssertEqual(shown(a, rig), titled("a"))
        XCTAssertEqual(a.title, titled("a"))

        let b = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertTrue(model.isShown)
        XCTAssertEqual(model.items.map(\.isSelected), [false, true])
        XCTAssertNil(shown(b, rig), "还没有标题：新聊天")
        await rig.loadPage(b, page(titled("b")), at: chat("bbb"))
        try await waitUntil { self.shown(b, rig) == titled("b") }
        XCTAssertEqual(shown(b, rig), titled("b"))

        try await setTitle(b, titled("b2"))
        try await waitUntil { self.shown(b, rig) == titled("b2") }
        XCTAssertEqual(shown(b, rig), titled("b2"), "脚本改了标题，模型跟着改")
        try await setTitle(b, "ChatGPT")
        try await waitUntil { b.title == "ChatGPT" }
        XCTAssertEqual(b.title, "ChatGPT")
        XCTAssertNil(shown(b, rig), "网站的通用标题：新聊天")
        b.runtime.onTitleChange?(titled("b3"), true)
        XCTAssertNil(shown(b, rig), "加载中：新聊天")
        b.runtime.onTitleChange?(titled("b3"), false)
        XCTAssertEqual(shown(b, rig), titled("b3"))

        rig.tabs.select(a)
        XCTAssertEqual(model.items.map(\.isSelected), [true, false])
        let c = try XCTUnwrap(rig.tabs.openLink(chat("ccc"), from: a, .background))
        XCTAssertEqual(model.items.map(\.id), [a.id, c.id, b.id], "放在来源的紧右边")
        await rig.loadPage(c, page(titled("c")), at: chat("ccc"))
        try await waitUntil { self.shown(c, rig) == titled("c") }
        XCTAssertEqual(shown(c, rig), titled("c"), "不显示的标签页的标题也到模型")
        let d = try XCTUnwrap(rig.tabs.openLink(chat("ddd"), from: a, .foreground))
        XCTAssertEqual(model.items.map(\.id), [a.id, d.id, c.id, b.id])
        XCTAssertEqual(model.items.map(\.isSelected), [false, true, false, false])
        XCTAssertEqual(model.newTabButton, TabBarRules.NewTabButton(dimmed: true, clickable: true, explainsLimit: true), "到上限")
        await rig.loadPage(d, page(titled("d")), at: chat("ddd"))
        try await waitUntil { self.shown(d, rig) == titled("d") }
        XCTAssertNil(rig.tabs.newTab(), "到上限：不新增")

        rig.tabs.closeTab(c)
        XCTAssertEqual(model.items.map(\.id), [a.id, d.id, b.id])
        XCTAssertEqual(model.newTabButton, TabBarRules.NewTabButton(dimmed: false, clickable: true, explainsLimit: false))
        rig.tabs.closeSelectedTab()
        XCTAssertEqual(model.items.map(\.id), [a.id, b.id])
        XCTAssertEqual(model.items.map(\.isSelected), [false, true])
        let r = try XCTUnwrap(rig.tabs.reopenClosedTab())
        XCTAssertEqual(model.items.map(\.id), [a.id, r.id, b.id], "放回关闭时的位置")
        XCTAssertNil(shown(r, rig))
        await rig.loadPage(r, page(titled("r")), at: chat("ddd"))
        try await waitUntil { self.shown(r, rig) == titled("r") }
        XCTAssertEqual(shown(r, rig), titled("r"))
        XCTAssertEqual(changes, [[2, 2], [3, 3], [4, 4], [3, 3], [2, 2], [3, 3]], "onTabsChanged 调用时模型已经是新的")

        // 关闭以后：回调已经断开，网页里的标题再变也不改它记下的、不进模型。
        XCTAssertNil(c.runtime.onTitleChange)
        try await setTitle(c, titled("late"))
        try await waitUntil { c.runtime.webView.title == titled("late") }
        XCTAssertEqual(c.runtime.webView.title, titled("late"))
        XCTAssertEqual(c.title, titled("c"))
        XCTAssertFalse(model.items.contains { $0.id == c.id })

        let entries = rig.diagnostics.entries
        XCTAssertGreaterThan(entries.filter { $0.category == "tabs" }.count, 5, "上面的操作都写了日志")
        XCTAssertEqual(entries.filter { $0.message.contains(marker) || $0.category.contains(marker) }.map(\.message), [],
                       "日志里没有标题")
        XCTAssertFalse(rig.diagnostics.report(build: "TabTitleTests").contains(marker), "诊断报告里没有标题")
        XCTAssertEqual(rig.controller.window?.title, "Classic Companion", "窗口标题不跟着网页标题")
        XCTAssertFalse(model.items.map(\.description).joined().contains(marker), "模型的文字描述不带标题")
    }
}
