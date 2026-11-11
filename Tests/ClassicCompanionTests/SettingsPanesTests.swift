import XCTest
import SwiftUI
@testable import ClassicCompanion
import CompanionCore

/// 设置分成“通用 / 快捷键 / 高级”三页（用户 2026-11-10）。每个现有选项都要有去处，存储键和默认值不变。
@MainActor
final class SettingsPanesTests: XCTestCase {
    private let suite = "cc.settings.panes.tests"

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        LanguageController.shared.preference = .system
        super.tearDown()
    }

    private func freshSettings() -> AppSettings {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        return AppSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    // MARK: - 归组

    func testPanesAreGeneralShortcutsAdvancedInThatOrder() {
        XCTAssertEqual(SettingsPane.allCases, [.general, .shortcuts, .advanced])
    }

    func testEachPaneHoldsTheRequestedSettings() {
        XCTAssertEqual(SettingsPane.general.items,
                       [.appLanguage, .pageZoom, .restoreLastConversation, .focusInputOnShow, .escapeHidesWindow])
        XCTAssertEqual(SettingsPane.shortcuts.items, [.wakeShortcut, .modeShortcut])
        XCTAssertEqual(SettingsPane.advanced.items, [.webEnhancements, .allowPageAccessibility, .diagnostics])
    }

    func testEverySettingAppearsOnExactlyOnePane() {
        let placed = SettingsPane.allCases.flatMap(\.items)
        XCTAssertEqual(placed.count, Set(placed).count, "有选项出现在两页上")
        XCTAssertEqual(Set(placed), Set(SettingsItem.allCases), "有选项没有去处")
    }

    /// 盘点：AppSettings 里用户能改的每个存储键都在某一页上；不在设置里显示的只有内部记录和旧版遗留。
    func testEveryUserFacingStoredKeyIsOnAPane() {
        // 把 AppSettings 的每个属性原样写一遍，存下来的键就是它管理的全部键。
        let settings = freshSettings()
        settings.hotKey = settings.hotKey
        settings.modeKey = settings.modeKey
        settings.rateLevel = settings.rateLevel
        settings.webEnhancements = settings.webEnhancements
        settings.focusInputOnShow = settings.focusInputOnShow
        settings.escapeHidesWindow = settings.escapeHidesWindow
        settings.restoreLastConversation = settings.restoreLastConversation
        settings.allowPageAccessibility = settings.allowPageAccessibility
        settings.pageZoom = settings.pageZoom
        settings.lastConversationURL = URL(string: "https://chatgpt.com/c/test")
        let stored = Set(UserDefaults(suiteName: suite)!.persistentDomain(forName: suite)?.keys.map { $0 } ?? [])
        XCTAssertEqual(stored.count, 12)
        let placed = Set(SettingsItem.allCases.flatMap(\.storageKeys))
        // rateLevel：旧版自带朗读的语速，界面早已不显示，存储保留不动；lastConversationURL：应用自己记的最近对话。
        let notShown: Set<String> = ["rateLevel", "lastConversationURL"]
        XCTAssertEqual(stored.subtracting(notShown).subtracting(placed), [], "有存储的设置没有放到任何一页")
        XCTAssertEqual(placed.subtracting(stored), [LanguagePreference.defaultsKey], "页面上的键必须是现有的存储键")
    }

    // MARK: - 网页增强依赖

    func testOnlyInputFocusAndEscapeDependOnWebEnhancements() {
        XCTAssertEqual(SettingsItem.allCases.filter(\.requiresWebEnhancements), [.focusInputOnShow, .escapeHidesWindow])
    }

    func testDependentSettingsAreUnavailableWhileWebEnhancementsAreOff() {
        let settings = freshSettings()
        settings.webEnhancements = false
        XCTAssertFalse(SettingsItem.focusInputOnShow.isAvailable(in: settings))
        XCTAssertFalse(SettingsItem.escapeHidesWindow.isAvailable(in: settings))
        XCTAssertTrue(SettingsItem.restoreLastConversation.isAvailable(in: settings))
        XCTAssertTrue(SettingsItem.allowPageAccessibility.isAvailable(in: settings))
        settings.webEnhancements = true
        XCTAssertTrue(SettingsItem.allCases.allSatisfy { $0.isAvailable(in: settings) })
    }

    func testTurningWebEnhancementsOffKeepsTheSavedDependentValues() {
        let settings = freshSettings()
        settings.focusInputOnShow = false
        settings.escapeHidesWindow = true
        settings.webEnhancements = false
        XCTAssertFalse(settings.focusInputOnShow)
        XCTAssertTrue(settings.escapeHidesWindow)
        // 重启后也一样，重新打开网页增强后原样恢复。
        let reopened = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertFalse(reopened.webEnhancements)
        XCTAssertFalse(reopened.focusInputOnShow)
        XCTAssertTrue(reopened.escapeHidesWindow)
        reopened.webEnhancements = true
        XCTAssertFalse(reopened.focusInputOnShow)
        XCTAssertTrue(reopened.escapeHidesWindow)
    }

    func testDefaultsAreUnchanged() {
        let settings = freshSettings()
        XCTAssertTrue(settings.webEnhancements)
        XCTAssertTrue(settings.focusInputOnShow)
        XCTAssertTrue(settings.escapeHidesWindow)
        XCTAssertTrue(settings.restoreLastConversation)
        XCTAssertFalse(settings.allowPageAccessibility)
        XCTAssertEqual(settings.pageZoom, PageZoom.actualSize)
        XCTAssertEqual(settings.hotKey, .standard)
        XCTAssertEqual(settings.modeKey, .modeStandard)
    }

    // MARK: - 四种语言

    func testPaneTitlesUseTheRequestedWords() {
        let expected: [AppLanguage: [String]] = [
            .simplifiedChinese: ["通用", "快捷键", "高级"],
            .traditionalChinese: ["一般", "快速鍵", "進階"],
            .english: ["General", "Shortcuts", "Advanced"],
            .japanese: ["一般", "ショートカット", "詳細"],
        ]
        for (language, titles) in expected {
            XCTAssertEqual(SettingsPane.allCases.map { $0.title(in: language) }, titles, language.rawValue)
        }
    }

    func testNewSettingsTextsExistInEveryLanguage() {
        let keys = ["settings.web.note", "settings.web.dependencyNote", "settings.assistive.purpose",
                    "settings.assistive.learnMore", "settings.assistive.details", "settings.web.requiredHint",
                    "settings.assistive.expanded", "settings.assistive.collapsed"]
        for language in AppLanguage.allCases {
            for key in keys {
                XCTAssertNotEqual(L10n.string(key, in: language), key, "\(language.rawValue) 缺 \(key)")
            }
        }
    }

    /// 详细说明折叠起来，但内容不能丢：性能影响和重启要求都还在。
    func testAssistiveDetailsKeepThePerformanceAndRestartNotes() {
        XCTAssertTrue(L10n.string("settings.assistive.details", in: .simplifiedChinese).contains("卡顿"))
        XCTAssertTrue(L10n.string("settings.assistive.details", in: .simplifiedChinese).contains("重启"))
        XCTAssertTrue(L10n.string("settings.assistive.details", in: .english).contains("freeze"))
        XCTAssertTrue(L10n.string("settings.assistive.details", in: .english).contains("restart"))
    }

    // MARK: - 页面切换

    private func makeTabs() -> SettingsTabsController {
        SettingsTabsController { pane in NSViewController.placeholder(pane) }
    }

    func testTabsFollowThePaneOrderWithLocalizedLabels() {
        LanguageController.shared.preference = .english
        let tabs = makeTabs()
        XCTAssertEqual(tabs.tabStyle, .toolbar)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["General", "Shortcuts", "Advanced"])
        XCTAssertTrue(tabs.tabViewItems.allSatisfy { $0.image != nil })
        XCTAssertEqual(tabs.selectedPane, .general)
    }

    func testRelabelKeepsTheCurrentPane() {
        LanguageController.shared.preference = .english
        let tabs = makeTabs()
        tabs.selectedPane = .advanced
        LanguageController.shared.preference = .japanese
        tabs.relabel()
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["一般", "ショートカット", "詳細"])
        XCTAssertEqual(tabs.selectedPane, .advanced)
    }

    /// 录制中切到别的页面：快捷键那一页看不见了，录制要结束，不然按键还会被悄悄录走。
    func testLeavingAPaneIsReported() {
        let tabs = makeTabs()
        var left: [SettingsPane] = []
        tabs.onLeavePane = { left.append($0) }
        tabs.selectedPane = .shortcuts
        tabs.selectedPane = .advanced
        tabs.selectedPane = .advanced
        XCTAssertEqual(left, [.general, .shortcuts])
    }

    /// 工具栏拿页面的 identifier 当工具栏项目标识，不是字符串时窗口一显示就崩溃（预览探针 00:42 发现）。
    func testTabIdentifiersAreToolbarIdentifierStrings() {
        let ids = makeTabs().tabViewItems.map { $0.identifier as? String }
        XCTAssertEqual(ids, ["settings.pane.general", "settings.pane.shortcuts", "settings.pane.advanced"])
    }

    /// 窗口标题保持“Classic Companion 设置”，不被页面名覆盖。
    func testSelectingAPaneDoesNotRetitleTheWindow() {
        XCTAssertFalse(makeTabs().canPropagateSelectedChildViewControllerTitle)
    }
}

private extension NSViewController {
    static func placeholder(_ pane: SettingsPane) -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        controller.title = "\(pane)"
        return controller
    }
}
