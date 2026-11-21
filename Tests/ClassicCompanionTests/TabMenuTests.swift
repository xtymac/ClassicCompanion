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
        /// 整个主菜单。
        let main: NSMenu
        let file: NSMenu
        let window: NSMenu
        let toolbar: ToolbarState
        let items: TabMenus.Items
    }

    /// 主菜单（language、切换键 modeKey）和接上它的 TabMenus，像 AppDelegate 那样接：用户的键里有切换键，
    /// 标签页的个数变了就 refresh。
    private func build(_ rig: TabCloseRig, language: AppLanguage = .simplifiedChinese,
                       modeKey: HotKeyCombo = .modeStandard) throws -> Built {
        let toolbar = ToolbarState()
        let menus = TabMenus(tabs: rig.tabs, chatWindow: rig.controller.window, diagnostics: rig.diagnostics, toolbar: toolbar)
        menus.keyWindow = { [weak self] in self?.key }
        menus.isAppModal = { [weak self] in self?.modal ?? false }
        menus.currentEventIsRepeat = { [weak self] in self?.repeating ?? false }
        menus.userHotKeys = { [modeKey] }
        rig.tabs.onTabsChanged = { [weak menus] in menus?.refresh() }
        let main = AppDelegate.makeMainMenu(modeKey: modeKey, language: language)
        menus.attach(main.tabItems)
        let file = try XCTUnwrap(main.menu.item(at: 1)?.submenu)
        let window = try XCTUnwrap(main.menu.item(at: 4)?.submenu)
        XCTAssertTrue(window === main.windowMenu)
        return Built(menus: menus, main: main.menu, file: file, window: window, toolbar: toolbar, items: main.tabItems)
    }

    /// 这一项的快捷键按菜单的写法（⌃⌥⇧⌘ 加键，Tab 写成 Tab），没有是 nil。字符是大写字母时算上 ⇧（AppKit 这样认：
    /// “重做”的字符是大写 Z，就是 ⇧⌘Z）。
    private func keys(_ item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        var mask = item.keyEquivalentModifierMask
        if key != key.lowercased() { mask.insert(.shift) }
        var keys = ""
        if mask.contains(.control) { keys += "⌃" }
        if mask.contains(.option) { keys += "⌥" }
        if mask.contains(.shift) { keys += "⇧" }
        if mask.contains(.command) { keys += "⌘" }
        if mask.contains(.function) { keys += "fn" }
        return keys + (key == "\t" ? "Tab" : key.uppercased())
    }

    /// “标题 快捷键”。
    private func describe(_ item: NSMenuItem) -> String {
        if item.isSeparatorItem { return "—" }
        return keys(item).map { "\(item.title) \($0)" } ?? item.title
    }

    /// 菜单里（连子菜单、连藏着的项）每个快捷键在哪几项上。
    private func holders(_ menu: NSMenu) -> [String: [NSMenuItem]] {
        var result: [String: [NSMenuItem]] = [:]
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let keys = keys(item) { result[keys, default: []].append(item) }
                item.submenu.map(walk)
            }
        }
        walk(menu)
        return result
    }

    /// 没有两项拿着同一个快捷键（连子菜单、连藏着的项）。
    private func assertNoSharedKeys(_ menu: NSMenu, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for (keys, items) in holders(menu) where items.count > 1 {
            XCTFail("\(what)：\(keys) 在 \(items.count) 项上：\(items.map { "\($0.title)\($0.isHidden ? "（藏着）" : "")" })",
                    file: file, line: line)
        }
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

    // MARK: - 快捷键不重复

    /// 看着的菜单（文件菜单）：每次它的项变了（NSMenu 的通知，改快捷键时就发）都看一遍没有两项拿着同一个快捷键。
    private var watched: NSMenu?
    private var watchedChanges = 0
    private var midwayShared: [String] = []

    @objc private func watchedMenuChanged(_ notification: Notification) {
        guard let watched else { return }
        watchedChanges += 1
        for (keys, items) in holders(watched) where items.count > 1 {
            midwayShared.append("\(keys)：\(items.map(\.title))")
        }
    }

    /// AppKit 的主菜单里几项的快捷键相同、动作不同时，只有先登记的那一项拿着它，后来的那一项既不显示、也不接这个键，藏着的项也算
    /// （11-21 用户看到多个标签页时“关闭标签页”没有 ⌘W：藏着的原来那一项还拿着它）。这里看不到 AppKit 画出来的样子，看的是
    /// 规则本身：每种情形下整个主菜单（连子菜单、连藏着的项）没有两项拿着同一个快捷键；⌘W 在显示着的那一项上——多个标签页、
    /// 聊天窗口在前面时是关闭标签页（藏着的原来那一项不带 ⌘W，按不到 performClose），别的时候是原来的关闭窗口（D11：设置等窗口里
    /// ⌘W 关那个窗口）。改到一半时也没有。菜单栏图标的菜单没有快捷键。
    func testNoTwoMenuItemsShareAKeyEquivalent() throws {
        // 刚建好、还没接上 TabMenus：就是一个标签页时的样子。
        let raw = AppDelegate.makeMainMenu(modeKey: .modeStandard, language: .simplifiedChinese)
        assertNoSharedKeys(raw.menu, "刚建好")
        XCTAssertTrue(holders(raw.menu)["⌘W"]?.first === raw.tabItems.closeWindow)

        let rig = make()
        let built = try build(rig)
        let i = built.items
        watched = built.file
        NotificationCenter.default.addObserver(self, selector: #selector(watchedMenuChanged(_:)), name: NSMenu.didChangeItemNotification,
                                               object: built.file)
        addTeardownBlock { @MainActor [weak self] in
            guard let self else { return }
            NotificationCenter.default.removeObserver(self, name: NSMenu.didChangeItemNotification, object: nil)
        }
        func check(_ main: NSMenu, _ menus: TabMenus, closeKeyOn closer: NSMenuItem, _ what: String,
                   file: StaticString = #filePath, line: UInt = #line) {
            assertNoSharedKeys(main, what, file: file, line: line)
            let w = holders(main)["⌘W"] ?? []
            XCTAssertTrue(w.count == 1 && w[0] === closer && !closer.isHidden,
                          "\(what)：⌘W 应该在“\(describe(closer))”上，现在在 \(w.map(describe))", file: file, line: line)
            let status = NSMenu()
            AppDelegate.fillStatusMenu(status, language: .simplifiedChinese)
            menus.attachStatus(status)
            XCTAssertTrue(holders(status).isEmpty, "\(what)：菜单栏图标的菜单没有快捷键", file: file, line: line)
        }

        check(built.main, built.menus, closeKeyOn: i.closeWindow, "一个标签页")
        _ = try XCTUnwrap(rig.tabs.newTab())
        check(built.main, built.menus, closeKeyOn: i.closeTab, "两个标签页")
        XCTAssertEqual(i.closeWindow.keyEquivalent, "", "藏着的原来那一项不带 ⌘W")
        key = other
        built.menus.refresh()
        check(built.main, built.menus, closeKeyOn: i.closeWindow, "别的窗口在前面")
        key = nil
        built.menus.refresh()
        check(built.main, built.menus, closeKeyOn: i.closeWindow, "没有 key 窗口")
        key = rig.controller.window
        built.menus.refresh()
        check(built.main, built.menus, closeKeyOn: i.closeTab, "聊天窗口回到前面")
        modal = true
        built.menus.refresh()
        check(built.main, built.menus, closeKeyOn: i.closeWindow, "模态框")
        modal = false
        built.menus.refresh()
        _ = try XCTUnwrap(rig.tabs.newTab())
        _ = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertTrue(rig.tabs.list.isFull)
        check(built.main, built.menus, closeKeyOn: i.closeTab, "到上限")

        // 聊天窗口里按 ⌘W：窗口的按键监视处理、吃掉（到不了菜单），关掉选中的那一个，不隐藏窗口。
        let window = try XCTUnwrap(rig.controller.window).windowNumber
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                   windowNumber: window, context: nil, characters: "w", charactersIgnoringModifiers: "w",
                                                   isARepeat: false, keyCode: UInt16(kVK_ANSI_W)))
        let mark = rig.mark()
        XCTAssertTrue(rig.controller.handleKeyDown(KeyPress(event)), "按键监视吃掉 ⌘W")
        XCTAssertEqual(rig.tabs.tabs.count, 3)
        XCTAssertEqual(rig.hidden, [])
        XCTAssertEqual(menuLines(rig, since: mark), [], "不经菜单")
        check(built.main, built.menus, closeKeyOn: i.closeTab, "按 ⌘W 关了一个")

        while rig.tabs.tabs.count > 1 { rig.tabs.closeSelectedTab() }
        check(built.main, built.menus, closeKeyOn: i.closeWindow, "关回一个")
        XCTAssertGreaterThan(watchedChanges, 0, "改快捷键时文件菜单发了通知")
        XCTAssertEqual(midwayShared, [], "改到一半时两项拿着同一个快捷键")

        // 用户的切换键就是标签页的某个组合（这些组合加进保留的键以前设的）：切换键那一项拿着它，标签页的那一项不带。
        // ⌘W 不在这里：录制时一直不让设，也不算用户的键（TabMenuRules）。
        let taken: [(String, HotKeyCombo)] = [
            ("⌘T", HotKeyCombo(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(cmdKey))),
            ("⇧⌘T", HotKeyCombo(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(cmdKey | shiftKey))),
            ("⇧⌘W", HotKeyCombo(keyCode: UInt32(kVK_ANSI_W), carbonModifiers: UInt32(cmdKey | shiftKey))),
            ("⌃Tab", HotKeyCombo(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(controlKey))),
            ("⌃⇧Tab", HotKeyCombo(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(controlKey | shiftKey))),
        ]
        for (name, combo) in taken {
            let rig = make()
            let built = try build(rig, modeKey: combo)
            let mode = try XCTUnwrap(built.file.item(at: 3))
            XCTAssertEqual(mode.title, "切换小窗 / 完整窗口")
            check(built.main, built.menus, closeKeyOn: built.items.closeWindow, "切换键是 \(name)，一个标签页")
            _ = try XCTUnwrap(rig.tabs.newTab())
            check(built.main, built.menus, closeKeyOn: built.items.closeTab, "切换键是 \(name)，两个标签页")
            // 这台机器的键盘布局上 T、W 不在美式键盘的位置时，切换键那一项的字符是别的，就不和标签页的项比。
            if combo.menuKeyEquivalent.map({ $0.key == "t" || $0.key == "w" || $0.key == "\t" }) == true {
                XCTAssertTrue(holders(built.main)[name]?.first === mode, "\(name) 在切换键那一项上")
            }
        }
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
        // 到上限（有记录）：新建、重新打开置灰，写上原因；菜单栏图标的还能点（D9：找回窗口、显示提示），也写上原因；别的照样。
        _ = try XCTUnwrap(rig.tabs.newTab())
        _ = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertTrue(rig.tabs.list.isFull)
        check(built, [false, false, true, true, true, true, true], "到上限")
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

    /// 窗口隐藏着、到上限：菜单栏图标的“新建标签页”还能点（D9）；点了先找回窗口，再显示到上限的提示，不新增、不建。
    func testStatusNewTabAtTheLimitRevealsTheWindowThenShowsTheLimitHint() throws {
        let rig = make()
        let built = try build(rig)
        for _ in 0..<3 { _ = try XCTUnwrap(rig.tabs.newTab()) }
        XCTAssertTrue(rig.tabs.list.isFull)
        rig.tabs.windowIsVisible = { false }
        key = nil
        built.menus.refresh()
        let status = NSMenu()
        AppDelegate.fillStatusMenu(status)
        built.menus.attachStatus(status)
        let item = try XCTUnwrap(built.menus.statusNewTab)
        XCTAssertTrue(built.menus.validateMenuItem(item))
        let list = rig.tabs.list, hints = rig.limitHints
        let mark = rig.mark()
        built.menus.statusNewTab(nil)
        XCTAssertEqual(rig.lines(since: mark), [
            "[menu] 菜单 新建标签页（菜单栏图标）", "[tabs] 不新增标签页：已到上限（4 个）",
            "[tabs] 窗口没有显示，先找回窗口再提示", "找回窗口", "[hint] 显示 到上限（4 个）的提示",
        ])
        XCTAssertEqual(rig.limitHints, hints + 1)
        XCTAssertEqual(rig.tabs.list, list, "不新增")
    }

    /// 窗口显示着（可能在别的窗口、别的应用后面）：菜单栏图标的“新建标签页”也先把窗口带到前面（同一个找回窗口的入口，
    /// 它自己看要不要激活、放到前面），再新增。聊天窗口是 key 窗口、别的窗口是 key 窗口、没有 key 窗口（别的应用在前面）都一样。
    func testStatusNewTabBringsAShownWindowForwardFirst() throws {
        let rig = make()
        let built = try build(rig)
        for front in [nil, other, rig.controller.window] {
            key = front
            let mark = rig.mark()
            let count = rig.tabs.tabs.count
            built.menus.statusNewTab(nil)
            let lines = rig.lines(since: mark)
            XCTAssertEqual(Array(lines.prefix(3)), ["[menu] 菜单 新建标签页（菜单栏图标）", "[tabs] 新增标签页：先把窗口带到前面", "找回窗口"])
            XCTAssertEqual(lines.filter { $0 == "找回窗口" }.count, 1)
            XCTAssertEqual(rig.tabs.tabs.count, count + 1)
        }
    }

    /// 窗口显示着、到上限：菜单栏图标的“新建标签页”先把窗口带到前面，再显示到上限的提示（好让人看见），不新增。
    func testStatusNewTabAtTheLimitBringsAShownWindowForwardThenShowsTheLimitHint() throws {
        let rig = make()
        let built = try build(rig)
        for _ in 0..<3 { _ = try XCTUnwrap(rig.tabs.newTab()) }
        XCTAssertTrue(rig.tabs.list.isFull)
        key = nil
        let list = rig.tabs.list, hints = rig.limitHints
        let mark = rig.mark()
        built.menus.statusNewTab(nil)
        XCTAssertEqual(rig.lines(since: mark), [
            "[menu] 菜单 新建标签页（菜单栏图标）", "[tabs] 不新增标签页：已到上限（4 个）",
            "[tabs] 先把窗口带到前面再提示", "找回窗口", "[hint] 显示 到上限（4 个）的提示",
        ])
        XCTAssertEqual(rig.limitHints, hints + 1)
        XCTAssertEqual(rig.tabs.list, list, "不新增")
    }

    /// 只有菜单栏图标的那一项把显示着的窗口带到前面：文件菜单的“新建标签页”和 ⌘T 照原来，窗口显示着就不找回
    /// （新增时、⌘T 到上限时都不），也不写“带到前面”的行。到上限时文件菜单的那一项本来就置灰、不做。
    func testTheFileMenuAndCommandTDoNotBringAShownWindowForward() throws {
        let rig = make()
        let built = try build(rig)
        let newTabKey = TabKeys.Match(.newTab, "⌘T")
        let inChat = TabKeys.Context(inChatWindow: true)
        let mark = rig.mark()
        built.menus.newTab(nil)
        XCTAssertTrue(rig.tabs.handleKey(newTabKey, inChat))
        XCTAssertEqual(rig.tabs.tabs.count, 3)
        built.menus.newTab(nil)
        XCTAssertTrue(rig.tabs.list.isFull)
        built.menus.newTab(nil)
        XCTAssertTrue(rig.tabs.handleKey(newTabKey, inChat))
        let lines = rig.lines(since: mark)
        XCTAssertTrue(lines.contains("[menu] 菜单 新建标签页：现在不能用，不做"), "到上限时文件菜单的那一项置灰")
        XCTAssertEqual(lines.filter { $0.hasPrefix("[tabs] 不新增标签页") }.count, 1)
        XCTAssertEqual(lines.filter { $0.hasPrefix("[hint] 显示 到上限") }.count, 1, "⌘T 到上限照样提示")
        XCTAssertFalse(lines.contains("找回窗口"))
        XCTAssertFalse(lines.contains { $0.contains("带到前面") || $0.contains("找回窗口") })
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
