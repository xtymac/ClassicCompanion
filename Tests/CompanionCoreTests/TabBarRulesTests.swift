import Foundation
import Testing
@testable import CompanionCore

/// 标签栏的纯规则（4.1）：标题怎么显示、每个标签多宽、＋ 的样子。
@Suite struct TabBarRulesTests {
    /// 空的、只有空白、加载中、正好是 “ChatGPT”：nil（显示“新聊天”）；别的去掉首尾空白照样显示。
    @Test func displayTitle() {
        for untitled in [nil, "", "   ", "\n\t ", "ChatGPT", "  ChatGPT \n"] as [String?] {
            #expect(TabBarRules.displayTitle(pageTitle: untitled, isLoading: false) == nil, "\(String(describing: untitled))")
        }
        #expect(TabBarRules.displayTitle(pageTitle: "Trip plan", isLoading: true) == nil, "加载中")
        #expect(TabBarRules.displayTitle(pageTitle: "Trip plan", isLoading: false) == "Trip plan")
        #expect(TabBarRules.displayTitle(pageTitle: "  Trip plan \n", isLoading: false) == "Trip plan")
        #expect(TabBarRules.displayTitle(pageTitle: "ChatGPT - x", isLoading: false) == "ChatGPT - x", "只比相等")
        #expect(TabBarRules.displayTitle(pageTitle: "chatgpt", isLoading: false) == "chatgpt")
    }

    @Test func showsBarFromTwoTabs() {
        #expect(!TabBarRules.showsBar(tabCount: 1))
        #expect(TabBarRules.showsBar(tabCount: 2))
        #expect(TabBarRules.showsBar(tabCount: 4))
    }

    /// 480 宽、4 个标签：(480 − 2×12 − 3×4 − 4 − 26) ÷ 4 = 103.5。标签、间距、边距、＋ 加起来正好是整个宽度；再窄也不给负数。
    @Test func equalTabWidths() {
        #expect(TabBarRules.tabWidth(availableWidth: 480, tabCount: 4) == 103.5)
        #expect(TabBarRules.tabWidth(availableWidth: 640, tabCount: 2) == (640 - 24 - 4 - 4 - 26) / 2)
        for width in [480.0, 640, 1000] {
            for count in 1...4 {
                let tab = TabBarRules.tabWidth(availableWidth: width, tabCount: count)
                let total = 2 * TabBarRules.sideMargin + Double(count) * tab + Double(count) * TabBarRules.gap
                    + TabBarRules.newTabButtonWidth
                #expect(abs(total - width) < 0.001, "\(width) \(count)")
            }
        }
        for width in [0.0, 10, 50, 66, 78] {
            for count in 1...4 { #expect(TabBarRules.tabWidth(availableWidth: width, tabCount: count) >= 0) }
        }
        #expect(TabBarRules.tabWidth(availableWidth: 480, tabCount: 0) == 0)
    }

    /// ＋：平常能点、不置灰；到上限置灰但还能点、写上原因；启动画面、模态框时点不了；不看哪个窗口在前面。
    @Test(arguments: TabMenuRules.Scope.allCases) func newTabButton(scope: TabMenuRules.Scope) {
        typealias Button = TabBarRules.NewTabButton
        func button(modal: Bool = false, launch: Bool = false, full: Bool = false) -> Button {
            TabBarRules.newTabButton(in: TabMenuRules.State(scope: scope, appModal: modal, launchScreenUp: launch,
                                                            atLimit: full, tabCount: full ? 4 : 2))
        }
        #expect(button() == Button(dimmed: false, clickable: true, explainsLimit: false))
        #expect(button(full: true) == Button(dimmed: true, clickable: true, explainsLimit: true))
        #expect(button(launch: true) == Button(dimmed: true, clickable: false, explainsLimit: false))
        #expect(button(launch: true, full: true) == Button(dimmed: true, clickable: false, explainsLimit: false))
        #expect(button(modal: true, full: true) == Button(dimmed: true, clickable: false, explainsLimit: false))
    }
}
