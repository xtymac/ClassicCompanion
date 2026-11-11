import AppKit
import XCTest
@testable import ClassicCompanion

/// 界面语言：跟随系统时怎么选、手动选择的保存、字符串表和资源包。
/// 真实界面里的切换、菜单和布局要在真实应用上看，这里不能代替。
final class LocalizationTests: XCTestCase {
    // MARK: - 跟随系统

    private func match(_ preferred: [String]) -> AppLanguage {
        AppLanguage.matching(preferredLanguages: preferred)
    }

    func testRegionTagsMatchTheirLanguage() {
        XCTAssertEqual(match(["en-US"]), .english)
        XCTAssertEqual(match(["en-GB"]), .english)
        XCTAssertEqual(match(["en-JP"]), .english)
        XCTAssertEqual(match(["ja-JP"]), .japanese)
        XCTAssertEqual(match(["ja"]), .japanese)
    }

    func testSimplifiedChineseTagsMatchSimplifiedChinese() {
        XCTAssertEqual(match(["zh-Hans"]), .simplifiedChinese)
        XCTAssertEqual(match(["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(match(["zh-Hans-CN"]), .simplifiedChinese)
        XCTAssertEqual(match(["zh-Hans-JP"]), .simplifiedChinese)
        XCTAssertEqual(match(["zh-SG"]), .simplifiedChinese)
        XCTAssertEqual(match(["zh-Hans-HK"]), .simplifiedChinese, "香港用简体的写法仍是简体")
        XCTAssertEqual(match(["zh"]), .simplifiedChinese)
    }

    func testTraditionalChineseTagsMatchTraditionalChinese() {
        for tag in ["zh-Hant", "zh-Hant-TW", "zh-TW", "zh-HK", "zh-Hant-HK", "zh-MO", "zh-Hant-MO", "zh-Hant-JP"] {
            XCTAssertEqual(match([tag]), .traditionalChinese, "\(tag) 是繁体，不能显示简体")
        }
    }

    /// 简繁体只按首选语言列表的顺序定，不互相替代。
    func testSimplifiedAndTraditionalChineseFollowThePreferredOrder() {
        XCTAssertEqual(match(["zh-HK", "zh-Hans-CN"]), .traditionalChinese)
        XCTAssertEqual(match(["zh-Hans-CN", "zh-Hant-TW"]), .simplifiedChinese)
        XCTAssertEqual(match(["zh-Hant-TW", "ja-JP"]), .traditionalChinese)
        XCTAssertEqual(match(["fr-FR", "zh-MO"]), .traditionalChinese, "前面没有的语言跳过")
    }

    /// 粤语没有单独的界面，系统给应用选本地化时退到繁体中文（Foundation 的规则，2026-11-09 实测），这里照系统走。
    func testCantoneseUsesTraditionalChineseLikeTheSystem() {
        XCTAssertEqual(match(["yue-Hant-HK"]), .traditionalChinese)
        XCTAssertEqual(match(["yue-HK"]), .traditionalChinese)
    }

    func testOrderOfThePreferredListDecides() {
        XCTAssertEqual(match(["en-JP", "ja-JP", "zh-Hans-JP"]), .english, "本机的顺序")
        XCTAssertEqual(match(["ja-JP", "en-US", "zh-Hans-CN"]), .japanese)
        XCTAssertEqual(match(["zh-Hans-CN", "ja-JP", "en-US"]), .simplifiedChinese)
        XCTAssertEqual(match(["fr-FR", "ja-JP", "en-US"]), .japanese, "前面没有的语言跳过")
    }

    func testUnsupportedLanguagesFallBackToEnglish() {
        XCTAssertEqual(match(["ko-KR"]), .english)
        XCTAssertEqual(match(["fr-FR", "de-DE"]), .english)
        XCTAssertEqual(match([]), .english)
    }

    // MARK: - 手动选择

    private var suiteName = ""

    private func freshDefaults() -> UserDefaults {
        let name = "LocalizationTests.\(UUID().uuidString)"
        suiteName = name
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    func testFollowsSystemWhenNothingIsSaved() {
        XCTAssertEqual(LanguagePreference.stored(in: freshDefaults()), .system)
    }

    func testUnknownSavedValueFollowsSystem() {
        let defaults = freshDefaults()
        defaults.set("fr", forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(LanguagePreference.stored(in: defaults), .system)
    }

    func testFixedChoiceIgnoresTheSystemList() {
        XCTAssertEqual(LanguagePreference.japanese.resolve(systemLanguages: ["en-US"]), .japanese)
        XCTAssertEqual(LanguagePreference.simplifiedChinese.resolve(systemLanguages: ["ja-JP"]), .simplifiedChinese)
        XCTAssertEqual(LanguagePreference.english.resolve(systemLanguages: ["zh-Hans-CN"]), .english)
        XCTAssertEqual(LanguagePreference.traditionalChinese.resolve(systemLanguages: ["zh-Hans-CN"]), .traditionalChinese)
        XCTAssertEqual(LanguagePreference.simplifiedChinese.resolve(systemLanguages: ["zh-Hant-TW"]), .simplifiedChinese)
        XCTAssertEqual(LanguagePreference.system.resolve(systemLanguages: ["ja-JP"]), .japanese)
    }

    @MainActor func testChoiceIsSavedAndReadBackOnNextLaunch() {
        let defaults = freshDefaults()
        let first = LanguageController(defaults: defaults, systemLanguages: { ["en-US"] }, apply: { _ in })
        XCTAssertEqual(first.language, .english)
        first.preference = .japanese
        XCTAssertEqual(first.language, .japanese)

        let next = LanguageController(defaults: defaults, systemLanguages: { ["en-US"] }, apply: { _ in })
        XCTAssertEqual(next.preference, .japanese)
        XCTAssertEqual(next.language, .japanese)

        next.preference = .traditionalChinese
        XCTAssertEqual(defaults.string(forKey: LanguagePreference.defaultsKey), "zh-Hant")
        let third = LanguageController(defaults: defaults, systemLanguages: { ["zh-Hans-CN"] }, apply: { _ in })
        XCTAssertEqual(third.preference, .traditionalChinese)
        XCTAssertEqual(third.language, .traditionalChinese, "手动选的繁体优先于简体的系统语言")
    }

    @MainActor func testGoingBackToSystemRemovesTheSavedChoice() {
        let defaults = freshDefaults()
        let controller = LanguageController(defaults: defaults, systemLanguages: { ["zh-Hans-CN"] }, apply: { _ in })
        controller.preference = .english
        controller.preference = .system
        XCTAssertNil(defaults.object(forKey: LanguagePreference.defaultsKey))
        XCTAssertEqual(controller.language, .simplifiedChinese)
        XCTAssertEqual(LanguageController(defaults: defaults, systemLanguages: { ["ja-JP"] }, apply: { _ in }).language, .japanese,
                       "跟随系统时，下次启动按那时的系统语言")
    }

    /// 写 AppleLanguages 会让 WebKit 的 navigator.language 跟着变，ChatGPT 网页就可能换语言。
    @MainActor func testChangingLanguageNeverWritesAppleLanguages() {
        let defaults = freshDefaults()
        let controller = LanguageController(defaults: defaults, systemLanguages: { ["en-US"] }, apply: { _ in })
        for preference in LanguagePreference.allCases.reversed() { controller.preference = preference }
        controller.preference = .japanese
        XCTAssertEqual(Set(defaults.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? []), [LanguagePreference.defaultsKey],
                       "只写 appLanguage，不写 AppleLanguages、AppleLocale")
    }

    @MainActor func testEveryChangeIsAppliedOnce() {
        var applied: [AppLanguage] = []
        let controller = LanguageController(defaults: freshDefaults(), systemLanguages: { ["en-US"] }, apply: { applied.append($0) })
        controller.preference = .japanese
        controller.preference = .japanese
        controller.preference = .simplifiedChinese
        controller.preference = .traditionalChinese
        controller.preference = .system
        XCTAssertEqual(applied, [.english, .japanese, .simplifiedChinese, .traditionalChinese, .english])
    }

    // MARK: - 选项的写法

    func testLanguageNamesAreWrittenInTheirOwnLanguage() {
        XCTAssertEqual(AppLanguage.simplifiedChinese.nativeName, "简体中文")
        XCTAssertEqual(AppLanguage.traditionalChinese.nativeName, "繁體中文")
        XCTAssertEqual(AppLanguage.english.nativeName, "English")
        XCTAssertEqual(AppLanguage.japanese.nativeName, "日本語")
    }

    func testPickerOptionsInRequiredOrder() {
        XCTAssertEqual(LanguagePreference.allCases, [.system, .simplifiedChinese, .traditionalChinese, .english, .japanese])
        for language in AppLanguage.allCases {
            XCTAssertEqual(LanguagePreference.simplifiedChinese.title(in: language), "简体中文")
            XCTAssertEqual(LanguagePreference.traditionalChinese.title(in: language), "繁體中文")
            XCTAssertEqual(LanguagePreference.english.title(in: language), "English")
            XCTAssertEqual(LanguagePreference.japanese.title(in: language), "日本語")
        }
        XCTAssertEqual(LanguagePreference.system.title(in: .simplifiedChinese), "跟随系统")
        XCTAssertEqual(LanguagePreference.system.title(in: .english), "Follow System")
        XCTAssertEqual(LanguagePreference.system.title(in: .japanese), "システムに合わせる")
        XCTAssertEqual(LanguagePreference.system.title(in: .traditionalChinese), "跟隨系統")
    }

    // MARK: - 字符串表

    private func table(_ language: AppLanguage) throws -> [String: String] {
        let url = try XCTUnwrap(L10n.resources?.url(forResource: "Localizable", withExtension: "strings",
                                                     subdirectory: nil, localization: language.rawValue))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    private func pluralTable(_ language: AppLanguage) throws -> [String: Any] {
        let url = try XCTUnwrap(L10n.resources?.url(forResource: "Localizable", withExtension: "stringsdict",
                                                     subdirectory: nil, localization: language.rawValue))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
    }

    func testResourceBundleIsFoundOutsideTheApp() {
        XCTAssertNotNil(L10n.resources, "swift test 下资源包在测试包旁边")
    }

    func testEveryLanguageHasTheSameKeys() throws {
        XCTAssertEqual(Set(AppLanguage.allCases.map(\.rawValue)), ["en", "ja", "zh-Hans", "zh-Hant"])
        let english = try Set(table(.english).keys)
        XCTAssertGreaterThan(english.count, 100)
        for language in AppLanguage.allCases where language != .english {
            let keys = try Set(table(language).keys)
            XCTAssertEqual(keys.subtracting(english), [], "\(language) 多出的键")
            XCTAssertEqual(english.subtracting(keys), [], "\(language) 缺的键")
            XCTAssertEqual(try Set(pluralTable(language).keys), try Set(pluralTable(.english).keys), "\(language) 复数表")
        }
    }

    /// 格式里的 %@、%ld 个数和类型必须一致，不然 String(format:) 会读错参数。
    func testFormatSpecifiersMatchAcrossLanguages() throws {
        let english = try table(.english)
        for language in AppLanguage.allCases where language != .english {
            let other = try table(language)
            for (key, value) in english {
                XCTAssertEqual(Self.specifiers(other[key] ?? ""), Self.specifiers(value), "\(language) \(key)")
            }
        }
    }

    func testNoEmptyOrUntranslatedPlaceholderValues() throws {
        for language in AppLanguage.allCases {
            for (key, value) in try table(language) {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language) \(key)")
                XCTAssertNotEqual(value, key, "\(language) \(key)")
            }
        }
    }

    /// 简体表里不能混进日文假名，日文表里不能混进简体特有的字（常见的漏翻）。
    func testTablesAreWrittenInTheirOwnLanguage() throws {
        let kana = try NSRegularExpression(pattern: "[\\p{Hiragana}\\p{Katakana}]")
        for (key, value) in try table(.simplifiedChinese) {
            XCTAssertNil(kana.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), "简体表 \(key)：\(value)")
        }
        let han = try NSRegularExpression(pattern: "\\p{Han}")
        for (key, value) in try table(.english) {
            XCTAssertNil(han.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), "英文表 \(key)：\(value)")
        }
        for (key, value) in try table(.japanese) where value.contains(where: { "们这个时对说设关开显选择键还为应".contains($0) }) {
            XCTFail("日文表 \(key) 像简体：\(value)")
        }
        for (key, value) in try table(.traditionalChinese) {
            XCTAssertNil(kana.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), "繁体表 \(key)：\(value)")
            if let c = value.first(where: { Self.simplifiedOnly.contains($0) }) { XCTFail("繁体表 \(key) 有简体字「\(c)」：\(value)") }
        }
        for (key, value) in try table(.simplifiedChinese) {
            if let c = value.first(where: { Self.traditionalOnly.contains($0) }) { XCTFail("简体表 \(key) 有繁体字「\(c)」：\(value)") }
        }
    }

    /// 只在一边用的字形（两边都合法的字不放进来，比如“后”“里”“于”“窗”）。
    static let simplifiedOnly = "们这时对说设关开显选择键还为应发输语页创录读诊断认试档图网话记动从单务办区击请隐缩视将让该钮释览确实验证态载"
    static let traditionalOnly = "們這時對說設關開顯選擇鍵還為應發輸語頁創錄讀診斷認試檔圖網話記動從單務辦區擊請隱縮視將讓該鈕釋覽確實驗證態載"

    /// 繁体用 macOS 繁体中文（台湾）自己的菜单用词（取自系统 AppKit 的 zh_TW 表），不是逐字转写简体。
    @MainActor func testTraditionalChineseMenuUsesMacTerms() {
        let words = titles(AppDelegate.makeMainMenu(modeKey: .modeStandard, language: .traditionalChinese).menu)
        for term in ["關於 Classic Companion", "設定⋯", "隱藏 Classic Companion", "隱藏其他", "顯示全部", "結束 Classic Companion",
                     "檔案", "關閉視窗", "編輯", "還原", "重做", "剪下", "拷貝", "貼上", "全選", "顯示方式", "放大", "縮小",
                     "實際大小", "視窗", "縮到最小", "縮放", "將此程式所有視窗移至最前"] {
            XCTAssertTrue(words.contains(term), "\(term) 不在：\(words)")
        }
    }

    func testEveryKeyUsedInTheSourcesExists() throws {
        let english = try table(.english)
        let plurals = try pluralTable(.english)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/ClassicCompanion")
        let pattern = try NSRegularExpression(pattern: #"(?:L10n\.(?:string|format|plural)|LocalizedText)\(\s*"([a-zA-Z0-9_.]+)""#)
        var used = Set<String>()
        for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                used.insert(String(text[Range(m.range(at: 1), in: text)!]))
            }
        }
        XCTAssertGreaterThan(used.count, 100)
        XCTAssertEqual(used.filter { english[$0] == nil && plurals[$0] == nil }, [], "代码里用了表里没有的键")
    }

    static func specifiers(_ format: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:(\\d+)\\$)?(?:#@[a-zA-Z]+@|l?[@dDuUxXfgs])")
        let matches = regex.matches(in: format, range: NSRange(format.startIndex..., in: format))
        var result: [(Int, String)] = []
        for (index, m) in matches.enumerated() {
            let whole = String(format[Range(m.range, in: format)!])
            let position = Range(m.range(at: 1), in: format).flatMap { Int(format[$0]) } ?? index + 1
            let type = whole.replacingOccurrences(of: "^%(\\d+\\$)?", with: "%", options: .regularExpression)
            result.append((position, type))
        }
        return result.sorted { $0.0 < $1.0 }.map { "\($0.0):\($0.1)" }
    }

    // MARK: - 取字符串

    func testLookupUsesTheRequestedLanguage() {
        XCTAssertEqual(L10n.string("menu.newChat", in: .simplifiedChinese), "新建对话")
        XCTAssertEqual(L10n.string("menu.newChat", in: .english), "New Chat")
        XCTAssertEqual(L10n.string("menu.newChat", in: .japanese), "新規チャット")
        XCTAssertEqual(L10n.string("menu.newChat", in: .traditionalChinese), "新增對話")
    }

    func testFormatPutsArgumentsInPlace() {
        XCTAssertEqual(L10n.format("about.version", in: .simplifiedChinese, "0.1.0", "20261109.1700"), "版本 0.1.0（构建 20261109.1700）")
        XCTAssertEqual(L10n.format("about.version", in: .english, "0.1.0", "20261109.1700"), "Version 0.1.0 (Build 20261109.1700)")
        XCTAssertEqual(L10n.format("about.version", in: .japanese, "0.1.0", "20261109.1700"), "バージョン 0.1.0（ビルド 20261109.1700）")
        XCTAssertEqual(L10n.format("about.version", in: .traditionalChinese, "0.1.0", "20261109.1700"), "版本 0.1.0（建置 20261109.1700）")
    }

    func testPluralsFollowTheLanguage() {
        XCTAssertEqual(L10n.plural("diag.messageCount", in: .english, 1), "1 message")
        XCTAssertEqual(L10n.plural("diag.messageCount", in: .english, 2), "2 messages")
        XCTAssertEqual(L10n.plural("diag.messageCount", in: .english, 0), "0 messages")
        XCTAssertEqual(L10n.plural("diag.messageCount", in: .simplifiedChinese, 1), "共 1 条")
        XCTAssertEqual(L10n.plural("diag.messageCount", in: .simplifiedChinese, 2), "共 2 条")
        XCTAssertEqual(L10n.plural("diag.messageCount", in: .japanese, 2), "2 件")
        XCTAssertEqual(L10n.plural("diag.messageCount", in: .traditionalChinese, 1), "共 1 則")
        XCTAssertEqual(L10n.plural("diag.messageCount", in: .traditionalChinese, 2), "共 2 則")
    }

    func testMissingKeyShowsTheKeyInsteadOfCrashing() {
        XCTAssertEqual(L10n.string("no.such.key", in: .japanese), "no.such.key")
    }

    func testLocalizedTextIsRenderedWhenShown() {
        let text = LocalizedText("hotkey.reject.common", .plain("⌘C"))
        XCTAssertEqual(text.string(in: .simplifiedChinese), "⌘C 是常用的快捷键，请换一个。")
        XCTAssertEqual(text.string(in: .english), "⌘C is a common shortcut. Choose another one.")
        XCTAssertEqual(text.string(in: .japanese), "⌘C はよく使われるショートカットです。別の組み合わせを選んでください。")
        XCTAssertEqual(text.string(in: .traditionalChinese), "⌘C 是常用的快速鍵，請換一個。")
        XCTAssertEqual(LocalizedText.verbatim("⌥…").string(in: .japanese), "⌥…")
    }

    func testNestedTextAndListsUseTheSameLanguage() {
        let nested = LocalizedText("hotkey.reject.used", .plain("⌘W"), .text(LocalizedText("purpose.hideWindow")))
        XCTAssertEqual(nested.string(in: .simplifiedChinese), "⌘W 用来隐藏窗口，请换一个。")
        XCTAssertEqual(nested.string(in: .english), "⌘W is used to hide the window. Choose another one.")
        let list = LocalizedText("hotkey.conflict", .list(["Gemini", "ChatGPT"]))
        XCTAssertEqual(list.string(in: .simplifiedChinese), "按下时 Gemini、ChatGPT 也会打开。")
        XCTAssertEqual(list.string(in: .english), "Pressing it also opens Gemini, ChatGPT.")
        XCTAssertEqual(list.string(in: .japanese), "押すと Gemini、ChatGPT も開きます。")
        XCTAssertEqual(nested.string(in: .traditionalChinese), "⌘W 用來隱藏視窗，請換一個。")
        XCTAssertEqual(list.string(in: .traditionalChinese), "按下時 Gemini、ChatGPT 也會打開。")
    }

    // MARK: - 菜单

    private struct ItemShape: Equatable {
        let action: String, key: String, modifiers: UInt, hidden: Bool, separator: Bool, depth: Int
    }

    @MainActor private func shape(_ menu: NSMenu, depth: Int = 0) -> [ItemShape] {
        menu.items.flatMap { item in
            [ItemShape(action: item.action.map(NSStringFromSelector) ?? "", key: item.keyEquivalent,
                       modifiers: item.keyEquivalentModifierMask.rawValue, hidden: item.isHidden,
                       separator: item.isSeparatorItem, depth: depth)]
                + (item.submenu.map { shape($0, depth: depth + 1) } ?? [])
        }
    }

    @MainActor private func titles(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { item in
            (item.isSeparatorItem ? [] : [item.title]) + (item.submenu.map { [$0.title] + titles($0) } ?? [])
        }.filter { !$0.isEmpty }
    }

    @MainActor func testMainMenuKeepsActionsAndShortcutsInEveryLanguage() {
        let menus = AppLanguage.allCases.map { AppDelegate.makeMainMenu(modeKey: .modeStandard, language: $0).menu }
        let english = shape(menus[0])
        XCTAssertGreaterThan(english.count, 25)
        for menu in menus.dropFirst() { XCTAssertEqual(shape(menu), english) }
        for (language, menu) in zip(AppLanguage.allCases, menus) {
            let words = titles(menu)
            XCTAssertFalse(words.contains { $0.hasPrefix("menu.") }, "\(language) 有没翻译的键：\(words)")
        }
        let all = menus.map(titles)
        XCTAssertEqual(Set(all.map { $0.joined(separator: "|") }).count, AppLanguage.allCases.count, "每种语言的菜单字都不同")
    }

    /// 以前的版本菜单就是中文：简体中文下除了切换项外，菜单字和以前一样。
    @MainActor func testChineseMainMenuKeepsThePreviousWording() {
        let words = titles(AppDelegate.makeMainMenu(modeKey: .modeStandard, language: .simplifiedChinese).menu)
        for previous in ["关于 Classic Companion", "设置…", "诊断", "隐藏 Classic Companion", "隐藏其他", "全部显示",
                         "退出 Classic Companion", "文件", "新建对话", "重新加载", "关闭窗口", "编辑", "撤销", "重做", "剪切",
                         "拷贝", "粘贴", "全选", "显示", "放大", "缩小", "实际大小", "窗口", "最小化", "缩放", "前置全部窗口"] {
            XCTAssertTrue(words.contains(previous), previous)
        }
    }

    @MainActor func testModeShortcutFollowsTheSettingInEveryLanguage() {
        let custom = HotKeyCombo(keyCode: 40, carbonModifiers: 2048 | 4096)
        for language in AppLanguage.allCases {
            let item = AppDelegate.makeMainMenu(modeKey: custom, language: language).modeItem
            XCTAssertEqual(item.keyEquivalent, custom.menuKeyEquivalent?.key)
            XCTAssertEqual(item.keyEquivalentModifierMask, custom.menuKeyEquivalent?.modifiers)
        }
    }

    /// 主菜单和菜单栏菜单里同一个功能用同一句话。
    @MainActor func testStatusMenuUsesTheMainMenuWords() {
        for language in AppLanguage.allCases {
            let main = AppDelegate.makeMainMenu(modeKey: .modeStandard, language: language).menu
            var mainTitles: [String: String] = [:]
            func collect(_ menu: NSMenu) {
                for item in menu.items {
                    if let action = item.action, !item.isHidden { mainTitles[NSStringFromSelector(action)] = item.title }
                    item.submenu.map(collect)
                }
            }
            collect(main)
            let status = NSMenu()
            AppDelegate.fillStatusMenu(status, language: language)
            var shared = 0
            for item in status.items {
                guard let action = item.action, let title = mainTitles[NSStringFromSelector(action)] else { continue }
                XCTAssertEqual(item.title, title, "\(language) \(NSStringFromSelector(action))")
                shared += 1
            }
            XCTAssertEqual(shared, 5, "新建对话、设置、诊断、关于、退出")
            XCTAssertEqual(status.items.filter { !$0.isSeparatorItem }.count, 7)
        }
    }

    // MARK: - 打包后的位置

    /// build-app.sh 把资源包放进 Contents/Resources。按同样的位置摆一个假应用，确认找得到、每种语言都能读。
    func testResourceBundleIsFoundInsidePackagedApp() throws {
        let built = try XCTUnwrap(L10n.resources?.bundleURL)
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("L10nProbe-\(UUID().uuidString).app")
        addTeardownBlock { try? FileManager.default.removeItem(at: app) }
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: built, to: resources.appendingPathComponent(L10n.resourceBundleName))
        try #"{"CFBundleIdentifier":"local.l10nprobe","CFBundlePackageType":"APPL"}"#
            .write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let packaged = try XCTUnwrap(L10n.locateResources(near: [XCTUnwrap(Bundle(url: app))]))
        XCTAssertEqual(packaged.bundleURL.resolvingSymlinksInPath().path,
                       resources.appendingPathComponent(L10n.resourceBundleName).resolvingSymlinksInPath().path)
        let tables = L10n.tables(in: packaged)
        XCTAssertEqual(Set(tables.keys), Set(AppLanguage.allCases))
        XCTAssertEqual(L10n.string("menu.newChat", in: .japanese, tables: tables), "新規チャット")
        XCTAssertEqual(L10n.string("menu.newChat", in: .traditionalChinese, tables: tables), "新增對話")
    }

    func testNoResourceBundleNearAnUnrelatedBundle() {
        XCTAssertNil(L10n.locateResources(near: [Bundle(for: NSObject.self)]))
    }
}
