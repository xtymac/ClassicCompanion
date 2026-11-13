import Foundation
import Combine
import CompanionCore

/// 唤醒快捷键叫出窗口时用哪个模式（用户 2026-11-14 改为默认“保持上次模式”，没有时限）。
/// 只管唤醒快捷键：启动、Dock、⌘Tab、Finder 再次打开、从最小化恢复都照旧。
enum WakeWindowMode: String, CaseIterable {
    case keepLast, alwaysQuick

    func title(in language: AppLanguage? = nil) -> String {
        switch self {
        case .keepLast: L10n.string("settings.wakeMode.keepLast", in: language)
        case .alwaysQuick: L10n.string("settings.wakeMode.alwaysQuick", in: language)
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    /// 早期版本在 hotKey 里保存下拉框的序号，没有 hotKeyCode 时沿用，见 HotKeyCombo.saved。
    @Published var hotKey: HotKeyCombo {
        didSet {
            defaults.set(Int(hotKey.keyCode), forKey: "hotKeyCode")
            defaults.set(Int(hotKey.carbonModifiers), forKey: "hotKeyModifiers")
        }
    }
    /// 小窗和完整窗口切换。只在本应用窗口在前台时有效。
    @Published var modeKey: HotKeyCombo {
        didSet {
            defaults.set(Int(modeKey.keyCode), forKey: "modeKeyCode")
            defaults.set(Int(modeKey.carbonModifiers), forKey: "modeKeyModifiers")
        }
    }
    @Published var rateLevel: SpeechRateLevel {
        didSet { defaults.set(rateLevel.rawValue, forKey: "rateLevel") }
    }
    /// 可选网页增强总开关：输入框聚焦和 Esc 隐藏窗口。
    @Published var webEnhancements: Bool {
        didSet { defaults.set(webEnhancements, forKey: "webEnhancements") }
    }
    /// 唤醒后聚焦官方输入框
    @Published var focusInputOnShow: Bool {
        didSet { defaults.set(focusInputOnShow, forKey: "focusInputOnShow") }
    }
    /// 普通聊天状态下 Esc 隐藏窗口
    @Published var escapeHidesWindow: Bool {
        didSet { defaults.set(escapeHidesWindow, forKey: "escapeHidesWindow") }
    }
    @Published var restoreLastConversation: Bool {
        didSet { defaults.set(restoreLastConversation, forKey: "restoreLastConversation") }
    }

    /// 是否允许其他应用读取网页内容。默认拦截：放行后官方弹层开关时页面会卡十几秒（见 CompanionWebView）。
    @Published var allowPageAccessibility: Bool {
        didSet { defaults.set(allowPageAccessibility, forKey: "allowPageAccessibility") }
    }

    /// 页面缩放。Quick 和 Full 共用，退出后保留。
    @Published var pageZoom: Double {
        didSet { defaults.set(pageZoom, forKey: "pageZoom") }
    }

    /// 改了不动当前窗口，下次按唤醒快捷键时才用。
    @Published var wakeWindowMode: WakeWindowMode {
        didSet { defaults.set(wakeWindowMode.rawValue, forKey: "wakeWindowMode") }
    }

    /// 仅保存对话路径（不含 query），用于重启后恢复。
    var lastConversationURL: URL? {
        get { defaults.string(forKey: "lastConversationURL").flatMap(URL.init(string:)) }
        set { defaults.set(newValue?.absoluteString, forKey: "lastConversationURL") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "rateLevel": SpeechRateLevel.normal.rawValue,
            "webEnhancements": true,
            "focusInputOnShow": true,
            "escapeHidesWindow": true,
            "restoreLastConversation": true,
            "allowPageAccessibility": false,
            "pageZoom": PageZoom.actualSize,
            // 老用户没有这个键，也得到“保持上次模式”；不写入，其他设置不受影响。
            "wakeWindowMode": WakeWindowMode.keepLast.rawValue,
        ])
        hotKey = HotKeyCombo.saved(keyCode: defaults.object(forKey: "hotKeyCode") as? Int,
                                   modifiers: defaults.object(forKey: "hotKeyModifiers") as? Int,
                                   legacyPreset: defaults.integer(forKey: "hotKey"))
        if let code = defaults.object(forKey: "modeKeyCode") as? Int, let modifiers = defaults.object(forKey: "modeKeyModifiers") as? Int {
            modeKey = HotKeyCombo.stored(keyCode: code, modifiers: modifiers) ?? .modeStandard
        } else {
            modeKey = .modeStandard
        }
        rateLevel = SpeechRateLevel(rawValue: defaults.integer(forKey: "rateLevel")) ?? .normal
        webEnhancements = defaults.bool(forKey: "webEnhancements")
        focusInputOnShow = defaults.bool(forKey: "focusInputOnShow")
        escapeHidesWindow = defaults.bool(forKey: "escapeHidesWindow")
        restoreLastConversation = defaults.bool(forKey: "restoreLastConversation")
        allowPageAccessibility = defaults.bool(forKey: "allowPageAccessibility")
        pageZoom = PageZoom.nearestLevel(to: defaults.double(forKey: "pageZoom"))
        wakeWindowMode = defaults.string(forKey: "wakeWindowMode").flatMap(WakeWindowMode.init(rawValue:)) ?? .keepLast
    }
}
