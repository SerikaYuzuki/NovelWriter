import Network
import SwiftUI

/// Reachability is only a wake hint; the outbox and account fences decide what may run.
@MainActor
final class ConnectivityRecovery {
    private var monitor: NWPathMonitor?

    func start(constrained: @escaping @MainActor @Sendable (Bool, Bool) async -> Void = { _, _ in }, recovered: @escaping @MainActor @Sendable () async -> Void) {
        guard monitor == nil else { return }
        #if !FUMINIWA_TEST_COMPOSITION
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let reachable = path.status == .satisfied
            let limited = path.isConstrained || path.isExpensive
            Task { @MainActor in
                await constrained(reachable, limited)
                if path.status == .satisfied {
                    await recovered()
                }
            }
        }
        self.monitor = monitor
        monitor.start(queue: DispatchQueue(label: "fuminiwa.connectivity"))
        #endif
    }

    func stop() {
        monitor?.cancel(); monitor = nil
    }

    deinit { monitor?.cancel() }
}
