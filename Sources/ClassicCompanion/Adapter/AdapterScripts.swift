// 所有 ChatGPT 网页 DOM 选择器与脚本集中于此文件。
// 脚本运行在 WKContentWorld.defaultClient（隔离世界）：与网页共享 DOM，但网页脚本无法读取或篡改这里的变量和函数。
// 选择器均为对当前官方网页的假设，必须经 Phase 0 实测确认；无法确认时返回 "unrecognized"，由原生层禁用相应功能。

enum AdapterScripts {
    /// 等网页按目标宽度画好一帧，放回阅读位置，再画一帧。窗口放大时用户看到的第一帧就该是新排版。
    /// 通过 callAsyncJavaScript 运行，width 是调用时传入的 CSS 像素宽度。只读窗口宽度，不碰页面内容。
    /// 返回每一段的毫秒数和可滚动高度，写进诊断日志，用来查动画前的等待花在哪里（用户 2026-11-08）。只有数字。
    static let layoutReadyScript = """
    const t0 = performance.now();
    const frames = () => new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done)));
    await new Promise(done => {
      const check = () => Math.abs(window.innerWidth - width) <= 2 ? done() : requestAnimationFrame(check);
      check();
    });
    const matched = performance.now();
    await frames();
    const laidOut = performance.now();
    window.__ccReadingHold?.restore();
    await frames();
    const end = performance.now();
    const scroll = window.__ccScroll?.();
    return { match: Math.round(matched - t0), layout: Math.round(laidOut - matched), restore: Math.round(end - laidOut),
             height: scroll ? scroll.max : -1 };
    """

    /// 共享的选择器定义（每个脚本开头拼接）
    static let selectors = """
    // 每项为候选列表，按优先级排列；不依赖单一选择器。
    // 2026-11-03 实测（未登录页面）：输入框为 textarea#mobile-composer-prompt[name=prompt]，页面无 data-testid。
    // 登录后的 DOM 尚未实测，以下其余候选来自既往结构，须以诊断报告中的“选择器命中”确认。
    const CAND = {
      input: ['#prompt-textarea', 'textarea[name="prompt"]', 'form [contenteditable="true"][role="textbox"]', 'form [contenteditable="true"]', 'form textarea'],
      message: ['[data-message-author-role]'],
      assistant: ['[data-message-author-role="assistant"]'],
      user: ['[data-message-author-role="user"]'],
      streaming: ['[data-testid="stop-button"]', '.result-streaming', 'button[aria-label="Stop streaming"]', 'button[aria-label="Stop generating"]'],
      turn: ['[data-testid^="conversation-turn-"]', 'article', 'section[data-turn]', '[data-turn]'],
      completion: ['[data-testid="copy-turn-action-button"]', '[data-testid="good-response-turn-action-button"]', '[data-testid="bad-response-turn-action-button"]'],
      overlay: ['[role="dialog"]', '[role="alertdialog"]', '[role="menu"]', '[role="listbox"]', '[data-radix-popper-content-wrapper]', '[data-composer-overlay-floating-ui]'],
      loginButton: ['[data-testid="login-button"]'],
      markdown: ['.markdown'],
      // 小窗（窄排版）页头里 ChatGPT 自己的侧栏按钮和新建按钮，小窗里藏起来（见 quickHideUserScript）。
      // 1606 实测：说明是“Show sidebar”，页头有两个看得见的这种元素，不限标签类型。旧写法留作兜底；按用户叫法猜的“Toggle sidebar”没命中，已去掉。
      sidebarToggle: ['[aria-label="Show sidebar" i]', '[data-testid="open-sidebar-button"]', 'button[aria-label="Open sidebar" i]'],
      headerNewChat: ['[data-testid="create-new-chat-button"]', 'a[aria-label="New chat"]', 'button[aria-label="New chat"]'],
    };
    const SEL = Object.fromEntries(Object.entries(CAND).map(([k, v]) => [k, v.join(', ')]));
    const visible = (el) => !!el && (el.offsetWidth > 0 || el.offsetHeight > 0 || el.getClientRects().length > 0);
    // 按优先级取第一个可见元素
    function pick(list) {
      for (const s of list) {
        const el = Array.from(document.querySelectorAll(s)).find(visible);
        if (el) return el;
      }
      return null;
    }
    """

    /// 页面能力探测：只返回布尔值与计数，不返回任何正文。
    static let probe = selectors + """
    const input = pick(CAND.input);
    const active = document.activeElement;
    // 选择器命中数：仅数量，用于登录后确认适配是否仍有效
    const hits = {};
    for (const [k, list] of Object.entries(CAND)) {
      hits[k] = list.map(s => { try { return document.querySelectorAll(s).length; } catch (e) { return -1; } }).join('/');
    }
    // 小窗藏按钮：样式在不在 / 藏住了几个 / 页面宽度。认不出时看 headerIds：页头看得见的控件的 data-testid，不含文字。
    const hidden = [...document.querySelectorAll(CAND.sidebarToggle.concat(CAND.headerNewChat).join(', '))]
      .filter(el => getComputedStyle(el).display === 'none').length;
    hits.quickHide = (document.getElementById('cc-quick-hide') ? 1 : 0) + '/' + hidden + '/' + innerWidth;
    const header = [...document.querySelectorAll('button, a, [role="button"]')]
      .filter(el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.top >= 0 && r.bottom <= 72; });
    hits.headerIds = header.map(el => (el.getAttribute('data-testid') || '?').replace(/[0-9a-f-]{8,}/gi, '<id>')).join('|') || '-';
    // 页头看得见的图标按钮的说明（ChatGPT 自己的按钮名，不超过 40 字）；带文字的控件只记 T，不读文字。
    hits.headerIcons = header.map(el => el.innerText.trim() ? 'T' : (el.getAttribute('aria-label') || '-').slice(0, 40)).join('|') || '-';
    return JSON.stringify({
      hits,
      host: location.hostname,
      inputFound: !!input,
      inputFocused: !!input && (active === input || input.contains(active)),
      messageCount: document.querySelectorAll(SEL.message).length,
      assistantCount: document.querySelectorAll(SEL.assistant).length,
      streaming: !!document.querySelector(SEL.streaming),
      overlayOpen: !!pick(CAND.overlay),
      loginButtonVisible: !!document.querySelector(SEL.loginButton),
    });
    """

    /// 小窗里藏起 ChatGPT 页头自己的侧栏按钮和新建按钮。用户 1524：小窗里点侧栏会卡住，“小窗里面就不要有这两个按钮了”，
    /// 并破例同意为这两个按钮改网页（2026-11-08）。只加一条样式，不删除、不移动元素；
    /// 只在 ChatGPT 的窄排版（不到 768 CSS 像素，即小窗）生效，完整窗口照常。藏起来的新建按钮仍可被顶部“新建对话”点击。
    /// 可重复注入；关闭网页增强时用 __ccRemoveQuickHide 拿掉。
    static let quickHideUserScript = "(() => {\n" + selectors + """
      const id = 'cc-quick-hide';
      if (!document.getElementById(id)) {
        const style = document.createElement('style');
        style.id = id;
        style.textContent = '@media (max-width: 767.98px) { ' + CAND.sidebarToggle.concat(CAND.headerNewChat).join(', ')
          + ' { display: none !important; } }';
        (document.head || document.documentElement).appendChild(style);
      }
      window.__ccRemoveQuickHide = () => document.getElementById(id)?.remove();
    })();
    """

    /// 聚焦官方输入框。页面有对话框或其他输入控件已获焦点时不抢焦点（例如登录框）。
    /// 官方“新对话”入口：点击后由官方页面在页内切换，不重新加载。
    /// data-testid 和 href 不随界面语言变化，`a[href="/"]` 是结构兜底。只统计命中数，不读文字。
    static let newChat = #"""
    const selectors = ['a[data-testid="create-new-chat-button"]', 'button[data-testid="create-new-chat-button"]',
                       'a[aria-label="New chat"]', 'button[aria-label="New chat"]', 'a[href="/"]'];
    const hits = selectors.map(s => document.querySelectorAll(s).length);
    const control = selectors.map(s => document.querySelector(s)).find(Boolean);
    control?.click();
    return JSON.stringify({ clicked: !!control, hits });
    """#

    static let focusInput = selectors + """
    const input = pick(CAND.input);
    if (!input) return JSON.stringify({ ok: false, reason: 'input-not-found' });
    if (pick(['[role="dialog"]', '[role="alertdialog"]'])) return JSON.stringify({ ok: false, reason: 'dialog-open' });
    const a = document.activeElement;
    if (a && a !== document.body && a !== input && !input.contains(a) &&
        a.matches('input, textarea, select, [contenteditable="true"], [contenteditable=""]')) {
      return JSON.stringify({ ok: false, reason: 'other-field-focused' });
    }
    if (a === input || input.contains(a)) return JSON.stringify({ ok: true, reason: 'already-focused' });
    input.focus({ preventScroll: true });
    try {
      if (input.tagName === 'TEXTAREA') {
        input.selectionStart = input.selectionEnd = input.value.length;
      } else {
        const r = document.createRange(); r.selectNodeContents(input); r.collapse(false);
        const s = getSelection(); s.removeAllRanges(); s.addRange(r);
      }
    } catch (e) {}
    return JSON.stringify({ ok: true, reason: 'focused' });
    """

    /// 定位“最新一条已完成的助手回答”。返回 {status, ref, blocks}。
    /// status: ok / no-messages / awaiting-answer / streaming / unrecognized(reason)
    /// 定位条件：最后一条消息是助手消息；页面无生成中标记；所在 turn 具有完成标记与 message id。
    static let locateCommon = selectors + """
    function locate() {
      const all = Array.from(document.querySelectorAll(SEL.message));
      if (all.length === 0) return { status: 'no-messages' };
      const last = all[all.length - 1];
      if (last.getAttribute('data-message-author-role') !== 'assistant') return { status: 'awaiting-answer' };
      if (document.querySelector(SEL.streaming)) return { status: 'streaming' };
      const turn = last.closest(SEL.turn);
      if (!turn) return { status: 'unrecognized', reason: 'turn-container-not-found' };
      if (turn.querySelector(SEL.user)) return { status: 'unrecognized', reason: 'turn-contains-user-message' };
      if (!turn.querySelector(SEL.completion)) return { status: 'unrecognized', reason: 'completion-marker-missing' };
      const msgs = Array.from(turn.querySelectorAll(SEL.assistant));
      const ids = msgs.map(m => m.getAttribute('data-message-id') || '');
      if (ids.some(id => !id)) return { status: 'unrecognized', reason: 'message-id-missing' };
      return { status: 'ok', turn, msgs, ref: { path: location.pathname, ids: ids.join(',') } };
    }
    """

    static let verify = locateCommon + """
    const r = locate();
    if (r.status !== 'ok') return JSON.stringify({ status: r.status });
    return JSON.stringify({ status: 'ok', path: r.ref.path, ids: r.ref.ids });
    """

    /// 【历史探索代码，不在正式路径】曾用于系统 TTS 的全文提取。1.2 版计划要求使用官方 Read Aloud，此脚本不再调用。
    /// 把回答 DOM 转成朗读块。只读取可见内容；代码、公式、图片、复杂表格、非 Markdown 组件以提示代替。
    static let extract = locateCommon + """
    const r = locate();
    if (r.status !== 'ok') return JSON.stringify({ status: r.status, reason: r.reason || null });

    const blocks = [];
    let buf = '';
    const notice = t => { flush(); blocks.push({ kind: 'notice', text: t }); };
    function flush() {
      const t = buf.replace(/[ \\t\\u00a0]+/g, ' ').replace(/\\s*\\n\\s*/g, '\\n').trim();
      if (t) blocks.push({ kind: 'text', text: t });
      buf = '';
    }
    function isHidden(el) {
      if (el.classList.contains('sr-only')) return true;
      if (el.getAttribute('aria-hidden') === 'true') return true;
      const cs = getComputedStyle(el);
      return cs.display === 'none' || cs.visibility === 'hidden';
    }
    const BLOCK = new Set(['P','H1','H2','H3','H4','H5','H6','LI','BLOCKQUOTE','DIV','SECTION','UL','OL','DL','DT','DD','FIGURE','FIGCAPTION','HR','DETAILS','SUMMARY']);

    function cellText(c) { return (c.innerText || '').replace(/\\s+/g, ' ').trim(); }
    function table(t) {
      const rows = Array.from(t.rows);
      const complex = t.querySelector('table') || Array.from(t.querySelectorAll('th,td')).some(c => c.colSpan > 1 || c.rowSpan > 1);
      if (complex || rows.length < 2) { notice('表格已跳过'); return; }
      const head = Array.from(rows[0].cells).map(cellText);
      if (head.some(h => !h)) { notice('表格已跳过'); return; }
      const MAX = 30;
      blocks.push({ kind: 'notice', text: '以下为表格内容' });
      rows.slice(1, MAX + 1).forEach(row => {
        const cells = Array.from(row.cells).map(cellText);
        const parts = cells.map((v, i) => (head[i] ? head[i] + '：' : '') + v).filter(p => p.trim());
        if (parts.length) blocks.push({ kind: 'text', text: parts.join('，') });
      });
      if (rows.length - 1 > MAX) notice('表格其余行已跳过');
    }

    function visit(node) {
      if (node.nodeType === Node.TEXT_NODE) { buf += node.nodeValue; return; }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      const el = node;
      // KaTeX 的可视部分带 aria-hidden，需在隐藏判断之前处理
      if (el.matches('.katex-display')) { notice('公式已跳过'); return; }
      if (el.matches('.katex, math, mjx-container')) { buf += '（公式）'; return; }
      if (isHidden(el)) return;
      const tag = el.tagName;
      if (tag === 'PRE') { notice('代码块已跳过'); return; }
      if (tag === 'TABLE') { flush(); table(el); return; }
      if (tag === 'IMG' || tag === 'PICTURE' || tag === 'VIDEO' || tag === 'CANVAS' || tag === 'IFRAME') { notice('图片或媒体已跳过'); return; }
      if (tag === 'svg' || tag === 'SVG' || tag === 'BUTTON' || tag === 'STYLE' || tag === 'SCRIPT') return;
      if (tag === 'BR') { buf += '\\n'; return; }
      if (tag === 'A') { buf += (el.innerText || ''); return; } // 只读可见标题，不读 URL
      const block = BLOCK.has(tag);
      if (block) flush();
      for (const c of el.childNodes) visit(c);
      if (block) flush();
    }

    for (const m of r.msgs) {
      const mds = Array.from(m.querySelectorAll(SEL.markdown)).filter(md => !isHidden(md));
      if (mds.length === 0) { notice('非文本内容或交互组件已跳过'); continue; }
      for (const md of mds) { visit(md); flush(); }
      // Markdown 之外的可见媒体/组件
      const extras = Array.from(m.querySelectorAll('img, iframe, canvas, video')).filter(e => !e.closest(SEL.markdown) && !isHidden(e));
      if (extras.length) notice('回答附带的图片或组件已跳过');
    }
    if (!blocks.some(b => b.kind === 'text')) return JSON.stringify({ status: 'unrecognized', reason: 'no-readable-text' });
    return JSON.stringify({ status: 'ok', path: r.ref.path, ids: r.ref.ids, blocks });
    """

    /// 用户脚本：Esc 处理。
    /// - 捕获阶段记录按下时的状态（IME 组合中、网页弹层是否打开），防止网页先关闭弹层后被误判为普通聊天状态。
    /// - 冒泡阶段：仅当非 IME 组合、无弹层、网页未 preventDefault 时，请求原生层隐藏窗口。
    static let escapeUserScript = "(() => {\n" + selectors + """
      // Keep declarations local: reinjection after mode/settings changes must be idempotent.
      window.__ccRemoveEscape?.();
      let captured = null;
      // Phase 0 evidence: structure-only Esc / IME / caret trace. Survives reinjection; no text or field values,
      // only key names Escape/Process and caret categories (start/end/middle/...).
      const log = (window.__ccEscLog ||= []);
      const note = entry => { log.push(entry); if (log.length > 60) log.splice(0, log.length - 60); return entry; };
      const now = () => Math.round(performance.now());
      const MODALS = '[role="dialog"], [role="alertdialog"], [aria-modal="true"]';
      const kind = t => {
        if (!(t instanceof Element)) return 'none';
        const input = pick(CAND.input);
        if (input && (t === input || input.contains(t))) return 'composer';
        const field = t.matches('input, textarea, select, [contenteditable="true"], [contenteditable=""]') || !!t.closest('[contenteditable="true"], [contenteditable=""]');
        return (t.closest(MODALS) ? 'modal-' : '') + (field ? 'field' : t === document.body ? 'body' : 'other');
      };
      // K10: message selectors match nothing on the signed-in page, so find the scroller by structure (largest scrollable area).
      const scroller = () => {
        const mains = document.querySelectorAll('main, [role="main"]');
        let best = null, most = 4;
        for (const root of mains.length ? mains : [document.body]) for (const el of root.querySelectorAll('*')) {
          const extra = el.scrollHeight - el.clientHeight;
          if (extra <= most || el.clientHeight < 80) continue;
          const oy = getComputedStyle(el).overflowY;
          if (oy === 'auto' || oy === 'scroll' || oy === 'overlay') { best = el; most = extra; }
        }
        const se = document.scrollingElement;
        return best || (se && se.scrollHeight > se.clientHeight + 4 ? se : null);
      };
      // Caret position inside the composer. Offsets stay in memory; the trace only ever gets categories.
      const caretInfo = el => {
        if (!el) return { why: 'no-composer' };
        const a = document.activeElement;
        if (!(a === el || el.contains(a))) return { why: 'unfocused' };
        if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
          return { at: el.selectionStart, n: el.value.length, collapsed: el.selectionStart === el.selectionEnd };
        }
        const sel = getSelection();
        if (!sel || !sel.rangeCount) return { why: 'none' };
        const r = sel.getRangeAt(0);
        if (!el.contains(r.startContainer)) return { why: 'outside' };
        const pre = document.createRange(); pre.selectNodeContents(el); pre.setEnd(r.startContainer, r.startOffset);
        return { at: pre.toString().length, n: (el.textContent || '').length, collapsed: r.collapsed };
      };
      const caret = el => {
        const i = caretInfo(el);
        if (i.why) return i.why;
        if (!i.n) return 'empty';
        if (!i.collapsed) return 'range';
        return i.at === 0 ? 'start' : i.at >= i.n ? 'end' : 'middle';
      };
      const setCaret = (el, at) => {
        if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') { el.selectionStart = el.selectionEnd = at; return; }
        const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
        let node = null, left = at;
        while (walker.nextNode()) {
          node = walker.currentNode;
          if (left <= node.length) break;
          left -= node.length;
        }
        if (!node) return;
        const r = document.createRange(); r.setStart(node, Math.min(left, node.length)); r.collapse(true);
        const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r);
      };
      // Kept on the isolated window: every show reinjects this script, and identity must survive that.
      const composerState = () => {
        const el = pick(CAND.input);
        const same = !!el && window.__ccLastComposer?.deref() === el;
        if (el) window.__ccLastComposer = new WeakRef(el);
        return { same, caret: caret(el), docFocus: document.hasFocus() };
      };
      const site = () => ({
        overlay: !!pick(CAND.overlay), streaming: !!pick(CAND.streaming), modals: [...document.querySelectorAll(MODALS)].filter(visible),
      });
      const isEsc = e => e.key === 'Escape' || e.code === 'Escape';
      const capture = e => {
        if (!isEsc(e)) return;
        const target = kind(e.target);
        if (e.isComposing || e.keyCode === 229) {
          // The input method already used this Esc to cancel composition / candidates. WebKit still reports it as an
          // Escape keydown (key 'Escape', keyCode 229) and pop-up layers close on it (0219: image preview closed).
          // Keep it from the page. The IME state itself is unaffected: it handled the key before this event.
          note({
            t: now(), kind: 'esc', key: e.key === 'Escape' ? 'Escape' : 'other', composing: e.isComposing, k229: e.keyCode === 229, target,
            modals: site().modals.length, action: 'ime-swallowed',
          });
          e.stopImmediatePropagation();
          return;
        }
        const st = site(), sc = scroller();
        const entry = note({
          t: now(), kind: 'esc', key: e.key === 'Escape' ? 'Escape' : e.key === 'Process' ? 'Process' : 'other',
          composing: false, k229: false, target,
          modals: st.modals.length, scroll: sc ? Math.round(sc.scrollTop) : null, action: 'not-bubbled',
        });
        captured = {
          escKey: e.key === 'Escape',
          target,
          overlay: st.overlay,
          streaming: st.streaming,
          fullscreen: !!document.fullscreenElement,
          entry,
        };
        setTimeout(() => {
          entry.after = { scroll: sc?.isConnected ? Math.round(sc.scrollTop) : null, modals: site().modals.length };
        }, 600);
      };
      const bubble = e => {
        if (!isEsc(e) || !captured) return;
        const c = captured; captured = null;
        const done = action => { c.entry.action = action; c.entry.prevented = e.defaultPrevented; };
        if (!c.escKey) return done('ime-key');
        // 0219: the official composer marks every Esc as handled although nothing visible happens. With focus in the
        // composer and no pop-up, menu, list or popover open (site's own visibility) and no answer streaming, treat it
        // as a plain Esc. Any other handled Esc belongs to the page.
        const composerOnly = c.target === 'composer' && !c.overlay && !c.streaming;
        if (e.defaultPrevented && !composerOnly) return done('page-handled');
        if (c.overlay || c.fullscreen) return done('keep-window');
        if (e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return done('modifier');
        done(e.defaultPrevented ? 'hide-request-composer' : 'hide-request');
        window.webkit.messageHandlers.cc.postMessage({ type: 'escape' });
      };
      const composition = e => {
        window.__ccComposing = e.type === 'compositionstart';
        note({ t: now(), kind: e.type === 'compositionstart' ? 'comp-start' : 'comp-end', target: kind(e.target) });
      };
      // K14: when the WebView resigns first responder while hidden, WebKit can clear the page selection and the editor
      // puts the caret at the start. This is the safety net. It runs after the page shows, so the move can be visible.
      // Only that case is corrected: same element, same length (nothing typed), no composition, caret collapsed at 0.
      // State lives on the isolated window because every show reinjects this script.
      const saveCaret = () => {
        if (window.__ccCaretSaved) return;
        const el = pick(CAND.input), i = caretInfo(el);
        window.__ccCaretSaved = !i.why && i.collapsed && i.at > 0 ? { el: new WeakRef(el), at: i.at, n: i.n } : null;
      };
      const restoreCaret = () => {
        const s = window.__ccCaretSaved;
        window.__ccCaretSaved = null;
        if (!s) return;
        // Later attempts: the editor can push its own selection back shortly after regaining focus.
        for (const delay of [120, 400, 900]) setTimeout(() => {
          const el = s.el.deref();
          if (!el || el !== pick(CAND.input) || window.__ccComposing) return;
          const i = caretInfo(el);
          if (i.why || i.n !== s.n || !i.collapsed || i.at !== 0) return;
          setCaret(el, s.at);
          note({ t: now(), kind: 'caret-restored', delay, caret: caret(el) });
        }, delay);
      };
      // Evidence for when the caret moves: selection changes while hidden and just after becoming visible.
      const selectionMoved = () => {
        if (document.visibilityState === 'visible' && Date.now() > (window.__ccCaretWatch || 0)) return;
        note({ t: now(), kind: 'caret', state: document.visibilityState, caret: caret(pick(CAND.input)), docFocus: document.hasFocus() });
      };
      // Caret evidence around mode switches (K14): composer identity and caret category before and after a resize burst.
      let resizeTimer = 0;
      const resized = () => {
        if (!resizeTimer) note({ t: now(), kind: 'resize-start', w: innerWidth, ...composerState() });
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => {
          resizeTimer = 0;
          const entry = note({ t: now(), kind: 'resize-end', w: innerWidth, ...composerState() });
          setTimeout(() => { entry.later = composerState(); }, 500);
        }, 250);
      };
      const focusMove = e => {
        if (kind(e.target) !== 'composer') return;
        const entry = note({ t: now(), kind: e.type === 'focusin' ? 'c-focus' : 'c-blur', ...composerState() });
        if (e.type === 'focusin') setTimeout(() => { entry.later = composerState(); }, 100);
      };
      // Caret evidence for waking from hidden.
      const visibility = () => {
        const visible = document.visibilityState === 'visible';
        const entry = note({ t: now(), kind: 'visibility', state: document.visibilityState, ...composerState() });
        if (!visible) return saveCaret();
        window.__ccCaretWatch = Date.now() + 1200;
        restoreCaret();
        setTimeout(() => { entry.later = composerState(); }, 500);
      };
      const listeners = [
        [window, 'keydown', capture, true], [window, 'keydown', bubble, false],
        [window, 'compositionstart', composition, true], [window, 'compositionend', composition, true],
        [window, 'resize', resized, false], [window, 'focusin', focusMove, true], [window, 'focusout', focusMove, true],
        [document, 'visibilitychange', visibility, false], [document, 'selectionchange', selectionMoved, false],
      ];
      for (const [t, type, fn, cap] of listeners) t.addEventListener(type, fn, cap);
      // Probe access: scroll position as numbers only.
      window.__ccScroll = () => {
        const s = scroller();
        return s ? { top: Math.round(s.scrollTop), max: Math.round(s.scrollHeight - s.clientHeight), view: Math.round(s.clientHeight) } : null;
      };
      // 缩放和窗口大小变化都会重新排版：scrollTop 不变时，读到的内容就跳走了。记下视口里的一块内容，排版后放回原来的高度。
      // 只用位置，不读正文。用户自己滚动或按键时立刻放手。
      let hold = null;
      const contentAt = (s, box) => {
        for (const fy of [0.25, 0.4, 0.55, 0.1, 0.7]) for (const fx of [0.5, 0.25, 0.75]) {
          const el = document.elementFromPoint(box.left + box.width * fx, box.top + box.height * fy);
          if (el && el !== s && s.contains(el) && el.getBoundingClientRect().height < box.height) return el;
        }
        return null;
      };
      const releaseHold = () => {
        if (!hold) return;
        hold.timers.forEach(clearTimeout);
        hold = null;
        window.removeEventListener('wheel', releaseHold, { capture: true });
        window.removeEventListener('touchmove', releaseHold, { capture: true });
        window.removeEventListener('keydown', releaseHold, true);
      };
      const applyHold = () => {
        if (!hold) return;
        const { s, el, ratio } = hold;
        if (!s.isConnected || (el && !el.isConnected)) return releaseHold();
        if (!el) return s.scrollTo({ top: s.scrollHeight, behavior: 'instant' });
        const box = s.getBoundingClientRect();
        const off = el.getBoundingClientRect().top - box.top - ratio * box.height;
        if (Math.abs(off) >= 1) s.scrollTo({ top: s.scrollTop + off, behavior: 'instant' });
      };
      window.__ccReadingHold = {
        // 连续操作时沿用第一次记下的内容，误差不会累积。el 为空表示停在对话底部。
        save() {
          if (hold) return true;
          const s = scroller();
          if (!s) return false;
          const box = s.getBoundingClientRect();
          const el = s.scrollHeight - s.clientHeight - s.scrollTop < 4 ? null : contentAt(s, box);
          if (!el && s.scrollHeight - s.clientHeight - s.scrollTop >= 4) return false;
          hold = { s, el, ratio: el ? (el.getBoundingClientRect().top - box.top) / box.height : 0, timers: [] };
          window.addEventListener('wheel', releaseHold, { capture: true, passive: true });
          window.addEventListener('touchmove', releaseHold, { capture: true, passive: true });
          window.addEventListener('keydown', releaseHold, true);
          return true;
        },
        // 网页排版比窗口慢，排版稳定前再放回几次。
        restore() {
          if (!hold) return;
          hold.timers.forEach(clearTimeout);
          applyHold();
          if (!hold) return;
          hold.timers = [60, 160, 320, 640, 1000].map(ms => setTimeout(applyHold, ms));
          hold.timers.push(setTimeout(releaseHold, 1100));
        },
      };
      window.__ccRemoveEscape = () => {
        for (const [t, type, fn, cap] of listeners) t.removeEventListener(type, fn, cap);
        releaseHold();
        delete window.__ccReadingHold;
        clearTimeout(resizeTimer);
        delete window.__ccRemoveEscape;
      };
    })();
    """
    // MARK: - 官方 Read Aloud 证据采集（只读）

    /// UI 词汇分类：只输出分类名，不输出原始标签文本，避免把可能含正文的属性写入报告。
    static let uiVocabulary = """
    const VOCAB = [
      ['read-aloud', /read aloud|朗读|朗讀|読み上げ/i],
      ['speed', /speed|playback rate|速度|倍速|再生速度/i],
      ['pause', /pause|暂停|暫停|一時停止/i],
      ['stop', /stop|停止/i],
      ['play', /\\bplay\\b|播放|再生/i],
      ['more', /more|更多|その他/i],
      ['copy', /copy|复制|複製|コピー/i],
      ['good', /good response|喜欢|良い/i],
      ['bad', /bad response|不喜欢|悪い/i],
      ['share', /share|分享|共有/i],
      ['regenerate', /regenerate|try again|retry|重新生成|重试|再生成/i],
      ['edit', /\\bedit\\b|编辑|編集/i],
      ['branch', /previous response|next response|上一|下一/i],
      ['voice', /voice|语音|音声/i],
      ['login', /^(log in|sign in|sign up|登录|注册|ログイン)$/i],
    ];
    function kw(label) {
      if (!label) return null;
      label = String(label).trim();
      if (!label) return null;
      if (label.length > 40) return 'long-label';
      for (const [k, re] of VOCAB) if (re.test(label)) return k;
      return 'other';
    }
    const safeId = (v) => (v && /^[a-z0-9-]{1,60}$/i.test(v)) ? v : (v ? 'non-identifier' : null);
    function mediaState() {
      return Array.from(document.querySelectorAll('audio, video')).map(m => ({
        tag: m.tagName.toLowerCase(),
        paused: m.paused, ended: m.ended,
        rate: m.playbackRate, defaultRate: m.defaultPlaybackRate,
        ready: m.readyState, muted: m.muted,
        t: Math.round(m.currentTime * 10) / 10,
        dur: Number.isFinite(m.duration) ? Math.round(m.duration * 10) / 10 : (m.duration === Infinity ? 'inf' : null),
        visible: visible(m),
      }));
    }
    """

    /// 采集官方 Read Aloud 相关结构：登录迹象、最新助手回答的操作按钮、可见菜单项、可见朗读相关控件、DOM 媒体元素状态。
    /// 只返回计数、布尔值、data-testid 标识符和 UI 词汇分类；不返回正文、aria-label 原文、链接或媒体地址。
    static let readAloudProbe = selectors + uiVocabulary + """
    const visibleButtons = Array.from(document.querySelectorAll('button, [role="button"]')).filter(visible);
    const loginButtons = visibleButtons.filter(b => kw(b.innerText) === 'login' || kw(b.getAttribute('aria-label')) === 'login').length;
    const historyLinks = document.querySelectorAll('a[href^="/c/"], a[href*="/c/"]').length;

    const assistants = document.querySelectorAll(SEL.assistant);
    const lastAssistant = assistants.length ? assistants[assistants.length - 1] : null;
    let lastTurn = null, turnButtons = [];
    if (lastAssistant) {
      lastTurn = lastAssistant.closest(SEL.turn);
      // 操作按钮可能不在 turn 容器内，向上最多 3 层寻找包含按钮的祖先
      let scope = lastTurn || lastAssistant;
      for (let i = 0; i < 3 && scope && scope.querySelectorAll('button').length === 0; i++) scope = scope.parentElement;
      turnButtons = scope ? Array.from(scope.querySelectorAll('button, [role="button"]')).slice(0, 25).map(b => ({
        testid: safeId(b.getAttribute('data-testid')),
        kw: kw(b.getAttribute('aria-label') || b.getAttribute('title')),
        popup: b.getAttribute('aria-haspopup') || null,
        expanded: b.getAttribute('aria-expanded'),
        pressed: b.getAttribute('aria-pressed'),
        visible: visible(b),
      })) : [];
    }

    const menus = Array.from(document.querySelectorAll('[role="menu"]')).filter(visible).map(menu =>
      Array.from(menu.querySelectorAll('[role="menuitem"], [role="menuitemradio"], [role="menuitemcheckbox"], button'))
        .slice(0, 20).map(it => ({ kw: kw(it.innerText || it.getAttribute('aria-label')), testid: safeId(it.getAttribute('data-testid')) })));

    const readAloudControls = visibleButtons
      .map(b => ({ kw: kw(b.getAttribute('aria-label') || b.getAttribute('title')), testid: safeId(b.getAttribute('data-testid')) }))
      .filter(x => ['read-aloud', 'speed', 'pause', 'stop', 'play'].includes(x.kw) || (x.testid && /voice|read|aloud|speech|audio|play/i.test(x.testid)));

    return JSON.stringify({
      host: location.hostname,
      loginButtons, historyLinks,
      messageCount: document.querySelectorAll(SEL.message).length,
      assistantCount: assistants.length,
      lastAssistantHasTurn: !!lastTurn,
      streaming: !!document.querySelector(SEL.streaming),
      turnButtons, menus, readAloudControls,
      media: mediaState(),
    });
    """

    /// 测量 DOM 媒体元素的实际播放速率：两次采样 currentTime，与墙钟时间比较。只读。
    static let measureMedia = selectors + uiVocabulary + """
    const els = Array.from(document.querySelectorAll('audio, video'));
    const t0 = performance.now();
    const a = els.map(m => m.currentTime);
    await new Promise(r => setTimeout(r, 2000));
    const wall = (performance.now() - t0) / 1000;
    return JSON.stringify({
      wall: Math.round(wall * 100) / 100,
      media: els.map((m, i) => ({
        tag: m.tagName.toLowerCase(), paused: m.paused, rate: m.playbackRate,
        effective: Math.round(((m.currentTime - a[i]) / wall) * 100) / 100,
      })),
    });
    """

    /// 【实验，仅诊断窗口手动触发】对“正在播放且唯一”的 DOM 媒体元素设置标准 playbackRate。
    /// 不读取媒体地址；元素不唯一或不存在时不做任何修改。参数 rate 由原生层校验。
    static let setMediaRate = selectors + uiVocabulary + """
    const playing = Array.from(document.querySelectorAll('audio, video')).filter(m => !m.paused && !m.ended);
    if (playing.length !== 1) return JSON.stringify({ status: playing.length === 0 ? 'no-playing-dom-media' : 'ambiguous', count: playing.length });
    const m = playing[0];
    const before = m.playbackRate;
    m.playbackRate = rate;
    return JSON.stringify({ status: 'set', before, after: m.playbackRate });
    """
}
