import Foundation

/// 应用内更新的配置，全部来自 Info.plist（build-app.sh 写入，数值在 scripts/update-config.sh）。
///
/// 代码里不写 feed 地址、公钥，也没有测试开关：正式包和隔离测试副本只靠 Info.plist 区分。
/// 正式包的 feed 必须是 HTTPS、不能带 ATS 例外，由 build-app.sh 和 verify-release.sh 检查；
/// 用户默认值里残留的 SUFeedURL 会在启动时清掉（UpdateController），只认 Info.plist。
struct UpdateConfiguration: Equatable {
    /// 更新渠道。beta 版本（版本号带 -beta 等预发布后缀）收 beta 渠道和默认渠道（适用的正式版）的更新；
    /// 正式版只收默认渠道。渠道由构建时写进 Info.plist 的 CCUpdateChannel 决定，不看 GitHub 的 Pre-release 标记；
    /// 而且只有 Info.plist 的版本号本身也是预发布版本时才认 beta（见 init），正式版不会因为配置写错收到 beta。
    enum Channel: String, Equatable, CaseIterable {
        case stable
        case beta

        /// Sparkle 的 allowedChannels。默认渠道（不带 sparkle:channel 的条目）任何渠道都能收到，不用列。
        var sparkleChannels: Set<String> {
            switch self {
            case .stable: []
            case .beta: ["beta"]
            }
        }

        /// 版本号带预发布后缀（0.1.0-beta.2、1.0.0-rc.1）就是 beta 渠道。
        /// scripts/update-config.sh 的 cc_update_channel 用同一规则（UpdateTests 核对两边一致）。
        static func forVersion(_ version: String) -> Channel {
            version.contains("-") ? .beta : .stable
        }
    }

    static let channelKey = "CCUpdateChannel"

    let feedURL: URL
    let publicKey: String
    let channel: Channel
    /// Info.plist 写的渠道和版本号推出的渠道不一致（构建配置有问题）。这时按正式版处理，并记进诊断日志。
    let channelMismatch: Bool

    /// Info.plist 缺少 feed、公钥或渠道时返回 nil：这时不启动更新器（swift run、单元测试、没有更新配置的构建）。
    init?(infoDictionary info: [String: Any]?) {
        guard let info,
              let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)), feed.host != nil,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty,
              let declared = (info[Self.channelKey] as? String).flatMap(Channel.init(rawValue:))
        else { return nil }
        let fromVersion = Channel.forVersion(info["CFBundleShortVersionString"] as? String ?? "")
        self.feedURL = feed
        self.publicKey = key
        // 两边都说 beta 才是 beta；任何不一致都按正式版，宁可少收 beta，不让正式版收到 beta。
        self.channel = declared == .beta && fromVersion == .beta ? .beta : .stable
        self.channelMismatch = declared != fromVersion
    }
}
