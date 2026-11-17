import AppKit
import Combine
import SwiftUI
import WebKit
import XCTest
@testable import ClassicCompanion

/// 换窗口里显示的网页视图（为聊天标签页准备，ChatWindowController.replaceWebView）：
/// 容器、Esc 判断、页面底色观察和键盘焦点都跟着换，旧网页视图不再被持有。
/// WebKit 报的页面颜色和 LaunchColourTests 一样直接设 underPageBackgroundColor 来模拟（颜色真的变了才有观察通知）。
/// 这些测试不显示窗口。
@MainActor
final class WebViewSwapTests: XCTestCase {
    private let savedDark = NSColor(srgbRed: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x0E / 255.0, alpha: 1)
    private let pageBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    /// 起始颜色：不是白色，也不是测试里要报的颜色，所以之后设的每个颜色都是真的变化（见 LaunchColourTests.make(saved:reported:)）。
    private let blankDark = NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)

    private var defaults: UserDefaults!
    private var old: WKWebView!
    private var new: WKWebView!
    private var appearance: PageAppearance!
    private var controller: ChatWindowController!
    private var diagnostics: Diagnostics!
    /// 顶部一条等原生部分用过的每一个颜色（PageAppearance.background 的每次变化）。
    private var shown: [NSColor?] = []
    private var watch: AnyCancellable?

    /// 两个网页视图开始时都报着 blankDark；记下的页面颜色是 savedDark，没有启动画面。
    private func make() {
        let name = "WebViewSwapTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        defaults = UserDefaults(suiteName: name)!
        let rgb = savedDark.usingColorSpace(.sRGB)!
        defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init), forKey: "pageBackgroundRGB")
        old = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        new = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        for web in [old!, new!] {
            web.underPageBackgroundColor = blankDark
            XCTAssertTrue(PageAppearance.sameColor(web.underPageBackgroundColor, blankDark), "起始颜色已设上")
        }
        appearance = PageAppearance(defaults: defaults)
        diagnostics = Diagnostics()
        controller = ChatWindowController(webView: old, toolbar: EmptyView(), diagnostics: diagnostics, appearance: appearance)
        addTeardownBlock { [controller] in controller?.window?.orderOut(nil) }
        shown = []
        watch = appearance.$background.dropFirst().sink { [weak self] in self?.shown.append($0) }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await pause(0.03) }
    }

    private func chatWindow() throws -> ChatWindow {
        try XCTUnwrap(controller.window as? ChatWindow)
    }

    // MARK: - 容器

    /// 换过之后容器里只有新网页视图，它铺满容器；容器本身还在原来的位置。
    func testTheContainerHoldsOnlyTheNewViewAndItFillsIt() throws {
        make()
        let content = try XCTUnwrap(controller.window?.contentView)
        let place = try XCTUnwrap(old.superview)
        XCTAssertTrue(place.superview === content)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(place.bounds.isEmpty)
        XCTAssertEqual(old.frame, place.bounds, "换之前旧网页视图铺满容器")
        let before = place.frame

        controller.replaceWebView(with: new)
        content.layoutSubtreeIfNeeded()
        XCTAssertNil(old.superview, "旧网页视图已拿掉")
        XCTAssertTrue(new.superview === place)
        XCTAssertEqual(place.subviews, [new])
        XCTAssertEqual(new.frame, place.bounds, "新网页视图铺满容器")
        XCTAssertEqual(place.frame, before, "容器的位置没变")
        XCTAssertTrue(controller.webView === new)
    }

    // MARK: - Esc 和焦点

    /// ChatWindow.webView（Esc 判断）指向新网页视图，不是容器。
    func testTheWindowsEscCheckPointsAtTheNewView() throws {
        make()
        let window = try chatWindow()
        XCTAssertTrue(window.webView === old)
        controller.replaceWebView(with: new)
        XCTAssertTrue(window.webView === new)
    }

    /// 焦点原来在旧网页里：交给新网页；之后网页焦点下的 Esc 仍交给网页，不由窗口隐藏。
    func testFocusInTheOldViewIsHandedToTheNewView() throws {
        make()
        let window = try chatWindow()
        XCTAssertTrue(window.makeFirstResponder(old))
        XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: old) ?? false, "不显示窗口也能把焦点放进网页")
        controller.replaceWebView(with: new)
        let responder = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertTrue(responder.isDescendant(of: new), "焦点交给新网页")
        var cancelled = false
        window.onCancel = { cancelled = true }
        window.cancelOperation(nil)
        XCTAssertFalse(cancelled, "焦点在新网页里时 Esc 交给网页")
    }

    /// 焦点不在网页里：换网页视图不抢焦点；这时 Esc 由窗口处理。
    func testFocusOutsideTheOldViewIsLeftAlone() throws {
        make()
        let window = try chatWindow()
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertTrue(window.firstResponder === window)
        controller.replaceWebView(with: new)
        XCTAssertTrue(window.firstResponder === window, "没有把焦点交给新网页")
        var cancelled = false
        window.onCancel = { cancelled = true }
        window.cancelOperation(nil)
        XCTAssertTrue(cancelled, "焦点不在网页里时 Esc 由窗口处理")
    }

    // MARK: - 页面底色

    /// 换之前跟随旧网页；换之后旧网页的颜色变化不起作用，新网页的照常跟随。
    func testOnlyTheNewViewsColourIsFollowedAfterTheSwap() async throws {
        make()
        old.underPageBackgroundColor = pageBlack
        try await waitUntil { PageAppearance.sameColor(appearance.background, pageBlack) }
        XCTAssertTrue(PageAppearance.sameColor(appearance.background, pageBlack), "换之前跟随旧网页")
        let shownBefore = shown.count

        controller.replaceWebView(with: new)
        old.underPageBackgroundColor = white
        XCTAssertTrue(PageAppearance.sameColor(old.underPageBackgroundColor, white), "旧网页的颜色确实变了")
        try await pause(0.5)
        XCTAssertTrue(PageAppearance.sameColor(appearance.background, pageBlack), "旧网页的颜色不再跟随")
        XCTAssertEqual(shown.count, shownBefore)
        XCTAssertEqual(controller.chromeAppearance?.name, .darkAqua)

        new.underPageBackgroundColor = white
        try await waitUntil { appearance.isDark == false }
        XCTAssertEqual(appearance.isDark, false, "新网页的颜色照常跟随")
        XCTAssertEqual(controller.chromeAppearance?.name, .aqua)
    }

    /// 旧网页报的颜色还在 150ms 的队里时换掉：这次更新作废，既不采用旧网页的颜色，也不去读新网页的颜色。
    /// 新网页此刻报着的颜色也不马上采用，等它变化。
    func testAColourUpdateQueuedByTheOldViewIsDropped() async throws {
        make()
        new.underPageBackgroundColor = pageBlack
        old.underPageBackgroundColor = white
        controller.replaceWebView(with: new)
        try await pause(0.5)
        XCTAssertTrue(shown.isEmpty, "排着队的更新没有生效")
        XCTAssertTrue(PageAppearance.sameColor(appearance.background, savedDark))
    }

    // MARK: - 释放

    /// 换掉之后控制器和窗口不再持有旧网页视图：调用方放手它就释放。
    func testTheOldViewIsReleasedOnceTheCallerDropsIt() async throws {
        make()
        weak let released = old
        try chatWindow().makeFirstResponder(old)
        autoreleasepool {
            controller.replaceWebView(with: new)
            old = nil
        }
        try await waitUntil { released == nil }
        XCTAssertNil(released, "旧网页视图已释放")
        XCTAssertNotNil(new.superview)
    }
}
