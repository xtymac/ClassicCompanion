import AppKit
import WebKit
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 2026-11-24：右键菜单里“下载图像”没反应、“在新窗口中打开图像”空白、“拷贝图像”对 SVG 不起作用。
@MainActor
final class ImageMenuTests: XCTestCase {
    private func makeRuntime() -> WebRuntime {
        let name = "ImageMenuTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return WebRuntime(diagnostics: Diagnostics(), settings: AppSettings(defaults: UserDefaults(suiteName: name)!),
                          watchesNetwork: false)
    }

    /// WebKit 只通过这个回调交出右键菜单发起的下载；名字写错就又没人接了。
    func testContextMenuDownloadsHaveADelegateHook() {
        XCTAssertTrue(makeRuntime().responds(to: Selector(("_webView:contextMenuDidCreateDownload:"))))
    }

    /// SVG 里带链接、内嵌网页和子框架：只能当图片显示。
    private static let hostileSVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"30\"><rect width=\"40\" height=\"30\" fill=\"green\"/>"
        + "<a href=\"https://example.invalid/\"><rect width=\"40\" height=\"30\" fill-opacity=\"0\"/></a>"
        + "<foreignObject width=\"40\" height=\"30\"><iframe xmlns=\"http://www.w3.org/1999/xhtml\" src=\"https://example.invalid/\"></iframe></foreignObject></svg>"

    private func openViewer(_ web: WebRuntime) async throws -> WKWebView {
        let payload = try XCTUnwrap(ImageDataURL.decode(URL(string: "data:image/svg+xml;utf8," + Self.hostileSVG.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)))
        let viewer = web.openImageViewer(payload, show: false)
        var shown = false
        for _ in 0..<50 where !shown {
            try await Task.sleep(nanoseconds: 100_000_000)
            shown = ((try? await viewer.evaluateJavaScript("document.images.length === 1 && document.images[0].naturalWidth === 40")) as? Bool) ?? false
        }
        XCTAssertTrue(shown, "图片应当显示出来，而不是空白页")
        return viewer
    }

    func testDataImageOpensInItsOwnViewer() async throws {
        let viewer = try await openViewer(makeRuntime())
        XCTAssertFalse(viewer.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(viewer.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    func testViewerShowsTheImageOnlyAsAnImage() async throws {
        let viewer = try await openViewer(makeRuntime())
        let counts = try await viewer.evaluateJavaScript("[document.querySelectorAll('svg, a, iframe, foreignObject').length, window.frames.length].join()") as? String
        XCTAssertEqual(counts, "0,0", "SVG 不作为文档展开，里面的链接和子框架不存在")
        let html = WebRuntime.imageViewerHTML(try XCTUnwrap(ImageDataURL.decode(URL(string: "data:IMAGE/PNG;base64,AQID"))))
        XCTAssertTrue(html.contains("default-src 'none'; img-src data:; style-src 'unsafe-inline'"))
        XCTAssertTrue(html.contains("<img src=\"data:image/png;base64,AQID\">"))
    }

    func testViewerRefusesEveryLaterNavigation() async throws {
        let viewer = try await openViewer(makeRuntime())
        viewer.load(URLRequest(url: URL(string: "https://example.invalid/")!))
        viewer.loadHTMLString("<p id='replaced'>x</p>", baseURL: URL(string: "https://chatgpt.com/")!)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(viewer.url?.absoluteString, "about:blank")
        let stillImage = try await viewer.evaluateJavaScript("document.images.length === 1 && !document.getElementById('replaced')") as? Bool
        XCTAssertEqual(stillImage, true)
    }

    func testPagePointFollowsZoomAndFlipping() {
        XCTAssertEqual(CompanionWebView.pagePoint(viewPoint: CGPoint(x: 100, y: 50), viewHeight: 400, flipped: true, pageZoom: 1),
                       CGPoint(x: 100, y: 50))
        XCTAssertEqual(CompanionWebView.pagePoint(viewPoint: CGPoint(x: 100, y: 50), viewHeight: 400, flipped: false, pageZoom: 1),
                       CGPoint(x: 100, y: 350))
        XCTAssertEqual(CompanionWebView.pagePoint(viewPoint: CGPoint(x: 100, y: 50), viewHeight: 400, flipped: true, pageZoom: 1.25),
                       CGPoint(x: 80, y: 40))
    }

    private func loadedWebView(_ html: String) async throws -> CompanionWebView {
        let web = CompanionWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
        let name = NSPasteboard.Name("ImageMenuTests.\(UUID().uuidString)")
        web.imagePasteboard = NSPasteboard(name: name)
        addTeardownBlock { @MainActor in web.imagePasteboard.releaseGlobally() }
        web.loadHTMLString(html, baseURL: nil)
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if ((try? await web.evaluateJavaScript("document.images.length > 0 && Array.from(document.images).every(i => i.complete)")) as? Bool) == true { break }
        }
        return web
    }

    private static let svgImage = "data:image/svg+xml;utf8,"
        + "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"50\"><rect width=\"100\" height=\"50\" fill=\"green\"/></svg>"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    /// 1×1 PNG
    private static let pngImage = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    func testSVGImageIsCopiedAsBitmap() async throws {
        let web = try await loadedWebView("<body style='margin:0'><div style='position:relative'><img src='\(Self.svgImage)' style='width:100px;height:50px;display:block'><div style='position:absolute;inset:0'></div></div>")
        let copied = await web.copyVectorImage(atPagePoint: CGPoint(x: 50, y: 25))
        XCTAssertTrue(copied, "盖在图片上的元素不应挡住查找")
        let png = try XCTUnwrap(web.imagePasteboard.data(forType: .png))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, 2 * rep.pixelsHigh)
        XCTAssertGreaterThanOrEqual(rep.pixelsWide, 200, "至少两倍清晰度")
        let colour = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(colour.greenComponent, colour.redComponent + 0.2)
        XCTAssertNotNil(web.imagePasteboard.data(forType: .tiff))
    }

    func testBitmapImagesAndEmptySpotsAreLeftToWebKit() async throws {
        let web = try await loadedWebView("<body style='margin:0'><img src='\(Self.pngImage)' style='width:100px;height:50px;display:block'>")
        let onBitmap = await web.copyVectorImage(atPagePoint: CGPoint(x: 50, y: 25))
        let onNothing = await web.copyVectorImage(atPagePoint: CGPoint(x: 300, y: 200))
        XCTAssertFalse(onBitmap)
        XCTAssertFalse(onNothing)
        XCTAssertNil(web.imagePasteboard.data(forType: .png))
    }
}
