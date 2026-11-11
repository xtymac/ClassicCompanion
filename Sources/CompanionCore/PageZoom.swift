/// 页面缩放档位。缩放的是整个网页，文字和界面一起变大，不改网页结构。
public enum PageZoom {
    public static let levels: [Double] = [0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    public static let actualSize = 1.0

    public static func nearestLevel(to value: Double) -> Double {
        levels.min { abs($0 - value) < abs($1 - value) } ?? actualSize
    }

    public static func zoomedIn(from value: Double) -> Double {
        levels.first { $0 > nearestLevel(to: value) } ?? levels[levels.count - 1]
    }

    public static func zoomedOut(from value: Double) -> Double {
        levels.last { $0 < nearestLevel(to: value) } ?? levels[0]
    }
}
