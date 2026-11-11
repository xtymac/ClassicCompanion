import AppKit
import XCTest
@testable import ClassicCompanion

final class WindowPlacementTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = NSRect(x: 0, y: 70, width: 1512, height: 875)
    private let size = NSSize(width: 720, height: 520)

    func testRestoresTheSamePosition() {
        let frame = NSRect(x: 40, y: 200, width: 720, height: 520)
        let placement = QuickPlacement(frame: frame, screenFrame: screen)
        XCTAssertEqual(placement.origin(size: size, screenFrame: screen, visibleFrame: visible), frame.origin)
    }

    func testKeepsTopLeftWhenWindowSizeDiffers() {
        let placement = QuickPlacement(frame: NSRect(x: 40, y: 200, width: 900, height: 600), screenFrame: screen)
        // 顶边 800：小窗 520 高时底边 280
        XCTAssertEqual(placement.origin(size: size, screenFrame: screen, visibleFrame: visible), NSPoint(x: 40, y: 280))
    }

    func testSurvivesScreenArrangementChange() {
        let placement = QuickPlacement(frame: NSRect(x: 40, y: 200, width: 720, height: 520), screenFrame: screen)
        let moved = screen.offsetBy(dx: -1512, dy: 300), movedVisible = visible.offsetBy(dx: -1512, dy: 300)
        XCTAssertEqual(placement.origin(size: size, screenFrame: moved, visibleFrame: movedVisible), NSPoint(x: -1472, y: 500))
    }

    func testFallsBackWhenCompletelyOutsideVisibleArea() {
        let large = NSRect(x: 0, y: 0, width: 3000, height: 2000)
        let placement = QuickPlacement(frame: NSRect(x: 2500, y: 100, width: 720, height: 520), screenFrame: large)
        XCTAssertNil(placement.origin(size: size, screenFrame: screen, visibleFrame: visible))
    }

    func testPartlyOutsideIsKeptForClamping() {
        let placement = QuickPlacement(frame: NSRect(x: 1400, y: 200, width: 720, height: 520), screenFrame: screen)
        XCTAssertEqual(placement.origin(size: size, screenFrame: screen, visibleFrame: visible), NSPoint(x: 1400, y: 200))
    }

    func testWindowAcrossTwoScreensIsLeftAlone() {
        let left = NSRect(x: -1324, y: -490, width: 1324, height: 993)
        let frame = NSRect(x: -300, y: 100, width: 640, height: 720)
        XCTAssertTrue(ChatWindowController.titleBarReachable(frame, screens: [visible, left]))
    }

    func testWindowWithoutReachableTitleBarNeedsRescue() {
        XCTAssertFalse(ChatWindowController.titleBarReachable(NSRect(x: 3000, y: 100, width: 640, height: 720), screens: [visible]))
        // 标题栏在屏幕上方、只有窗口下部露在屏幕内：同样够不着
        XCTAssertFalse(ChatWindowController.titleBarReachable(NSRect(x: 100, y: 800, width: 640, height: 720), screens: [visible]))
    }

    func testEachScreenKeepsItsOwnPositionAcrossReload() throws {
        let suite = "cc-placement-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = QuickPlacement(frame: NSRect(x: 10, y: 20, width: 720, height: 520), screenFrame: screen)
        let b = QuickPlacement(frame: NSRect(x: 300, y: 40, width: 720, height: 520), screenFrame: screen)
        QuickPlacementStore(defaults: defaults).save(a, forScreen: "A")
        QuickPlacementStore(defaults: defaults).save(b, forScreen: "B")
        let reloaded = QuickPlacementStore(defaults: defaults)
        XCTAssertEqual(reloaded.placement(forScreen: "A"), a)
        XCTAssertEqual(reloaded.placement(forScreen: "B"), b)
        XCTAssertNil(reloaded.placement(forScreen: "C"))
    }
}

@MainActor
final class CycleCounterTests: XCTestCase {
    func testOnlyHiddenToVisibleCountsAsWake() {
        let d = Diagnostics()
        d.resetCycleCounters()
        d.recordHotKey()
        d.recordShow(.wake, previousApp: "x")
        d.recordShow(.modeSwitch, previousApp: nil)
        d.recordShow(.modeSwitch, previousApp: nil)
        d.recordShow(.activate, previousApp: "x")
        d.recordHide()
        XCTAssertEqual(d.hotKeyCount, 1)
        XCTAssertEqual(d.showCount, 1)
        XCTAssertEqual(d.modeSwitchCount, 2)
        XCTAssertEqual(d.activateCount, 1)
        XCTAssertEqual(d.hideCount, 1)
        XCTAssertEqual(d.appDistribution["x"], 1)
        XCTAssertTrue(d.entries.contains { $0.category == "cycle" && $0.message.contains("唤醒 #1") })
        d.resetCycleCounters()
        XCTAssertEqual(d.hotKeyCount + d.modeSwitchCount + d.activateCount, 0)
    }
}
