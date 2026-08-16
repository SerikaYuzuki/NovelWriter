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

        if row.availability == .needsReview,
           let localURL = snapshotLocalURL(for: workID),
           let loaded = try? await repository.load(from: localURL) {
            let attachments = (try? await loadAttachmentsThrowing(for: localURL)) ?? []
            installDocument(loaded, at: localURL, attachments: attachments)
            await loadSnapshotConflict(for: workID, worker: worker)
            return startupState.isReady
        }

        if let localURL = snapshotLocalURL(for: workID),
           FileManager.default.fileExists(atPath: localURL.path),
           row.availability != .remoteOnly,
           let loaded = try? await repository.load(from: localURL) {
            let attachments = (try? await loadAttachmentsThrowing(for: localURL)) ?? []
            installDocument(loaded, at: localURL, attachments: attachments)
            await loadSnapshotConflict(for: workID, worker: worker)
            return startupState.isReady
        }

        guard let remote = snapshotRemoteLibraryEntries[workID],
              let head = remote.head else { return false }
        do {
            let payload = try await worker.remoteSnapshot(
                workID: workID,
                snapshotID: head.snapshotID
            )
            guard let object = payload.objects.first,
                  let snapshot = try? JSONDecoder().decode(WorkSnapshot.self, from: object.bytes),
                  snapshot.documentID.rawValue == workID else { return false }
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
