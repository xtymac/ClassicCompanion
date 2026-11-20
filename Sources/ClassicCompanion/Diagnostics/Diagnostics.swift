import Foundation
import Combine
import os
import CompanionCore

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
        /// 这份快照是哪个标签页的（探测它的适配器的标签页），报告里那一段带上它的标签；nil 不带（测试里单独建的适配器）。
        var tab: TabID?
        /// 最近一次回答提取是哪个标签页的（和上面的快照可能不是同一个）。
        var extractionTab: TabID?
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
    @Published private(set) var readAloudEvidence = Diagnostics.notCollected
    @Published private(set) var mediaMeasurement = Diagnostics.notMeasured
    @Published private(set) var webMediaState = "unknown"
    @Published private(set) var experiments: [String] = []

    // 下面这几样说的都是某一个标签页：各记下是哪个标签页的（开始读、开始采集这一刻绑定的那个，不是写进来时选中的那个），
    // 报告里那一行带上它的标签（reportTag）。nil 不带。只有标签页的创建序号，没有标题、地址。
    private(set) var readAloudEvidenceTab: TabID?
    private(set) var mediaMeasurementTab: TabID?
    private(set) var webMediaStateTab: TabID?
    /// 和 experiments 一一对应。
    private var experimentTabs: [TabID?] = []
    /// 已经关闭的标签页（ChatTabs.close(_:) 告诉这里）。标识不再用，所以只增不减；报告里它们的行写“已关闭的标签N”。
    private var closedTabs: Set<TabID> = []

    /// 官方 Read Aloud 的结构证据（脱敏 JSON 摘要），是标签页 tab 的（PageEvidence.collect 交开始时绑定的那个）。
    func recordReadAloudEvidence(_ evidence: String, tab: TabID?) {
        readAloudEvidence = evidence
        readAloudEvidenceTab = tab
    }

    /// 媒体速率测量的结果，是标签页 tab 的（采集证据、测量实验交开始时绑定的那个）。
    func recordMediaMeasurement(_ measured: String, tab: TabID?) {
        mediaMeasurement = measured
        mediaMeasurementTab = tab
    }

    /// WebKit 报的媒体状态，是标签页 tab 的（每秒读的那一次开始时选中的那个，ChatTabs.mediaTick）。
    func recordWebMediaState(_ state: String, tab: TabID?) {
        webMediaState = state
        webMediaStateTab = tab
    }

    /// tab：实验是对哪个标签页做的。给了就在日志那一行末尾带上它的标签（TabLog），报告里的实验记录那一行也带上
    /// （reportTag）；诊断窗口里的实验记录（experiments）照原样不带。
    func recordExperiment(_ line: String, tab: TabID? = nil) {
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        experiments.append("\(tf.string(from: Date())) \(line)")
        experimentTabs.append(tab)
        if experiments.count > 50 {
            experiments.removeFirst()
            experimentTabs.removeFirst()
        }
        log("experiment", TabLog.tagged(line, tab))
    }

    /// 标签页 tab 关闭了（ChatTabs.close(_:)）。它写下的那几样留着（是它关闭前的），报告里那一行改写“已关闭的标签N”，
    /// 不去掉，也不标成别的标签页。nil（没有标签的）不记。
    func tabClosed(_ tab: TabID?) {
        guard let tab else { return }
        closedTabs.insert(tab)
    }

    /// 报告里一行末尾说它是哪个标签页的：“ 【标签N】”；那个标签页已经关闭是“ 【已关闭的标签N】”；nil 是空。
    /// 和日志的标签（TabLog.tag）一样只有创建序号。
    func reportTag(_ tab: TabID?) -> String {
        guard let tab else { return "" }
        return closedTabs.contains(tab) ? " 【已关闭的标签\(tab.rawValue)】" : " \(TabLog.tag(tab))"
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
        lines.append("[页面能力] 检查于 \(c.checkedAt.map(df.string(from:)) ?? "-")\(reportTag(c.tab))")
        lines.append("  页面类型=\(c.pageKind) 位置=\(c.location)")
        lines.append("  输入框=\(c.inputFound) 已聚焦=\(c.inputFocused) 消息数=\(c.messageCount) 助手消息数=\(c.assistantCount)")
        lines.append("  生成中=\(c.streaming) 弹层=\(c.overlayOpen) 登录按钮可见=\(c.loginButtonVisible)")
        lines.append("  最近一次回答提取=\(c.lastExtraction)\(reportTag(c.extractionTab))")
        lines.append("  选择器命中=\(c.selectorHits)")
        lines.append("")
        lines.append("[官方 Read Aloud 证据]")
        lines.append("  WebKit 媒体状态=\(webMediaState)\(reportTag(webMediaStateTab))")
        lines.append("  结构=\(readAloudEvidence)\(reportTag(readAloudEvidenceTab))")
        lines.append("  速率测量=\(mediaMeasurement)\(reportTag(mediaMeasurementTab))")
        lines.append("  实验记录:")
        for (e, tab) in zip(experiments, experimentTabs) { lines.append("    \(e)\(reportTag(tab))") }
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

/// 一个标签页写诊断日志用的：每行末尾带上这个标签页的标签，看得出是哪个标签页的事。
/// 网页运行时和适配器各拿一个（建的时候给标签页的标识，见 ChatTab.make）；ChatTabs 写某个标签页的事时用那个标签页的标签
/// （ChatTab.logTag）现建一个。
/// 标签只是标签页的创建序号（TabID.rawValue：从 1 起，关掉的不再用，不保存，重开应用重新从 1 数），
/// 不含标题、地址或别的内容。一行里其余的内容和不带标签时一字不差，脱敏照旧由各行自己做（Redactor）。
/// tab 为 nil 时不带标签：测试里单独建的运行时、适配器就是这样，原有的日志断言不用改。
/// 窗口（ChatWindowController）、AppDelegate、更新和计数写的不带标签：它们说的是窗口或全应用的事，
/// 窗口只为显示着的页面（选中的标签页）写。
struct TabLog: Sendable {
    let diagnostics: Diagnostics
    let tab: TabID?

    @MainActor func callAsFunction(_ category: String, _ message: String) {
        diagnostics.log(category, Self.tagged(message, tab))
    }

    /// 标签的写法：“【标签N】”，N 是创建序号，只有一个标签页时也写。
    /// 找某个标签页的行：grep '【标签2】'（数字后面紧跟“】”，找标签 1 不会找到标签 12）；
    /// 找所有带标签的行：grep -E ' 【标签[0-9]+】$'。
    static func tag(_ tab: TabID) -> String { "【标签\(tab.rawValue)】" }

    /// 一行加上标签：原文、一个空格、标签，放在末尾。放在末尾而不放在开头：按开头找的
    /// （“[nav] 加载 ”、hasPrefix("首次收到无障碍请求")）照样找得到，不会因为多了标签就找不到、把“有”当成“没有”。
    static func tagged(_ message: String, _ tab: TabID?) -> String {
        guard let tab else { return message }
        return "\(message) \(tag(tab))"
    }
}
