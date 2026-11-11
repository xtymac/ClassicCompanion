import AppKit
import WebKit

/// 是否把无障碍请求交给 WebKit。VoiceOver、切换控制开启时始终放行。
struct WebAccessibilityGate: Equatable {
    var blockRequested: Bool
    var assistiveTechnologyOn: Bool

    var allowsPageAccessibility: Bool { !blockRequested || assistiveTechnologyOn }
}

/// 任何应用一旦向 WKWebView 发无障碍请求，WebKit 就会为网页建立无障碍缓存；官方弹层打开或关闭时批量切换
/// aria-hidden，缓存逐个元素重算样式，2026-11-04 采样时主线程因此卡住十几秒，拦下请求后不再卡顿。
/// 默认拦截（用户决定），设置里可放行。本类只用公开接口，并记录每种请求第一次到达的时间（只有请求名，不含内容）。
/// WebKit 的缓存建立后不会撤销：从放行改回拦截，要等网页进程重启才完全生效。
final class CompanionWebView: WKWebView {
    var blockAccessibility = false
    var assistiveTechnologyOn: () -> Bool = {
        NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
    }
    /// 每种请求只回调一次：(请求名, 是否放行)
    var onAccessibilityRequest: ((String, Bool) -> Void)?
    private var seenRequests = Set<String>()

    private func admits(_ request: String) -> Bool {
        let allow = WebAccessibilityGate(blockRequested: blockAccessibility,
                                         assistiveTechnologyOn: assistiveTechnologyOn()).allowsPageAccessibility
        if seenRequests.insert(request).inserted { onAccessibilityRequest?(request, allow) }
        return allow
    }

    override var accessibilityFocusedUIElement: Any? {
        admits("focused") ? super.accessibilityFocusedUIElement : nil
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        admits("hitTest") ? super.accessibilityHitTest(point) : nil
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        admits(attribute.rawValue) ? super.accessibilityAttributeValue(attribute) : nil
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.ParameterizedAttribute, forParameter parameter: Any?) -> Any? {
        admits("param:\(attribute.rawValue)") ? super.accessibilityAttributeValue(attribute, forParameter: parameter) : nil
    }
}
