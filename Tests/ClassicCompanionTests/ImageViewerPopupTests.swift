import AppKit
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 右键菜单“在新窗口中打开图像”（内嵌 data: 图片）和“下载图像”遇上标签页和弹窗的规则：
/// - 看图窗口是这一页的弹窗：开的时候先记下（owns(_:) 认它），关上、这一页关闭时拆掉；不是选中的标签页要开，不开；
/// - 右键菜单发起的下载：这一页的网页视图发起的接下来，关闭以后、不认识的网页视图发起的取消。
/// 不开窗口、不联网：显示弹窗换成记录，看图窗口从不显示；下载先取消再交，不写进“下载”文件夹。
@MainActor
final class ImageViewerPopupTests: XCTestCase {
    private func makeRuntime() -> (WebRuntime, Diagnostics) {
        let name = "ImageViewerPopupTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let diagnostics = Diagnostics()
        let runtime = WebRuntime(diagnostics: diagnostics, settings: AppSettings(defaults: UserDefaults(suiteName: name)!),
                                 watchesNetwork: false)
        runtime.loadRequest = { _ in }
        return (runtime, diagnostics)
    }

    private func lines(_ diagnostics: Diagnostics) -> [String] {
        diagnostics.entries.map { "[\($0.category)] \($0.message)" }
    }

    private static let svg = "data:image/svg+xml;utf8,"
        + "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"30\"><rect width=\"40\" height=\"30\" fill=\"green\"/></svg>"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

    /// 网页 window.open 一张内嵌图片时 WebKit 交来的导航动作（和右键菜单的一样是要新窗口）。新窗口不给。
    private func imageWindowAction() async throws -> WKNavigationAction {
        let catcher = OpenCatcher()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: config)
        web.uiDelegate = catcher
        addTeardownBlock { @MainActor in _ = web; _ = catcher }
        web.loadHTMLString("<script>window.open('\(Self.svg)')</script>", baseURL: nil)
        let deadline = Date().addingTimeInterval(5)
        while catcher.action == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return try XCTUnwrap(catcher.action)
    }

    func testAnImageViewerIsTrackedAsThePagesPopupAndTornDownOnClose() async throws {
        let (runtime, diagnostics) = makeRuntime()
        var shown: [NSWindow] = []
        var trackedWhenShown: Bool?
        runtime.showPopupWindow = {
            shown.append($0)
            trackedWhenShown = runtime.tracksPopupForTesting($0)
        }
        let action = try await imageWindowAction()
        XCTAssertNotNil(ImageDataURL.decode(action.request.url))

        let returned = runtime.webView(runtime.webView, createWebViewWith: WKWebViewConfiguration(), for: action,
                                       windowFeatures: WKWindowFeatures())
        XCTAssertNil(returned, "图片由自己的看图窗口显示，不给 WebKit 弹窗")
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(trackedWhenShown, true, "显示之前已经记下")
        let viewer = try XCTUnwrap(shown.first?.contentView as? WKWebView)
        XCTAssertFalse(viewer.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(lines(diagnostics).last, "[nav] 在新窗口打开内嵌图片 image/svg+xml")

        // 看图窗口的导航（加载那张图片）由这一页放行：owns(_:) 认它。
        var found = false
        for _ in 0..<50 where !found {
            try await Task.sleep(nanoseconds: 100_000_000)
            found = ((try? await viewer.evaluateJavaScript("!!document.querySelector('svg rect')")) as? Bool) ?? false
        }
        XCTAssertTrue(found)

        // 用户关上看图窗口：拆掉，不再认它。
        shown[0].close()
        XCTAssertFalse(runtime.tracksPopupForTesting(shown[0]))
        XCTAssertEqual(lines(diagnostics).last, "[web] 弹窗的窗口关上了：停止加载，不再认它")

        // 这一页关闭：开着的看图窗口一起拆掉。
        let second = runtime.openImageViewer(try XCTUnwrap(ImageDataURL.decode(action.request.url)), show: false)
        let secondWindow = try XCTUnwrap(second.window)
        XCTAssertTrue(runtime.tracksPopupForTesting(secondWindow))
        runtime.close()
        XCTAssertFalse(runtime.tracksPopupForTesting(secondWindow))
    }

    func testABackgroundTabDoesNotOpenAnImageViewer() async throws {
        let (runtime, diagnostics) = makeRuntime()
        var shown: [NSWindow] = []
        runtime.showPopupWindow = { shown.append($0) }
        runtime.isSelectedTab = { false }
        let action = try await imageWindowAction()
        let returned = runtime.webView(runtime.webView, createWebViewWith: WKWebViewConfiguration(), for: action,
                                       windowFeatures: WKWindowFeatures())
        XCTAssertNil(returned)
        XCTAssertEqual(shown.count, 0)
        XCTAssertEqual(lines(diagnostics).last, "[nav] 不显示的标签页要开弹窗：不开")
    }

    /// 下载先取消（不写文件），只看交给运行时以后它接不接（代理是不是运行时）。
    func testContextMenuDownloadsAreTakenOnlyFromThePagesOwnWebViews() async throws {
        let (runtime, diagnostics) = makeRuntime()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let stranger = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: config)
        func cancelledDownload() async throws -> WKDownload {
            let download = await stranger.startDownload(using: URLRequest(url: URL(string: Self.svg)!))
            download.delegate = nil
            _ = await download.cancel()
            return download
        }

        let fromStranger = try await cancelledDownload()
        runtime.webView(stranger, contextMenuDidCreateDownload: fromStranger)
        XCTAssertNil(fromStranger.delegate)
        XCTAssertEqual(lines(diagnostics).last, "[download] 关掉的弹窗或不认识的网页视图要下载：取消")

        let fromPage = try await cancelledDownload()
        runtime.webView(runtime.webView, contextMenuDidCreateDownload: fromPage)
        XCTAssertTrue(fromPage.delegate === runtime)

        runtime.close()
        let afterClose = try await cancelledDownload()
        let count = diagnostics.entries.count
        runtime.webView(runtime.webView, contextMenuDidCreateDownload: afterClose)
        XCTAssertNil(afterClose.delegate)
        XCTAssertEqual(diagnostics.entries.count, count, "关闭以后不写日志")
    }
}

/// 记下要新窗口的导航动作，新窗口不给。
@MainActor
private final class OpenCatcher: NSObject, WKUIDelegate {
    var action: WKNavigationAction?

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action == nil { action = navigationAction }
        return nil
    }
}
