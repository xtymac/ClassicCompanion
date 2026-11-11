import AppKit
import Carbon.HIToolbox

/// 唤醒键。按物理键位保存，直接对应 RegisterEventHotKey 的参数，不随输入法变。
struct HotKeyCombo: Hashable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    static let standard = HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
    /// 小窗和完整窗口切换。只在本应用窗口在前台时有效，不注册为全局快捷键。
    static let modeStandard = HotKeyCombo(keyCode: UInt32(kVK_ANSI_F), carbonModifiers: UInt32(controlKey | cmdKey))

    var label: String { "\(Self.symbols(carbonModifiers)) \(Self.keyName(for: keyCode))" }

    /// 修饰键按系统菜单的顺序显示。
    static func symbols(_ carbonModifiers: UInt32) -> String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { carbonModifiers & UInt32($0.0) != 0 }
            .map(\.1)
            .joined()
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// 菜单项显示用。认不出的键返回 nil，菜单里就不显示组合。
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        let key: String
        if let special = Self.menuKeys[Int(keyCode)] {
            key = String(Character(UnicodeScalar(special)!))
        } else {
            let name = Self.keyName(for: keyCode)
            guard name.count == 1 else { return nil }
            key = name.lowercased()
        }
        return (key, modifierFlags)
    }

    private static let menuKeys: [Int: Int] = [
        kVK_Space: 0x20, kVK_Return: 0x0D, kVK_Tab: 0x09, kVK_Delete: 0x08, kVK_Escape: 0x1B,
        kVK_ForwardDelete: NSDeleteFunctionKey,
        kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
        kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
        kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey, kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
        kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey, kVK_F4: NSF4FunctionKey,
        kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey, kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey,
        kVK_F9: NSF9FunctionKey, kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
        kVK_F13: NSF13FunctionKey, kVK_F14: NSF14FunctionKey, kVK_F15: NSF15FunctionKey, kVK_F16: NSF16FunctionKey,
        kVK_F17: NSF17FunctionKey, kVK_F18: NSF18FunctionKey, kVK_F19: NSF19FunctionKey, kVK_F20: NSF20FunctionKey,
    ]

    /// 录制时按着这些修饰键，临时登记它们和下面每个键的组合。别的应用也在用的组合，按键到不了窗口，
    /// 但登记了就能收到（2026-11-07 实验）。Esc 留给取消，⌘Tab 是系统切换应用。
    static func grabCandidates(carbonModifiers: UInt32) -> [HotKeyCombo] {
        var codes = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I,
            kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
            kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
            kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
            kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_ANSI_Backslash,
            kVK_ANSI_Semicolon, kVK_ANSI_Quote, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Slash, kVK_ANSI_Grave,
            kVK_Space, kVK_Return, kVK_Delete, kVK_ForwardDelete,
            kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        if carbonModifiers & UInt32(cmdKey) == 0 { codes.append(kVK_Tab) }
        return codes.map { HotKeyCombo(keyCode: UInt32($0), carbonModifiers: carbonModifiers) }
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        return UInt32(modifiers)
    }

    /// 键名。字母和符号取自 ASCII 键盘布局，开着中文或日文输入法时也能显示。
    static func keyName(for keyCode: UInt32) -> String {
        if let name = namedKeys[Int(keyCode)] { return name }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return L10n.format("hotkey.keyNumber", String(keyCode))
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return L10n.format("hotkey.keyNumber", String(keyCode)) }
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return L10n.format("hotkey.keyNumber", String(keyCode)) }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_ANSI_KeypadEnter: "Enter", kVK_Tab: "Tab",
        kVK_Delete: "Delete", kVK_ForwardDelete: "Forward Delete", kVK_Escape: "Esc",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// 先试新组合，失败时把原来的键装回去。RegisterEventHotKey 只拒绝部分冲突：
    /// 别的应用用自己的方式监听同一组合时这里仍会成功（Gemini 的 ⌥Space 就是这样）。
    static func apply(_ new: HotKeyCombo, over old: HotKeyCombo,
                      register: (HotKeyCombo) -> OSStatus) -> (active: HotKeyCombo, error: LocalizedText?) {
        let status = register(new)
        guard status != noErr else { return (new, nil) }
        let restored = register(old) == noErr
        let problem = status == OSStatus(eventHotKeyExistsErr) ? "inUse" : "invalid"
        let error = LocalizedText("hotkey.apply.\(problem).\(restored ? "kept" : "lost")", .plain(new.label), .plain(old.label))
        return (old, error)
    }

    /// 保存的组合，不带 ⌘、⌥ 或 ⌃ 时不用。
    static func stored(keyCode: Int, modifiers: Int) -> HotKeyCombo? {
        let combo = HotKeyCombo(keyCode: UInt32(keyCode), carbonModifiers: UInt32(modifiers))
        return combo.carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0 ? combo : nil
    }

    /// 读取保存的唤醒键。没有保存过时沿用早期版本下拉框里的选择。
    static func saved(keyCode: Int?, modifiers: Int?, legacyPreset: Int) -> HotKeyCombo {
        if let keyCode, let modifiers {
            return stored(keyCode: keyCode, modifiers: modifiers) ?? .standard
        }
        switch legacyPreset {
        case 1: return HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey))
        case 2: return HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey | shiftKey))
        case 3: return HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | shiftKey))
        case 4: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(controlKey | optionKey))
        default: return .standard
        }
    }
}

/// 录制时按下一个键的结果。
enum HotKeyCapture: Equatable {
    case cancel
    case reject(LocalizedText)
    case accept(HotKeyCombo)

    static let needsModifier = LocalizedText("hotkey.reject.needsModifier")

    /// 应用自己在用、不能改的组合。全局快捷键会先于菜单拿到按键，这些功能就失效了。
    /// 两个可以改的键不在这里，由 taken 传入当前值。
    private static let reserved: [String: LocalizedText] = [
        "⌘W": LocalizedText("purpose.hideWindow"), "⌘Q": LocalizedText("purpose.quitApp"),
        "⌘M": LocalizedText("purpose.minimizeWindow"), "⌘H": LocalizedText("purpose.hideApp"),
        "⌥⌘H": LocalizedText("purpose.hideOthers"), "⌘N": LocalizedText("purpose.newChat"),
        "⌘K": LocalizedText("purpose.searchChats"), "⌘R": LocalizedText("purpose.reload"),
        "⇧⌘R": LocalizedText("purpose.restorePage"), "⌘,": LocalizedText("purpose.openSettings"),
        "⌥⌘D": LocalizedText("purpose.openDiagnostics"), "⇧⌘Z": LocalizedText("purpose.redo"),
        "⌘=": LocalizedText("purpose.zoomPage"), "⇧⌘=": LocalizedText("purpose.zoomPage"),
        "⌘-": LocalizedText("purpose.zoomPage"), "⌘0": LocalizedText("purpose.zoomPage"),
    ]

    /// - Parameter taken: 另一行正在用的组合和它的用途（purpose.* 键）。
    static func evaluate(keyCode: UInt32, flags: NSEvent.ModifierFlags, keyName: String,
                         taken: [HotKeyCombo: LocalizedText] = [:]) -> HotKeyCapture {
        let modifiers = flags.intersection([.command, .option, .control, .shift])
        if keyCode == UInt32(kVK_Escape), modifiers.isEmpty { return .cancel }
        guard !modifiers.isDisjoint(with: [.command, .option, .control]) else { return .reject(needsModifier) }
        let carbon = HotKeyCombo.carbonModifiers(from: modifiers)
        let combo = HotKeyCombo(keyCode: keyCode, carbonModifiers: carbon)
        if let purpose = taken[combo] { return .reject(LocalizedText("hotkey.reject.used", .plain(combo.label), .text(purpose))) }
        let name = HotKeyCombo.symbols(carbon) + keyName
        if let purpose = reserved[name] { return .reject(LocalizedText("hotkey.reject.used", .plain(name), .text(purpose))) }
        // 纯 ⌘ 加字母、数字、符号或方向键，几乎每个应用都在用，全局占用会让它们在所有应用里失效。
        if modifiers == .command, keyName.count == 1 { return .reject(LocalizedText("hotkey.reject.common", .plain(name))) }
        return .accept(combo)
    }
}
