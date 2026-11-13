import AppKit
import Sparkle

/// Sparkle 的用户界面：几乎全部交给官方 SPUStandardUserDriver（权限询问、检查进度、发现新版本和更新说明、
/// 下载进度、无更新、错误提示），只在两处插入应用自己的确认（UpdatePromptWindow）。
///
/// 安装边界（Sparkle 2.10.1，SPUUserDriver.h；2026-11-13 隔离实测）：下载完成、开始验证和解压时 Sparkle 就启动安装器，
/// 从那时起应用自己退出——包括崩溃、被强制退出，这些应用拦不住——就会安装。Sparkle 没有“只下载、不启动安装器”的官方接口。
/// 所以用户必须在下载之前明确授权：
/// 1. 标准新版本窗口里选“安装更新”时，先不把选择交给 Sparkle，而是显示“下载并安装”确认（authorize）。
///    “稍后”或关闭窗口回复 Dismiss：不下载、不启动安装器，什么都不装。
/// 2. 授权后才回复 Install：Sparkle 下载、验证、解压。准备好（showReady）时按授权直接回复 Install，安装并重新启动，不再询问。
///    没有授权就到了这一步（不应发生）回复 Skip：按 SPUUserDriver.h，这一步的 Skip 只取消正在进行的安装，不会跳过这个版本。
/// 3. 安装器已经在等的 installing 阶段（授权后应用没能退出等）：显示“安装并重新启动”确认（install），“稍后”回复 Skip 取消安装。
@MainActor
final class ConfirmingUserDriver: NSObject, SPUUserDriver {
    let standard: SPUStandardUserDriver
    /// 给诊断日志（中文，和以前的记录一致）。
    var log: (String) -> Void = { _ in }
    /// 有没有等用户确认的更新（版本号；没有时为 nil）。菜单和设置据此显示“有新版本”，点了把确认窗口叫回来。
    var onPendingInstallChange: (String?) -> Void = { _ in }

    private var version: String?
    private var prompt: UpdatePromptWindow?
    private var pending: (kind: UpdatePromptKind, reply: (SPUUserUpdateChoice) -> Void)?
    /// 用户在这次更新会话里授权了“下载并安装”。会话结束、出错或开始新的会话时清掉。
    private var authorized = false
    /// 下载完成后正在验证、解压（安装器已经启动），还没到 showReady。
    private var preparingInstall = false
    /// 准备期间用户退出应用：准备好后不安装，直接取消。
    private var cancelWhenReady = false

    init(standard: SPUStandardUserDriver) {
        self.standard = standard
    }

    /// 有一个等用户回答的确认（授权下载并安装，或安装器已在等的安装）。
    var hasPendingInstallDecision: Bool { pending != nil }

    /// 安装器已经启动（正在验证、解压，或者 installing 阶段等用户确认）。这时退出应用要先取消安装
    /// （UpdateController.terminationReply）：按 SPUUserDriver.h，应用自己退出时 Sparkle 会试着把准备好的更新装上。
    /// 等用户授权下载时还没有安装器，退出不需要取消任何东西。
    var isHoldingInstall: Bool { pending?.kind == .install || preparingInstall }

    /// 用户没选就要退出应用（⌘Q、注销、关机）：先取消这次安装，保证正常退出时不装。
    func cancelPendingInstall(reason: String) {
        if pending?.kind == .install {
            log("准备好的更新被取消（\(reason)），退出时不安装")
            finish(.skip)
        } else if preparingInstall {
            log("更新还在准备时\(reason)：准备好后立即取消，退出时不安装")
            cancelWhenReady = true
        }
    }

    // MARK: - 插入的确认

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        version = appcastItem.displayVersionString
        authorized = false
        log("发现新版本 \(appcastItem.displayVersionString)（\(appcastItem.versionString)），\(state.userInitiated ? "手动检查" : "定时检查")")
        if state.stage == .installing {
            // 安装器已经在等。标准提醒在这一步会给“退出时安装”，所以用确认窗口：确认才安装，“稍后”取消安装。
            // 按 SPUUserDriver.h，这里的 Skip 也会跳过这个版本的定时提醒，手动“检查更新…”仍能找到它。
            // 定时检查发现的不弹窗，只在菜单和设置里提示（温和提醒）。
            presentPrompt(.install, takeFocus: state.userInitiated, show: state.userInitiated, reply: reply)
            return
        }
        standard.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
            guard let self else {
                // 不会发生（驱动和应用同生命周期）；万一发生也不在没有授权时安装。
                reply(choice == .install ? .dismiss : choice)
                return
            }
            self.log("新版本提示：\(Self.describe(choice))")
            guard choice == .install else {
                reply(choice)
                return
            }
            // 用户刚在 Sparkle 窗口里点了按钮，应用在前台：确认窗口取得焦点（主按钮先停 1 秒，见 UpdatePromptGate）。
            self.presentPrompt(.authorize, takeFocus: NSApp.isActive, reply: reply)
        }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        preparingInstall = false
        if cancelWhenReady {
            cancelWhenReady = false
            authorized = false
            standard.dismissUpdateInstallation()
            log("应用正在退出：取消这次安装")
            reply(.skip)
            return
        }
        guard authorized else {
            standard.dismissUpdateInstallation()
            log("没有用户授权：取消这次安装")
            reply(.skip)
            return
        }
        authorized = false
        // 标准进度窗口留着：Sparkle 接着显示“正在安装更新…”，然后退出、安装、重新打开。
        log("下载和验证完成：按用户授权安装并重新启动")
        reply(.install)
    }

    /// 菜单“检查更新…”、菜单栏菜单的“有新版本”和设置里的“查看更新…”：有等确认的更新时把确认窗口叫到前面。
    func presentPendingPrompt() {
        guard pending != nil else { return }
        prompt?.present(takeFocus: true)
    }

    /// show 为 false：只记下等确认的更新（菜单和设置里显示“有新版本”），用户点了才显示确认窗口。
    private func presentPrompt(_ kind: UpdatePromptKind, takeFocus: Bool, show: Bool = true,
                               reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pending = (kind, reply)
        prompt?.close()
        let window = UpdatePromptWindow(
            kind: kind, version: version,
            onInstall: { [weak self] in self?.confirm() },
            onLater: { [weak self] in self?.decline() })
        prompt = window
        if show { window.present(takeFocus: takeFocus) }
        onPendingInstallChange(version ?? "")
        let shown = show ? (takeFocus ? "取得焦点" : "不抢焦点") : "只在菜单和设置里提示"
        switch kind {
        case .authorize: log("等待用户授权下载并安装（\(shown)）；还没有下载，也没有启动安装器")
        case .install: log("更新已准备好，等待用户确认（\(shown)）")
        }
    }

    private func confirm() {
        guard let kind = pending?.kind else { return }
        switch kind {
        case .authorize:
            log("用户授权下载并安装：下载和验证完成后自动安装并重新启动")
            authorized = true
        case .install:
            log("用户确认安装并重新启动")
        }
        finish(.install)
    }

    private func decline() {
        guard let kind = pending?.kind else { return }
        switch kind {
        case .authorize:
            log("用户选择稍后：不下载、不安装")
            finish(.dismiss)
        case .install:
            log("用户选择稍后：取消这次安装，应用继续运行")
            finish(.skip)
        }
    }

    private func finish(_ choice: SPUUserUpdateChoice) {
        let reply = pending?.reply
        clearPrompt()
        reply?(choice)
    }

    private func clearPrompt() {
        let hadPending = pending != nil
        pending = nil
        prompt?.close()
        prompt = nil
        if hadPending { onPendingInstallChange(nil) }
    }

    /// 更新会话结束或出错：授权只对这一次会话有效。
    private func endSession() {
        clearPrompt()
        authorized = false
        preparingInstall = false
        cancelWhenReady = false
    }

    func retitle() { prompt?.retitle() }

    // MARK: - 其余全部交给标准界面

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        log("询问是否自动检查更新（Sparkle 标准提示）")
        standard.show(request) { [weak self] response in
            self?.log("自动检查更新：\(response.automaticUpdateChecks ? "开" : "关")")
            reply(response)
        }
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        standard.showUpdateReleaseNotes(with: downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        standard.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        log("没有可用的新版本（\(Self.describe(error))）")
        standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        log("更新失败（\(Self.describe(error))），当前版本不变")
        endSession()
        standard.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        log("开始下载更新")
        standard.showDownloadInitiated(cancellation: { [weak self] in
            self?.log("用户取消下载：不安装")
            cancellation()
        })
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        standard.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        preparingInstall = true
        log(authorized ? "下载完成，开始验证和解压（安装器启动）" : "下载完成，开始验证和解压，但没有用户授权：准备好后取消")
        standard.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        standard.showExtractionReceivedProgress(progress)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func showUpdateInFocus() {
        if pending != nil {
            presentPendingPrompt()
        } else {
            standard.showUpdateInFocus()
        }
    }

    func dismissUpdateInstallation() {
        if pending != nil { log("更新会话结束，确认窗口关闭") }
        endSession()
        standard.dismissUpdateInstallation()
    }

    // MARK: - 日志用的描述（不含网址、路径和错误原文）

    static func describe(_ choice: SPUUserUpdateChoice) -> String {
        switch choice {
        case .install: "安装"
        case .dismiss: "稍后提醒"
        case .skip: "跳过这个版本"
        @unknown default: "未知（\(choice.rawValue)）"
        }
    }

    static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
