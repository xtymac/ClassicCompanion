import AppKit
import WebKit

/// 是否把无障碍请求交给 WebKit。VoiceOver、切换控制开启时始终放行。
struct WebAccessibilityGate: Equatable {
    var blockRequested: Bool
    var assistiveTechnologyOn: Bool

    var allowsPageAccessibility: Bool { !blockRequested || assistiveTechnologyOn }
}

/// 任何应用一旦向 WKWebView 发无障碍请求，WebKit 就会为网页建立无障碍缓存；官方弹层打开或关闭时批量切换
/// aria-hidden，缓存逐个元素重算样式，2026-11-04 采样时主线程因此卡住十几秒，拦下请求后不再卡顿。
/// 默认拦截（用户决定），设置里可放行。本类只用公开接口，并记录每种请求第一次到达的时间（只有请求名，不含内容）。
/// WebKit 的缓存建立后不会撤销：从放行改回拦截，要等网页进程重启才完全生效。
final class CompanionWebView: WKWebView {
    var blockAccessibility = false
    var assistiveTechnologyOn: () -> Bool = {
        NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
    }
    /// 每种请求只回调一次：(请求名, 是否放行)
    var onAccessibilityRequest: ((String, Bool) -> Void)?
    private var seenRequests = Set<String>()

    private func admits(_ request: String) -> Bool {
        let allow = WebAccessibilityGate(blockRequested: blockAccessibility,
                                         assistiveTechnologyOn: assistiveTechnologyOn()).allowsPageAccessibility
        if seenRequests.insert(request).inserted { onAccessibilityRequest?(request, allow) }
        return allow
    }

    override var accessibilityFocusedUIElement: Any? {
        admits("focused") ? super.accessibilityFocusedUIElement : nil
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        admits("hitTest") ? super.accessibilityHitTest(point) : nil
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        admits(attribute.rawValue) ? super.accessibilityAttributeValue(attribute) : nil
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.ParameterizedAttribute, forParameter parameter: Any?) -> Any? {
        admits("param:\(attribute.rawValue)") ? super.accessibilityAttributeValue(attribute, forParameter: parameter) : nil
    }

    // MARK: - 右键菜单“拷贝图像”

    /// 测试换成自己的剪贴板。
    var imagePasteboard: NSPasteboard = .general
    private weak var webKitCopyImageTarget: AnyObject?
    private var webKitCopyImageAction: Selector?
    private var menuPagePoint: CGPoint = .zero
    /// 最近一次按下鼠标的位置（视图坐标）。willOpenMenu 收到的事件不一定是那次点击（实测位置不对），所以自己记。
    private var lastMouseDown: CGPoint = .zero

    override func rightMouseDown(with event: NSEvent) {
        lastMouseDown = convert(event.locationInWindow, from: nil)
        super.rightMouseDown(with: event)
    }

    /// 按住 Control 点按也会打开右键菜单。
    override func mouseDown(with event: NSEvent) {
        lastMouseDown = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    /// WebKit 的“拷贝图像”对 SVG 图片什么都不写进剪贴板（Safari 也一样，2026-11-24 实测）。
    /// 这里接过这一项：先照常交给 WebKit，再对 SVG 图片补一份位图。
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let item = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyImage" }),
              let action = item.action, action != #selector(copyImageFromMenu(_:)) else { return }
        webKitCopyImageTarget = item.target
        webKitCopyImageAction = action
        menuPagePoint = Self.pagePoint(viewPoint: lastMouseDown, viewHeight: bounds.height,
                                       flipped: isFlipped, pageZoom: pageZoom)
        item.target = self
        item.action = #selector(copyImageFromMenu(_:))
    }

    @objc private func copyImageFromMenu(_ sender: NSMenuItem) {
        if let action = webKitCopyImageAction, let target = webKitCopyImageTarget {
            NSApp.sendAction(action, to: target, from: sender)
        }
        let point = menuPagePoint
        Task { @MainActor in _ = await self.copyVectorImage(atPagePoint: point) }
    }

    /// 视图里的点换成网页视口坐标（CSS 像素，原点在左上）。
    static func pagePoint(viewPoint: CGPoint, viewHeight: CGFloat, flipped: Bool, pageZoom: CGFloat) -> CGPoint {
        let zoom = pageZoom > 0 ? pageZoom : 1
        let y = flipped ? viewPoint.y : viewHeight - viewPoint.y
        return CGPoint(x: viewPoint.x / zoom, y: y / zoom)
    }

    /// 该点上是 SVG 图片时，把它画成 PNG 放进剪贴板，返回 true。其他图片留给 WebKit，返回 false。
    /// 只读取这一张图片，不读取网页其他内容。
    @discardableResult
    func copyVectorImage(atPagePoint point: CGPoint) async -> Bool {
        let result = try? await callAsyncJavaScript(Self.rasterizeScript, arguments: ["x": point.x, "y": point.y],
                                                    in: nil, contentWorld: .defaultClient)
        guard let text = result as? String, let comma = text.firstIndex(of: ","),
              let png = Data(base64Encoded: String(text[text.index(after: comma)...])), !png.isEmpty else { return false }
        imagePasteboard.clearContents()
        imagePasteboard.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
            imagePasteboard.setData(tiff, forType: .tiff)
        }
        return true
    }

    private static let rasterizeScript = """
        const img = document.elementsFromPoint(x, y).find(e => e.tagName === 'IMG');
        if (!img) return null;
        const src = img.currentSrc || img.src || '';
        let vector = /^data:image\\/svg\\+xml/i.test(src) || /\\.svg([?#]|$)/i.test(src);
        if (!vector && src.startsWith('blob:')) {
            try { vector = (await (await fetch(src)).blob()).type === 'image/svg+xml'; } catch (e) {}
        }
        if (!vector) return null;
        const box = img.getBoundingClientRect();
        const scale = Math.max(2, window.devicePixelRatio || 1);
        let w = box.width * scale, h = box.height * scale;
        const fit = Math.min(1, 4096 / Math.max(w, h));
        w = Math.round(w * fit); h = Math.round(h * fit);
        if (!(w > 0 && h > 0)) return null;
        const canvas = document.createElement('canvas');
        canvas.width = w; canvas.height = h;
        try {
            canvas.getContext('2d').drawImage(img, 0, 0, w, h);
            return canvas.toDataURL('image/png');
        } catch (e) { return null; }
        """
}
