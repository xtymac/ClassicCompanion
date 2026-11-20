import AppKit
import CompanionCore

/// 一次按下（keyDown）里窗口的按键监视要看的事实：键码、不计修饰键的字符、修饰键、属于哪个窗口、是不是按住不放的重复。
/// 按键监视的闭包不在主线程隔离里，NSEvent 不能带进 MainActor.assumeIsolated，所以先取出这些，再交给
/// ChatWindowController.handleKeyDown(_:)。测试用 NSEvent.keyEvent(...) 造一个、取出来直接交过去。
/// 认 ⌘W、标签页的键（tabKey）、Esc、切换键都看这里，只有一套。
struct KeyPress {
    let keyCode: UInt16
    /// charactersIgnoringModifiers：保留 ⇧ 的效果（⇧⌘] 在美式键盘上是“}”）。
    let characters: String?
    let flags: NSEvent.ModifierFlags
    let windowNumber: Int
    let isRepeat: Bool

    /// 只用于按键事件（keyDown、keyUp）：别的事件取 charactersIgnoringModifiers、isARepeat 会抛异常。
    init(_ event: NSEvent) {
        keyCode = event.keyCode
        characters = event.charactersIgnoringModifiers
        flags = event.modifierFlags
        windowNumber = event.windowNumber
        isRepeat = event.isARepeat
    }

    /// 标签页的键（含 ⌘W），规则见 TabKeys.match(characters:keyCode:modifiers:)。不是时为 nil。
    var tabKey: TabKeys.Match? {
        TabKeys.match(characters: characters, keyCode: keyCode, modifiers: TabKeys.Modifiers(flags))
    }

    /// 不带修饰键的 Esc（大写锁定、fn 不算）。
    var isPlainEscape: Bool {
        keyCode == 53 && flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function]).isEmpty
    }

    /// 按键位和修饰键（⌃⌥⇧⌘）的组合，和录制唤醒键、切换键时一样：和用户设的键比用它。
    var combo: HotKeyCombo {
        HotKeyCombo(keyCode: UInt32(keyCode), carbonModifiers: HotKeyCombo.carbonModifiers(from: flags))
    }
}

extension TabKeys.Modifiers {
    /// 按键的修饰键：⌘⇧⌃⌥ 照搬，大写锁定不算，别的（fn、小键盘、帮助键）算作 other。
    /// 所以纯 ⌘W 认法和原来一样（去掉大写锁定以后正好是 ⌘）。
    init(_ flags: NSEvent.ModifierFlags) {
        let pressed = flags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        var modifiers: TabKeys.Modifiers = []
        if pressed.contains(.command) { modifiers.insert(.command) }
        if pressed.contains(.shift) { modifiers.insert(.shift) }
        if pressed.contains(.control) { modifiers.insert(.control) }
        if pressed.contains(.option) { modifiers.insert(.option) }
        if !pressed.subtracting([.command, .shift, .control, .option]).isEmpty { modifiers.insert(.other) }
        self = modifiers
    }
}
