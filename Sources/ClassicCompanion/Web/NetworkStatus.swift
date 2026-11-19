import Network

/// 全应用共用一个网络监视（NWPathMonitor），把每次网络变化转给登记过的网页运行时。
/// 只负责通知：页面要不要重试，完全由它自己的恢复规则决定（WebRuntime.networkChanged → LoadRecovery）。
/// 这里从不加载、也不重新加载任何页面。运行时只弱引用，释放了就从名单里去掉。
@MainActor
final class NetworkStatus {
    /// 最近一次知道的网络状态。系统还没报过时是 nil。
    private(set) var online: Bool?
    private var runtimes: [WeakRuntime] = []
    private let monitor: NWPathMonitor?

    /// `startsMonitor: false` 只给测试用：不看真实网络，状态由 `deliver(online:)` 送进来。
    init(startsMonitor: Bool = true) {
        guard startsMonitor else {
            monitor = nil
            return
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        // 和原来每个运行时自己的监视一样：在主队列上异步送到，开始监视后系统先报一次当前状态。
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            MainActor.assumeIsolated { self?.deliver(online: online) }
        }
        monitor.start(queue: .main)
    }

    deinit {
        monitor?.cancel()
    }

    /// 登记一个运行时。已经知道网络状态时，马上把它补发给这一个运行时：原来各自开监视，系统一开始就报当前状态；
    /// 共用以后靠这次补发，断网时才创建的页面也等得到“网络恢复”。还不知道状态时什么都不发，等第一次报告。
    /// 同一个运行时重复登记不算，免得一次变化送到两遍。
    func add(_ runtime: WebRuntime) {
        runtimes.removeAll { $0.value == nil }
        guard !runtimes.contains(where: { $0.value === runtime }) else { return }
        runtimes.append(WeakRuntime(value: runtime))
        if let online { runtime.networkChanged(online: online) }
    }

    /// 系统的每次报告都走这里（测试直接调用）：先记下状态，再原样转给每个还在的运行时，不去重、不加别的动作。
    /// 先记状态：转发途中才登记的运行时由补发拿到这次的状态，不在这一轮名单里，不会收到两遍。
    func deliver(online: Bool) {
        self.online = online
        runtimes.removeAll { $0.value == nil }
        for runtime in runtimes.compactMap(\.value) {
            runtime.networkChanged(online: online)
        }
    }

    /// 名单里的条数（测试用：确认释放的运行时被去掉、重复登记不加条）。
    var registeredCount: Int { runtimes.count }
}

private struct WeakRuntime {
    weak var value: WebRuntime?
}
