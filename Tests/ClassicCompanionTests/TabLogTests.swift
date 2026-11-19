import AppKit
import SwiftUI
import XCTest
import CompanionCore
@testable import ClassicCompanion

/// 每个标签页的日志带它的标签（TabLog）：行末一个空格加“【标签N】”，N 是标签页的创建序号。
/// 标签页都按正式运行时的建法建（ChatTab.make），窗口是真的 ChatWindowController（不显示），加载请求不发出去。
/// 一个标签页时的整段冷启动（带标签和不带标签逐行比、窗口的行不带）在 LaunchWiringTests 里。
@MainActor
final class TabLogTests: XCTestCase {
    private let chat = URL(string: "https://chatgpt.com/c/abc?model=x")!

    private func makeDefaults() -> UserDefaults {
        let name = "TabLogTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func makeRig() -> TaggedTabs {
        let rig = TaggedTabs(defaults: makeDefaults())
        addTeardownBlock { [controller = rig.controller] in controller.window?.orderOut(nil) }
        return rig
    }

    private func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: - 写法

    /// 行末一个空格加“【标签N】”，原文一字不动；没有标签页（nil）时原样。标签里只有序号。
    func testTheTagIsTheSerialAfterTheUnchangedMessage() throws {
        var list = TabList()
        guard case .added(let second) = list.append(select: false) else { return XCTFail("应该加得进") }
        XCTAssertEqual(TabLog.tag(list.selected), "【标签1】")
        XCTAssertEqual(TabLog.tag(second), "【标签2】")
        let message = "加载 https://chatgpt.com/c/<id>?<redacted>"
        XCTAssertEqual(TabLog.tagged(message, second), message + " 【标签2】")
        XCTAssertEqual(TabLog.tagged(message, nil), message)
        let pattern = try NSRegularExpression(pattern: "^【标签[0-9]+】$")
        for tag in [TabLog.tag(list.selected), TabLog.tag(second)] {
            XCTAssertEqual(pattern.numberOfMatches(in: tag, range: NSRange(tag.startIndex..., in: tag)), 1, tag)
        }
    }

    // MARK: - 正式运行时的建法

    /// 启动时的那个标签页正式运行时这样建（AppDelegate：新列表选中的标识交给 ChatTab.make）：
    /// 运行时和适配器的日志从建的时候写的第一行起就带“【标签1】”，只有一个标签页也带。
    func testTheLaunchTabAsBuiltAtLaunchTagsItsLinesFromTheFirst() {
        let settings = AppSettings(defaults: makeDefaults())
        let diagnostics = Diagnostics()
        let tab = ChatTab.make(id: TabList().selected, diagnostics: diagnostics, settings: settings)
        XCTAssertEqual(tab.id.rawValue, 1)
        XCTAssertEqual(tab.runtime.log.tab, tab.id)
        XCTAssertEqual(tab.adapter.log.tab, tab.id)
        XCTAssertEqual(tab.logTag, tab.id)
        XCTAssertEqual(diagnostics.entries.map { "[\($0.category)] \($0.message)" }, [
            "[ax] 允许其他应用读取网页内容=\(settings.allowPageAccessibility) VoiceOver=\(NSWorkspace.shared.isVoiceOverEnabled) 【标签1】",
            "[web] 网页检查器：开 【标签1】",
        ])
    }

    // MARK: - 两个标签页

    /// 两个标签页共用一份诊断：A（标签 1，选中）和 B（标签 2，不显示）。各自的运行时写的、ChatTabs 为各自写的
    /// （页面变化、每秒的媒体状态）、改设置时每个都写的、网络变化时每个都写的，都带各自的标签。
    func testEachTabsLinesCarryItsOwnTag() async throws {
        let rig = makeRig()
        let a = rig.first, b = rig.add()
        XCTAssertEqual([a, b].map(\.id.rawValue), [1, 2])
        let mark = rig.diagnostics.entries.count
        b.runtime.load(chat)
        a.runtime.load(WebRuntime.homeURL)
        b.runtime.onURLChange?(chat)
        a.runtime.onURLChange?(WebRuntime.homeURL)
        rig.tabs.setPageZoom(1.25)
        rig.tabs.setPageAccessibilityAllowed(true)
        rig.network.deliver(online: false)
        rig.tabs.selectForTesting(b)
        rig.tabs.mediaTick()
        try await waitUntil { rig.lines(since: mark).last?.hasPrefix("[media]") == true }
        XCTAssertEqual(rig.lines(since: mark), [
            "[nav] 加载 https://chatgpt.com/c/<id>?<redacted> 【标签2】",
            "[nav] 加载 https://chatgpt.com/ 【标签1】",
            "[nav] 页面变化 https://chatgpt.com/c/<id>?<redacted> 【标签2】",
            "[nav] 页面变化 https://chatgpt.com/ 【标签1】",
            "[zoom] 页面缩放 125% 【标签1】",
            "[zoom] 页面缩放 125% 【标签2】",
            "[ax] 允许其他应用读取网页内容=true 【标签1】",
            "[ax] 允许其他应用读取网页内容=true 【标签2】",
            "[net] 网络不可用 【标签1】",
            "[net] 网络不可用 【标签2】",
            "[media] WebKit 媒体状态 none → playing（窗口可见=false） 【标签2】",
        ])
    }

    /// 标签是创建序号：拿掉一个再加，新的是下一个序号，不重用拿掉的那个。拿掉的那个之后还写的行仍是它自己的标签，
    /// 和新的分得开。新的那个建的时候写的行就带它的标签。
    func testTagsAreUniqueAndNotReusedAfterARemoveAndANewAdd() {
        let rig = makeRig()
        let b = rig.add()
        rig.tabs.removeForTesting(b)
        let mark = rig.diagnostics.entries.count
        let c = rig.add()
        XCTAssertEqual(rig.tabs.tabs.map { TabLog.tag($0.id) }, ["【标签1】", "【标签3】"])
        XCTAssertEqual([rig.first, b, c].map { $0.runtime.log.tab?.rawValue }, [1, 2, 3])
        XCTAssertEqual([rig.first, b, c].map { $0.adapter.log.tab?.rawValue }, [1, 2, 3])
        c.runtime.load(WebRuntime.homeURL)
        b.runtime.load(WebRuntime.homeURL)
        XCTAssertEqual(rig.lines(since: mark), [
            "[ax] 允许其他应用读取网页内容=\(rig.settings.allowPageAccessibility) VoiceOver=\(NSWorkspace.shared.isVoiceOverEnabled) 【标签3】",
            "[web] 网页检查器：开 【标签3】",
            "[nav] 加载 https://chatgpt.com/ 【标签3】",
            "[nav] 加载 https://chatgpt.com/ 【标签2】",
        ])
    }

    /// 媒体实验那一行日志带它对的那个标签页（开始时选中的）的标签；诊断窗口和报告里的实验记录照原样不带。
    func testAnExperimentsLogLineCarriesItsTabsTagButTheRecordDoesNot() async {
        let rig = makeRig()
        let b = rig.add()
        rig.tabs.selectForTesting(b)
        rig.tabs.evidenceTarget = { _ in FixedEvidence() }
        let mark = rig.diagnostics.entries.count
        await rig.tabs.runExperiment(.setRate(1.5))
        XCTAssertEqual(rig.lines(since: mark), ["[experiment] DOM playbackRate=1.5：set=ok 【标签2】"])
        XCTAssertEqual(rig.diagnostics.experiments.map { String($0.drop { $0 != " " }.dropFirst()) },
                       ["DOM playbackRate=1.5：set=ok"])
    }

    // MARK: - 源文件

    /// 运行时、适配器和 ChatTabs 写的日志都经过标签页的 log，源文件里没有绕过它直接写诊断日志的地方；实验记录都交了标签页。
    /// 适配器的那几行要在真实的 ChatGPT 页面里才写得出来（都先看是不是聊天页），不开页面只能这样核对。
    func testNoLineInTheRuntimeAdapterOrTabsBypassesTheTabsLog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ClassicCompanion")
        for file in ["Web/WebRuntime.swift", "Adapter/ChatGPTAdapter.swift", "Tabs/ChatTabs.swift", "Tabs/ChatTab.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(source.contains("diagnostics.log("), file)
        }
        let evidence = try String(contentsOf: root.appendingPathComponent("Diagnostics/PageEvidence.swift"), encoding: .utf8)
        let records = evidence.components(separatedBy: "\n").filter { $0.contains("recordExperiment(") }
        XCTAssertEqual(records.count, 5)
        XCTAssertTrue(records.allSatisfy { $0.hasSuffix(", tab: tab)") }, "\(records)")
    }
}

/// 两个以上的标签页：启动时的那个和之后加的，都用 ChatTab.make 建（日志带标签），共用一份诊断和一个窗口。
/// 加载请求不发出去；AppDelegate 交给 ChatTabs 的几样换成不做事的替身，读网页媒体状态返回 media。
@MainActor
private final class TaggedTabs {
    let settings: AppSettings
    let diagnostics = Diagnostics()
    let first: ChatTab
    let controller: ChatWindowController
    private(set) var tabs: ChatTabs!
    let network = NetworkStatus(startsMonitor: false)
    var media = "playing"

    init(defaults: UserDefaults) {
        settings = AppSettings(defaults: defaults)
        let list = TabList()
        first = ChatTab.make(id: list.selected, diagnostics: diagnostics, settings: settings)
        first.runtime.loadRequest = { _ in }
        controller = ChatWindowController(webView: first.runtime.webView, toolbar: EmptyView(), diagnostics: diagnostics,
                                          appearance: PageAppearance(defaults: defaults), page: first.page)
        controller.pageColorSettleLimit = 60
        tabs = ChatTabs(list: list, tab: first, windowController: controller, diagnostics: diagnostics, network: network,
                        hideWindow: { _ in },
                        focusInput: { _ in "TabLogTests" },
                        saveLastConversation: { _ in },
                        mediaState: { [weak self] _ in self?.media ?? "?" },
                        openNewChat: { _ in true })
        tabs.wire(first)
    }

    /// 加一个标签页（正式运行时的建法），不选中。
    func add() -> ChatTab {
        let tab = tabs.add { ChatTab.make(id: $0, diagnostics: diagnostics, settings: settings) }!
        tab.runtime.loadRequest = { _ in }
        return tab
    }

    /// mark 条之后写的日志（“[类别] 内容”），去掉跟着真实鼠标、键盘、屏幕写的（LiveInputLogLines）。
    func lines(since mark: Int) -> [String] {
        diagnostics.entries.dropFirst(mark).filter { !LiveInputLogLines.excludes($0) }.map { "[\($0.category)] \($0.message)" }
    }
}

/// 证据采集和媒体实验的替身：每样都马上返回固定的内容。
@MainActor
private struct FixedEvidence: EvidenceTarget {
    func probe() async {}
    func readAloudEvidence() async -> String { "{}" }
    func measureMedia() async -> String { "测量" }
    func webMediaState() async -> String { "none" }
    func experimentSetRate(_ rate: Double) async -> String { "set=ok" }
    func setAllMediaPlaybackSuspended(_ suspended: Bool) async {}
    func pauseAllMediaPlayback() async {}
}
