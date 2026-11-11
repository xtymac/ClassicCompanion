import Foundation

/// 主框架加载失败后的恢复。只做决定，不碰 WebKit 和定时器，调用方照 Action 执行。
///
/// 来由（2026-11-11 白屏）：开机登录时应用先启动，Wi‑Fi 晚 7 秒才连上，首次加载 -1009 失败，
/// 窗口里没有任何页面，此后再也没有加载。WKWebView 不显示错误页，⌘R 的 reload() 也没有可重载的页面。
///
/// - 保留失败的地址（恢复上次对话时就是那个对话），重试和 ⌘R 都加载它。
///   只保留应用内本来就允许的 https 地址（ChatGPT、登录页，见 NavigationPolicy）；其他地址不记，
///   窗口空白又没有可用地址时回到首页。重试照常经过导航策略。
/// - 只在“没有页面”且是网络类错误时自动重试；页面还在时不自动跳走。
/// - 自动重试按退避间隔，有次数上限；已知断网时不发请求，等网络恢复。
/// - 同一时间只有一次重试在进行。
///
/// 调用方约定：收到 `.schedule` 或 `.retry` 时先取消之前排的定时器，同一时间最多一个定时器。
public struct LoadRecovery: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// 现在加载这个地址。
        case retry(URL)
        /// 过这么久调用 `retryTimerFired()`。
        case schedule(after: TimeInterval)
    }

    /// 窗口里的提示。只有“没有页面”时才显示。
    public enum Status: Equatable, Sendable {
        case hidden
        /// 正在加载（自动重试、⌘R 或用户自己点的加载）。
        case connecting
        /// 还会自动重试（包括断网时等网络恢复）。
        case waiting
        /// 不再自动重试，等用户按 ⌘R 或“重新加载”。
        case stopped
    }

    /// 2+5+15+30+60 秒，在线却一直失败时约两分钟后停下。断网期间不消耗次数。
    public static let defaultBackoff: [TimeInterval] = [2, 5, 15, 30, 60]

    /// 系统还没报网络状态时按在线处理：首次失败就排第一次重试。
    public private(set) var online = true
    public private(set) var failedURL: URL?
    public private(set) var autoRetries = 0
    private let backoff: [TimeInterval]
    private let home: URL
    /// 失败时窗口里没有页面。
    private var blank = false
    /// 失败是网络类错误，可以自动重试。
    private var networkFailure = false
    private var inFlight = false

    public init(backoff: [TimeInterval] = LoadRecovery.defaultBackoff,
                home: URL = URL(string: "https://chatgpt.com/")!) {
        self.backoff = backoff
        self.home = home
    }

    /// 自动重试和 ⌘R 可以加载的地址：主框架本来就允许的 https 页面（ChatGPT、登录页）。
    public static func isRetryable(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        switch NavigationPolicy.classify(url) {
        case .chat, .auth: return true
        case .external, .blocked: return false
        }
    }

    /// 网络没连上、连不到服务器、超时、DNS 等。证书、取消等不算。
    public static func isNetworkError(domain: String, code: Int) -> Bool {
        guard domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,                  // -1001
            NSURLErrorCannotFindHost,            // -1003
            NSURLErrorCannotConnectToHost,       // -1004
            NSURLErrorNetworkConnectionLost,     // -1005
            NSURLErrorDNSLookupFailed,           // -1006
            NSURLErrorNotConnectedToInternet,    // -1009
            NSURLErrorInternationalRoamingOff,   // -1018
            NSURLErrorDataNotAllowed,            // -1020
        ].contains(code)
    }

    public var status: Status {
        guard failedURL != nil, blank else { return .hidden }
        if inFlight { return .connecting }
        return canRetryAutomatically ? .waiting : .stopped
    }

    private var canRetryAutomatically: Bool {
        failedURL != nil && blank && networkFailure && autoRetries < backoff.count
    }

    /// 主框架开始加载（任何来源）。
    public mutating func navigationStarted() {
        inFlight = true
    }

    /// 主框架加载失败（已排除取消）。`url` 取错误里的失败地址，没有就沿用上一次的。
    /// 页面还在时什么都不做：网页照常显示，⌘R 重新加载眼前的页面，不自动跳走。
    public mutating func loadFailed(url: URL?, domain: String, code: Int, hasPage: Bool) -> Action {
        guard !hasPage else {
            loadSucceeded()
            return .none
        }
        if let url, Self.isRetryable(url) {
            failedURL = url
        } else if failedURL == nil {
            failedURL = home
        }
        inFlight = false
        blank = true
        networkFailure = Self.isNetworkError(domain: domain, code: code)
        return nextAutomaticRetry()
    }

    /// 主框架加载被取消（-999、WebKit 102），而且之后没有别的加载在进行。取消不算失败，不改失败地址和原因；
    /// 只是窗口还空着时不能一直显示“正在重新连接”：回到等待，按剩下的次数排下一次。
    public mutating func navigationCancelled() -> Action {
        guard inFlight else { return .none }
        inFlight = false
        guard blank, failedURL != nil else { return .none }
        return nextAutomaticRetry()
    }

    private func nextAutomaticRetry() -> Action {
        guard canRetryAutomatically, online else { return .none }
        return .schedule(after: backoff[autoRetries])
    }

    /// 页面已经在窗口里：加载成功、主框架已提交，或失败时页面还在。
    public mutating func loadSucceeded() {
        failedURL = nil
        autoRetries = 0
        blank = false
        networkFailure = false
        inFlight = false
    }

    public mutating func retryTimerFired() -> Action {
        automaticRetry()
    }

    /// 只有从断网变成在线才算恢复。
    public mutating func networkChanged(online: Bool) -> Action {
        let cameBack = online && !self.online
        self.online = online
        return cameBack ? automaticRetry() : .none
    }

    /// 窗口显示时：还在等自动重试就提前试一次，算一次自动重试。
    public mutating func windowShown() -> Action {
        automaticRetry()
    }

    /// ⌘R 或“重新加载”。窗口空白且有失败地址时返回它（调用方用 load(URLRequest) 显式加载，空白时 reload() 不会重新请求），
    /// 并恢复自动重试的次数；否则返回 nil，走普通重新加载。
    public mutating func manualReload() -> URL? {
        guard let failedURL else { return nil }
        autoRetries = 0
        inFlight = true
        return failedURL
    }

    private mutating func automaticRetry() -> Action {
        guard canRetryAutomatically, online, !inFlight, let failedURL else { return .none }
        autoRetries += 1
        inFlight = true
        return .retry(failedURL)
    }
}
