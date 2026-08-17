import Foundation
import NovelCore
import NovelSync

struct IOSDeviceSyncPreparationRecovery {
    let content: String
    let identity: IOSDeviceSyncEpisodeIdentity
    let state: EpisodeSyncState
}

enum IOSPackageOnlyDeviceSyncRecovery: Equatable {
    case recovered
    case packageWins
    case preserveMarker
}

struct IOSPreparedDeviceSyncPackageCheckpoints {
    var checkpoints: [IOSDeviceSyncPackageCheckpoint] = []
    var allPrepared = true
}

extension IOSDocumentStore {
    func performCoordinatedDocumentSave(
        _ document: NovelDocument,
        to url: URL
    ) async throws {
        if snapshotSyncV2Application != nil {
            guard await checkpointSnapshotSyncV2(document, reason: .autosave) else {
                throw IOSPrivateWorkingCopyLocationError.unsafeRoot
            }
            // Snapshot Sync v2 owns the durable local authority.  A novpkg is
            // deliberately not rewritten during ordinary autosave; it is an
            // import/export boundary only.
            return
        }
        if usesSnapshotSyncRuntime {
            try await repository.save(document, to: url)
            noteDeviceSyncPackageSaved(document)
            guard await commitLocalCanonicalSnapshot(document) else {
                deviceSyncLocalDurabilityState = .failed
                return
            }
            deviceSyncLocalDurabilityState = .saved
            deviceSyncTransferState = .notApplicable
            scheduleSnapshotSync(for: document.id)
            return
        }
        if usesWholeWorkDeviceSync {
            try await performCoordinatedWorkDocumentSave(document, to: url)
            return
        }
        let intentReady = await flushPendingDeviceSyncEditIntents()
        let checkpoints = await prepareDeviceSyncPackageCheckpoints(for: document, at: url)
        guard let privateWorkingCopyLocation else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        _ = try privateWorkingCopyLocation.attestPackage(at: url)
        try await repository.save(document, to: url)
        noteDeviceSyncPackageSaved(document)
        try await recordCloudLibraryPackageMutationIfNeeded(document, at: url)
        let checkpointsCommitted = await commitDeviceSyncPackageCheckpoints(checkpoints)
        if !intentReady || !checkpoints.allPrepared || !checkpointsCommitted {
            deviceSyncLocalDurabilityState = .failed
        }
        // NovelpkgRepositoryのatomic replaceではpackage inodeが正当に変わる。
        // fixed rootを再証明し、置換後の新package identityを次の基準にする。
        _ = try privateWorkingCopyLocation.attestPackage(at: url)
    }
}
