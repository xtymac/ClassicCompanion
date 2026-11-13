import AppKit
import Combine
import Sparkle

/// 设置和菜单看到的更新状态。没有更新配置的构建（swift run、单元测试）里 isAvailable 为 false，开关灰掉。
@MainActor
final class UpdateStatus: ObservableObject {
    @Published fileprivate(set) var isAvailable = false
    /// Sparkle 的 automaticallyChecksForUpdates（存在用户默认值 SUEnableAutomaticChecks）。
    /// 首次询问的回答、设置里的开关都改这一个值，所以菜单、设置和 Sparkle 自己永远一致。
    @Published fileprivate(set) var automaticallyChecks = false
    @Published fileprivate(set) var canCheck = false
    /// 定时检查发现、还没被用户看过的新版本（温和提醒：只在菜单、菜单栏菜单和设置里提示，不弹窗），
    /// 或者等用户授权下载并安装（或确认安装）的版本。菜单和设置里显示“有新版本”，点了打开对应的窗口。
    @Published fileprivate(set) var pendingVersion: String?
    /// 有等用户回答的确认窗口（授权下载并安装，或确认安装）。这时 Sparkle 的会话还没结束、canCheck 为 false，
    /// 但“检查更新…”仍可用：把确认窗口叫回来。
    @Published fileprivate(set) var awaitingInstallDecision = false

    fileprivate var setAutomaticallyChecks: (Bool) -> Void = { _ in }
    fileprivate var check: () -> Void = {}

    /// 参数只给布局测试用（量“发现新版本”时设置页的高度）；UpdateController 用默认值。
    init(isAvailable: Bool = false, pendingVersion: String? = nil) {
        self.isAvailable = isAvailable
        self.pendingVersion = pendingVersion
    }

    func setAutomaticChecks(_ enabled: Bool) { setAutomaticallyChecks(enabled) }
    func checkForUpdates() { check() }
}

/// 应用内更新（Sparkle 2）。见 docs/updates.md。
///
/// - 不自动下载、不自动安装、不退出时安装（Info.plist：SUAllowsAutomaticUpdates = NO，SUAutomaticallyUpdate 不设）。
/// - 是否自动检查：第二次启动时由 Sparkle 标准提示询问，之后在设置里改。
/// - 定时检查发现新版本不弹窗、不抢焦点：用 Sparkle 的温和提醒接口，只在菜单、菜单栏菜单和设置里提示，不用 Dock 角标。
/// - 下载之前用户必须在确认窗口里授权“下载并安装”（ConfirmingUserDriver）：授权之前不启动安装器，
///   正常退出、崩溃或被强制退出都不会安装。授权后下载、验证完成就安装并重新启动。
///   不根据有没有声音、空闲时间或“生成中”判断能否重启。
///
/// SPUUpdater 和标准界面的委托回调都在主线程（Sparkle 文档）；SPUStandardUserDriverDelegate 的头文件没标主线程，所以用 @preconcurrency。
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    let status = UpdateStatus()
    let configuration: UpdateConfiguration?
    private let diagnostics: Diagnostics
    private var updater: SPUUpdater?
    private var driver: ConfirmingUserDriver?
    private var observations: [NSKeyValueObservation] = []
    private var terminationWaiters: [() -> Void] = []

    init(diagnostics: Diagnostics, bundle: Bundle = .main) {
        self.diagnostics = diagnostics
        configuration = UpdateConfiguration(infoDictionary: bundle.infoDictionary)
        super.init()
        guard configuration != nil else { return }
        let standard = SPUStandardUserDriver(hostBundle: bundle, delegate: self)
        let driver = ConfirmingUserDriver(standard: standard)
        driver.log = { [weak self] in self?.diagnostics.log("update", $0) }
        driver.onPendingInstallChange = { [weak self] version in
            guard let self else { return }
            self.status.awaitingInstallDecision = version != nil
            self.status.pendingVersion = version.flatMap { $0.isEmpty ? nil : $0 }
        }
        self.driver = driver
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
    }

    /// 在第一次显示聊天窗口之后调用：第二次启动时的标准询问会出现在聊天窗口上面。
    func start() {
        guard let updater, let configuration else {
            diagnostics.log("update", "没有更新配置，不检查更新")
            return
        }
        do {
            try updater.start()
        } catch {
            // 只记错误类别，不记原文（可能带路径）。
            diagnostics.log("update", "更新器没有启动：\(ConfirmingUserDriver.describe(error))")
            return
        }
        // 只认 Info.plist 里的 feed：清掉旧 API 可能留在用户默认值里的地址。
        if updater.clearFeedURLFromUserDefaults() != nil {
            diagnostics.log("update", "清除了用户默认值里的旧 feed 地址")
        }
        status.isAvailable = true
        status.setAutomaticallyChecks = { [weak updater] in updater?.automaticallyChecksForUpdates = $0 }
        status.check = { [weak self] in self?.checkForUpdates() }
        observations = [
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.status.automaticallyChecks = updater.automaticallyChecksForUpdates }
            },
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.status.canCheck = updater.canCheckForUpdates }
            },
        ]
        if configuration.channelMismatch {
            diagnostics.log("update", "Info.plist 的渠道和版本号不一致：按正式版处理，不收 beta")
        }
        diagnostics.log("update", "更新器已启动：渠道 \(configuration.channel.rawValue)，自动检查 \(updater.automaticallyChecksForUpdates ? "开" : "关")")
    }

    func checkForUpdates() {
        guard let updater, let driver else { return }
        if driver.hasPendingInstallDecision {
            diagnostics.log("update", "显示等待确认的安装")
            driver.presentPendingPrompt()
            return
        }
        diagnostics.log("update", "手动检查更新")
        updater.checkForUpdates()
    }

    func retitle() { driver?.retitle() }

    /// 退出应用时调用。安装器已经启动（授权后正在验证解压，或 installing 阶段等用户确认）时，先取消安装再退出，
    /// 保证正常退出时不安装（不靠声音、空闲或“生成中”判断）。等用户授权下载时还没有安装器，直接退出。
    /// 按授权安装时 Sparkle 发来的退出不受影响。
    func terminationReply(proceed: @escaping () -> Void) -> NSApplication.TerminateReply {
        guard let driver else { return .terminateNow }
        // 已经在等取消完成时再按一次 ⌘Q：继续等，不能在取消消息送到安装器之前就退出。
        if !terminationWaiters.isEmpty {
            terminationWaiters.append(proceed)
            return .terminateLater
        }
        guard driver.isHoldingInstall else { return .terminateNow }
        terminationWaiters.append(proceed)
        driver.cancelPendingInstall(reason: "退出应用")
        // 取消消息要先送到安装器。更新会话结束（didFinishUpdateCycle）后再退出；最多等 10 秒（包括还在解压的情况）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.releaseTermination("超时") }
        return .terminateLater
    }

    private func releaseTermination(_ why: String) {
        guard !terminationWaiters.isEmpty else { return }
        diagnostics.log("update", "取消安装后继续退出（\(why)）")
        let waiters = terminationWaiters
        terminationWaiters = []
        waiters.forEach { $0() }
    }

    // MARK: - SPUUpdaterDelegate

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        configuration?.channel.sparkleChannels ?? []
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        diagnostics.log("update", "找到可用更新 \(item.displayVersionString)（\(item.versionString)）")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        diagnostics.log("update", "没有更新（\(ConfirmingUserDriver.describe(error))）")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        diagnostics.log("update", "更新中止（\(ConfirmingUserDriver.describe(error))）")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        diagnostics.log("update", "开始安装 \(item.displayVersionString)（\(item.versionString)），应用将重新启动")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.releaseTermination("会话结束") }
    }

    // MARK: - SPUStandardUserDriverDelegate：温和提醒

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 定时检查一律由这里处理，不让标准界面弹出更新窗口：
    /// 标准界面会在应用刚启动、或用户切回应用时把更新窗口设为键盘焦点，这时用户按快捷键打开聊天窗口打字，回车会按到“安装更新”。
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        status.pendingVersion = update.displayVersionString
        diagnostics.log("update", "定时检查发现 \(update.displayVersionString)：只在菜单、菜单栏菜单和设置里提示")
    }

    // 不用 Dock 角标（用户 2026-11-12 决定）：更新功能不碰 Dock 图标的任何状态。

    func standardUserDriverWillFinishUpdateSession() {
        status.pendingVersion = nil
    }
}
