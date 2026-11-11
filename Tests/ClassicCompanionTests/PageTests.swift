import Carbon.HIToolbox
import SwiftUI
import XCTest
import WebKit
@testable import ClassicCompanion

@MainActor
final class PageTests: XCTestCase {
    private final class Recorder: NSObject, WKScriptMessageHandler {
        var types: [String] = []
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any], let type = body["type"] as? String { types.append(type) }
        }
    }

    private func page(_ html: String, recorder: Recorder? = nil) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        if let recorder { config.userContentController.add(recorder, contentWorld: .defaultClient, name: "cc") }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 720, height: 520), configuration: config)
        web.loadHTMLString(html, baseURL: URL(string: "https://chatgpt.com/"))
        for _ in 0..<100 {
            if !web.isLoading, (try? await js(web, "document.readyState")) as? String == "complete" { return web }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Fixture did not load")
        return web
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

    private func asyncJS(_ web: WKWebView, _ body: String) async throws -> Any? {
        try await web.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    private let fixture = """
    <html><body><div id="shell">
    <aside id="history"><a href="/c/private">PRIVATE HISTORY</a></aside>
    <div><button aria-label="Show sidebar" id="toggle">Sidebar</button>
    <main id="chat"><p>Current conversation</p><span hidden id="hidden">Hidden content</span></main>
    <form><textarea name="prompt" id="composer"></textarea></form></div></div></body></html>
    """

    // 输入法组词或候选中按 Esc：只取消输入法状态，不得请求隐藏窗口，也不得让网页弹层收到这次 Esc（0219：图片预览被一起关掉）。
    // WebKit 可能在 compositionend 之后才派发 keyCode 229 的 keydown。
    func testEscapeDuringIMECompositionNeverReachesPageOrHidesWindow() async throws {
        let recorder = Recorder()
        let web = try await page(fixture, recorder: recorder)
        _ = try await js(web, AdapterScripts.escapeUserScript)
        _ = try await js(web, AdapterScripts.escapeUserScript)
        _ = try await js(web, """
            // 模拟官方弹层：在 document 捕获阶段监听 Esc（与 Radix 相同）
            document.addEventListener('keydown', e => { if (e.key === 'Escape' || e.code === 'Escape') window.__pageSeen = (window.__pageSeen || 0) + 1; }, true);
            const t = document.getElementById('composer'); t.focus(); t.value = 'SECRET-DRAFT';
            t.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true, data: 'SECRET-IME' }));
            t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', isComposing: true, bubbles: true, cancelable: true }));
            t.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '' }));
            t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Process', code: 'Escape', keyCode: 229, bubbles: true, cancelable: true }));
            t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 229, bubbles: true, cancelable: true }));
            true
            """)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(recorder.types.contains("escape"), "组词中的 Esc 不得隐藏窗口")
        let seenDuringIME = try await js(web, "window.__pageSeen || 0") as? Int
        XCTAssertEqual(seenDuringIME, 0, "输入法用掉的 Esc 不得传给网页")
        // 组词结束后的普通 Esc：网页照常收到，并按设置请求隐藏
        _ = try await js(web, "document.getElementById('composer').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true, cancelable: true })); true")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.types.filter { $0 == "escape" }.count, 1)
        let seenAfter = try await js(web, "window.__pageSeen || 0") as? Int
        XCTAssertEqual(seenAfter, 1)
        _ = try await js(web, "window.dispatchEvent(new Event('resize')); true")
        try await Task.sleep(for: .milliseconds(900))
        let trace = try await js(web, "JSON.stringify(window.__ccEscLog)") as? String ?? ""
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(trace.utf8)) as? [[String: Any]])
        let keyed = entries.filter { ["esc", "comp-start", "comp-end"].contains($0["kind"] as? String ?? "") }
        XCTAssertEqual(keyed.map { $0["kind"] as? String }, ["comp-start", "esc", "comp-end", "esc", "esc", "esc"], "重复注入不重复记录")
        XCTAssertEqual(keyed.compactMap { $0["action"] as? String }, ["ime-swallowed", "ime-swallowed", "ime-swallowed", "hide-request"])
        XCTAssertEqual(keyed.first?["target"] as? String, "composer")
        XCTAssertNotNil(keyed.last?["after"], "600ms 后补记关闭结果")
        let resize = entries.filter { ($0["kind"] as? String)?.hasPrefix("resize") == true }
        XCTAssertEqual(resize.map { $0["kind"] as? String }, ["resize-start", "resize-end"])
        XCTAssertTrue(["end", "unfocused"].contains(resize.last?["caret"] as? String ?? ""), "光标只记类别")
        XCTAssertFalse(trace.contains("SECRET"), "轨迹不含输入内容")
    }

    // 0219 实测：官方输入框把每次 Esc 都标记为已处理，导致普通聊天状态 Esc 无反应。
    func testComposerEscapeHandledByPageHidesOnlyWhenNothingIsOpen() async throws {
        let recorder = Recorder()
        let web = try await page(fixture, recorder: recorder)
        _ = try await js(web, AdapterScripts.escapeUserScript)
        func escapes() -> Int { recorder.types.filter { $0 == "escape" }.count }
        _ = try await js(web, """
            const t = document.getElementById('composer'); t.focus();
            t.addEventListener('keydown', e => { if (e.key === 'Escape') e.preventDefault(); });
            t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true, cancelable: true }));
            true
            """)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(escapes(), 1, "输入框中、没有任何弹层时，网页标记已处理的 Esc 仍按设置隐藏窗口")
        // 菜单打开时（网页用 Esc 关闭它）不隐藏窗口
        _ = try await js(web, """
            document.body.insertAdjacentHTML('beforeend', '<div role="menu" id="menu" style="position:fixed;top:0;left:0;width:50px;height:50px">m</div>');
            document.getElementById('composer').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true, cancelable: true }));
            true
            """)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(escapes(), 1)
        // 生成回答期间不隐藏
        _ = try await js(web, """
            document.getElementById('menu').remove();
            document.body.insertAdjacentHTML('beforeend', '<button data-testid="stop-button" id="stop">stop</button>');
            document.getElementById('composer').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true, cancelable: true }));
            true
            """)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(escapes(), 1)
        // 网页在输入框以外处理的 Esc 仍归网页
        _ = try await js(web, """
            document.getElementById('stop').remove();
            const b = document.getElementById('toggle'); b.addEventListener('keydown', e => e.preventDefault());
            b.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true, cancelable: true }));
            true
            """)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(escapes(), 1)
    }

    // K10：登录页面没有消息选择器；关闭预览前后的滚动位置要靠结构找到滚动区，且输入法 Esc 要记下预览是否开着。
    /// 把小窗拉到 900 及以上就切到完整模式，窗口保持拖到的大小（用户决定，2026-11-05）。
    func testDraggingQuickWideEntersFullAndKeepsSize() throws {
        let controller = ChatWindowController(webView: WKWebView(), toolbar: EmptyView(), diagnostics: Diagnostics())
        defer { controller.window?.orderOut(nil) }
        let window = try XCTUnwrap(controller.window)
        var shown: [ChatWindowController.Mode] = []
        controller.onWillShow = { mode in shown.append(mode) }
        controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))

        window.setFrame(NSRect(x: 100, y: 100, width: 899, height: 700), display: false)
        controller.enterFullIfDraggedWide()
        XCTAssertEqual(controller.mode, .quick, "不到 900 不切换")
        XCTAssertEqual(shown, [])

        window.setFrame(NSRect(x: 100, y: 100, width: 900, height: 700), display: false)
        XCTAssertEqual(controller.mode, .quick, "不是手动拖动（切模式动画、绿色按钮、系统平铺）不切换")
        controller.enterFullIfDraggedWide()
        XCTAssertEqual(controller.mode, .full)
        XCTAssertEqual(shown, [.full])
        XCTAssertEqual(window.frame.size, NSSize(width: 900, height: 700), "不跳到 1100×800")
    }

    /// 用户：完整模式拖动窗口时按 ⌃⌘F，切到小窗后立刻被当成“拉大”切回完整模式，窗口却是小窗大小。
    func testDragStartedInFullNeverSwitchesAfterGoingQuick() throws {
        let controller = ChatWindowController(webView: WKWebView(), toolbar: EmptyView(), diagnostics: Diagnostics())
        defer { controller.window?.orderOut(nil) }
        let window = try XCTUnwrap(controller.window)
        controller.show(mode: .full)
        controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        controller.show(mode: .quick)
        window.setFrame(NSRect(x: 100, y: 100, width: 1000, height: 700), display: false)
        controller.enterFullIfDraggedWide()
        XCTAssertEqual(controller.mode, .quick)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
    }

    /// 切回小窗的缩放动画也算 live resize，起点宽度超过 900 时不能被当成“拉大”。
    func testShrinkingAnimationToQuickStaysQuick() throws {
        let controller = ChatWindowController(webView: WKWebView(), toolbar: EmptyView(), diagnostics: Diagnostics())
        defer { controller.window?.orderOut(nil) }
        controller.show(mode: .full)
        controller.show(mode: .quick)
        XCTAssertEqual(controller.mode, .quick)
        XCTAssertEqual(controller.window?.frame.size, ChatWindowController.quickSize)
    }

    /// 反方向不自动：完整模式缩小后仍是完整模式，要回小窗用 ⌃⌘F。
    func testDraggingFullNarrowStaysFull() throws {
        let controller = ChatWindowController(webView: WKWebView(), toolbar: EmptyView(), diagnostics: Diagnostics())
        defer { controller.window?.orderOut(nil) }
        let window = try XCTUnwrap(controller.window)
        controller.show(mode: .full)
        window.setFrame(NSRect(x: 100, y: 100, width: 700, height: 700), display: false)
        controller.enterFullIfDraggedWide()
        XCTAssertEqual(controller.mode, .full)
    }

    // MARK: - 缩放时保持阅读位置

    /// 宽度按窗口算，缩放时文字重新换行、每行高度都变，和真实对话一样。
    private func zoomFixture() async throws -> WKWebView {
        let rows = (0..<120).map { "<div id=\"row\($0)\" style=\"padding:8px\">\(String(repeating: "word ", count: 40 + $0 % 30))</div>" }.joined()
        let web = try await page("""
            <html><body style="margin:0"><main id="chat"><div id="scroll" style="height:60vh;width:100%;overflow-y:auto">\(rows)</div></main></body></html>
            """)
        _ = try await js(web, AdapterScripts.escapeUserScript)
        return web
    }

    private func rowAtReadingLine(_ web: WKWebView) async throws -> String? {
        try await js(web, """
            (() => { const s = document.getElementById('scroll'), b = s.getBoundingClientRect(), y = b.top + b.height * 0.25;
              return [...s.children].find(r => { const q = r.getBoundingClientRect(); return q.top <= y && q.bottom > y; })?.id ?? 'none'; })()
            """) as? String
    }

    private func zoom(_ web: WKWebView, to level: Double) async throws {
        _ = try await js(web, "window.__ccReadingHold.save(); 0")
        web.pageZoom = level
        _ = try await js(web, "window.__ccReadingHold.restore(); 0")
    }

    /// xctest 不运行 NSApp，网页始终是 hidden，requestAnimationFrame 不会触发：这里只测脚本逻辑，帧换成定时器。
    /// 真实的帧要在真实窗口里验证（见 docs/phase0/gate-verification.md）。
    @MainActor private func onScreen(_ web: WKWebView) async throws -> NSWindow {
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        web.autoresizingMask = [.width, .height]
        window.contentView = web
        window.orderFrontRegardless()
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        _ = try await js(web, "window.requestAnimationFrame = frame => setTimeout(frame, 16); 0")
        return window
    }

    @MainActor private final class Flag { var value = false }

    @MainActor private func waitForLayout(_ web: WKWebView, width: Int) -> Flag {
        let flag = Flag()
        web.callAsyncJavaScript(AdapterScripts.layoutReadyScript, arguments: ["width": width], in: nil, in: .defaultClient) { _ in
            MainActor.assumeIsolated { flag.value = true }
        }
        return flag
    }

    /// 还没到目标宽度就回答的话，窗口会在新排版画好之前放大，空白又回来了。
    @MainActor func testLayoutReadyWaitsForTheTargetWidth() async throws {
        let web = try await zoomFixture()
        let window = try await onScreen(web)
        let ready = waitForLayout(web, width: 1000)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(ready.value)
        window.setContentSize(NSSize(width: 1000, height: 520))
        // 隐藏页面里连续的定时器会被限速到约每秒一次，所以这里等得比较久。
        for _ in 0..<400 where !ready.value { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(ready.value)
    }

    /// 用户（1347）：“开始播放动画之前有延迟”。日志要能看出时间花在哪一段：到达目标宽度、排版、放回阅读位置。
    /// 只报毫秒数和可滚动高度，不读正文。
    @MainActor func testLayoutReadyReportsHowLongEachStepTook() async throws {
        let web = try await zoomFixture()
        let window = try await onScreen(web)
        window.setContentSize(NSSize(width: 1000, height: 520))
        let result = try await web.callAsyncJavaScript(AdapterScripts.layoutReadyScript, arguments: ["width": 1000],
                                                        in: nil, contentWorld: .defaultClient)
        let steps = try XCTUnwrap(result as? [String: Any])
        for key in ["match", "layout", "restore", "height"] {
            XCTAssertNotNil(steps[key] as? NSNumber, key)
        }
        XCTAssertEqual(Set(steps.keys), ["match", "layout", "restore", "height"], "只有数字，没有页面内容")
    }

    /// 窗口放大时用户看到的第一帧就该是原来读到的地方。
    @MainActor func testLayoutReadyPutsTheReadingPositionBackFirst() async throws {
        let web = try await zoomFixture()
        let window = try await onScreen(web)
        _ = try await js(web, "document.getElementById('scroll').scrollTop = 3000; 0")
        // 比较这一行的顶部：窗口变宽后这一行变矮，阅读线可能落到下一行，那不算跑位。
        let reading = try await rowAtReadingLine(web)
        let row = try XCTUnwrap(reading)
        let top = "document.getElementById('\(row)').getBoundingClientRect().top"
        let before = try await js(web, top) as? Double
        _ = try await js(web, "window.__ccReadingHold.save(); 0")
        window.setContentSize(NSSize(width: 1000, height: 520))
        let ready = waitForLayout(web, width: 1000)
        for _ in 0..<100 where !ready.value { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(ready.value)
        let after = try await js(web, top) as? Double
        XCTAssertEqual(try XCTUnwrap(after), try XCTUnwrap(before), accuracy: 1)
    }

    func testPageWidthFollowsPageZoom() {
        XCTAssertEqual(WebRuntime.cssWidth(points: 1242, zoom: 1), 1242)
        XCTAssertEqual(WebRuntime.cssWidth(points: 1280, zoom: 1.25), 1024)
        XCTAssertEqual(WebRuntime.cssWidth(points: 640, zoom: 0.8), 800)
    }

    /// 用户：放大和缩小的时候会出现位移。0058 实测 ⌘+ 后视图跳到前面很远，⌘- 也回不来。
    func testZoomKeepsTheContentBeingRead() async throws {
        let web = try await zoomFixture()
        _ = try await js(web, "document.getElementById('scroll').scrollTop = 3000; 0")
        let before = try await rowAtReadingLine(web)
        try await zoom(web, to: 1.5)
        try await Task.sleep(for: .milliseconds(1200))
        let zoomedIn = try await rowAtReadingLine(web)
        XCTAssertEqual(zoomedIn, before)
        try await zoom(web, to: 1)
        try await Task.sleep(for: .milliseconds(1200))
        let zoomedBack = try await rowAtReadingLine(web)
        XCTAssertEqual(zoomedBack, before)
    }

    /// 连按 ⌘+ 时沿用第一次记下的内容，否则误差会一档档累积。
    func testRapidZoomKeepsTheFirstAnchor() async throws {
        let web = try await zoomFixture()
        _ = try await js(web, "document.getElementById('scroll').scrollTop = 3000; 0")
        let before = try await rowAtReadingLine(web)
        for level in [1.1, 1.25, 1.5] { try await zoom(web, to: level) }
        try await Task.sleep(for: .milliseconds(1200))
        let after = try await rowAtReadingLine(web)
        XCTAssertEqual(after, before)
    }

    func testZoomStaysAtTheBottomOfTheConversation() async throws {
        let web = try await zoomFixture()
        _ = try await js(web, "const s = document.getElementById('scroll'); s.scrollTop = s.scrollHeight; 0")
        try await zoom(web, to: 1.5)
        try await Task.sleep(for: .milliseconds(1200))
        let gap = try await js(web, "const b = document.getElementById('scroll'); b.scrollHeight - b.clientHeight - b.scrollTop") as? Double
        XCTAssertLessThan(try XCTUnwrap(gap), 2)
    }

    /// 用户自己滚动后要立刻放手，不能被拉回去。
    func testUserScrollingCancelsTheZoomHold() async throws {
        let web = try await zoomFixture()
        _ = try await js(web, "document.getElementById('scroll').scrollTop = 3000; 0")
        try await zoom(web, to: 1.5)
        _ = try await js(web, """
            const s = document.getElementById('scroll');
            s.dispatchEvent(new WheelEvent('wheel', { bubbles: true, deltaY: -100 }));
            s.scrollTop = 40; 0
            """)
        try await Task.sleep(for: .milliseconds(1200))
        let top = try await js(web, "document.getElementById('scroll').scrollTop") as? Double
        XCTAssertEqual(top, 40)
    }

    func testZoomHoldIsHarmlessWithoutAConversation() async throws {
        let web = try await page("<html><body><main><p>empty</p></main></body></html>")
        _ = try await js(web, AdapterScripts.escapeUserScript)
        let saved = try await js(web, "window.__ccReadingHold.save()") as? Bool
        XCTAssertEqual(saved, false)
        _ = try await js(web, "window.__ccReadingHold.restore(); 0")
    }

    /// 官方页面现在可能有两个 main（探针显示 main=2），对话不一定在第一个里，只看第一个时位置全是空的（第 5 组记录失败）。
    func testScrollIsFoundInAnyMain() async throws {
        let web = try await page("""
            <html><body style="margin:0"><main id="other"></main><main id="chat"><div id="scroll" style="height:200px;overflow-y:auto"><div style="height:1000px"></div></div></main></body></html>
            """)
        _ = try await js(web, AdapterScripts.escapeUserScript)
        let scroll = try await js(web, "document.getElementById('scroll').scrollTop = 120; JSON.stringify(window.__ccScroll())") as? String
        XCTAssertEqual(scroll, #"{"top":120,"max":800,"view":200}"#)
    }

    func testEscapeTraceRecordsScrollWithoutMessageSelectorsAndModalsDuringIME() async throws {
        let web = try await page("""
            <html><body style="margin:0"><main id="chat"><div id="scroll" style="height:200px;overflow-y:auto"><div style="height:900px">x</div></div>
            <form><textarea name="prompt" id="composer"></textarea></form></main></body></html>
            """)
        _ = try await js(web, AdapterScripts.escapeUserScript)
        _ = try await js(web, """
            document.getElementById('scroll').scrollTop = 120;
            document.body.insertAdjacentHTML('beforeend', '<div role="dialog" style="position:fixed;top:0;left:0;width:50px;height:50px">d</div>');
            const t = document.getElementById('composer');
            t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 229, bubbles: true, cancelable: true }));
            t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true, cancelable: true }));
            true
            """)
        try await Task.sleep(for: .milliseconds(750))
        let trace = try await js(web, "JSON.stringify(window.__ccEscLog.filter(e => e.kind === 'esc'))") as? String ?? ""
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(trace.utf8)) as? [[String: Any]])
        XCTAssertEqual(entries.first?["action"] as? String, "ime-swallowed")
        XCTAssertEqual(entries.first?["modals"] as? Int, 1, "输入法 Esc 也要记录弹层是否开着")
        XCTAssertEqual(entries.last?["scroll"] as? Int, 120)
        XCTAssertEqual((entries.last?["after"] as? [String: Any])?["scroll"] as? Int, 120)
    }

    // 1216 实测：隐藏时光标在末尾，唤醒后同一输入框的光标在开头。只纠正这一种情况，且不触碰用户已改动的内容。
    private let caretPage = """
    <html><body><main><form><div contenteditable="true" role="textbox" id="composer"><p>SECRET one</p><p>two</p></div></form></main></body></html>
    """
    private let caretHelpers = """
    window.__vis = 'visible';
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => window.__vis });
    window.__setVis = v => { window.__vis = v; document.dispatchEvent(new Event('visibilitychange')); };
    window.__place = at => {
      const el = document.getElementById('composer'); el.focus();
      const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT); let left = at, n = null;
      while (w.nextNode()) { n = w.currentNode; if (left <= n.length) break; left -= n.length; }
      const r = document.createRange(); r.setStart(n, left); r.collapse(true);
      const s = getSelection(); s.removeAllRanges(); s.addRange(r);
    };
    window.__at = () => {
      const el = document.getElementById('composer'), r = getSelection().getRangeAt(0);
      const p = document.createRange(); p.selectNodeContents(el); p.setEnd(r.startContainer, r.startOffset);
      return p.toString().length;
    };
    true
    """

    // MARK: - 小窗里藏起 ChatGPT 自己的侧栏和新建按钮

    /// 用户（1524）：小窗里点 Toggle Sidebar 会卡住，旁边还有个新建按钮，“小窗里面就不要有这两个按钮了”。
    /// 用户破例同意为这两个按钮改网页（2026-11-08）：只加一条样式，窄排版（不到 768 CSS 像素）里不显示，完整窗口照常。
    private let chatHeader = """
    <header>
      <button data-testid="open-sidebar-button">s</button>
      <a data-testid="create-new-chat-button" href="/" onclick="document.body.dataset.opened = '1'; return false">n</a>
      <button data-testid="model-switcher-dropdown-button">m</button>
    </header><main>x</main>
    """

    private func displays(_ web: WKWebView) async throws -> [String] {
        try await js(web, """
            ['open-sidebar-button', 'create-new-chat-button', 'model-switcher-dropdown-button']
              .map(id => getComputedStyle(document.querySelector(`[data-testid="${id}"]`)).display)
            """) as? [String] ?? []
    }

    func testQuickWindowHidesChatGPTsSidebarAndNewChatButtonsOnly() async throws {
        let web = try await page(chatHeader)   // 720 宽：小窗
        _ = try await js(web, AdapterScripts.quickHideUserScript + "\n0")
        let narrow = try await displays(web)
        XCTAssertEqual(narrow[0], "none", "侧栏按钮")
        XCTAssertEqual(narrow[1], "none", "新建按钮")
        XCTAssertNotEqual(narrow[2], "none", "别的按钮不动")

        web.frame.size.width = 1100   // 完整窗口
        for _ in 0..<50 {
            if (try await js(web, "innerWidth") as? Int ?? 0) >= 1000 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let wide = try await displays(web)
        XCTAssertFalse(wide.contains("none"), "完整窗口不藏")
    }

    func testQuickHideCanBeInjectedTwiceAndRemoved() async throws {
        let web = try await page(chatHeader)
        _ = try await js(web, AdapterScripts.quickHideUserScript + "\n0")
        _ = try await js(web, AdapterScripts.quickHideUserScript + "\n0")
        let styles = try await js(web, "document.querySelectorAll('#cc-quick-hide').length") as? Int
        XCTAssertEqual(styles, 1)
        _ = try await js(web, "window.__ccRemoveQuickHide(); 0")
        let shown = try await displays(web)
        XCTAssertFalse(shown.contains("none"), "关闭网页增强时恢复原样")
    }

    /// 顶部“新建对话”点的就是这个官方入口：藏起来以后也要能用。
    func testTopBarNewChatStillWorksWhenTheOfficialButtonIsHidden() async throws {
        let web = try await page(chatHeader)
        _ = try await js(web, AdapterScripts.quickHideUserScript + "\n0")
        let value = try await asyncJS(web, AdapterScripts.newChat)
        XCTAssertTrue(try XCTUnwrap(value as? String).contains(#""clicked":true"#))
        let opened = try await js(web, "document.body.dataset.opened") as? String
        XCTAssertEqual(opened, "1")
    }

    /// 诊断报告里能看出藏没藏住：样式在不在、藏了几个、页面宽度；认不出时列出顶部控件的 data-testid（不含文字）。
    func testProbeReportsWhetherTheButtonsAreHidden() async throws {
        let web = try await page(chatHeader)
        _ = try await js(web, AdapterScripts.quickHideUserScript + "\n0")
        let probe = try await asyncJS(web, AdapterScripts.probe)
        let json = try XCTUnwrap(probe as? String)
        let hits = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["hits"] as? [String: String])
        XCTAssertEqual(hits["quickHide"], "1/2/720")
        XCTAssertEqual(hits["headerIds"], "model-switcher-dropdown-button", "藏起来的不列，只列看得见的")
    }

    /// 1551 实测：真实页头的控件都没有 data-testid，新建按钮是 `button[aria-label="New chat"]`。
    /// 1606 实测：侧栏按钮的说明是“Show sidebar”，页头有两个看得见的这种元素（标签类型未知，所以一个用 button、一个用 role=button）。
    private let labelledHeader = """
    <header>
      <button aria-label="Show sidebar"><svg width="16" height="16"></svg></button>
      <div role="button" aria-label="Show sidebar"><svg width="16" height="16"></svg></div>
      <button aria-label="New chat"><svg width="16" height="16"></svg></button>
      <button aria-label="Model selector">Model 9</button>
      <button aria-label="Open conversation options"><svg width="16" height="16"></svg></button>
    </header><main>x</main>
    """

    func testQuickWindowHidesTheButtonsByTheirLabelsWhenThereAreNoTestIDs() async throws {
        let web = try await page(labelledHeader)
        _ = try await js(web, AdapterScripts.quickHideUserScript + "\n0")
        let shown = try await js(web, "[...document.querySelectorAll('header > *')].map(b => getComputedStyle(b).display)") as? [String] ?? []
        XCTAssertEqual(shown.count, 5)
        XCTAssertEqual(shown[0], "none", "侧栏按钮")
        XCTAssertEqual(shown[1], "none", "侧栏按钮（role=button）")
        XCTAssertEqual(shown[2], "none", "新建按钮")
        XCTAssertNotEqual(shown[3], "none", "模型按钮不动")
        XCTAssertNotEqual(shown[4], "none", "别的图标按钮不动")
    }

    /// 认不出侧栏按钮时，探针列出页头看得见的图标按钮的说明（ChatGPT 自己的按钮名，不是用户内容）；带文字的控件只记一个 T，不读文字。
    func testProbeListsIconButtonLabelsButNeverText() async throws {
        let web = try await page(labelledHeader)
        let before = try await asyncJS(web, AdapterScripts.probe)
        let hits = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(XCTUnwrap(before as? String).utf8)) as? [String: Any])?["hits"] as? [String: String])
        XCTAssertEqual(hits["headerIcons"], "Show sidebar|Show sidebar|New chat|T|Open conversation options")
        XCTAssertFalse(try XCTUnwrap(before as? String).contains("Model 9"), "不读文字")

        _ = try await js(web, AdapterScripts.quickHideUserScript + "\n0")
        let after = try await asyncJS(web, AdapterScripts.probe)
        let hidden = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(XCTUnwrap(after as? String).utf8)) as? [String: Any])?["hits"] as? [String: String])
        XCTAssertEqual(hidden["headerIcons"], "T|Open conversation options")
        XCTAssertEqual(hidden["quickHide"], "1/3/720")
    }

    func testNewChatClicksOfficialControl() async throws {
        let web = try await page("""
        <main><a data-testid="create-new-chat-button" href="/" onclick="document.body.dataset.opened = '1'; return false">x</a></main>
        """)
        let value = try await asyncJS(web, AdapterScripts.newChat)
        let result = try XCTUnwrap(value as? String)
        XCTAssertTrue(result.contains(#""clicked":true"#), result)
        let opened = try await js(web, "document.body.dataset.opened") as? String
        XCTAssertEqual(opened, "1")
    }

    func testNewChatFallsBackToHomeLinkAndReportsMissingControl() async throws {
        let home = try await page(#"<a href="/" onclick="document.body.dataset.opened = '1'; return false">x</a>"#)
        let value = try await asyncJS(home, AdapterScripts.newChat)
        let found = try XCTUnwrap(value as? String)
        XCTAssertTrue(found.contains(#""hits":[0,0,0,0,1]"#), found)
        let opened = try await js(home, "document.body.dataset.opened") as? String
        XCTAssertEqual(opened, "1")

        let missing = try await page("<main>x</main>")
        let nothing = try await asyncJS(missing, AdapterScripts.newChat)
        let none = try XCTUnwrap(nothing as? String)
        XCTAssertTrue(none.contains(#""clicked":false"#), none)
    }

    func testCaretRestoredAfterWakeWhenItJumpedToStart() async throws {
        let web = try await page(caretPage)
        _ = try await js(web, AdapterScripts.escapeUserScript)
        _ = try await js(web, caretHelpers)
        // 中间位置也要恢复，并跨越每次显示时的重复注入
        _ = try await js(web, "window.__place(12); window.__setVis('hidden'); true")
        _ = try await js(web, AdapterScripts.escapeUserScript)
        _ = try await js(web, "window.__place(0); window.__setVis('visible'); true")
        try await Task.sleep(for: .milliseconds(1100))
        let at = try await js(web, "window.__at()") as? Int
        XCTAssertEqual(at, 12)
        let trace = try await js(web, "JSON.stringify(window.__ccEscLog)") as? String ?? ""
        XCTAssertTrue(trace.contains("caret-restored"))
        XCTAssertFalse(trace.contains("SECRET"), "轨迹不含内容")
        XCTAssertFalse(trace.contains("\"at\""), "轨迹不含偏移量")
    }

    func testCaretLeftAloneWhenUserTypedComposedOrItDidNotJump() async throws {
        let web = try await page(caretPage)
        _ = try await js(web, AdapterScripts.escapeUserScript)
        _ = try await js(web, caretHelpers)
        func cycle(_ duringHidden: String) async throws -> Int? {
            _ = try await js(web, "window.__place(5); window.__setVis('hidden'); \(duringHidden) window.__setVis('visible'); true")
            try await Task.sleep(for: .milliseconds(1100))
            return try await js(web, "window.__at()") as? Int
        }
        let moved = try await cycle("window.__place(3);")
        XCTAssertEqual(moved, 3, "光标不在开头：不是这个问题，不动")
        let typed = try await cycle("document.querySelector('p').append('x'); window.__place(0);")
        XCTAssertEqual(typed, 0, "内容变了：不恢复")
        _ = try await js(web, "document.getElementById('composer').dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true })); true")
        let composing = try await cycle("window.__place(0);")
        XCTAssertEqual(composing, 0, "组词中：不动")
    }

    func testPlainEscapeMatching() throws {
        func key(_ flags: NSEvent.ModifierFlags, _ code: UInt16 = 53) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(ChatWindowController.isPlainEscape(try key([])))
        XCTAssertTrue(ChatWindowController.isPlainEscape(try key(.capsLock)))
        XCTAssertFalse(ChatWindowController.isPlainEscape(try key(.command)))
        XCTAssertFalse(ChatWindowController.isPlainEscape(try key(.shift)))
        XCTAssertFalse(ChatWindowController.isPlainEscape(try key([], 13)))
    }

    func testModeShortcutMatching() throws {
        func key(_ chars: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 3))
        }
        let standard = HotKeyCombo.modeStandard
        XCTAssertTrue(ChatWindowController.isModeShortcut(try key("f", [.command, .control]), combo: standard))
        XCTAssertTrue(ChatWindowController.isModeShortcut(try key("f", [.command, .control, .function]), combo: standard), "部分键盘带 fn 标志")
        XCTAssertTrue(ChatWindowController.isModeShortcut(try key("f", [.command, .control, .capsLock]), combo: standard))
        XCTAssertFalse(ChatWindowController.isModeShortcut(try key("f", .command), combo: standard), "⌘F 留给网页查找")
        XCTAssertFalse(ChatWindowController.isModeShortcut(try key("F", [.command, .shift]), combo: standard))
        XCTAssertFalse(ChatWindowController.isModeShortcut(try key("f", [.command, .control, .option]), combo: standard))
    }

    /// 用户改了切换键之后，只认新的组合。按键位匹配，和录制时一致，不随输入法或键盘布局变。
    func testModeShortcutFollowsTheSetting() throws {
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: code))
        }
        let controlOptionJ = HotKeyCombo(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(controlKey | optionKey))
        XCTAssertTrue(ChatWindowController.isModeShortcut(try key(UInt16(kVK_ANSI_J), [.control, .option]), combo: controlOptionJ))
        XCTAssertFalse(ChatWindowController.isModeShortcut(try key(UInt16(kVK_ANSI_F), [.control, .command]), combo: controlOptionJ))
        XCTAssertFalse(ChatWindowController.isModeShortcut(try key(UInt16(kVK_ANSI_J), [.control]), combo: controlOptionJ))
    }

    func testCommandWMatching() throws {
        func key(_ chars: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 13))
        }
        XCTAssertTrue(ChatWindowController.isCloseShortcut(try key("w", .command)))
        XCTAssertTrue(ChatWindowController.isCloseShortcut(try key("w", [.command, .capsLock])))
        XCTAssertFalse(ChatWindowController.isCloseShortcut(try key("w", [.command, .shift])))
        XCTAssertFalse(ChatWindowController.isCloseShortcut(try key("w", [.command, .option])))
        XCTAssertFalse(ChatWindowController.isCloseShortcut(try key("w", [])))
        XCTAssertFalse(ChatWindowController.isCloseShortcut(try key("q", .command)))
    }

    /// 切模式时窗口留在原屏幕（用户报告：⌘K 放大后跳到另一块屏幕，鼠标当时在那块屏幕上）。只有唤醒才跟随鼠标。
    func testVisibleWindowKeepsItsScreenWhenSwitchingMode() {
        func pick(_ modeChanged: Bool, _ visible: Bool, _ current: String?) -> String {
            ChatWindowController.screenForShow(modeChanged: modeChanged, windowVisible: visible, current: current, underMouse: "mouse")
        }
        XCTAssertEqual(pick(true, true, "window"), "window", "切模式留在原屏幕")
        XCTAssertEqual(pick(true, true, nil), "mouse", "窗口不在任何屏幕上时才看鼠标")
        XCTAssertEqual(pick(true, false, "window"), "mouse", "隐藏时切模式等于唤醒")
        XCTAssertEqual(pick(false, false, "window"), "mouse", "唤醒跟随鼠标")
        XCTAssertEqual(pick(false, true, "window"), "mouse", "激活已可见窗口保持原有行为")
    }

    /// “+” 的官方层没有 role，也不在 Radix 包装里（1032 实测）：一层 display:contents，一层 fixed，里面才是标记。
    private func plusLayer(_ items: String = "<button id=\"pi\">Add</button><img id=\"pimg\" alt=\"\">") -> String {
        "<div id=\"portal\" style=\"display:contents\"><div style=\"position:fixed\"><div data-composer-overlay-floating-ui id=\"layer\"><div data-mention-list-scroll-area>\(items)</div></div></div></div>"
    }

    private let plusOpener = """
        document.querySelector('form').insertAdjacentHTML('beforeend', '<button type="button" id="plus" aria-expanded="true" data-state="open">+</button>');
        """

    /// 用户报告：“+” 开着时按 Esc 关掉了整个窗口。网页标记已处理也好、没标记也好，这次 Esc 都归网页。
    func testEscapeWithPlusLayerOpenKeepsWindow() async throws {
        let recorder = Recorder()
        let web = try await page(fixture, recorder: recorder)
        _ = try await js(web, AdapterScripts.escapeUserScript)
        let esc = "document.getElementById('composer').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true, cancelable: true })); true"
        _ = try await js(web, """
            \(plusOpener) document.body.insertAdjacentHTML('beforeend', `\(plusLayer())`);
            const t = document.getElementById('composer'); t.focus();
            t.addEventListener('keydown', e => { if (e.key === 'Escape') e.preventDefault(); });
            \(esc)
            """)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(recorder.types.contains("escape"), "“+” 开着不得隐藏窗口")
        _ = try await js(web, "document.getElementById('portal').remove(); document.getElementById('plus').remove(); \(esc)")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.types.filter { $0 == "escape" }.count, 1, "关闭后仍按设置隐藏")
    }

    /// 官方搜索框（1115 Chrome 实测）：body 下一层 display:contents，里面是遮暗层和 dialog；输入框是 combobox，结果在 listbox。
    private func searchPortal(_ extra: String = "") -> String {
        "<div id=\"portal\" style=\"display:contents\"><div id=\"dim\" aria-hidden=\"true\" style=\"position:fixed;inset:0\"></div><div role=\"dialog\" aria-modal=\"true\" id=\"box\" style=\"position:fixed;top:50px\"><input role=\"combobox\" aria-autocomplete=\"list\" aria-controls=\"r\" id=\"q\"><div role=\"listbox\" id=\"r\"><a href=\"/c/old?src=history_search\" id=\"hit\">Title</a></div>\(extra)</div></div>"
    }

    func testEscapeInQuickSearchClosesItAndKeepsWindow() async throws {
        let recorder = Recorder()
        let web = try await page(fixture, recorder: recorder)
        _ = try await js(web, AdapterScripts.escapeUserScript)
        let closed = try await js(web, """
            document.body.insertAdjacentHTML('beforeend', `\(searchPortal())`);
            const q = document.getElementById('q'); q.focus();
            document.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); document.getElementById('portal')?.remove(); } });
            q.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true, cancelable: true }));
            !document.getElementById('portal')
            """) as? Bool
        XCTAssertEqual(closed, true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(recorder.types.contains("escape"), "不得隐藏窗口")
    }

    func testEscapeReinjectionAndDisable() async throws {
        let web = try await page(fixture)
        _ = try await js(web, AdapterScripts.escapeUserScript)
        _ = try await js(web, AdapterScripts.escapeUserScript)
        let installed = try await js(web, "typeof window.__ccRemoveEscape === 'function'") as? Bool
        XCTAssertEqual(installed, true)
        _ = try await js(web, "window.__ccRemoveEscape()")
        let removed = try await js(web, "typeof window.__ccRemoveEscape === 'undefined'") as? Bool
        XCTAssertEqual(removed, true)
    }
}
