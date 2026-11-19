import AppKit

/// 更新后第一次启动时，把 Dock 里的图标换成应用包里的图标。
/// 应用内更新装好后自动重启时，Dock 仍显示旧图标，退出再打开一次才换成新的
/// （0.1.0-beta.3 → 0.1.0-beta.4 隔离升级，2026-11-19：安装目录里的图标和系统给运行中应用的图标都已经是新的）。
/// 只在构建号变了的那一次启动里设；全新安装和之后的普通启动不设，图标仍由系统管理
/// （自己设的图标不跟随系统的图标外观设置）。
enum DockIconRefresh {
    /// 上次运行的构建号。0.1.0-beta.4 起才记；更早的版本没有这一项。
    static let buildKey = "lastRunBuild"

    /// 0.1.0-beta.3 及更早的版本运行过就会留下的设置，用来把“从没记构建号的旧版本更新上来”和“全新安装”分开：
    /// Sparkle 的首次启动标记（0.1.0-beta.2 起）、上次的页面底色、窗口显示计数、上次的对话地址。
    /// 要在本次启动写入这些设置之前判断（Sparkle 启动、网页加载、窗口显示之前）。
    static let earlierVersionKeys = ["SUHasLaunchedBefore", "pageBackgroundRGB", "diag.showCount", "lastConversationURL"]

    enum Launch: Equatable {
        /// 没有上次的构建号，也没有旧版本留下的设置。
        case firstInstall
        case sameBuild
        /// 构建号变了。`from` 为 nil：从没记构建号的旧版本更新上来。
        case updated(from: String?)
    }

    static func classify(defaults: UserDefaults, build: String) -> Launch {
        if let last = defaults.string(forKey: buildKey) {
            return last == build ? .sameBuild : .updated(from: last)
        }
        let ranBefore = earlierVersionKeys.contains { defaults.object(forKey: $0) != nil }
        return ranBefore ? .updated(from: nil) : .firstInstall
    }

    /// 判断这次启动是哪一种，并记下这次的构建号。没打包运行（没有构建号）时不记，也不算更新。
    static func recordLaunch(defaults: UserDefaults, build: String) -> Launch {
        guard build != "unbundled" else { return .sameBuild }
        let launch = classify(defaults: defaults, build: build)
        defaults.set(build, forKey: buildKey)
        return launch
    }

    /// 应用包里的图标文件（Info.plist 的 CFBundleIconFile），不经过系统的图标缓存。
    static func bundleIcon(in bundle: Bundle = .main) -> NSImage? {
        guard let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let url = bundle.url(forResource: (name as NSString).deletingPathExtension, withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }
}
