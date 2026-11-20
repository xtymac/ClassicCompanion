import Foundation
import Testing
@testable import CompanionCore

/// 标签页的按键：认哪些键（match），这一刻做什么（keyAction）。
@Suite struct TabKeysTests {
    typealias M = TabKeys.Modifiers

    /// `count` 个标签页，选中从左数第 `chosen` 个（0 起）。
    func list(_ count: Int, selected chosen: Int) -> TabList {
        var list = TabList()
        for _ in 1..<count { _ = list.append() }
        _ = list.select(list.tabs[chosen])
        return list
    }

    // MARK: 认键

    /// 每个键：正好的修饰键、它的字符（含按着 ⇧ 时的字符、大写锁定时的大写）→ 要做的事和键名。
    static let matches: [(String?, UInt16, M, TabKeys.Command, String)] = [
        ("t", 17, [.command], .newTab, "⌘T"),
        ("T", 17, [.command], .newTab, "⌘T"),
        ("T", 17, [.command, .shift], .reopenClosedTab, "⇧⌘T"),
        ("t", 17, [.command, .shift], .reopenClosedTab, "⇧⌘T"),
        ("w", 13, [.command], .closeTab, "⌘W"),
        ("W", 13, [.command], .closeTab, "⌘W"),
        ("W", 13, [.command, .shift], .hideWindow, "⇧⌘W"),
        ("}", 30, [.command, .shift], .next, "⇧⌘]"),
        ("]", 30, [.command, .shift], .next, "⇧⌘]"),
        ("{", 33, [.command, .shift], .previous, "⇧⌘["),
        ("[", 33, [.command, .shift], .previous, "⇧⌘["),
        ("\t", 48, [.control], .next, "⌃Tab"),
        (nil, 48, [.control], .next, "⌃Tab"),
        ("\u{19}", 48, [.control, .shift], .previous, "⌃⇧Tab"),
        ("\t", 48, [.control, .shift], .previous, "⌃⇧Tab"),
        ("1", 18, [.command], .position(1), "⌘1"),
        ("2", 19, [.command], .position(2), "⌘2"),
        ("3", 20, [.command], .position(3), "⌘3"),
        ("4", 21, [.command], .position(4), "⌘4"),
        ("9", 25, [.command], .last, "⌘9"),
    ]

    @Test(arguments: matches) func eachTabKeyIsRecognised(_ key: (String?, UInt16, M, TabKeys.Command, String)) {
        let (characters, keyCode, modifiers, command, name) = key
        #expect(TabKeys.match(characters: characters, keyCode: keyCode, modifiers: modifiers) == TabKeys.Match(command, name))
    }

    /// 同一个字符或 Tab 键，修饰键不对（多了、少了、带着 fn 等别的标志）：不是标签页的键。
    @Test func otherModifiersAreNotTabKeys() {
        let letters: [(String, [M])] = [
            ("t", [[], [.shift], [.option], [.control], [.command, .option], [.command, .control], [.command, .other],
                   [.command, .shift, .option], [.command, .shift, .control], [.command, .shift, .other]]),
            ("w", [[], [.shift], [.command, .option], [.command, .control], [.command, .other], [.command, .shift, .other],
                   [.command, .shift, .option]]),
            ("}", [[.command], [.shift], [.command, .option, .shift], [.command, .shift, .other], [.control, .shift]]),
            ("]", [[.command], [.command, .option], [.command, .control], []]),
            ("{", [[.command], [.command, .shift, .control]]),
            ("[", [[.command], [.command, .option]]),
            ("1", [[], [.command, .shift], [.command, .option], [.command, .control], [.command, .other]]),
            ("9", [[.command, .shift], [.command, .other]]),
        ]
        for (characters, sets) in letters {
            for modifiers in sets {
                #expect(TabKeys.match(characters: characters, keyCode: 0, modifiers: modifiers) == nil,
                        "\(characters) \(modifiers.rawValue)")
            }
        }
        for modifiers: M in [[], [.shift], [.command], [.option], [.command, .shift], [.control, .option],
                             [.control, .command], [.control, .other], [.control, .shift, .other], [.control, .shift, .option]] {
            #expect(TabKeys.match(characters: "\t", keyCode: 48, modifiers: modifiers) == nil, "Tab \(modifiers.rawValue)")
        }
    }

    /// 别的键：⌘5–⌘8、⌘0、纯 ⌘[ ⌘]（后退、前进）、⇧⌘ 的数字、别的字母、没有字符、法文 AZERTY 上不按 ⇧ 的“&”、
    /// 不是 Tab 键的制表字符：都不是。
    @Test func otherKeysAreNotTabKeys() {
        let others: [(String?, UInt16, M)] = [
            ("5", 23, [.command]), ("6", 22, [.command]), ("7", 26, [.command]), ("8", 28, [.command]), ("0", 29, [.command]),
            ("[", 33, [.command]), ("]", 30, [.command]),
            ("!", 18, [.command, .shift]), ("(", 25, [.command, .shift]),
            ("n", 45, [.command]), ("r", 15, [.command]), ("f", 3, [.command, .control]), ("q", 12, [.command]),
            ("z", 6, [.command, .shift]), ("r", 15, [.command, .shift]),
            (nil, 17, [.command]), (nil, 13, [.command]), ("", 17, [.command]),
            ("&", 18, [.command]),
            ("\t", 0, [.control]), ("\u{19}", 0, [.control, .shift]),
            ("tt", 17, [.command]),
        ]
        for (characters, keyCode, modifiers) in others {
            #expect(TabKeys.match(characters: characters, keyCode: keyCode, modifiers: modifiers) == nil,
                    "\(characters ?? "nil") \(keyCode) \(modifiers.rawValue)")
        }
    }

    // MARK: 这一刻做什么

    static let commands: [TabKeys.Command] = [
        .newTab, .reopenClosedTab, .closeTab, .hideWindow, .next, .previous,
        .position(1), .position(2), .position(3), .position(4), .last,
    ]

    /// 在聊天窗口里、没有模态框、不是用户的键、不是重复时，按列表算出来的应有结果（不经 TabList 的查询，自己按下标算）。
    func expected(_ command: TabKeys.Command, count: Int, chosen: Int, ids: [TabID]) -> TabKeys.Action {
        let index: Int?
        switch command {
        case .newTab: return .newTab
        case .reopenClosedTab: return .reopenClosedTab
        case .closeTab: return .closeTab
        case .hideWindow: return .hideWindow
        case .next: index = (chosen + 1) % count
        case .previous: index = (chosen + count - 1) % count
        case .position(let n): index = n <= count ? n - 1 : nil
        case .last: index = count - 1
        }
        guard let index, index != chosen else { return .swallow }
        return .select(ids[index])
    }

    /// 1–4 个标签页、每个选中位置、每个键、情形的每种组合（在不在聊天窗口、模态框、是不是用户的键、是不是重复）。
    @Test(arguments: 1...4) func everyKeyInEverySituation(count: Int) {
        for chosen in 0..<count {
            let l = list(count, selected: chosen)
            for command in Self.commands {
                for inWindow in [true, false] {
                    for modal in [false, true] {
                        for taken in [false, true] {
                            for repeating in [false, true] {
                                let context = TabKeys.Context(inChatWindow: inWindow, appModal: modal,
                                                              takenByUserHotKey: taken, isRepeat: repeating)
                                let want: TabKeys.Action
                                if !inWindow || modal { want = .pass }
                                else if taken && command != .closeTab { want = .pass }
                                else if repeating { want = .swallow }
                                else { want = expected(command, count: count, chosen: chosen, ids: l.tabs) }
                                #expect(TabKeys.keyAction(command, context, list: l) == want,
                                        "\(count) 个选中第 \(chosen + 1) 个 \(command) 窗口=\(inWindow) 模态=\(modal) 用户的键=\(taken) 重复=\(repeating)")
                            }
                        }
                    }
                }
            }
        }
    }

    /// 几个读起来直接的例子（上面那张表的一部分）。
    @Test func examples() {
        let inWindow = TabKeys.Context(inChatWindow: true)
        let two = list(2, selected: 1)
        #expect(TabKeys.keyAction(.position(3), inWindow, list: two) == .swallow, "⌘3 时只有两个：吃掉，什么都不做")
        #expect(TabKeys.keyAction(.position(1), inWindow, list: two) == .select(two.tabs[0]))
        #expect(TabKeys.keyAction(.next, inWindow, list: two) == .select(two.tabs[0]), "最右之后回到最左")
        #expect(TabKeys.keyAction(.last, inWindow, list: two) == .swallow, "已经是最后一个")
        let one = TabList()
        #expect(TabKeys.keyAction(.next, inWindow, list: one) == .swallow, "只有一个：下一个吃掉")
        #expect(TabKeys.keyAction(.previous, inWindow, list: one) == .swallow)
        #expect(TabKeys.keyAction(.closeTab, inWindow, list: one) == .closeTab, "只有一个时的 ⌘W 照常交给关闭（它隐藏窗口）")
        #expect(TabKeys.keyAction(.reopenClosedTab, inWindow, list: one) == .reopenClosedTab, "没有记录也交给入口（它写一行）")
        let taken = TabKeys.Context(inChatWindow: true, takenByUserHotKey: true)
        #expect(TabKeys.keyAction(.reopenClosedTab, taken, list: one) == .pass, "用户把 ⇧⌘T 设成了自己的键")
        #expect(TabKeys.keyAction(.closeTab, taken, list: one) == .closeTab, "⌘W 照旧")
        let otherWindow = TabKeys.Context(inChatWindow: false)
        #expect(TabKeys.keyAction(.closeTab, otherWindow, list: one) == .pass, "设置等别的窗口里的 ⌘W 交给菜单")
    }
}
