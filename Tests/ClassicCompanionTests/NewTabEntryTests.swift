import AppKit
import Combine
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 新增标签页的入口（ChatTabs.newTab()，3.6，只有接口）。启动时的标签页（标签 1）和新增的都按正式运行时的建法建
/// （ChatTab.make，日志带标签），新增的建法交给 ChatTabs（makeTab），建好后让加载请求只记下来、不发出去。核对：
/// - 不新增：启动画面还在（到时限后还在等提交也算）时只写一行；到上限（上限来自 TabList）时响一声、写一行。
///   列表、选中项、窗口都不变，不建网页，不找回窗口。
/// - 新增的顺序：（窗口没显示时先找回窗口）→ 建、接线、登记网络 → 开始新标签页的遮挡 → 加载新对话页 → 切换过去。
///   遮挡在切换之前就属于它：窗口换上它时遮挡一起投上，窗口不写“启动保护”的行；第一次显示不补排版。
/// - 聚焦、记下的对话地址跟着切换（select）走；设置建的时候就照现在的，之后改设置也改到它；接线和网络和启动的那个一样。
/// - 换下去的那一页之后的事件只改它自己的状态；A → 新的 B → 回到 A 时补排版和阅读位置照常。
/// - 新的那一页关闭以后，它迟到的回调和计时什么都不做，标签页能释放。
/// 不显示窗口：找回窗口、提示音、窗口显示着没有都换成替身。真的找回窗口（ChatWindowController.reveal()）要上屏看。
@MainActor
final class NewTabEntryTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!
    private let other = URL(string: "https://chatgpt.com/c/def")!

    private func make(capacity: Int = TabList.defaultCapacity) -> NewTabRig {
        let name = "NewTabEntryTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = NewTabRig(defaults: UserDefaults(suiteName: name)!, capacity: capacity)
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

    /// 运行时建的时候写的两行（和 TabLogTests 一样）。
    private func creationLines(_ rig: NewTabRig, _ n: Int) -> [String] {
        ["[ax] 允许其他应用读取网页内容=\(rig.settings.allowPageAccessibility) VoiceOver=\(NSWorkspace.shared.isVoiceOverEnabled) 【标签\(n)】",
         "[web] 网页检查器：开 【标签\(n)】"]
    }

    // MARK: - 新增的顺序

    /// 窗口显示着：建、接线 → “新增”一行 → 遮挡（这时它不显示、不选中）→ 加载新对话页（加载时已经盖着、还没选中、窗口还没显示它）
    /// → 切换（“选中”一行）。之后它是选中的、放在最右，窗口显示它的网页视图并盖着新标签页的遮挡；换下去的那一页藏着。
    /// 窗口不写任何行（没有“启动保护”：遮挡不是在它显示着时开始的），也不补排版。不找回窗口、不响。
    func testANewTabIsBuiltCoveredLoadedThenSelectedInThatOrder() throws {
        let rig = make()
        let mark = rig.mark()
        let b = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertEqual(rig.lines(since: mark), ["建 2"] + creationLines(rig, 2) + [
            "[tabs] 新增（现在 2 个） 【标签2】",
            "[nav] 加载 https://chatgpt.com/ 【标签2】",
            "加载 2 https://chatgpt.com/ 遮挡=newTab 选中=1 显示=1",
            "[tabs] 选中 【标签2】",
        ])
        XCTAssertEqual(b.id.rawValue, 2)
        XCTAssertEqual(rig.tabs.list.tabs.map(\.rawValue), [1, 2], "放在最右")
        XCTAssertTrue(rig.tabs.tabs.last === b)
        XCTAssertTrue(rig.tabs.selected === b)
        XCTAssertTrue(rig.controller.page === b.page)
        XCTAssertTrue(rig.controller.webView === b.runtime.webView)
        XCTAssertFalse(b.runtime.webView.isHidden)
        XCTAssertTrue(rig.first.runtime.webView.isHidden, "换下去的那一页藏着")
        XCTAssertEqual(rig.controller.shownCoverKind, .newTab)
        XCTAssertTrue(b.page.isCovered)
        XCTAssertTrue(b.page.holdsPageColor, "它自己的启动保护")
        XCTAssertFalse(rig.controller.isCatchingUp, "第一次显示不补排版")
        XCTAssertEqual(rig.prepared, [])
        XCTAssertEqual(rig.loads["2"], [WebRuntime.homeURL])
        XCTAssertNil(rig.loads["1"])
        XCTAssertEqual(rig.made, [2])
        XCTAssertEqual(rig.reveals, 0)
        XCTAssertEqual(rig.beeps, 0)
    }

    /// 再新增一个：前一个新的还盖着自己的遮挡也能新增（那不是启动画面）；新的放在最右，哪怕选中的是最左的那个。
    /// 前一个的遮挡留在它自己的状态里，窗口投的是新的这个的。
    func testAnotherNewTabGoesOnTheRightWhileThePreviousOneIsStillCovered() throws {
        let rig = make()
        let b = try XCTUnwrap(rig.tabs.newTab())
        rig.tabs.select(rig.first)
        XCTAssertNil(rig.controller.shownCoverKind)
        XCTAssertTrue(b.page.isCovered)
        XCTAssertFalse(rig.tabs.isLaunchScreenUp)
        let mark = rig.mark()
        let c = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertFalse(rig.lines(since: mark).contains { $0.hasPrefix("[tabs] 不新增") })
        XCTAssertEqual(rig.tabs.list.tabs.map(\.rawValue), [1, 2, 3])
        XCTAssertTrue(rig.tabs.selected === c)
        XCTAssertTrue(rig.controller.page === c.page)
        XCTAssertEqual(rig.controller.shownCoverKind, .newTab)
        XCTAssertTrue(b.page.isCovered, "前一个的遮挡还是它自己的")
        XCTAssertTrue(rig.lines(since: mark).contains("[tabs] 新增（现在 3 个） 【标签3】"))
    }

    // MARK: - 聚焦、记下的对话地址（由 select 做）

    /// 窗口是 key 窗口：只聚焦新的那一页（80ms 后），之前给启动的那一页排着的作废。不是 key 窗口：都不聚焦。
    func testOnlyTheNewTabIsFocusedAndOnlyWhenTheWindowIsKey() async throws {
        for key in [true, false] {
            let rig = make()
            rig.tabs.windowIsKey = { key }
            rig.tabs.focusInputSoon(for: rig.first)
            rig.tabs.newTab()
            try await pause(0.3)
            XCTAssertEqual(rig.focused, key ? ["2"] : [], "key=\(key)")
        }
    }

    /// 新的那一页还没有对话地址：记下的不改。它拿到对话地址时记它的；启动的那一页在后台换地址不记；切回去时记它的。
    func testTheLastConversationFollowsTheNewTabOnceItHasOne() throws {
        let rig = make()
        rig.first.runtime.onURLChange?(chat)
        XCTAssertEqual(rig.saved, [chat])
        let b = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertEqual(rig.saved, [chat], "新的那一页还没有地址")
        b.runtime.onURLChange?(WebRuntime.homeURL)
        XCTAssertEqual(rig.saved, [chat], "新对话页不是可以恢复的对话")
        b.runtime.onURLChange?(other)
        XCTAssertEqual(rig.saved, [chat, other])
        rig.first.runtime.onURLChange?(URL(string: "https://chatgpt.com/c/ghi")!)
        XCTAssertEqual(rig.saved, [chat, other], "后台换地址不记")
        rig.tabs.select(rig.first)
        XCTAssertEqual(rig.saved, [chat, other, URL(string: "https://chatgpt.com/c/ghi")!])
    }

    // MARK: - 不新增

    /// 启动画面还在（刚开始；到时限后还在等提交）：只写一行，别的都不做——不响、不找回窗口（窗口没显示也不）、不建、
    /// 列表和窗口不变。启动画面结束以后照常新增。
    func testNothingIsAddedWhileTheLaunchScreenIsUp() async throws {
        for awaitsCommit in [false, true] {
            let rig = make()
            rig.visible = false
            if awaitsCommit { rig.controller.launchScreenLimit = 0.05 }
            rig.controller.beginLaunchScreen()
            if awaitsCommit {
                try await waitUntil { rig.first.page.coverAwaitsCommit }
                XCTAssertTrue(rig.first.page.coverAwaitsCommit)
            }
            XCTAssertTrue(rig.tabs.isLaunchScreenUp)
            let window = rig.windowState(), list = rig.tabs.list
            let mark = rig.mark()
            XCTAssertNil(rig.tabs.newTab())
            XCTAssertEqual(rig.lines(since: mark), ["[tabs] 不新增标签页：启动画面还在"], "等提交=\(awaitsCommit)")
            XCTAssertEqual(rig.beeps, 0)
            XCTAssertEqual(rig.reveals, 0)
            XCTAssertEqual(rig.made, [])
            XCTAssertEqual(rig.tabs.list, list)
            XCTAssertEqual(rig.tabs.tabs.count, 1)
            XCTAssertEqual(rig.windowState(), window)
            XCTAssertEqual(rig.controller.shownCoverKind, .launch)

            rig.first.runtime.webView(rig.first.runtime.webView, didCommit: nil)
            rig.first.runtime.webView(rig.first.runtime.webView, didFinish: nil)
            XCTAssertFalse(rig.tabs.isLaunchScreenUp)
            rig.visible = true
            XCTAssertNotNil(rig.tabs.newTab(), "启动画面结束以后照常新增（等提交=\(awaitsCommit)）")
        }
    }

    /// 已到上限（默认 4 个）：响一声、写一行（个数来自 TabList），别的都不做——不找回窗口（窗口没显示也不）、不建、
    /// 列表、选中项、窗口不变。
    func testNothingIsAddedAtTheLimitExceptOneBeepAndOneLine() throws {
        let rig = make()
        XCTAssertNotNil(rig.tabs.newTab())
        XCTAssertNotNil(rig.tabs.newTab())
        let d = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertEqual(rig.tabs.list.tabs.count, TabList.defaultCapacity)
        rig.visible = false
        let window = rig.windowState(), list = rig.tabs.list
        let mark = rig.mark()
        XCTAssertNil(rig.tabs.newTab())
        XCTAssertEqual(rig.beeps, 1)
        XCTAssertEqual(rig.lines(since: mark), ["提示音", "[tabs] 不新增标签页：已到上限（4 个）"])
        XCTAssertEqual(rig.reveals, 0)
        XCTAssertEqual(rig.made, [2, 3, 4])
        XCTAssertEqual(rig.tabs.list, list)
        XCTAssertEqual(rig.tabs.tabs.count, 4)
        XCTAssertTrue(rig.tabs.selected === d)
        XCTAssertEqual(rig.windowState(), window)
    }

    /// 上限不是写死的：列表的上限是 1 时一开始就满了，那一行写 1。启动画面还在、上限也到了：只写启动画面那一行，不响。
    func testTheLimitComesFromTheListAndTheLaunchScreenRefusalComesFirst() {
        let rig = make(capacity: 1)
        XCTAssertTrue(rig.tabs.list.isFull)
        rig.controller.beginLaunchScreen()
        XCTAssertTrue(rig.tabs.isLaunchScreenUp)
        let launch = rig.mark()
        XCTAssertNil(rig.tabs.newTab())
        XCTAssertEqual(rig.lines(since: launch), ["[tabs] 不新增标签页：启动画面还在"], "两样都有时按启动画面算")
        XCTAssertEqual(rig.beeps, 0)

        rig.first.runtime.webView(rig.first.runtime.webView, didCommit: nil)
        rig.first.runtime.webView(rig.first.runtime.webView, didFinish: nil)
        XCTAssertFalse(rig.tabs.isLaunchScreenUp)
        let full = rig.mark()
        XCTAssertNil(rig.tabs.newTab())
        XCTAssertEqual(rig.lines(since: full), ["提示音", "[tabs] 不新增标签页：已到上限（1 个）"])
        XCTAssertEqual(rig.beeps, 1)
        XCTAssertEqual(rig.made, [])
        XCTAssertEqual(rig.tabs.list.tabs.map(\.rawValue), [1])
    }

    // MARK: - 窗口没显示（D9）

    /// 窗口没显示：先写一行、找回窗口（只一次，在建之前），再照常新增。找回窗口时窗口照常说“显示了”（替身像 show() 那样
    /// 调用窗口显示后的回调：给这时选中的启动的那一页排聚焦、提前重试）；之后的切换让那次聚焦作废，只聚焦新的那一页。
    /// 窗口显示着：不找回（第一个测试）。
    func testAHiddenWindowIsRevealedFirstThenTheTabIsAdded() async throws {
        let rig = make()
        rig.visible = false
        rig.tabs.windowIsKey = { true }
        rig.onReveal = { [weak rig] in
            rig?.visible = true
            rig?.controller.onDidShow?(.wake)
        }
        let mark = rig.mark()
        let b = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertEqual(rig.reveals, 1)
        XCTAssertEqual(Array(rig.lines(since: mark).prefix(3)), [
            "[tabs] 新增标签页：窗口没有显示，先找回窗口",
            "找回窗口（选中=1 个数=1）",
            "建 2",
        ])
        XCTAssertTrue(rig.tabs.selected === b)
        XCTAssertTrue(rig.controller.page === b.page)
        XCTAssertEqual(rig.controller.shownCoverKind, .newTab)
        try await pause(0.3)
        XCTAssertEqual(rig.focused, ["2"], "窗口显示后给启动的那一页排的聚焦被切换作废")

        rig.tabs.select(rig.first)
        XCTAssertNotNil(rig.tabs.newTab())
        XCTAssertEqual(rig.reveals, 1, "窗口显示着就不找回")
    }

    /// 正式运行时的“窗口显示着”看的是窗口：测试的窗口从没显示过，所以是 false（找回窗口要上屏看，这里换成替身）。
    func testTheDefaultVisibilityReadsTheWindow() {
        let rig = make()
        XCTAssertFalse(rig.controller.window!.isVisible)
        XCTAssertFalse(rig.defaultWindowIsVisible())
    }

    // MARK: - 设置、接线、网络（和启动的那个一样）

    /// 改过的设置（页面缩放、网页无障碍、网页增强）新的那一页建的时候就照着；之后改设置也改到它（弹窗标题也是）。
    /// 它的运行时、适配器、页面的日志带它的标签；回调都接好了；登记在共用的网络状态上（已知断网时马上补发给它）。
    func testSettingsWiringAndTheNetworkReachTheNewTab() throws {
        let rig = make()
        let scripts = { (tab: ChatTab) in tab.runtime.webView.configuration.userContentController.userScripts.count }
        rig.settings.pageZoom = 1.25
        rig.tabs.setPageZoom(1.25)
        rig.settings.allowPageAccessibility = true
        rig.tabs.setPageAccessibilityAllowed(true)
        rig.settings.webEnhancements = false
        rig.tabs.applyEnhancementScripts()
        rig.network.deliver(online: false)
        let mark = rig.mark()

        let b = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertEqual(b.runtime.webView.pageZoom, 1.25)
        XCTAssertFalse(b.runtime.webView.blockAccessibility)
        XCTAssertEqual(scripts(b), 0)
        XCTAssertEqual(Array(rig.lines(since: mark).prefix(5)), ["建 2"] + creationLines(rig, 2) + [
            "[net] 网络不可用 【标签2】",
            "[tabs] 新增（现在 2 个） 【标签2】",
        ], "已知断网：接好线、登记时马上补发")

        rig.settings.pageZoom = 1.5
        rig.tabs.setPageZoom(1.5)
        XCTAssertEqual(b.runtime.webView.pageZoom, 1.5)
        XCTAssertEqual(rig.first.runtime.webView.pageZoom, 1.5)
        rig.tabs.setPageAccessibilityAllowed(false)
        XCTAssertTrue(b.runtime.webView.blockAccessibility)
        rig.settings.webEnhancements = true
        rig.tabs.applyEnhancementScripts()
        XCTAssertEqual(scripts(b), 2)
        XCTAssertEqual(scripts(rig.first), 2)
        let popup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: true)
        popup.isReleasedWhenClosed = false
        popup.title = "旧标题"
        b.runtime.adoptPopupForTesting(popup)
        rig.tabs.retitlePopups()
        XCTAssertEqual(popup.title, L10n.string("window.popup"))

        XCTAssertEqual(b.runtime.log.tab, b.id)
        XCTAssertEqual(b.adapter.log.tab, b.id)
        XCTAssertEqual(b.page.logTag, b.id)
        XCTAssertNotNil(b.runtime.onURLChange)
        XCTAssertNotNil(b.runtime.onEscapeRequest)
        XCTAssertNotNil(b.runtime.onMainFrameLoaded)
        XCTAssertNotNil(b.runtime.onLoadFailed)
        XCTAssertNotNil(b.runtime.onLoadProblemChange)
        XCTAssertNotNil(b.runtime.onMainFrameCommitted)

        let online = rig.mark()
        rig.network.deliver(online: true)
        XCTAssertTrue(rig.lines(since: online).contains("[net] 网络可用 【标签2】"))
    }

    /// 新的那一页（显示着）自己的第一次加载经接线结束它的遮挡：窗口写的是和启动画面一样的那一行（不带标签），揭开、淡出，
    /// 再解除启动保护；窗口是 key 窗口就聚焦它。
    func testTheNewTabsFirstLoadEndsItsCoverThroughTheSameWiring() async throws {
        let rig = make()
        rig.tabs.windowIsKey = { true }
        let b = try XCTUnwrap(rig.tabs.newTab())
        let mark = rig.mark()
        b.runtime.webView(b.runtime.webView, didCommit: nil)
        b.runtime.webView(b.runtime.webView, didFinish: nil)
        XCTAssertFalse(b.page.isCovered)
        XCTAssertNil(rig.controller.shownCoverKind)
        XCTAssertNotNil(rig.controller.launchFadeView)
        XCTAssertFalse(b.page.holdsPageColor)
        let window = rig.lines(since: mark).filter { $0.hasPrefix("[launch]") || $0.hasPrefix("[appearance]") }
        XCTAssertEqual(window.first, "[launch] 启动画面结束：网页已加载（…ms）")
        XCTAssertEqual(window.count, 2)
        let released = window.dropFirst().first ?? ""
        XCTAssertTrue(released.hasPrefix("[appearance] 启动保护解除："), released)
        try await pause(0.3)
        XCTAssertFalse(rig.focused.isEmpty)
        XCTAssertEqual(Set(rig.focused), ["2"])
    }

    // MARK: - 换下去的那一页

    /// 新增以后，换下去的启动的那一页的加载、失败、重新加载、提交、加载完成、换地址、Esc 只改它自己的状态：
    /// 窗口（显示的页面、遮挡、提示、启动保护、淡出、补排版）、新的那一页、聚焦、隐藏、记下的地址、窗口的日志都不变。
    func testTheOutgoingTabsEventsChangeOnlyItsOwnState() async throws {
        let rig = make()
        rig.tabs.windowIsKey = { true }
        let a = rig.first
        let b = try XCTUnwrap(rig.tabs.newTab())
        try await pause(0.2)
        let window = rig.windowState(), newOne = rig.pageState(b.page), aBefore = rig.pageState(a.page)
        let calls = "隐藏=\(rig.hidden) 聚焦=\(rig.focused) 记下=\(rig.saved)"
        let windowLines = { (mark: Int) in
            rig.lines(since: mark).filter { line in ["[launch]", "[appearance]", "[window]", "[tabs]"].contains { line.hasPrefix($0) } }
        }
        let mark = rig.mark()

        a.runtime.load(chat)
        rig.fail(a.runtime)
        XCTAssertEqual(a.page.notice, .waiting, "A 自己的提示")
        XCTAssertNil(rig.controller.shownLoadProblem, "窗口不显示 A 的提示")
        a.runtime.reload()
        a.runtime.webView(a.runtime.webView, didCommit: nil)
        a.runtime.webView(a.runtime.webView, didFinish: nil)
        a.runtime.onURLChange?(chat)
        a.runtime.onEscapeRequest?()
        try await pause(0.3)
        XCTAssertNotEqual(rig.pageState(a.page), aBefore, "A 自己的状态照常改")
        XCTAssertTrue(a.page.hasFinishedFirstLoad)
        XCTAssertEqual(rig.windowState(), window, "窗口不变")
        XCTAssertEqual(rig.pageState(b.page), newOne, "新的那一页不变")
        XCTAssertEqual("隐藏=\(rig.hidden) 聚焦=\(rig.focused) 记下=\(rig.saved)", calls)
        XCTAssertEqual(windowLines(mark), [], "窗口不写日志")
    }

    // MARK: - A → 新的 B → 回到 A

    /// 回到 A 时：A 离开时的大小没变就不补排版、马上显示；藏着时窗口变大了就先补排版——补排版前记下 A 的阅读位置
    /// （A 还藏着、还是离开时的大小），排好时放回给显示着的 A。新的 B 第一次显示从不补排版。
    func testReturningToTheOutgoingTabFollowsTheCatchUpRules() throws {
        for grows in [false, true] {
            let rig = make()
            let calls = rig.recordReadingPosition()
            let a = rig.first
            a.runtime.onURLChange?(chat)
            let left = a.runtime.webView.frame.size
            XCTAssertNotNil(rig.tabs.newTab())
            XCTAssertFalse(rig.controller.isCatchingUp)
            if grows { rig.grow() }
            rig.tabs.select(a)
            XCTAssertTrue(rig.controller.page === a.page)
            XCTAssertEqual(rig.controller.isCatchingUp, grows, "变大了=\(grows)")
            if grows {
                XCTAssertEqual(calls.list, ["记下 1（藏着 \(Int(left.width))×\(Int(left.height))）"])
                XCTAssertEqual(rig.prepared, ["1"])
                try XCTUnwrap(rig.prepares.first)()
                XCTAssertFalse(rig.controller.isCatchingUp)
                XCTAssertEqual(calls.list, ["记下 1（藏着 \(Int(left.width))×\(Int(left.height))）", "放回 1（显示着）"])
                XCTAssertEqual(calls.tokens, [1, 1])
            } else {
                XCTAssertEqual(calls.list, [])
                XCTAssertEqual(rig.prepared, [])
            }
        }
    }

    /// A 上正在切模式（排版前记下了 A 的阅读位置）时新增：先改选中项、再结束切模式，所以 A 的位置留在 A 上，不放回到
    /// 正要藏起的 A；新的 B 不补排版。回到 A：A 离开时还没排好，先补排版（不再记一次），排好时放回留着的那一次。
    func testANewTabDuringAModeSwitchLeavesTheOutgoingPositionPendingUntilItsReturn() throws {
        let rig = make()
        let calls = rig.recordReadingPosition()
        let a = rig.first
        a.runtime.onURLChange?(chat)
        rig.controller.beginLayoutChangeForTesting(to: rig.biggerFrame())
        try XCTUnwrap(rig.snapshots.first)(NSImage(size: NSSize(width: 10, height: 10)))
        XCTAssertEqual(calls.list, ["记下 1（显示着）"])
        let mark = rig.mark()

        XCTAssertNotNil(rig.tabs.newTab())
        XCTAssertFalse(rig.controller.isChangingLayout)
        XCTAssertFalse(rig.controller.isCatchingUp, "新的那一页第一次显示不补排版")
        XCTAssertEqual(calls.list, ["记下 1（显示着）"], "不放回到换下去的 A")
        XCTAssertEqual(a.pendingReadingRestore?.token, 1)
        XCTAssertEqual(rig.lines(since: mark).filter { $0.hasPrefix("[tabs]") || $0.hasPrefix("[reading]") }, [
            "[tabs] 新增（现在 2 个） 【标签2】",
            "[tabs] 选中 【标签2】",
            "[reading] 阅读位置：这一页没有显示，记下的位置留到它再显示并排好版时放回 【标签1】",
        ])

        rig.tabs.select(a)
        XCTAssertTrue(rig.controller.isCatchingUp)
        XCTAssertEqual(calls.list, ["记下 1（显示着）"], "补排版前不再记")
        XCTAssertEqual(rig.prepared, ["1", "1"])
        try XCTUnwrap(rig.prepares.dropFirst().first)()
        XCTAssertEqual(calls.list, ["记下 1（显示着）", "放回 1（显示着）"])
        XCTAssertEqual(calls.tokens, [1, 1])
        XCTAssertNil(a.pendingReadingRestore)
    }

    // MARK: - 新的那一页关闭以后

    /// 新增 B，切回 A，关闭 B。之后 B 迟到的回调（关闭前拿到的接线：提交、加载完成、失败、提示、换地址、Esc）、
    /// 它遮挡的时限和上限、它排着的聚焦、它再要加载都什么都不做：窗口、A、聚焦、隐藏、记下的地址、加载、日志都不变。
    func testTheNewTabsLateCallbacksAfterItIsClosedDoNothing() async throws {
        let rig = make()
        rig.tabs.windowIsKey = { true }
        rig.controller.launchScreenLimit = 0.1
        rig.controller.launchScreenCap = 0.2
        rig.controller.pageRevealLimit = 0.1
        let b = try XCTUnwrap(rig.tabs.newTab())
        let late = (committed: b.runtime.onMainFrameCommitted, loaded: b.runtime.onMainFrameLoaded,
                    failed: b.runtime.onLoadFailed, problem: b.runtime.onLoadProblemChange,
                    url: b.runtime.onURLChange, escape: b.runtime.onEscapeRequest)
        rig.tabs.select(rig.first)
        rig.tabs.close(b)
        XCTAssertTrue(b.runtime.isClosed)
        XCTAssertTrue(b.page.isClosed)
        XCTAssertNil(b.runtime.webView.superview, "从窗口里拿出来")
        let window = rig.windowState(), aState = rig.pageState(rig.first.page)
        let mark = rig.mark()

        late.committed?()
        late.loaded?()
        late.failed?()
        late.problem?(.waiting)
        late.url?(other)
        late.escape?()
        b.runtime.newChat()
        try await pause(0.5)
        XCTAssertEqual(rig.lines(since: mark), [])
        XCTAssertEqual(rig.windowState(), window)
        XCTAssertEqual(rig.pageState(rig.first.page), aState)
        XCTAssertEqual(rig.focused, ["1"], "B 排着的聚焦不做，只聚焦切回去的 A")
        XCTAssertEqual(rig.hidden, [])
        XCTAssertEqual(rig.saved, [])
        XCTAssertEqual(rig.loads["2"], [WebRuntime.homeURL], "关闭以后不再加载")
        XCTAssertEqual(rig.tabs.list.tabs.map(\.rawValue), [1])
    }

    /// 新增、切回、关闭以后，新的那一页连同运行时、页面状态和网页视图都释放。
    func testANewTabIsReleasedAfterItIsClosed() async throws {
        let rig = make()
        weak var tab: ChatTab?, page: PageLoadState?, web: WKWebView?
        autoreleasepool {
            guard let b = rig.tabs.newTab() else { return XCTFail("应该新增") }
            tab = b
            page = b.page
            web = b.runtime.webView
            rig.tabs.select(rig.first)
            rig.tabs.close(b)
        }
        try await waitUntil(5) { tab == nil && page == nil && web == nil }
        XCTAssertNil(tab)
        XCTAssertNil(page)
        XCTAssertNil(web)
    }
}

/// 记下、放回、丢弃阅读位置的记录。
@MainActor
private final class ReadingLog {
    var list: [String] = []
    var tokens: [Int] = []
    var issued = 0
}

/// 启动时的标签页（标签 1）和窗口、ChatTabs，像 AppDelegate 那样建（列表、标签页、窗口、ChatTabs、wire），新增的建法交给
/// ChatTabs：正式运行时的 ChatTab.make，建好后加载请求只记下来。AppDelegate 交给 ChatTabs 的几样换成记录；
/// 找回窗口、提示音、窗口显示着没有换成替身。替身的调用和共用的日志按发生的先后记在 timeline 里。
/// 切模式的快照和排版换成手动送回。这里只弱引用新增的标签页（关闭以后看它能不能释放）。
@MainActor
private final class NewTabRig {
    let settings: AppSettings
    let diagnostics = Diagnostics()
    let appearance: PageAppearance
    let first: ChatTab
    let controller: ChatWindowController
    let network = NetworkStatus(startsMonitor: false)
    private(set) var tabs: ChatTabs!
    /// 日志（“[类别] 内容”，去掉跟着真实输入写的）和替身的调用，按发生的先后。
    private var timeline: [String] = []
    /// 建过的标签页的序号。
    private(set) var made: [Int] = []
    /// 每个标签页（按序号）发出的加载请求。
    private(set) var loads: [String: [URL]] = [:]
    private(set) var focused: [String] = []
    private(set) var saved: [URL] = []
    private(set) var hidden: [String] = []
    private(set) var beeps = 0
    private(set) var reveals = 0
    /// 窗口显示着没有（替身）。
    var visible = true
    /// 找回窗口的替身记下之后再做的事（测试用它像 show() 那样调用窗口显示后的回调）。
    var onReveal: (() -> Void)?
    /// 正式运行时的“窗口显示着”（换成替身之前的那个）。
    private(set) var defaultWindowIsVisible: @MainActor () -> Bool = { true }
    var snapshots: [(NSImage?) -> Void] = []
    var prepares: [() -> Void] = []
    /// 每次排版交给的是哪个标签页（序号）。
    var prepared: [String] = []
    private var watch: AnyCancellable?

    init(defaults: UserDefaults, capacity: Int) {
        settings = AppSettings(defaults: defaults)
        appearance = PageAppearance(defaults: defaults)
        let list = TabList(capacity: capacity)
        first = Self.pinColour(ChatTab.make(id: list.selected, diagnostics: diagnostics, settings: settings))
        // 顶部一条和正式的一样高度固定：用 EmptyView 时它没有高度，竖直方向的排版不确定，换遮挡的样子
        // （启动画面 ↔ 新标签页的遮挡，内容大小不同）就会让网页的位置变高变矮，切回时被当成“大小和离开时不同”。
        controller = ChatWindowController(webView: first.runtime.webView,
                                          toolbar: Color.clear.frame(height: WebBar.height).frame(maxWidth: .infinity),
                                          diagnostics: diagnostics, appearance: appearance, page: first.page)
        controller.pageColorSettleLimit = 60
        controller.layoutWaitLimit = 60
        tabs = ChatTabs(list: list, tab: first, windowController: controller, diagnostics: diagnostics, network: network,
                        hideWindow: { [weak self] reason in self?.hidden.append(reason) },
                        focusInput: { [weak self] adapter in
                            self?.focused.append(self?.name(adapter) ?? "?")
                            return "NewTabEntryTests"
                        },
                        saveLastConversation: { [weak self] url in self?.saved.append(url) },
                        mediaState: { _ in "none" },
                        openNewChat: { _ in true },
                        makeTab: { [weak self] id in self!.build(id) },
                        revealWindow: { [weak self] in
                            guard let self else { return }
                            self.reveals += 1
                            self.timeline.append("找回窗口（选中=\(self.tabs.list.selected.rawValue) 个数=\(self.tabs.tabs.count)）")
                            self.onReveal?()
                        })
        tabs.wire(first)
        first.runtime.loadRequest = { [weak self] request in self?.loads["1", default: []].append(request.url!) }
        defaultWindowIsVisible = tabs.windowIsVisible
        tabs.windowIsVisible = { [weak self] in self?.visible ?? true }
        tabs.beep = { [weak self] in
            self?.beeps += 1
            self?.timeline.append("提示音")
        }
        controller.onSnapshotPage = { [weak self] done in self?.snapshots.append(done) }
        controller.onPrepareLayout = { [weak self] _, done in
            guard let self else { return }
            self.prepared.append("\(self.tabs.selected.id.rawValue)")
            self.prepares.append(done)
        }
        controller.window!.contentView!.layoutSubtreeIfNeeded()
        watch = diagnostics.$entries.dropFirst().sink { [weak self] entries in
            guard let self, let entry = entries.last, !LiveInputLogLines.excludes(entry) else { return }
            self.timeline.append("[\(entry.category)] \(entry.message)")
        }
    }

    /// 网页视图建好就设上页面底色（白色），这一组测试就和这个测试进程的外观无关。实测（窗口不显示；只在这个测试进程里设应用外观，
    /// 不改系统设置）：
    /// - WebKit 在进程里建第一个网页视图时，按那时应用的外观定下网页视图还没报颜色时的底色（深色是 #1E1E1E，浅色是白色），
    ///   之后建的网页视图都用它，再改应用外观也不变；
    /// - 网页视图放进窗口、有了大小以后 0.03–0.25 秒，它的空白页报出自己的底色：白色（没有加载任何网页）。
    /// 浅色下前后都是白色，没有变化；深色下是一次变化：窗口观察着显示的网页视图，150ms 后采用，写一行
    /// “[appearance] 页面底色：浅色”，窗口底色变白——和这里要测的事无关，却会落在“什么都不变”的核对里。
    /// 设上底色以后 WebKit 不再报它自己的底色（设成什么颜色都一样）；测试自己再设，窗口照样观察得到。
    private static func pinColour(_ tab: ChatTab) -> ChatTab {
        tab.runtime.webView.underPageBackgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        return tab
    }

    /// 新增的建法：正式运行时的 ChatTab.make，加载请求只记下来，记的时候写上它的遮挡、选中的是谁、窗口显示的是谁。
    private func build(_ id: TabID) -> ChatTab {
        let name = "\(id.rawValue)"
        made.append(id.rawValue)
        timeline.append("建 \(name)")
        let tab = Self.pinColour(ChatTab.make(id: id, diagnostics: diagnostics, settings: settings))
        tab.runtime.loadRequest = { [weak self, weak tab] request in
            guard let self, let tab else { return }
            let url = request.url!
            self.loads[name, default: []].append(url)
            let cover = tab.page.isCovered ? "\(tab.page.coverKind)" : "无"
            self.timeline.append("加载 \(name) \(url.absoluteString) 遮挡=\(cover) 选中=\(self.tabs.list.selected.rawValue) "
                                 + "显示=\(self.pageName(self.controller.page))")
        }
        return tab
    }

    func name(_ adapter: ChatGPTAdapter) -> String {
        tabs.tabs.first { $0.adapter === adapter }.map { "\($0.id.rawValue)" } ?? "?"
    }

    func pageName(_ p: PageLoadState) -> String {
        tabs.tabs.first { $0.page === p }.map { "\($0.id.rawValue)" } ?? "?"
    }

    func runtimeName(_ runtime: WebRuntime) -> String {
        tabs.tabs.first { $0.runtime === runtime }.map { "\($0.id.rawValue)" } ?? "?"
    }

    func mark() -> Int {
        timeline.count
    }

    /// mark 之后的时间线，去掉运行时加载完成后自己异步写的 [esc]、[render]，毫秒数换成“…”。
    func lines(since mark: Int) -> [String] {
        timeline.dropFirst(mark)
            .filter { !$0.hasPrefix("[esc]") && !$0.hasPrefix("[render]") }
            .map { $0.replacingOccurrences(of: #"（\d+ms）"#, with: "（…ms）", options: .regularExpression) }
    }

    /// 记下、放回、丢弃阅读位置换成记录：“记下 1（藏着 宽×高）”“记下 1（显示着）”“放回 1（显示着）”“丢弃 1”，和各自的编号。
    func recordReadingPosition() -> ReadingLog {
        let calls = ReadingLog()
        tabs.holdReadingPosition = { [weak self] runtime in
            calls.issued += 1
            let web = runtime.webView
            let state = web.isHidden ? "藏着 \(Int(web.frame.width))×\(Int(web.frame.height))" : "显示着"
            calls.list.append("记下 \(self?.runtimeName(runtime) ?? "?")（\(state)）")
            calls.tokens.append(calls.issued)
            return calls.issued
        }
        tabs.restoreReadingPosition = { [weak self] runtime, token, _ in
            let shown = self?.controller.webView === runtime.webView && !runtime.webView.isHidden
            calls.list.append("放回 \(self?.runtimeName(runtime) ?? "?")（\(shown ? "显示着" : "没显示")）")
            calls.tokens.append(token)
        }
        tabs.discardReadingPosition = { [weak self] runtime, token in
            calls.list.append("丢弃 \(self?.runtimeName(runtime) ?? "?")")
            calls.tokens.append(token)
        }
        return calls
    }

    /// 加载 url 失败（-1009），和 LoadRecoveryWebTests 一样直接调导航代理。
    func fail(_ runtime: WebRuntime, _ url: URL = URL(string: "https://chatgpt.com/c/abc")!) {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                            userInfo: [NSURLErrorFailingURLErrorKey: url])
        runtime.webView(runtime.webView, didFailProvisionalNavigation: nil, withError: error)
    }

    /// 藏着时窗口变大（像切过模式、拖过边）。
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
        "显示=\(pageName(controller.page)) 网页=\(runtimeNameOfShownWebView()) 遮挡=\(controller.isShowingLaunchScreen) "
            + "样子=\(controller.shownCoverKind.map { "\($0)" } ?? "无") 淡出=\(Self.identity(controller.launchFadeView)) "
            + "启动保护=\(controller.isHoldingPageColor) 提示=\(controller.shownLoadProblem.map { "\($0)" } ?? "无") "
            + "提示淡出=\(Self.identity(controller.loadProblemFadeView)) 补排版=\(controller.isCatchingUp) "
            + "切模式=\(controller.isChangingLayout) 页面颜色=\(appearance.background.map { "\($0)" } ?? "nil") "
            + "窗口底色=\(controller.window?.backgroundColor.description ?? "nil")"
    }

    private func runtimeNameOfShownWebView() -> String {
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
