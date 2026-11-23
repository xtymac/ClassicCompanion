import AppKit
import WebKit
import XCTest
@testable import ClassicCompanion

/// “重启音频”（issue #16）：菜单项、四种语言的名字、结束进程前对 pid 的核对。
/// 真实的媒体进程重启和它对无声故障有没有用，要在真实应用上看，这里不能代替。
final class MediaProcessTests: XCTestCase {
    @MainActor func testOnlyAWebKitMediaProcessIsAccepted() {
        let name = WebRuntime.mediaProcessName
        XCTAssertTrue(WebRuntime.isMediaProcess(pid: 4321, name: name))
        XCTAssertFalse(WebRuntime.isMediaProcess(pid: 4321, name: "com.apple.WebKit.WebContent"), "网页内容进程不能动")
        XCTAssertFalse(WebRuntime.isMediaProcess(pid: 4321, name: "ClassicCompanion"))
        XCTAssertFalse(WebRuntime.isMediaProcess(pid: 4321, name: nil), "查不到名字的 pid 不动")
        XCTAssertFalse(WebRuntime.isMediaProcess(pid: 0, name: name), "0 表示没有媒体进程；kill(0) 会发给整个进程组")
        XCTAssertFalse(WebRuntime.isMediaProcess(pid: -1, name: name), "kill(-1) 会发给所有进程")
        XCTAssertFalse(WebRuntime.isMediaProcess(pid: 1, name: name))
        XCTAssertFalse(WebRuntime.isMediaProcess(pid: getpid(), name: name), "不能结束自己")
    }

    /// 没放过声音的网页视图可能还没有媒体进程：查询不能崩，查到的话必须真是媒体进程。
    @MainActor func testLookingUpTheMediaProcessOfAFreshWebViewIsSafe() {
        let webView = WKWebView(frame: .zero)
        if let pid = WebRuntime.mediaProcessID(of: webView) {
            XCTAssertGreaterThan(pid, 1)
            XCTAssertNotEqual(pid, getpid())
        }
    }

    @MainActor func testFileMenuHasRestartAudioInEveryLanguage() throws {
        let expected: [AppLanguage: String] = [.english: "Restart Audio", .japanese: "オーディオを再起動",
                                               .simplifiedChinese: "重启音频", .traditionalChinese: "重新啟動音訊"]
        for language in AppLanguage.allCases {
            let menu = AppDelegate.makeMainMenu(modeKey: .modeStandard, language: language).menu
            let file = try XCTUnwrap(menu.items.dropFirst().first?.submenu, "\(language)")
            let item = try XCTUnwrap(file.items.first { $0.action.map(NSStringFromSelector) == "restartAudio" }, "\(language)")
            XCTAssertEqual(item.title, try XCTUnwrap(expected[language]))
            XCTAssertEqual(item.keyEquivalent, "", "不占快捷键")
            let reload = try XCTUnwrap(file.items.firstIndex { $0.action.map(NSStringFromSelector) == "reloadPage" })
            XCTAssertEqual(file.items.firstIndex(of: item), reload + 1, "排在“重新加载”后面")
        }
    }
}
