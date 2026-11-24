import AppKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 有几个标签页时的后退、前进（⌘[ ⌘]、鼠标侧键、菜单、顶部返回箭头）：
/// - 目标是操作开始这一刻选中的标签页（ChatTabs.historyPage(commandWindow:)），别的窗口在前面时没有目标。
/// - 顶部返回箭头跟着选中的标签页（ChatTabs.onBackButtonChange）：切换、关掉显示着的那一页、它自己的历史变了时重报；
///   不显示的标签页的历史变了不报。
/// TabCloseRig（聊天窗口只创建、从不显示）。标签页的历史用两个 data: 页面（不联网），和 HistoryNavigationTests 里
/// 真实 WebRuntime 的那一条一样；按键直接用值调用窗口的处理函数，不发真实的按键。
@MainActor
final class TabHistoryTargetTests: XCTestCase {
    private let one = URL(string: "data:text/html,one")!
    private let two = URL(string: "data:text/html,two")!
    private let three = URL(string: "data:text/html,three")!

    private func make() -> TabCloseRig {
        let name = "TabHistoryTargetTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabCloseRig(defaults: UserDefaults(suiteName: name)!)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        // 和 AppDelegate 一样：窗口的 ⌘[ ⌘]、侧键在按下时解析一次目标（这里操作的窗口就是聊天窗口）。
        rig.controller.historyPage = { [weak rig] in
            guard let rig else { return nil }
            return rig.tabs.historyPage(commandWindow: rig.controller.window)
        }
        return rig
    }

    private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// 在 tab 里依次打开 urls（直接交给网页视图，不经运行时的加载入口），等到最后一个加载完。
    private func browse(_ tab: ChatTab, _ urls: [URL]) async throws {
        tab.runtime.openInBrowser = { _ in XCTFail("data: 页面不该交给浏览器") }
        for url in urls {
            tab.runtime.webView.load(URLRequest(url: url))
            try await waitUntil { tab.runtime.webView.url == url && !tab.runtime.webView.isLoading }
            XCTAssertEqual(tab.runtime.webView.url, url)
        }
    }

    /// 箭头的报告：（要不要显示，哪个标签页）。
    private final class Arrow {
        var reports: [(Bool, String)] = []
        var last: Bool? { reports.last?.0 }
    }

    private func watchArrow(_ rig: TabCloseRig) -> Arrow {
        let arrow = Arrow()
        rig.tabs.onBackButtonChange = { [weak rig] shows, page in
            let name = rig?.tabs.tabs.first { $0.runtime === page }.map { "\($0.id.rawValue)" } ?? "?"
            arrow.reports.append((shows, name))
        }
        return arrow
    }

    // MARK: - 目标

    /// 目标是这一刻选中的标签页的运行时，跟着切换、关闭换；聊天窗口以外的窗口在前面（或没有窗口）时没有目标。
    func testTheTargetIsTheSelectedTabInTheChatWindowOnly() throws {
        let rig = make()
        let window = try XCTUnwrap(rig.controller.window)
        let second = rig.add(), third = rig.add()
        XCTAssertTrue(rig.tabs.historyPage(commandWindow: window) === rig.first.runtime)
        rig.tabs.select(second)
        XCTAssertTrue(rig.tabs.historyPage(commandWindow: window) === second.runtime)
        rig.tabs.select(third)
        XCTAssertTrue(rig.tabs.historyPage(commandWindow: window) === third.runtime)
        rig.tabs.closeTab(third)
        XCTAssertTrue(rig.tabs.historyPage(commandWindow: window) === rig.tabs.selected.runtime)
        XCTAssertFalse(rig.tabs.selected === third)
        XCTAssertNil(rig.tabs.historyPage(commandWindow: NSObject()), "登录弹窗等别的窗口在前面")
        XCTAssertNil(rig.tabs.historyPage(commandWindow: nil))
    }

    /// ⌘[ 走选中的那一页自己的历史，不动别的标签页；换到没有历史的标签页以后 ⌘[ 吃掉、什么都不做，
    /// 有历史的那一页留在原处。菜单项的可用跟着选中的那一页。
    func testTheKeyGoesBackInTheSelectedTabOnly() async throws {
        let rig = make()
        let number = try XCTUnwrap(rig.controller.window).windowNumber
        XCTAssertGreaterThan(number, 0)
        let second = rig.add()
        try await browse(second, [one, two])
        try await waitUntil { second.runtime.canGo(.back) }
        XCTAssertTrue(second.runtime.canGo(.back))

        // 选中的是没有历史的第一页：⌘[ 吃掉，第二页不动；菜单项是灰的。
        let window = rig.controller.window
        XCTAssertFalse(HistoryNavigation.isAvailable(.back, on: rig.tabs.historyPage(commandWindow: window)))
        XCTAssertTrue(rig.controller.handleHistoryKey(.back, isRepeat: false, windowNumber: number))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(second.runtime.webView.url, two)

        // 换到第二页：菜单项可用，⌘[ 让它后退一次。
        rig.tabs.select(second)
        XCTAssertTrue(HistoryNavigation.isAvailable(.back, on: rig.tabs.historyPage(commandWindow: window)))
        XCTAssertTrue(rig.controller.handleHistoryKey(.back, isRepeat: false, windowNumber: number))
        try await waitUntil { second.runtime.webView.url == one && !second.runtime.webView.isLoading }
        XCTAssertEqual(second.runtime.webView.url, one)
        XCTAssertFalse(rig.first.runtime.canGo(.back))
        XCTAssertFalse(rig.first.runtime.canGo(.forward))

        // 前进：菜单项跟着它的 canGoForward。
        try await waitUntil { second.runtime.canGo(.forward) }
        XCTAssertTrue(HistoryNavigation.isAvailable(.forward, on: rig.tabs.historyPage(commandWindow: window)))
        rig.tabs.select(rig.first)
        XCTAssertFalse(HistoryNavigation.isAvailable(.forward, on: rig.tabs.historyPage(commandWindow: window)))
    }

    // MARK: - 顶部返回箭头

    /// 箭头跟着选中的标签页：换上有历史（不是聊天页面、能后退）的那一页时显示，换回、关掉它时收起；
    /// 不显示的标签页的历史变了不报，选中的标签页的历史变了才报。
    func testTheBackArrowFollowsTheSelectedTabOnly() async throws {
        let rig = make()
        let arrow = watchArrow(rig)
        let second = rig.add(), third = rig.add()

        // 后台的第二页有了历史：不报。
        try await browse(second, [one, two])
        try await waitUntil { second.runtime.showsBackButton }
        XCTAssertTrue(second.runtime.showsBackButton)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(arrow.reports.isEmpty, "不显示的标签页的历史变了不动箭头：\(arrow.reports)")

        // 换上第二页：显示。
        rig.tabs.select(second)
        XCTAssertEqual(arrow.last, true)
        XCTAssertEqual(arrow.reports.last?.1, "2")

        // 换到第三页（没有历史）：收起。第二页在后台再走一步：不报。
        rig.tabs.select(third)
        XCTAssertEqual(arrow.last, false)
        let before = arrow.reports.count
        try await browse(second, [three])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(arrow.reports.count, before, "后台的第二页换页不动箭头")

        // 选中的第三页自己有了历史：报，显示。
        try await browse(third, [one, two])
        try await waitUntil { arrow.last == true }
        XCTAssertEqual(arrow.last, true)
        XCTAssertTrue(arrow.reports.dropFirst(before).allSatisfy { $0.1 == "3" }, "\(arrow.reports)")

        // 换回第二页（也能后退），再关掉它：换上邻居（第三页）时照邻居报。
        rig.tabs.select(second)
        XCTAssertEqual(arrow.reports.last?.1, "2")
        rig.tabs.closeTab(second)
        XCTAssertTrue(rig.tabs.selected === third)
        XCTAssertEqual(arrow.reports.last?.1, "3")
        XCTAssertEqual(arrow.last, true)

        // 再关第三页：换上第一页（没有历史），收起。
        rig.tabs.closeTab(third)
        XCTAssertTrue(rig.tabs.selected === rig.first)
        XCTAssertEqual(arrow.last, false)
        XCTAssertEqual(arrow.reports.last?.1, "1")
    }

    /// 关掉的标签页的运行时不再报历史变化（关闭时断开回调）。
    func testAClosedTabNoLongerReportsHistoryChanges() {
        let rig = make()
        let second = rig.add()
        rig.tabs.closeTab(second)
        XCTAssertNil(second.runtime.onHistoryChange)
    }
}
