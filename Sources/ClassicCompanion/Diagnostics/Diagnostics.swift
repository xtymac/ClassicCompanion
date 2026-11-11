import Foundation
import Combine
import os

/// 脱敏诊断。只记录功能状态、耗时和错误类别；不记录聊天正文、回答全文、凭证或完整 URL。
@MainActor
final class Diagnostics: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let message: String
    }

    /// 网页能力探测快照（只含布尔值与计数）
    struct PageCapabilities: Equatable {
        var pageKind = "unknown"
        var location = "<nil>"
        var inputFound = false
        var inputFocused = false
        var messageCount = 0
        var assistantCount = 0
        var streaming = false
        var overlayOpen = false
        var loginButtonVisible = false
        var lastExtraction = "未执行"
        /// 每个候选选择器的命中数，例如 input=0/1/0/0/1
        var selectorHits = "-"
        var checkedAt: Date?
    }

    private let logger = Logger(subsystem: "local.classiccompanion", category: "app")
    private let defaults = UserDefaults.standard

    @Published private(set) var entries: [Entry] = []
    @Published var capabilities = PageCapabilities()
    /// 唤醒键最近一次注册的结果，nil 是还没注册。界面按语言显示（GlobalHotKey.statusText），报告里是固定的中文。
    @Published var hotKeyRegistration: OSStatus?
    @Published var userAgent = "<未知>"
    @Published var dataStoreIsPersistent = false
    /// 启动模式：用于证明对照测试未经过 Quick
    @Published var launchMode = "默认（Quick）"

    // 官方 Read Aloud 证据（脱敏 JSON 摘要）。下面两个初始值是报告里的固定写法，诊断窗口显示时按语言换掉。
    static let notCollected = "未采集"
    static let notMeasured = "未测量"
    @Published var readAloudEvidence = Diagnostics.notCollected
    @Published var mediaMeasurement = Diagnostics.notMeasured
    @Published var webMediaState = "unknown"
    @Published private(set) var experiments: [String] = []

    func recordExperiment(_ line: String) {
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        experiments.append("\(tf.string(from: Date())) \(line)")
        if experiments.count > 50 { experiments.removeFirst() }
        log("experiment", line)
    }

    /// 报告文件位置（只含脱敏内容）
    static var reportURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClassicCompanion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics-latest.txt")
    }

    func writeReportFile(build: String) {
        do {
            try report(build: build).write(to: Self.reportURL, atomically: true, encoding: .utf8)
            log("diag", "报告已写入 Application Support/ClassicCompanion/diagnostics-latest.txt")
        } catch {
            log("diag", "报告写入失败 \((error as NSError).code)")
        }
    }

    // Gate C：唤醒/隐藏循环计数（跨重启保存，仅含前台应用 bundle id 与计数）
    /// 显示窗口的原因。只有 wake 与隐藏次数配对；其余两类单独计数，用于和日志对账。
    enum ShowKind: String {
        case wake = "唤醒"
        case activate = "激活已可见窗口"
        case modeSwitch = "切换模式"
    }

    /// 本应用收到的快捷键次数：用户按键次数比它多，说明按键被其他应用拿走。
    @Published private(set) var hotKeyCount = 0
    @Published private(set) var showCount = 0
    @Published private(set) var hideCount = 0
    @Published private(set) var activateCount = 0
    @Published private(set) var modeSwitchCount = 0
    @Published private(set) var appDistribution: [String: Int] = [:]
    @Published private(set) var focusRestoreOK = 0
    @Published private(set) var focusRestoreFailed = 0
    @Published private(set) var inputFocusResults: [String: Int] = [:]

    init() {
        hotKeyCount = defaults.integer(forKey: "diag.hotKeyCount")
        showCount = defaults.integer(forKey: "diag.showCount")
        hideCount = defaults.integer(forKey: "diag.hideCount")
        activateCount = defaults.integer(forKey: "diag.activateCount")
        modeSwitchCount = defaults.integer(forKey: "diag.modeSwitchCount")
        focusRestoreOK = defaults.integer(forKey: "diag.focusRestoreOK")
        focusRestoreFailed = defaults.integer(forKey: "diag.focusRestoreFailed")
        appDistribution = defaults.dictionary(forKey: "diag.apps") as? [String: Int] ?? [:]
        inputFocusResults = defaults.dictionary(forKey: "diag.inputFocus") as? [String: Int] ?? [:]
    }

    func log(_ category: String, _ message: String) {
        logger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        entries.append(Entry(date: Date(), category: category, message: message))
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
    }

    func recordHotKey() {
        hotKeyCount += 1
        log("cycle", "快捷键 #\(hotKeyCount)")
        persistCycle()
    }

    func recordShow(_ kind: ShowKind, previousApp: String?) {
        switch kind {
        case .wake:
            showCount += 1
            log("cycle", "唤醒 #\(showCount)")
            appDistribution[previousApp ?? "<无/本应用>", default: 0] += 1
        case .activate:
            activateCount += 1
            log("cycle", "激活已可见窗口 #\(activateCount)")
        case .modeSwitch:
            modeSwitchCount += 1
            log("cycle", "切换模式 #\(modeSwitchCount)")
        }
        persistCycle()
    }

    func recordHide() {
        hideCount += 1
        log("cycle", "隐藏 #\(hideCount)")
        persistCycle()
    }

    func recordFocusRestore(ok: Bool) {
        if ok { focusRestoreOK += 1 } else { focusRestoreFailed += 1 }
        persistCycle()
    }

    func recordInputFocus(_ result: String) {
        inputFocusResults[result, default: 0] += 1
        persistCycle()
    }

    func resetCycleCounters() {
        hotKeyCount = 0; showCount = 0; hideCount = 0; activateCount = 0; modeSwitchCount = 0
        focusRestoreOK = 0; focusRestoreFailed = 0
        appDistribution = [:]; inputFocusResults = [:]
        persistCycle()
        log("diag", "Gate C 计数已重置")
    }

    private func persistCycle() {
        defaults.set(hotKeyCount, forKey: "diag.hotKeyCount")
        defaults.set(showCount, forKey: "diag.showCount")
        defaults.set(hideCount, forKey: "diag.hideCount")
        defaults.set(activateCount, forKey: "diag.activateCount")
        defaults.set(modeSwitchCount, forKey: "diag.modeSwitchCount")
        defaults.set(focusRestoreOK, forKey: "diag.focusRestoreOK")
        defaults.set(focusRestoreFailed, forKey: "diag.focusRestoreFailed")
        defaults.set(appDistribution, forKey: "diag.apps")
        defaults.set(inputFocusResults, forKey: "diag.inputFocus")
    }

    /// 生成可粘贴到验证记录中的脱敏报告。
    func report(build: String) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let c = capabilities
        let df = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("Classic Companion Phase 0 诊断（脱敏）")
        lines.append("生成时间: \(df.string(from: Date()))")
        lines.append("构建: \(build)")
        lines.append("macOS: \(os)")
        lines.append("快捷键: \(hotKeyRegistration.map(GlobalHotKey.describe) ?? "未注册")")
        lines.append("WebKit 数据存储持久化: \(dataStoreIsPersistent)")
        lines.append("启动模式: \(launchMode)")
        lines.append("User-Agent: \(userAgent)")
        lines.append("")
        lines.append("[页面能力] 检查于 \(c.checkedAt.map(df.string(from:)) ?? "-")")
        lines.append("  页面类型=\(c.pageKind) 位置=\(c.location)")
        lines.append("  输入框=\(c.inputFound) 已聚焦=\(c.inputFocused) 消息数=\(c.messageCount) 助手消息数=\(c.assistantCount)")
        lines.append("  生成中=\(c.streaming) 弹层=\(c.overlayOpen) 登录按钮可见=\(c.loginButtonVisible)")
        lines.append("  最近一次回答提取=\(c.lastExtraction)")
        lines.append("  选择器命中=\(c.selectorHits)")
        lines.append("")
        lines.append("[官方 Read Aloud 证据]")
        lines.append("  WebKit 媒体状态=\(webMediaState)")
        lines.append("  结构=\(readAloudEvidence)")
        lines.append("  速率测量=\(mediaMeasurement)")
        lines.append("  实验记录:")
        for e in experiments { lines.append("    \(e)") }
        lines.append("")
        lines.append("[Gate C 计数] 快捷键=\(hotKeyCount) 唤醒=\(showCount) 隐藏=\(hideCount) 激活已可见窗口=\(activateCount) 切换模式=\(modeSwitchCount) 焦点恢复成功=\(focusRestoreOK) 失败=\(focusRestoreFailed)")
        lines.append("  前台应用分布: " + appDistribution.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
        lines.append("  输入框聚焦结果: " + inputFocusResults.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
        lines.append("")
        lines.append("[最近日志]")
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        for e in entries.suffix(80) {
            lines.append("  \(tf.string(from: e.date)) [\(e.category)] \(e.message)")
        }
        return lines.joined(separator: "\n")
    }
}
