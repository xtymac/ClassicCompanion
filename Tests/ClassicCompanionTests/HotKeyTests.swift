import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ClassicCompanion

/// 唤醒键录制的规则。真实按键和输入法状态要在真实应用里用物理键盘确认。
final class HotKeyTests: XCTestCase {
    private let controlOptionK = HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(controlKey | optionKey))

    private let wakeRowTaken: [HotKeyCombo: LocalizedText] = [.modeStandard: LocalizedText("purpose.toggleMode")]

    private func capture(_ keyCode: Int, _ flags: NSEvent.ModifierFlags, _ keyName: String) -> HotKeyCapture {
        HotKeyCapture.evaluate(keyCode: UInt32(keyCode), flags: flags, keyName: keyName, taken: wakeRowTaken)
    }

    /// 提示存的是键和参数，这里按简体中文生成后比较：中文的写法和以前一样。
    private func zh(_ text: LocalizedText?) -> String? { text?.string(in: .simplifiedChinese) }

    private func rejection(_ capture: HotKeyCapture) -> String? {
        if case .reject(let reason) = capture { return zh(reason) }
        return nil
    }

    // MARK: - 显示

    func testLabelUsesTheSystemModifierOrder() {
        XCTAssertEqual(HotKeyCombo.standard.label, "⌥ Space")
        XCTAssertEqual(HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | shiftKey)).label, "⇧⌘ Space")
        XCTAssertEqual(HotKeyCombo(keyCode: UInt32(kVK_F5), carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey)).label,
                       "⌃⌥⇧⌘ F5")
    }

    func testSpecialKeysHaveNames() {
        XCTAssertEqual(HotKeyCombo.keyName(for: UInt32(kVK_Space)), "Space")
        XCTAssertEqual(HotKeyCombo.keyName(for: UInt32(kVK_Return)), "Return")
        XCTAssertEqual(HotKeyCombo.keyName(for: UInt32(kVK_F12)), "F12")
        XCTAssertEqual(HotKeyCombo.keyName(for: UInt32(kVK_LeftArrow)), "←")
    }

    /// 键名不随输入法变：开着中文或日文输入法时也要显示字母。
    func testLetterKeysAreNamedFromAnAsciiLayout() {
        XCTAssertEqual(HotKeyCombo.keyName(for: UInt32(kVK_ANSI_K)), "K")
        XCTAssertEqual(controlOptionK.label, "⌃⌥ K")
    }

    // MARK: - 录制规则

    func testPlainEscapeCancels() {
        XCTAssertEqual(capture(kVK_Escape, [], "Esc"), .cancel)
        XCTAssertEqual(capture(kVK_Escape, .capsLock, "Esc"), .cancel)
    }

    func testAcceptsCombinationsWithARealModifier() {
        XCTAssertEqual(capture(kVK_ANSI_K, [.control, .option], "K"), .accept(controlOptionK))
        XCTAssertEqual(capture(kVK_Space, .option, "Space"), .accept(.standard))
        XCTAssertEqual(capture(kVK_F5, [.command, .shift], "F5"),
                       .accept(HotKeyCombo(keyCode: UInt32(kVK_F5), carbonModifiers: UInt32(cmdKey | shiftKey))))
    }

    func testCapsLockAndFnDoNotCount() {
        XCTAssertEqual(capture(kVK_ANSI_K, [.control, .option, .capsLock, .function], "K"), .accept(controlOptionK))
        XCTAssertEqual(capture(kVK_ANSI_K, [.capsLock, .function], "K"), .reject(HotKeyCapture.needsModifier))
    }

    func testKeysWithoutACommandOptionOrControlAreRejected() {
        XCTAssertEqual(capture(kVK_ANSI_K, [], "K"), .reject(HotKeyCapture.needsModifier))
        XCTAssertEqual(capture(kVK_ANSI_K, .shift, "K"), .reject(HotKeyCapture.needsModifier))
        XCTAssertEqual(capture(kVK_F5, [], "F5"), .reject(HotKeyCapture.needsModifier))
        XCTAssertEqual(capture(kVK_Space, [], "Space"), .reject(HotKeyCapture.needsModifier))
    }

    func testTheAppsOwnShortcutsAreRejectedWithTheirPurpose() {
        XCTAssertEqual(rejection(capture(kVK_ANSI_W, .command, "W")), "⌘W 用来隐藏窗口，请换一个。")
        XCTAssertEqual(rejection(capture(kVK_ANSI_F, [.control, .command], "F")), "⌃⌘ F 用来切换小窗和完整窗口，请换一个。")
        XCTAssertEqual(rejection(capture(kVK_ANSI_R, [.shift, .command], "R")), "⇧⌘R 用来恢复页面，请换一个。")
        XCTAssertEqual(rejection(capture(kVK_ANSI_D, [.option, .command], "D")), "⌥⌘D 用来打开诊断，请换一个。")
        XCTAssertEqual(rejection(capture(kVK_ANSI_Equal, .command, "=")), "⌘= 用来调整页面大小，请换一个。")
    }

    /// 全局快捷键会把这个组合从所有应用手里拿走。
    func testPlainCommandWithAPrintableKeyIsRejected() {
        XCTAssertEqual(rejection(capture(kVK_ANSI_C, .command, "C")), "⌘C 是常用的快捷键，请换一个。")
        XCTAssertEqual(rejection(capture(kVK_ANSI_S, .command, "S")), "⌘S 是常用的快捷键，请换一个。")
        XCTAssertEqual(rejection(capture(kVK_LeftArrow, .command, "←")), "⌘← 是常用的快捷键，请换一个。")
    }

    func testCommandWithANamedKeyIsAllowed() {
        XCTAssertEqual(capture(kVK_F5, .command, "F5"),
                       .accept(HotKeyCombo(keyCode: UInt32(kVK_F5), carbonModifiers: UInt32(cmdKey))))
    }

    // MARK: - 小窗 / 完整窗口切换键（第二行）

    func testModeDefaultIsControlCommandF() {
        XCTAssertEqual(HotKeyCombo.modeStandard.label, "⌃⌘ F")
    }

    /// 切换键改走之后，⌃⌘F 空出来，唤醒键可以用；新的切换键唤醒键不能用。
    func testTheWakeRowFollowsTheCurrentModeKey() {
        let controlOptionJ = HotKeyCombo(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(controlKey | optionKey))
        let taken: [HotKeyCombo: LocalizedText] = [controlOptionJ: LocalizedText("purpose.toggleMode")]
        XCTAssertEqual(rejection(HotKeyCapture.evaluate(keyCode: UInt32(kVK_ANSI_J), flags: [.control, .option], keyName: "J", taken: taken)),
                       "⌃⌥ J 用来切换小窗和完整窗口，请换一个。")
        XCTAssertEqual(HotKeyCapture.evaluate(keyCode: UInt32(kVK_ANSI_F), flags: [.control, .command], keyName: "F", taken: taken),
                       .accept(.modeStandard))
    }

    func testTheModeRowRejectsTheWakeKey() {
        let taken: [HotKeyCombo: LocalizedText] = [controlOptionK: LocalizedText("purpose.wake")]
        XCTAssertEqual(rejection(HotKeyCapture.evaluate(keyCode: UInt32(kVK_ANSI_K), flags: [.control, .option], keyName: "K", taken: taken)),
                       "⌃⌥ K 用来唤醒和隐藏窗口，请换一个。")
        XCTAssertEqual(HotKeyCapture.evaluate(keyCode: UInt32(kVK_ANSI_F), flags: [.control, .command], keyName: "F", taken: taken),
                       .accept(.modeStandard), "切换键可以设回自己的默认值")
    }

    /// 菜单里显示的组合跟着设置走。
    func testMenuKeyEquivalent() throws {
        let f = try XCTUnwrap(HotKeyCombo.modeStandard.menuKeyEquivalent)
        XCTAssertEqual(f.key, "f")
        XCTAssertEqual(f.modifiers, [.control, .command])
        XCTAssertEqual(HotKeyCombo.standard.menuKeyEquivalent?.key, " ")
        XCTAssertEqual(HotKeyCombo.standard.menuKeyEquivalent?.modifiers, .option)
        let f5 = HotKeyCombo(keyCode: UInt32(kVK_F5), carbonModifiers: UInt32(cmdKey | shiftKey))
        XCTAssertEqual(f5.menuKeyEquivalent?.key, String(Character(UnicodeScalar(NSF5FunctionKey)!)))
        XCTAssertEqual(f5.menuKeyEquivalent?.modifiers, [.shift, .command])
        XCTAssertEqual(HotKeyCombo(keyCode: UInt32(kVK_LeftArrow), carbonModifiers: UInt32(optionKey)).menuKeyEquivalent?.key,
                       String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        XCTAssertNil(HotKeyCombo(keyCode: 0x7F, carbonModifiers: UInt32(optionKey)).menuKeyEquivalent, "认不出的键不显示")
    }

    // MARK: - 换键失败时回到原来的键

    func testApplyKeepsTheNewCombinationWhenRegistrationSucceeds() {
        var tried: [HotKeyCombo] = []
        let result = HotKeyCombo.apply(controlOptionK, over: .standard) { tried.append($0); return noErr }
        XCTAssertEqual(result.active, controlOptionK)
        XCTAssertNil(result.error)
        XCTAssertEqual(tried, [controlOptionK])
    }

    func testApplyFallsBackToTheOldCombinationWhenTaken() {
        var tried: [HotKeyCombo] = []
        let result = HotKeyCombo.apply(controlOptionK, over: .standard) { combo in
            tried.append(combo)
            return combo == .standard ? noErr : OSStatus(eventHotKeyExistsErr)
        }
        XCTAssertEqual(result.active, .standard)
        XCTAssertEqual(zh(result.error), "⌃⌥ K 已被占用，仍在使用 ⌥ Space。")
        XCTAssertEqual(tried, [controlOptionK, .standard], "失败后必须把旧键装回去")
    }

    func testApplyReportsAnInvalidCombinationDifferently() {
        let result = HotKeyCombo.apply(controlOptionK, over: .standard) { $0 == .standard ? noErr : OSStatus(eventHotKeyInvalidErr) }
        XCTAssertEqual(zh(result.error), "⌃⌥ K 不能使用，仍在使用 ⌥ Space。")
    }

    func testApplySaysSoWhenTheOldCombinationCannotComeBack() {
        let result = HotKeyCombo.apply(controlOptionK, over: .standard) { _ in OSStatus(eventHotKeyExistsErr) }
        XCTAssertEqual(result.active, .standard)
        XCTAssertEqual(zh(result.error), "⌃⌥ K 已被占用，⌥ Space 也没有恢复，请重新设置。")
    }

    // MARK: - 保存

    private func freshDefaults() -> UserDefaults {
        let name = "hotkey-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor func testDefaultIsOptionSpace() {
        XCTAssertEqual(AppSettings(defaults: freshDefaults()).hotKey, .standard)
    }

    @MainActor func testChangedCombinationSurvivesARestart() {
        let defaults = freshDefaults()
        AppSettings(defaults: defaults).hotKey = controlOptionK
        XCTAssertEqual(AppSettings(defaults: defaults).hotKey, controlOptionK)
    }

    /// 之前在下拉框里选过的组合继续有效。
    @MainActor func testEarlierPresetChoicesCarryOver() {
        let expected: [(Int, HotKeyCombo)] = [
            (0, .standard),
            (1, HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey))),
            (2, HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey | shiftKey))),
            (3, HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | shiftKey))),
            (4, HotKeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(controlKey | optionKey))),
        ]
        for (preset, combo) in expected {
            let defaults = freshDefaults()
            defaults.set(preset, forKey: "hotKey")
            XCTAssertEqual(AppSettings(defaults: defaults).hotKey, combo, "预设 \(preset)")
        }
    }

    @MainActor func testModeKeyDefaultsToControlCommandF() {
        XCTAssertEqual(AppSettings(defaults: freshDefaults()).modeKey, .modeStandard)
    }

    @MainActor func testChangedModeKeySurvivesARestart() {
        let defaults = freshDefaults()
        AppSettings(defaults: defaults).modeKey = controlOptionK
        XCTAssertEqual(AppSettings(defaults: defaults).modeKey, controlOptionK)
        XCTAssertEqual(AppSettings(defaults: defaults).hotKey, .standard, "两行分开保存")
    }

    @MainActor func testUnusableSavedModeKeyFallsBackToTheDefault() {
        let defaults = freshDefaults()
        defaults.set(UInt32(kVK_ANSI_K), forKey: "modeKeyCode")
        defaults.set(UInt32(shiftKey), forKey: "modeKeyModifiers")
        XCTAssertEqual(AppSettings(defaults: defaults).modeKey, .modeStandard)
    }

    @MainActor func testUnusableSavedValueFallsBackToTheDefault() {
        let defaults = freshDefaults()
        defaults.set(UInt32(kVK_ANSI_K), forKey: "hotKeyCode")
        defaults.set(0, forKey: "hotKeyModifiers")
        XCTAssertEqual(AppSettings(defaults: defaults).hotKey, .standard)
    }

    // MARK: - 录制过程

    @MainActor private func makeRecorder(applyResult: LocalizedText? = nil, defaultCombo: HotKeyCombo = .standard,
                                         taken: [HotKeyCombo: LocalizedText] = [:]) -> (HotKeyRecorderModel, Log) {
        let log = Log()
        let model = HotKeyRecorderModel(defaultCombo: defaultCombo,
                                        taken: { taken },
                                        apply: { log.events.append("apply \($0.label)"); return applyResult },
                                        onPause: { log.events.append("pause") },
                                        onResume: { log.events.append("resume") },
                                        log: { log.lines.append($0) })
        return (model, log)
    }

    @MainActor private final class Log { var events: [String] = []; var lines: [String] = [] }

    @MainActor func testRecordingPausesTheOldKey() {
        let (model, log) = makeRecorder()
        model.begin()
        XCTAssertTrue(model.recording)
        XCTAssertEqual(log.events, ["pause"], "录制时按到旧键不能把窗口隐藏")
    }

    @MainActor func testEscapeCancelsAndResumesTheOldKey() {
        let (model, log) = makeRecorder()
        model.begin()
        model.handle(keyCode: UInt32(kVK_Escape), flags: [], keyName: "Esc")
        XCTAssertFalse(model.recording)
        XCTAssertNil(model.message)
        XCTAssertEqual(log.events, ["pause", "resume"])
    }

    @MainActor func testRejectedKeyKeepsRecordingAndExplainsWhy() {
        let (model, log) = makeRecorder()
        model.begin()
        model.handle(keyCode: UInt32(kVK_ANSI_K), flags: [], keyName: "K")
        XCTAssertTrue(model.recording)
        XCTAssertEqual(model.message, HotKeyCapture.needsModifier)
        XCTAssertEqual(log.events, ["pause"])
    }

    @MainActor func testAcceptedKeyStopsRecordingAndClearsTheMessage() {
        let (model, log) = makeRecorder()
        model.begin()
        model.handle(keyCode: UInt32(kVK_ANSI_K), flags: [], keyName: "K")
        model.handle(keyCode: UInt32(kVK_ANSI_K), flags: [.control, .option], keyName: "K")
        XCTAssertFalse(model.recording)
        XCTAssertNil(model.message)
        XCTAssertEqual(log.events, ["pause", "apply ⌃⌥ K"], "apply 自己装键，不再恢复旧键")
    }

    @MainActor func testFailedApplyShowsItsMessage() {
        let (model, _) = makeRecorder(applyResult: .verbatim("⌃⌥ K 已被占用，仍在使用 ⌥ Space。"))
        model.begin()
        model.handle(keyCode: UInt32(kVK_ANSI_K), flags: [.control, .option], keyName: "K")
        XCTAssertFalse(model.recording)
        XCTAssertEqual(zh(model.message), "⌃⌥ K 已被占用，仍在使用 ⌥ Space。")
    }

    /// 切到别的窗口时录制结束，旧键要回来；没在录制时什么也不做。
    @MainActor func testCancelOnlyActsWhileRecording() {
        let (model, log) = makeRecorder()
        model.cancel()
        XCTAssertEqual(log.events, [])
        model.begin()
        model.cancel()
        model.cancel()
        XCTAssertEqual(log.events, ["pause", "resume"])
    }

    /// 关掉设置再打开，不留着上次的错误。
    @MainActor func testLeavingClearsAStaleMessage() {
        let (model, _) = makeRecorder(applyResult: .verbatim("⌃⌥ K 已被占用，仍在使用 ⌥ Space。"))
        model.reset()
        XCTAssertNotNil(model.message)
        model.leave()
        XCTAssertNil(model.message)
    }

    // MARK: - 按键时的实时反馈（用户：“没有实时反应任何按键”）

    @MainActor func testPromptShowsHeldModifiersAsTheyArePressed() {
        let (model, _) = makeRecorder()
        model.begin()
        XCTAssertEqual(model.prompt, HotKeyRecorderModel.waitingPrompt)
        model.flagsChanged([.control])
        XCTAssertEqual(model.prompt, .verbatim("⌃…"))
        model.flagsChanged([.control, .option])
        XCTAssertEqual(model.prompt, .verbatim("⌃⌥…"))
        model.flagsChanged([])
        XCTAssertEqual(model.prompt, HotKeyRecorderModel.waitingPrompt)
    }

    @MainActor func testCapsLockAloneIsNotShown() {
        let (model, _) = makeRecorder()
        model.begin()
        model.flagsChanged([.capsLock, .function])
        XCTAssertEqual(model.prompt, HotKeyRecorderModel.waitingPrompt)
    }

    @MainActor func testPromptShowsARejectedKey() {
        let (model, _) = makeRecorder()
        model.begin()
        model.handle(keyCode: UInt32(kVK_ANSI_K), flags: [], keyName: "K")
        XCTAssertEqual(model.prompt, .verbatim("K"))
        model.handle(keyCode: UInt32(kVK_ANSI_K), flags: .shift, keyName: "K")
        XCTAssertEqual(model.prompt, .verbatim("⇧K"))
        model.handle(keyCode: UInt32(kVK_ANSI_W), flags: .command, keyName: "W")
        XCTAssertEqual(model.prompt, .verbatim("⌘W"))
    }

    @MainActor func testPromptStartsCleanEachTime() {
        let (model, _) = makeRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.cancel()
        model.begin()
        XCTAssertEqual(model.prompt, HotKeyRecorderModel.waitingPrompt)
    }

    @MainActor func testModifiersAreIgnoredWhenNotRecording() {
        let (model, _) = makeRecorder()
        model.flagsChanged([.option])
        XCTAssertEqual(model.prompt, HotKeyRecorderModel.waitingPrompt)
    }

    // MARK: - 诊断记录（物理按键的问题只能靠它查）

    @MainActor func testEveryStepIsLogged() {
        let (model, log) = makeRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.handle(keyCode: UInt32(kVK_ANSI_K), flags: [], keyName: "K")
        model.handle(keyCode: UInt32(kVK_ANSI_K), flags: [.control, .option], keyName: "K")
        model.begin()
        model.cancel("窗口失去焦点")
        XCTAssertEqual(log.lines, ["录制开始", "录制修饰键：⌥", "录制拒绝：K", "录制收到：⌃⌥ K", "录制开始", "录制取消：窗口失去焦点"])
    }

    // MARK: - 组合被其他应用拿走（用户 13:05 实测：按住 ⌥ 再按 Space，Space 没到，1 秒后窗口失去焦点）

    @MainActor func testLosingFocusWhileHoldingModifiersExplainsTheLikelyConflict() {
        let (model, log) = makeRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.focusLost()
        XCTAssertFalse(model.recording)
        XCTAssertEqual(model.message, HotKeyRecorderModel.grabbedHint)
        XCTAssertEqual(log.events, ["pause", "resume"], "旧键要回来")
        XCTAssertEqual(log.lines.last, "录制取消：窗口失去焦点（按着 ⌥）")
    }

    @MainActor func testLosingFocusWithoutModifiersCancelsQuietly() {
        let (model, _) = makeRecorder()
        model.begin()
        model.focusLost()
        XCTAssertFalse(model.recording)
        XCTAssertNil(model.message)
    }

    @MainActor func testReleasedModifiersDoNotCount() {
        let (model, _) = makeRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.flagsChanged([])
        model.focusLost()
        XCTAssertNil(model.message)
    }

    @MainActor func testFocusLostOutsideRecordingDoesNothing() {
        let (model, log) = makeRecorder()
        model.focusLost()
        XCTAssertNil(model.message)
        XCTAssertEqual(log.events, [])
    }

    @MainActor func testResetUsesTheRowsOwnDefault() {
        let (model, log) = makeRecorder(defaultCombo: .modeStandard)
        model.reset()
        XCTAssertEqual(log.events, ["apply ⌃⌘ F"])
    }

    @MainActor func testTheOtherRowsKeyIsRejectedWhileRecording() {
        let (model, log) = makeRecorder(taken: [controlOptionK: LocalizedText("purpose.wake")])
        model.begin()
        model.handle(keyCode: UInt32(kVK_ANSI_K), flags: [.control, .option], keyName: "K")
        XCTAssertTrue(model.recording)
        XCTAssertEqual(zh(model.message), "⌃⌥ K 用来唤醒和隐藏窗口，请换一个。")
        XCTAssertEqual(log.events, ["pause"])
    }

    /// 两行不能同时录制：开始一行时另一行结束，它暂停的旧键先回来再由新的一行暂停。
    @MainActor func testStartingOneRowEndsTheOther() {
        let (wake, wakeLog) = makeRecorder()
        let (mode, modeLog) = makeRecorder(defaultCombo: .modeStandard)
        HotKeyRecorderModel.makeExclusive(wake, mode)
        wake.begin()
        mode.begin()
        XCTAssertFalse(wake.recording)
        XCTAssertTrue(mode.recording)
        XCTAssertEqual(wakeLog.events, ["pause", "resume"])
        XCTAssertEqual(modeLog.events, ["pause"])
        XCTAssertEqual(wakeLog.lines.last, "录制取消：开始录制另一项")
        mode.cancel()
    }

    // MARK: - 录到别的应用也在用的组合（21:47 实验：登记了就能收到，按键到不了窗口）

    func testGrabCandidatesCoverCommonKeys() {
        let option = UInt32(optionKey)
        let codes = Set(HotKeyCombo.grabCandidates(carbonModifiers: option).map(\.keyCode))
        for key in [kVK_Space, kVK_ANSI_K, kVK_ANSI_1, kVK_ANSI_Equal, kVK_F5, kVK_LeftArrow, kVK_Return] {
            XCTAssertTrue(codes.contains(UInt32(key)), "缺少键 \(key)")
        }
        XCTAssertFalse(codes.contains(UInt32(kVK_Escape)), "Esc 留给取消")
        XCTAssertTrue(HotKeyCombo.grabCandidates(carbonModifiers: option).allSatisfy { $0.carbonModifiers == option })
        let command = Set(HotKeyCombo.grabCandidates(carbonModifiers: UInt32(cmdKey)).map(\.keyCode))
        XCTAssertFalse(command.contains(UInt32(kVK_Tab)), "⌘Tab 是系统切换应用")
    }

    @MainActor private final class Clock {
        var scheduled: [() -> Void] = []
        func runScheduled() { let jobs = scheduled; scheduled = []; jobs.forEach { $0() } }
    }

    /// 别的应用在屏幕上的窗口：窗口编号 → 应用名。
    @MainActor private final class Screen { var windows: [Int: String] = [1: "Ghostty"] }

    @MainActor private func makeGrabbingRecorder(taken: [HotKeyCombo: LocalizedText] = [:])
        -> (HotKeyRecorderModel, Log, Clock, Screen) {
        let log = Log(), clock = Clock(), screen = Screen()
        let model = HotKeyRecorderModel(taken: { taken },
                                        apply: { log.events.append("apply \($0.label)"); return nil },
                                        onPause: { log.events.append("pause") },
                                        onResume: { log.events.append("resume") },
                                        log: { log.lines.append($0) },
                                        grab: { log.events.append($0.map { "arm \($0)" } ?? "disarm") },
                                        otherAppWindows: { screen.windows },
                                        schedule: { _, job in clock.scheduled.append(job) })
        return (model, log, clock, screen)
    }

    private let optionSpace = HotKeyCombo.standard

    @MainActor func testHoldingAModifierRegistersEveryKeyWithIt() {
        let (model, log, _, _) = makeGrabbingRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.flagsChanged([.option, .control])
        model.flagsChanged([.shift])
        model.flagsChanged([])
        XCTAssertEqual(log.events, ["pause", "arm \(optionKey)", "arm \(optionKey | controlKey)", "disarm"],
                       "只按 ⇧ 不算，松开后不重复取消")
    }

    @MainActor func testEndingTheRecordingRemovesTheTemporaryKeys() {
        let (model, log, _, _) = makeGrabbingRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.cancel()
        XCTAssertEqual(log.events, ["pause", "arm \(optionKey)", "disarm", "resume"])
    }

    @MainActor func testAGrabbedKeyIsRecorded() {
        let (model, log, _, _) = makeGrabbingRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.grabbed(optionSpace)
        XCTAssertFalse(model.recording)
        XCTAssertEqual(log.events, ["pause", "arm \(optionKey)", "disarm", "apply ⌥ Space"], "先撤掉临时登记再装新键")
        XCTAssertNil(model.message)
        XCTAssertEqual(log.lines.last, "录制收到（系统登记）：⌥ Space")
    }

    @MainActor func testGrabsAreIgnoredWhenNotRecording() {
        let (model, log, _, _) = makeGrabbingRecorder()
        model.grabbed(optionSpace)
        XCTAssertEqual(log.events, [])
    }

    @MainActor func testAGrabbedKeyStillFollowsTheRules() {
        let (model, log, _, _) = makeGrabbingRecorder(taken: [optionSpace: LocalizedText("purpose.toggleMode")])
        model.begin()
        model.flagsChanged([.option])
        model.grabbed(optionSpace)
        XCTAssertTrue(model.recording)
        XCTAssertEqual(zh(model.message), "⌥ Space 用来切换小窗和完整窗口，请换一个。")
        XCTAssertEqual(log.events, ["pause", "arm \(optionKey)"])
    }

    // MARK: 别的应用也响应了：看有没有新出现的窗口（用户 22:05：⌥K 没有别的应用响应，旧做法却提示了）

    @MainActor func testANewWindowFromAnotherAppIsNamed() {
        let (model, log, clock, screen) = makeGrabbingRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.grabbed(optionSpace)
        screen.windows[2] = "Gemini"
        clock.runScheduled()
        XCTAssertNil(model.message, "改成功了，不是错误")
        XCTAssertEqual(model.notice, HotKeyRecorderModel.conflictNotice(apps: ["Gemini"]))
        XCTAssertEqual(log.lines.last, "录制后新出现窗口：Gemini")
    }

    @MainActor func testNoNewWindowMeansNoNotice() {
        let (model, log, clock, _) = makeGrabbingRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.grabbed(HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(optionKey)))
        model.focusLost()
        clock.runScheduled()
        XCTAssertNil(model.notice, "失去焦点本身不算别的应用响应")
        XCTAssertEqual(log.lines.last, "录制后没有新窗口")
    }

    /// 按修饰键之前已经开着的窗口不算。
    @MainActor func testWindowsAlreadyOpenDoNotCount() {
        let (model, _, clock, screen) = makeGrabbingRecorder()
        screen.windows[3] = "Notes"
        model.begin()
        model.flagsChanged([.option])
        model.grabbed(optionSpace)
        clock.runScheduled()
        XCTAssertNil(model.notice)
    }

    @MainActor func testTwoAppsAreBothNamed() {
        // 用户 22:41：“太啰嗦、太长了”。框里已经显示新组合，不再重复。
        XCTAssertEqual(zh(HotKeyRecorderModel.conflictNotice(apps: ["Gemini"])), "按下时 Gemini 也会打开。")
        XCTAssertEqual(zh(HotKeyRecorderModel.conflictNotice(apps: ["Gemini", "ChatGPT"])), "按下时 Gemini、ChatGPT 也会打开。")
    }

    @MainActor func testTheSameAppWithTwoNewWindowsIsNamedOnce() {
        let (model, _, clock, screen) = makeGrabbingRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.grabbed(optionSpace)
        screen.windows[2] = "Gemini"
        screen.windows[4] = "Gemini"
        clock.runScheduled()
        XCTAssertEqual(model.notice, HotKeyRecorderModel.conflictNotice(apps: ["Gemini"]))
    }

    @MainActor func testStartingAgainClearsTheNotice() {
        let (model, _, clock, screen) = makeGrabbingRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.grabbed(optionSpace)
        screen.windows[2] = "Gemini"
        clock.runScheduled()
        model.begin()
        XCTAssertNil(model.notice)
        model.cancel()
        model.reset()
        XCTAssertNil(model.notice)
    }

    /// 检查还没跑就开始了新的录制，过期的检查不碰它。
    @MainActor func testAStaleCheckDoesNotTouchANewRecording() {
        let (model, _, clock, screen) = makeGrabbingRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.grabbed(optionSpace)
        model.begin()
        screen.windows[2] = "Gemini"
        clock.runScheduled()
        XCTAssertNil(model.notice)
        model.cancel()
    }

    /// 焦点可能比系统登记的按键先到。
    @MainActor func testFocusLossBeforeTheGrabArrivesStillRecords() {
        let (model, log, clock, _) = makeGrabbingRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.focusLost()
        XCTAssertTrue(model.recording, "先等一下")
        model.grabbed(optionSpace)
        XCTAssertFalse(model.recording)
        clock.runScheduled()
        XCTAssertNil(model.message)
        XCTAssertEqual(log.events, ["pause", "arm \(optionKey)", "disarm", "apply ⌥ Space"])
    }

    @MainActor func testFocusLossWithoutAGrabEndsTheRecordingAfterAShortWait() {
        let (model, log, clock, _) = makeGrabbingRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.focusLost()
        clock.runScheduled()
        XCTAssertFalse(model.recording)
        XCTAssertEqual(model.message, HotKeyRecorderModel.grabbedHint)
        XCTAssertEqual(log.events, ["pause", "arm \(optionKey)", "disarm", "resume"])
    }

    /// 真的登记到系统里，马上撤掉。
    @MainActor func testTemporaryRegistrationRegistersAndRemovesTheKeys() {
        let hotKey = GlobalHotKey()
        let candidates = HotKeyCombo.grabCandidates(carbonModifiers: UInt32(controlKey | optionKey | shiftKey))
        let count = hotKey.registerTemporary(candidates)
        hotKey.unregisterTemporary()
        XCTAssertGreaterThan(count, candidates.count - 5, "大部分组合都能登记")
        XCTAssertEqual(hotKey.registerTemporary(candidates), count, "撤掉后能再登记同样多")
        hotKey.unregisterTemporary()
    }

    /// 等待期间又开始了新的录制，过期的等待不能把它取消。
    @MainActor func testAStaleWaitDoesNotEndANewRecording() {
        let (model, _, clock, _) = makeGrabbingRecorder()
        model.begin()
        model.flagsChanged([.option])
        model.focusLost()
        model.cancel()
        model.begin()
        clock.runScheduled()
        XCTAssertTrue(model.recording)
        model.cancel()
    }

    @MainActor func testBeginTwiceIsHarmless() {
        let (model, log) = makeRecorder()
        model.begin()
        model.begin()
        XCTAssertEqual(log.events, ["pause"])
        model.cancel()
    }

    @MainActor func testResetAppliesTheDefault() {
        let (model, log) = makeRecorder()
        model.reset()
        XCTAssertEqual(log.events, ["apply ⌥ Space"])
    }

    @MainActor func testResetWhileRecordingStopsRecordingWithoutResumingTheOldKey() {
        let (model, log) = makeRecorder()
        model.begin()
        model.reset()
        XCTAssertFalse(model.recording)
        XCTAssertEqual(log.events, ["pause", "apply ⌥ Space"])
    }

    // MARK: 每行自己的说明（用户 22:50：“同时设置这两个的时候不知道是哪个快捷键在提示”）

    private func note(message: String? = nil, notice: String? = nil, recording: Bool = false,
                      registrationError: String? = nil) -> HotKeyNote {
        HotKeyNote.make(message: message.map(LocalizedText.verbatim), notice: notice.map(LocalizedText.verbatim), recording: recording,
                        registrationError: registrationError.map(LocalizedText.verbatim), idle: .verbatim("平时的说明"))
    }

    func testARowWithNothingToSayShowsItsOwnDescription() {
        XCTAssertEqual(note(), HotKeyNote(text: .verbatim("平时的说明"), tone: .normal))
    }

    func testARecordingRowSaysHowToCancel() {
        XCTAssertEqual(note(recording: true), HotKeyNote(text: HotKeyNote.recordingHint, tone: .normal))
    }

    func testARejectedKeyShowsInRedWhileStillRecording() {
        XCTAssertEqual(note(message: "换一个", recording: true), HotKeyNote(text: .verbatim("换一个"), tone: .error))
    }

    func testAnotherAppOpeningIsAWarning() {
        XCTAssertEqual(note(notice: "按下时 Gemini 也会打开。"), HotKeyNote(text: .verbatim("按下时 Gemini 也会打开。"), tone: .warning))
    }

    func testARegistrationFailureOutranksTheWarning() {
        XCTAssertEqual(note(notice: "按下时 Gemini 也会打开。", registrationError: "注册失败"),
                       HotKeyNote(text: .verbatim("注册失败"), tone: .error))
    }

    func testTheTwoRowsDescribeThemselvesDifferently() {
        XCTAssertNotEqual(HotKeyNote.wakeIdle, HotKeyNote.modeIdle)
    }

    // MARK: 各种界面语言（只换字，不换规则）

    func testRejectionsAreWrittenInEachLanguage() throws {
        guard case .reject(let reserved) = capture(kVK_ANSI_W, .command, "W") else { return XCTFail() }
        XCTAssertEqual(reserved.string(in: .english), "⌘W is used to hide the window. Choose another one.")
        XCTAssertEqual(reserved.string(in: .japanese), "⌘W は「ウインドウを隠す」に使われています。別の組み合わせを選んでください。")
        XCTAssertEqual(reserved.string(in: .traditionalChinese), "⌘W 用來隱藏視窗，請換一個。")
        guard case .reject(let taken) = capture(kVK_ANSI_F, [.control, .command], "F") else { return XCTFail() }
        XCTAssertEqual(taken.string(in: .english), "⌃⌘ F is used to switch between the Quick and Full window. Choose another one.")
        XCTAssertEqual(HotKeyCapture.needsModifier.string(in: .english),
                       "Include at least one of ⌘, ⌥ or ⌃, so typing doesn’t trigger it by accident.")
    }

    func testApplyErrorsAreWrittenInEachLanguage() {
        let result = HotKeyCombo.apply(controlOptionK, over: .standard) { $0 == .standard ? noErr : OSStatus(eventHotKeyExistsErr) }
        XCTAssertEqual(result.error?.string(in: .english), "⌃⌥ K is already in use. Still using ⌥ Space.")
        XCTAssertEqual(result.error?.string(in: .japanese), "⌃⌥ K はすでに使われています。引き続き ⌥ Space を使います。")
        XCTAssertEqual(result.error?.string(in: .traditionalChinese), "⌃⌥ K 已被佔用，仍在使用 ⌥ Space。")
    }

    @MainActor func testConflictNoticeJoinsAppNamesPerLanguage() {
        let notice = HotKeyRecorderModel.conflictNotice(apps: ["Gemini", "ChatGPT"])
        XCTAssertEqual(notice.string(in: .english), "Pressing it also opens Gemini, ChatGPT.")
        XCTAssertEqual(notice.string(in: .japanese), "押すと Gemini、ChatGPT も開きます。")
        XCTAssertEqual(notice.string(in: .traditionalChinese), "按下時 Gemini、ChatGPT 也會打開。")
    }

    /// 设置里“注册失败”的判断不看显示的字（以前比较 "已注册"，换了语言就会误判）。
    @MainActor func testRegistrationStatusTextDoesNotDecideFailure() {
        XCTAssertEqual(GlobalHotKey.statusText(noErr).string(in: .english), "Registered")
        XCTAssertEqual(GlobalHotKey.statusText(nil).string(in: .japanese), "未登録")
        XCTAssertEqual(GlobalHotKey.statusText(nil).string(in: .traditionalChinese), "未註冊")
        XCTAssertEqual(GlobalHotKey.statusText(OSStatus(eventHotKeyExistsErr)).string(in: .simplifiedChinese),
                       GlobalHotKey.describe(OSStatus(eventHotKeyExistsErr)), "中文显示和日志的写法一致")
        XCTAssertEqual(GlobalHotKey.statusText(-9999).string(in: .english), "Registration failed: OSStatus -9999", "错误码不加千位分隔")
    }
}
