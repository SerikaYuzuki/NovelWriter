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
        DeviceSyncLog.snapshot(
            "conflict resolution requested choice=\(choice.rawValue)"
        )
        guard usesSnapshotSyncRuntime else {
            DeviceSyncLog.snapshot("conflict resolution blocked(runtime-unavailable)")
            return false
        }
        guard let conflict = snapshotSyncConflict else {
            DeviceSyncLog.snapshot("conflict resolution blocked(conflict-missing)")
            return false
        }
        guard let worker = localSnapshotSyncWorker else {
            DeviceSyncLog.snapshot("conflict resolution blocked(worker-missing)")
            return false
        }
        guard let store = localCanonicalStore else {
            DeviceSyncLog.snapshot("conflict resolution blocked(store-missing)")
            return false
        }
        guard permitsDocumentInteraction else {
            DeviceSyncLog.snapshot(
                "conflict resolution blocked(document-not-permitted) "
                    + "ready=\(startupState.isReady) transition=\(isDocumentTransitionInProgress) "
                    + "termination=\(isTerminationPending)"
            )
            return false
        }
        DeviceSyncLog.snapshot(
            "conflict resolution begin choice=\(choice.rawValue) "
                + "conflict=\(conflict.conflictID.uuidString.lowercased())"
        )
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        do {
            switch choice {
            case .useThisDevice:
                let outcome = try await worker.resolveUsingLocal(conflict)
                lastSnapshotSyncOutcome = outcome
                await refreshSnapshotConflict(for: conflict.workID, outcome: outcome)
                return true
            case .useServer:
                guard let head = try await worker.remoteHead(workID: conflict.workID) else {
                    DeviceSyncLog.snapshot("conflict server choice blocked(remote-head-missing)")
                    return false
                }
                guard head.snapshotID == conflict.remoteSnapshotID else {
                    DeviceSyncLog.snapshot(
                        "conflict server choice blocked(remote-head-changed) "
                            + "expected=\(conflict.remoteSnapshotID) actual=\(head.snapshotID)"
                    )
                    return false
                }
                let payload = try await worker.remoteSnapshot(
                    workID: conflict.workID,
                    snapshotID: head.snapshotID
                )
                guard let object = payload.object(forEntityKey: "work/document") else {
                    DeviceSyncLog.snapshot("conflict server choice failed: missing work/document")
                    return false
                }
                let remoteSnapshot: WorkSnapshot
                do {
                    remoteSnapshot = try JSONDecoder().decode(WorkSnapshot.self, from: object.bytes)
                } catch {
                    DeviceSyncLog.snapshot(
                        "conflict server choice failed: invalid work/document",
                        error: error
                    )
                    return false
                }
                let remoteDocument = try remoteSnapshot.materializedDocument()
                guard remoteDocument.id == document.id else {
                    DeviceSyncLog.snapshot("conflict server choice blocked(document-identity-mismatch)")
                    return false
                }
                let expectedSession = documentSessionToken
                guard await saveNow() else {
                    DeviceSyncLog.snapshot("conflict server choice failed(local-save)")
                    return false
                }
                guard documentSessionToken == expectedSession else {
                    DeviceSyncLog.snapshot("conflict server choice blocked(session-changed-before-install)")
                    return false
                }
                var state = try await store.workState(for: conflict.workID)
                try await repository.save(remoteDocument, to: documentURL)
                let installed: LocalSnapshotRecord
                do {
                    installed = try await store.installRemoteSnapshot(
                        RemoteSnapshotInstallRequest(
                            identity: .init(
                                workID: conflict.workID,
                                documentID: remoteDocument.id,
                                documentCreatedAt: state?.documentCreatedAt ?? Date().ISO8601Format()
                            ),
                            payload: .init(
                                snapshotID: payload.snapshotID,
                                parentSnapshotIDs: payload.parentSnapshotIDs,
                                manifest: payload.manifest,
                                objects: payload.objects
                            ),
                            expectations: .init(
                                remoteGeneration: head.generation,
                                expectedLocalSnapshotID: state?.currentLocalSnapshotID,
                                expectedLocalGeneration: state?.localGeneration
                            )
                        )
                    )
                } catch LocalStoreError.statementFailed("local snapshot changed") {
                    // saveNow schedules the remote worker after its local
                    // commit. If that worker acknowledges or coalesces the
                    // just-saved state before this install transaction, retry
                    // against the latest local pointer instead of surfacing a
                    // false storage failure to the user.
                    guard documentSessionToken == expectedSession else { return false }
                    state = try await store.workState(for: conflict.workID)
                    installed = try await store.installRemoteSnapshot(
                        RemoteSnapshotInstallRequest(
                            identity: .init(
                                workID: conflict.workID,
                                documentID: remoteDocument.id,
                                documentCreatedAt: state?.documentCreatedAt ?? Date().ISO8601Format()
                            ),
                            payload: .init(
                                snapshotID: payload.snapshotID,
                                parentSnapshotIDs: payload.parentSnapshotIDs,
                                manifest: payload.manifest,
                                objects: payload.objects
                            ),
                            expectations: .init(
                                remoteGeneration: head.generation,
                                expectedLocalSnapshotID: state?.currentLocalSnapshotID,
                                expectedLocalGeneration: state?.localGeneration
                            )
                        )
                    )
                }
                guard documentSessionToken == expectedSession else {
                    DeviceSyncLog.snapshot("conflict server choice blocked(session-changed-after-install)")
                    return false
                }
                installDocument(remoteDocument, at: documentURL, attachments: [])
                try await worker.resolveUsingServer(conflict)
                lastSnapshotSyncOutcome = .uploaded(
                    snapshotID: installed.id,
                    generation: head.generation
                )
                await refreshSnapshotConflict(
                    for: conflict.workID,
                    outcome: lastSnapshotSyncOutcome
                )
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
