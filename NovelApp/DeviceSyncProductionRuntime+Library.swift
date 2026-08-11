#if canImport(NovelSyncCloudKit) && !FUMINIWA_ENABLE_EXPERIMENTAL_AI
import Foundation
import NovelSync
import NovelSyncCloudKit

extension DeviceSyncProductionRuntimeBox {
    func loadLibrary() async throws -> DeviceSyncRemoteLibrarySnapshot {
        await retryRemoteBootstrapIfNeeded()
        let snapshot: AppleDeviceSyncLibrarySnapshot
        switch state {
        case let .ready(services):
            snapshot = try await services.loadLibrary()
        case let .blocked(blocked?):
            snapshot = await blocked.loadLibrary()
        case .starting:
            return DeviceSyncRemoteLibrarySnapshot(entries: [], connection: .offline)
        case .blocked(nil):
            return DeviceSyncRemoteLibrarySnapshot(entries: [], connection: .accountRequired)
        }
        return DeviceSyncRemoteLibrarySnapshot(
            entries: snapshot.entries.map {
                DeviceSyncRemoteLibraryEntry(
                    work: $0.work,
                    availability: Self.libraryAvailability($0.availability)
                )
            },
            connection: Self.libraryConnection(snapshot.connection)
        )
    }

    func prepareLibraryOpen(
        _ expected: SyncWorkLibraryEntry
    ) async throws -> DeviceSyncPreparedLibraryWork {
        let prepared = try await readyServices().prepareOpen(expected)
        return try makePreparedLibraryWork(prepared)
    }

    func resumeLibraryOpen(
        _ workID: SyncWorkID
    ) async throws -> DeviceSyncPreparedLibraryWork {
        let prepared: AppleDeviceSyncPreparedRemoteWork
        switch state {
        case let .ready(services):
            prepared = try await services.resumePendingOpen(workID)
        case let .blocked(blocked?):
            prepared = try await blocked.resumePendingOpen(workID)
        case .starting, .blocked(nil):
            throw EpisodeSyncTransportError.unavailable
        }
        return try makePreparedLibraryWork(prepared)
    }

    func canResumeLibraryOpenOffline(_ workID: SyncWorkID) async -> Bool {
        switch state {
        case let .ready(services):
            await services.canResumePendingOpenOffline(workID)
        case let .blocked(blocked?):
            await blocked.canResumePendingOpenOffline(workID)
        case .starting, .blocked(nil):
            false
        }
    }

    func offlineResumableLibraryOpenWorkIDs() async -> [SyncWorkID] {
        switch state {
        case let .ready(services):
            await services.offlineResumablePendingOpenWorkIDs()
        case let .blocked(blocked?):
            await blocked.offlineResumablePendingOpenWorkIDs()
        case .starting, .blocked(nil):
            []
        }
    }

    func hasCompletedLibraryOpenLocally(
        _ expected: SyncWorkLibraryEntry
    ) async -> Bool {
        switch state {
        case let .ready(services):
            await services.hasCompletedRemoteOpenLocally(expected)
        case let .blocked(blocked?):
            await blocked.hasCompletedRemoteOpenLocally(expected)
        case .starting, .blocked(nil):
            false
        }
    }

    func libraryWorkNeedsReview(
        workID: SyncWorkID,
        documentID: UUID
    ) async throws -> Bool {
        let url = try workingCopyRoot.destination(for: workID)
        let session = DocumentSessionToken(
            generation: 0,
            documentID: documentID,
            documentURL: url
        )
        guard let resolution = try await resolveLocalWork(
            session: session,
            localSourceDocumentID: documentID
        ),
            resolution.binding.workID == workID,
            let journal = resolution.workJournal,
            let record = try await journal.load(for: workID) else {
            return false
        }
        return record.conflictReview != nil
            || record.reconciliationStatus == WorkReconciliationStatus.reviewRequired
    }

    func hasLocalPublishAuthority(
        workID: SyncWorkID,
        documentID: UUID
    ) async -> Bool {
        do {
            let url = try workingCopyRoot.destination(for: workID)
            let session = DocumentSessionToken(
                generation: 0,
                documentID: documentID,
                documentURL: url
            )
            guard let resolved = try await resolveLocalWork(
                session: session,
                localSourceDocumentID: documentID
            ) else { return false }
            return resolved.binding.workID == workID
        } catch {
            return false
        }
    }

    private func makePreparedLibraryWork(
        _ prepared: AppleDeviceSyncPreparedRemoteWork
    ) throws -> DeviceSyncPreparedLibraryWork {
        let document = try prepared.materializedDocument()
        return DeviceSyncPreparedLibraryWork(
            entry: prepared.entry,
            document: document,
            packageSnapshot: prepared.revision.snapshot,
            bind: { [weak self] packageSnapshot in
                guard let self else { throw AppleDeviceSyncServicesError.pendingLibraryOpenMismatch }
                try await bindLibraryOpen(prepared, packageSnapshot: packageSnapshot)
            }
        )
    }

    private func bindLibraryOpen(
        _ prepared: AppleDeviceSyncPreparedRemoteWork,
        packageSnapshot: WorkSnapshot
    ) async throws {
        let resolved: AppleResolvedWorkingCopy
        switch state {
        case let .ready(services):
            resolved = try await services.bindPreparedOpen(
                prepared,
                packageSnapshot: packageSnapshot
            )
        case let .blocked(blocked?):
            resolved = try await blocked.bindPreparedOpen(
                prepared,
                packageSnapshot: packageSnapshot
            )
        case .starting, .blocked(nil):
            throw EpisodeSyncTransportError.unavailable
        }
        knownBoundLocators.insert(prepared.destinationLocator)
        guard resolved.binding.workID == prepared.entry.workID else {
            throw AppleDeviceSyncServicesError.pendingLibraryOpenMismatch
        }
        signalContinuation.yield()
    }

    private static func libraryConnection(
        _ connection: AppleDeviceSyncLibraryConnection
    ) -> DeviceSyncLibraryConnection {
        switch connection {
        case .available:
            .available
        case .offline:
            .offline
        case .accountRequired:
            .accountRequired
        case .differentAccount:
            .differentAccount
        }
    }

    private static func libraryAvailability(
        _ availability: AppleDeviceSyncLibraryAvailability
    ) -> DeviceSyncRemoteLibraryAvailability {
        switch availability {
        case .locallyBound:
            .locallyBound
        case .remoteOnly:
            .remoteOnly
        case .remoteDownloadPending:
            .remoteDownloadPending
        case .publishPending:
            .publishPending
        }
    }
}
#endif
