import AppKit
import Carbon.HIToolbox
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 标签页的键（3.10）经窗口的按键监视（ChatWindowController.handleKeyDown(_:)）到 ChatTabs.handleKey(_:_:)。
/// 按键用 NSEvent.keyEvent(...) 造出来、取出事实（KeyPress）直接交给 handleKeyDown，不发真的按键、不显示窗口。
/// 一组是 TabCloseRig（像 AppDelegate 那样建：正式的建法、真的窗口控制器；隐藏窗口、找回窗口、提示音都是记录）。
/// 不测切换键本身（切换模式会显示窗口）：只按不是切换键的组合；切换键优先只经 userHotKeyTakes(_:) 和 handleKey 核对。
@MainActor
final class TabKeyTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc")!

    private func make() -> TabCloseRig {
        let name = "TabKeyTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let rig = TabCloseRig(defaults: UserDefaults(suiteName: name)!)
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        return rig
    }

    /// 本窗口的窗口号（真的、大于 0：和“别的窗口”的号分得开）。
    private func number(_ rig: TabCloseRig) throws -> Int {
        let number = try XCTUnwrap(rig.controller.window?.windowNumber)
        XCTAssertGreaterThan(number, 0)
        return number
    }

    private func event(_ characters: String, _ keyCode: Int, _ flags: NSEvent.ModifierFlags, window: Int,
                       repeating: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: repeating, keyCode: UInt16(keyCode)))
    }

    /// 在 rig 的窗口里按一下（window 给了就是那个窗口），返回按键监视吃没吃掉。
    @discardableResult
    private func press(_ rig: TabCloseRig, _ characters: String, _ keyCode: Int, _ flags: NSEvent.ModifierFlags,
                       window: Int? = nil, repeating: Bool = false) throws -> Bool {
        let press = KeyPress(try event(characters, keyCode, flags, window: try window ?? number(rig), repeating: repeating))
        guard press.combo != rig.controller.modeKey else {
            XCTFail("测试不按切换键：切换模式会显示窗口")
            return false
        }
        return rig.controller.handleKeyDown(press)
    }

    // 各个键（美式键盘的字符）。
    private func commandT(_ rig: TabCloseRig, repeating: Bool = false) throws -> Bool {
        try press(rig, "t", kVK_ANSI_T, .command, repeating: repeating)
    }
    private func commandShiftT(_ rig: TabCloseRig) throws -> Bool { try press(rig, "T", kVK_ANSI_T, [.command, .shift]) }
    private func commandW(_ rig: TabCloseRig, repeating: Bool = false) throws -> Bool {
        try press(rig, "w", kVK_ANSI_W, .command, repeating: repeating)
    }
    private func commandShiftW(_ rig: TabCloseRig, repeating: Bool = false) throws -> Bool {
        try press(rig, "W", kVK_ANSI_W, [.command, .shift], repeating: repeating)
    }
    private func controlTab(_ rig: TabCloseRig, repeating: Bool = false) throws -> Bool {
        try press(rig, "\t", kVK_Tab, .control, repeating: repeating)
    }
    private func controlShiftTab(_ rig: TabCloseRig) throws -> Bool { try press(rig, "\u{19}", kVK_Tab, [.control, .shift]) }
    private func commandShiftRightBracket(_ rig: TabCloseRig) throws -> Bool {
        try press(rig, "}", kVK_ANSI_RightBracket, [.command, .shift])
    }
    private func commandShiftLeftBracket(_ rig: TabCloseRig) throws -> Bool {
        try press(rig, "{", kVK_ANSI_LeftBracket, [.command, .shift])
    }
    private func commandDigit(_ rig: TabCloseRig, _ digit: Int) throws -> Bool {
        let codes = [1: kVK_ANSI_1, 2: kVK_ANSI_2, 3: kVK_ANSI_3, 4: kVK_ANSI_4, 5: kVK_ANSI_5, 9: kVK_ANSI_9]
        return try press(rig, "\(digit)", try XCTUnwrap(codes[digit]), .command)
    }

    /// 日志里最后一条的标识，之后写的用 entries(_:after:) 取。
    private func mark(_ rig: TabCloseRig) -> UUID? {
        rig.diagnostics.entries.last?.id
    }

    private func entries(_ rig: TabCloseRig, after mark: UUID?) -> [Diagnostics.Entry] {
        let all = rig.diagnostics.entries
        guard let mark, let index = all.firstIndex(where: { $0.id == mark }) else { return all }
        return Array(all[(index + 1)...])
    }

    /// mark 之后这里写的“标签页按键”那几行。
    private func tabKeyLines(_ rig: TabCloseRig, after mark: UUID?) -> [String] {
        entries(rig, after: mark).filter { $0.category == "keys" && $0.message.hasPrefix("标签页按键") }.map(\.message)
    }

    // MARK: - ⌘W

    /// 只有一个标签页：⌘W 和原来一样只隐藏窗口，原因“⌘W”（正式运行时窗口写“[window] 隐藏：⌘W”），不写“标签页按键”那一行，
    /// 什么都不关。大写锁定开着（字符是“W”）也一样。
    func testCommandWWithOneTabHidesExactlyAsBefore() throws {
        let rig = make()
        let lines = rig.mark(), keys = mark(rig), list = rig.tabs.list
        XCTAssertTrue(try commandW(rig))
        XCTAssertTrue(try press(rig, "W", kVK_ANSI_W, [.command, .capsLock]))
        XCTAssertEqual(rig.hidden, ["⌘W", "⌘W"])
        XCTAssertEqual(rig.lines(since: lines), ["隐藏窗口：⌘W", "隐藏窗口：⌘W"])
        XCTAssertEqual(entries(rig, after: keys).filter { $0.category == "keys" }.map(\.message), [], "没有多写 [keys]")
        XCTAssertEqual(rig.tabs.list, list)
        XCTAssertFalse(rig.first.runtime.isClosed)
    }

    /// 多个标签页：⌘W 关闭选中的（和 closeSelectedTab 一样：选右边的邻居，没有就左边），写一行“标签页按键 ⌘W”；
    /// 关到只剩一个以后，⌘W 隐藏窗口，不写这一行。
    func testCommandWWithSeveralTabsClosesTheSelectedOne() throws {
        let rig = make()
        let b = try XCTUnwrap(rig.tabs.newTab()), c = try XCTUnwrap(rig.tabs.newTab())
        XCTAssertTrue(rig.tabs.selected === c)
        let keys = mark(rig)
        XCTAssertTrue(try commandW(rig))
        XCTAssertFalse(rig.tabs.holds(c))
        XCTAssertTrue(c.runtime.isClosed)
        XCTAssertTrue(rig.tabs.selected === b, "最右的关了选左边")
        XCTAssertTrue(rig.controller.webView === b.runtime.webView)
        XCTAssertTrue(try commandW(rig))
        XCTAssertTrue(rig.tabs.selected === rig.first)
        XCTAssertEqual(rig.tabs.tabs.count, 1)
        XCTAssertEqual(rig.hidden, [])
        XCTAssertTrue(try commandW(rig))
        XCTAssertEqual(rig.hidden, ["⌘W"])
        XCTAssertEqual(tabKeyLines(rig, after: keys), ["标签页按键 ⌘W", "标签页按键 ⌘W"])
    }

    /// 隐藏的原因和原来 ⌘W 交给窗口的是同一个，而且只有一条路：窗口不再自己隐藏（按键监视里没有 hide(reason: "⌘W")），
    /// ⌘W 经 ChatTabs.closeSelectedTab() 到 hideWindow("⌘W")，正式运行时它就是 windowController.hide(reason:)。
    func testCommandWHasOnePathToTheHide() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let window = try String(contentsOf: root.appendingPathComponent("Sources/ClassicCompanion/Window/ChatWindowController.swift"),
                                encoding: .utf8)
        XCTAssertFalse(window.contains("hide(reason: \"⌘W\")"))
        let rig = make()
        rig.controller.onTabKey = nil
        XCTAssertFalse(try commandW(rig), "没接上 ChatTabs 时 ⌘W 交给菜单（只建窗口的情形）")
        XCTAssertEqual(rig.hidden, [])
    }

    // MARK: - ⌘T、⇧⌘T、⇧⌘W

    /// ⌘T 新增（选中它）；有对话地址的那一页关掉以后，⇧⌘T 重新打开它（放回原位、选中、加载那个地址）。各写一行。
    /// ⇧⌘ 的键照原来还有 Phase 0 那一行（“⌘⇧ 组合到达…”），不变。
    func testCommandTAddsATabAndCommandShiftTReopensTheClosedOne() throws {
        let rig = make()
        let keys = mark(rig)
        XCTAssertTrue(try commandT(rig))
        XCTAssertEqual(rig.tabs.tabs.count, 2)
        let b = rig.tabs.selected
        XCTAssertFalse(b === rig.first)
        XCTAssertTrue(rig.controller.webView === b.runtime.webView)
        b.runtime.onURLChange?(chat)
        XCTAssertTrue(try commandW(rig))
        XCTAssertEqual(rig.tabs.tabs.count, 1)
        XCTAssertTrue(try commandShiftT(rig))
        XCTAssertEqual(rig.tabs.tabs.count, 2)
        let reopened = rig.tabs.selected
        XCTAssertFalse(reopened === b)
        XCTAssertTrue(rig.tabs.tabs.last === reopened, "放回原位（第 2 个）")
        XCTAssertEqual(rig.loads["\(reopened.id.rawValue)"], [chat])
        XCTAssertEqual(tabKeyLines(rig, after: keys), ["标签页按键 ⌘T", "标签页按键 ⌘W", "标签页按键 ⇧⌘T"])
        let arrivals = entries(rig, after: keys).filter { $0.category == "keys" && $0.message.contains("组合到达") }.map(\.message)
        XCTAssertEqual(arrivals, ["⌘⇧ 组合到达 keyCode=17 字符=T 本窗口=true 匹配切换=false"])
    }

    /// ⇧⌘W：隐藏窗口（原因“⇧⌘W”，和左上角的 × 一样只隐藏），标签页都留着、不关；只有一个时也一样。
    func testCommandShiftWHidesTheWindowAndKeepsEveryTab() throws {
        let rig = make()
        let b = try XCTUnwrap(rig.tabs.newTab())
        let keys = mark(rig), list = rig.tabs.list
        XCTAssertTrue(try commandShiftW(rig))
        XCTAssertEqual(rig.hidden, ["⇧⌘W"])
        XCTAssertEqual(rig.tabs.list, list)
        XCTAssertFalse(b.runtime.isClosed)
        XCTAssertTrue(rig.tabs.selected === b)
        let one = make()
        XCTAssertTrue(try commandShiftW(one))
        XCTAssertEqual(one.hidden, ["⇧⌘W"])
        XCTAssertEqual(tabKeyLines(rig, after: keys), ["标签页按键 ⇧⌘W"])
    }

    // MARK: - 做不了时照样吃掉

    /// 固定的键做不了时也吃掉（D13、D17），入口自己写一行或响一声：⇧⌘T 没有记录；⌘T 启动画面还在；⌘T 到上限；
    /// ⌘3 时只有两个；只有一个时的上一个、下一个；已经选中的 ⌘1、⌘9。
    func testFixedKeysThatCannotActAreStillSwallowed() throws {
        let rig = make()
        var lines = rig.mark()
        XCTAssertTrue(try commandShiftT(rig))
        XCTAssertEqual(rig.lines(since: lines), ["[tabs] 不重新打开标签页：没有记录"])
        let keys = mark(rig)
        XCTAssertTrue(try controlTab(rig))
        XCTAssertTrue(try controlShiftTab(rig))
        XCTAssertTrue(try commandShiftRightBracket(rig))
        XCTAssertTrue(try commandShiftLeftBracket(rig))
        XCTAssertTrue(try commandDigit(rig, 1))
        XCTAssertTrue(try commandDigit(rig, 9))
        XCTAssertTrue(try commandDigit(rig, 3))
        XCTAssertEqual(tabKeyLines(rig, after: keys), ["⌃Tab", "⌃⇧Tab", "⇧⌘]", "⇧⌘[", "⌘1", "⌘9", "⌘3"].map {
            "标签页按键 \($0)：没有可切换到的标签页，按键不交给网页"
        })
        XCTAssertEqual(rig.tabs.tabs.count, 1)
        XCTAssertTrue(try commandT(rig))
        XCTAssertTrue(try commandT(rig))
        XCTAssertTrue(try commandT(rig))
        XCTAssertEqual(rig.tabs.tabs.count, 4)
        lines = rig.mark()
        XCTAssertTrue(try commandT(rig))
        XCTAssertEqual(rig.lines(since: lines), ["提示音", "[tabs] 不新增标签页：已到上限（4 个）"])
        XCTAssertEqual(rig.tabs.tabs.count, 4)

        let two = make()
        _ = try XCTUnwrap(two.tabs.newTab())
        let before = two.tabs.list
        XCTAssertTrue(try commandDigit(two, 3), "⌘3 时只有两个")
        XCTAssertTrue(try commandDigit(two, 9), "已经是最后一个")
        XCTAssertEqual(two.tabs.list, before)

        let launching = make()
        launching.controller.beginLaunchScreen()
        lines = launching.mark()
        XCTAssertTrue(try commandT(launching))
        XCTAssertEqual(launching.lines(since: lines), ["[tabs] 不新增标签页：启动画面还在"])
        XCTAssertEqual(launching.tabs.tabs.count, 1)
    }

    // MARK: - 切换

    /// 四个标签页（选中第 4 个）：⌃Tab ⇧⌘] 下一个、⌃⇧Tab ⇧⌘[ 上一个，到头绕回；⌘1–⌘4 第 N 个；⌘9 最后一个。
    /// 每次都经 ChatTabs.select（写“选中”那一行，窗口换上那一页），各写一行“标签页按键 X”。
    func testSwitchingKeysWrapAndPickByPosition() throws {
        let rig = make()
        let all = [rig.first] + (try (1...3).map { _ in try XCTUnwrap(rig.tabs.newTab()) })
        XCTAssertTrue(rig.tabs.selected === all[3])
        let keys = mark(rig), lines = rig.mark()
        let steps: [(String, (TabCloseRig) throws -> Bool, Int)] = [
            ("⌃Tab", { try self.controlTab($0) }, 0), ("⌃⇧Tab", { try self.controlShiftTab($0) }, 3),
            ("⇧⌘]", { try self.commandShiftRightBracket($0) }, 0), ("⇧⌘[", { try self.commandShiftLeftBracket($0) }, 3),
            ("⇧⌘[", { try self.commandShiftLeftBracket($0) }, 2), ("⌃Tab", { try self.controlTab($0) }, 3),
            ("⌘2", { try self.commandDigit($0, 2) }, 1), ("⌘9", { try self.commandDigit($0, 9) }, 3),
            ("⌘1", { try self.commandDigit($0, 1) }, 0), ("⌘4", { try self.commandDigit($0, 4) }, 3),
            ("⌘3", { try self.commandDigit($0, 3) }, 2),
        ]
        for (name, key, target) in steps {
            XCTAssertTrue(try key(rig), name)
            XCTAssertTrue(rig.tabs.selected === all[target], "\(name) → 第 \(target + 1) 个")
            XCTAssertTrue(rig.controller.webView === all[target].runtime.webView, "\(name)：窗口显示它")
        }
        XCTAssertEqual(tabKeyLines(rig, after: keys), steps.map { "标签页按键 \($0.0)" })
        let selections = rig.lines(since: lines).filter { $0.hasPrefix("[tabs] 选中") }
        XCTAssertEqual(selections, steps.map { "[tabs] 选中 【标签\(all[$0.2].id.rawValue)】" })
        XCTAssertEqual(rig.tabs.tabs.count, 4)
    }

    // MARK: - 重复按键

    /// 按住不放的重复按键：吃掉、不做、不写行。只有一个标签页时重复的 ⌘W 也不隐藏（原来会：有意的改变）。
    func testRepeatsAreSwallowedWithoutActing() throws {
        let rig = make()
        let b = try XCTUnwrap(rig.tabs.newTab())
        let keys = mark(rig), list = rig.tabs.list
        XCTAssertTrue(try commandW(rig, repeating: true))
        XCTAssertTrue(try commandT(rig, repeating: true))
        XCTAssertTrue(try controlTab(rig, repeating: true))
        XCTAssertTrue(try commandShiftW(rig, repeating: true))
        XCTAssertEqual(rig.tabs.list, list)
        XCTAssertTrue(rig.tabs.selected === b)
        XCTAssertEqual(rig.hidden, [])
        XCTAssertEqual(tabKeyLines(rig, after: keys), [])

        let one = make()
        XCTAssertTrue(try commandW(one, repeating: true))
        XCTAssertEqual(one.hidden, [])
    }

    // MARK: - 不拦的

    /// 别的窗口（设置、诊断、登录弹窗等）的按键：都不拦，什么都不做（D11）。
    func testKeysOfAnotherWindowAreNotIntercepted() throws {
        let rig = make(), other = make()
        _ = try XCTUnwrap(rig.tabs.newTab())
        let elsewhere = try number(other)
        XCTAssertNotEqual(elsewhere, try number(rig))
        let keys = mark(rig), list = rig.tabs.list
        for (characters, code, flags) in tabKeyPresses {
            XCTAssertFalse(try press(rig, characters, code, flags, window: elsewhere), characters)
        }
        XCTAssertEqual(rig.tabs.list, list)
        XCTAssertEqual(rig.hidden, [])
        XCTAssertEqual(tabKeyLines(rig, after: keys), [])
    }

    /// 有应用级模态框（提示框等）：都不拦（按键交给模态框）。
    func testAnAppModalAlertKeepsBlockingTheKeys() throws {
        let rig = make()
        _ = try XCTUnwrap(rig.tabs.newTab())
        rig.controller.isAppModal = { true }
        let keys = mark(rig), list = rig.tabs.list
        for (characters, code, flags) in tabKeyPresses {
            XCTAssertFalse(try press(rig, characters, code, flags), characters)
        }
        XCTAssertEqual(rig.tabs.list, list)
        XCTAssertEqual(rig.hidden, [])
        XCTAssertEqual(tabKeyLines(rig, after: keys), [])
    }

    /// 每个标签页的键按一次（美式键盘）。
    private var tabKeyPresses: [(String, Int, NSEvent.ModifierFlags)] {
        [("t", kVK_ANSI_T, .command), ("T", kVK_ANSI_T, [.command, .shift]), ("w", kVK_ANSI_W, .command),
         ("W", kVK_ANSI_W, [.command, .shift]), ("\t", kVK_Tab, .control), ("\u{19}", kVK_Tab, [.control, .shift]),
         ("}", kVK_ANSI_RightBracket, [.command, .shift]), ("{", kVK_ANSI_LeftBracket, [.command, .shift]),
         ("1", kVK_ANSI_1, .command), ("2", kVK_ANSI_2, .command), ("4", kVK_ANSI_4, .command), ("9", kVK_ANSI_9, .command)]
    }

    /// 不是标签页的键：照原来交给网页（⌘N、⌘R 由菜单，纯 ⌘[ ⌘] 是后退前进，⌘5 没有，带 ⌥ 的、纯 Tab、Esc）。
    func testOtherKeysPassUntouched() throws {
        let rig = make()
        _ = try XCTUnwrap(rig.tabs.newTab())
        let keys = mark(rig), list = rig.tabs.list
        let others: [(String, Int, NSEvent.ModifierFlags)] = [
            ("n", kVK_ANSI_N, .command), ("r", kVK_ANSI_R, .command), ("[", kVK_ANSI_LeftBracket, .command),
            ("]", kVK_ANSI_RightBracket, .command), ("5", kVK_ANSI_5, .command), ("t", kVK_ANSI_T, [.command, .option]),
            ("w", kVK_ANSI_W, [.command, .control]), ("\t", kVK_Tab, []), ("\t", kVK_Tab, .option), ("t", kVK_ANSI_T, []),
            ("\u{1b}", kVK_Escape, []),
        ]
        for (characters, code, flags) in others {
            XCTAssertFalse(try press(rig, characters, code, flags), "\(characters) \(flags.rawValue)")
        }
        XCTAssertEqual(rig.tabs.list, list)
        XCTAssertEqual(rig.hidden, [])
        XCTAssertEqual(tabKeyLines(rig, after: keys), [])
    }

    // MARK: - 用户自己的键优先

    /// 唤醒键（注册失败、录制时暂停注册的时候按键会到这里）就是这个组合：标签页的键不做，交给原来的路（返回 false）。
    /// ⌘W 例外：照旧关闭或隐藏。
    func testTheUserWakeKeyWins() throws {
        let rig = make()
        let b = try XCTUnwrap(rig.tabs.newTab())
        b.runtime.onURLChange?(chat)
        let keys = mark(rig)
        rig.controller.wakeKey = HotKeyCombo(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(cmdKey | shiftKey))
        XCTAssertFalse(try commandShiftT(rig))
        rig.controller.wakeKey = HotKeyCombo(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(controlKey))
        XCTAssertFalse(try controlTab(rig))
        XCTAssertTrue(rig.tabs.selected === b)
        XCTAssertEqual(rig.tabs.tabs.count, 2)
        XCTAssertEqual(tabKeyLines(rig, after: keys), [])
        rig.controller.wakeKey = HotKeyCombo(keyCode: UInt32(kVK_ANSI_W), carbonModifiers: UInt32(cmdKey))
        XCTAssertTrue(try commandW(rig), "⌘W 照旧")
        XCTAssertFalse(rig.tabs.holds(b))
    }

    /// 切换键就是这个组合：userHotKeyTakes 认它，ChatTabs 不做、返回 false（窗口接着当切换键处理；
    /// 切换模式会显示窗口，这里不经 handleKeyDown 按它）。
    func testTheUserModeKeyWins() throws {
        let rig = make()
        _ = try XCTUnwrap(rig.tabs.newTab())
        let standard = rig.controller.modeKey
        addTeardownBlock { rig.controller.modeKey = standard }
        rig.controller.modeKey = HotKeyCombo(keyCode: UInt32(kVK_ANSI_LeftBracket), carbonModifiers: UInt32(cmdKey | shiftKey))
        let pressed = KeyPress(try event("{", kVK_ANSI_LeftBracket, [.command, .shift], window: try number(rig)))
        XCTAssertTrue(rig.controller.userHotKeyTakes(pressed))
        let key = try XCTUnwrap(pressed.tabKey)
        let keys = mark(rig), list = rig.tabs.list
        XCTAssertFalse(rig.tabs.handleKey(key, TabKeys.Context(inChatWindow: true, takenByUserHotKey: true)))
        XCTAssertEqual(rig.tabs.list, list)
        XCTAssertEqual(tabKeyLines(rig, after: keys), [])
        let other = KeyPress(try event("}", kVK_ANSI_RightBracket, [.command, .shift], window: try number(rig)))
        XCTAssertFalse(rig.controller.userHotKeyTakes(other), "别的组合不算")
        rig.controller.wakeKey = nil
        rig.controller.modeKey = standard
        XCTAssertFalse(rig.controller.userHotKeyTakes(pressed))
    }

    /// 正式运行时唤醒键跟着设置交给窗口（和切换键一样）。
    func testTheAppPassesTheWakeKeyToTheWindow() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/ClassicCompanion/App/AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("settings.$hotKey.removeDuplicates().sink { [weak self] combo in self?.windowController.wakeKey = combo }"))
        let tabs = try String(contentsOf: root.appendingPathComponent("Sources/ClassicCompanion/Tabs/ChatTabs.swift"), encoding: .utf8)
        XCTAssertTrue(tabs.contains("windowController.onTabKey = { [weak self] key, context in self?.handleKey(key, context) ?? false }"))
    }

    // MARK: - 认法和原来一样

    /// 留给测试的三个认法（⌘W、Esc、切换键）现在都问 KeyPress：和原来写在这里的判断逐个比，修饰标志的每种组合、几个字符。
    func testTheMatchersAgreeWithTheOldOnes() throws {
        let bits: [NSEvent.ModifierFlags] = [.command, .shift, .control, .option, .capsLock, .function, .numericPad, .help]
        let standard = HotKeyCombo.modeStandard
        for mask in 0..<(1 << bits.count) {
            let flags = NSEvent.ModifierFlags(bits.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            for (characters, code) in [("w", kVK_ANSI_W), ("W", kVK_ANSI_W), ("t", kVK_ANSI_T), ("f", kVK_ANSI_F),
                                       ("\u{1b}", kVK_Escape), ("ω", kVK_ANSI_W)] {
                let event = try event(characters, code, flags, window: 0)
                let oldClose = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command
                    && event.charactersIgnoringModifiers?.lowercased() == "w"
                let oldEscape = event.keyCode == 53
                    && event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function]).isEmpty
                let oldMode = UInt32(event.keyCode) == standard.keyCode
                    && HotKeyCombo.carbonModifiers(from: event.modifierFlags) == standard.carbonModifiers
                XCTAssertEqual(ChatWindowController.isCloseShortcut(event), oldClose, "\(characters) \(flags.rawValue)")
                XCTAssertEqual(ChatWindowController.isPlainEscape(event), oldEscape, "\(characters) \(flags.rawValue)")
                XCTAssertEqual(ChatWindowController.isModeShortcut(event, combo: standard), oldMode, "\(characters) \(flags.rawValue)")
            }
        }
    }

    // MARK: - 录制时不能设成这些

    /// 六个组合录制时被拒绝，说明它们的用途（四种语言）。之前已经设成这些组合的唤醒键、切换键照样读出来、留着。
    func testTheTabCombosAreReservedWithTheirPurpose() throws {
        let cases: [(Int, NSEvent.ModifierFlags, String, String, [String])] = [
            (kVK_Tab, .control, "Tab", "⌃Tab",
             ["switch to the next tab", "次のタブに切り替え", "切换到下一个标签页", "切換到下一個分頁"]),
            (kVK_Tab, [.control, .shift], "Tab", "⌃⇧Tab",
             ["switch to the previous tab", "前のタブに切り替え", "切换到上一个标签页", "切換到上一個分頁"]),
            (kVK_ANSI_RightBracket, [.command, .shift], "]", "⇧⌘]",
             ["switch to the next tab", "次のタブに切り替え", "切换到下一个标签页", "切換到下一個分頁"]),
            (kVK_ANSI_LeftBracket, [.command, .shift], "[", "⇧⌘[",
             ["switch to the previous tab", "前のタブに切り替え", "切换到上一个标签页", "切換到上一個分頁"]),
            (kVK_ANSI_T, [.command, .shift], "T", "⇧⌘T",
             ["reopen the last closed tab", "最後に閉じたタブを再度開く", "重新打开最近关闭的标签页", "重新打開最近關閉的分頁"]),
            (kVK_ANSI_W, [.command, .shift], "W", "⇧⌘W",
             ["hide the window and keep all tabs", "タブを残してウインドウを隠す", "隐藏窗口并保留标签页", "隱藏視窗並保留分頁"]),
        ]
        for (code, flags, keyName, name, purposes) in cases {
            guard case .reject(let text) = HotKeyCapture.evaluate(keyCode: UInt32(code), flags: flags, keyName: keyName) else {
                XCTFail("\(name) 应该被拒绝")
                continue
            }
            XCTAssertEqual(text.string(in: .english), "\(name) is used to \(purposes[0]). Choose another one.")
            XCTAssertEqual(text.string(in: .japanese), "\(name) は「\(purposes[1])」に使われています。別の組み合わせを選んでください。")
            XCTAssertEqual(text.string(in: .simplifiedChinese), "\(name) 用来\(purposes[2])，请换一个。")
            XCTAssertEqual(text.string(in: .traditionalChinese), "\(name) 用來\(purposes[3])，請換一個。")
        }
        guard case .reject = HotKeyCapture.evaluate(keyCode: UInt32(kVK_ANSI_T), flags: .command, keyName: "T") else {
            return XCTFail("⌘T 本来就被拒绝（纯 ⌘ 加一个字符）")
        }
        guard case .accept = HotKeyCapture.evaluate(keyCode: UInt32(kVK_Tab), flags: [.control, .option], keyName: "Tab") else {
            return XCTFail("⌃⌥Tab 不是标签页的键")
        }

        let name = "TabKeyTests-stored-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        defaults.set(kVK_ANSI_T, forKey: "hotKeyCode")
        defaults.set(cmdKey | shiftKey, forKey: "hotKeyModifiers")
        defaults.set(kVK_Tab, forKey: "modeKeyCode")
        defaults.set(controlKey, forKey: "modeKeyModifiers")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.hotKey, HotKeyCombo(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(cmdKey | shiftKey)))
        XCTAssertEqual(settings.modeKey, HotKeyCombo(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(controlKey)))
    }
}
