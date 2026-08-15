import Foundation
import NovelLocalStore

extension AppState {
    /// Starts remote replay after the local commit boundary. The caller never
    /// awaits network completion, so navigation/background/quit remain local
    /// first even when the server is unavailable.
    func scheduleSnapshotSync(for workID: UUID) {
        guard let worker = localSnapshotSyncWorker else { return }
        Task { [weak self] in
            do {
                let outcome = try await worker.sync(workID: workID)
                guard let self else { return }
                self.lastSnapshotSyncOutcome = outcome
            } catch {
                self?.lastSnapshotSyncOutcome = .offline
            }
        }
    }

    /// Explicit sync for the post-cutover lane. Local save remains the only
    /// required boundary; this action additionally waits for one remote
    /// attempt so the status can immediately show uploaded/offline/conflict.
    @discardableResult
    func saveAndSyncSnapshotNow() async -> Bool {
        guard usesSnapshotSyncRuntime, permitsDocumentInteraction else { return false }
        let saved = await saveNow()
        guard saved, let worker = localSnapshotSyncWorker else { return saved }
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        do {
            let outcome = try await worker.sync(workID: document.id)
            lastSnapshotSyncOutcome = outcome
            switch outcome {
            case .uploaded, .idle:
                return true
            case .offline, .needsChoice:
                return false
            }
        } catch {
            lastSnapshotSyncOutcome = .offline
            return false
        }
    }

    /// Replays all durable intents after launch or a successful sign-in.
    /// SQLite remains the source of truth; this only wakes the remote lane.
    func resumePendingSnapshotSync() async {
        guard let store = localCanonicalStore else { return }
        do {
            let intents = try await store.pendingIntents()
            for workID in Set(intents.map(\.workID)) {
                scheduleSnapshotSync(for: workID)
            }
        } catch {
            lastSnapshotSyncOutcome = .offline
        }
    }
}
