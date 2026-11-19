import AppKit
import Carbon.HIToolbox
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 后退、前进：菜单（⌘[ ⌘]）、聊天窗口里的 ⌘[ ⌘]、鼠标侧键、顶部的返回箭头。
/// 不显示窗口、不发真实的按键和鼠标事件：处理函数直接用按键、侧键的值调用，窗口只创建不显示。
/// 真实网页（介绍页、登录流程）、输入框里按键、真实鼠标侧键和箭头的样子要在真实应用里确认。
@MainActor
final class HistoryNavigationTests: XCTestCase {
    /// 记下走了几次的假页面。
    private final class FakePage: HistoryPage {
        var canBack: Bool
        var canForward: Bool
        private(set) var went: [HistoryDirection] = []

        init(canBack: Bool = true, canForward: Bool = false) {
            self.canBack = canBack
            self.canForward = canForward
        }

        func canGo(_ direction: HistoryDirection) -> Bool { direction == .back ? canBack : canForward }

        @discardableResult func go(_ direction: HistoryDirection, source: String) -> Bool {
            guard canGo(direction) else { return false }
            went.append(direction)
            return true
        }
    }

    private final class Counter { var count = 0 }

    private func makeDefaults() -> UserDefaults {
        let name = "HistoryNavigationTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// 聊天窗口（只创建，不显示）。historyPage 每次被调用都记一次，用来确认目标页面每次操作只解析一次。
    private func makeController(page: FakePage, resolves: Counter = Counter()) throws -> (ChatWindowController, Int) {
        let controller = ChatWindowController(webView: WKWebView(), toolbar: EmptyView(), diagnostics: Diagnostics(),
                                              appearance: PageAppearance(defaults: makeDefaults()))
        controller.historyPage = { resolves.count += 1; return page }
        let number = try XCTUnwrap(controller.window).windowNumber
        XCTAssertGreaterThan(number, 0)
        return (controller, number)
    }

    // MARK: - 目标页面

    /// 菜单看 key 窗口：聊天窗口在前面时是它的页面；登录弹窗、设置等窗口在前面时没有目标，主窗口的页面不动。
    func testOnlyTheChatWindowHasATarget() {
        let chat = NSObject(), popup = NSObject(), settings = NSObject()
        let page = FakePage()
        XCTAssertTrue(HistoryNavigation.target(for: chat, chatWindow: chat, page: page) === page)
        XCTAssertNil(HistoryNavigation.target(for: popup, chatWindow: chat, page: page), "登录弹窗是 key 窗口")
        XCTAssertNil(HistoryNavigation.target(for: settings, chatWindow: chat, page: page))
        XCTAssertNil(HistoryNavigation.target(for: nil, chatWindow: chat, page: page), "没有 key 窗口")
        XCTAssertNil(HistoryNavigation.target(for: chat, chatWindow: nil, page: page))
        XCTAssertNil(HistoryNavigation.target(for: nil, chatWindow: nil, page: page))
        XCTAssertNil(HistoryNavigation.target(for: chat, chatWindow: chat, page: FakePage?.none))
    }

    /// 按键、侧键和箭头先看 key 窗口：登录弹窗是 key 窗口时，鼠标停在聊天窗口上按侧键、点箭头也不动聊天窗口的页面
    /// （登录途中主窗口换页可能打断弹窗里的登录）。应用不在前台、没有 key 窗口时，看事件所在的窗口。
    func testAPopupInFrontKeepsTheChatPageEvenUnderThePointer() {
        let chat = NSObject(), popup = NSObject()
        let page = FakePage()
        func target(key: NSObject?, event: NSObject?) -> FakePage? {
            HistoryNavigation.target(for: HistoryNavigation.commandWindow(keyWindow: key, eventWindow: event), chatWindow: chat, page: page)
        }
        XCTAssertNil(target(key: popup, event: chat), "弹窗在前面，侧键按在聊天窗口上")
        XCTAssertTrue(target(key: chat, event: chat) === page)
        XCTAssertTrue(target(key: nil, event: chat) === page, "应用不在前台时，侧键按在聊天窗口上")
        XCTAssertNil(target(key: nil, event: nil), "菜单没有事件窗口")
        XCTAssertTrue(target(key: chat, event: nil) === page, "菜单：聊天窗口是 key 窗口")
        XCTAssertNil(target(key: popup, event: nil), "菜单：弹窗是 key 窗口")
    }

    /// 没有目标时（AppDelegate 在弹窗是 key 窗口时给 nil），侧键按在聊天窗口上被吃掉，什么都不做；
    /// 按键原样放过（它本来就到不了这里：按键的窗口就是 key 窗口）。
    func testNoTargetMeansNothingHappens() throws {
        let page = FakePage()
        let controller = ChatWindowController(webView: WKWebView(), toolbar: EmptyView(), diagnostics: Diagnostics(),
                                              appearance: PageAppearance(defaults: makeDefaults()))
        let resolves = Counter()
        controller.historyPage = { resolves.count += 1; return nil }
        let number = try XCTUnwrap(controller.window).windowNumber
        XCTAssertTrue(controller.handleHistoryMouse(type: .otherMouseDown, button: 3, windowNumber: number))
        XCTAssertTrue(controller.handleHistoryMouse(type: .otherMouseUp, button: 3, windowNumber: number))
        XCTAssertFalse(controller.handleHistoryKey(.back, isRepeat: false, windowNumber: number))
        XCTAssertEqual(resolves.count, 2)
        XCTAssertEqual(page.went, [])
    }

    // MARK: - 菜单

    /// 菜单项跟着那一页的 canGoBack / canGoForward；弹窗在前面时没有目标，两项都是灰的。
    func testMenuItemsFollowCanGoBackAndCanGoForward() {
        let chat = NSObject(), popup = NSObject()
        let page = FakePage(canBack: true, canForward: false)
        let target = HistoryNavigation.target(for: chat, chatWindow: chat, page: page)
        XCTAssertTrue(HistoryNavigation.isAvailable(.back, on: target))
        XCTAssertFalse(HistoryNavigation.isAvailable(.forward, on: target))
        page.canBack = false
        page.canForward = true
        XCTAssertFalse(HistoryNavigation.isAvailable(.back, on: target))
        XCTAssertTrue(HistoryNavigation.isAvailable(.forward, on: target))
        page.canBack = true
        let popupTarget = HistoryNavigation.target(for: popup, chatWindow: chat, page: page)
        XCTAssertFalse(HistoryNavigation.isAvailable(.back, on: popupTarget), "弹窗是 key 窗口时灰掉")
        XCTAssertFalse(HistoryNavigation.isAvailable(.forward, on: popupTarget))
        XCTAssertEqual(page.went, [], "判断可用不会导航")
    }

    /// 文件菜单里有“后退 ⌘[”“前进 ⌘]”，每种语言一样；动作名不是 WKWebView 自己的 goBack，
    /// 响应链不会把它交给网页（包括登录弹窗），只会到 AppDelegate、经过目标页面的解析。
    func testMenuHasBackAndForwardWithTheirShortcutsInEveryLanguage() throws {
        for language in AppLanguage.allCases {
            let menu = AppDelegate.makeMainMenu(modeKey: .modeStandard, language: language).menu
            let file = try XCTUnwrap(menu.items.first { $0.submenu?.title == L10n.string("menu.file", in: language) }?.submenu)
            let items = file.items.filter { AppDelegate.historyDirection(of: $0.action) != nil }
            XCTAssertEqual(items.map { AppDelegate.historyDirection(of: $0.action) }, [.back, .forward], "\(language)")
            XCTAssertEqual(items.map(\.title), [L10n.string("menu.back", in: language), L10n.string("menu.forward", in: language)])
            XCTAssertEqual(items.map(\.keyEquivalent), ["[", "]"])
            XCTAssertEqual(items.map(\.keyEquivalentModifierMask), [.command, .command])
            for item in items {
                let action = try XCTUnwrap(item.action)
                XCTAssertFalse(WKWebView.instancesRespond(to: action), "\(NSStringFromSelector(action)) 不能被网页接走")
                XCTAssertTrue(AppDelegate.instancesRespond(to: action))
            }
        }
        XCTAssertNil(AppDelegate.historyDirection(of: #selector(NSApplication.terminate(_:))))
        XCTAssertNil(AppDelegate.historyDirection(of: nil))
    }

    // MARK: - 顶部返回箭头

    /// 只在不是聊天页面、并且能后退时显示；聊天页面上不管能不能后退都不显示。
    func testBackArrowShowsOnlyOffChatPagesWithSomewhereToGoBack() {
        let chatPages = ["https://chatgpt.com/", "https://chatgpt.com/c/abc", "https://chatgpt.com/g/g-1/c/2", "https://chatgpt.com/g/g-1"]
        let otherPages = ["https://chatgpt.com/pricing", "https://chatgpt.com/auth/login", "https://auth.openai.com/log-in",
                          "https://openai.com/chatgpt/pricing/"]
        for url in chatPages {
            XCTAssertFalse(HistoryNavigation.showsBackButton(url: URL(string: url), canGoBack: true), url)
            XCTAssertFalse(HistoryNavigation.showsBackButton(url: URL(string: url), canGoBack: false), url)
        }
        for url in otherPages {
            XCTAssertTrue(HistoryNavigation.showsBackButton(url: URL(string: url), canGoBack: true), url)
            XCTAssertFalse(HistoryNavigation.showsBackButton(url: URL(string: url), canGoBack: false), url)
        }
    }

    /// 箭头不显示时不占地方：聊天页面上顶部一条和以前一样宽。显示时多一个按钮加一个间距，最窄的窗口（480）也放得下。
    func testBackArrowOnlyTakesSpaceWhenShown() {
        func width(showsBack: Bool) -> CGFloat {
            let state = ToolbarState()
            state.showsBack = showsBack
            let bar = WebBar(onClose: {}, onNewChat: {}, onToggleMode: {}, onDoubleClick: {}, state: state,
                             appearance: PageAppearance(defaults: makeDefaults()), icon: NSImage(size: NSSize(width: 64, height: 64)))
            let host = NSHostingView(rootView: bar)
            host.frame = NSRect(x: 0, y: 0, width: 480, height: WebBar.height)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        let hidden = width(showsBack: false), shown = width(showsBack: true)
        XCTAssertEqual(shown - hidden, GlassCircleButton.size + 10, accuracy: 0.5)
        XCTAssertLessThanOrEqual(shown, 480)
    }

    // MARK: - ⌘[ ⌘]

    /// 只认纯 ⌘ 加 [ 或 ]。打字、输入法要用的 [ ]、带 ⇧ ⌥ ⌃ 的组合都交给网页。
    func testShortcutsArePlainCommandBrackets() {
        XCTAssertEqual(HistoryNavigation.direction(characters: "[", flags: .command), .back)
        XCTAssertEqual(HistoryNavigation.direction(characters: "]", flags: .command), .forward)
        XCTAssertEqual(HistoryNavigation.direction(characters: "[", flags: [.command, .capsLock]), .back, "大写锁定不算")
        XCTAssertNil(HistoryNavigation.direction(characters: "[", flags: []), "打字")
        XCTAssertNil(HistoryNavigation.direction(characters: "]", flags: []), "打字")
        XCTAssertNil(HistoryNavigation.direction(characters: "{", flags: [.command, .shift]))
        XCTAssertNil(HistoryNavigation.direction(characters: "[", flags: [.command, .shift]))
        XCTAssertNil(HistoryNavigation.direction(characters: "[", flags: [.command, .option]))
        XCTAssertNil(HistoryNavigation.direction(characters: "[", flags: [.command, .control]))
        XCTAssertNil(HistoryNavigation.direction(characters: "[", flags: .option))
        XCTAssertNil(HistoryNavigation.direction(characters: "「", flags: .command))
        XCTAssertNil(HistoryNavigation.direction(characters: "w", flags: .command))
        XCTAssertNil(HistoryNavigation.direction(characters: nil, flags: .command))
    }

    /// 用户把切换键设成 ⌘[ 时，用户的设置优先：⌘[ 只切换窗口，不后退。⌘] 不受影响。
    func testTheUsersModeKeyWinsOverTheFixedShortcut() throws {
        let (controller, _) = try makeController(page: FakePage())
        let bracket = UInt16(kVK_ANSI_LeftBracket)
        XCTAssertEqual(controller.historyShortcut(keyCode: bracket, characters: "[", flags: .command), .back, "默认的切换键是 ⌃⌘F")
        controller.modeKey = HotKeyCombo(keyCode: UInt32(kVK_ANSI_LeftBracket), carbonModifiers: UInt32(cmdKey))
        XCTAssertNil(controller.historyShortcut(keyCode: bracket, characters: "[", flags: .command))
        XCTAssertEqual(controller.historyShortcut(keyCode: UInt16(kVK_ANSI_RightBracket), characters: "]", flags: .command), .forward)
        XCTAssertNil(controller.historyShortcut(keyCode: bracket, characters: "[", flags: []), "打字")
    }

    /// 按一下走一次，目标页面只解析一次；按住不放的重复按键只吃掉，不连着后退。
    func testOneKeyPressGoesOnceAndRepeatsAreSwallowed() throws {
        let page = FakePage(canBack: true, canForward: true)
        let resolves = Counter()
        let (controller, number) = try makeController(page: page, resolves: resolves)
        XCTAssertTrue(controller.handleHistoryKey(.back, isRepeat: false, windowNumber: number))
        XCTAssertEqual(page.went, [.back])
        XCTAssertEqual(resolves.count, 1)
        for _ in 0..<3 { XCTAssertTrue(controller.handleHistoryKey(.back, isRepeat: true, windowNumber: number)) }
        XCTAssertEqual(page.went, [.back], "重复按键不再后退")
        XCTAssertTrue(controller.handleHistoryKey(.forward, isRepeat: false, windowNumber: number))
        XCTAssertEqual(page.went, [.back, .forward])
    }

    /// 走不了时不处理：按键原样交给网页（菜单项也是灰的），和没有这个功能时一样。
    func testAKeyWithNowhereToGoIsLeftToThePage() throws {
        let page = FakePage(canBack: false, canForward: false)
        let (controller, number) = try makeController(page: page)
        XCTAssertFalse(controller.handleHistoryKey(.back, isRepeat: false, windowNumber: number))
        XCTAssertFalse(controller.handleHistoryKey(.forward, isRepeat: false, windowNumber: number))
        XCTAssertEqual(page.went, [])
    }

    /// 登录弹窗等别的窗口里的按键不碰聊天窗口的页面，也不去解析它。
    func testKeysInAnotherWindowLeaveTheChatPageAlone() throws {
        let page = FakePage()
        let resolves = Counter()
        let (controller, number) = try makeController(page: page, resolves: resolves)
        XCTAssertFalse(controller.handleHistoryKey(.back, isRepeat: false, windowNumber: number + 1000))
        XCTAssertEqual(page.went, [])
        XCTAssertEqual(resolves.count, 0)
    }

    // MARK: - 鼠标侧键

    func testSideButtonMapping() {
        XCTAssertEqual(HistoryNavigation.mouseAction(type: .otherMouseDown, button: 3), .navigate(.back))
        XCTAssertEqual(HistoryNavigation.mouseAction(type: .otherMouseDown, button: 4), .navigate(.forward))
        for button in [3, 4] {
            XCTAssertEqual(HistoryNavigation.mouseAction(type: .otherMouseUp, button: button), .swallow)
            XCTAssertEqual(HistoryNavigation.mouseAction(type: .otherMouseDragged, button: button), .swallow)
        }
        for button in [0, 1, 2, 5, 6] {
            for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp, .otherMouseDragged] {
                XCTAssertEqual(HistoryNavigation.mouseAction(type: type, button: button), .pass, "\(button)")
            }
        }
        XCTAssertEqual(HistoryNavigation.mouseAction(type: .leftMouseDown, button: 3), .pass)
    }

    /// 按一下侧键（按下、拖动、松开）只走一次，目标页面只在按下时解析一次。三个事件都被吃掉，
    /// WebKit 和网页收不到，即使它们自己也处理侧键，也不会再走一次。
    func testOneSideButtonPressGoesOnce() throws {
        let page = FakePage(canBack: true, canForward: true)
        let resolves = Counter()
        let (controller, number) = try makeController(page: page, resolves: resolves)
        for type in [NSEvent.EventType.otherMouseDown, .otherMouseDragged, .otherMouseDragged, .otherMouseUp] {
            XCTAssertTrue(controller.handleHistoryMouse(type: type, button: 3, windowNumber: number), "\(type)")
        }
        XCTAssertEqual(page.went, [.back])
        XCTAssertEqual(resolves.count, 1)
        for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
            XCTAssertTrue(controller.handleHistoryMouse(type: type, button: 4, windowNumber: number))
        }
        XCTAssertEqual(page.went, [.back, .forward])
        XCTAssertEqual(resolves.count, 2)
    }

    /// 左右键、中键和更多的键照常交给网页。
    func testOtherMouseButtonsPassThrough() throws {
        let page = FakePage()
        let resolves = Counter()
        let (controller, number) = try makeController(page: page, resolves: resolves)
        for button in [0, 1, 2, 5] {
            for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
                XCTAssertFalse(controller.handleHistoryMouse(type: type, button: button, windowNumber: number))
            }
        }
        XCTAssertEqual(page.went, [])
        XCTAssertEqual(resolves.count, 0)
    }

    /// 鼠标在登录弹窗等别的窗口上时原样放过，聊天窗口的页面不动。
    func testSideButtonsOverAnotherWindowLeaveTheChatPageAlone() throws {
        let page = FakePage()
        let resolves = Counter()
        let (controller, number) = try makeController(page: page, resolves: resolves)
        for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
            XCTAssertFalse(controller.handleHistoryMouse(type: type, button: 3, windowNumber: number + 1000))
        }
        XCTAssertEqual(page.went, [])
        XCTAssertEqual(resolves.count, 0)
    }

    /// 没有可去的页面时侧键也被吃掉，什么都不做。
    func testASideButtonWithNowhereToGoDoesNothing() throws {
        let page = FakePage(canBack: false, canForward: false)
        let (controller, number) = try makeController(page: page)
        XCTAssertTrue(controller.handleHistoryMouse(type: .otherMouseDown, button: 3, windowNumber: number))
        XCTAssertTrue(controller.handleHistoryMouse(type: .otherMouseUp, button: 3, windowNumber: number))
        XCTAssertEqual(page.went, [])
    }

    // MARK: - 应用里的网页

    private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// 应用里真正用的网页（WebRuntime）：后退一次只有一次导航，并且经过导航策略（decidePolicyFor 记下的后退/前进导航）；
    /// 能否后退、箭头是否显示跟着变。用两个 data: 页面，不联网，窗口只创建不显示。
    func testTheAppWebViewGoesBackOnceThroughTheNavigationPolicy() async throws {
        let diagnostics = Diagnostics()
        let web = WebRuntime(diagnostics: diagnostics, settings: AppSettings(defaults: makeDefaults()), watchesNetwork: false)
        let changes = Counter()
        web.onHistoryChange = { changes.count += 1 }
        let one = try XCTUnwrap(URL(string: "data:text/html,one")), two = try XCTUnwrap(URL(string: "data:text/html,two"))
        let policyDecisions = { diagnostics.entries.filter { $0.message.hasPrefix("后退/前进导航") }.count }

        web.webView.load(URLRequest(url: one))
        try await waitUntil { web.webView.url == one && !web.webView.isLoading }
        XCTAssertEqual(web.webView.url, one)
        XCTAssertFalse(web.canGo(.back))
        XCTAssertFalse(web.showsBackButton)
        XCTAssertFalse(web.go(.back, source: "测试"), "没有可去的页面时什么都不做")

        web.webView.load(URLRequest(url: two))
        try await waitUntil { web.webView.url == two && !web.webView.isLoading && web.canGo(.back) }
        XCTAssertTrue(web.canGo(.back))
        XCTAssertFalse(web.canGo(.forward))
        XCTAssertTrue(web.showsBackButton, "data: 页面不是聊天页面，能后退时显示箭头")
        XCTAssertGreaterThan(changes.count, 0, "能否后退变了要通知")
        XCTAssertEqual(policyDecisions(), 0)

        XCTAssertTrue(web.go(.back, source: "测试"))
        try await waitUntil { web.webView.url == one && !web.webView.isLoading && web.canGo(.forward) }
        // 多等一会儿：如果一次后退引出了第二次导航，这里会看到。
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(web.webView.url, one)
        XCTAssertEqual(policyDecisions(), 1, "一次后退只有一次导航，并且经过导航策略")
        XCTAssertFalse(web.canGo(.back))
        XCTAssertTrue(web.canGo(.forward))
        XCTAssertFalse(web.showsBackButton)
        XCTAssertTrue(diagnostics.entries.contains { $0.message == "后退（测试）→ data:<…>" }, "日志只写脱敏后的地址")

        XCTAssertTrue(web.go(.forward, source: "测试"))
        try await waitUntil { web.webView.url == two && !web.webView.isLoading }
        XCTAssertEqual(web.webView.url, two)
        XCTAssertEqual(policyDecisions(), 2)
    }

    // MARK: - 文字

    /// 菜单、箭头的标签和提示、录制时的说明四种语言都有，并且用各自的写法。
    func testWordsExistInAllFourLanguages() {
        let expected: [AppLanguage: (back: String, forward: String, tooltip: String, reserved: String)] = [
            .english: ("Back", "Forward", "Back (⌘[)", "⌘[ is used to go back a page. Choose another one."),
            .japanese: ("戻る", "進む", "戻る（⌘[）", "⌘[ は「前のページに戻る」に使われています。別の組み合わせを選んでください。"),
            .simplifiedChinese: ("后退", "前进", "后退（⌘[）", "⌘[ 用来返回上一页，请换一个。"),
            .traditionalChinese: ("上一頁", "下一頁", "上一頁（⌘[）", "⌘[ 用來回到上一頁，請換一個。"),
        ]
        XCTAssertEqual(Set(expected.keys), Set(AppLanguage.allCases))
        for (language, words) in expected {
            XCTAssertEqual(L10n.string("menu.back", in: language), words.back)
            XCTAssertEqual(L10n.string("menu.forward", in: language), words.forward)
            XCTAssertEqual(L10n.format("format.withShortcut", in: language, words.back, HistoryNavigation.shortcutName(.back)),
                           words.tooltip)
            let reserved = LocalizedText("hotkey.reject.used", .plain("⌘["), .text(LocalizedText("purpose.goBack")))
            XCTAssertEqual(reserved.string(in: language), words.reserved)
            XCTAssertNotEqual(L10n.string("purpose.goForward", in: language), "purpose.goForward")
        }
    }
}
