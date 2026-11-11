import Foundation
import Combine
import Synchronization

/// 应用界面语言：简体中文、繁体中文、英文、日文。
///
/// 只管应用自己的原生界面，不碰 ChatGPT 网页。切换语言不写 AppleLanguages：写了以后 WebKit 的
/// navigator.language（和 Accept-Language）也会跟着变，网页就可能换语言。2026-11-09 用小程序实测：
/// navigator.language 只跟系统的首选语言列表走，应用声明哪些本地化不影响它。
enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    /// 一套繁体（用 macOS 繁体中文的台湾用词），不分台湾、香港版本。
    case traditionalChinese = "zh-Hant"

    /// 语言名用这种语言自己写，任何界面语言下都一样。
    var nativeName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// 按系统首选语言列表的顺序找第一个支持的语言，用 Foundation 给应用选本地化的同一套规则：
    /// en-GB、ja-JP、zh-CN、zh-Hans-JP 这样带地区的标签能对上；zh-Hant、zh-TW、zh-HK、zh-MO 是繁体，
    /// zh-CN、zh-SG、zh-Hans-HK 是简体，简繁按列表顺序定、不互相替代（粤语按系统规则退到繁体）；都对不上时用英文。
    static func matching(preferredLanguages: [String]) -> AppLanguage {
        let match = Bundle.preferredLocalizations(from: allCases.map(\.rawValue), forPreferences: preferredLanguages).first
        return match.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }
}

/// 设置里“应用语言”的选项，按这个顺序显示。手动选择保存在 UserDefaults 的 appLanguage，跟随系统时不保存。
enum LanguagePreference: String, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"

    static let defaultsKey = "appLanguage"

    var fixedLanguage: AppLanguage? { AppLanguage(rawValue: rawValue) }

    func resolve(systemLanguages: [String]) -> AppLanguage {
        fixedLanguage ?? AppLanguage.matching(preferredLanguages: systemLanguages)
    }

    /// 选项上的字：语言名总是用它自己的语言写；“跟随系统”跟着当前界面语言。
    func title(in language: AppLanguage) -> String {
        fixedLanguage?.nativeName ?? L10n.string("settings.language.system", in: language)
    }

    static func stored(in defaults: UserDefaults) -> LanguagePreference {
        defaults.string(forKey: defaultsKey).flatMap(LanguagePreference.init(rawValue:)) ?? .system
    }
}

/// 界面文字都从这里取，各处不判断语言。
///
/// 字符串表是 Resources/<语言>.lproj/Localizable.strings，带数量的句子在 Localizable.stringsdict。
/// swift build 把它们放进资源包 ClassicCompanion_ClassicCompanion.bundle；build-app.sh 再把资源包复制到
/// 应用的 Contents/Resources/。日志和诊断报告不经过这里，仍是原来的中文，方便和以前的记录对照、给脚本查。
enum L10n {
    /// swift build 按“包名_目标名”命名资源包。
    static let resourceBundleName = "ClassicCompanion_ClassicCompanion.bundle"

    /// 不用 SwiftPM 生成的 Bundle.module：它只在应用根目录和本机构建目录里找，找不到就直接崩溃；
    /// 资源包放在应用根目录又会让签名不合规。
    static let resources: Bundle? = locateResources(near: [.main, Bundle(for: BundleMarker.self)])

    /// 打包的应用：Contents/Resources/ 里。swift build、swift test：和可执行文件或测试包在同一个目录。
    static func locateResources(near bundles: [Bundle]) -> Bundle? {
        var candidates: [URL] = []
        for bundle in bundles {
            if let resources = bundle.resourceURL { candidates.append(resources) }
            candidates.append(bundle.bundleURL)
            candidates.append(bundle.bundleURL.deletingLastPathComponent())
        }
        return candidates.lazy
            .map { $0.appendingPathComponent(resourceBundleName) }
            .compactMap { Bundle(url: $0) }
            .first { $0.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en") != nil }
    }

    /// 每种语言一个只含该语言的表。手动选的语言可以和系统语言不同，所以不靠 Bundle 自己按系统选。
    static func tables(in resources: Bundle?) -> [AppLanguage: Bundle] {
        guard let resources else { return [:] }
        var tables: [AppLanguage: Bundle] = [:]
        for language in AppLanguage.allCases {
            if let folder = resources.url(forResource: language.rawValue, withExtension: "lproj"), let table = Bundle(url: folder) {
                tables[language] = table
            }
        }
        return tables
    }

    private static let allTables = tables(in: resources)

    private static let current = Mutex(LanguagePreference.stored(in: .standard).resolve(systemLanguages: Locale.preferredLanguages))

    /// 当前界面语言。启动时按保存的选择或系统语言定好；之后只由 LanguageController 改。
    static var language: AppLanguage { current.withLock { $0 } }

    static func use(_ language: AppLanguage) { current.withLock { $0 = language } }

    private static let missing = "\u{1}missing\u{1}"

    static func string(_ key: String, in language: AppLanguage? = nil) -> String {
        string(key, in: language ?? self.language, tables: allTables)
    }

    /// 表里没有这个键时先用英文，再没有就显示键名，不崩溃。测试保证各语言表的键一样。
    static func string(_ key: String, in language: AppLanguage, tables: [AppLanguage: Bundle]) -> String {
        for candidate in [language, .english] {
            if let value = tables[candidate]?.localizedString(forKey: key, value: missing, table: nil), value != missing {
                return value
            }
        }
        return key
    }

    /// 带参数的句子。参数位置写在表里（%1$@、%2$@），各语言可以调换顺序。
    static func format(_ key: String, in language: AppLanguage? = nil, _ arguments: CVarArg...) -> String {
        let language = language ?? self.language
        return String(format: string(key, in: language), locale: language.locale, arguments: arguments)
    }

    /// 带数量的句子，复数规则在 Localizable.stringsdict。
    static func plural(_ key: String, in language: AppLanguage? = nil, _ count: Int) -> String {
        let language = language ?? self.language
        return String(format: string(key, in: language), locale: language.locale, arguments: [count])
    }

    /// 几个名字连起来（应用名等）。中文（简繁）和日文用顿号，英文用逗号。
    static func list(_ items: [String], in language: AppLanguage? = nil) -> String {
        items.joined(separator: string("list.separator", in: language))
    }
}

/// 找测试包和应用包用。
private final class BundleMarker {}

/// 一句界面文字：存键和参数，显示时按当前语言生成。错误和提示存成这样，切换语言后已经显示的也跟着换。
struct LocalizedText: Hashable, Sendable {
    enum Argument: Hashable, Sendable {
        /// 不翻译的文字：快捷键符号、按键名、应用名。
        case plain(String)
        case text(LocalizedText)
        /// 几个名字，按语言连接。
        case list([String])
    }

    let key: String
    let arguments: [Argument]

    init(_ key: String, _ arguments: Argument...) {
        self.key = key
        self.arguments = arguments
    }

    private init(key: String, arguments: [Argument]) {
        self.key = key
        self.arguments = arguments
    }

    /// 本身不用翻译的内容，比如录制时框里的“⌥…”。
    static func verbatim(_ text: String) -> LocalizedText { LocalizedText(key: "", arguments: [.plain(text)]) }

    func string(in language: AppLanguage? = nil) -> String {
        let language = language ?? L10n.language
        let values: [String] = arguments.map {
            switch $0 {
            case .plain(let text): text
            case .text(let nested): nested.string(in: language)
            case .list(let items): L10n.list(items, in: language)
            }
        }
        if key.isEmpty { return values.joined() }
        let format = L10n.string(key, in: language)
        return values.isEmpty ? format : String(format: format, locale: language.locale, arguments: values)
    }
}

/// 设置里的“应用语言”。改了马上生效：界面观察它重新显示，菜单和窗口标题由 AppDelegate 重建，不用重启。
@MainActor
final class LanguageController: ObservableObject {
    static let shared = LanguageController()

    @Published var preference: LanguagePreference {
        didSet {
            guard preference != oldValue else { return }
            if preference == .system {
                defaults.removeObject(forKey: LanguagePreference.defaultsKey)
            } else {
                defaults.set(preference.rawValue, forKey: LanguagePreference.defaultsKey)
            }
            update()
        }
    }

    @Published private(set) var language: AppLanguage

    var locale: Locale { language.locale }

    private let defaults: UserDefaults
    private let systemLanguages: () -> [String]
    private let apply: (AppLanguage) -> Void

    /// - Parameter apply: 定下语言后调用。默认交给 L10n，界面从那里取字；测试传别的，免得改动全局语言。
    init(defaults: UserDefaults = .standard, systemLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
         apply: @escaping (AppLanguage) -> Void = { L10n.use($0) }) {
        self.defaults = defaults
        self.systemLanguages = systemLanguages
        self.apply = apply
        let preference = LanguagePreference.stored(in: defaults)
        self.preference = preference
        let language = preference.resolve(systemLanguages: systemLanguages())
        self.language = language
        apply(language)
    }

    private func update() {
        let resolved = preference.resolve(systemLanguages: systemLanguages())
        guard resolved != language else { return }
        // 先交给 L10n 再发布：收到变化的菜单和界面重建时，取到的已经是新语言。
        apply(resolved)
        language = resolved
    }
}
