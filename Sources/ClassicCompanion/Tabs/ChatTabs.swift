import Foundation
import CompanionCore

/// 标签页和窗口之间的接线：把标签页的网页运行时的回调接到窗口上（wire(_:)），加上换页面（urlChanged）和聚焦输入框
/// （focusInputSoon）。原来都写在 AppDelegate 里，原样搬过来：同样的闭包、同样的内容、同样的顺序。
/// 搬出来是为了能在不建 AppDelegate、不开应用的测试里核对这些顺序（LaunchWiringTests）：冷启动看起来对不对就靠它们。
///
/// 现在只有一个标签页（tab）。带页面的窗口入口传的是这个标签页自己的 page：只有一个标签页时它就是窗口的 page
/// （同一个对象，AppDelegate 建窗口时传的就是它），所以和原来不带页面的入口效果一样。
/// 不判断标签页选没选中，不建、不选第二个标签页。
///
/// 要用到的 AppDelegate 的东西由 AppDelegate 交进来（正式运行时的做法写在各项旁边），测试换成记录。
@MainActor
final class ChatTabs {
    /// 现在唯一的标签页。
    let tab: ChatTab
    private let windowController: ChatWindowController
    private let diagnostics: Diagnostics
    /// 隐藏窗口，参数是写进日志的原因。AppDelegate：windowController.hide(reason:)。
    private let hideWindow: @MainActor (String) -> Void
    /// 聚焦官方输入框，返回结果代码。AppDelegate：适配器的 focusInput()。
    private let focusInput: @MainActor (ChatGPTAdapter) async -> String
    /// 记下可以恢复的对话地址。AppDelegate：settings.lastConversationURL。
    private let saveLastConversation: @MainActor (URL) -> Void
    /// 网页媒体状态，只写日志。AppDelegate：适配器的 webMediaState()。
    private let mediaState: @MainActor (ChatGPTAdapter) async -> String
    /// 窗口是不是 key 窗口（加载完成时据此决定要不要聚焦）。就是 windowController.isKey；
    /// 只有测试换它：测试不显示窗口，窗口不会成为 key 窗口。
    var windowIsKey: @MainActor () -> Bool

    init(tab: ChatTab, windowController: ChatWindowController, diagnostics: Diagnostics,
         hideWindow: @escaping @MainActor (String) -> Void,
         focusInput: @escaping @MainActor (ChatGPTAdapter) async -> String,
         saveLastConversation: @escaping @MainActor (URL) -> Void,
         mediaState: @escaping @MainActor (ChatGPTAdapter) async -> String) {
        self.tab = tab
        self.windowController = windowController
        self.diagnostics = diagnostics
        self.hideWindow = hideWindow
        self.focusInput = focusInput
        self.saveLastConversation = saveLastConversation
        self.mediaState = mediaState
        windowIsKey = { windowController.isKey }
    }

    /// 把标签页 tab 的网页运行时的回调接到窗口上，再接窗口提示里的“重新加载”。AppDelegate 在启动时原来接这些的地方调用。
    /// page 和 webView 是 tab 的常量（let），接线时取和回调时取是同一个对象。闭包挂在运行时上，持有它们不成环（它们不持有运行时）。
    func wire(_ tab: ChatTab) {
        let page = tab.page, webView = tab.runtime.webView
        tab.runtime.onURLChange = { [weak self] url in self?.urlChanged(url) }
        tab.runtime.onEscapeRequest = { [weak self] in self?.hideWindow("网页 Esc") }
        // 页面加载完成时结束启动画面；若窗口在前台，再尝试聚焦一次（唤醒时页面可能尚未就绪）
        tab.runtime.onMainFrameLoaded = { [weak self] in
            guard let self else { return }
            self.windowController.endLaunchScreen("网页已加载", for: page)
            // 网页第一次加载完成才恢复跟随页面底色；加载失败、启动画面到时限都不恢复，等之后哪次加载完成。
            // 报的颜色是这个标签页的网页视图此刻报的；只有一个标签页时它就是窗口显示着的网页视图（原来入口读的那个）。
            self.windowController.pageDidFinishLoading(page, reportedColor: webView.underPageBackgroundColor)
            if self.windowIsKey() { self.focusInputSoon() }
        }
        // 加载失败时结束启动画面。WebKit 不显示错误页：首次加载失败时窗口里没有页面，
        // 由 WebRuntime 自动重试（退避、限次、断网不发请求），窗口盖“无法连接”提示，⌘R 和提示里的按钮显式加载失败的地址
        // （2026-11-11 开机白屏）。
        tab.runtime.onLoadFailed = { [weak self] in self?.windowController.endLaunchScreen("加载失败", for: page) }
        tab.runtime.onLoadProblemChange = { [weak self] status in self?.windowController.showLoadProblem(status, for: page) }
        // 提交时先告诉窗口：到时限后还在的启动画面和留着的提示要等加载完成（或提交后 1 秒）再撤。
        tab.runtime.onMainFrameCommitted = { [weak self] in self?.windowController.pageDidCommit(page) }
        windowController.onReloadRequest = { [weak self] in self?.tab.runtime.reload() }
    }

    private func urlChanged(_ url: URL?) {
        if let restorable = NavigationPolicy.restorableConversationURL(url) {
            saveLastConversation(restorable)
        }
        // 仅路径变化视为切换页面（忽略 query 变化）
        let path = url.map { "\($0.host ?? "")\($0.path)" }
        guard path != tab.lastPath else { return }
        let previous = tab.lastPath
        tab.lastPath = path
        tab.adapter.invalidate()
        diagnostics.log("nav", "页面变化 \(Redactor.describe(url))")
        // 记录导航时网页媒体状态，用于验证“切换对话后官方朗读是否停止”（不主动干预）
        if previous != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self else { return }
                self.diagnostics.log("media", "页面变化后 0.8s WebKit 媒体状态=\(await self.mediaState(self.tab.adapter))")
            }
        }
    }

    func focusInputSoon() {
        tab.focusTask?.cancel()
        tab.focusTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            let result = await self.focusInput(self.tab.adapter)
            self.diagnostics.recordInputFocus(result)
        }
    }
}
