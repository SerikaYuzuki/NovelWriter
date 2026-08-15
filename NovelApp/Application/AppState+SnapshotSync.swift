import Foundation
import NovelCore
import NovelLocalStore

extension AppState {
    /// Existing `.novelpkg` documents predate the SQLite authority. Seed one
    /// canonical local snapshot when they are opened so an explicit sync can
    /// publish an unchanged work as well as a newly edited work.
    func ensureLocalSnapshotSeeded(for document: NovelDocument) async {
        guard usesSnapshotSyncRuntime, let store = localCanonicalStore else { return }
        do {
            guard try await store.workState(for: document.id) == nil else {
                DeviceSyncLog.snapshot("seed skipped(existing-local-state)")
                return
            }
            guard await commitLocalCanonicalSnapshot(document) else {
                DeviceSyncLog.snapshot("seed failed(local-commit)")
                return
            }
            scheduleSnapshotSync(for: document.id)
            DeviceSyncLog.snapshot("seeded existing document")
        } catch {
            DeviceSyncLog.snapshot("seed failed", error: error)
        }
    }

    /// Starts remote replay after the local commit boundary. The caller never
    /// awaits network completion, so navigation/background/quit remain local
    /// first even when the server is unavailable.
    func scheduleSnapshotSync(for workID: UUID) {
        guard let worker = localSnapshotSyncWorker else { return }
        DeviceSyncLog.snapshot("scheduled")
        Task { [weak self] in
            do {
                let outcome = try await worker.sync(workID: workID)
                guard let self else { return }
                self.lastSnapshotSyncOutcome = outcome
                DeviceSyncLog.snapshot("finished \(String(describing: outcome))")
            } catch {
                DeviceSyncLog.snapshot("failed", error: error)
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
        DeviceSyncLog.snapshot("explicit begin")
        let saved = await saveNow()
        guard saved, let worker = localSnapshotSyncWorker else {
            DeviceSyncLog.snapshot("explicit local-save-failed")
            return saved
        }
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        do {
            let outcome = try await worker.sync(workID: document.id)
            lastSnapshotSyncOutcome = outcome
            DeviceSyncLog.snapshot("explicit finished \(String(describing: outcome))")
            switch outcome {
            case .uploaded, .idle:
                return true
            case .offline, .needsChoice:
                return false
            }
        } catch {
            DeviceSyncLog.snapshot("explicit failed", error: error)
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
            DeviceSyncLog.snapshot("resume pending=\(intents.count)")
            for workID in Set(intents.map(\.workID)) {
                scheduleSnapshotSync(for: workID)
            }
        } catch {
            lastSnapshotSyncOutcome = .offline
        }
    }
}
