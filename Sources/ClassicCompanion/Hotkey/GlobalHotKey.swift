import AppKit
import Carbon.HIToolbox

/// 基于 Carbon RegisterEventHotKey 的全局快捷键。不需要辅助功能权限。
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x4343_4F4D // 'CCOM'
    var onPressed: (() -> Void)?
    /// 录制时临时登记的组合被按下。
    var onTemporaryPressed: ((HotKeyCombo) -> Void)?
    private var temporaryRefs: [EventHotKeyRef] = []
    private var temporaryCombos: [UInt32: HotKeyCombo] = [:]
    private static let firstTemporaryID: UInt32 = 1000

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let number = status == noErr ? id.id : 1
            // Carbon 事件在主线程分发
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().pressed(number)
            }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
    }

    /// 返回 noErr 表示注册成功；eventHotKeyExistsErr 表示已被占用。
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        unregister()
        let id = EventHotKeyID(signature: signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { hotKeyRef = ref }
        return status
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func pressed(_ number: UInt32) {
        if number < Self.firstTemporaryID {
            onPressed?()
        } else if let combo = temporaryCombos[number] {
            onTemporaryPressed?(combo)
        }
    }

    /// 录制时临时登记一批组合，返回登记成功的个数。系统保留的组合会失败，跳过。
    @discardableResult
    func registerTemporary(_ combos: [HotKeyCombo]) -> Int {
        unregisterTemporary()
        for (index, combo) in combos.enumerated() {
            let number = Self.firstTemporaryID + UInt32(index)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: signature, id: number),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                temporaryRefs.append(ref)
                temporaryCombos[number] = combo
            }
        }
        return temporaryRefs.count
    }

    func unregisterTemporary() {
        temporaryRefs.forEach { UnregisterEventHotKey($0) }
        temporaryRefs = []
        temporaryCombos = [:]
    }

    /// 日志用，保持原来的中文。界面上用 statusText。
    static func describe(_ status: OSStatus) -> String {
        switch status {
        case noErr: "已注册"
        case OSStatus(eventHotKeyExistsErr): "注册失败：组合已被其他应用或系统占用（eventHotKeyExistsErr）"
        case OSStatus(eventHotKeyInvalidErr): "注册失败：无效组合（eventHotKeyInvalidErr）"
        default: "注册失败：OSStatus \(status)"
        }
    }

    /// 设置和诊断窗口里显示的注册状态，按界面语言。nil 是还没注册。
    static func statusText(_ status: OSStatus?) -> LocalizedText {
        guard let status else { return LocalizedText("hotkey.status.notRegistered") }
        return switch status {
        case noErr: LocalizedText("hotkey.status.registered")
        case OSStatus(eventHotKeyExistsErr): LocalizedText("hotkey.status.inUse")
        case OSStatus(eventHotKeyInvalidErr): LocalizedText("hotkey.status.invalid")
        default: LocalizedText("hotkey.status.other", .plain(String(status)))
        }
    }
}
