import Foundation
import NovelCore
import NovelLocalStore
import NovelSync

private struct IOSLocalManifest: Encodable {
    let schemaVersion: Int
    let workId: UUID
    let parentSnapshotIds: [String]
    let entries: [IOSLocalManifestEntry]
}

private struct IOSLocalManifestEntry: Encodable {
    let entityKey: String
    let objectId: String
    let byteCount: Int
    let contentType: String
}

extension IOSDocumentStore {
    var usesSnapshotSyncRuntime: Bool {
        localSnapshotSyncWorker != nil
    }

    func ensureLocalSnapshotSeeded(for document: NovelDocument) async {
        guard usesSnapshotSyncRuntime, let store = localCanonicalStore else { return }
        do {
            guard try await store.workState(for: document.id) == nil else {
                DeviceSyncLog.snapshot("ios seed skipped(existing-local-state)")
                return
            }
            guard await commitLocalCanonicalSnapshot(document) else {
                DeviceSyncLog.snapshot("ios seed failed(local-commit)")
                return
            }
            scheduleSnapshotSync(for: document.id)
            DeviceSyncLog.snapshot("ios seeded existing document")
        } catch {
            DeviceSyncLog.snapshot("ios seed failed", error: error)
        }
    }

    @discardableResult
    func commitLocalCanonicalSnapshot(_ document: NovelDocument) async -> Bool {
        guard let store = localCanonicalStore else { return true }
        do {
            let snapshot = try WorkSnapshot(document: document)
            let objectBytes = try WorkCanonicalJSON.encodeSnapshot(snapshot)
            let objectID = SyncContentDigest(
                content: String(decoding: objectBytes, as: UTF8.self)
            ).rawValue
            let previous = try await store.workState(for: document.id)
            let manifest = IOSLocalManifest(
                schemaVersion: 1,
                workId: document.id,
                parentSnapshotIds: previous?.currentLocalSnapshotID.map { [$0] } ?? [],
                entries: [
                    IOSLocalManifestEntry(
                        entityKey: "work/document",
                        objectId: objectID,
                        byteCount: objectBytes.count,
                        contentType: "application/json"
                    )
                ]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let manifestBytes = try encoder.encode(manifest)
            let snapshotID = SyncContentDigest(
                content: String(decoding: manifestBytes, as: UTF8.self)
            ).rawValue
            let createdAtKey = "fuminiwa.documentCreatedAt.\(document.id.uuidString.lowercased())"
            let createdAt: String
            if let existing = userDefaults.string(forKey: createdAtKey) {
                createdAt = existing
            } else {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [
                    .withInternetDateTime,
                    .withDashSeparatorInDate,
                    .withColonSeparatorInTime
                ]
                createdAt = formatter.string(from: Date())
                userDefaults.set(createdAt, forKey: createdAtKey)
            }
            _ = try await store.commitSnapshot(
                workID: document.id,
                documentID: document.id,
                documentCreatedAt: createdAt,
                snapshotID: snapshotID,
                parentSnapshotIDs: manifest.parentSnapshotIds,
                manifest: manifestBytes,
                objects: [LocalObject(objectID: objectID, bytes: objectBytes)],
                reason: .autosave
            )
            return true
        } catch {
            DeviceSyncLog.snapshot("ios local commit failed", error: error)
            return false
        }
    }

    func scheduleSnapshotSync(for workID: UUID) {
        guard let worker = localSnapshotSyncWorker else { return }
        DeviceSyncLog.snapshot("ios scheduled")
        Task { @MainActor [weak self] in
            do {
                let outcome = try await worker.sync(workID: workID)
                guard let self else { return }
                snapshotSyncOutcome = outcome
                await refreshSnapshotConflict(for: workID, outcome: outcome)
                DeviceSyncLog.snapshot("ios finished \(String(describing: outcome))")
            } catch {
                guard let self else { return }
                snapshotSyncOutcome = .offline
                DeviceSyncLog.snapshot("ios failed", error: error)
            }
        }
    }

    @discardableResult
    func saveAndSyncSnapshotNow() async -> Bool {
        guard usesSnapshotSyncRuntime, startupState == .ready else { return false }
        DeviceSyncLog.snapshot("ios explicit begin")
        let saved = await saveNow()
        guard saved, let worker = localSnapshotSyncWorker else { return saved }
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        do {
            let outcome = try await worker.sync(workID: document.id)
            snapshotSyncOutcome = outcome
            await refreshSnapshotConflict(for: document.id, outcome: outcome)
            DeviceSyncLog.snapshot("ios explicit finished \(String(describing: outcome))")
            switch outcome {
            case .uploaded, .idle:
                return true
            case .notStarted, .offline, .needsChoice:
                return false
            }
        } catch {
            snapshotSyncOutcome = .offline
            DeviceSyncLog.snapshot("ios explicit failed", error: error)
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
              startupState == .ready else { return false }
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        do {
            switch choice {
            case .useThisDevice:
                let outcome = try await worker.resolveUsingLocal(conflict)
                snapshotSyncOutcome = outcome
                await refreshSnapshotConflict(for: conflict.workID, outcome: outcome)
                return true
            case .useServer:
                guard let head = try await worker.remoteHead(workID: conflict.workID),
                      head.snapshotID == conflict.remoteSnapshotID else { return false }
                let payload = try await worker.remoteSnapshot(
                    workID: conflict.workID,
                    snapshotID: head.snapshotID
                )
                guard let object = payload.object(forEntityKey: "work/document") else {
                    DeviceSyncLog.snapshot("ios conflict server choice failed: missing work/document")
                    return false
                }
                let remoteSnapshot: WorkSnapshot
                do {
                    remoteSnapshot = try JSONDecoder().decode(WorkSnapshot.self, from: object.bytes)
                } catch {
                    DeviceSyncLog.snapshot("ios conflict server choice failed: invalid work/document", error: error)
                    return false
                }
                let remoteDocument = try remoteSnapshot.materializedDocument()
                guard remoteDocument.id == document.id else { return false }
                guard await saveNow() else { return false }
                let state = try await store.workState(for: conflict.workID)
                try await repository.save(remoteDocument, to: documentURL)
                _ = try await store.installRemoteSnapshot(
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
                guard install(remoteDocument, at: documentURL, attachments: []) else {
                    return false
                }
                try await worker.resolveUsingServer(conflict)
                snapshotSyncOutcome = .uploaded(
                    snapshotID: payload.snapshotID,
                    generation: head.generation
                )
                await refreshSnapshotConflict(
                    for: conflict.workID,
                    outcome: snapshotSyncOutcome
                )
                return true
            case .keepBoth:
                return false
            }
        } catch {
            DeviceSyncLog.snapshot("ios conflict resolution failed", error: error)
            return false
        }
    }

    private func refreshSnapshotConflict(for workID: UUID, outcome: SnapshotSyncOutcome) async {
        guard let worker = localSnapshotSyncWorker else { return }
        do {
            let conflicts = try await worker.conflicts(workID: workID)
            if let conflict = conflicts.last {
                snapshotSyncConflict = conflict
            } else if case .needsChoice = outcome {
                snapshotSyncConflict = nil
            }
            if conflicts.count > 1 {
                DeviceSyncLog.snapshot("ios conflicts loaded count=\(conflicts.count)")
            }
            if let conflict = snapshotSyncConflict {
                DeviceSyncLog.snapshot(
                    "ios conflict loaded id=\(conflict.conflictID.uuidString.lowercased())"
                )
            }
        } catch {
            DeviceSyncLog.snapshot("ios conflict load failed", error: error)
        }
    }

    func resumePendingSnapshotSync() async {
        guard let store = localCanonicalStore else { return }
        do {
            let intents = try await store.pendingIntents()
            DeviceSyncLog.snapshot("ios resume pending=\(intents.count)")
            for workID in Set(intents.map(\.workID)) {
                scheduleSnapshotSync(for: workID)
            }
        } catch {
            snapshotSyncOutcome = .offline
            DeviceSyncLog.snapshot("ios resume failed", error: error)
        }
    }

    func restoreFuminiwaSession() async {
        guard let authSessionCoordinator else {
            authUIState = .unavailable
            return
        }
        do {
            let session = try await authSessionCoordinator.currentSession()
            authSession = session
            authUIState = session.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
        } catch {
            authSession = nil
            authUIState = .failed("サインイン状態を復元できませんでした")
        }
    }

    func signInWithApple() async {
        guard let authSessionCoordinator, let appleSignInCoordinator else {
            authUIState = .unavailable
            return
        }
        guard authUIState != .signingIn else { return }
        authUIState = .signingIn
        do {
            let challenge = try await authSessionCoordinator.createAppleChallenge()
            let authorization = try await appleSignInCoordinator.authorize(using: challenge)
            let session = try await authSessionCoordinator.completeAppleSignIn(
                challenge: challenge,
                authorizationCode: authorization.authorizationCode,
                identityToken: authorization.identityToken
            )
            authSession = session
            authUIState = .signedIn(accountID: session.accountID)
            await resumePendingSnapshotSync()
        } catch is CancellationError {
            authUIState = authSession.map { .signedIn(accountID: $0.accountID) } ?? .signedOut
        } catch {
            authUIState = .failed("Appleでのサインインを完了できませんでした")
        }
    }

    func signOutFromFuminiwa() async {
        guard let authSessionCoordinator else {
            authSession = nil
            authUIState = .unavailable
            return
        }
        do {
            try await authSessionCoordinator.signOut()
            authSession = nil
            authUIState = .signedOut
        } catch {
            authUIState = .failed("サインアウトを完了できませんでした")
        }
    }
}
