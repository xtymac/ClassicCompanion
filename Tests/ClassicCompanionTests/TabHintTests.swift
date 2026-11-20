import AppKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 窗口里的提示（3.11，TabHintPresenter）：到上限的提示、第一次有多个标签页的提示。提示框放进 TabCloseRig 的从不显示的窗口里、
/// 排好版看位置；计时（schedule）、窗口在不在屏幕上（windowShowsContent）、读屏播报（announce）都是替身，测试自己决定什么时候到点。
/// 不显示窗口、不出声。样子（材质、字、圆角、浅深色）只能上屏看。
@MainActor
final class TabHintTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!
    /// 排下的计时：几秒、到点做的事（按排下的先后）。
    private var timers: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
    /// 替身：窗口这一刻在不在屏幕上。
    private var onScreen = false
    private var announced: [String] = []

    /// tipShown：第一次有多个标签页的提示是不是已经记下显示过（默认没有）。
    private func make(tipShown: Bool = false) -> TabCloseRig {
        let name = "TabHintTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabCloseRig(defaults: UserDefaults(suiteName: name)!)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        rig.tabs.tipRecord = MemoryTabTipRecord(shown: tipShown)
        let hints = rig.controller.hints
        hints.schedule = { [weak self] delay, work in self?.timers.append((delay, work)) }
        hints.windowShowsContent = { [weak self] in self?.onScreen ?? false }
        hints.announce = { [weak self] in self?.announced.append($0) }
        return rig
    }

    /// 排下的 delay 秒的计时都到点（按排下的先后），从列表里拿掉。
    private func fire(_ delay: TimeInterval) {
        let due = timers.filter { $0.delay == delay }
        timers.removeAll { $0.delay == delay }
        for timer in due { timer.work() }
    }

    private func hintLines(_ rig: TabCloseRig, since mark: Int) -> [String] {
        rig.lines(since: mark).filter { $0.hasPrefix("[hint]") }
    }

    private func record(_ rig: TabCloseRig) -> Bool {
        rig.tabs.tipRecord.severalTabsTipShown
    }

    /// 放满四个（第一次的提示已经记下，不出现）。
    private func fill(_ rig: TabCloseRig) throws {
        while !rig.tabs.list.isFull { _ = try XCTUnwrap(rig.tabs.newTab()) }
    }

    // MARK: - 到上限的提示

    /// 到上限：写那一行、显示“最多打开 4 个标签页”，播报同一句话；不抢焦点（第一响应者不变、提示框不当第一响应者），
    /// 点不着（点按落到下面的网页上）；放在窗口内容的最上层、网页区域上方正中离上沿 10 点；不改窗口大小。
    func testTheLimitHintIsQuietClickThroughAndOnTop() throws {
        let rig = make(tipShown: true)
        try fill(rig)
        let window = try XCTUnwrap(rig.controller.window)
        let content = try XCTUnwrap(window.contentView)
        let responder = window.firstResponder, frame = window.frame
        let mark = rig.mark()
        XCTAssertNil(rig.tabs.newTab())
        let hints = rig.controller.hints, host = hints.host
        XCTAssertEqual(rig.lines(since: mark), ["[tabs] 不新增标签页：已到上限（4 个）", "[hint] 显示 到上限（4 个）的提示"])
        XCTAssertEqual(hints.current, .limit(capacity: 4))
        XCTAssertEqual(announced, [TabHint.limit(capacity: 4).text()])
        XCTAssertFalse(host.isHidden)
        XCTAssertFalse(host.takesClicks)
        XCTAssertFalse(host.acceptsFirstResponder)
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertTrue(content.subviews.last === host, "在所有遮挡之上")

        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.frame.width, 0)
        XCTAssertGreaterThan(host.frame.height, 0)
        XCTAssertEqual(host.frame.maxY, content.bounds.maxY - WebBar.height - 10, accuracy: 0.5, "网页区域上沿下面 10 点")
        XCTAssertEqual(host.frame.midX, content.bounds.midX, accuracy: 0.5, "正中")
        XCTAssertGreaterThan(host.frame.minY, content.bounds.midY, "在上半部分，不挡输入框")
        XCTAssertNil(host.hitTest(NSPoint(x: host.frame.midX, y: host.frame.midY)), "点不着")
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(host.appearance?.name, rig.controller.chromeAppearance?.name, "浅深色和顶部一条一样跟着页面")
    }

    /// 3 秒后自己收起；还显示着时又到上限：重新计时（之前排下的那次到点不收起），不叠第二个。
    func testTheLimitHintGoesAwayAfterThreeSecondsAndPressingAgainRefreshes() throws {
        let rig = make(tipShown: true)
        try fill(rig)
        let mark = rig.mark()
        XCTAssertNil(rig.tabs.newTab())
        XCTAssertEqual(timers.map(\.delay), [3])
        XCTAssertNil(rig.tabs.reopenClosedTab(), "没有记录：不提示")
        XCTAssertNil(rig.tabs.newTab())
        XCTAssertEqual(timers.map(\.delay), [3, 3])
        let hosts = try XCTUnwrap(rig.controller.window?.contentView).subviews.filter { $0 is TabHintHost }
        XCTAssertEqual(hosts.count, 1)

        timers[0].work()
        XCTAssertEqual(rig.controller.hints.current, .limit(capacity: 4), "之前排下的那次不收起")
        timers[1].work()
        XCTAssertNil(rig.controller.hints.current)
        XCTAssertTrue(rig.controller.hints.host.isHidden)
        XCTAssertEqual(hintLines(rig, since: mark), [
            "[hint] 显示 到上限（4 个）的提示", "[hint] 到上限（4 个）的提示还显示着，重新计时", "[hint] 收起 到上限（4 个）的提示：到时",
        ])
        XCTAssertEqual(announced.count, 1, "重新计时不再播报")
    }

    /// 窗口隐藏（最小化也一样）：到上限的提示马上收起，再显示窗口时不出现。
    func testHidingTheWindowDropsTheLimitHint() throws {
        let rig = make(tipShown: true)
        try fill(rig)
        XCTAssertNil(rig.tabs.newTab())
        let mark = rig.mark()
        rig.controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
        XCTAssertNil(rig.controller.hints.current)
        rig.controller.windowDidDeminiaturize(Notification(name: NSWindow.didDeminiaturizeNotification))
        XCTAssertNil(rig.controller.hints.current)
        XCTAssertEqual(hintLines(rig, since: mark), ["[hint] 收起 到上限（4 个）的提示：窗口隐藏"])
        // 隐藏窗口的正式入口（hide(reason:)）在 orderOut 之后告诉提示（测试不调用它：它会把前台还给别的应用）。
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/ClassicCompanion/Window/ChatWindowController.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("        window.orderOut(nil)\n        hints.windowHidden()\n"))
        XCTAssertTrue(source.contains("        onDidShow?(kind)\n        hints.windowMayBeOnScreen()\n"))
    }

    // MARK: - 第一次有多个标签页的提示

    /// 第二个标签页打开时显示（能关、收得到点按），窗口在屏幕上连续 0.5 秒才记下；窗口不在屏幕上不记，露出来以后再等 0.5 秒。
    /// 记下以后不再显示。
    func testTheTipIsRecordedOnlyAfterItWasOnScreen() throws {
        let rig = make()
        let mark = rig.mark()
        let b = try XCTUnwrap(rig.tabs.newTab())
        let hints = rig.controller.hints
        XCTAssertEqual(hints.current, .severalTabs)
        XCTAssertTrue(hints.host.takesClicks)
        XCTAssertEqual(announced, [TabHint.severalTabs.text()])
        XCTAssertEqual(timers.map(\.delay), [0.5], "能关的不自己收起")
        fire(0.5)
        XCTAssertFalse(record(rig), "窗口不在屏幕上：不记")

        onScreen = true
        rig.controller.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification))
        XCTAssertFalse(record(rig), "露出来的那一刻还不算")
        fire(0.5)
        XCTAssertTrue(record(rig))
        XCTAssertEqual(hintLines(rig, since: mark), ["[hint] 显示 第一次有多个标签页的提示", "[hint] 第一次有多个标签页的提示显示过，记下"])

        // 记下以后：留着直到手动关闭；之后再多开也不再显示。
        rig.tabs.select(rig.first)
        rig.tabs.closeTab(b)
        XCTAssertEqual(hints.current, .severalTabs, "切换、关闭标签页都不收起")
        hints.closeByHand()
        _ = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertNil(hints.current)
        XCTAssertEqual(hintLines(rig, since: mark).suffix(1), ["[hint] 收起 第一次有多个标签页的提示：手动关闭"])
    }

    /// 0.5 秒还没到就被到上限的提示换掉（一次只有一个）：不记；关掉一个、到上限的提示收起以后再新增：再显示一次。
    func testATipReplacedBeforeItWasOnScreenIsNotRecordedAndComesBack() throws {
        let rig = make()
        onScreen = true
        let mark = rig.mark()
        _ = try XCTUnwrap(rig.tabs.newTab())
        _ = try XCTUnwrap(rig.tabs.newTab())
        _ = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertNil(rig.tabs.newTab())
        XCTAssertEqual(rig.controller.hints.current, .limit(capacity: 4))
        fire(0.5)
        XCTAssertFalse(record(rig))
        XCTAssertEqual(hintLines(rig, since: mark), [
            "[hint] 显示 第一次有多个标签页的提示", "[hint] 收起 第一次有多个标签页的提示：换成别的提示", "[hint] 显示 到上限（4 个）的提示",
        ])

        rig.tabs.closeSelectedTab()
        fire(3)
        _ = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertEqual(rig.controller.hints.current, .severalTabs)
        fire(0.5)
        XCTAssertTrue(record(rig))
    }

    /// 窗口隐藏、最小化：等着的“显示过”作废，提示留着；再显示（还原）以后重新等 0.5 秒。
    func testHidingTheWindowRestartsTheWaitButKeepsTheTip() throws {
        let rig = make()
        onScreen = true
        _ = try XCTUnwrap(rig.tabs.newTab())
        rig.controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
        fire(0.5)
        XCTAssertFalse(record(rig), "隐藏时排着的那次作废")
        XCTAssertEqual(rig.controller.hints.current, .severalTabs)
        rig.controller.windowDidDeminiaturize(Notification(name: NSWindow.didDeminiaturizeNotification))
        fire(0.5)
        XCTAssertTrue(record(rig))
    }

    /// 手动关闭：窗口在屏幕上时算显示过（马上记下）；不在屏幕上时不算，下次打开标签页时再显示。
    func testClosingTheTipByHandCountsOnlyWhenOnScreen() throws {
        let rig = make()
        _ = try XCTUnwrap(rig.tabs.newTab())
        rig.controller.hints.closeByHand()
        XCTAssertFalse(record(rig))
        XCTAssertNil(rig.controller.hints.current)
        XCTAssertFalse(rig.controller.hints.host.takesClicks)
        XCTAssertTrue(rig.controller.hints.host.isHidden)

        _ = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertEqual(rig.controller.hints.current, .severalTabs, "没记下：再显示")
        onScreen = true
        let mark = rig.mark()
        rig.controller.hints.closeByHand()
        XCTAssertTrue(record(rig))
        XCTAssertEqual(hintLines(rig, since: mark), ["[hint] 第一次有多个标签页的提示显示过，记下",
                                                     "[hint] 收起 第一次有多个标签页的提示：手动关闭"])
        fire(0.5)
        XCTAssertEqual(hintLines(rig, since: mark).count, 2, "收起后排着的那次不再做事")
    }

    /// 按键（⌘T）和重新打开也经同一条路（open）显示，不是 handleKey 自己显示：只有一个标签页时不显示；没记下时每次多开都再显示。
    func testTheTipComesFromOpeningNotFromTheKeys() throws {
        let rig = make()
        XCTAssertNil(rig.controller.hints.current, "只有一个：不显示")
        let window = try XCTUnwrap(rig.controller.window).windowNumber
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                   windowNumber: window, context: nil, characters: "t", charactersIgnoringModifiers: "t",
                                                   isARepeat: false, keyCode: 17))
        XCTAssertTrue(rig.controller.handleKeyDown(KeyPress(event)))
        let b = rig.tabs.selected
        XCTAssertEqual(rig.controller.hints.current, .severalTabs)
        rig.controller.hints.closeByHand()
        b.runtime.onURLChange?(chat)
        rig.tabs.closeTab(b)
        XCTAssertNil(rig.controller.hints.current)
        XCTAssertNotNil(rig.tabs.reopenClosedTab())
        XCTAssertEqual(rig.controller.hints.current, .severalTabs, "重新打开以后又是两个：再显示")
        XCTAssertEqual(rig.shownHints, [.severalTabs, .severalTabs])

        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ClassicCompanion/Tabs/ChatTabs.swift"), encoding: .utf8)
        // 3.12 起两处：新增、重新打开共用的 open 里一处，⌘ 点击链接打开的 openLink 里一处（LinkTabOpenTests 核对它照样提示）。
        // 每一处往前找最近的“func ”，就是调用它的函数。
        let callers = source.components(separatedBy: "offerSeveralTabsTip()\n").dropLast().map { before -> String in
            guard let declaration = before.range(of: "func ", options: .backwards) else { return "?" }
            return String(before[declaration.upperBound...].prefix { $0 != "(" })
        }
        XCTAssertEqual(callers, ["open", "openLink"], "只在 open 和 openLink 里调用")
    }

    // MARK: - 共存

    /// 提示属于窗口：盖着新标签页的遮挡时也在最上层；切换标签页、切到别的页面、关闭标签页后还在、还在最上层。
    func testTheHintStaysOnTopOfCoversAndAcrossTabs() throws {
        let rig = make()
        let content = try XCTUnwrap(rig.controller.window?.contentView)
        let b = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertTrue(b.page.isCovered, "新标签页的遮挡还盖着")
        XCTAssertTrue(content.subviews.last === rig.controller.hints.host)
        rig.tabs.select(rig.first)
        rig.tabs.select(b)
        XCTAssertTrue(content.subviews.last === rig.controller.hints.host)
        rig.tabs.closeTab(b)
        XCTAssertEqual(rig.controller.hints.current, .severalTabs)
        XCTAssertTrue(content.subviews.last === rig.controller.hints.host)
        XCTAssertEqual(content.subviews.filter { $0 is TabHintHost }.count, 1)
    }

    // MARK: - 文字和记录

    /// 四种语言的文字。第一次的提示说 ⌘W 关标签页、未发送的草稿可能丢失、⇧⌘T 只能重新打开已保存的聊天、× 隐藏整个窗口；
    /// 不说能找回草稿、原样恢复。
    func testHintTextsInEveryLanguage() {
        let limit: [AppLanguage: String] = [
            .simplifiedChinese: "最多打开 4 个标签页", .traditionalChinese: "最多打開 4 個分頁",
            .english: "You can open up to 4 tabs", .japanese: "タブは 4 個まで開けます",
        ]
        let tip: [AppLanguage: String] = [
            .simplifiedChinese: "⌘W 关闭当前标签页，未发送的草稿可能丢失；⇧⌘T 只能重新打开已保存的聊天。左上角的 × 隐藏整个窗口，标签页都会保留。",
            .traditionalChinese: "⌘W 關閉目前的分頁，未傳送的草稿可能會遺失；⇧⌘T 只能重新打開已儲存的聊天。左上角的 × 會隱藏整個視窗，分頁都會保留。",
            .english: "⌘W closes the current tab; unsent drafts may be lost. ⇧⌘T only reopens saved chats. The × at the top left hides the whole window and keeps your tabs.",
            .japanese: "⌘W で現在のタブを閉じます。送信していない下書きは失われることがあります。⇧⌘T で開き直せるのは保存済みのチャットだけです。左上の × はウインドウ全体を隠し、タブはそのまま残ります。",
        ]
        let close: [AppLanguage: String] = [.simplifiedChinese: "关闭提示", .traditionalChinese: "關閉提示", .english: "Close Tip",
                                            .japanese: "ヒントを閉じる"]
        for language in AppLanguage.allCases {
            XCTAssertEqual(TabHint.limit(capacity: 4).text(in: language), limit[language])
            XCTAssertEqual(TabHint.severalTabs.text(in: language), tip[language])
            XCTAssertEqual(L10n.string("tabs.hint.close", in: language), close[language])
            let text = TabHint.severalTabs.text(in: language)
            for promise in ["原样", "原樣", "找回", "恢复草稿", "恢復草稿", "restore", "Restore", "復元"] {
                XCTAssertFalse(text.contains(promise), "\(language) \(promise)")
            }
        }
        XCTAssertEqual(TabHint.limit(capacity: 1).text(in: .english), "You can open up to 1 tab")
        XCTAssertEqual(TabHint.limit(capacity: 4).text(in: .simplifiedChinese), "最多打开 4 个标签页")
    }

    /// 正式的记录存在设置里（UserDefaults 的 tabs.severalTabsTipShown），重启后还在；AppDelegate 把它、播报和菜单接上。
    func testTheOnceOnlyFlagIsStoredInSettings() throws {
        let name = "TabHintTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.severalTabsTipShown)
        let record: any TabTipRecord = settings
        record.severalTabsTipShown = true
        XCTAssertTrue(defaults.bool(forKey: "tabs.severalTabsTipShown"))
        XCTAssertTrue(AppSettings(defaults: defaults).severalTabsTipShown)
        XCTAssertFalse(MemoryTabTipRecord().severalTabsTipShown)

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/ClassicCompanion/App/AppDelegate.swift"), encoding: .utf8)
        for wiring in ["chatTabs.tipRecord = settings", "windowController.hints.announce = { text in",
                       "chatTabs.onTabsChanged = { [weak self] in self?.tabMenus.refresh() }", "tabMenus.attach(built.tabItems)",
                       "tabMenus.attachStatus(menu)"] {
            XCTAssertTrue(app.contains(wiring), wiring)
        }
    }
}
