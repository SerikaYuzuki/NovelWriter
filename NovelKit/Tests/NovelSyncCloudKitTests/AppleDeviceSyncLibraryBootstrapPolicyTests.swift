import CloudKit
import Foundation
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("Apple Device Sync cloud library bootstrap policy")
struct AppleDeviceSyncBootstrapPolicyTests {
    @Test("only a scoped pristine zone may bootstrap a missing zone")
    func pristineZonePolicy() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)

        let unscoped = await store.snapshot()
        #expect(!permits(.zoneUnavailable, metadata: unscoped))
        _ = try await store.installAccountScope(testAccountScope)
        let clean = await store.snapshot()

        #expect(permits(.zoneUnavailable, metadata: clean))
        #expect(permits(.invalidArguments, metadata: clean))
        #expect(permits(.recordNotFound, metadata: clean))
        #expect(permits(.partialFailure([.unknownItem]), metadata: clean))
        #expect(
            AppleDeviceSyncLibraryBootstrapPolicy.permitsEmptyAvailableCatalog(
                for: CloudKitErrorMapper.map(CKError(.unknownItem)),
                metadata: clean
            )
        )
        #expect(!permits(.zoneReset, metadata: clean))
        #expect(!permits(.invalidRemoteRecord, metadata: clean))
        #expect(!permits(.accountUnavailable(.noAccount), metadata: clean))
        #expect(
            AppleDeviceSyncLibraryBootstrapPolicy.isEmptyCatalogSchemaError(
                CloudKitSyncAdapterError.recordNotFound
            )
        )
        #expect(
            AppleDeviceSyncLibraryBootstrapPolicy.isEmptyCatalogSchemaError(
                CloudKitSyncAdapterError.zoneUnavailable
            )
        )
    }

    @Test("schema bootstrap requires an exact pending create and binding")
    func exactPendingCreatePolicy() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try await preparedStore(root)
        let locator = try AppleLocalDocumentLocator(rawValue: "clean.pending-create")
        let descriptor = try pendingDescriptor()

        _ = try await store.preparePendingWorkCreation(
            locator,
            proposedDescriptor: descriptor,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let unboundPending = await store.snapshot()
        #expect(permits(.invalidArguments, metadata: unboundPending))
        #expect(permits(.recordNotFound, metadata: unboundPending))

        _ = try await store.bind(
            locator,
            to: descriptor.workID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let pending = await store.snapshot()
        #expect(pending.permitsPendingCreateSchemaBootstrap)
        #expect(permits(.zoneUnavailable, metadata: pending))
        #expect(permits(.invalidArguments, metadata: pending))
    }

    @Test("empty catalog listing still knows local binding identities")
    func knownIdentitiesAreMissingFromEmptyListing() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try await preparedStore(root)
        let locator = try AppleLocalDocumentLocator(rawValue: "known.binding")
        _ = try await store.bind(
            locator,
            to: cloudTestWorkID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let metadata = await store.snapshot()
        let missing = AppleDeviceSyncKnownCatalogIdentities.missingWorkIDs(
            listed: [],
            metadata: metadata
        )
        #expect(missing == [cloudTestWorkID])

        let listed = try [SyncWorkLibraryEntry(descriptor: pendingDescriptor())]
        #expect(
            AppleDeviceSyncKnownCatalogIdentities.missingWorkIDs(
                listed: listed,
                metadata: metadata
            ).isEmpty
        )
        let fetched = try SyncWorkLibraryEntry(descriptor: pendingDescriptor())
        let merged = AppleDeviceSyncKnownCatalogIdentities.merging(
            listed: [],
            fetched: [fetched]
        )
        #expect(merged.map(\.workID) == [cloudTestWorkID])
    }

    @Test("catalog-discovered unbound works stay visible when backfill adds extra local IDs")
    func catalogDiscoveredRemoteOnlyIsNotHiddenByBackfill() {
        let discovered = SyncWorkID()
        #expect(
            AppleDeviceSyncLibraryRemoteVisibility.availability(
                workID: discovered,
                isBound: false,
                includeAllRemoteOnly: false,
                catalogDiscoveredWorkIDs: [discovered]
            ) == .remoteOnly
        )
        #expect(
            AppleDeviceSyncLibraryRemoteVisibility.availability(
                workID: discovered,
                isBound: false,
                includeAllRemoteOnly: false,
                catalogDiscoveredWorkIDs: []
            ) == nil
        )
        #expect(
            AppleDeviceSyncLibraryRemoteVisibility.availability(
                workID: cloudTestWorkID,
                isBound: true,
                includeAllRemoteOnly: false,
                catalogDiscoveredWorkIDs: []
            ) == .locallyBound
        )
    }

    @Test("confirmed local binding still treats Note schema errors as empty catalog")
    func confirmedBindingAllowsNoteSchemaEmptyCatalog() async throws {
        let confirmedRoot = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(confirmedRoot) }
        let confirmed = try await preparedStore(confirmedRoot)
        let locator = try AppleLocalDocumentLocator(rawValue: "confirmed.binding")
        _ = try await confirmed.bind(
            locator,
            to: cloudTestWorkID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let confirmedSnapshot = await confirmed.snapshot()
        #expect(!permits(.zoneUnavailable, metadata: confirmedSnapshot))
        #expect(permits(.invalidArguments, metadata: confirmedSnapshot))
        #expect(permits(.recordNotFound, metadata: confirmedSnapshot))
        #expect(
            permits(
                CloudKitErrorMapper.map(
                    CKError(
                        .invalidArguments,
                        userInfo: [
                            NSUnderlyingErrorKey: NSError(
                                domain: "CKInternalErrorDomain",
                                code: 2015
                            )
                        ]
                    )
                ),
                metadata: confirmedSnapshot
            )
        )
    }

    @Test("cached remotes stay fail-closed")
    func cachedRemoteEvidencePolicy() async throws {
        let cachedRoot = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(cachedRoot) }
        let cached = try await preparedStore(cachedRoot)
        let entry = try SyncWorkLibraryEntry(head: makeWorkRevision())
        try await cached.replaceCachedLibraryEntries([entry])
        let cachedSnapshot = await cached.snapshot()
        #expect(!permits(.zoneUnavailable, metadata: cachedSnapshot))
        #expect(!permits(.invalidArguments, metadata: cachedSnapshot))
        #expect(!permits(.recordNotFound, metadata: cachedSnapshot))
    }

    @Test("pending downloads stay fail-closed; mismatched bindings still allow Note schema empty catalog")
    func pendingAndMismatchedEvidencePolicy() async throws {
        let pendingOpenRoot = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(pendingOpenRoot) }
        let pendingOpen = try await preparedStore(pendingOpenRoot)
        _ = try await pendingOpen.preparePendingLibraryOpen(
            SyncWorkLibraryEntry(head: makeWorkRevision())
        )
        let pendingOpenSnapshot = await pendingOpen.snapshot()
        #expect(!permits(.invalidArguments, metadata: pendingOpenSnapshot))

        let mismatchedRoot = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(mismatchedRoot) }
        let mismatched = try await preparedStore(mismatchedRoot)
        let pendingLocator = try AppleLocalDocumentLocator(rawValue: "mismatch.pending")
        _ = try await mismatched.preparePendingWorkCreation(
            pendingLocator,
            proposedDescriptor: pendingDescriptor(),
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let unrelatedLocator = try AppleLocalDocumentLocator(rawValue: "mismatch.binding")
        let unrelatedUUID = try #require(
            UUID(uuidString: "99999999-9999-4999-8999-999999999999")
        )
        let unrelatedWorkID = SyncWorkID(rawValue: unrelatedUUID)
        _ = try await mismatched.bind(
            unrelatedLocator,
            to: unrelatedWorkID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let snapshot = await mismatched.snapshot()
        #expect(snapshot.bindings.count == snapshot.pendingWorkCreations.count)
        #expect(!permits(.zoneUnavailable, metadata: snapshot))
        #expect(permits(.invalidArguments, metadata: snapshot))
    }

    private var testAccountScope: AppleCloudAccountScope {
        AppleCloudAccountScope(
            containerIdentifier: "iCloud.dev.serikayuzuki.fuminiwa.sync",
            userRecordName: "clean-container-account"
        )
    }

    private func preparedStore(_ root: URL) async throws -> AppleDeviceSyncMetadataStore {
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        _ = try await store.installAccountScope(testAccountScope)
        return store
    }

    private func pendingDescriptor() throws -> SyncWorkDescriptor {
        try SyncWorkDescriptor(
            workID: cloudTestWorkID,
            sourceDocumentID: #require(
                UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
            ),
            structureDigest: SyncWorkStructureDigest(
                validating: String(repeating: "b", count: 64)
            ),
            title: "初回作成"
        )
    }

    private func permits(
        _ error: CloudKitSyncAdapterError,
        metadata: AppleDeviceSyncMetadataSnapshot
    ) -> Bool {
        AppleDeviceSyncLibraryBootstrapPolicy.permitsEmptyAvailableCatalog(
            for: error,
            metadata: metadata
        )
    }
}
