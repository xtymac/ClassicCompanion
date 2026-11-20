import XCTest
import WebKit
@testable import ClassicCompanion

/// 网页里的阅读位置（AdapterScripts 里的 __ccReadingHold）按编号记下、放回、丢弃，以及“新对话页拿到对话地址”时的确认；
/// 和 WebRuntime 怎样把编号交给网页。真实的 WebKit，但网页视图不放进窗口（不开窗口、不上屏）：xctest 里网页始终是隐藏的，
/// requestAnimationFrame 不会触发，这里只测不靠帧的部分（记下、放回、丢弃、确认），排版完成时的那次放回
/// （layoutReadyScript）要在 PageTests 的真实窗口里测。
/// 页面是固定的假页面：一个可滚动区，里面 80 段，每段是一个带 data-turn-key 的“一问一答”。没有正文以外的东西，不联网。
@MainActor
final class ReadingHoldScriptTests: XCTestCase {
    /// rows 段，每段一个“一问一答”（turns 为假时不带 data-turn-key）。每段高度不一样，和真实对话一样。
    /// nested 为真时每一问一答里面还有一层带 data-turn-key 的部分（class="part"），像回答在一问一答里面。
    private func fixture(turns: Bool = true, prefix: String = "k", nested: Bool = false) -> String {
        """
        <html><body style="margin:0"><main id="chat"><div id="scroll" style="height:300px;width:100%;overflow-y:auto">\
        \(thread(turns: turns, prefix: prefix, nested: nested))</div></main></body></html>
        """
    }

    private func thread(turns: Bool = true, prefix: String = "k", id: String = "thread", nested: Bool = false) -> String {
        let rows = (0..<80).map { i in
            let key = turns ? " data-turn-key=\"\(prefix)\(i)\"" : ""
            let text = "<p style=\"margin:0;padding:8px\">\(String(repeating: "word ", count: 30 + i % 20))</p>"
            let body = nested ? "<div class=\"part\" data-turn-key=\"\(prefix)\(i)-a\">\(text)</div>" : text
            return "<div id=\"\(prefix)\(i)\"\(key)>\(body)</div>"
        }.joined()
        return "<div id=\"\(id)\">\(rows)</div>"
    }

    private func page(_ html: String, path: String = "/") async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 720, height: 520), configuration: config)
        try await load(html, into: web, path: path)
        return web
    }

    private func load(_ html: String, into web: WKWebView, path: String = "/") async throws {
        web.loadHTMLString(html, baseURL: URL(string: "https://chatgpt.com" + path))
        for _ in 0..<150 {
            if !web.isLoading, (try? await js(web, "document.readyState")) as? String == "complete" {
                _ = try await js(web, AdapterScripts.escapeUserScript + "\n0")
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("假页面没有加载完")
    }

    private func js(_ web: WKWebView, _ script: String) async throws -> Any? {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value):
                    do { continuation.resume(returning: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) }
                    catch { continuation.resume(throwing: error) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// 调 __ccReadingHold 的一个方法，例如 hold(web, "save(1)")。
    private func hold(_ web: WKWebView, _ call: String) async throws -> Any? {
        try await js(web, "window.__ccReadingHold.\(call)")
    }

    private func scroll(_ web: WKWebView, to top: Int) async throws {
        _ = try await js(web, "document.getElementById('scroll').scrollTop = \(top); 0")
    }

    /// 调 __ccReadingHold 的一个方法，核对它返回的字符串（restore）或布尔值（save、discard）。
    private func expect(_ web: WKWebView, _ call: String, is expected: String,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await hold(web, call) as? String
        XCTAssertEqual(value, expected, call, file: file, line: line)
    }

    private func expect(_ web: WKWebView, _ call: String, is expected: Bool,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await hold(web, call) as? Bool
        XCTAssertEqual(value, expected, call, file: file, line: line)
    }

    private func scrollTop(_ web: WKWebView) async throws -> Double {
        let value = try await js(web, "document.getElementById('scroll').scrollTop") as? Double
        return try XCTUnwrap(value)
    }

    /// 阅读线（滚动区 25% 高处）上是哪一段。
    private func row(_ web: WKWebView) async throws -> String {
        let value = try await js(web, """
            (() => { const s = document.getElementById('scroll'), b = s.getBoundingClientRect(), y = b.top + b.height * 0.25;
              const rows = [...document.querySelectorAll('#scroll [id]')].filter(r => r.parentElement?.id?.startsWith('thread'));
              return rows.find(r => { const q = r.getBoundingClientRect(); return q.height > 0 && q.top <= y && q.bottom > y; })?.id ?? 'none'; })()
            """) as? String
        return try XCTUnwrap(value)
    }

    /// 同一份文档里换路径（像 ChatGPT 页内换页面那样，不重新加载）。
    private func push(_ web: WKWebView, _ path: String) async throws {
        _ = try await js(web, "history.pushState(null, '', '\(path)'); location.pathname")
    }

    // MARK: - 按编号丢弃

    /// 丢弃以后再记下，记的是这时的位置，不沿用丢掉的那次。对照：不丢弃时，连续记下沿用第一次的（误差不累积，原来的行为）。
    func testADiscardedSaveIsNotReusedByALaterSave() async throws {
        let web = try await page(fixture())
        try await scroll(web, to: 1000)
        let first = try await row(web)
        try await expect(web, "save(1)", is: true)
        try await scroll(web, to: 3000)
        let second = try await row(web)
        XCTAssertNotEqual(first, second)
        try await expect(web, "discard(1)", is: true)
        try await expect(web, "save(2)", is: true)
        try await scroll(web, to: 0)
        try await expect(web, "restore(2)", is: "restored")
        let restored = try await row(web)
        XCTAssertEqual(restored, second, "丢掉的那次不再被沿用")

        let control = try await page(fixture())
        try await scroll(control, to: 1000)
        let controlFirst = try await row(control)
        _ = try await hold(control, "save(1)")
        try await scroll(control, to: 3000)
        _ = try await hold(control, "save(2)")
        try await scroll(control, to: 0)
        try await expect(control, "restore(2)", is: "restored")
        let controlRestored = try await row(control)
        XCTAssertEqual(controlRestored, controlFirst, "不丢弃时沿用第一次记下的")
    }

    /// 两次记下共用一份记录（沿用）：丢弃旧的那次只去掉它的编号，更新的那次照样放回；旧的那次放回不了，再丢一次也没有。
    func testDiscardingAnOlderSaveKeepsANewerOneThatSharesIt() async throws {
        let web = try await page(fixture())
        try await scroll(web, to: 1000)
        let first = try await row(web)
        _ = try await hold(web, "save(1)")
        _ = try await hold(web, "save(2)")
        try await scroll(web, to: 3000)
        try await expect(web, "discard(1)", is: true)
        try await expect(web, "restore(1)", is: "none")
        try await expect(web, "discard(1)", is: false)
        try await expect(web, "restore(2)", is: "restored")
        let restored = try await row(web)
        XCTAssertEqual(restored, first)
    }

    /// 丢弃一个没记下过的编号（例如更新的、或者别的文档里的）：什么都不变，记下的那次照样放回。
    func testDiscardingAnotherNumberChangesNothing() async throws {
        let web = try await page(fixture())
        try await scroll(web, to: 1000)
        let first = try await row(web)
        _ = try await hold(web, "save(1)")
        try await scroll(web, to: 3000)
        try await expect(web, "discard(7)", is: false)
        try await expect(web, "restore(1)", is: "restored")
        let restored = try await row(web)
        XCTAssertEqual(restored, first)
    }

    // MARK: - 换过页面

    /// 换了页面（路径变了）以后再记下：不沿用换页面之前的那份，先放掉它（旧编号放回不了），记这时的位置。
    func testASaveAfterThePageMovedOnDoesNotReuseTheOldOne() async throws {
        let web = try await page(fixture(), path: "/c/aaa")
        try await scroll(web, to: 1000)
        _ = try await hold(web, "save(1)")
        try await push(web, "/c/bbb")
        try await scroll(web, to: 3000)
        let second = try await row(web)
        try await expect(web, "save(2)", is: true)
        try await expect(web, "restore(1)", is: "none")
        try await scroll(web, to: 0)
        try await expect(web, "restore(2)", is: "restored")
        let restored = try await row(web)
        XCTAssertEqual(restored, second)
    }

    /// 不带编号的放回（排好版时 layoutReadyScript 调的）只在路径没变时放回；路径变了什么都不动，留给原生按规则决定，
    /// 原生决定放回时（带编号）照样放得回去。
    func testTheNumberlessRestoreOnlyPutsBackOnTheSamePath() async throws {
        let web = try await page(fixture())
        try await scroll(web, to: 1000)
        let first = try await row(web)
        _ = try await hold(web, "save(1)")
        try await scroll(web, to: 3000)
        try await push(web, "/c/new")
        try await expect(web, "restore()", is: "none")
        let untouched = try await scrollTop(web)
        XCTAssertEqual(untouched, 3000, accuracy: 1)
        try await expect(web, "restore(1)", is: "restored")
        let restored = try await row(web)
        XCTAssertEqual(restored, first)

        let same = try await page(fixture(), path: "/c/aaa")
        try await scroll(same, to: 1000)
        let sameFirst = try await row(same)
        _ = try await hold(same, "save(1)")
        try await scroll(same, to: 3000)
        try await expect(same, "restore()", is: "restored")
        let sameRestored = try await row(same)
        XCTAssertEqual(sameRestored, sameFirst)
    }

    // MARK: - 新对话页拿到对话地址：网页确认

    /// 同一份文档里路径从 / 变成 /c/…，记下时视口里的那一问一答还是同一个元素、还显示着、标识没变：确认，放回。
    func testTheSameConversationThatGotItsAddressIsConfirmed() async throws {
        let web = try await page(fixture())
        try await scroll(web, to: 1000)
        let first = try await row(web)
        _ = try await hold(web, "save(1)")
        try await push(web, "/c/new")
        try await scroll(web, to: 2500)
        try await expect(web, "restore(1, true)", is: "restored")
        let restored = try await row(web)
        XCTAssertEqual(restored, first)
    }

    /// 对话内容整个换成了新的元素（换了对话；标识一样也不算）：确认不了，不动滚动位置，这一次丢掉（之后放回、丢弃都没有它）。
    func testReplacedTurnsAreNotConfirmed() async throws {
        let web = try await page(fixture())
        try await scroll(web, to: 1000)
        _ = try await hold(web, "save(1)")
        try await push(web, "/c/other")
        _ = try await js(web, "document.getElementById('scroll').innerHTML = \(jsString(thread())); 0")
        try await scroll(web, to: 2500)
        try await expect(web, "restore(1, true)", is: "unconfirmed")
        let top = try await scrollTop(web)
        XCTAssertEqual(top, 2500, accuracy: 1, "确认不了就不动")
        try await expect(web, "restore(1)", is: "none")
        try await expect(web, "discard(1)", is: false)
    }

    /// 旧的内容藏着留在页面里（ChatGPT 换页面后会这样），显示的是另一段：确认不了。
    func testTurnsLeftHiddenAreNotConfirmed() async throws {
        let web = try await page(fixture())
        try await scroll(web, to: 1000)
        _ = try await hold(web, "save(1)")
        try await push(web, "/c/other")
        _ = try await js(web, """
            document.getElementById('thread').style.display = 'none';
            document.getElementById('scroll').insertAdjacentHTML('beforeend', \(jsString(thread(prefix: "n", id: "thread2")))); 0
            """)
        try await expect(web, "restore(1, true)", is: "unconfirmed")
    }

    /// 看的是最外层的一问一答：里面的部分重画了（换了元素），外层还是原来的：确认，放回。
    func testTheOutermostTurnIsTheWitness() async throws {
        let web = try await page(fixture(nested: true))
        try await scroll(web, to: 1000)
        let first = try await row(web)
        _ = try await hold(web, "save(1)")
        try await push(web, "/c/new")
        _ = try await js(web, """
            document.querySelectorAll('.part').forEach(p => {
              const n = document.createElement('div'); n.className = 'part'; n.setAttribute('data-turn-key', p.getAttribute('data-turn-key'));
              n.append(...p.childNodes); p.replaceWith(n);
            }); 0
            """)
        try await scroll(web, to: 2500)
        try await expect(web, "restore(1, true)", is: "restored")
        let restored = try await row(web)
        XCTAssertEqual(restored, first)
    }

    /// 那一问一答还在、还显示着、标识没变，但已经不在记下时的滚动区里：确认不了。
    func testATurnOutsideTheScrollerIsNotConfirmed() async throws {
        let web = try await page(fixture())
        try await scroll(web, to: 1000)
        let reading = try await row(web)
        _ = try await hold(web, "save(1)")
        try await push(web, "/c/other")
        _ = try await js(web, "document.body.appendChild(document.getElementById('\(reading)')); 0")
        try await expect(web, "restore(1, true)", is: "unconfirmed")
    }

    /// 还是那些元素，但一问一答的标识变了：确认不了。
    func testAChangedTurnKeyIsNotConfirmed() async throws {
        let web = try await page(fixture())
        try await scroll(web, to: 1000)
        _ = try await hold(web, "save(1)")
        try await push(web, "/c/other")
        _ = try await js(web, "document.querySelectorAll('[data-turn-key]').forEach((t, i) => t.setAttribute('data-turn-key', 'x' + i)); 0")
        try await expect(web, "restore(1, true)", is: "unconfirmed")
    }

    /// 记下时视口里没有认得出的一问一答（空的新对话页、或结构认不出）：确认不了。不要求确认时照样放回（原来的行为）。
    func testWithoutATurnInViewNothingIsConfirmed() async throws {
        let web = try await page(fixture(turns: false))
        try await scroll(web, to: 1000)
        try await expect(web, "save(1)", is: true)
        try await push(web, "/c/new")
        try await expect(web, "restore(1, true)", is: "unconfirmed")

        let plain = try await page(fixture(turns: false))
        try await scroll(plain, to: 1000)
        _ = try await hold(plain, "save(1)")
        try await expect(plain, "restore(1)", is: "restored")
    }

    /// 停在对话底部时记下的（没有那块内容，只记“在底部”）：视口里的一问一答照样能确认，放回到底部。
    func testAtTheBottomTheTurnInViewStillConfirms() async throws {
        let web = try await page(fixture())
        _ = try await js(web, "const s = document.getElementById('scroll'); s.scrollTop = s.scrollHeight; 0")
        _ = try await hold(web, "save(1)")
        try await push(web, "/c/new")
        try await scroll(web, to: 500)
        try await expect(web, "restore(1, true)", is: "restored")
        let gap = try await js(web, "const b = document.getElementById('scroll'); b.scrollHeight - b.clientHeight - b.scrollTop") as? Double
        XCTAssertLessThan(try XCTUnwrap(gap), 2)
    }

    // MARK: - 放手

    /// 离开这份文档（pagehide，整页导航或进返回缓存）：放手，回来也不沿用。
    func testLeavingTheDocumentReleasesTheHold() async throws {
        let web = try await page(fixture())
        try await scroll(web, to: 1000)
        _ = try await hold(web, "save(1)")
        _ = try await js(web, "window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: true })); 0")
        try await expect(web, "restore(1)", is: "none")
        try await expect(web, "discard(1)", is: false)
    }

    /// 记下的那块内容不再显示（藏起来了）：放回时放手，不按藏起来的元素去滚动。
    func testAnAnchorThatIsNoLongerShownIsLetGo() async throws {
        let web = try await page(fixture())
        try await scroll(web, to: 1000)
        let reading = try await row(web)
        _ = try await hold(web, "save(1)")
        _ = try await js(web, "document.getElementById('\(reading)').style.display = 'none'; 0")
        let before = try await scrollTop(web)
        try await expect(web, "restore(1)", is: "none")
        let after = try await scrollTop(web)
        XCTAssertEqual(after, before, accuracy: 1)
        try await expect(web, "discard(1)", is: false)
    }

    /// 停在底部时记下的（没有那块内容），滚动区不再显示：放回时放手。
    func testAtTheBottomAScrollerThatIsNoLongerShownIsLetGo() async throws {
        let web = try await page(fixture())
        _ = try await js(web, "const s = document.getElementById('scroll'); s.scrollTop = s.scrollHeight; 0")
        _ = try await hold(web, "save(1)")
        _ = try await js(web, "document.getElementById('scroll').style.display = 'none'; 0")
        try await expect(web, "restore(1)", is: "none")
        try await expect(web, "discard(1)", is: false)
    }

    /// 再记下时只沿用还在原处的：记下的那块内容不显示了，或者（停在底部时）滚动区不显示了，都不沿用，旧编号随之放掉。
    func testASaveDoesNotReuseAHoldWhoseContentIsGone() async throws {
        let web = try await page(fixture())
        try await scroll(web, to: 1000)
        let reading = try await row(web)
        _ = try await hold(web, "save(1)")
        _ = try await js(web, "document.getElementById('\(reading)').style.display = 'none'; 0")
        try await expect(web, "save(2)", is: true)
        try await expect(web, "discard(1)", is: false)
        try await expect(web, "discard(2)", is: true)

        let bottom = try await page(fixture())
        _ = try await js(bottom, "const s = document.getElementById('scroll'); s.scrollTop = s.scrollHeight; 0")
        _ = try await hold(bottom, "save(1)")
        _ = try await js(bottom, "document.getElementById('scroll').style.display = 'none'; 0")
        try await expect(bottom, "save(2)", is: false)
        try await expect(bottom, "discard(1)", is: false)
    }

    /// 换了页面以后再记下、这次什么都没记下（找不到滚动区）：旧的那份照样放掉。
    func testASaveThatFindsNothingStillLetsGoOfTheOldOne() async throws {
        let web = try await page(fixture(), path: "/c/aaa")
        try await scroll(web, to: 1000)
        _ = try await hold(web, "save(1)")
        try await push(web, "/c/bbb")
        _ = try await js(web, "document.getElementById('scroll').style.display = 'none'; 0")
        try await expect(web, "save(2)", is: false)
        try await expect(web, "discard(1)", is: false)
    }

    // MARK: - WebRuntime 交给网页的编号

    /// 一个运行时（不看网络），网页视图里是 html。webEnhancements 关着：脚本由这里手动注入，加载完成时运行时不再注入一遍
    /// （重新注入会放掉记下的）。
    private func runtime(_ html: String, path: String = "/") async throws -> (WebRuntime, Diagnostics) {
        let name = "ReadingHoldScriptTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: name)!)
        settings.webEnhancements = false
        let diagnostics = Diagnostics()
        let runtime = WebRuntime(diagnostics: diagnostics, settings: settings, watchesNetwork: false)
        // 运行时建的网页视图是零大小（放进窗口才有大小）：给它和别的假页面一样的大小，视口里才有内容。
        runtime.webView.frame = CGRect(x: 0, y: 0, width: 720, height: 520)
        try await load(html, into: runtime.webView, path: path)
        return (runtime, diagnostics)
    }

    private func readingLines(_ diagnostics: Diagnostics) -> [String] {
        diagnostics.entries.filter { $0.category == "reading" }.map(\.message)
    }

    /// 编号从 1 起每次加一；丢弃只动给的那个编号。
    func testTheRuntimeNumbersEachSaveAndDiscardsOnlyThatNumber() async throws {
        let (r, _) = try await runtime(fixture())
        try await scroll(r.webView, to: 1000)
        let t1 = r.holdReadingPosition()
        let t2 = r.holdReadingPosition()
        XCTAssertEqual(t1, 1)
        XCTAssertEqual(t2, 2)
        r.discardReadingPosition(t1)
        try await expect(r.webView, "discard(\(t1))", is: false)
        try await expect(r.webView, "discard(\(t2))", is: true)
    }

    /// 运行时放回时带上编号：原生按规则决定放回的（例如同一个对话换了路径的写法），路径变了也放得回去，
    /// 不像不带编号的那样只认记下时的路径。
    func testTheRuntimeRestoresByNumberAfterThePathChanged() async throws {
        let (r, _) = try await runtime(fixture(), path: "/c/aaa")
        try await scroll(r.webView, to: 1000)
        let first = try await row(r.webView)
        let t1 = r.holdReadingPosition()
        try await push(r.webView, "/g/space/c/aaa")
        try await scroll(r.webView, to: 3000)
        r.restoreReadingPosition(t1)
        _ = try await js(r.webView, "0")
        let restored = try await row(r.webView)
        XCTAssertEqual(restored, first)
    }

    /// 留着一次没放回（像不显示的标签页留着的那次）时改页面缩放。对照（3.2 记下的问题）：运行时自己记下、马上放回，
    /// 自己那次和留着的共用一份记录，放回后 1.1 秒放手，留着的那次就放回不了了。
    /// 不自己记下、放回（ChatTabs 给留着阅读位置的标签页这样改）：过了那段时间，留着的那次照样放得回去。
    func testAZoomWithoutItsOwnHoldLeavesAnEarlierHoldRestorable() async throws {
        for keeping in [true, false] {
            let (r, _) = try await runtime(fixture())
            try await scroll(r.webView, to: 1000)
            let first = try await row(r.webView)
            let pending = r.holdReadingPosition()
            let holds = r.readingHolds
            r.setPageZoom(1.25, keepingReadingPosition: keeping)
            XCTAssertEqual(r.webView.pageZoom, 1.25)
            XCTAssertEqual(r.readingHolds, keeping ? holds + 1 : holds)
            try await Task.sleep(for: .milliseconds(1500))
            try await scroll(r.webView, to: 3000)
            try await expect(r.webView, "restore(\(pending))", is: keeping ? "none" : "restored")
            if !keeping {
                let restored = try await row(r.webView)
                XCTAssertEqual(restored, first)
            }
        }
    }

    /// 关闭以后不碰网页：之后的丢弃、放回（含要确认的）都不做，记下照样发编号但网页里什么都没记，也不写日志。
    func testAClosedRuntimeLeavesThePageAlone() async throws {
        let (r, diagnostics) = try await runtime(fixture())
        try await scroll(r.webView, to: 1000)
        let t1 = r.holdReadingPosition()
        r.close()
        try await scroll(r.webView, to: 3000)
        r.discardReadingPosition(t1)
        r.restoreReadingPosition(t1, confirmingContinuation: true)
        r.restoreReadingPosition(t1)
        let t2 = r.holdReadingPosition()
        XCTAssertEqual(t2, t1 + 1)
        try await Task.sleep(for: .milliseconds(200))
        let top = try await scrollTop(r.webView)
        XCTAssertEqual(top, 3000, accuracy: 1, "关闭以后不放回")
        try await expect(r.webView, "discard(\(t2))", is: false)
        try await expect(r.webView, "discard(\(t1))", is: true)
        XCTAssertEqual(readingLines(diagnostics), [])
    }

    /// 关闭前请网页确认、结果在关闭以后才回来（请求和关闭在主线程的同一段里，结果只能在关闭以后到）：
    /// 网页照样确认并放回了，但不写日志。
    func testAConfirmationAnsweredAfterCloseIsNotLogged() async throws {
        let (r, diagnostics) = try await runtime(fixture())
        try await scroll(r.webView, to: 1000)
        let first = try await row(r.webView)
        let t1 = r.holdReadingPosition()
        try await push(r.webView, "/c/new")
        try await scroll(r.webView, to: 2500)
        r.restoreReadingPosition(t1, confirmingContinuation: true)
        r.close()
        _ = try await js(r.webView, "0")
        try await Task.sleep(for: .milliseconds(200))
        let restored = try await row(r.webView)
        XCTAssertEqual(restored, first, "确认在关闭前已经发给网页")
        XCTAssertEqual(readingLines(diagnostics), [])
    }

    /// 要网页确认的放回：结果写一行日志（只有结果，没有地址和内容）。确认了、确认不了、网页里已经没有，三种各一行。
    func testAConfirmingRestoreLogsOnlyItsResult() async throws {
        let (r, diagnostics) = try await runtime(fixture())
        try await scroll(r.webView, to: 1000)
        let first = try await row(r.webView)
        let t1 = r.holdReadingPosition()
        try await push(r.webView, "/c/new")
        try await scroll(r.webView, to: 2500)
        r.restoreReadingPosition(t1, confirmingContinuation: true)
        for _ in 0..<100 where readingLines(diagnostics).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(readingLines(diagnostics), ["阅读位置：网页确认记下时看着的那段对话还在，放回"])
        let restored = try await row(r.webView)
        XCTAssertEqual(restored, first)

        _ = try await js(r.webView, "window.dispatchEvent(new PageTransitionEvent('pagehide')); 0")
        let t2 = r.holdReadingPosition()
        _ = try await js(r.webView, "document.getElementById('scroll').innerHTML = \(jsString(thread())); 0")
        r.restoreReadingPosition(t2, confirmingContinuation: true)
        r.restoreReadingPosition(t2, confirmingContinuation: true)
        for _ in 0..<100 where readingLines(diagnostics).count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(readingLines(diagnostics), [
            "阅读位置：网页确认记下时看着的那段对话还在，放回",
            "阅读位置：网页确认不了还是同一段对话，丢弃",
            "阅读位置：网页里已经没有这次记下的位置",
        ])
    }

    /// 字符串放进脚本：JSON 的写法就是合法的 JavaScript 字符串。
    private func jsString(_ s: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]), encoding: .utf8)!
    }
}
