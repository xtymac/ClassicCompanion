import AppKit
import SwiftUI

/// 窗口里的提示（3.11，样子用户 11-20 定）：两种，共用一个小提示框（TabHintView），属于窗口、不属于哪个标签页。
/// - 到上限（limit）：“最多打开 N 个标签页”（N 是 TabList 的上限）。⌘T、⇧⌘T 和菜单到上限时都是它。不出声、不抢焦点，
///   点不着（点按落到下面的网页上），大约 3 秒后自己收起；还显示着时又到上限：重新计时，不叠第二个。
/// - 第一次有多个标签页（severalTabs）：⌘W 关闭标签页（未发送的草稿可能丢失）、⇧⌘T 只能重新打开已保存的聊天、
///   左上角的 × 隐藏整个窗口。不自己收起，右边有关闭按钮。每次安装只显示一次：真正显示过才记下（规则见 TabHintPresenter）。
enum TabHint: Hashable {
    case limit(capacity: Int)
    case severalTabs

    /// 有关闭按钮（要收得到点按）。到上限的提示没有，自己收起。
    var closable: Bool { self == .severalTabs }

    /// 提示的文字，language 不给时用现在的界面语言。
    func text(in language: AppLanguage? = nil) -> String {
        switch self {
        case .limit(let capacity): L10n.plural("tabs.limit", in: language, capacity)
        case .severalTabs: L10n.string("tabs.tip.severalTabs", in: language)
        }
    }

    /// 写日志用的名字（不写提示的文字）。
    var logName: String {
        switch self {
        case .limit(let capacity): "到上限（\(capacity) 个）"
        case .severalTabs: "第一次有多个标签页"
        }
    }
}

/// “第一次有多个标签页”的提示显示过没有（每次安装一次）。正式运行是 AppSettings（存在 UserDefaults，键 tabs.severalTabsTipShown）。
@MainActor
protocol TabTipRecord: AnyObject {
    var severalTabsTipShown: Bool { get set }
}

/// 只记在内存里：ChatTabs 没交进来正式的记录时用（测试），不写 UserDefaults。
@MainActor
final class MemoryTabTipRecord: TabTipRecord {
    var severalTabsTipShown: Bool

    init(shown: Bool = false) {
        severalTabsTipShown = shown
    }
}

/// 提示框：圆角的半透明材质（和窗口里的按钮一样跟着浅深色走），callout 字号，能关的右边有一个小的关闭按钮。
/// 没有提示时什么都不画（宿主视图同时藏起来）。文字跟着界面语言变（观察 LanguageController）。
struct TabHintView: View {
    let hint: TabHint?
    let onClose: () -> Void
    @ObservedObject private var languages = LanguageController.shared

    /// 能关的提示的宽度（文字折行）。最窄的窗口（480 点）里左右各留 12 点也放得下。
    static let tipWidth: CGFloat = 340
    static let cornerRadius: CGFloat = 12

    var body: some View {
        if let hint {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(hint.text())
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: hint.closable ? .infinity : nil, alignment: .leading)
                if hint.closable {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    // 不用键盘焦点：点它不把焦点从网页的输入框拿走。
                    .focusable(false)
                    .help(L10n.string("tabs.hint.close"))
                    .accessibilityLabel(L10n.string("tabs.hint.close"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: hint.closable ? Self.tipWidth : nil)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .accessibilityElement(children: .contain)
        }
    }
}

/// 放提示框的视图。不当第一响应者（显示提示不改键盘焦点）；到上限的提示点不着（hitTest 返回 nil，点按落到下面的网页上），
/// 能关的提示收得到点按（关闭按钮要用）。
final class TabHintHost: NSHostingView<TabHintView> {
    /// 收不收点按：只有显示着能关的提示时收。
    var takesClicks = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard takesClicks, !isHidden else { return nil }
        return super.hitTest(point)
    }

    override var acceptsFirstResponder: Bool { false }
}

/// 窗口里的提示由谁显示、什么时候收起、什么时候算“显示过”（ChatWindowController 持有一个，hints）。
/// 一次只有一个提示：显示新的就换掉旧的（不叠）；同一个还显示着时再显示：到上限的重新计时，能关的不变。
///
/// 位置：网页区域（顶部一条下面）的上方正中，离上沿 10 点，左右至少留 12 点。在网页、新标签页的遮挡和启动画面、
/// “无法连接”提示、补排版的遮挡之上（加在窗口内容的最上层），所以第一次加载的遮挡盖着时也看得到；不在下方，不挡输入框。
/// 大小只按提示框自己的大小，不撑窗口（压缩的优先级低于拖窗口）。跟着网页区域，切模式、拖大小时一起动。
///
/// 计时（schedule 排的，到点时看代号，旧的不做）：
/// - 到上限的提示 3 秒（limitDuration）后收起；还显示着时又到上限，从那一刻重新算 3 秒。窗口隐藏、最小化时马上收起
///   （再显示窗口时不再出现：它说的是刚才那一下按键）。
/// - 能关的提示一直留着，直到点关闭按钮或被别的提示换掉；窗口隐藏、切换标签页、关闭标签页、切模式都不收起。
///
/// “显示过”（只对交进来 onDisplayed 的提示，即第一次有多个标签页的提示）：提示放上去以后，窗口在屏幕上
/// （windowShowsContent：可见、没有最小化、没有被完全挡住）连续 0.5 秒（displayDwell）没有变化，并且这时提示还是它，
/// 才调用 onDisplayed 一次（ChatTabs 记下）；或者用户在窗口在屏幕上时点了它的关闭按钮。
/// 窗口隐藏、最小化、被挡住或露出来（遮挡状态变了）、显示时都从那一刻重新等 0.5 秒；到点时窗口不在屏幕上就不记，
/// 等窗口下一次显示、露出来再等。还没记下就被收起、被别的提示换掉：不记（onDisplayed 丢掉），下次打开标签页时再显示。
/// 只看窗口和提示框是不是放在屏幕上，不能确定用户真的看到了。
@MainActor
final class TabHintPresenter {
    static let limitDuration: TimeInterval = 3
    static let displayDwell: TimeInterval = 0.5

    let host: TabHintHost
    /// 显示着的提示，没有是 nil（测试和诊断用）。
    private(set) var current: TabHint?
    /// 过一会儿做一件事。就是主队列的 asyncAfter；只有测试换它（测试自己决定什么时候到点）。
    var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }
    /// 窗口这一刻在屏幕上：可见、没有最小化、没有被完全挡住（occlusionState）。只有测试换它：测试的窗口从不显示。
    var windowShowsContent: @MainActor () -> Bool
    /// 给读屏播报提示的文字。默认什么都不做；AppDelegate 接上 NSAccessibility 的播报（测试里不出声）。
    var announce: @MainActor (String) -> Void = { _ in }
    private let log: @MainActor (String) -> Void
    /// 换上一个提示、重新计时、收起时加一：排着的“到时收起”只在代号没变时做。
    private var showing = 0
    /// 开始等“显示过”、窗口隐藏或可能变化、收起时加一：排着的“显示过”只在代号没变时算。
    private var dwelling = 0
    /// 显示着的提示真正显示过时调用（调用一次就丢掉）。
    private var onDisplayed: (@MainActor () -> Void)?

    init(windowShowsContent: @escaping @MainActor () -> Bool, log: @escaping @MainActor (String) -> Void) {
        self.windowShowsContent = windowShowsContent
        self.log = log
        host = TabHintHost(rootView: TabHintView(hint: nil, onClose: {}))
        host.isHidden = true
        host.translatesAutoresizingMaskIntoConstraints = false
        // 大小只按提示框自己的大小；不让它的最小、最大尺寸变成约束去撑窗口。
        host.sizingOptions = [.intrinsicContentSize]
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        host.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    /// 显示提示 hint（见类的说明）。onDisplayed：它真正显示过时调用一次。
    func show(_ hint: TabHint, onDisplayed: (@MainActor () -> Void)? = nil) {
        if hint == current {
            if case .limit = hint {
                showing += 1
                scheduleExpiry()
                log("\(hint.logName)的提示还显示着，重新计时")
            }
            return
        }
        if let current { log("收起 \(current.logName)的提示：换成别的提示") }
        showing += 1
        current = hint
        self.onDisplayed = onDisplayed
        host.takesClicks = hint.closable
        host.rootView = TabHintView(hint: hint, onClose: { [weak self] in self?.closeByHand() })
        host.isHidden = false
        log("显示 \(hint.logName)的提示")
        announce(hint.text())
        if case .limit = hint { scheduleExpiry() }
        startDwell()
    }

    /// 用户点了能关的提示的关闭按钮。窗口这时在屏幕上就算显示过。
    func closeByHand() {
        guard let hint = current, hint.closable else { return }
        if onDisplayed != nil, windowShowsContent() { recordDisplayed() }
        dismiss("手动关闭")
    }

    /// 窗口隐藏或最小化了：等着的“显示过”作废；到上限的提示马上收起。
    func windowHidden() {
        dwelling += 1
        if case .limit = current { dismiss("窗口隐藏") }
    }

    /// 窗口显示了、从 Dock 还原了、遮挡状态变了：还没记下显示过的提示从这一刻重新等。
    func windowMayBeOnScreen() {
        guard current != nil, onDisplayed != nil else { return }
        startDwell()
    }

    private func scheduleExpiry() {
        let token = showing
        schedule(Self.limitDuration) { [weak self] in
            guard let self, self.showing == token else { return }
            self.dismiss("到时")
        }
    }

    private func startDwell() {
        dwelling += 1
        guard onDisplayed != nil else { return }
        let token = dwelling
        schedule(Self.displayDwell) { [weak self] in
            guard let self, self.dwelling == token, self.windowShowsContent() else { return }
            self.recordDisplayed()
        }
    }

    private func recordDisplayed() {
        guard let onDisplayed, let hint = current else { return }
        self.onDisplayed = nil
        log("\(hint.logName)的提示显示过，记下")
        onDisplayed()
    }

    private func dismiss(_ reason: String) {
        guard let hint = current else { return }
        showing += 1
        dwelling += 1
        current = nil
        onDisplayed = nil
        host.takesClicks = false
        host.isHidden = true
        host.rootView = TabHintView(hint: nil, onClose: {})
        log("收起 \(hint.logName)的提示：\(reason)")
    }
}
