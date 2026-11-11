import AppKit
import WebKit
import XCTest
@testable import ClassicCompanion

@MainActor
final class WebAccessibilityTests: XCTestCase {
    func testAssistiveTechnologyAlwaysReachesThePage() {
        XCTAssertTrue(WebAccessibilityGate(blockRequested: false, assistiveTechnologyOn: false).allowsPageAccessibility)
        XCTAssertTrue(WebAccessibilityGate(blockRequested: false, assistiveTechnologyOn: true).allowsPageAccessibility)
        XCTAssertTrue(WebAccessibilityGate(blockRequested: true, assistiveTechnologyOn: true).allowsPageAccessibility, "VoiceOver 用户不能被挡")
        XCTAssertFalse(WebAccessibilityGate(blockRequested: true, assistiveTechnologyOn: false).allowsPageAccessibility)
    }

    func testOtherAppsAreBlockedByDefault() {
        XCTAssertFalse(AppSettings().allowPageAccessibility)
    }

    func testBlockedRequestsStopBeforeWebKit() {
        let web = CompanionWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.blockAccessibility = true
        web.assistiveTechnologyOn = { false }
        var seen: [String] = []
        var allowed: [Bool] = []
        web.onAccessibilityRequest = { name, allow in seen.append(name); allowed.append(allow) }

        XCTAssertNil(web.accessibilityFocusedUIElement)
        XCTAssertNil(web.accessibilityHitTest(.zero))
        XCTAssertNil(web.accessibilityAttributeValue(.children))
        XCTAssertNil(web.accessibilityAttributeValue(.children), "同一请求只记录一次")
        XCTAssertNil(web.accessibilityAttributeValue(.stringForRange, forParameter: nil))

        XCTAssertEqual(seen, ["focused", "hitTest", "AXChildren", "param:AXStringForRange"])
        XCTAssertEqual(Set(allowed), [false])
    }
}
