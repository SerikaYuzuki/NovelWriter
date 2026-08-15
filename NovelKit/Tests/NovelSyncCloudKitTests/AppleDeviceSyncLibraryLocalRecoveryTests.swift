import Foundation
import NovelCore
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("Apple Device Sync library local recovery")
struct AppleDeviceSyncLibraryLocalRecoveryTests {
    @Test("staged pending IDs resume after the App-registry crash window without leaking accounts")
    func identityOnlyPendingRecoveryAndCompletedAttestation() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let setup = try await makeSetup(root)
        let prepared = try await setup.coordinator.prepareOpen(setup.entry, remote: setup.remote)

        let restartedStore = try AppleDeviceSyncMetadataStore(rootURL: root)
        let restartedFactory = makeJournalFactory(root, store: restartedStore)
        let offline = blocked(.temporarilyUnavailable, restartedStore, restartedFactory)
        #expect(await offline.offlineResumablePendingOpenWorkIDs() == [setup.entry.workID])
        #expect(await offline.hasCompletedRemoteOpenLocally(setup.entry) == false)

        let quarantinedReasons: [AppleDeviceSyncBlockReason] = [
            .accountUnavailable,
            .differentCloudAccount,
            .runtimeInitializationFailed
        ]
        for reason in quarantinedReasons {
            let service = blocked(reason, restartedStore, restartedFactory)
            #expect(await service.offlineResumablePendingOpenWorkIDs().isEmpty)
        }

        _ = try await offline.bindPreparedOpen(prepared, packageSnapshot: setup.revision.snapshot)
        #expect(await offline.offlineResumablePendingOpenWorkIDs().isEmpty)
        #expect(await offline.hasCompletedRemoteOpenLocally(setup.entry))

        let newerRevision = try makeWorkRevision(
            id: #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444")),
            parents: [setup.revision.revisionID],
            title: "別端末の新しい版"
        )
        let newerEntry = try SyncWorkLibraryEntry(head: newerRevision)
        #expect(await offline.hasCompletedRemoteOpenLocally(newerEntry) == false)
    }

    @Test("completion proof survives acknowledgement and rejects a local outbox")
    func completedAttestationRequiresExactOutboxFreeJournal() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let setup = try await makeSetup(root)
        let prepared = try await setup.coordinator.prepareOpen(setup.entry, remote: setup.remote)
        let resolved = try await setup.coordinator.completePreparedOpen(
            prepared,
            packageSnapshot: setup.revision.snapshot
        )
        #expect(await setup.coordinator.hasCompletedRemoteOpenLocally(setup.entry))

        let workCoordinator = WorkSyncCoordinator(
            workID: setup.entry.workID,
            localWorkingCopyID: resolved.binding.localWorkingCopyID,
            replicaID: setup.store.replicaID,
            sessionID: SyncEditSessionID(),
            transport: RecoveryUnavailableTransport(),
            journal: resolved.workJournal
        )
        _ = try #require(try await workCoordinator.restore())
        try await workCoordinator.acknowledgeRemoteMaterialization(
            setup.revision.revisionID,
            packageSnapshot: setup.revision.snapshot
        )
        #expect(await setup.coordinator.hasCompletedRemoteOpenLocally(setup.entry))

        let changed = try makeCloudTestWorkSnapshot(title: "端末内で変更した作品")
        let staged = try await workCoordinator.stageLocalSnapshot(changed, at: cloudTestDate)
        try await workCoordinator.confirmLocalSnapshotMaterialized(
            staged.revisionID,
            packageSnapshot: changed
        )
        #expect(await setup.coordinator.hasCompletedRemoteOpenLocally(setup.entry) == false)
    }

    private func makeSetup(_ root: URL) async throws -> LocalRecoverySetup {
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        _ = try await store.installAccountScope(
            AppleCloudAccountScope(
                containerIdentifier: "iCloud.dev.serikayuzuki.fuminiwa.sync",
                userRecordName: "library-local-recovery-test-account"
            )
        )
        let revision = try makeWorkRevision()
        let entry = try SyncWorkLibraryEntry(head: revision)
        let remote = RecoveryLibraryRemote(entry: entry, revision: revision)
        let factory = makeJournalFactory(root, store: store)
        return LocalRecoverySetup(
            store: store,
            coordinator: AppleDeviceSyncLibraryOpenCoordinator(
                replicaID: store.replicaID,
                metadataStore: store,
                journalFactory: factory
            ),
            remote: remote,
            revision: revision,
            entry: entry
        )
    }

    private func makeJournalFactory(
        _ root: URL,
        store: AppleDeviceSyncMetadataStore
    ) -> AppleDeviceSyncJournalFactory {
        AppleDeviceSyncJournalFactory(
            rootURL: root.appendingPathComponent("journals-v1", isDirectory: true),
            metadataStore: store
        )
    }

    private func blocked(
        _ reason: AppleDeviceSyncBlockReason,
        _ store: AppleDeviceSyncMetadataStore,
        _ factory: AppleDeviceSyncJournalFactory
    ) -> AppleDeviceSyncBlockedServices {
        AppleDeviceSyncBlockedServices(
            replicaID: store.replicaID,
            reason: reason,
            metadataStore: store,
            journalFactory: factory
        )
    }
}

private struct LocalRecoverySetup {
    let store: AppleDeviceSyncMetadataStore
    let coordinator: AppleDeviceSyncLibraryOpenCoordinator
    let remote: RecoveryLibraryRemote
    let revision: WorkRevision
    let entry: SyncWorkLibraryEntry
}

private actor RecoveryLibraryRemote: AppleDeviceSyncLibraryRemote {
    let entry: SyncWorkLibraryEntry
    let revision: WorkRevision

    init(entry: SyncWorkLibraryEntry, revision: WorkRevision) {
        self.entry = entry
        self.revision = revision
    }

    func listLibraryWorks() async throws -> [SyncWorkLibraryEntry] {
        [entry]
    }

    func fetchSnapshot(for _: SyncWorkID) async throws -> WorkRemoteSnapshot {
        WorkRemoteSnapshot(head: revision)
    }

    func fetchRevision(_ id: SyncRevisionID, for workID: SyncWorkID) async throws -> WorkRevision {
        guard id == revision.revisionID, workID == revision.workID else {
            throw WorkSyncTransportError.missingRevision
        }
        return revision
    }

    func publish(_: WorkPublishRequest) async throws -> WorkPublishResult {
        throw WorkSyncTransportError.unavailable
    }
}

private actor RecoveryUnavailableTransport: WorkSyncTransport {
    func fetchSnapshot(for _: SyncWorkID) async throws -> WorkRemoteSnapshot {
        throw WorkSyncTransportError.unavailable
    }

    func fetchRevision(_: SyncRevisionID, for _: SyncWorkID) async throws -> WorkRevision {
        throw WorkSyncTransportError.unavailable
    }

    func publish(_: WorkPublishRequest) async throws -> WorkPublishResult {
        throw WorkSyncTransportError.unavailable
    }
}
