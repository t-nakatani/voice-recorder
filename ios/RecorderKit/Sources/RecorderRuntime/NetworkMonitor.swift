import Foundation
import Network

/// ネットワークが使えるようになったら知らせる。送信のやり直しのきっかけに使う。
public final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "recorder.network-monitor")
    private var wasSatisfied = false

    public init() {}

    public func start(onBecameReachable: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            if satisfied && !self.wasSatisfied { onBecameReachable() }
            self.wasSatisfied = satisfied
        }
        monitor.start(queue: queue)
    }

    public func stop() { monitor.cancel() }
}
