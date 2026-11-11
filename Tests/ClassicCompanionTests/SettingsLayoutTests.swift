import XCTest
import SwiftUI
@testable import ClassicCompanion

/// 设置窗口改成三页后，窗口高度是固定的首选值，不再按旧的整张长表单（英文约 1150 pt）定。
/// 屏幕放不下时只缩内容区，内容区自己滚动；页面切换在窗口工具栏里，始终看得见。
/// 只量 NSHostingView，不建窗口。
@MainActor
final class SettingsLayoutTests: XCTestCase {
    private let suite = "cc.settings.layout.tests"

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        LanguageController.shared.preference = .system
        super.tearDown()
    }

    private func host(_ pane: SettingsPane, webEnhancements: Bool = true) -> NSHostingView<SettingsPaneView> {
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.webEnhancements = webEnhancements
        let view = SettingsPaneView(pane: pane, settings: settings, diagnostics: Diagnostics(),
                                    hotKeyRecorder: HotKeyRecorderModel(apply: { _ in nil }, onPause: {}, onResume: {}),
                                    modeKeyRecorder: HotKeyRecorderModel(defaultCombo: .modeStandard, apply: { _ in nil },
                                                                         onPause: {}, onResume: {}),
                                    onShowDiagnostics: {})
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// 内建屏上每一页都不用滚动（“了解更多”收起时），四种语言、网页增强开关两种状态都算。
    func testEveryPaneFitsThePreferredHeightInEveryLanguage() {
        for language in AppLanguage.allCases {
            LanguageController.shared.preference = LanguagePreference(rawValue: language.rawValue)!
            for pane in SettingsPane.allCases {
                for web in [true, false] {
                    let height = host(pane, webEnhancements: web).fittingSize.height
                    XCTAssertLessThanOrEqual(height, SettingsWindowLayout.contentHeight,
                                             "\(language.rawValue) \(pane) web=\(web) 需要 \(height)")
                }
            }
        }
    }

    func testWindowIsNoLongerSizedByTheOldLongForm() {
        XCTAssertLessThan(SettingsWindowLayout.contentHeight, 600)
        XCTAssertEqual(SettingsWindowLayout.width, 500)
        // 内建屏（可用 1085 pt）和随航（993 pt）都用首选高度。
        XCTAssertEqual(SettingsWindowLayout.contentHeight(screenVisibleHeight: 1085, chrome: 90), SettingsWindowLayout.contentHeight)
        XCTAssertEqual(SettingsWindowLayout.contentHeight(screenVisibleHeight: 993, chrome: 90), SettingsWindowLayout.contentHeight)
    }

    func testShortScreenShrinksOnlyTheContentArea() {
        let limited = SettingsWindowLayout.contentHeight(screenVisibleHeight: 480, chrome: 90)
        XCTAssertLessThan(limited, SettingsWindowLayout.contentHeight)
        XCTAssertLessThanOrEqual(limited + 90, 480 - 20, "窗口上下要留一点空")
        // 很小的屏幕也留一个能用的下限。
        XCTAssertGreaterThanOrEqual(SettingsWindowLayout.contentHeight(screenVisibleHeight: 200, chrome: 90),
                                    SettingsWindowLayout.minimumContentHeight)
    }

    /// 内容区比内容矮时，表单在内容区里滚动，不把窗口撑高，最下面的控件滚过去就能点到。
    func testPaneScrollsInsideAShortContentArea() throws {
        for pane in SettingsPane.allCases {
            let host = host(pane)
            let natural = host.fittingSize.height
            let short = min(natural - 40, SettingsWindowLayout.minimumContentHeight)
            // 表单的行要放进窗口才排版。窗口不上屏、不激活。
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsWindowLayout.width, height: short),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: SettingsWindowLayout.width, height: short)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let scroll = try XCTUnwrap(Self.scrollView(in: host), "\(pane) 没有滚动区")
            XCTAssertLessThanOrEqual(scroll.frame.height, short + 0.5, "\(pane)")
            XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, scroll.frame.height, "\(pane) 内容应能滚动")
        }
    }

    /// 真实的设置窗口（不上屏）：工具栏样式、固定内容大小；矮屏幕只缩内容区；切换页面不改窗口大小和标题。
    func testSettingsWindowKeepsItsSizeToolbarAndTitle() throws {
        let tabs = SettingsTabsController { _ in
            let host = NSHostingController(rootView: Text(verbatim: "pane"))
            host.sizingOptions = []
            return host
        }
        let window = SettingsTabsController.makeWindow(tabs)
        defer { window.close() }
        XCTAssertEqual(window.toolbarStyle, .preference)
        XCTAssertNotNil(window.toolbar, "工具栏在窗口上屏前就要在，算高度时才算得进去")
        XCTAssertEqual(window.toolbar?.allowsUserCustomization, false, "三个页面不能被用户从工具栏移走")
        XCTAssertEqual(window.title, L10n.string("window.settings"))
        let content = try XCTUnwrap(window.contentView)

        SettingsTabsController.fit(window, screenVisibleHeight: 1085)
        XCTAssertEqual(content.frame.size, NSSize(width: SettingsWindowLayout.width, height: SettingsWindowLayout.contentHeight))
        let chrome = window.frame.height - content.frame.height
        XCTAssertGreaterThan(chrome, 60, "标题栏加工具栏")

        tabs.selectedPane = .advanced
        XCTAssertEqual(content.frame.height, SettingsWindowLayout.contentHeight, "切换页面不改窗口大小")
        XCTAssertEqual(window.title, L10n.string("window.settings"), "切换页面不改窗口标题")

        SettingsTabsController.fit(window, screenVisibleHeight: 480)
        XCTAssertEqual(content.frame.height, SettingsWindowLayout.contentHeight(screenVisibleHeight: 480, chrome: chrome))
        XCTAssertLessThanOrEqual(window.frame.height, 480 - 20)
        XCTAssertFalse(SettingsTabsController.fit(window, screenVisibleHeight: 480), "大小没变时不重排")
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scrollView).first
    }
}
