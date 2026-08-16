import Foundation
import NovelCore
import NovelLocalStore
import NovelSync

extension AppState {
    private static func snapshotSyncErrorToken(_ error: Error) -> String {
        guard let error = error as? SnapshotSyncError else {
            return String(reflecting: type(of: error))
        }
        switch error {
        case .invalidManifest:
            return "invalidManifest"
        case let .transport(message):
            return "transport:\(message)"
        case .offline:
            return "offline"
        case .unauthorized:
            return "unauthorized"
        case .conflict:
            return "conflict"
        }
    }

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
                lastSnapshotSyncOutcome = outcome
                await refreshSnapshotConflict(for: workID, outcome: outcome)
                DeviceSyncLog.snapshot("finished \(String(describing: outcome))")
            } catch {
                DeviceSyncLog.snapshot("failed \(Self.snapshotSyncErrorToken(error))")
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
            await refreshSnapshotConflict(for: document.id, outcome: outcome)
            DeviceSyncLog.snapshot("explicit finished \(String(describing: outcome))")
            switch outcome {
            case .uploaded, .idle:
                return true
            case .notStarted, .offline, .needsChoice:
                return false
            }
        } catch {
            DeviceSyncLog.snapshot("explicit failed \(Self.snapshotSyncErrorToken(error))")
            lastSnapshotSyncOutcome = .offline
            return false
        }
    }

    @discardableResult
    func resolveSnapshotConflict(
        using choice: SnapshotSyncConflictChoice
    ) async -> Bool {
        guard usesSnapshotSyncRuntime,
              let conflict = snapshotSyncConflict,
              let worker = localSnapshotSyncWorker,
              let store = localCanonicalStore,
              permitsDocumentInteraction else { return false }
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        do {
            switch choice {
            case .useThisDevice:
                let outcome = try await worker.resolveUsingLocal(conflict)
                lastSnapshotSyncOutcome = outcome
                snapshotSyncConflict = nil
                return true
            case .useServer:
                guard let head = try await worker.remoteHead(workID: conflict.workID),
                      head.snapshotID == conflict.remoteSnapshotID else { return false }
                let payload = try await worker.remoteSnapshot(
                    workID: conflict.workID,
                    snapshotID: head.snapshotID
                )
                guard let object = payload.objects.first else { return false }
                let remoteSnapshot = try JSONDecoder().decode(WorkSnapshot.self, from: object.bytes)
                let remoteDocument = try remoteSnapshot.materializedDocument()
                guard remoteDocument.id == document.id else { return false }
                guard await saveNow() else { return false }
                let state = try await store.workState(for: conflict.workID)
                try await repository.save(remoteDocument, to: documentURL)
                _ = try await store.installRemoteSnapshot(
                    workID: conflict.workID,
                    documentID: remoteDocument.id,
                    documentCreatedAt: state?.documentCreatedAt ?? Date().ISO8601Format(),
                    snapshotID: payload.snapshotID,
                    parentSnapshotIDs: payload.parentSnapshotIDs,
                    manifest: payload.manifest,
                    objects: payload.objects,
                    remoteGeneration: head.generation,
                    expectedLocalSnapshotID: state?.currentLocalSnapshotID,
                    expectedLocalGeneration: state?.localGeneration
                )
                installDocument(remoteDocument, at: documentURL, attachments: [])
                try await worker.resolveUsingServer(conflict)
                lastSnapshotSyncOutcome = .uploaded(
                    snapshotID: payload.snapshotID,
                    generation: head.generation
                )
                snapshotSyncConflict = nil
                return true
            case .keepBoth:
                // Keep-both requires the clone WorkID/root transaction from the
                // versioned server contract. The UI exposes it only after that
                // transaction is available; never silently choose a winner.
                return false
            }
        } catch {
            DeviceSyncLog.snapshot("conflict resolution failed", error: error)
            return false
        }
    }

    private func refreshSnapshotConflict(
        for workID: UUID,
        outcome: SnapshotSyncOutcome
    ) async {
        guard let worker = localSnapshotSyncWorker else { return }
        do {
            let conflicts = try await worker.conflicts(workID: workID)
            if let conflict = conflicts.first {
                snapshotSyncConflict = conflict
            } else if case .needsChoice = outcome {
                snapshotSyncConflict = nil
            }
        } catch {
            // Keep an already-loaded conflict visible when a status refresh
            // is temporarily offline. A failed refresh must not hide the
            // user's pending choice.
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
