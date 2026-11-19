import AppKit
import Combine
import SwiftUI
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 页面关闭以后（ChatWindowController.pageClosed(_:)）：带这个页面的入口和它排着的回调都不起作用，不改它的状态，也不动窗口。
/// 这里关的是窗口显示着的页面 B（controller.page）：正式的关闭入口 ChatTabs.close(_:) 只关不显示的标签页（不显示的页面关闭后
/// 的事件见 TabCloseTests），显示着的页面关闭时换上哪个页面是以后切换标签页的事。这里核对的是：在换走之前，它的事件和回调
/// 不会改窗口——启动画面、提示、颜色（等待、排着的更新、新报的颜色）都停在关闭时的样子。
/// 每条都先不关闭跑一遍同样的步骤做对照（会变），说明关了以后不变是关闭带来的。
/// WebKit 报的页面颜色和 LaunchColourTests 一样直接设 underPageBackgroundColor 来模拟。这些测试不显示窗口。
@MainActor
final class PageCloseTests: XCTestCase {
    private let savedDark = NSColor(srgbRed: 0x0E / 255.0, green: 0x0E / 255.0, blue: 0x0E / 255.0, alpha: 1)
    private let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    /// 起始颜色：不是白色，所以之后设白色是真的变化（见 LaunchColourTests.make(saved:reported:)）。
    private let blankDark = NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)

    private var web: WKWebView!
    private var appearance: PageAppearance!
    private var controller: ChatWindowController!
    private var diagnostics: Diagnostics!
    /// 显示着的页面。
    private var b: PageLoadState!
    /// 顶部一条等原生部分用过的每一个颜色（PageAppearance.background 的每次变化）。
    private var shown: [NSColor?] = []
    private var watch: AnyCancellable?

    /// 记下的页面颜色是 savedDark，网页视图开始时报着 blankDark，没有启动画面。显示着的页面是 b。
    private func make() {
        let name = "PageCloseTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = UserDefaults(suiteName: name)!
        let rgb = savedDark.usingColorSpace(.sRGB)!
        defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init), forKey: "pageBackgroundRGB")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        web.underPageBackgroundColor = blankDark
        XCTAssertTrue(PageAppearance.sameColor(web.underPageBackgroundColor, blankDark), "起始颜色已设上")
        appearance = PageAppearance(defaults: defaults)
        diagnostics = Diagnostics()
        b = PageLoadState()
        controller = ChatWindowController(webView: web, toolbar: EmptyView(), diagnostics: diagnostics, appearance: appearance, page: b)
        addTeardownBlock { [controller] in controller?.window?.orderOut(nil) }
        shown = []
        watch = appearance.$background.dropFirst().sink { [weak self] in self?.shown.append($0) }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func count(_ text: String) -> Int {
        diagnostics.entries.filter { $0.message.contains(text) }.count
    }

    /// 窗口上看得见的一切和窗口的日志（不算跟着真实鼠标、键盘、屏幕写的行），加上显示着的页面 B 的全部状态。
    private func state() -> [String] {
        let p = b!
        return [
            "启动画面=\(controller.isShowingLaunchScreen)",
            "启动画面淡出那层=\(controller.launchFadeView.map { "\(ObjectIdentifier($0))" } ?? "无")",
            "启动保护=\(controller.isHoldingPageColor)",
            "提示=\(String(describing: controller.shownLoadProblem))",
            "提示淡出那层=\(controller.loadProblemFadeView.map { "\(ObjectIdentifier($0))" } ?? "无")",
            "页面颜色=\(Self.rgb(appearance.background))",
            "顶部外观=\(controller.chromeAppearance?.name.rawValue ?? "nil")",
            "窗口底色=\(Self.rgb(controller.window?.backgroundColor))",
            "用过的颜色=\(shown.map { Self.rgb($0) })",
            "B：提交=\(p.hasCommittedPage) 等加载完成=\(p.awaitingFinish) 代号=\(p.commitGeneration) 提示=\(p.notice) "
                + "留着=\(p.noticeAwaitsLoad) 启动保护=\(p.holdsPageColor) 加载完成前的颜色=\(Self.rgb(p.colorBeforeFirstLoad)) "
                + "第一次加载已完成=\(p.hasFinishedFirstLoad) 加载完成时的颜色=\(Self.rgb(p.colorAtLastFinish))",
        ] + LiveInputLogLines.compared(diagnostics.entries).map { "[\($0.category)] \($0.message)" }
    }

    private static func rgb(_ color: NSColor?) -> String {
        guard let color else { return "nil" }
        guard let c = color.usingColorSpace(.sRGB) else { return color.description }
        return String(format: "(%.3f, %.3f, %.3f, a %.2f)", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    // MARK: - 启动画面、提示、加载状态

    /// B 的启动画面显示着（启动保护中），下面盖着“正在连接”。B 关闭以后：它的加载失败、加载完成、提交、提示变化
    /// （带页和不带页的入口）都不结束启动画面、不改提示、不解除启动保护，B 的状态不变，窗口不写日志。
    /// 启动画面的时限和上限到点也不再因 B 动作（启动画面属于关闭的 B；换上别的页面时怎么处理遮挡，是以后切换入口的事）。
    /// 对照：不关闭时第一步（加载失败）就结束启动画面。
    func testAClosedLaunchPagesEventsAndTimersLeaveTheWindowAsItWas() async throws {
        make()
        controller.beginLaunchScreen()
        controller.showLoadProblem(.connecting)
        controller.endLaunchScreen("加载失败", for: b)
        XCTAssertFalse(controller.isShowingLaunchScreen, "对照：不关闭时加载失败结束启动画面")

        make()
        controller.launchScreenLimit = 0.1
        controller.launchScreenCap = 0.3
        controller.beginLaunchScreen()
        controller.showLoadProblem(.connecting)
        let before = state()
        controller.pageClosed(b)
        XCTAssertTrue(b.isClosed)
        controller.endLaunchScreen("加载失败", for: b)
        controller.showLoadProblem(.waiting, for: b)
        controller.pageDidCommit(b)
        controller.showLoadProblem(.hidden)
        controller.pageDidFinishLoading(b, reportedColor: white)
        controller.endLaunchScreen("网页已加载")
        controller.pageDidCommit()
        controller.pageDidFinishLoading()
        XCTAssertEqual(state(), before, "关闭以后的事件")
        try await pause(0.6)
        XCTAssertEqual(state(), before, "时限和上限到点以后")
        XCTAssertTrue(controller.isShowingLaunchScreen)
        controller.pageClosed(b)
        XCTAssertEqual(state(), before, "关两遍")
    }

    /// B 已提交、提示留到加载完成（排着提交后的兜底）。关闭以后兜底到点：B 留着的提示不收起，窗口的提示不变。
    /// 对照：不关闭时兜底到点收起。
    func testAClosedPagesCommitFallbackDoesNothing() async throws {
        for closes in [false, true] {
            make()
            controller.pageRevealLimit = 0.2
            controller.showLoadProblem(.connecting)
            controller.pageDidCommit()
            controller.showLoadProblem(.hidden)
            XCTAssertTrue(b.noticeAwaitsLoad)
            let before = state()
            if closes { controller.pageClosed(b) }
            try await pause(0.5)
            if closes {
                XCTAssertEqual(state(), before, "关闭以后兜底不起作用")
            } else {
                XCTAssertNil(controller.shownLoadProblem, "对照：不关闭时兜底收起提示")
                XCTAssertEqual(count("无法连接提示：提交后 200ms 还没加载完成，收起"), 1)
            }
        }
    }

    // MARK: - 颜色

    /// B 解除启动保护后在等颜色变化（到时限按当前颜色采用）。关闭以后等待到点：不采用、不写日志，B 记着的颜色不清掉。
    /// 对照：不关闭时到点采用白色。
    func testAClosedPagesColourSettleWaitDoesNothing() async throws {
        for closes in [false, true] {
            make()
            controller.pageColorSettleLimit = 0.8
            controller.beginLaunchScreen()
            web.underPageBackgroundColor = white
            controller.endLaunchScreen("网页已加载")
            controller.pageDidFinishLoading()
            XCTAssertTrue(PageAppearance.sameColor(b.colorBeforeFirstLoad, white), "B 在等颜色变化")
            // 启动画面淡出那层 0.2 秒后自己拿掉：等它没了再记下窗口，免得把它算成关闭以后的变化。
            let deadline = Date().addingTimeInterval(0.6)
            while controller.launchFadeView != nil, Date() < deadline { try await pause(0.02) }
            XCTAssertNil(controller.launchFadeView)
            let before = state()
            if closes { controller.pageClosed(b) }
            try await pause(1.0)
            if closes {
                XCTAssertEqual(state(), before, "关闭以后颜色等待不起作用")
                XCTAssertTrue(shown.isEmpty)
            } else {
                XCTAssertEqual(appearance.isDark, false, "对照：不关闭时到点采用")
                XCTAssertEqual(count("加载完成后 800ms 页面颜色没有变，按当前颜色采用"), 1)
            }
        }
    }

    /// B 报的白色还在 150ms 的队里时关闭：这次更新不采用。对照：不关闭时采用。
    func testAColourUpdateQueuedBeforeTheCloseIsDropped() async throws {
        for closes in [false, true] {
            make()
            web.underPageBackgroundColor = white
            let before = state()
            if closes { controller.pageClosed(b) }
            try await pause(0.5)
            if closes {
                XCTAssertEqual(state(), before, "关闭以后排着的更新不采用")
            } else {
                XCTAssertEqual(appearance.isDark, false, "对照：不关闭时采用")
                XCTAssertEqual(shown.count, 1)
            }
        }
    }

    /// 关闭以后 B 的网页视图再报颜色：不排更新、不采用；还在启动保护中时也不写“启动保护中”的日志。
    /// 对照：不关闭时启动保护中报颜色写一行日志，没有启动保护时采用。
    func testColoursReportedAfterTheCloseAreIgnored() async throws {
        for holding in [false, true] {
            for closes in [false, true] {
                make()
                if holding { controller.beginLaunchScreen() }
                let before = state()
                if closes { controller.pageClosed(b) }
                web.underPageBackgroundColor = white
                try await pause(0.5)
                switch (closes, holding) {
                case (true, _):
                    XCTAssertEqual(state(), before, "关闭以后报的颜色（启动保护中=\(holding)）")
                case (false, true):
                    XCTAssertEqual(count("启动保护中：页面底色报为浅色，不采用"), 1, "对照")
                    XCTAssertTrue(shown.isEmpty)
                case (false, false):
                    XCTAssertEqual(appearance.isDark, false, "对照：采用")
                }
            }
        }
    }
}
