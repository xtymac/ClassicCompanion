// 只编进开发版：发布版不带（发布回归 2026-11-08，用户选“收起两项”）。打开后本机任何进程都能用通知往网页发鼠标事件。
#if DEBUG
import AppKit
import WebKit

/// TEMPORARY investigation hook (sidebar jank). Enabled only with
/// `defaults write local.classiccompanion.ClassicCompanion debugDriver -bool true`.
/// Commands arrive as local distributed notifications `local.classiccompanion.debug`.
@MainActor
final class DebugDriver {
    private let windowController: ChatWindowController
    private let webView: WKWebView
    private let out: URL

    init(windowController: ChatWindowController, webView: WKWebView) {
        self.windowController = windowController
        self.webView = webView
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClassicCompanion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        out = dir.appendingPathComponent("debug-trace.txt")
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.classiccompanion.debug"), object: nil, queue: .main
        ) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.handle(command) }
        }
        write("driver ready")
    }

    private func write(_ line: String) {
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: out) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: out) }
    }

    private func handle(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "show-full": windowController.show(mode: .full); write("show-full")
        case "show-quick": windowController.show(mode: .quick); write("show-quick")
        case "hide": windowController.hide(reason: "调试"); write("hide")
        case "click":
            let xy = arg.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { return }
            click(CGPoint(x: xy[0], y: xy[1]))
        case "move":
            let xy = arg.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { return }
            click(CGPoint(x: xy[0], y: xy[1]), moveOnly: true)
        case "watch": Task { await watch(seconds: Int(arg) ?? 30) }
        case "escape": key(53, "\u{1b}")
        case "scroll-to": Task { await scroll(top: Int(arg) ?? 0) }
        case "reveal": Task { await reveal(arg) }
        case "native": write("native \(nativeState())")
        case "trace": Task { await trace(arg) }
        // Never execute arbitrary scripts or persist untrusted command payloads.
        default: write("rejected unknown command")
        }
    }

    /// Gate B：只允许这些元素类型，不接受任意选择器。只返回几何信息，不含正文。
    private static let revealKinds: Set<String> = ["table", "pre", ".katex-display", ".katex", "main img"]

    private func scroll(top: Int) async {
        await runScroll(kind: "", index: 0, top: top, label: "scroll-to \(top)")
    }

    /// 参数形如 `table#0`：把第 0 个同类元素滚到视口中央。
    private func reveal(_ arg: String) async {
        let parts = arg.split(separator: "#", maxSplits: 1).map(String.init)
        guard let kind = parts.first, Self.revealKinds.contains(kind) else { return write("rejected reveal") }
        await runScroll(kind: kind, index: parts.count > 1 ? Int(parts[1]) ?? 0 : 0, top: 0, label: "reveal \(arg)")
    }

    private func runScroll(kind: String, index: Int, top: Int, label: String) async {
        let result = try? await webView.callAsyncJavaScript(Self.scrollScript, arguments: ["kind": kind, "index": index, "top": top],
                                                            contentWorld: .defaultClient)
        write("\(label) \(result as? String ?? "nil")")
    }

    static let scrollScript = """
    const box = document.querySelector('.thread-scroll-container');
    if (!box) return 'no-scroller';
    const list = kind ? [...document.querySelectorAll(kind)] : [];
    if (kind) {
      if (!list[index]) return JSON.stringify({ count: list.length, missing: index });
      list[index].scrollIntoView({ block: 'center', behavior: 'instant' });
    } else if (top === 0) {
      // 官方对话按需加载旧消息：滚到顶后高度还会变，等它稳定。
      let height = -1;
      for (let step = 0; step < 40; step++) {
        box.scrollTo({ top: 0, behavior: 'instant' });
        await new Promise(done => setTimeout(done, 500));
        if (box.scrollTop === 0 && box.scrollHeight === height) break;
        height = box.scrollHeight;
      }
    } else {
      box.scrollTo({ top, behavior: 'instant' });
    }
    await new Promise(done => setTimeout(done, 300));
    return JSON.stringify({ count: list.length, top: Math.round(box.scrollTop), max: box.scrollHeight - box.clientHeight, view: box.clientHeight });
    """

    private func nativeState() -> String {
        guard let w = windowController.window else { return "no-window" }
        return "wid=\(w.windowNumber) visible=\(w.isVisible) key=\(w.isKeyWindow) appActive=\(NSApp.isActive) occluded=\(!w.occlusionState.contains(.visible)) webHidden=\(webView.isHidden) hiddenAncestor=\(webView.isHiddenOrHasHiddenAncestor) frame=\(Int(w.frame.width))x\(Int(w.frame.height)) web=\(Int(webView.frame.width))x\(Int(webView.frame.height)) mode=\(windowController.mode) fr=\(type(of: w.firstResponder as Any))"
    }

    /// Real AppKit mouse events through WKWebView's normal hit-testing (CSS px == points at zoom 1).
    private func click(_ p: CGPoint, moveOnly: Bool = false) {
        guard let window = windowController.window else { return }
        let local = webView.isFlipped ? p : CGPoint(x: p.x, y: webView.bounds.height - p.y)
        let loc = webView.convert(local, to: nil)
        let types: [NSEvent.EventType] = moveOnly ? [.mouseMoved] : [.mouseMoved, .leftMouseDown, .leftMouseUp]
        for type in types {
            if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                          pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(e)
            }
        }
        write("\(moveOnly ? "move" : "click") \(Int(p.x)),\(Int(p.y)) -> window \(Int(loc.x)),\(Int(loc.y))")
    }

    /// Continuous recorder for a real-user repro: input events, sidebar panel state transitions,
    /// janky frames, event-loop stalls and native window/cover changes. UI chrome only, no text.
    private func watch(seconds: Int) async {
        write("watch start \(seconds)s native \(nativeState())")
        _ = try? await webView.callAsyncJavaScript(Self.watchInstall, contentWorld: .defaultClient)
        var lastNative = ""
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < end {
            let n = nativeState()
            if n != lastNative { write("watch native \(n)"); lastNative = n }
            if let lines = try? await webView.callAsyncJavaScript("return window.__ccWatch ? window.__ccWatch.drain() : 'not-installed'", contentWorld: .defaultClient) as? String, !lines.isEmpty {
                write("watch page\n" + lines)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        _ = try? await webView.callAsyncJavaScript("window.__ccWatch?.stop(); return true", contentWorld: .defaultClient)
        write("watch end")
    }

    static let watchInstall = """
    window.__ccWatch?.stop();
    const t0 = performance.now(), log = [], ts = () => Math.round(performance.now() - t0);
    const safe = /^(Toggle sidebar|Open sidebar|Close sidebar|Show sidebar|Hide sidebar|Usage|Open profile menu|Project sidebar options|Chat sidebar options|Search chats|New chat)$/;
    const desc = el => {
      if (!(el instanceof Element)) return String(el && el.nodeName);
      const b = el.closest('button, a, [role="button"], input, textarea, [contenteditable="true"]') || el;
      const label = b.getAttribute('aria-label') || '';
      const rail = b.closest('#app-shell-sidebar') ? (b.closest('nav')?.getBoundingClientRect().width < 80 ? 'rail:' : 'panel:') : '';
      return rail + b.tagName.toLowerCase() + (b.getAttribute('data-testid') ? '[' + b.getAttribute('data-testid') + ']' : '') +
        (label ? '"' + (safe.test(label) ? label : 'label') + '"' : '') + (b.getAttribute('aria-expanded') ? ' exp=' + b.getAttribute('aria-expanded') : '');
    };
    let lastInput = null;
    const onEvent = e => {
      if (e.type === 'keydown' && e.key !== 'Escape') return;
      lastInput = { type: e.type, at: performance.now() };
      log.push(ts() + ' ev ' + e.type + (e.key ? ':' + e.key : '') + ' ' + desc(e.target) + (e.defaultPrevented ? ' prevented' : '') + (e.isTrusted ? '' : ' untrusted'));
    };
    const types = ['pointerdown', 'pointerup', 'click', 'keydown'];
    types.forEach(t => window.addEventListener(t, onEvent, true));
    let enterCount = 0;
    const onEnter = e => { if (e.target instanceof Element && e.target.closest('#app-shell-sidebar')) enterCount++; };
    window.addEventListener('pointerover', onEnter, true);
    // Panel state: the expanded nav loses/gains inert.
    const panelState = () => [...document.querySelectorAll('#app-shell-sidebar nav')].map(n => Math.round(n.getBoundingClientRect().width) + (n.closest('[inert]') ? 'i' : '')).join('/') +
      ' dialogs=' + document.querySelectorAll('[role="dialog"]').length + ' inert=' + document.querySelectorAll('[inert]').length;
    let lastState = panelState();
    log.push(ts() + ' state ' + lastState);
    const mo = new MutationObserver(() => {
      const s = panelState();
      if (s !== lastState) {
        log.push(ts() + ' state ' + s + (lastInput ? ' (+' + Math.round(performance.now() - lastInput.at) + 'ms after ' + lastInput.type + ')' : ''));
        lastState = s;
      }
    });
    mo.observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['inert', 'data-state', 'aria-expanded', 'style', 'class'] });
    // Frame pacing and main-thread stalls.
    let running = true, last = performance.now(), frames = 0, jank = 0, worst = 0;
    const raf = now => { const gap = now - last; last = now; frames++; if (gap > 50) { jank++; worst = Math.max(worst, gap); if (gap > 120) log.push(ts() + ' frame-gap ' + Math.round(gap) + 'ms vis=' + document.visibilityState); } if (running) requestAnimationFrame(raf); };
    requestAnimationFrame(raf);
    let tick = performance.now();
    const iv = setInterval(() => { const now = performance.now(), d = now - tick - 100; tick = now; if (d > 80) log.push(ts() + ' loop-stall ' + Math.round(d) + 'ms'); }, 100);
    const onVis = () => log.push(ts() + ' visibility ' + document.visibilityState);
    document.addEventListener('visibilitychange', onVis);
    let lastSummary = performance.now();
    window.__ccWatch = {
      drain() {
        const now = performance.now();
        if (now - lastSummary > 2000) {
          log.push(ts() + ' fps=' + Math.round(frames * 1000 / (now - lastSummary)) + ' jank=' + jank + ' worst=' + Math.round(worst) + ' sidebarHover=' + enterCount + ' vis=' + document.visibilityState + ' focus=' + document.hasFocus());
          frames = 0; jank = 0; worst = 0; enterCount = 0; lastSummary = now;
        }
        return log.splice(0).join('\\n');
      },
      stop() { running = false; clearInterval(iv); mo.disconnect(); types.forEach(t => window.removeEventListener(t, onEvent, true));
        window.removeEventListener('pointerover', onEnter, true); document.removeEventListener('visibilitychange', onVis); delete window.__ccWatch; },
    };
    return true;
    """

    private func key(_ code: UInt16, _ chars: String) {
        guard let window = windowController.window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                window.sendEvent(e)
            }
        }
        write("key \(code)")
    }

    /// Samples UI-chrome state only (sidebar control labels, geometry, animation and frame metrics); no message text.
    private func trace(_ label: String) async {
        write("trace[\(label)] native \(nativeState())")
        for delay in [0, 150, 500, 1200, 2500] {
            let t0 = Date()
            do {
                let r = try await webView.callAsyncJavaScript(Self.probe, contentWorld: .defaultClient)
                write("trace[\(label)] +\(delay)ms (\(Int(Date().timeIntervalSince(t0) * 1000))ms) \(r as? String ?? "nil")")
            } catch {
                write("trace[\(label)] +\(delay)ms error \(error)")
            }
            try? await Task.sleep(for: .milliseconds(delay == 0 ? 150 : 350))
        }
    }

    static let probe = """
    const desc = el => !el ? null : el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (el.getAttribute('data-testid') ? '[' + el.getAttribute('data-testid') + ']' : '');
    const ctrls = [...document.querySelectorAll('button, [role="button"]')].filter(b =>
      /sidebar|サイドバー|侧边栏|側邊欄/i.test((b.getAttribute('aria-label') || '') + ' ' + (b.getAttribute('data-testid') || '')));
    const controls = ctrls.map(b => {
      const r = b.getBoundingClientRect(), cx = r.x + r.width / 2, cy = r.y + r.height / 2;
      const hit = r.width ? document.elementFromPoint(cx, cy) : null;
      return { label: b.getAttribute('aria-label'), testid: b.getAttribute('data-testid'), exp: b.getAttribute('aria-expanded'),
        x: Math.round(cx), y: Math.round(cy), w: Math.round(r.width), hit: !!hit && (hit === b || b.contains(hit)),
        hitEl: hit && !(hit === b || b.contains(hit)) ? desc(hit) : undefined, inert: !!b.closest('[inert]'), ah: !!b.closest('[aria-hidden="true"]') };
    });
    const panes = [...document.querySelectorAll('nav, [id*="sidebar" i], [data-testid*="sidebar" i]')].slice(0, 6).map(el => {
      const r = el.getBoundingClientRect(), cs = getComputedStyle(el);
      return { el: desc(el), x: Math.round(r.x), w: Math.round(r.width), vis: cs.visibility, op: cs.opacity,
        tf: cs.transform === 'none' ? undefined : cs.transform, tr: cs.transitionDuration, inert: el.closest('[inert]') ? 1 : 0 };
    });
    const anims = document.getAnimations();
    const running = anims.filter(a => a.playState === 'running').slice(0, 8).map(a => ({
      k: a.constructor.name, n: a.animationName || a.transitionProperty || a.id || '', t: Math.round(a.currentTime ?? -1),
      target: desc(a.effect?.target) }));
    // Frame and event-loop health over 400ms.
    let frames = 0, maxGap = 0, last = performance.now();
    const stop = performance.now() + 400;
    await new Promise(resolve => { const tick = now => { frames++; maxGap = Math.max(maxGap, now - last); last = now; if (now < stop) requestAnimationFrame(tick); else resolve(); }; requestAnimationFrame(tick); setTimeout(resolve, 1500); });
    let lag = 0; for (let i = 0; i < 5; i++) { const s = performance.now(); await new Promise(r => setTimeout(r, 0)); lag = Math.max(lag, performance.now() - s); }
    return JSON.stringify({ vis: document.visibilityState, focus: document.hasFocus(), iw: innerWidth, dpr: devicePixelRatio,
      reduce: matchMedia('(prefers-reduced-motion: reduce)').matches, rafIn400: frames, maxFrameGap: Math.round(maxGap), timerLag: Math.round(lag),
      dialogs: document.querySelectorAll('[role="dialog"]').length, inert: document.querySelectorAll('[inert]').length,
      active: desc(document.activeElement), anims: anims.length, running, controls, panes });
    """
}
#endif
