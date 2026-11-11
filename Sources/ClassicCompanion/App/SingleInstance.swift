import AppKit

/// 同一账号只运行一个实例。两个实例会共用 WebKit 数据和快捷键。
/// 系统只对同一路径去重；从 DMG 或其他位置打开副本时，请求转给已在运行的实例。
enum SingleInstance {
    struct Candidate: Equatable {
        let pid: pid_t
        let launchDate: Date?
    }

    /// 先启动的留下；时间相同按 pid。所有实例按同一规则得出同一结果。
    static func survivor(among candidates: [Candidate]) -> Candidate? {
        candidates.min { a, b in
            let left = a.launchDate ?? .distantFuture, right = b.launchDate ?? .distantFuture
            return left == right ? a.pid < b.pid : left < right
        }
    }

    /// 已有实例时把打开请求转过去（系统会发 reopen，由它找回窗口）。返回 true 表示本进程应直接退出。
    static func handOffToRunningInstance() -> Bool {
        // 未打包运行（swift run）没有 bundle id，不参与。
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let own = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { !$0.isTerminated && $0.processIdentifier != own.processIdentifier }
        guard !others.isEmpty else { return false }
        let candidates = ([own] + others).map { Candidate(pid: $0.processIdentifier, launchDate: $0.launchDate) }
        guard let survivor = survivor(among: candidates), survivor.pid != own.processIdentifier,
              let url = others.first(where: { $0.processIdentifier == survivor.pid })?.bundleURL else { return false }
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 3)
        return true
    }
}
