import XCTest
@testable import ClassicCompanion

/// 唤醒快捷键从隐藏或不在前台的状态叫出窗口时用哪个模式（用户 2026-11-14）。不建窗口。
/// 不设时限：判断里没有时间，等多久、切到别的应用、断网都不影响结果。
final class WakeWindowModeTests: XCTestCase {
    func testKeepLastWakesTheQuickWindowAsBefore() {
        XCTAssertEqual(ChatWindowController.hotKeyWakeMode(.keepLast, last: .quick, defaultMode: .quick), .quick)
    }

    /// 完整窗口不指定模式：保持完整模式，和 Dock、⌘Tab 找回一样放置。改动前这里是 .quick。
    func testKeepLastKeepsTheFullWindow() {
        XCTAssertNil(ChatWindowController.hotKeyWakeMode(.keepLast, last: .full, defaultMode: .quick))
    }

    /// “总是小窗”就是改动之前的行为：回到默认模式。
    func testAlwaysQuickUsesTheDefaultModeLikeBefore() {
        for last in [ChatWindowController.Mode.quick, .full] {
            XCTAssertEqual(ChatWindowController.hotKeyWakeMode(.alwaysQuick, last: last, defaultMode: .quick), .quick)
        }
    }
}
