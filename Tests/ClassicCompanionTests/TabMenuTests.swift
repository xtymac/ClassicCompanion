import AppKit
import Carbon.HIToolbox
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 标签页的菜单项（3.11，TabMenus）：主菜单用正式的建法（AppDelegate.makeMainMenu）建、接到 TabCloseRig 的 ChatTabs 上。
/// 不弹出菜单：直接问验证（validateMenuItem）、直接调用菜单项的动作。key 窗口、模态框、用户的键、重复按键都是替身，
/// 窗口从不显示（隐藏窗口、找回窗口在 rig 里是记录）。
@MainActor
final class TabMenuTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!
    /// 替身：这一刻的 key 窗口（默认是聊天窗口）、模态框、重复按键。
    private var key: NSWindow?
    private var modal = false
    private var repeating = false
    /// 别的窗口（设置等）：建了、从不显示。
    private lazy var other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                                      backing: .buffered, defer: true)

    private func make() -> TabCloseRig {
        let name = "TabMenuTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabCloseRig(defaults: UserDefaults(suiteName: name)!)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        key = rig.controller.window
        return rig
    }

    private struct Built {
        let menus: TabMenus
        let file: NSMenu
        let window: NSMenu
        let toolbar: ToolbarState
        let items: TabMenus.Items
    }

    /// 主菜单（language）和接上它的 TabMenus，像 AppDelegate 那样接：标签页的个数变了就 refresh。
    private func build(_ rig: TabCloseRig, language: AppLanguage = .simplifiedChinese) throws -> Built {
        let toolbar = ToolbarState()
        let menus = TabMenus(tabs: rig.tabs, chatWindow: rig.controller.window, diagnostics: rig.diagnostics, toolbar: toolbar)
        menus.keyWindow = { [weak self] in self?.key }
        menus.isAppModal = { [weak self] in self?.modal ?? false }
        menus.currentEventIsRepeat = { [weak self] in self?.repeating ?? false }
        rig.tabs.onTabsChanged = { [weak menus] in menus?.refresh() }
        let main = AppDelegate.makeMainMenu(modeKey: .modeStandard, language: language)
        menus.attach(main.tabItems)
        let file = try XCTUnwrap(main.menu.item(at: 1)?.submenu)
        let window = try XCTUnwrap(main.menu.item(at: 4)?.submenu)
        XCTAssertTrue(window === main.windowMenu)
        return Built(menus: menus, file: file, window: window, toolbar: toolbar, items: main.tabItems)
    }

    /// “标题 快捷键”，快捷键按菜单的写法（⌃⌥⇧⌘ 加键，Tab 写成 Tab）。
    private func describe(_ item: NSMenuItem) -> String {
        if item.isSeparatorItem { return "—" }
        guard !item.keyEquivalent.isEmpty else { return item.title }
        let mask = item.keyEquivalentModifierMask
        var keys = ""
        if mask.contains(.control) { keys += "⌃" }
        if mask.contains(.option) { keys += "⌥" }
        if mask.contains(.shift) { keys += "⇧" }
        if mask.contains(.command) { keys += "⌘" }
        keys += item.keyEquivalent == "\t" ? "Tab" : item.keyEquivalent.uppercased()
        return "\(item.title) \(keys)"
    }

    private func visible(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isHidden }.map(describe)
    }

    /// 关掉一个有对话地址的标签页，留下一条记录（关之前先加一个，个数不变）。
    private func leaveARecord(_ rig: TabCloseRig) throws {
        let extra = try XCTUnwrap(rig.tabs.newTab())
        extra.runtime.onURLChange?(chat)
        rig.tabs.closeTab(extra)
        XCTAssertTrue(rig.tabs.canReopenClosedTab)
    }

    private func menuLines(_ rig: TabCloseRig, since mark: Int) -> [String] {
        rig.lines(since: mark).filter { $0.hasPrefix("[menu]") }
    }

    // MARK: - 结构

    /// 一个标签页：文件菜单和原来一样多了“新建标签页 ⌘T”“重新打开最近关闭的标签页 ⇧⌘T”，关闭还是“关闭窗口 ⌘W”；
    /// 窗口菜单多了“显示下一个标签页 ⌃Tab”“显示上一个标签页 ⌃⇧Tab”（一组，前后有分隔线）。
    /// 两个、四个：“关闭窗口 ⌘W”换成“关闭标签页 ⌘W”和“关闭窗口 ⇧⌘W”。四个：新建标签页置灰，下面写“最多打开 4 个标签页”。
    func testMenuStructureForOneTwoAndFourTabs() throws {
        let rig = make()
        let built = try build(rig)
        let mode = try XCTUnwrap(built.file.item(at: 3))
        XCTAssertEqual(mode.title, "切换小窗 / 完整窗口")
        let head = ["新建对话 ⌘N", "新建标签页 ⌘T", "重新打开最近关闭的标签页 ⇧⌘T", describe(mode), "重新加载 ⌘R"]
        let windowMenu = ["最小化 ⌘M", "缩放", "—", "显示下一个标签页 ⌃Tab", "显示上一个标签页 ⌃⇧Tab", "—", "前置全部窗口"]

        XCTAssertEqual(visible(built.file), head + ["关闭窗口 ⌘W"])
        XCTAssertEqual(visible(built.window), windowMenu)
        XCTAssertTrue(built.items.closeWindow.action == #selector(NSWindow.performClose(_:)) && built.items.closeWindow.target == nil,
                      "原来那一项照原来交给 key 窗口")
        XCTAssertNil(built.items.newTab.subtitle)

        _ = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertEqual(visible(built.file), head + ["关闭标签页 ⌘W", "关闭窗口 ⇧⌘W"])
        XCTAssertEqual(visible(built.window), windowMenu)
        XCTAssertTrue(built.items.closeWindow.isHidden)

        _ = try XCTUnwrap(rig.tabs.newTab())
        _ = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertEqual(rig.tabs.tabs.count, 4)
        XCTAssertEqual(visible(built.file), head + ["关闭标签页 ⌘W", "关闭窗口 ⇧⌘W"])
        XCTAssertFalse(built.menus.validateMenuItem(built.items.newTab))
        XCTAssertEqual(built.items.newTab.subtitle, TabHint.limit(capacity: 4).text())
        XCTAssertNil(built.items.reopenClosedTab.subtitle, "没有记录：只是置灰，不写到上限")

        // 关回一个：和原来一样。
        while rig.tabs.tabs.count > 1 { rig.tabs.closeSelectedTab() }
        XCTAssertEqual(visible(built.file), head + ["关闭窗口 ⌘W"])
        XCTAssertNil(built.items.newTab.subtitle)
    }

    /// 菜单栏图标的菜单：“新建对话”下面多了“新建标签页”（没有快捷键），目标是 TabMenus。
    func testStatusMenuHasNewTab() throws {
        let rig = make()
        let built = try build(rig)
        let status = NSMenu()
        AppDelegate.fillStatusMenu(status, language: .simplifiedChinese)
        built.menus.attachStatus(status)
        XCTAssertEqual(status.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["显示小窗", "打开完整窗口", "新建对话", "新建标签页", "设置…", "诊断", "关于 Classic Companion", "退出 Classic Companion"])
        let item = try XCTUnwrap(built.menus.statusNewTab)
        XCTAssertTrue(item.target === built.menus)
        XCTAssertEqual(item.keyEquivalent, "")
        XCTAssertTrue(built.menus.validateMenuItem(item))
    }

    // MARK: - 能不能点

    /// 每一项在每种情形下能不能点（validateMenuItem）、显不显示快捷键。
    func testEnabledStateInEachSituation() throws {
        /// 按这个顺序：新建标签页、重新打开、关闭标签页、关闭窗口 ⇧⌘W、下一个、上一个、菜单栏图标的新建标签页。
        func check(_ built: Built, _ want: [Bool], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
            let m = built.menus, i = built.items
            let status = NSMenu()
            AppDelegate.fillStatusMenu(status)
            m.attachStatus(status)
            let got = [i.newTab, i.reopenClosedTab, i.closeTab, i.hideWindowKeepingTabs, i.nextTab, i.previousTab].map(m.validateMenuItem)
                + [m.statusNewTab.map(m.validateMenuItem) ?? false]
            XCTAssertEqual(got, want, what, file: file, line: line)
        }

        // 一个标签页、没有记录。
        let rig = make()
        let built = try build(rig)
        check(built, [true, false, false, false, false, false, true], "一个标签页")
        // 两个、有记录。
        _ = try XCTUnwrap(rig.tabs.newTab())
        try leaveARecord(rig)
        check(built, [true, true, true, true, true, true, true], "两个、有记录")
        // 别的窗口在前面：主菜单的都置灰、不显示快捷键，原来的“关闭窗口 ⌘W”回来（D11）；菜单栏图标的照样能点。
        key = other
        built.menus.refresh()
        check(built, [false, false, false, false, false, false, true], "别的窗口在前面")
        XCTAssertEqual(visible(built.file).suffix(1), ["关闭窗口 ⌘W"])
        for item in [built.items.newTab, built.items.reopenClosedTab, built.items.nextTab, built.items.previousTab] {
            XCTAssertEqual(item.keyEquivalent, "", item.title)
        }
        // 没有 key 窗口（聊天窗口隐藏着、应用不在前台）。
        key = nil
        built.menus.refresh()
        check(built, [false, false, false, false, false, false, true], "没有 key 窗口")
        // 模态框：都不能点，菜单栏图标的也不能。
        key = rig.controller.window
        modal = true
        built.menus.refresh()
        check(built, [false, false, false, false, false, false, false], "模态框")
        modal = false
        built.menus.refresh()
        // 到上限（有记录）：新建、重新打开、菜单栏图标的置灰，写上原因；别的照样。
        _ = try XCTUnwrap(rig.tabs.newTab())
        _ = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertTrue(rig.tabs.list.isFull)
        check(built, [false, false, true, true, true, true, false], "到上限")
        let limit = TabHint.limit(capacity: 4).text()
        XCTAssertEqual(built.items.newTab.subtitle, limit)
        XCTAssertEqual(built.items.reopenClosedTab.subtitle, limit)
        XCTAssertEqual(built.menus.statusNewTab?.subtitle, limit)

        // 启动画面还在：新建、菜单栏图标的置灰，不写到上限。
        let launching = make()
        let early = try build(launching)
        launching.controller.beginLaunchScreen()
        XCTAssertTrue(launching.tabs.isLaunchScreenUp)
        early.menus.refresh()
        check(early, [false, false, false, false, false, false, false], "启动画面还在")
        XCTAssertNil(early.items.newTab.subtitle)
    }

    // MARK: - 点了

    /// 点了调用和按键相同的入口（不经 handleKey：没有“[keys] 标签页按键”那一行），每次写一行“[menu] 菜单 …”。
    func testActionsReachTheSameEntriesAsTheKeys() throws {
        let rig = make()
        let built = try build(rig)
        let m = built.menus
        var mark = rig.mark()
        m.newTab(nil)
        XCTAssertEqual(rig.tabs.tabs.count, 2)
        let b = rig.tabs.selected
        XCTAssertEqual(rig.lines(since: mark).first, "[menu] 菜单 新建标签页")
        XCTAssertTrue(rig.lines(since: mark).contains { $0.hasPrefix("[tabs] 新增（现在 2 个）") })

        m.showPreviousTab(nil)
        XCTAssertTrue(rig.tabs.selected === rig.first)
        m.showNextTab(nil)
        XCTAssertTrue(rig.tabs.selected === b)
        m.showNextTab(nil)
        XCTAssertTrue(rig.tabs.selected === rig.first, "到头绕回")

        b.runtime.onURLChange?(chat)
        mark = rig.mark()
        m.showNextTab(nil)
        m.closeTab(nil)
        XCTAssertEqual(rig.tabs.tabs.count, 1)
        XCTAssertFalse(rig.tabs.holds(b))
        XCTAssertTrue(rig.lines(since: mark).contains { $0.hasPrefix("[tabs] 关闭（剩 1 个）") })

        m.reopenClosedTab(nil)
        XCTAssertEqual(rig.tabs.tabs.count, 2)
        XCTAssertFalse(rig.tabs.canReopenClosedTab)

        m.hideWindowKeepingTabs(nil)
        XCTAssertEqual(rig.hidden, ["菜单：关闭窗口"])
        XCTAssertEqual(rig.tabs.tabs.count, 2, "标签页都留着")

        XCTAssertEqual(menuLines(rig, since: mark), ["[menu] 菜单 显示下一个标签页", "[menu] 菜单 关闭标签页",
                                                     "[menu] 菜单 重新打开最近关闭的标签页", "[menu] 菜单 关闭窗口"])
        XCTAssertFalse(rig.diagnostics.entries.contains { $0.category == "keys" && $0.message.hasPrefix("标签页按键") })
    }

    /// 菜单栏图标的“新建标签页”：窗口没显示时入口先找回窗口（D9），再新增。别的窗口在前面时也能用。
    func testStatusNewTabRevealsAHiddenWindowFirst() throws {
        let rig = make()
        let built = try build(rig)
        rig.tabs.windowIsVisible = { false }
        key = nil
        let mark = rig.mark()
        built.menus.statusNewTab(nil)
        let lines = rig.lines(since: mark)
        XCTAssertEqual(Array(lines.prefix(3)), ["[menu] 菜单 新建标签页（菜单栏图标）", "[tabs] 新增标签页：窗口没有显示，先找回窗口", "找回窗口"])
        XCTAssertEqual(rig.tabs.tabs.count, 2)
    }

    /// 不能点的时候直接调用动作（菜单是一会儿之前验证的）：再看一遍，写一行，不做。按住不放的重复按键也不做。
    func testActionsThatCannotActNowDoNothing() throws {
        let rig = make()
        let built = try build(rig)
        _ = try XCTUnwrap(rig.tabs.newTab())
        let list = rig.tabs.list
        let mark = rig.mark()
        key = other
        built.menus.newTab(nil)
        built.menus.closeTab(nil)
        key = rig.controller.window
        modal = true
        built.menus.showNextTab(nil)
        built.menus.hideWindowKeepingTabs(nil)
        built.menus.statusNewTab(nil)
        modal = false
        repeating = true
        built.menus.newTab(nil)
        built.menus.statusNewTab(nil)
        repeating = false
        XCTAssertEqual(rig.tabs.list, list)
        XCTAssertEqual(rig.hidden, [])
        XCTAssertEqual(menuLines(rig, since: mark), [
            "[menu] 菜单 新建标签页：现在不能用，不做", "[menu] 菜单 关闭标签页：现在不能用，不做",
            "[menu] 菜单 显示下一个标签页：现在不能用，不做", "[menu] 菜单 关闭窗口：现在不能用，不做",
            "[menu] 菜单 新建标签页（菜单栏图标）：现在不能用，不做",
            "[menu] 菜单 新建标签页：按住不放的重复按键，不做", "[menu] 菜单 新建标签页（菜单栏图标）：按住不放的重复按键，不做",
        ])
        XCTAssertEqual(rig.lines(since: mark).filter { !$0.hasPrefix("[menu]") }, [])
    }

    // MARK: - 用户的键

    /// 用户的唤醒键或切换键就是这一项的组合：这一项不显示快捷键（照样能点）；左上角 × 的提示不写 ⇧⌘W。⌘W 照常。
    func testUserHotKeysHideTheTabKeyEquivalents() throws {
        let rig = make()
        let built = try build(rig)
        _ = try XCTUnwrap(rig.tabs.newTab())
        try leaveARecord(rig)
        var user: [HotKeyCombo] = []
        built.menus.userHotKeys = { user }

        user = [HotKeyCombo(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(controlKey))]
        built.menus.refresh()
        XCTAssertEqual(built.items.nextTab.keyEquivalent, "")
        XCTAssertTrue(built.menus.validateMenuItem(built.items.nextTab))
        XCTAssertEqual(describe(built.items.previousTab), "显示上一个标签页 ⌃⇧Tab")

        user = [HotKeyCombo(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(controlKey | shiftKey))]
        built.menus.refresh()
        XCTAssertEqual(describe(built.items.nextTab), "显示下一个标签页 ⌃Tab")
        XCTAssertEqual(built.items.previousTab.keyEquivalent, "")

        let reopen = HotKeyCombo(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(cmdKey | shiftKey))
        let hide = HotKeyCombo(keyCode: UInt32(kVK_ANSI_W), carbonModifiers: UInt32(cmdKey | shiftKey))
        try XCTSkipUnless(reopen.menuKeyEquivalent?.key == "t" && hide.menuKeyEquivalent?.key == "w",
                          "这台机器的键盘布局上 T、W 不在美式键盘的位置：菜单按字符比")
        user = [reopen, hide]
        built.menus.refresh()
        XCTAssertEqual(built.items.reopenClosedTab.keyEquivalent, "")
        XCTAssertTrue(built.menus.validateMenuItem(built.items.reopenClosedTab))
        XCTAssertEqual(built.items.hideWindowKeepingTabs.keyEquivalent, "")
        XCTAssertNil(built.toolbar.hideShortcut, "⇧⌘W 是用户的键：× 的提示不写键")
        XCTAssertEqual(describe(built.items.newTab), "新建标签页 ⌘T")
        XCTAssertEqual(describe(built.items.closeTab), "关闭标签页 ⌘W")

        // 以前存下的 ⌘W（录制时不让设）：⌘W 照常。
        user = [HotKeyCombo(keyCode: UInt32(kVK_ANSI_W), carbonModifiers: UInt32(cmdKey))]
        built.menus.refresh()
        XCTAssertEqual(describe(built.items.closeTab), "关闭标签页 ⌘W")
        XCTAssertEqual(built.toolbar.hideShortcut, "⇧⌘W")
    }

    // MARK: - 左上角 ×

    /// 左上角 × 的提示：一个标签页“隐藏窗口（⌘W）”，多个“隐藏窗口（⇧⌘W）”，个数变了就跟着变。
    func testHideButtonTooltipFollowsTheTabCount() throws {
        let rig = make()
        let built = try build(rig)
        XCTAssertEqual(built.toolbar.hideShortcut, "⌘W")
        let b = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertEqual(built.toolbar.hideShortcut, "⇧⌘W")
        rig.tabs.closeTab(b)
        XCTAssertEqual(built.toolbar.hideShortcut, "⌘W")
        XCTAssertEqual(ToolbarState().hideShortcut, "⌘W", "没接上时和原来一样")

        let expected: [(AppLanguage, String, String, String)] = [
            (.simplifiedChinese, "隐藏窗口（⌘W）", "隐藏窗口（⇧⌘W）", "隐藏窗口"),
            (.traditionalChinese, "隱藏視窗（⌘W）", "隱藏視窗（⇧⌘W）", "隱藏視窗"),
            (.english, "Hide Window (⌘W)", "Hide Window (⇧⌘W)", "Hide Window"),
            (.japanese, "ウインドウを隠す（⌘W）", "ウインドウを隠す（⇧⌘W）", "ウインドウを隠す"),
        ]
        for (language, one, several, none) in expected {
            XCTAssertEqual(WebBar.hideHelp("⌘W", in: language), one)
            XCTAssertEqual(WebBar.hideHelp("⇧⌘W", in: language), several)
            XCTAssertEqual(WebBar.hideHelp(nil, in: language), none)
        }
    }

    // MARK: - 语言

    /// 每种语言的标题（切换语言时主菜单整份重建：动作和快捷键一样，字换成那种语言）。
    func testNewItemsAreTitledInEveryLanguage() throws {
        let expected: [AppLanguage: [String]] = [
            .simplifiedChinese: ["新建标签页", "重新打开最近关闭的标签页", "关闭窗口", "关闭标签页", "关闭窗口", "显示下一个标签页", "显示上一个标签页"],
            .traditionalChinese: ["新增分頁", "重新打開最近關閉的分頁", "關閉視窗", "關閉分頁", "關閉視窗", "顯示下一個分頁", "顯示上一個分頁"],
            .english: ["New Tab", "Reopen Last Closed Tab", "Close Window", "Close Tab", "Close Window", "Show Next Tab", "Show Previous Tab"],
            .japanese: ["新規タブ", "最後に閉じたタブを再度開く", "ウインドウを閉じる", "タブを閉じる", "ウインドウを閉じる", "次のタブを表示", "前のタブを表示"],
        ]
        for language in AppLanguage.allCases {
            let items = AppDelegate.makeMainMenu(modeKey: .modeStandard, language: language).tabItems
            XCTAssertEqual(items.all.map(\.1.title), expected[language], "\(language)")
            let status = NSMenu()
            AppDelegate.fillStatusMenu(status, language: language)
            XCTAssertEqual(status.items.first { $0.action == #selector(TabMenus.statusNewTab(_:)) }?.title, expected[language]?.first)
        }
        // 重建后接上：按这一刻的情形改（新的一份菜单项也对）。
        let rig = make()
        let first = try build(rig, language: .english)
        _ = try XCTUnwrap(rig.tabs.newTab())
        let second = try build(rig, language: .japanese)
        XCTAssertEqual(visible(second.file).suffix(2), ["タブを閉じる ⌘W", "ウインドウを閉じる ⇧⌘W"])
        XCTAssertEqual(visible(first.file).suffix(2), ["Close Tab ⌘W", "Close Window ⇧⌘W"])
    }

    // MARK: - 到上限

    /// 到上限：⌘T、⇧⌘T（有记录）按键经入口显示“最多打开 4 个标签页”的提示（记录留着）；菜单的那几项置灰、下面写着同一句话。
    func testTheLimitHintForKeysAndMenus() throws {
        let rig = make()
        let built = try build(rig)
        _ = try XCTUnwrap(rig.tabs.newTab())
        try leaveARecord(rig)
        _ = try XCTUnwrap(rig.tabs.newTab())
        _ = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertTrue(rig.tabs.list.isFull)
        let window = try XCTUnwrap(rig.controller.window).windowNumber
        func press(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> Bool {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                       windowNumber: window, context: nil, characters: characters,
                                                       charactersIgnoringModifiers: characters, isARepeat: false,
                                                       keyCode: UInt16(kVK_ANSI_T)))
            return rig.controller.handleKeyDown(KeyPress(event))
        }
        var mark = rig.mark()
        XCTAssertTrue(try press("t", .command))
        // 时间线不记 [keys] 的行（跟着真实输入写的），按键的那一行在诊断里看。
        XCTAssertEqual(rig.lines(since: mark), ["[tabs] 不新增标签页：已到上限（4 个）", "[hint] 显示 到上限（4 个）的提示"])
        XCTAssertEqual(rig.diagnostics.entries.last { $0.category == "keys" && $0.message.hasPrefix("标签页按键") }?.message, "标签页按键 ⌘T")
        mark = rig.mark()
        XCTAssertTrue(try press("T", [.command, .shift]))
        XCTAssertEqual(rig.lines(since: mark), [
            "[tabs] 不重新打开标签页：已到上限（4 个）", "[hint] 到上限（4 个）的提示还显示着，重新计时",
        ])
        XCTAssertEqual(rig.diagnostics.entries.last { $0.category == "keys" && $0.message.hasPrefix("标签页按键") }?.message, "标签页按键 ⇧⌘T")
        XCTAssertTrue(rig.tabs.canReopenClosedTab, "记录留着")
        XCTAssertEqual(rig.limitHints, 2)

        let limit = TabHint.limit(capacity: 4).text()
        XCTAssertFalse(built.menus.validateMenuItem(built.items.newTab))
        XCTAssertFalse(built.menus.validateMenuItem(built.items.reopenClosedTab))
        XCTAssertEqual(built.items.newTab.subtitle, limit)
        XCTAssertEqual(built.items.reopenClosedTab.subtitle, limit)
        mark = rig.mark()
        built.menus.newTab(nil)
        XCTAssertEqual(rig.lines(since: mark), ["[menu] 菜单 新建标签页：现在不能用，不做"], "置灰的项不会被点到；直接调用也不做")
    }
}
