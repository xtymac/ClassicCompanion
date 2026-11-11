import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 设置里录制唤醒键的过程。
@MainActor
final class HotKeyRecorderModel: ObservableObject {
    @Published private(set) var recording = false
    /// 提示都存成 LocalizedText，显示时才按当前语言生成：切换语言后，已经显示的提示也跟着换。
    @Published private(set) var message: LocalizedText?
    /// 录制时框里显示的内容：按住的修饰键，或刚按下但不合格的键。
    @Published private(set) var prompt = HotKeyRecorderModel.waitingPrompt
    /// 改成功了，但别的应用也会响应这个组合。不是错误，和 message 分开显示。
    @Published private(set) var notice: LocalizedText?

    static let waitingPrompt = LocalizedText("hotkey.prompt.waiting")
    static let grabbedHint = LocalizedText("hotkey.grabbedHint")

    /// 框里已经显示新组合，这里只说谁也会打开（用户嫌长）。
    static func conflictNotice(apps: [String]) -> LocalizedText {
        LocalizedText("hotkey.conflict", .list(apps))
    }

    /// 按下后等这么久再看有没有别的应用开了新窗口。
    private static let windowCheckDelay: TimeInterval = 0.8
    /// 焦点先丢时，等系统登记的按键这么久。
    private static let grabWait: TimeInterval = 0.4

    /// 换成这个组合，返回要显示的错误。
    private let apply: (HotKeyCombo) -> LocalizedText?
    private let defaultCombo: HotKeyCombo
    /// 另一行正在用的组合和用途，录制时不能选。
    private let taken: () -> [HotKeyCombo: LocalizedText]
    /// 开始录制前调用，用来结束另一行的录制。
    private var willBegin: (() -> Void)?
    /// 录制时暂停旧键：不然按到旧键会隐藏窗口，这个键也到不了录制框。
    private let onPause: () -> Void
    private let onResume: () -> Void
    private let log: (String) -> Void
    private var monitor: Any?
    /// 按住的修饰键。窗口失去焦点后收不到松开，留下的值就是那一刻按着的键。
    private var held = ""

    /// 临时登记按着的修饰键加每个键，nil 表示撤掉。为空时不做（切换键只在本应用里有效，别的应用拿走的组合用不了）。
    private let grab: ((UInt32?) -> Void)?
    /// 别的应用在屏幕上的窗口：窗口编号 → 应用名。用来判断按下后有没有别的应用也响应了。
    private let otherAppWindows: () -> [Int: String]
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var armed: UInt32?
    /// 开始按住修饰键时已经开着的窗口，之后新出现的才算响应了这个组合。
    private var windowsBefore: Set<Int>?
    /// 焦点丢了但还在等系统登记的按键。
    private var pendingLoss = false
    /// 每次开始录制加一，过期的等待不碰新的录制。
    private var session = 0

    init(defaultCombo: HotKeyCombo = .standard, taken: @escaping () -> [HotKeyCombo: LocalizedText] = { [:] },
         apply: @escaping (HotKeyCombo) -> LocalizedText?, onPause: @escaping () -> Void, onResume: @escaping () -> Void,
         log: @escaping (String) -> Void = { _ in },
         grab: ((UInt32?) -> Void)? = nil,
         otherAppWindows: @escaping () -> [Int: String] = { [:] },
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, job in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { job() } }
         }) {
        self.grab = grab
        self.otherAppWindows = otherAppWindows
        self.schedule = schedule
        self.defaultCombo = defaultCombo
        self.taken = taken
        self.apply = apply
        self.onPause = onPause
        self.onResume = onResume
        self.log = log
    }

    /// 两行不能同时录制，否则两个按键监听会抢同一个键。
    static func makeExclusive(_ a: HotKeyRecorderModel, _ b: HotKeyRecorderModel) {
        a.willBegin = { [weak b] in b?.cancel("开始录制另一项") }
        b.willBegin = { [weak a] in a?.cancel("开始录制另一项") }
    }

    func begin() {
        guard !recording else { return }
        willBegin?()
        recording = true
        message = nil
        notice = nil
        prompt = Self.waitingPrompt
        held = ""
        pendingLoss = false
        windowsBefore = nil
        session += 1
        log("录制开始")
        onPause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let keyCode = UInt32(event.keyCode), flags = event.modifierFlags
            if event.type == .flagsChanged {
                MainActor.assumeIsolated { self?.flagsChanged(flags) }
                return event
            }
            guard !event.isARepeat else { return nil }
            MainActor.assumeIsolated {
                self?.handle(keyCode: keyCode, flags: flags, keyName: HotKeyCombo.keyName(for: keyCode))
            }
            return nil
        }
    }

    /// 只按修饰键不产生 keyDown，要单独看，不然按住时框里没有任何反应。
    func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        guard recording else { return }
        let carbon = HotKeyCombo.carbonModifiers(from: flags)
        held = HotKeyCombo.symbols(carbon)
        prompt = held.isEmpty ? Self.waitingPrompt : .verbatim("\(held)…")
        if !held.isEmpty { log("录制修饰键：\(held)") }
        guard let grab else { return }
        let usable = carbon & UInt32(cmdKey | optionKey | controlKey) != 0 ? carbon : nil
        guard usable != armed else { return }
        if armed == nil { windowsBefore = Set(otherAppWindows().keys) }
        armed = usable
        grab(usable)
    }

    /// 临时登记的组合被按下：按键被系统拦下，到不了窗口，从这里收到。
    func grabbed(_ combo: HotKeyCombo) {
        guard recording else { return }
        handle(keyCode: combo.keyCode, flags: combo.modifierFlags, keyName: HotKeyCombo.keyName(for: combo.keyCode), viaGrab: true)
    }

    func handle(keyCode: UInt32, flags: NSEvent.ModifierFlags, keyName: String) {
        handle(keyCode: keyCode, flags: flags, keyName: keyName, viaGrab: false)
    }

    private func handle(keyCode: UInt32, flags: NSEvent.ModifierFlags, keyName: String, viaGrab: Bool) {
        guard recording else { return }
        switch HotKeyCapture.evaluate(keyCode: keyCode, flags: flags, keyName: keyName, taken: taken()) {
        case .cancel:
            cancel("Esc")
        case .reject(let reason):
            let pressed = HotKeyCombo.symbols(HotKeyCombo.carbonModifiers(from: flags)) + keyName
            prompt = .verbatim(pressed)
            log("录制拒绝：\(pressed)")
            message = reason
        case .accept(let combo):
            log(viaGrab ? "录制收到（系统登记）：\(combo.label)" : "录制收到：\(combo.label)")
            let before = windowsBefore
            finish()
            message = apply(combo)
            guard viaGrab, message == nil, let before else { return }
            // 按键被系统登记拦下时，别的应用登记了同一组合也会收到。看它有没有开新窗口。
            let token = session
            schedule(Self.windowCheckDelay) { [weak self] in
                guard let self, self.session == token else { return }
                self.checkForNewWindows(since: before)
            }
        }
    }

    private func checkForNewWindows(since before: Set<Int>) {
        var apps: [String] = []
        for (window, app) in otherAppWindows().sorted(by: { $0.key < $1.key })
        where !before.contains(window) && !apps.contains(app) {
            apps.append(app)
        }
        guard !apps.isEmpty else { log("录制后没有新窗口"); return }
        log("录制后新出现窗口：\(apps.joined(separator: "、"))")
        notice = Self.conflictNotice(apps: apps)
    }

    func cancel(_ reason: String = "取消") {
        guard recording else { return }
        log("录制取消：\(reason)")
        finish()
        message = nil
        onResume()
    }

    /// 录制中窗口失去焦点。按着修饰键时多半是别的应用也响应了这个组合、弹出了窗口：
    /// 系统登记的按键可能晚一点才到，先等一下；没有登记（切换键这一行）就只能结束录制。
    /// 失去焦点本身不说明是哪个应用（用户 22:05：⌥K 没有别的应用响应也会失去焦点）。
    func focusLost() {
        guard recording else { return }
        if armed != nil {
            guard !pendingLoss else { return }
            pendingLoss = true
            let token = session
            schedule(Self.grabWait) { [weak self] in
                guard let self, self.session == token, self.pendingLoss else { return }
                self.endAfterFocusLoss()
            }
            return
        }
        endAfterFocusLoss()
    }

    private func endAfterFocusLoss() {
        guard recording else { return }
        let wasHolding = held
        cancel(wasHolding.isEmpty ? "窗口失去焦点" : "窗口失去焦点（按着 \(wasHolding)）")
        if !wasHolding.isEmpty { message = Self.grabbedHint }
    }

    func reset() {
        finish()
        notice = nil
        message = apply(defaultCombo)
    }

    /// 设置窗口关闭时调用。
    func leave() {
        cancel("关闭设置")
        message = nil
        notice = nil
    }

    private func finish() {
        recording = false
        pendingLoss = false
        if armed != nil {
            armed = nil
            grab?(nil)
        }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// 设置里每一行快捷键下面的那行字。两行各说各的，同时设置时也分得清是哪一行。
struct HotKeyNote: Equatable {
    enum Tone { case normal, warning, error }
    let text: LocalizedText
    let tone: Tone

    static let recordingHint = LocalizedText("hotkey.note.recording")
    static let wakeIdle = LocalizedText("hotkey.note.wakeIdle")
    static let modeIdle = LocalizedText("hotkey.note.modeIdle")

    /// 优先级：这一行的错误 > 正在录制 > 注册失败 > 别的应用也会打开 > 平时的说明。
    static func make(message: LocalizedText?, notice: LocalizedText?, recording: Bool,
                     registrationError: LocalizedText?, idle: LocalizedText) -> HotKeyNote {
        if let message { return HotKeyNote(text: message, tone: .error) }
        if recording { return HotKeyNote(text: recordingHint, tone: .normal) }
        if let registrationError { return HotKeyNote(text: registrationError, tone: .error) }
        if let notice { return HotKeyNote(text: notice, tone: .warning) }
        return HotKeyNote(text: idle, tone: .normal)
    }
}

/// 屏幕上别的应用的窗口，用来判断录下的组合有没有让别的应用也弹出窗口。
/// 只用窗口编号、所属进程和大小（不需要录屏权限，也不读窗口标题和内容）。
enum OtherAppWindows {
    /// 比这小的多是菜单栏、指示条之类，不是应用弹出的窗口。
    private static let minimumSide: CGFloat = 40

    static func onScreen() -> [Int: String] {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var apps: [pid_t: NSRunningApplication] = [:]
        var result: [Int: String] = [:]
        for info in list {
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= minimumSide, frame.height >= minimumSide,
                  let app = apps[pid] ?? NSRunningApplication(processIdentifier: pid) else { continue }
            apps[pid] = app
            // 系统界面（程序坞、通知横幅等）不算。
            guard app.activationPolicy != .prohibited,
                  app.bundleIdentifier != "com.apple.notificationcenterui" else { continue }
            result[number] = app.localizedName ?? info[kCGWindowOwnerName as String] as? String ?? L10n.string("hotkey.otherApp")
        }
        return result
    }
}

/// 点一下开始录制，再点一下取消。
struct HotKeyField: View {
    @ObservedObject var model: HotKeyRecorderModel
    let combo: HotKeyCombo
    let name: String
    @ObservedObject private var languages = LanguageController.shared
    /// 用键盘导航（Tab）移到这个框上时的焦点。系统方角焦点环关掉了，自己画一圈圆角的。
    @FocusState private var focused: Bool

    var body: some View {
        Button {
            if model.recording { model.cancel("再次点击") } else { model.begin() }
        } label: {
            Text(model.recording ? model.prompt.string() : combo.label)
                .frame(minWidth: 124, minHeight: 22)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 框本身已经有录制状态的蓝边，系统焦点环是方角，叠在一起不好看。
        .focusEffectDisabled()
        .focused($focused)
        .foregroundStyle(model.recording ? Color.secondary : Color.primary)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(model.recording ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: model.recording ? 2 : 1)
        }
        .overlay {
            if focused && !model.recording {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                    .padding(-3)
            }
        }
        .accessibilityLabel(name)
        .accessibilityValue(model.recording ? L10n.string("hotkey.field.waiting") : combo.label)
    }
}
