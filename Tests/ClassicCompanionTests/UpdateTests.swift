import XCTest
import SwiftUI
import Sparkle
@testable import ClassicCompanion

/// 应用内更新（Sparkle）里不用开窗口、不联网就能检查的部分。升级本身的测试见 docs/updates.md。
@MainActor
final class UpdateTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated { LanguageController.shared.preference = .system }
        super.tearDown()
    }

    // MARK: - 配置只来自 Info.plist

    private let complete: [String: Any] = [
        "SUFeedURL": "https://example.invalid/appcast.xml",
        "SUPublicEDKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "CCUpdateChannel": "beta",
    ]

    private func info(channel: String, version: String?) -> [String: Any] {
        var info = complete
        info["CCUpdateChannel"] = channel
        info["CFBundleShortVersionString"] = version
        return info
    }

    func testConfigurationIsReadFromInfoPlist() throws {
        let config = try XCTUnwrap(UpdateConfiguration(infoDictionary: info(channel: "beta", version: "0.1.0-beta.2")))
        XCTAssertEqual(config.feedURL.absoluteString, "https://example.invalid/appcast.xml")
        XCTAssertEqual(config.channel, .beta)
        XCTAssertFalse(config.channelMismatch)
    }

    /// 实际会发的版本字符串：beta 版收 beta 和适用的正式版，正式版只收正式版。
    func testRealVersionStringsGetTheRightChannel() throws {
        let cases: [(channel: String, version: String, expected: UpdateConfiguration.Channel)] = [
            ("beta", "0.1.0-beta.1", .beta),
            ("beta", "0.1.0-beta.2", .beta),
            ("beta", "0.2.0-beta.10", .beta),
            ("beta", "1.0.0-rc.1", .beta),
            ("stable", "0.1.0", .stable),
            ("stable", "1.0.0", .stable),
            ("stable", "1.2.3", .stable),
        ]
        for c in cases {
            let config = try XCTUnwrap(UpdateConfiguration(infoDictionary: info(channel: c.channel, version: c.version)))
            XCTAssertEqual(config.channel, c.expected, c.version)
            XCTAssertFalse(config.channelMismatch, c.version)
        }
    }

    /// Info.plist 的渠道和版本号对不上（构建配置出错）时一律按正式版：正式版绝不会因此收到 beta。
    func testMismatchedChannelFallsBackToStable() throws {
        for (channel, version) in [("beta", "1.0.0"), ("beta", "0.1.0"), ("stable", "0.1.0-beta.2")] {
            let config = try XCTUnwrap(UpdateConfiguration(infoDictionary: info(channel: channel, version: version)))
            XCTAssertEqual(config.channel, .stable, "\(channel) / \(version)")
            XCTAssertTrue(config.channelMismatch, "\(channel) / \(version)")
            XCTAssertEqual(config.channel.sparkleChannels, [])
        }
        // 没有版本号也按正式版。
        let noVersion = try XCTUnwrap(UpdateConfiguration(infoDictionary: info(channel: "beta", version: nil)))
        XCTAssertEqual(noVersion.channel, .stable)
    }

    /// 少任何一项都不启动更新器（swift run、单元测试、没有更新配置的构建），而不是用代码里的默认值。
    func testMissingOrBrokenValuesMeanNoUpdater() {
        XCTAssertNil(UpdateConfiguration(infoDictionary: nil))
        for key in complete.keys {
            var info = complete
            info[key] = nil
            XCTAssertNil(UpdateConfiguration(infoDictionary: info), "缺 \(key)")
        }
        for (key, value) in [("SUFeedURL", "appcast.xml"), ("SUPublicEDKey", ""), ("CCUpdateChannel", "nightly")] {
            var info = complete
            info[key] = value
            XCTAssertNil(UpdateConfiguration(infoDictionary: info), "\(key) = \(value)")
        }
    }

    /// 单元测试和 swift run 没有更新配置：不建更新器，菜单项灰掉，退出不受影响。
    func testTestBundleHasNoUpdater() {
        XCTAssertNil(UpdateConfiguration(infoDictionary: Bundle.main.infoDictionary))
        let controller = UpdateController(diagnostics: Diagnostics())
        controller.start()
        XCTAssertNil(controller.configuration)
        XCTAssertFalse(controller.status.isAvailable)
        XCTAssertFalse(controller.status.canCheck)
        XCTAssertEqual(controller.terminationReply(proceed: { XCTFail("不该等待") }), .terminateNow)
    }

    // MARK: - 渠道

    func testPrereleaseVersionsAreBetaAndOthersStable() {
        XCTAssertEqual(UpdateConfiguration.Channel.forVersion("0.1.0-beta.1"), .beta)
        XCTAssertEqual(UpdateConfiguration.Channel.forVersion("0.1.0-beta.2"), .beta)
        XCTAssertEqual(UpdateConfiguration.Channel.forVersion("1.0.0-rc.1"), .beta)
        XCTAssertEqual(UpdateConfiguration.Channel.forVersion("1.0.0"), .stable)
        XCTAssertEqual(UpdateConfiguration.Channel.forVersion("1.2"), .stable)
    }

    /// 构建脚本（scripts/update-config.sh 的 cc_update_channel）写进 Info.plist 和 appcast 的渠道，与应用里的规则一致。
    func testShellAndAppAgreeOnChannels() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let versions = ["0.1.0-beta.1", "0.1.0-beta.2", "1.0.0-rc.1", "0.1.0", "1.0.0"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "source scripts/update-config.sh && for v in \"$@\"; do cc_update_channel \"$v\"; done", "zsh"] + versions
        process.currentDirectoryURL = root
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, versions.map { UpdateConfiguration.Channel.forVersion($0).rawValue })
    }

    /// Sparkle 比较的是构建号（CFBundleVersion / sparkle:version），不是 0.1.0-beta.2 这样的显示版本。
    /// 用 Sparkle 自己的比较器确认我们的构建号格式（日期.时分）按时间先后排序。
    func testBuildNumbersOrderTheWaySparkleComparesThem() {
        let comparator = SUStandardVersionComparator.default
        let ordered = ["20261110.0137", "20261112.0905", "20261112.1240", "20261112.1241", "20261201.0001"]
        for (older, newer) in zip(ordered, ordered.dropFirst()) {
            XCTAssertEqual(comparator.compareVersion(older, toVersion: newer), .orderedAscending, "\(older) < \(newer)")
            XCTAssertEqual(comparator.compareVersion(newer, toVersion: older), .orderedDescending, "\(newer) > \(older)")
        }
        XCTAssertEqual(comparator.compareVersion("20261112.1240", toVersion: "20261112.1240"), .orderedSame)
    }

    /// 正式版只收默认渠道（不带 sparkle:channel 的条目）；beta 版另外收 beta 渠道。
    func testStableNeverAllowsTheBetaChannel() {
        XCTAssertEqual(UpdateConfiguration.Channel.stable.sparkleChannels, [])
        XCTAssertEqual(UpdateConfiguration.Channel.beta.sparkleChannels, ["beta"])
    }

    /// 用户决定（2026-11-12）不用 Dock 数字角标：更新代码不碰 Dock，不会覆盖别处设置的 Dock 状态。
    func testUpdatesDoNotTouchTheDock() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let updates = root.appendingPathComponent("Sources/ClassicCompanion/Updates")
        let files = try FileManager.default.contentsOfDirectory(at: updates, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in ["dockTile", "NSDockTile", "badgeLabel"] {
                XCTAssertFalse(text.contains(banned), "\(file.lastPathComponent) 用了 \(banned)")
            }
        }
    }

    // MARK: - 菜单

    @MainActor private func appMenu(_ language: AppLanguage) -> NSMenu {
        AppDelegate.makeMainMenu(modeKey: .modeStandard, language: language).menu.items[0].submenu!
    }

    /// 应用菜单：关于之后就是“检查更新…”，四种语言都有。
    func testAppMenuHasCheckForUpdatesAfterAbout() {
        for language in AppLanguage.allCases {
            let menu = appMenu(language)
            XCTAssertEqual(menu.items[0].action.map(NSStringFromSelector), "showAbout")
            XCTAssertEqual(menu.items[1].action.map(NSStringFromSelector), "checkForUpdates")
            XCTAssertEqual(menu.items[1].title, L10n.string("menu.checkForUpdates", in: language))
            XCTAssertTrue(menu.items[1].title.hasSuffix("…") || menu.items[1].title.hasSuffix("⋯"), "\(language)：打开窗口的菜单项以省略号结尾")
            XCTAssertTrue(menu.items[1].keyEquivalent.isEmpty, "不占用快捷键")
            XCTAssertTrue(menu.items[2].isSeparatorItem)
        }
        XCTAssertEqual(appMenu(.simplifiedChinese).items[1].title, "检查更新…")
        XCTAssertEqual(appMenu(.traditionalChinese).items[1].title, "檢查更新項目⋯")
        XCTAssertEqual(appMenu(.english).items[1].title, "Check for Updates…")
        XCTAssertEqual(appMenu(.japanese).items[1].title, "アップデートを確認…")
    }

    /// 定时检查发现新版本时不弹窗，只在菜单栏菜单最上面多一项（四种语言），点它打开 Sparkle 的更新窗口。
    func testStatusMenuShowsAPendingUpdateOnlyWhenThereIsOne() {
        for language in AppLanguage.allCases {
            let plain = NSMenu()
            AppDelegate.fillStatusMenu(plain, language: language)
            XCTAssertFalse(plain.items.contains { $0.action.map(NSStringFromSelector) == "checkForUpdates" })

            let pending = NSMenu()
            AppDelegate.fillStatusMenu(pending, language: language, pendingUpdate: "0.1.0-beta.2")
            XCTAssertEqual(pending.items[0].action.map(NSStringFromSelector), "checkForUpdates")
            XCTAssertTrue(pending.items[0].title.contains("0.1.0-beta.2"), pending.items[0].title)
            XCTAssertFalse(pending.items[0].title.contains("%@"))
            XCTAssertTrue(pending.items[1].isSeparatorItem)
            XCTAssertEqual(pending.items.dropFirst(2).map(\.title), plain.items.map(\.title), "\(language)：其余菜单项不变")
        }
    }

    // MARK: - 下载之前的授权和安装确认

    private func readyView(_ language: AppLanguage, kind: UpdatePromptKind, version: String? = "0.1.0-beta.2") -> NSHostingView<UpdateReadyView> {
        LanguageController.shared.preference = LanguagePreference(rawValue: language.rawValue)!
        let host = NSHostingView(rootView: UpdateReadyView(kind: kind, version: version, gate: UpdatePromptGate(), onInstall: {}, onLater: {}))
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// 两种确认窗口的文字都跟随应用语言：版本号、提醒和“稍后”的说明都在，没有漏翻的键。
    func testPromptTextFollowsTheAppLanguage() {
        let reminderWords: [AppLanguage: [String]] = [
            .english: ["generated", "Read Aloud", "typing"],
            .simplifiedChinese: ["生成", "朗读", "输入"],
            .traditionalChinese: ["產生", "朗讀", "輸入"],
            .japanese: ["生成", "読み上げ", "入力"],
        ]
        for language in AppLanguage.allCases {
            for key in ["update.ready.windowTitle", "update.ready.later"] {
                XCTAssertNotEqual(L10n.string(key, in: language), key, "\(language) 缺 \(key)")
            }
            for kind in [UpdatePromptKind.authorize, .install] {
                let prefix = kind.keyPrefix
                XCTAssertTrue(L10n.format("\(prefix).message", in: language, "0.1.0-beta.2").contains("0.1.0-beta.2"))
                for key in ["title", "messageNoVersion", "reminder", "laterNote", "install"].map({ "\(prefix).\($0)" }) {
                    XCTAssertNotEqual(L10n.string(key, in: language), key, "\(language) 缺 \(key)")
                }
                // 提醒里必须提到“生成”“朗读”和“输入”三件事。
                let reminder = L10n.string("\(prefix).reminder", in: language)
                for word in reminderWords[language] ?? [] { XCTAssertTrue(reminder.contains(word), "\(language) \(prefix)：\(word)") }
            }
        }
    }

    /// 授权窗口要说清楚：授权后下载完成会自动退出、安装并重新打开，不再询问；“稍后”或关闭什么都不下载、不安装。
    func testAuthorizationPromptExplainsWhatHappensAfterConfirming() {
        let expectations: [AppLanguage: (message: [String], later: String, button: String)] = [
            .english: (["quits", "installs", "reopens", "without asking again", "cancel"], "downloads and installs nothing", "Download and Install"),
            .simplifiedChinese: (["自动退出", "安装", "重新打开", "不会再询问", "取消"], "不会下载或安装任何东西", "下载并安装"),
            .traditionalChinese: (["自動結束", "安裝", "重新打開", "不會再次詢問", "取消"], "不會下載或安裝任何東西", "下載並安裝"),
            .japanese: (["自動的に終了", "インストール", "再び開きます", "改めて確認することはありません", "キャンセル"], "何もダウンロードもインストールもされません", "ダウンロードしてインストール"),
        ]
        for language in AppLanguage.allCases {
            guard let expected = expectations[language] else { XCTFail("\(language)"); continue }
            for message in [L10n.format("update.authorize.message", in: language, "0.1.0-beta.3"),
                            L10n.string("update.authorize.messageNoVersion", in: language)] {
                for word in expected.message { XCTAssertTrue(message.contains(word), "\(language)：\(word)") }
            }
            XCTAssertTrue(L10n.string("update.authorize.laterNote", in: language).contains(expected.later), "\(language)")
            XCTAssertEqual(L10n.string("update.authorize.install", in: language), expected.button)
        }
    }

    /// 四种语言下两种确认窗口都放得下（宽度固定 480，高度不超过一般屏幕的一半）。
    func testPromptFitsInEveryLanguage() {
        for language in AppLanguage.allCases {
            for kind in [UpdatePromptKind.authorize, .install] {
                for version in ["0.1.0-beta.2", nil] {
                    let size = readyView(language, kind: kind, version: version).fittingSize
                    XCTAssertEqual(size.width, 480, accuracy: 1, "\(language) \(kind)")
                    XCTAssertLessThan(size.height, 420, "\(language) \(kind) 需要 \(size.height)")
                    XCTAssertGreaterThan(size.height, 150, "\(language) \(kind)：文字没有被截掉成一行")
                }
            }
        }
    }

    /// 窗口出现后主按钮先停 1 秒，然后自动恢复；重新叫回窗口时重新计时。
    func testPromptGateHoldsTheMainButtonBriefly() {
        let gate = UpdatePromptGate()
        XCTAssertTrue(gate.isOpen)
        gate.hold(for: 0.2)
        XCTAssertFalse(gate.isOpen)
        gate.hold(for: 0.4)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(gate.isOpen, "第二次 hold 重新计时，第一次的计时不提前放开")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(gate.isOpen)
    }

    /// 没有用户授权就到了“准备好安装”（不应发生）：取消这次安装（Skip），不安装。
    /// 授权之后正在准备时退出应用：同样取消。
    func testReadyWithoutAuthorizationCancelsTheInstall() {
        let driver = ConfirmingUserDriver(standard: SPUStandardUserDriver(hostBundle: .main, delegate: nil))
        var logs: [String] = []
        driver.log = { logs.append($0) }
        XCTAssertFalse(driver.isHoldingInstall)
        XCTAssertFalse(driver.hasPendingInstallDecision)

        var choices: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        XCTAssertEqual(choices, [.skip])
        XCTAssertTrue(logs.last?.contains("没有用户授权") == true, logs.joined(separator: "\n"))

        driver.cancelPendingInstall(reason: "退出应用")
        XCTAssertFalse(driver.isHoldingInstall, "没有安装器时退出不需要等")
    }
}
