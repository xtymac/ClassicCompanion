import AppKit
import XCTest
@testable import ClassicCompanion

/// 更新后第一次启动才设 Dock 图标（DockIconRefresh）。这些测试不显示窗口。
final class DockIconRefreshTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "DockIconRefreshTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// 全新安装：什么设置都没有。不算更新，图标由系统管理；之后同一构建再启动也不算。
    func testAFreshInstallIsNotAnUpdate() {
        let defaults = makeDefaults()
        XCTAssertEqual(DockIconRefresh.recordLaunch(defaults: defaults, build: "20261119.2116"), .firstInstall)
        XCTAssertEqual(defaults.string(forKey: DockIconRefresh.buildKey), "20261119.2116")
        XCTAssertEqual(DockIconRefresh.recordLaunch(defaults: defaults, build: "20261119.2116"), .sameBuild)
    }

    /// 0.1.0-beta.3 及更早的版本不记构建号：靠它们留下的设置认出是更新。每一种留下的设置单独都够。
    func testUpdatingFromAVersionThatDidNotRecordItsBuild() {
        let left: [(String, Any)] = [("SUHasLaunchedBefore", true), ("pageBackgroundRGB", [1.0, 1.0, 1.0]),
                                     ("diag.showCount", 0), ("lastConversationURL", "https://chatgpt.com/c/x")]
        XCTAssertEqual(left.map(\.0).sorted(), DockIconRefresh.earlierVersionKeys.sorted())
        for (key, value) in left {
            let defaults = makeDefaults()
            defaults.set(value, forKey: key)
            XCTAssertEqual(DockIconRefresh.recordLaunch(defaults: defaults, build: "20261119.2116"), .updated(from: nil), key)
            XCTAssertEqual(DockIconRefresh.recordLaunch(defaults: defaults, build: "20261119.2116"), .sameBuild, "\(key)：只有第一次启动算更新")
        }
    }

    /// 用户改过的设置（例如快捷键）不是每个旧版本用户都有，也不能单独说明运行过：不拿来判断。
    func testOtherSettingsAloneDoNotCountAsAnEarlierVersion() {
        let defaults = makeDefaults()
        defaults.set(37, forKey: "hotKeyCode")
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        XCTAssertEqual(DockIconRefresh.classify(defaults: defaults, build: "20261119.2116"), .firstInstall)
    }

    /// 0.1.0-beta.4 之后的更新（以及回退到旧构建）：构建号和上次不一样。
    func testALaterUpdateIsRecognisedByTheBuildNumber() {
        let defaults = makeDefaults()
        _ = DockIconRefresh.recordLaunch(defaults: defaults, build: "20261119.2116")
        XCTAssertEqual(DockIconRefresh.recordLaunch(defaults: defaults, build: "20261201.0900"), .updated(from: "20261119.2116"))
        XCTAssertEqual(DockIconRefresh.recordLaunch(defaults: defaults, build: "20261201.0900"), .sameBuild)
        XCTAssertEqual(DockIconRefresh.recordLaunch(defaults: defaults, build: "20261119.2116"), .updated(from: "20261201.0900"))
    }

    /// 没打包运行（swift run、测试）没有构建号：不记，也不算更新。
    func testUnbundledRunsRecordNothing() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "SUHasLaunchedBefore")
        XCTAssertEqual(DockIconRefresh.recordLaunch(defaults: defaults, build: "unbundled"), .sameBuild)
        XCTAssertNil(defaults.string(forKey: DockIconRefresh.buildKey))
    }

    /// 图标从应用包里按 CFBundleIconFile 找；测试进程不是打包的应用，没有这一项。
    func testBundleIconComesFromTheBundlesIconFile() throws {
        XCTAssertNil(DockIconRefresh.bundleIcon(in: Bundle(for: Self.self)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DockIconRefreshTests-\(UUID().uuidString).app")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "local.test.dockicon", "CFBundleIconFile": "AppIcon"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/icon/AppIcon.icns")
        try FileManager.default.copyItem(at: source, to: resources.appendingPathComponent("AppIcon.icns"))
        let icon = try XCTUnwrap(DockIconRefresh.bundleIcon(in: try XCTUnwrap(Bundle(url: root))))
        XCTAssertGreaterThan(icon.representations.count, 1, "icns 里的各个尺寸都在")
    }
}
