import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ClassicCompanion

/// 圆角玻璃外观：顶部一条和网页同色，浅深色跟随 ChatGPT 页面（用户 2026-11-08：“按你推荐来”）。
@MainActor
final class ChromeTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "ChromeTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private let dark = NSColor(srgbRed: 0x21 / 255.0, green: 0x21 / 255.0, blue: 0x21 / 255.0, alpha: 1)

    func testDarkOrLightIsJudgedFromThePageBackground() {
        XCTAssertTrue(PageAppearance.isDark(dark))
        XCTAssertTrue(PageAppearance.isDark(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)))
        XCTAssertFalse(PageAppearance.isDark(.white))
        XCTAssertFalse(PageAppearance.isDark(NSColor(srgbRed: 0.97, green: 0.97, blue: 0.97, alpha: 1)))
    }

    /// 启动画面出现时网页还没加载：用上次的颜色。第一次启动没有记录，跟随系统。
    func testRemembersTheLastPageBackgroundForNextLaunch() throws {
        let defaults = makeDefaults()
        let first = PageAppearance(defaults: defaults)
        XCTAssertNil(first.background)
        XCTAssertNil(first.isDark)
        first.update(dark)
        XCTAssertEqual(first.isDark, true)
        let next = PageAppearance(defaults: defaults)
        XCTAssertEqual(next.isDark, true)
        let remembered = try XCTUnwrap(next.background?.usingColorSpace(.sRGB))
        XCTAssertEqual(remembered.redComponent, 0x21 / 255.0, accuracy: 0.01)
    }

    /// 没有红黄绿三个按钮和标题；⌘W 和关闭仍然只隐藏窗口。
    func testNoSystemButtonsAndCloseStillHides() throws {
        let controller = ChatWindowController(webView: WKWebView(), toolbar: EmptyView(), diagnostics: Diagnostics(),
                                              appearance: PageAppearance(defaults: makeDefaults()))
        defer { controller.window?.orderOut(nil) }
        let window = try XCTUnwrap(controller.window)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertEqual(window.standardWindowButton(kind)?.isHidden ?? true, true, "\(kind.rawValue)")
        }
        XCTAssertEqual(window.titleVisibility, .hidden)
        controller.show(mode: .quick)
        XCTAssertTrue(window.isVisible)
        window.performClose(nil)
        XCTAssertFalse(window.isVisible, "⌘W 仍然隐藏窗口")
    }

    /// 应用里真正用的网页（WebRuntime 配置过的）也要报出页面底色。
    /// 0044 实测：WebRuntime 把 underPageBackgroundColor 固定成窗口底色，页面颜色永远报不出来，浅深色不跟随。
    func testTheAppWebViewReportsThePageBackground() async throws {
        let runtime = WebRuntime(diagnostics: Diagnostics(), settings: AppSettings())
        let appearance = PageAppearance(defaults: makeDefaults())
        let controller = ChatWindowController(webView: runtime.webView, toolbar: EmptyView(), diagnostics: Diagnostics(), appearance: appearance)
        defer { controller.window?.orderOut(nil) }
        runtime.webView.loadHTMLString("<html><body style='background:#212121'>x</body></html>", baseURL: URL(string: "https://chatgpt.com/"))
        for _ in 0..<100 where appearance.isDark != true { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(appearance.isDark, true)
    }

    /// 按钮在原来标题栏的位置：点击要到按钮，不能被隐藏的标题栏吃掉。
    func testButtonsInTheTitleBarAreaReceiveClicks() throws {
        let state = ToolbarState()
        let appearance = PageAppearance(defaults: makeDefaults())
        var closes = 0, newChats = 0, toggles = 0
        let bar = WebBar(onClose: { closes += 1 }, onNewChat: { newChats += 1 }, onToggleMode: { toggles += 1 },
                         onDoubleClick: {}, state: state, appearance: appearance)
        let controller = ChatWindowController(webView: WKWebView(), toolbar: bar, diagnostics: Diagnostics(), appearance: appearance)
        defer { controller.window?.orderOut(nil) }
        controller.show(mode: .quick)
        let window = try XCTUnwrap(controller.window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let height = try XCTUnwrap(window.contentView).bounds.height, width = window.contentView!.bounds.width
        func click(x: CGFloat) {
            let point = NSPoint(x: x, y: height - WebBar.height / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let button = GlassCircleButton.size
        click(x: 12 + button / 2)            // ✕
        click(x: width - 12 - button / 2)    // 切换
        click(x: width - 12 - button - 10 - button / 2)  // 新建
        XCTAssertEqual([closes, toggles, newChats], [1, 1, 1])
    }

    /// 用户（1501）：“这几个按钮可读性有点差。可以稍微再增加一下它们的背景色，然后加一下 mouse hover 的 effect”。
    /// 1501 的按钮只有系统玻璃，没有底色。现在玻璃上叠一层底色；鼠标移上去时底色更实、边更明显、稍微放大。
    func testButtonsHaveAFillAndRespondToHover() {
        for dark in [false, true] {
            let rest = GlassButtonLook(dark: dark, hovering: false)
            let hover = GlassButtonLook(dark: dark, hovering: true)
            XCTAssertGreaterThan(rest.fill, 0, "有底色")
            XCTAssertGreaterThan(hover.fill, rest.fill, "悬停时底色更实")
            XCTAssertGreaterThan(hover.stroke, rest.stroke, "悬停时边更明显")
            XCTAssertGreaterThan(hover.scale, 1)
            XCTAssertEqual(rest.scale, 1)
        }
        XCTAssertGreaterThanOrEqual(GlassButtonLook(dark: false, hovering: false).fill, 0.6, "浅色里白底要够实，黑色图标才清楚")
    }

    /// 用户（1442）：“这个按钮的尺寸有点小，可以稍微大一点”。1442 是 32 点。
    func testButtonsAreABitBiggerAndStillFitTheBar() {
        XCTAssertGreaterThanOrEqual(GlassCircleButton.size, 36)
        XCTAssertLessThanOrEqual(GlassCircleButton.size + 12, WebBar.height, "上下仍各留至少 6 点")
    }

    /// 用户：“顶栏双击没有反应”。双击顶部空白处按系统设置（桌面与程序坞 → 连按窗口标题栏）处理。
    func testDoubleClickingTheEmptyBarIsReported() throws {
        let state = ToolbarState()
        let appearance = PageAppearance(defaults: makeDefaults())
        var doubles = 0, toggles = 0
        let bar = WebBar(onClose: {}, onNewChat: {}, onToggleMode: { toggles += 1 }, onDoubleClick: { doubles += 1 },
                         state: state, appearance: appearance)
        let controller = ChatWindowController(webView: WKWebView(), toolbar: bar, diagnostics: Diagnostics(), appearance: appearance)
        defer { controller.window?.orderOut(nil) }
        controller.show(mode: .quick)
        let window = try XCTUnwrap(controller.window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let content = try XCTUnwrap(window.contentView)
        let point = NSPoint(x: content.bounds.width / 2, y: content.bounds.height - WebBar.height / 2)
        for count in [1, 2] {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(doubles, 1)
        XCTAssertEqual(toggles, 0, "空白处双击不是点到切换按钮")
    }

    /// 用户（1329）：“双击顶部栏难以被触发，双击的时候也会有延迟”。
    /// 和系统标题栏一样：两下之间手稍微动一点也算（是不是双击由系统按时间和距离给出 clickCount），
    /// 第二下按下就生效，不等松开。
    func testDoubleClickActsOnTheSecondPressEvenIfTheHandMovedSlightly() throws {
        let state = ToolbarState()
        let appearance = PageAppearance(defaults: makeDefaults())
        var doubles = 0, presses: [Int] = []
        let bar = WebBar(onClose: {}, onNewChat: {}, onToggleMode: {}, onDoubleClick: { doubles += 1 },
                         onBarPress: { count, _ in presses.append(count) }, state: state, appearance: appearance)
        let controller = ChatWindowController(webView: WKWebView(), toolbar: bar, diagnostics: Diagnostics(), appearance: appearance)
        defer { controller.window?.orderOut(nil) }
        controller.show(mode: .quick)
        let window = try XCTUnwrap(controller.window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let content = try XCTUnwrap(window.contentView)
        let start = NSPoint(x: content.bounds.width / 2, y: content.bounds.height - WebBar.height / 2)
        func send(_ type: NSEvent.EventType, clicks: Int, dx: CGFloat) {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + dx, y: start.y), modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!)
        }
        send(.leftMouseDown, clicks: 1, dx: 0)
        send(.leftMouseDragged, clicks: 1, dx: 2)
        send(.leftMouseUp, clicks: 1, dx: 2)
        send(.leftMouseDown, clicks: 2, dx: 3)
        XCTAssertEqual(doubles, 1, "第二下按下时就生效")
        send(.leftMouseUp, clicks: 2, dx: 3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(doubles, 1, "一次双击只算一次")
        XCTAssertEqual(presses, [1, 2], "每次按下都报给日志：双击没反应时看得出是系统没算成双击，还是没按在这一条上")
    }

    /// 用户（1347）：“透明度有点太高了，应该加一些白色的磨砂进去”。用户（1606）：“Darkmode 下面透明区域应该是黑色底色”。
    /// 磨砂只在上面，往下淡掉：浅色是白色，深色是黑色。下沿仍然完全是页面底色，和网页之间没有接缝。
    func testFrostIsWhiteInLightAndBlackInDarkOnTopAndThePageColourAtTheBottomEdge() {
        XCTAssertEqual(BarFrost.light.tint, .white)
        XCTAssertEqual(BarFrost.dark.tint, .black, "深色里透明区域是黑色底色，不是白色磨砂")
        for frost in [BarFrost.light, BarFrost.dark] {
            XCTAssertGreaterThan(frost.frost, 0, "加了磨砂底色")
            XCTAssertEqual(frost.page.last?.opacity, 1)
            XCTAssertEqual(frost.page.last?.location, 1)
        }
    }

    /// 用户（1407）：“渐变不够自然，应该更平滑一些”。1407 的页面底色在 55% 处折一下，到下沿时还在快速变化，看得出一条线。
    /// 改为缓动曲线：相邻两点变化不大，靠近下沿时已经几乎是页面底色、白色也几乎没了。
    func testFrostGradientIsSmoothAndLandsSoftlyOnThePage() {
        for frost in [BarFrost.light, BarFrost.dark] {
            for stops in [frost.page, frost.frostStops] {
                XCTAssertEqual(stops.first?.location, 0)
                XCTAssertEqual(stops.last?.location, 1)
                for (a, b) in zip(stops, stops.dropFirst()) {
                    XCTAssertLessThanOrEqual(abs(b.opacity - a.opacity), 0.15, "相邻两点变化太大，看得出折线")
                }
            }
            XCTAssertGreaterThanOrEqual(frost.page.dropLast().last?.opacity ?? 0, 0.97, "下沿前一点已经几乎是页面底色")
            XCTAssertLessThanOrEqual(frost.frostStops.dropLast().last?.opacity ?? 1, 0.01, "下沿前一点磨砂几乎没了")
            XCTAssertEqual(frost.frostStops.last?.opacity, 0)
        }
    }

    func testDoubleClickFollowsTheSystemSetting() {
        XCTAssertEqual(BarDoubleClick.action(systemSetting: nil), .toggleMode, "默认是缩放：在小窗和完整窗口之间切换")
        XCTAssertEqual(BarDoubleClick.action(systemSetting: "Maximize"), .toggleMode)
        XCTAssertEqual(BarDoubleClick.action(systemSetting: "Fill"), .toggleMode)
        XCTAssertEqual(BarDoubleClick.action(systemSetting: "Minimize"), .minimize)
        XCTAssertEqual(BarDoubleClick.action(systemSetting: "None"), .none)
    }

    /// 顶部一条和窗口底色跟着网页背景变；网页本身不改外观，ChatGPT 的“系统”主题仍然跟随 macOS。
    func testChromeFollowsThePageBackground() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let appearance = PageAppearance(defaults: makeDefaults())
        let controller = ChatWindowController(webView: web, toolbar: EmptyView(), diagnostics: Diagnostics(), appearance: appearance)
        defer { controller.window?.orderOut(nil) }
        func waitFor(dark expected: Bool) async throws {
            for _ in 0..<100 where appearance.isDark != expected { try await Task.sleep(for: .milliseconds(30)) }
            XCTAssertEqual(appearance.isDark, expected)
        }

        web.loadHTMLString("<html><body style='background:#212121'>x</body></html>", baseURL: nil)
        try await waitFor(dark: true)
        XCTAssertEqual(controller.chromeAppearance?.name, .darkAqua)
        let background = try XCTUnwrap(controller.window?.backgroundColor.usingColorSpace(.sRGB))
        XCTAssertEqual(background.redComponent, 0x21 / 255.0, accuracy: 0.01, "窗口底色和网页一致，切换和调整大小时不闪白")

        _ = try await web.evaluateJavaScript("document.body.style.background = '#ffffff'; 0")
        try await waitFor(dark: false)
        XCTAssertEqual(controller.chromeAppearance?.name, .aqua)

        XCTAssertNil(web.appearance)
        XCTAssertNil(controller.window?.appearance)
    }
}
