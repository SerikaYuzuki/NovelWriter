import Foundation
import NovelCore
import NovelLocalStore
import NovelSync

extension AppState {
    /// Projects the server's authoritative pending-conflict list into the
    /// single conflict shown by the macOS sheet. An empty successful response
    /// is a resolved state, including after choosing the server's version.
    static func snapshotConflictProjection(
        _ conflicts: [SnapshotSyncConflict]
    ) -> SnapshotSyncConflict? {
        conflicts.last
    }

    private static func snapshotSyncErrorToken(_ error: Error) -> String {
        if error is LocalStoreError {
            return DeviceSyncLog.errorToken(error)
        }
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
        guard let context = snapshotConflictResolutionContext(for: choice) else { return false }
        let conflict = context.conflict
        DeviceSyncLog.snapshot(
            "conflict resolution begin choice=\(choice.rawValue) "
                + "conflict=\(conflict.conflictID.uuidString.lowercased())"
        )
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        do {
            let outcome: SnapshotSyncOutcome?
            switch choice {
            case .useThisDevice:
                outcome = try await context.worker.resolveUsingLocal(conflict)
            case .useServer:
                outcome = try await resolveSnapshotConflictUsingServer(
                    conflict,
                    worker: context.worker,
                    store: context.store
                )
            case .keepBoth:
                // Keep-both requires the clone WorkID/root transaction from the
                // versioned server contract. The UI exposes it only after that
                // transaction is available; never silently choose a winner.
                return false
            }
            guard let outcome else { return false }
            lastSnapshotSyncOutcome = outcome
            await refreshSnapshotConflict(for: conflict.workID, outcome: outcome)
            return true
        } catch {
            DeviceSyncLog.snapshot("conflict resolution failed", error: error)
            return false
        }
    }

    private struct SnapshotConflictResolutionContext {
        let conflict: SnapshotSyncConflict
        let worker: LocalSnapshotSyncWorker
        let store: LocalSQLiteStore
    }

    private func snapshotConflictResolutionContext(
        for choice: SnapshotSyncConflictChoice
    ) -> SnapshotConflictResolutionContext? {
        DeviceSyncLog.snapshot(
            "conflict resolution requested choice=\(choice.rawValue)"
        )
        guard usesSnapshotSyncRuntime else {
            DeviceSyncLog.snapshot("conflict resolution blocked(runtime-unavailable)")
            return nil
        }
        guard let conflict = snapshotSyncConflict else {
            DeviceSyncLog.snapshot("conflict resolution blocked(conflict-missing)")
            return nil
        }
        guard let worker = localSnapshotSyncWorker else {
            DeviceSyncLog.snapshot("conflict resolution blocked(worker-missing)")
            return nil
        }
        guard let store = localCanonicalStore else {
            DeviceSyncLog.snapshot("conflict resolution blocked(store-missing)")
            return nil
        }
        guard permitsDocumentInteraction else {
            DeviceSyncLog.snapshot(
                "conflict resolution blocked(document-not-permitted) "
                    + "ready=\(startupState.isReady) transition=\(isDocumentTransitionInProgress) "
                    + "termination=\(isTerminationPending)"
            )
            return nil
        }
        return SnapshotConflictResolutionContext(conflict: conflict, worker: worker, store: store)
    }

    private func resolveSnapshotConflictUsingServer(
        _ conflict: SnapshotSyncConflict,
        worker: LocalSnapshotSyncWorker,
        store: LocalSQLiteStore
    ) async throws -> SnapshotSyncOutcome? {
        guard let prepared = try await prepareRemoteSnapshotForConflict(conflict, worker: worker) else {
            return nil
        }
        guard let installed = try await adoptRemoteSnapshotForConflict(
            conflict,
            prepared: prepared,
            store: store
        ) else {
            return nil
        }
        try await worker.resolveUsingServer(conflict)
        return .uploaded(snapshotID: installed.id, generation: prepared.head.generation)
    }

    private struct PreparedRemoteSnapshot {
        let head: RemoteSnapshotHead
        let payload: RemoteSnapshotPayload
        let document: NovelDocument
    }

    private func prepareRemoteSnapshotForConflict(
        _ conflict: SnapshotSyncConflict,
        worker: LocalSnapshotSyncWorker
    ) async throws -> PreparedRemoteSnapshot? {
        guard let head = try await worker.remoteHead(workID: conflict.workID) else {
            DeviceSyncLog.snapshot("conflict server choice blocked(remote-head-missing)")
            return nil
        }
        guard head.snapshotID == conflict.remoteSnapshotID else {
            DeviceSyncLog.snapshot(
                "conflict server choice blocked(remote-head-changed) "
                    + "expected=\(conflict.remoteSnapshotID) actual=\(head.snapshotID)"
            )
            return nil
        }
        let payload = try await worker.remoteSnapshot(
            workID: conflict.workID,
            snapshotID: head.snapshotID
        )
        guard let object = payload.object(forEntityKey: "work/document") else {
            DeviceSyncLog.snapshot("conflict server choice failed: missing work/document")
            return nil
        }
        let remoteSnapshot: WorkSnapshot
        do {
            remoteSnapshot = try JSONDecoder().decode(WorkSnapshot.self, from: object.bytes)
        } catch {
            DeviceSyncLog.snapshot(
                "conflict server choice failed: invalid work/document",
                error: error
            )
            return nil
        }
        let remoteDocument = try remoteSnapshot.materializedDocument()
        guard remoteDocument.id == document.id else {
            DeviceSyncLog.snapshot("conflict server choice blocked(document-identity-mismatch)")
            return nil
        }
        return PreparedRemoteSnapshot(head: head, payload: payload, document: remoteDocument)
    }

    private func adoptRemoteSnapshotForConflict(
        _ conflict: SnapshotSyncConflict,
        prepared: PreparedRemoteSnapshot,
        store: LocalSQLiteStore
    ) async throws -> LocalSnapshotRecord? {
        let expectedSession = documentSessionToken
        guard await saveNow() else {
            DeviceSyncLog.snapshot("conflict server choice failed(local-save)")
            return nil
        }
        guard documentSessionToken == expectedSession else {
            DeviceSyncLog.snapshot("conflict server choice blocked(session-changed-before-install)")
            return nil
        }
        var state = try await store.workState(for: conflict.workID)
        try await repository.save(prepared.document, to: documentURL)
        let installed: LocalSnapshotRecord
        do {
            installed = try await installRemoteSnapshotForConflict(
                conflict,
                prepared: prepared,
                state: state,
                store: store
            )
        } catch LocalStoreError.statementFailed("local snapshot changed") {
            // saveNow schedules the remote worker after its local commit. If
            // that worker advances the local pointer before this transaction,
            // retry against the latest pointer instead of reporting a false
            // storage failure.
            guard documentSessionToken == expectedSession else { return nil }
            state = try await store.workState(for: conflict.workID)
            installed = try await installRemoteSnapshotForConflict(
                conflict,
                prepared: prepared,
                state: state,
                store: store
            )
        }
        guard documentSessionToken == expectedSession else {
            DeviceSyncLog.snapshot("conflict server choice blocked(session-changed-after-install)")
            return nil
        }
        installDocument(prepared.document, at: documentURL, attachments: [])
        return installed
    }

    private func installRemoteSnapshotForConflict(
        _ conflict: SnapshotSyncConflict,
        prepared: PreparedRemoteSnapshot,
        state: LocalWorkState?,
        store: LocalSQLiteStore
    ) async throws -> LocalSnapshotRecord {
        try await store.installRemoteSnapshot(
            RemoteSnapshotInstallRequest(
                identity: .init(
                    workID: conflict.workID,
                    documentID: prepared.document.id,
                    documentCreatedAt: state?.documentCreatedAt ?? Date().ISO8601Format()
                ),
                payload: .init(
                    snapshotID: prepared.payload.snapshotID,
                    parentSnapshotIDs: prepared.payload.parentSnapshotIDs,
                    manifest: prepared.payload.manifest,
                    objects: prepared.payload.objects
                ),
                expectations: .init(
                    remoteGeneration: prepared.head.generation,
                    expectedLocalSnapshotID: state?.currentLocalSnapshotID,
                    expectedLocalGeneration: state?.localGeneration
                )
            )
        )
    }

    private func refreshSnapshotConflict(
        for workID: UUID,
        outcome _: SnapshotSyncOutcome
    ) async {
        guard let worker = localSnapshotSyncWorker else { return }
        do {
            let conflicts = try await worker.conflicts(workID: workID)
            snapshotSyncConflict = Self.snapshotConflictProjection(conflicts)
            if conflicts.count > 1 {
                DeviceSyncLog.snapshot("conflicts loaded count=\(conflicts.count)")
            }
            // A successful explicit resolution reports `.uploaded` (the
            // installed remote branch is now the local canonical head), not
            // `.needsChoice`. The empty projection above therefore dismisses
            // a resolved conflict instead of leaving a stale sheet visible.
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
