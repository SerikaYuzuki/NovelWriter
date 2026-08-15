import Foundation
import NovelCore
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("Apple Device Sync blocked pending creation")
struct BlockedPendingCreationTests {
    @Test("verified temporary offline persists and binds a retryable local creation")
    func temporaryOfflinePersistsLocalAuthorityWithoutCompletingIntent() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try await makeStore(root, installAccountScope: true)
        let descriptor = try makeDescriptor()
        let locator = try AppleLocalDocumentLocator.cloudLibrary(workID: descriptor.workID)
        let blocked = makeBlocked(.temporarilyUnavailable, store: store, root: root)

        let first = try await blocked.prepareAndBindPendingWorkCreation(
            locator,
            proposedDescriptor: descriptor,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let persisted = await store.snapshot()
        #expect(persisted.pendingWorkCreations[locator]?.descriptor == descriptor)
        #expect(persisted.bindings[locator]?.binding == first.binding)
        #expect(first.allowedEpisodeIDs == [cloudTestEpisodeID])

        let retried = try await blocked.prepareAndBindPendingWorkCreation(
            locator,
            proposedDescriptor: descriptor,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        #expect(retried.binding == first.binding)
        #expect(await store.pendingWorkCreation(for: locator) != nil)

        let restarted = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: root)
        let local = try #require(try await restarted.resolveLocal(locator))
        #expect(local.binding == first.binding)
        #expect(try await local.workJournal.load(for: descriptor.workID) == nil)
    }

    @Test("unverified and different account states cannot adopt local creations")
    func nonTemporaryOrUnscopedStatesAreRejected() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try await makeStore(root, installAccountScope: true)
        let descriptor = try makeDescriptor()
        let locator = try AppleLocalDocumentLocator.cloudLibrary(workID: descriptor.workID)
        let reasons: [AppleDeviceSyncBlockReason] = [
            .accountUnavailable,
            .differentCloudAccount,
            .runtimeInitializationFailed
        ]
        for reason in reasons {
            let blocked = makeBlocked(reason, store: store, root: root)
            await #expect(throws: AppleDeviceSyncServicesError.blocked(reason)) {
                try await blocked.prepareAndBindPendingWorkCreation(
                    locator,
                    proposedDescriptor: descriptor,
                    allowedEpisodeIDs: [cloudTestEpisodeID]
                )
            }
        }
        #expect(await store.snapshot().pendingWorkCreations.isEmpty)
        #expect(await store.snapshot().bindings.isEmpty)

        let unscopedRoot = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(unscopedRoot) }
        let unscoped = try await makeStore(unscopedRoot, installAccountScope: false)
        let offline = makeBlocked(.temporarilyUnavailable, store: unscoped, root: unscopedRoot)
        await #expect(throws: AppleDeviceSyncServicesError.blocked(.accountUnavailable)) {
            try await offline.prepareAndBindPendingWorkCreation(
                locator,
                proposedDescriptor: descriptor,
                allowedEpisodeIDs: [cloudTestEpisodeID]
            )
        }
        #expect(await unscoped.snapshot().pendingWorkCreations.isEmpty)
        #expect(await unscoped.snapshot().bindings.isEmpty)
    }

    private func makeStore(
        _ root: URL,
        installAccountScope: Bool
    ) async throws -> AppleDeviceSyncMetadataStore {
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        if installAccountScope {
            _ = try await store.installAccountScope(
                AppleCloudAccountScope(
                    containerIdentifier: "iCloud.dev.serikayuzuki.fuminiwa.sync",
                    userRecordName: "blocked-pending-creation-account"
                )
            )
        }
        return store
    }

    private func makeBlocked(
        _ reason: AppleDeviceSyncBlockReason,
        store: AppleDeviceSyncMetadataStore,
        root: URL
    ) -> AppleDeviceSyncBlockedServices {
        AppleDeviceSyncBlockedServices(
            replicaID: store.replicaID,
            reason: reason,
            metadataStore: store,
            journalFactory: AppleDeviceSyncJournalFactory(
                rootURL: root.appendingPathComponent("journals-v1", isDirectory: true),
                metadataStore: store
            )
        )
    }

    private func makeDescriptor() throws -> SyncWorkDescriptor {
        let workID = try #require(UUID(uuidString: "ABABABAB-ABAB-4BAB-8BAB-ABABABABABAB"))
        let documentID = try #require(
            UUID(uuidString: "CDCDCDCD-CDCD-4DCD-8DCD-CDCDCDCDCDCD")
        )
        let digest = try SyncWorkStructureDigest(
            validating: String(repeating: "d", count: 64)
        )
        return SyncWorkDescriptor(
            workID: SyncWorkID(rawValue: workID),
            sourceDocumentID: documentID,
            structureDigest: digest,
            title: "地下鉄で作った作品"
        )
    }
}
