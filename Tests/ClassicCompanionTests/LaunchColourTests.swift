import AppKit
import Combine
import SwiftUI
import WebKit
import XCTest
@testable import ClassicCompanion

/// 启动保护（2026-11-14 冷启动复现：深色启动画面在网页提交前变浅，加载完成后才变回深色）。
/// 启动画面出现到网页第一次加载完成之间，顶部一条、启动画面和窗口底色保持启动时的颜色，不保存临时颜色；
/// 加载完成后照常跟随页面。WebKit 报的页面颜色在这里直接设 underPageBackgroundColor 来模拟（会触发同样的观察）。
/// 这些测试不显示窗口。
@MainActor
final class LaunchColourTests: XCTestCase {
    private let savedDark = NSColor(srgbRed: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x0E / 255.0, alpha: 1)
    private let pageBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    private var defaults: UserDefaults!
    private var web: WKWebView!
    private var appearance: PageAppearance!
    private var controller: ChatWindowController!
    private var diagnostics: Diagnostics!
    /// 顶部一条等原生部分用过的每一个颜色（PageAppearance.background 的每次变化）。
    private var shown: [NSColor?] = []
    private var watch: AnyCancellable?

    private func make(saved: NSColor?) {
        let name = "LaunchColourTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        defaults = UserDefaults(suiteName: name)!
        if let rgb = saved?.usingColorSpace(.sRGB) {
            defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init), forKey: "pageBackgroundRGB")
        }
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        appearance = PageAppearance(defaults: defaults)
        diagnostics = Diagnostics()
        controller = ChatWindowController(webView: web, toolbar: EmptyView(), diagnostics: diagnostics, appearance: appearance)
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

    private var savedColor: NSColor? {
        (defaults.array(forKey: "pageBackgroundRGB") as? [Double]).map {
            NSColor(srgbRed: $0[0], green: $0[1], blue: $0[2], alpha: 1)
        }
    }

    private func assertStillDark(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(appearance.isDark, true, message, file: file, line: line)
        XCTAssertEqual(controller.chromeAppearance?.name, .darkAqua, message, file: file, line: line)
        let window = try XCTUnwrap(controller.window?.backgroundColor.usingColorSpace(.sRGB))
        XCTAssertTrue(PageAppearance.isDark(window), "窗口底色：" + message, file: file, line: line)
        XCTAssertTrue(PageAppearance.sameColor(savedColor, savedDark), "保存的颜色：" + message, file: file, line: line)
    }

    private var neverShownLight: Bool {
        shown.allSatisfy { $0.map(PageAppearance.isDark) ?? true }
    }

    // MARK: - 进入启动保护

    /// 启动保护开始前已经排队的颜色更新（150ms 后才执行）不能在保护期间生效。
    func testAColourUpdateQueuedBeforeTheLaunchScreenIsDropped() async throws {
        make(saved: savedDark)
        web.underPageBackgroundColor = white
        controller.beginLaunchScreen()
        try await pause(0.5)
        try assertStillDark("排队的浅色在启动保护里不生效")
        XCTAssertTrue(shown.isEmpty)
    }

    /// 启动画面显示期间 WebKit 报的颜色既不显示也不保存。
    func testColoursReportedDuringTheLaunchScreenAreNeitherShownNorSaved() async throws {
        make(saved: savedDark)
        controller.beginLaunchScreen()
        web.underPageBackgroundColor = white
        try await pause(0.5)
        try assertStillDark("启动画面期间不跟随")
        XCTAssertTrue(controller.isShowingLaunchScreen)
        XCTAssertTrue(shown.isEmpty)
        XCTAssertTrue(diagnostics.entries.contains { $0.message.contains("启动保护中：页面底色报为浅色") })
    }

    // MARK: - 恢复跟随

    /// 加载完成时还报着的临时颜色，恢复跟随后的回调不能把它采用或保存；真实颜色报出来再采用。
    func testTheColourLeftFromBeforeTheLoadIsNotAdoptedAfterFollowingResumes() async throws {
        make(saved: savedDark)
        controller.beginLaunchScreen()
        web.underPageBackgroundColor = white
        controller.endLaunchScreen("网页已加载")
        controller.pageDidFinishLoading()
        XCTAssertFalse(controller.isHoldingPageColor)
        try await pause(0.5)
        try assertStillDark("150ms 后的回调不采用加载完成前的浅色")
        web.underPageBackgroundColor = pageBlack
        try await waitUntil { PageAppearance.sameColor(appearance.background, pageBlack) }
        XCTAssertTrue(PageAppearance.sameColor(appearance.background, pageBlack))
        XCTAssertTrue(PageAppearance.sameColor(savedColor, pageBlack), "真实颜色照常保存")
        XCTAssertTrue(neverShownLight, "整个过程没有显示过浅色")
    }

    /// 真实颜色比 150ms 晚到很多：中间不闪浅色，到了就采用。
    func testARealColourThatArrivesLateIsAdoptedWithoutAFlash() async throws {
        make(saved: savedDark)
        controller.pageColorSettleLimit = 3
        controller.beginLaunchScreen()
        web.underPageBackgroundColor = white
        controller.endLaunchScreen("网页已加载")
        controller.pageDidFinishLoading()
        try await pause(1.2)
        try assertStillDark("真实颜色还没到")
        web.underPageBackgroundColor = pageBlack
        try await waitUntil { PageAppearance.sameColor(appearance.background, pageBlack) }
        XCTAssertTrue(PageAppearance.sameColor(appearance.background, pageBlack))
        XCTAssertTrue(neverShownLight)
    }

    /// 页面本来就是加载完成前那个颜色（真的浅色页面）：等到时限后照常跟随，只变一次。
    func testAPageThatReallyHasThatColourIsFollowedAfterTheLimit() async throws {
        make(saved: savedDark)
        controller.pageColorSettleLimit = 0.3
        controller.beginLaunchScreen()
        web.underPageBackgroundColor = white
        controller.endLaunchScreen("网页已加载")
        controller.pageDidFinishLoading()
        try await pause(0.2)
        try assertStillDark("时限之前")
        try await waitUntil { appearance.isDark == false }
        XCTAssertEqual(appearance.isDark, false)
        XCTAssertEqual(controller.chromeAppearance?.name, .aqua)
        XCTAssertTrue(PageAppearance.sameColor(savedColor, white))
        XCTAssertEqual(shown.count, 1, "深色到浅色只变一次")
    }

    /// 恢复跟随以后，ChatGPT 换主题（或跟随系统换色）照常跟随：同步没有停。
    func testFollowingContinuesAfterResuming() async throws {
        make(saved: savedDark)
        controller.beginLaunchScreen()
        web.underPageBackgroundColor = white
        controller.endLaunchScreen("网页已加载")
        controller.pageDidFinishLoading()
        web.underPageBackgroundColor = pageBlack
        try await waitUntil { PageAppearance.sameColor(appearance.background, pageBlack) }
        web.underPageBackgroundColor = white
        try await waitUntil { appearance.isDark == false }
        XCTAssertEqual(appearance.isDark, false, "加载完成后换成浅色主题照常跟随")
        web.underPageBackgroundColor = pageBlack
        try await waitUntil { appearance.isDark == true }
        XCTAssertEqual(appearance.isDark, true)
    }

    // MARK: - 加载失败、到时限

    /// 第一次加载失败：启动画面结束但保护不解除，空白窗口的颜色不采用；重试成功后照常跟随，之后也继续跟随。
    func testFollowingResumesAfterAFailedFirstLoadIsRetried() async throws {
        make(saved: savedDark)
        controller.beginLaunchScreen()
        controller.endLaunchScreen("加载失败")
        XCTAssertFalse(controller.isShowingLaunchScreen)
        XCTAssertTrue(controller.isHoldingPageColor)
        web.underPageBackgroundColor = white
        try await pause(0.5)
        try assertStillDark("加载失败后没有页面，不跟随")
        // 重试成功
        controller.pageDidFinishLoading()
        web.underPageBackgroundColor = pageBlack
        try await waitUntil { PageAppearance.sameColor(appearance.background, pageBlack) }
        XCTAssertTrue(PageAppearance.sameColor(appearance.background, pageBlack))
        XCTAssertTrue(neverShownLight, "恢复时没有闪浅色")
        web.underPageBackgroundColor = white
        try await waitUntil { appearance.isDark == false }
        XCTAssertEqual(appearance.isDark, false, "之后换色照常跟随")
    }

    /// 启动画面到时限先结束，网页之后才加载完成：保护一直保持到加载完成，然后照常跟随。
    /// 到时限时结束启动画面要网页已经提交（2026-11-15 起，见 PageRevealTests），所以这里先提交。
    func testFollowingResumesWhenTheLoadFinishesAfterTheLaunchScreenTimedOut() async throws {
        make(saved: savedDark)
        controller.launchScreenLimit = 0.05
        controller.beginLaunchScreen()
        controller.pageDidCommit()
        try await waitUntil { !controller.isShowingLaunchScreen }
        XCTAssertFalse(controller.isShowingLaunchScreen)
        XCTAssertTrue(controller.isHoldingPageColor)
        web.underPageBackgroundColor = white
        try await pause(0.5)
        try assertStillDark("到时限后网页还没加载完成，不跟随")
        controller.pageDidFinishLoading()
        web.underPageBackgroundColor = pageBlack
        try await waitUntil { PageAppearance.sameColor(appearance.background, pageBlack) }
        XCTAssertTrue(PageAppearance.sameColor(appearance.background, pageBlack))
        XCTAssertTrue(neverShownLight)
        web.underPageBackgroundColor = white
        try await waitUntil { appearance.isDark == false }
        XCTAssertEqual(appearance.isDark, false, "之后换色照常跟随")
    }

    /// 之后每次加载完成都会调用；保护已经解除时不再起作用，不会重新进入“等颜色变化”。
    func testLaterLoadsDoNotRestartTheWait() async throws {
        make(saved: savedDark)
        controller.beginLaunchScreen()
        controller.endLaunchScreen("网页已加载")
        controller.pageDidFinishLoading()
        web.underPageBackgroundColor = pageBlack
        try await waitUntil { PageAppearance.sameColor(appearance.background, pageBlack) }
        controller.pageDidFinishLoading()
        web.underPageBackgroundColor = white
        try await waitUntil { appearance.isDark == false }
        XCTAssertEqual(appearance.isDark, false)
    }

    /// 没有启动画面（例如测试或以后别的入口）时和原来一样直接跟随。
    func testWithoutALaunchScreenThePageColourIsFollowedAsBefore() async throws {
        make(saved: savedDark)
        web.underPageBackgroundColor = white
        try await waitUntil { appearance.isDark == false }
        XCTAssertEqual(appearance.isDark, false)
        XCTAssertEqual(controller.chromeAppearance?.name, .aqua)
    }

    // MARK: - 淡出那层

    /// 淡出途中顶部一条已经换成网页颜色，淡出那层的底色和文字、图标仍是启动画面结束那一刻的，两者一致。
    func testTheFadingLayerKeepsOneLookWhileTheBarFollowsThePage() async throws {
        make(saved: savedDark)
        controller.pageColorSettleLimit = 0.05
        controller.beginLaunchScreen()
        web.underPageBackgroundColor = white
        controller.endLaunchScreen("网页已加载")
        let fade = try XCTUnwrap(controller.launchFadeView)
        XCTAssertEqual(fade.appearance?.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertTrue(PageAppearance.sameColor(fade.rootView.fixedBackground, savedDark))
        // 让页面颜色在淡出那层还在的时候被采用（这里页面真是浅色，到时限后采用）。
        controller.pageDidFinishLoading()
        try await waitUntil { appearance.isDark == false }
        XCTAssertEqual(controller.chromeAppearance?.name, .aqua, "顶部一条已跟随页面")
        XCTAssertEqual(fade.appearance?.bestMatch(from: [.aqua, .darkAqua]), .darkAqua, "淡出那层的文字和图标没换外观")
        XCTAssertTrue(PageAppearance.sameColor(fade.rootView.fixedBackground, savedDark), "淡出那层的底色没换")
    }

    /// 没有记下页面颜色（第一次启动）：淡出那层把系统颜色换成固定颜色，深浅和它的外观一致。
    func testWithoutASavedColourTheFadingLayerFixesTheSystemLookConsistently() throws {
        make(saved: nil)
        controller.beginLaunchScreen()
        controller.endLaunchScreen("网页已加载")
        let fade = try XCTUnwrap(controller.launchFadeView)
        let look = try XCTUnwrap(fade.appearance)
        let fill = try XCTUnwrap(fade.rootView.fixedBackground)
        XCTAssertEqual(PageAppearance.isDark(fill), look.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    // MARK: - 真实 WebKit

    /// 真实 WebKit 冷加载一个深色页面，按应用的顺序在加载完成时结束启动画面、解除保护：
    /// 原生部分从头到尾没有用过浅色，最后是页面的颜色。WebKit 加载前报出什么颜色记在测试输出里，不作判断。
    func testAColdLoadOfADarkPageNeverShowsALightColour() async throws {
        make(saved: savedDark)
        let finished = Finished()
        web.navigationDelegate = finished
        controller.beginLaunchScreen()
        web.loadHTMLString("<html><body style='background:#212121'>x</body></html>", baseURL: nil)
        try await waitUntil(5) { finished.done }
        XCTAssertTrue(finished.done)
        controller.endLaunchScreen("网页已加载")
        controller.pageDidFinishLoading()
        try await waitUntil(3) { appearance.background.map { abs($0.redComponent - 0x21 / 255.0) < 0.01 } ?? false }
        let red = try XCTUnwrap(appearance.background?.usingColorSpace(.sRGB)?.redComponent)
        XCTAssertEqual(red, 0x21 / 255.0, accuracy: 0.01)
        XCTAssertTrue(neverShownLight)
        let held = diagnostics.entries.filter { $0.message.contains("启动保护中") }.map(\.message)
        print("LaunchColourTests 冷加载时启动保护挡下的报告：\(held.isEmpty ? "无" : held.joined(separator: "；"))")
    }
}

private final class Finished: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}
