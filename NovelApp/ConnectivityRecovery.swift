import Network
import SwiftUI

/// Reachability is only a wake hint; the outbox and account fences decide what may run.
@MainActor
final class ConnectivityRecovery {
    private var monitor: NWPathMonitor?

    func start(recovered: @escaping @MainActor @Sendable () async -> Void) {
        guard monitor == nil else { return }
        #if !FUMINIWA_TEST_COMPOSITION
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await recovered() }
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
