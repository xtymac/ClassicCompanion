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

    func testDataImageOpensInItsOwnViewer() async throws {
        let web = makeRuntime()
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"30\"><rect width=\"40\" height=\"30\" fill=\"green\"/></svg>"
        let payload = try XCTUnwrap(ImageDataURL.decode(URL(string: "data:image/svg+xml;utf8," + svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)))
        let viewer = web.openImageViewer(payload, show: false)
        var found = false
        for _ in 0..<50 where !found {
            try await Task.sleep(nanoseconds: 100_000_000)
            found = ((try? await viewer.evaluateJavaScript("!!document.querySelector('svg rect')")) as? Bool) ?? false
        }
        XCTAssertTrue(found, "图片应当显示出来，而不是空白页")
        XCTAssertFalse(viewer.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(viewer.configuration.defaultWebpagePreferences.allowsContentJavaScript)
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
