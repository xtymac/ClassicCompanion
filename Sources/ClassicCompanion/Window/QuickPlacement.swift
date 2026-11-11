import AppKit

/// 小窗在一块屏幕上最后的位置：窗口左上角相对屏幕左上角的偏移，屏幕排列变化后仍然有效。
struct QuickPlacement: Codable, Equatable {
    var left: CGFloat
    var top: CGFloat

    init(frame: NSRect, screenFrame: NSRect) {
        left = frame.minX - screenFrame.minX
        top = screenFrame.maxY - frame.maxY
    }

    /// 窗口已完全落在可用范围外时返回 nil，调用方改用默认位置；部分超出由 clampToVisibleScreen 拉回。
    func origin(size: NSSize, screenFrame: NSRect, visibleFrame: NSRect) -> NSPoint? {
        let rect = NSRect(x: screenFrame.minX + left, y: screenFrame.maxY - top - size.height,
                          width: size.width, height: size.height)
        return rect.intersects(visibleFrame) ? rect.origin : nil
    }
}

/// 每块屏幕各记一个位置（按显示器 UUID），跨重启保存。
struct QuickPlacementStore {
    private static let key = "quickWindowPlacements"
    let defaults: UserDefaults

    func placement(forScreen id: String) -> QuickPlacement? { all[id] }

    func save(_ placement: QuickPlacement, forScreen id: String) {
        var updated = all
        updated[id] = placement
        if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: Self.key) }
    }

    private var all: [String: QuickPlacement] {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: QuickPlacement].self, from: $0) } ?? [:]
    }
}

/// 完整窗口手动调整后的大小。比切到完整模式的宽度还窄时不记：下次切换不该得到这么小的窗口。
struct FullWindowSizeStore {
    private static let key = "fullWindowSize"
    let defaults: UserDefaults
    let minimumWidth: CGFloat

    var size: NSSize? {
        defaults.string(forKey: Self.key).map(NSSizeFromString).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
    }

    func remember(_ size: NSSize) {
        guard size.width >= minimumWidth else { return }
        defaults.set(NSStringFromSize(size), forKey: Self.key)
    }
}
