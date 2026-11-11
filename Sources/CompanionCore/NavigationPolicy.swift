import Foundation

/// 主框架导航的分类结果。子框架（iframe，例如 Cloudflare 验证）由网页自行管理，不经过此分类。
public enum NavigationKind: Equatable, Sendable {
    /// ChatGPT 聊天页面（应用内加载）
    case chat
    /// 认证相关页面（应用内加载，用户自行完成登录）
    case auth
    /// 其他外部链接（交给系统默认浏览器）
    case external
    /// 不处理的 scheme（例如 javascript:、file:）
    case blocked
}

public enum NavigationPolicy {
    /// 聊天主站
    static let chatHosts: Set<String> = ["chatgpt.com"]

    /// 登录流程可能经过的域名。仅用于“在应用内继续加载”，应用不会读取这些页面的内容或凭证。
    static let authHostSuffixes: [String] = [
        "openai.com",              // auth.openai.com / auth0.openai.com
        "accounts.google.com",
        "appleid.apple.com",
        "idmsa.apple.com",
        "login.microsoftonline.com",
        "login.live.com",
        "account.live.com",
        "challenges.cloudflare.com",
    ]

    public static func classify(_ url: URL?) -> NavigationKind {
        guard let url, let scheme = url.scheme?.lowercased() else { return .blocked }
        switch scheme {
        case "about", "blob", "data":
            // about:blank 等由 WebKit 内部使用，视为当前页面的一部分
            return .chat
        case "https":
            break
        case "http", "mailto", "tel":
            return .external
        default:
            return .blocked
        }
        guard let host = url.host?.lowercased() else { return .blocked }
        if chatHosts.contains(host) || chatHosts.contains(where: { host.hasSuffix("." + $0) }) {
            return .chat
        }
        if authHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) || isGoogleAccountsHost(host) {
            return .auth
        }
        return .external
    }

    /// Google 登录完成后会跳转到地区账号域名（例如 accounts.google.co.jp）和 accounts.youtube.com 写入登录状态。
    /// 2026-11-03 实测：缺少地区域名时，跳转被交给外部浏览器，登录流程中断（Google 400）。
    static func isGoogleAccountsHost(_ host: String) -> Bool {
        if host == "accounts.youtube.com" { return true }
        let prefix = "accounts.google."
        guard host.hasPrefix(prefix) else { return false }
        // 后缀只允许形如 com / co.jp / com.hk / de 的国家或地区域名
        let tld = host.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(tld.count) else { return false }
        return tld.allSatisfy { part in (2...3).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isLetter } }
    }

    /// 是否为可恢复的对话 URL（/c/<id> 或 /g/<gpt>/c/<id>）。返回去掉 query/fragment 的 URL。
    public static func restorableConversationURL(_ url: URL?) -> URL? {
        guard let url, classify(url) == .chat, url.scheme == "https",
              let host = url.host?.lowercased(), chatHosts.contains(host) else { return nil }
        let parts = url.path.split(separator: "/")
        let isConversation =
            (parts.count == 2 && parts[0] == "c") ||
            (parts.count == 4 && parts[0] == "g" && parts[2] == "c")
        guard isConversation else { return nil }
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = url.path
        return comps.url
    }
}
