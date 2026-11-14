import SwiftUI
import CompanionCore

/// 窗口顶部一条：左边隐藏窗口，右边新建对话和切换小窗 / 完整窗口（按钮布局参考用户给的图，2026-11-08）。
/// 底色和网页一样，看起来是同一块；按钮是圆形玻璃。查找会话（⌘K）和设置（⌘,）在菜单和快捷键里。
/// 决策 A：不显示播放状态，也不提供朗读控制；朗读只通过官方界面开始和停止。
struct WebBar: View {
    let onClose: () -> Void
    let onNewChat: () -> Void
    let onToggleMode: () -> Void
    /// 双击空白处，和系统标题栏一样（见 BarDoubleClick）。
    let onDoubleClick: () -> Void
    /// 空白处每次按下：第几下（系统给的 clickCount）、窗口有没有被拖动。写进日志，查双击没反应。
    var onBarPress: (_ clickCount: Int, _ moved: Bool) -> Void = { _, _ in }
    @ObservedObject var state: ToolbarState
    @ObservedObject var appearance: PageAppearance
    @ObservedObject private var languages = LanguageController.shared

    var body: some View {
        let hide = L10n.string("bar.hideWindow"), newChat = L10n.string("menu.newChat")
        let toggle = L10n.string(state.quick ? "bar.toFull" : "bar.toQuick")
        HStack(spacing: 10) {
            GlassCircleButton(symbol: "xmark", label: hide, help: L10n.format("format.withShortcut", hide, "⌘W"), action: onClose)
            Spacer(minLength: 0)
            GlassCircleButton(symbol: "square.and.pencil", label: newChat, help: L10n.format("format.withShortcut", newChat, "⌘N"),
                              action: onNewChat)
            GlassCircleButton(symbol: state.quick ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                              label: toggle, help: L10n.format("format.withShortcut", toggle, state.modeKeyLabel),
                              action: onToggleMode)
        }
        .padding(.horizontal, 12)
        .frame(height: WebBar.height)
        .frame(maxWidth: .infinity)
        // 空白处拖动、双击窗口：这一条占了原来标题栏的位置。
        .background {
            BarBackground(color: Color(nsColor: appearance.background ?? .windowBackgroundColor))
                .overlay(BarDragArea(onDoubleClick: onDoubleClick, onPress: onBarPress))
        }
    }

    static let height: CGFloat = 52
}

/// 顶部一条的底：上沿是半透明磨砂，透出窗口后面的桌面；往下渐变成页面底色，下沿和页面连成一块（用户 2026-11-08）。
/// 浅深色跟着这一条的外观（页面颜色）走。
private struct BarBackground: View {
    let color: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let frost = scheme == .dark ? BarFrost.dark : BarFrost.light
        ZStack {
            BehindWindowBlur()
            LinearGradient(stops: frost.frostStops.map { .init(color: frost.tint.color.opacity($0.opacity), location: $0.location) },
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: frost.page.map { .init(color: color.opacity($0.opacity), location: $0.location) },
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

/// 磨砂浓度。1329：透感不明显（`.titlebar` 材质，上沿叠 20% 页面底色）。1347：太透（`.fullScreenUI`，上沿什么都不叠）。
/// 用户要“加一些白色的磨砂”：上沿叠一层白色，往下淡掉。深色里白色多了像一条灰带，改为少量白色加一点页面底色。
/// 1407：用户说渐变不够自然。两层都改成同一条缓动曲线，两端斜率为 0，没有折点，落到下沿时看不出线。
/// 1606：用户说“Darkmode 下面透明区域应该是黑色底色”。深色的磨砂改成黑色：白 12% 看着是一层灰，比页面亮；
/// 黑 30% 仍偏灰，黑 70% 几乎不透，取黑 50%。
/// 浓度是在彩色条纹上并排截图挑的（2026-11-08）。
struct BarFrost {
    enum Tint: Equatable {
        case white, black
        var color: Color { self == .white ? .white : .black }
    }

    /// 磨砂的底色。
    let tint: Tint
    /// 上沿磨砂底色的不透明度，到下沿为 0。
    let frost: Double
    /// 上沿页面底色的不透明度，到下沿为 1。
    let pageTop: Double

    static let light = BarFrost(tint: .white, frost: 0.35, pageTop: 0)
    static let dark = BarFrost(tint: .black, frost: 0.5, pageTop: 0.25)

    /// 0（上沿）到 1（下沿）。smootherstep 两端斜率为 0；先取 t 的 1.4 次方，变化偏到下半段，上半部分保持透。
    nonisolated static func ease(_ t: Double) -> Double {
        let u = pow(min(max(t, 0), 1), 1.4)
        return u * u * u * (u * (u * 6 - 15) + 10)
    }

    private static let locations = (0...24).map { Double($0) / 24 }

    var page: [(opacity: Double, location: Double)] {
        Self.locations.map { (pageTop + (1 - pageTop) * Self.ease($0), $0) }
    }

    var frostStops: [(opacity: Double, location: Double)] {
        Self.locations.map { (frost * (1 - Self.ease($0)), $0) }
    }
}

/// 顶部空白处：按住拖动窗口，双击按系统设置处理。
/// 直接收 AppKit 的鼠标事件，是不是双击用系统给的 clickCount，和系统标题栏一样，第二下按下就生效。
/// 1329 用的 SwiftUI 拖动手势和双击手势会互相抢：两下之间手稍微一动，双击就不算了。
private struct BarDragArea: NSViewRepresentable {
    let onDoubleClick: () -> Void
    let onPress: (Int, Bool) -> Void

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.onDoubleClick = onDoubleClick
        view.onPress = onPress
    }

    final class DragView: NSView {
        var onDoubleClick: () -> Void = {}
        var onPress: (Int, Bool) -> Void = { _, _ in }

        override var mouseDownCanMoveWindow: Bool { false }
        // 窗口不在前面时，第一下也能拖，和标题栏一样。
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let before = window?.frame.origin
            switch event.clickCount {
            case 1: window?.performDrag(with: event)
            case 2: onDoubleClick()
            default: break
            }
            onPress(event.clickCount, window?.frame.origin != before)
        }
    }
}

/// 窗口后面的内容模糊后透出来。浅深色跟着这一条的外观（页面颜色）走。
/// `.fullScreenUI` 比 `.titlebar` 透：后面的颜色看得出来（2026-11-08 并排截图比较）。
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// 双击顶部空白处做什么：跟随“系统设置 → 桌面与程序坞 → 连按窗口标题栏”。
/// 缩放（默认）在小窗和完整窗口之间切换；最小化就最小化；“不执行任何操作”就不动。
enum BarDoubleClick: Equatable {
    case toggleMode, minimize, none

    static func action(systemSetting: String?) -> BarDoubleClick {
        switch systemSetting {
        case "Minimize": .minimize
        case "None": .none
        default: .toggleMode
        }
    }

    static var current: BarDoubleClick {
        action(systemSetting: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick"))
    }
}

/// 圆形玻璃按钮。macOS 26 起用系统的 Liquid Glass，之前的系统用半透明材质。
/// 玻璃上叠一层底色，鼠标移上去时更实、稍微放大（用户 1501：“可读性有点差”）。
struct GlassCircleButton: View {
    let symbol: String
    let label: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    /// 1442 是 32 点，用户说有点小（2026-11-08）。顶部一条 52 点高，上下各留 8 点。
    static let size: CGFloat = 36

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(GlassCircle(hovering: hovering))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// 按钮底色、边和悬停放大。浅色：白底，黑色图标；深色：浅灰底，白色图标。数值在彩色条纹上截图挑的。
struct GlassButtonLook: Equatable {
    /// 底色不透明度（浅色是白，深色是白叠在深色上）。
    let fill: Double
    /// 边线不透明度（浅色是黑，深色是白）。
    let stroke: Double
    let shadow: Double
    let scale: Double

    init(dark: Bool, hovering: Bool) {
        switch (dark, hovering) {
        case (false, false): (fill, stroke, shadow, scale) = (0.72, 0.10, 0.12, 1)
        case (false, true): (fill, stroke, shadow, scale) = (0.95, 0.18, 0.2, 1.06)
        case (true, false): (fill, stroke, shadow, scale) = (0.14, 0.14, 0.25, 1)
        case (true, true): (fill, stroke, shadow, scale) = (0.26, 0.24, 0.35, 1.06)
        }
    }
}

struct GlassCircle: ViewModifier {
    let hovering: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let look = GlassButtonLook(dark: dark, hovering: hovering)
        let filled = content
            .background(Circle().fill(Color.white.opacity(look.fill)))
            .overlay(Circle().strokeBorder((dark ? Color.white : Color.black).opacity(look.stroke), lineWidth: 0.5))
        Group {
            if #available(macOS 26, *) {
                filled.glassEffect(.regular.interactive(), in: .circle)
            } else {
                filled.background(.regularMaterial, in: Circle())
            }
        }
        .shadow(color: .black.opacity(look.shadow), radius: hovering ? 4 : 3, y: 1)
        .scaleEffect(look.scale)
    }
}

@MainActor
final class ToolbarState: ObservableObject {
    @Published var quick = true
    /// 小窗和完整窗口切换键，工具条提示用。
    @Published var modeKeyLabel = HotKeyCombo.modeStandard.label
}

/// 启动时网页加载完之前显示。底色用上次记下的页面颜色。图标跟随应用图标资源，换正式图标时不用改这里。
struct LaunchScreen: View {
    @ObservedObject var appearance: PageAppearance
    /// 启动画面结束后淡出的那层用：底色固定，不再跟着页面颜色变（文字和图标的外观由宿主视图固定）。
    var fixedBackground: NSColor?
    @ObservedObject private var languages = LanguageController.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Classic Companion").font(.title3.weight(.semibold))
            ProgressView().controlSize(.small).accessibilityLabel(L10n.string("launch.opening"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: fixedBackground ?? appearance.background ?? .textBackgroundColor))
    }
}

@MainActor
final class LoadProblemModel: ObservableObject {
    @Published var status: LoadRecovery.Status = .hidden
    var onReload: () -> Void = {}
}

/// 加载失败、窗口里没有页面时盖在网页上，代替一片空白（2026-11-11 开机白屏）。页面加载成功就收起。
struct LoadProblemView: View {
    @ObservedObject var model: LoadProblemModel
    @ObservedObject var appearance: PageAppearance
    /// 收起后淡出的那层用：底色固定，不再跟着页面颜色变（文字和图标的外观由宿主视图固定）。
    var fixedBackground: NSColor?
    @ObservedObject private var languages = LanguageController.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.string("load.problem.title")).font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if model.status == .connecting {
                ProgressView().controlSize(.small)
            } else {
                Button(L10n.string("menu.reload")) { model.onReload() }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: fixedBackground ?? appearance.background ?? .textBackgroundColor))
    }

    private var detail: String {
        switch model.status {
        case .connecting: L10n.string("load.problem.connecting")
        case .waiting: L10n.string("load.problem.waiting")
        case .stopped, .hidden: L10n.string("load.problem.stopped")
        }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var diagnostics: Diagnostics
    let build: String
    let onCollect: () -> Void
    let onExperiment: (ExperimentKind) -> Void
    @State private var rate = 1.5
    @ObservedObject private var languages = LanguageController.shared

    /// 窗口里的标签和按钮按界面语言；数值、页面类型、选择器这些机器字段原样显示。复制的报告保持原来的中文字段名。
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.string("diag.title")).font(.headline)
                Spacer()
                Button(L10n.string("diag.collect"), action: onCollect)
                    .help(L10n.string("diag.collect.help"))
                Button(L10n.string("diag.copyReport")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnostics.report(build: build), forType: .string)
                }
                .help(L10n.string("diag.copyReport.help"))
                Button(L10n.string("diag.resetGateC")) { diagnostics.resetCycleCounters() }
            }
            let c = diagnostics.capabilities
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row(L10n.string("diag.row.build"), build)
                row(L10n.string("diag.row.hotkey"), GlobalHotKey.statusText(diagnostics.hotKeyRegistration).string())
                row(L10n.string("diag.row.dataStore"),
                    L10n.string(diagnostics.dataStoreIsPersistent ? "diag.dataStore.persistent" : "diag.dataStore.ephemeral"))
                row(L10n.string("diag.row.page"), "\(c.pageKind) · \(c.location)")
                row(L10n.string("diag.row.input"), L10n.format("diag.input.value", String(c.inputFound), String(c.inputFocused)))
                row(L10n.string("diag.row.messages"),
                    L10n.format("diag.messages.value", L10n.plural("diag.messageCount", c.messageCount), c.assistantCount,
                                String(c.streaming), String(c.overlayOpen)))
                row(L10n.string("diag.row.selectors"), c.selectorHits)
                row(L10n.string("diag.row.gateC"),
                    L10n.format("diag.gateC.value", diagnostics.hotKeyCount, diagnostics.showCount, diagnostics.hideCount,
                                diagnostics.activateCount, diagnostics.modeSwitchCount, diagnostics.focusRestoreOK,
                                diagnostics.focusRestoreFailed))
                row(L10n.string("diag.row.frontApps"), diagnostics.appDistribution.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
                row(L10n.string("diag.row.inputFocus"), diagnostics.inputFocusResults.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)

            GroupBox(L10n.string("diag.readAloud")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.format("diag.readAloud.media", diagnostics.webMediaState))
                    Text(L10n.format("diag.readAloud.structure", shown(diagnostics.readAloudEvidence))).lineLimit(6)
                    Text(L10n.format("diag.readAloud.rate", shown(diagnostics.mediaMeasurement))).lineLimit(3)
                    Divider()
                    Text(L10n.string("diag.experiments.warning"))
                        .font(.caption).foregroundStyle(.orange)
                    HStack {
                        Button(L10n.string("diag.exp.measure")) { onExperiment(.measure) }
                        Button(L10n.string("diag.exp.suspend")) { onExperiment(.suspendAll) }
                        Button(L10n.string("diag.exp.resume")) { onExperiment(.resumeAll) }
                        Button(L10n.string("diag.exp.pauseAll")) { onExperiment(.pauseAll) }
                    }
                    HStack {
                        Picker("DOM playbackRate", selection: $rate) {
                            ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { Text(String(format: "%.2f", $0)).tag($0) }
                        }
                        .fixedSize()
                        Button(L10n.string("diag.exp.setRate")) { onExperiment(.setRate(rate)) }
                    }
                    ForEach(diagnostics.experiments.suffix(6), id: \.self) { Text($0).font(.caption2) }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollViewReader { proxy in
                List(diagnostics.entries) { e in
                    Text("\(e.date.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(languages.locale))) [\(e.category)] \(e.message)")
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .id(e.id)
                }
                .onChange(of: diagnostics.entries.count) {
                    if let last = diagnostics.entries.last { proxy.scrollTo(last.id) }
                }
            }
        }
        .padding(14)
        .environment(\.locale, languages.locale)
        .frame(minWidth: 720, minHeight: 680)
    }

    /// 还没采集、没测量时，报告里写的是固定的中文；窗口里按界面语言显示。
    private func shown(_ value: String) -> String {
        switch value {
        case Diagnostics.notCollected: L10n.string("diag.notCollected")
        case Diagnostics.notMeasured: L10n.string("diag.notMeasured")
        default: value
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v.isEmpty ? "-" : v).lineLimit(3)
        }
    }
}
