import AppKit
import Foundation

/// App lifecycle notifications are kept separate from document transition
/// operations. Their callbacks only schedule existing AppState boundaries;
/// they do not acquire the document gate or wait for remote work inline.
extension AppState {
    func observeResignActive() {
        guard resignActiveObserver.value == nil else { return }
        resignActiveObserver.value = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.flushDeviceSyncForBackground(waitForRemote: false)
                await self?.captureAutomaticSnapshotForBackground()
            }
        }
    }

    func observeSystemSleep() {
        guard systemSleepObserver.value == nil else { return }
        systemSleepObserver.value = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.flushDeviceSyncForBackground(waitForRemote: false)
                await self?.captureAutomaticSnapshotForBackground()
            }
        }
    }

    func observeDeviceSyncReactivation() {
        guard becomeActiveObserver.value == nil, systemWakeObserver.value == nil else { return }
        becomeActiveObserver.value = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDeviceSyncReactivation()
            }
        }
        systemWakeObserver.value = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDeviceSyncReactivation()
            }
        }
    }

    /// AppKit activation notifications are signals only. The notification
    /// callback schedules remote work and returns without awaiting sync I/O.
    private func scheduleDeviceSyncReactivation() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if case let .documentSelection(context) = startupState,
               context.presentation == .cloudLibrary {
                await refreshStartupLibrary()
            } else {
                await retryAccountScopedPendingPublicationsInBackground()
                await refreshActiveDeviceSyncWithoutPreparing()
            }
        }
    }
}
