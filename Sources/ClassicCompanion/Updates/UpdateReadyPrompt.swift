import AppKit
import SwiftUI

/// 应用自己的更新确认，文字跟随应用的界面语言。检查、更新说明、下载进度、签名验证、替换和重新启动仍全部由 Sparkle 完成。
///
/// - authorize：在 Sparkle 新版本窗口里选“安装更新”之后、开始下载之前。Sparkle 2 下载完一开始验证、解压就启动安装器，
///   从那时起应用自己退出（包括崩溃、被强制退出）就会安装（SPUUserDriver.h 对 showReadyToInstallAndRelaunch 的说明；
///   2026-11-13 在隔离副本实测 SIGKILL、SIGABRT 都装上了）。所以“下载并安装”的授权放在下载之前：
///   授权之前没有安装器，退出、崩溃都不会安装；授权之后下载、验证完成就直接安装并重新启动，不再询问。
/// - install：安装器已经在等（Sparkle 的 installing 阶段，比如授权后安装时应用没能退出），确认后立即安装并重新启动。
enum UpdatePromptKind {
    case authorize
    case install

    /// 两种确认各自的文字键；窗口标题和“稍后”共用 update.ready.*。
    var keyPrefix: String {
        switch self {
        case .authorize: "update.authorize"
        case .install: "update.ready"
        }
    }
}

/// 确认窗口出现后的 1 秒内主按钮不可用：在 Sparkle 窗口里按回车或连按两下时，按住的回车（自动重复）
/// 或第二下不会直接落到“下载并安装”上。
@MainActor
final class UpdatePromptGate: ObservableObject {
    @Published private(set) var isOpen = true
    private var generation = 0

    func hold(for seconds: TimeInterval = 1) {
        generation += 1
        let mine = generation
        isOpen = false
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.isOpen = true
        }
    }
}

struct UpdateReadyView: View {
    let kind: UpdatePromptKind
    let version: String?
    @ObservedObject var gate: UpdatePromptGate
    let onInstall: () -> Void
    let onLater: () -> Void
    @ObservedObject private var languages = LanguageController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("\(kind.keyPrefix).title"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                    Text(L10n.string("\(kind.keyPrefix).reminder"))
                        .fontWeight(.semibold)
                    Text(L10n.string("\(kind.keyPrefix).laterNote"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Spacer()
                // Esc、⌘. 和关闭窗口都等于“稍后”。
                Button(L10n.string("update.ready.later"), action: onLater)
                    .keyboardShortcut(.cancelAction)
                // 回车只在这个窗口是键盘焦点时生效；窗口出现时不会从聊天窗口抢走焦点（UpdatePromptWindow.present）。
                Button(L10n.string("\(kind.keyPrefix).install"), action: onInstall)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!gate.isOpen)
            }
        }
        .padding(20)
        .frame(width: 480)
        .environment(\.locale, languages.locale)
    }

    private var message: String {
        if let version { return L10n.format("\(kind.keyPrefix).message", version) }
        return L10n.string("\(kind.keyPrefix).messageNoVersion")
    }
}

/// 确认窗口。不是模态：等用户处理完手头的回答、朗读或输入时，聊天窗口照常可用。
@MainActor
final class UpdatePromptWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let gate = UpdatePromptGate()
    private let onLater: () -> Void

    init(kind: UpdatePromptKind, version: String?, onInstall: @escaping () -> Void, onLater: @escaping () -> Void) {
        self.onLater = onLater
        let host = NSHostingController(rootView: UpdateReadyView(
            kind: kind, version: version, gate: gate, onInstall: onInstall, onLater: onLater))
        window = NSWindow(contentViewController: host)
        super.init()
        window.styleMask = [.titled, .closable]
        // 和聊天窗口一样出现在当前空间（包括全屏的聊天窗口旁边），不把用户带到别的桌面。
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.title = L10n.string("update.ready.windowTitle")
        window.delegate = self
        window.center()
    }

    var isVisible: Bool { window.isVisible }

    /// takeFocus 为 false 时只放到前面、不成为键盘焦点：用户正在聊天窗口里打字，回车不会误按主按钮。
    func present(takeFocus: Bool) {
        gate.hold()
        if takeFocus {
            ChatWindowController.forceActivate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func retitle() { window.title = L10n.string("update.ready.windowTitle") }

    /// 程序关闭（已经做了选择）。不触发“稍后”。
    func close() {
        window.delegate = nil
        window.close()
    }

    /// 用户点关闭按钮或按 ⌘W：等于“稍后”。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onLater()
        return false
    }
}
