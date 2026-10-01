import NovelSyncV2
import NovelSyncV2Application
import UIKit

@MainActor
protocol IOSBackgroundTaskControlling: AnyObject {
    func beginBackgroundTask(
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

@MainActor
final class IOSApplicationBackgroundTaskController: IOSBackgroundTaskControlling {
    func beginBackgroundTask(
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask {
            Task { @MainActor in
                expirationHandler()
            }
        }
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

@MainActor
private final class IOSBackgroundTaskLease {
    private let controller: any IOSBackgroundTaskControlling
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var hasEnded = false

    init(
        controller: any IOSBackgroundTaskControlling,
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        self.controller = controller
        identifier = controller.beginBackgroundTask { [weak self] in
            expirationHandler()
            self?.end()
        }
    }

    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        guard identifier != .invalid else { return }
        controller.endBackgroundTask(identifier)
        identifier = .invalid
    }

    deinit {
        MainActor.assumeIsolated {
            end()
        }
    }
}

extension IOSDocumentStore {
    func openRemoteOnlyWithBackgroundTime(
        _ application: SyncV2Application, workID: WorkID
    ) async throws -> SyncV2OpenedWork {
        let task = Task { try await application.open(workID: workID) }
        let lease = IOSBackgroundTaskLease(controller: backgroundTaskController) { task.cancel() }
        defer { lease.end() }
        return try await withTaskCancellationHandler {
            let opened = try await task.value
            try Task.checkCancellation()
            return opened
        } onCancel: {
            task.cancel()
        }
    }

    /// suspension前のlocal durability区間をiOSへ明示し、expiration時は処理をcancelする。
    /// network同期の成否にかかわらず、package→journalの順序は通常flushと同じ。
    @discardableResult
    func flushDeviceSyncWithBackgroundTime() async -> Bool {
        let flushTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            let flushed = await flushDeviceSyncForBackground(waitForRemote: false)
            await captureAutomaticSnapshotForBackground()
            return flushed
        }
        let lease = IOSBackgroundTaskLease(
            controller: backgroundTaskController,
            expirationHandler: {
                flushTask.cancel()
            }
        )
        let result = await flushTask.value
        lease.end()
        return result
    }
}
