import AppKit
import SwiftUI
import CompanionCore

/// 标签栏（阶段 4，最小的一版）：顶部一条下面的一行，多于一个标签页时显示（ChatWindowController.setTabBarVisible(_:)）。
/// 32 点高，页面底色，没有分隔线。标签一样宽（TabBarRules.tabWidth）；每个标签都是一块胶囊（像 Safari）：
/// 都有一圈细边，不选中的底很淡，鼠标在上面时深一点，选中的明显更深（TabBarView.capsuleLook）。
/// 标题 12 点、一行、放不下在末尾截断；没有标题时是本地化的“新聊天”（tabs.untitled）。
/// 每个标签右边的 × 一直占着位置，只用透明度显隐（鼠标在这个标签上或它是选中的时显示），所以标题不会跟着跳。
/// 鼠标在 × 上时它后面有一个圆底、× 变深（画在 × 那一块里面，不改排版）。
/// 末尾是 ＋，置灰（到上限等，TabBarRules.newTabButton(in:)）时明显变淡；能不能新增在点的那一刻由 ChatTabs 再看。
/// 只读模型（TabBarModel），点按交给模型上的回调（ChatTabs 接上），这里不做决定。
/// 中键点标签关掉它，在宿主视图里做（TabBarHost）。
/// 不做：悬停提示文字、拖动、右键菜单、换顺序。
/// 不拿键盘焦点：按钮都不可聚焦，宿主视图（TabBarHost）不当第一响应者，网页里的输入框一直留着焦点。
/// 标题是对话内容：这里只显示（读屏也读得到），不写日志。
struct TabBarView: View {
    @ObservedObject var model: TabBarModel
    @ObservedObject var appearance: PageAppearance
    @ObservedObject private var languages = LanguageController.shared
    /// 鼠标在哪个标签上。
    @State private var hovered: TabID?
    /// 鼠标在哪个标签的 × 上。
    @State private var closeHovered: TabID?
    /// 测试用：每个标签的标题那一块在标签栏里的位置（不开窗口量排版）。正式运行时是 nil。
    private let onTitleFrames: (@MainActor @Sendable ([TabID: CGRect]) -> Void)?

    static let height: CGFloat = 32
    /// 选中的标签的胶囊（也是每个标签可点的那一块）的高度。
    static let capsuleHeight: CGFloat = 26
    static let closeSize: CGFloat = 16
    private static let space = "tabBar"

    /// 胶囊的底色和细边（0.5 点）的不透明度。颜色是 primary：宿主视图的外观跟着页面，浅色页面是黑、深色是白。
    /// 细边都一样；底色：不选中 0.05，鼠标在上面 0.08，选中 0.12（鼠标在上面也不变）。
    static func capsuleLook(selected: Bool, hovered: Bool) -> (fill: Double, stroke: Double) {
        (selected ? 0.12 : hovered ? 0.08 : 0.05, 0.12)
    }

    /// 鼠标在 × 上时它后面那个圆底（closeSize 大小）的不透明度。
    static let closeHoverFill = 0.12

    /// hovered：一开始鼠标在哪个标签上，只给测试用（不开窗口没有鼠标）。
    init(model: TabBarModel, appearance: PageAppearance, hovered: TabID? = nil,
         onTitleFrames: (@MainActor @Sendable ([TabID: CGRect]) -> Void)? = nil) {
        self.model = model
        self.appearance = appearance
        _hovered = State(initialValue: hovered)
        self.onTitleFrames = onTitleFrames
    }

    var body: some View {
        GeometryReader { geometry in
            let width = TabBarRules.tabWidth(availableWidth: geometry.size.width, tabCount: model.items.count)
            HStack(spacing: TabBarRules.gap) {
                ForEach(model.items) { item in
                    tab(item, width: width)
                }
                newTabButton
            }
            .padding(.horizontal, TabBarRules.sideMargin)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .frame(height: Self.height)
        .background(Color(nsColor: appearance.background ?? .windowBackgroundColor))
        .coordinateSpace(.named(Self.space))
        .onPreferenceChange(TitleFrames.self) { [onTitleFrames] frames in
            guard let onTitleFrames else { return }
            MainActor.assumeIsolated { onTitleFrames(frames) }
        }
    }

    private func tab(_ item: TabBarModel.Item, width: CGFloat) -> some View {
        let showsClose = item.isSelected || hovered == item.id
        let closeHighlighted = showsClose && closeHovered == item.id
        let look = Self.capsuleLook(selected: item.isSelected, hovered: hovered == item.id)
        return HStack(spacing: 0) {
            Button { model.onSelect?(item.id) } label: {
                Text(item.title ?? L10n.string("tabs.untitled"))
                    .font(.system(size: 12))
                    .foregroundStyle(item.isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: TitleFrames.self,
                                               value: [item.id: geometry.frame(in: .named(Self.space))])
                    })
                    .padding(.leading, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityAddTraits(item.isSelected ? .isSelected : [])
            Button { model.onClose?(item.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(closeHighlighted ? .primary : .secondary)
                    .frame(width: Self.closeSize, height: Self.closeSize)
                    .background(Circle().fill(Color.primary.opacity(closeHighlighted ? Self.closeHoverFill : 0)))
                    .padding(.leading, 4)
                    .padding(.trailing, 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            // 位置一直留着，只改透明度；看不见时也点不着。
            .opacity(showsClose ? 1 : 0)
            .allowsHitTesting(showsClose)
            .onHover { inside in
                if inside {
                    closeHovered = item.id
                } else if closeHovered == item.id {
                    closeHovered = nil
                }
            }
            .accessibilityLabel(L10n.string("menu.closeTab"))
        }
        .frame(width: width, height: Self.capsuleHeight)
        .background(Capsule()
            .fill(Color.primary.opacity(look.fill))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(look.stroke), lineWidth: 0.5)))
        .onHover { inside in
            if inside {
                hovered = item.id
            } else if hovered == item.id {
                hovered = nil
            }
        }
    }

    private var newTabButton: some View {
        Button { model.onNewTab?() } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: TabBarRules.newTabButtonWidth, height: Self.capsuleHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(model.newTabButton.dimmed ? 0.3 : 1)
        .focusable(false)
        .accessibilityLabel(L10n.string("menu.newTab"))
    }
}

/// 每个标签的标题那一块在标签栏里的位置（测试量排版用）。
private struct TitleFrames: PreferenceKey {
    static let defaultValue: [TabID: CGRect] = [:]

    static func reduce(value: inout [TabID: CGRect], nextValue: () -> [TabID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 放标签栏的视图：不当第一响应者，点标签栏不把键盘焦点从网页拿走。
/// 中键（buttonNumber 2）点标签关掉它，像浏览器：在一个标签的胶囊里按下、在同一个标签里松开时，走和点 × 同一条路
/// （model.onClose，即 ChatTabs.closeTab(id:)，同样的规则和日志），不管选没选中，也不先选中它。松开时才关：按下后移开就不关，
/// 和浏览器一样。按下、拖动、松开都不交给 SwiftUI（标签上的按钮不会因为中键被点）。＋、空白处：什么都不做。
/// 别的键照常交给 SwiftUI。只有落在标签栏上的事件到这里：网页里的中键不经过这里；侧键（3、4）在窗口的事件监视里就被拿走了
/// （ChatWindowController.handleHistoryMouse，只管 3、4）。
final class TabBarHost: NSHostingView<TabBarView> {
    override var acceptsFirstResponder: Bool { false }

    /// 中键在哪个标签上按下的（还没松开）。
    private var middlePressed: TabID?

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        middlePressed = tab(at: convert(event.locationInWindow, from: nil))
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDragged(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let pressed = middlePressed
        middlePressed = nil
        guard let pressed, tab(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        rootView.model.onClose?(pressed)
    }

    /// 这一点（本视图的坐标）落在哪个标签的胶囊上：横向照 TabBarRules.tabIndex（和 TabBarView 的排版用同一套宽度），
    /// 纵向在居中的 capsuleHeight 那一条里。边距、间距、＋、上下空出来的地方是 nil。
    func tab(at point: NSPoint) -> TabID? {
        guard abs(point.y - bounds.midY) <= TabBarView.capsuleHeight / 2 else { return nil }
        let items = rootView.model.items
        guard let index = TabBarRules.tabIndex(atX: point.x, availableWidth: bounds.width, tabCount: items.count) else { return nil }
        return items[index].id
    }
}
