import Foundation

/// 版本信息一律来自 Bundle，不在代码里写死。
struct AppInfo {
    /// 公开反馈地址（用户 2026-11-08 建好公开仓库并开了 Issues）。改地址时同步 docs/trial-notes.md 的“反馈”一节。
    static let feedbackURL: URL? = URL(string: "https://github.com/mactokyo/ClassicCompanion/issues")

    static var current: AppInfo { AppInfo(infoDictionary: Bundle.main.infoDictionary) }

    let version: String
    let build: String
    let usesPlaceholderIcon: Bool

    init(infoDictionary info: [String: Any]?) {
        version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        build = info?["CFBundleVersion"] as? String ?? "unbundled"
        usesPlaceholderIcon = info?["CCIconStatus"] as? String == "placeholder"
    }

    var summary: String { "\(version) (\(build))" }

    /// 反馈时附上的信息：只有版本和系统，不含对话内容。
    func feedbackText(system: String, architecture: String) -> String {
        "Classic Companion \(summary)\n\(system), \(architecture)"
    }

    static var runningArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}
