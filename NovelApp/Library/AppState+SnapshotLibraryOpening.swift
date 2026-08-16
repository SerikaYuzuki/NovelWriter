import Foundation
import NovelCore
import NovelLocalStore
import NovelSync

extension AppState {
    func openSnapshotLibraryWork(
        _ reference: StartupLibraryWorkReference,
        context: StartupDocumentSelectionContext,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard case let .cloudWork(rawWorkID) = reference,
              let row = context.works.first(where: { $0.reference == reference }),
              let workID = UUID(uuidString: rawWorkID.uuidString),
              let worker = localSnapshotSyncWorker,
              let store = localCanonicalStore else { return false }

        if row.availability == .needsReview {
            // Older local works may have been committed before the URL
            // preference was introduced. Reconstructing from SQLite keeps
            // the conflict review reachable instead of silently failing the
            // button when the package path is missing or stale.
            return await openLocalSnapshotCopy(
                workID: workID,
                worker: worker,
                store: store,
                expectedSession: expectedSession
            )
        }

        DeviceSyncLog.snapshot("library open requested work=\(workID.uuidString.lowercased()) availability=\(String(describing: row.availability))")

        if let localURL = snapshotLocalURL(for: workID),
           FileManager.default.fileExists(atPath: localURL.path),
           row.availability != .remoteOnly,
           let loaded = try? await repository.load(from: localURL) {
            let attachments = (try? await loadAttachmentsThrowing(for: localURL)) ?? []
            installDocument(loaded, at: localURL, attachments: attachments)
            await loadSnapshotConflict(for: workID, worker: worker)
            return startupState.isReady
        }

        guard let remote = snapshotRemoteLibraryEntries[workID] else {
            DeviceSyncLog.snapshot("remote library open failed: catalog entry missing")
            return false
        }
        guard let head = remote.head else {
            DeviceSyncLog.snapshot("remote library open failed: head missing")
            return false
        }
        do {
            let payload = try await worker.remoteSnapshot(
                workID: workID,
                snapshotID: head.snapshotID
            )
            guard let object = payload.object(forEntityKey: "work/document") else {
                DeviceSyncLog.snapshot("remote library open failed: missing work/document")
                return false
            }
            let snapshot: WorkSnapshot
            do {
                snapshot = try JSONDecoder().decode(WorkSnapshot.self, from: object.bytes)
            } catch {
                DeviceSyncLog.snapshot("remote library open failed: invalid work/document", error: error)
                return false
            }
            guard snapshot.documentID.rawValue == workID else {
                DeviceSyncLog.snapshot("remote library open failed: document identity mismatch")
                return false
            }
            let document = try snapshot.materializedDocument()
            let destinationURL = Self.availableSaveURL(
                forTitle: document.title,
                fileManager: fileManager,
                directoryName: defaultDocumentDirectoryName
            )
            try await repository.save(document, to: destinationURL)
            let readBack = try await repository.load(from: destinationURL)
            guard readBack == document else { return false }
            let createdAtKey = "fuminiwa.documentCreatedAt.\(workID.uuidString.lowercased())"
            let createdAt = userDefaults.string(forKey: createdAtKey) ?? {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [
                    .withInternetDateTime,
                    .withDashSeparatorInDate,
                    .withColonSeparatorInTime
                ]
                let value = formatter.string(from: Date())
                userDefaults.set(value, forKey: createdAtKey)
                return value
            }()
            let expectedState = try await store.workState(for: workID)
            _ = try await store.installRemoteSnapshot(
                workID: workID,
                documentID: document.id,
                documentCreatedAt: createdAt,
                snapshotID: payload.snapshotID,
                parentSnapshotIDs: payload.parentSnapshotIDs,
                manifest: payload.manifest,
                objects: payload.objects,
                remoteGeneration: head.generation,
                expectedLocalSnapshotID: expectedState?.currentLocalSnapshotID,
                expectedLocalGeneration: expectedState?.localGeneration
            )
            guard documentSessionToken == expectedSession else { return false }
            installDocument(readBack, at: destinationURL, attachments: [])
            userDefaults.set(
                destinationURL.standardizedFileURL.path,
                forKey: "fuminiwa.snapshot.documentURL.\(workID.uuidString.lowercased())"
            )
            return startupState.isReady
        } catch {
            DeviceSyncLog.snapshot("remote library open failed", error: error)
            return false
        }
    }

    private func openLocalSnapshotCopy(
        workID: UUID,
        worker: LocalSnapshotSyncWorker,
        store: LocalSQLiteStore,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        if let localURL = snapshotLocalURL(for: workID),
           FileManager.default.fileExists(atPath: localURL.path),
           let loaded = try? await repository.load(from: localURL) {
            let attachments = (try? await loadAttachmentsThrowing(for: localURL)) ?? []
            installDocument(loaded, at: localURL, attachments: attachments)
            await loadSnapshotConflict(for: workID, worker: worker)
            return startupState.isReady
        }

        do {
            guard let state = try await store.workState(for: workID),
                  let snapshotID = state.currentLocalSnapshotID,
                  let snapshot = try await store.snapshot(id: snapshotID),
                  let objectID = Self.manifestObjectID(snapshot.manifest),
                  let objectBytes = try await store.object(id: objectID) else {
                DeviceSyncLog.snapshot("local snapshot open failed: missing local state")
                return false
            }
            let workSnapshot = try JSONDecoder().decode(WorkSnapshot.self, from: objectBytes)
            guard workSnapshot.documentID.rawValue == workID else {
                DeviceSyncLog.snapshot("local snapshot open failed: document identity mismatch")
                return false
            }
            let document = try workSnapshot.materializedDocument()
            let destinationURL = Self.availableSaveURL(
                forTitle: document.title,
                fileManager: fileManager,
                directoryName: defaultDocumentDirectoryName
            )
            try await repository.save(document, to: destinationURL)
            let readBack = try await repository.load(from: destinationURL)
            guard readBack == document, documentSessionToken == expectedSession else {
                DeviceSyncLog.snapshot("local snapshot open failed: readback or session changed")
                return false
            }
            installDocument(readBack, at: destinationURL, attachments: [])
            userDefaults.set(
                destinationURL.standardizedFileURL.path,
                forKey: "fuminiwa.snapshot.documentURL.\(workID.uuidString.lowercased())"
            )
            await loadSnapshotConflict(for: workID, worker: worker)
            DeviceSyncLog.snapshot("local snapshot materialized for conflict review")
            return startupState.isReady
        } catch {
            DeviceSyncLog.snapshot("local snapshot open failed", error: error)
            return false
        }
    }

    private static func manifestObjectID(_ manifest: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else { return nil }
        return entries.first(where: { $0["entityKey"] as? String == "work/document" })?["objectId"] as? String
    }

    private func snapshotLocalURL(for workID: UUID) -> URL? {
        userDefaults.string(forKey: "fuminiwa.snapshot.documentURL.\(workID.uuidString.lowercased())")
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private func loadSnapshotConflict(
        for workID: UUID,
        worker: LocalSnapshotSyncWorker
    ) async {
        snapshotSyncConflict = try? await worker.conflicts(workID: workID).first
        if snapshotSyncConflict != nil {
            lastSnapshotSyncOutcome = .needsChoice(
                snapshotID: snapshotSyncConflict?.localSnapshotID ?? ""
            )
        }
    }
}
