import AppKit
import Combine

/// ChatGPT 页面的底色。顶部一条、按钮、启动画面和窗口底色跟着它变浅或变深，和 ChatGPT 自己的主题设置一致。
/// 颜色来自 WebKit 的 `underPageBackgroundColor`（页面背景，可观察），不用网页脚本。
/// 只改原生控件的外观，不改网页和窗口的外观：ChatGPT 选“系统”时，网页仍按 macOS 的浅深色显示。
@MainActor
final class PageAppearance: ObservableObject {
    /// nil：还不知道页面颜色（第一次启动），跟随系统。
    @Published private(set) var background: NSColor?
    private let defaults: UserDefaults
    private static let key = "pageBackgroundRGB"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let rgb = defaults.array(forKey: Self.key) as? [Double], rgb.count == 3 {
            background = NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        }
    }

    var isDark: Bool? { background.map(Self.isDark) }

    /// 原生控件用的外观；不知道页面颜色时为 nil，跟随系统。
    var nsAppearance: NSAppearance? {
        isDark.flatMap { NSAppearance(named: $0 ? .darkAqua : .aqua) }
    }

    /// 透明或取不到的颜色不算数（页面还没画出来）。记下来给下次启动的启动画面用。
    func update(_ color: NSColor?) {
        guard let rgb = color?.usingColorSpace(.sRGB), rgb.alphaComponent > 0.5 else { return }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init)
        if let old = background?.usingColorSpace(.sRGB),
           zip([old.redComponent, old.greenComponent, old.blueComponent].map(Double.init), components)
            .allSatisfy({ abs($0 - $1) < 0.002 }) { return }
        background = NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: 1)
        defaults.set(components, forKey: Self.key)
    }

    /// 相对亮度低于中灰算深色。ChatGPT 深色底 #212121 约 0.015，浅色底接近 1。
    nonisolated static func isDark(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        return luminance < 0.18
    }
}
