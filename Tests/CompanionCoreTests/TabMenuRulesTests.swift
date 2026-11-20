import Foundation
import Testing
@testable import CompanionCore

/// 标签页的菜单项（3.11）：每种情形下每一项的样子（TabMenuRules.look），和左上角 × 的提示里的键。
@Suite struct TabMenuRulesTests {
    typealias Item = TabMenuRules.Item
    typealias Look = TabMenuRules.Look

    /// 有快捷键、用户的键可能和它相同的项。
    static let keyed: [Item] = [.newTab, .reopenClosedTab, .hideWindowKeepingTabs, .nextTab, .previousTab]

    /// 不经 look 的写法，按项一条一条写出应有的样子（和 look 的写法分开写，用来对照）。
    func expected(_ item: Item, _ s: TabMenuRules.State) -> Look {
        let front = s.scope == .chatWindow
        if s.appModal {
            switch item {
            case .closeWindow: return Look(visible: true, enabled: true, showsKeyEquivalent: true)
            case .closeTab, .hideWindowKeepingTabs: return Look(visible: false, enabled: false, showsKeyEquivalent: false)
            default: return Look(visible: true, enabled: false, showsKeyEquivalent: false)
            }
        }
        let key = front && !s.takenByUserHotKey.contains(item)
        switch item {
        case .newTab:
            let enabled = front && !s.launchScreenUp && !s.atLimit
            return Look(visible: true, enabled: enabled, showsKeyEquivalent: key, explainsLimit: front && s.atLimit && !s.launchScreenUp)
        case .reopenClosedTab:
            let enabled = front && !s.launchScreenUp && !s.atLimit && s.canReopen
            return Look(visible: true, enabled: enabled, showsKeyEquivalent: key,
                        explainsLimit: front && s.atLimit && !s.launchScreenUp && s.canReopen)
        case .closeWindow:
            return Look(visible: !(front && s.tabCount > 1), enabled: true, showsKeyEquivalent: true)
        case .closeTab:
            let two = front && s.tabCount > 1
            return Look(visible: two, enabled: two, showsKeyEquivalent: two)
        case .hideWindowKeepingTabs:
            let two = front && s.tabCount > 1
            return Look(visible: two, enabled: two, showsKeyEquivalent: two && key)
        case .nextTab, .previousTab:
            return Look(visible: true, enabled: front && s.tabCount > 1, showsKeyEquivalent: key)
        case .statusNewTab:
            // 到上限也能点（D9：找回窗口、显示到上限的提示），照样写上原因。
            return Look(visible: true, enabled: !s.launchScreenUp, showsKeyEquivalent: false,
                        explainsLimit: s.atLimit && !s.launchScreenUp)
        }
    }

    /// 每种情形的每种组合：在前面的窗口、模态框、启动画面、到上限、有没有记录、1–4 个标签页、用户的键占了哪一项（不占、占一项）。
    @Test(arguments: TabMenuRules.Scope.allCases) func everyItemInEverySituation(scope: TabMenuRules.Scope) {
        let takenSets: [Set<Item>] = [[]] + Self.keyed.map { [$0] }
        for modal in [false, true] {
            for launch in [false, true] {
                for count in 1...4 {
                    for atLimit in [false, true] {
                        for canReopen in [false, true] {
                            for taken in takenSets {
                                let state = TabMenuRules.State(scope: scope, appModal: modal, launchScreenUp: launch, atLimit: atLimit,
                                                               canReopen: canReopen, tabCount: count, takenByUserHotKey: taken)
                                for item in Item.allCases {
                                    #expect(TabMenuRules.look(item, in: state) == expected(item, state), "\(item) \(state)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 几个读起来直接的例子（上面那张表的一部分）。
    @Test func examples() {
        let one = TabMenuRules.State(scope: .chatWindow)
        #expect(TabMenuRules.look(.newTab, in: one) == Look(visible: true, enabled: true, showsKeyEquivalent: true))
        #expect(TabMenuRules.look(.reopenClosedTab, in: one).enabled == false, "没有记录：置灰")
        #expect(TabMenuRules.look(.closeWindow, in: one).visible, "一个标签页：原来的关闭窗口 ⌘W")
        #expect(!TabMenuRules.look(.closeTab, in: one).visible)
        #expect(!TabMenuRules.look(.nextTab, in: one).enabled, "只有一个：下一个置灰")

        let four = TabMenuRules.State(scope: .chatWindow, atLimit: true, canReopen: true, tabCount: 4)
        #expect(TabMenuRules.look(.newTab, in: four) == Look(visible: true, enabled: false, showsKeyEquivalent: true, explainsLimit: true))
        #expect(TabMenuRules.look(.reopenClosedTab, in: four).explainsLimit, "有记录、到上限：写上原因")
        #expect(!TabMenuRules.look(.closeWindow, in: four).visible, "多个标签页：原来那一项藏起来")
        #expect(TabMenuRules.look(.closeTab, in: four) == Look(visible: true, enabled: true, showsKeyEquivalent: true))
        #expect(TabMenuRules.look(.hideWindowKeepingTabs, in: four).enabled)

        let settings = TabMenuRules.State(scope: .otherWindow, canReopen: true, tabCount: 3)
        #expect(TabMenuRules.look(.closeWindow, in: settings) == Look(visible: true, enabled: true, showsKeyEquivalent: true),
                "设置等窗口在前面：⌘W 关那个窗口（D11）")
        #expect(TabMenuRules.look(.newTab, in: settings) == Look(visible: true, enabled: false, showsKeyEquivalent: false))
        #expect(TabMenuRules.look(.nextTab, in: settings) == Look(visible: true, enabled: false, showsKeyEquivalent: false))
        #expect(TabMenuRules.look(.statusNewTab, in: settings).enabled, "菜单栏图标的菜单不看哪个窗口在前面")

        let hiddenAtLimit = TabMenuRules.State(scope: .noWindow, atLimit: true, canReopen: true, tabCount: 4)
        #expect(TabMenuRules.look(.statusNewTab, in: hiddenAtLimit)
                    == Look(visible: true, enabled: true, showsKeyEquivalent: false, explainsLimit: true),
                "窗口隐藏着、到上限：菜单栏图标的那一项能点（D9：找回窗口、显示到上限的提示），写上原因")
        #expect(!TabMenuRules.look(.newTab, in: hiddenAtLimit).enabled, "文件菜单的那一项照旧置灰")
        #expect(!TabMenuRules.look(.reopenClosedTab, in: hiddenAtLimit).enabled, "D15：到上限 ⇧⌘T 置灰")

        let modal = TabMenuRules.State(scope: .chatWindow, appModal: true, canReopen: true, tabCount: 2)
        for item in Item.allCases where item != .closeWindow {
            #expect(!TabMenuRules.look(item, in: modal).enabled, "模态框：\(item) 置灰")
        }

        let launch = TabMenuRules.State(scope: .chatWindow, launchScreenUp: true, atLimit: true, canReopen: true, tabCount: 4)
        #expect(TabMenuRules.look(.newTab, in: launch) == Look(visible: true, enabled: false, showsKeyEquivalent: true),
                "启动画面还在：置灰，不写到上限")

        let taken = TabMenuRules.State(scope: .chatWindow, canReopen: true, tabCount: 2, takenByUserHotKey: [.reopenClosedTab, .nextTab])
        #expect(TabMenuRules.look(.reopenClosedTab, in: taken) == Look(visible: true, enabled: true, showsKeyEquivalent: false),
                "用户的键是 ⇧⌘T：照样能点，不写快捷键")
        #expect(!TabMenuRules.look(.nextTab, in: taken).showsKeyEquivalent)
        #expect(TabMenuRules.look(.previousTab, in: taken).showsKeyEquivalent)
    }

    /// 左上角 × 的提示：一个标签页 ⌘W，多个 ⇧⌘W，⇧⌘W 是用户的键时不写键。
    @Test func hideButtonShortcut() {
        #expect(TabMenuRules.hideButtonShortcut(tabCount: 1, hideKeyTaken: false) == "⌘W")
        #expect(TabMenuRules.hideButtonShortcut(tabCount: 1, hideKeyTaken: true) == "⌘W")
        for count in 2...4 {
            #expect(TabMenuRules.hideButtonShortcut(tabCount: count, hideKeyTaken: false) == "⇧⌘W")
            #expect(TabMenuRules.hideButtonShortcut(tabCount: count, hideKeyTaken: true) == nil)
        }
    }
}
