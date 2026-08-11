import Foundation
import NovelCore
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("Apple Device Sync offline journal")
struct AppleDeviceSyncOfflineJournalTests {
    @Test("local bootstrap resolves a bound copy without CloudKit authority")
    func localBootstrapResolvesBoundCopyWithoutCloudKitAuthority() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let bootstrap = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: root)
        _ = try await bootstrap.metadataStore.installAccountScope(
            AppleCloudAccountScope(
                containerIdentifier: "iCloud.dev.serikayuzuki.fuminiwa.sync",
                userRecordName: "account-a"
            )
        )
        let locator = try AppleLocalDocumentLocator(rawValue: "mac.document.local-first")
        let snapshot = try await bootstrap.metadataStore.bind(
            locator,
            to: cloudTestWorkID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )

        let resolved = try #require(try await bootstrap.resolveLocal(locator))

        #expect(resolved.binding == snapshot.binding)
        #expect(resolved.allowedEpisodeIDs == Set([cloudTestEpisodeID]))
        let revision = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "50505050-5050-4050-8050-505050505050")),
            parents: [],
            content: "CloudKitを待たない本文"
        )
        try await resolved.journal.save(
            EpisodeSyncJournalRecord(
                key: cloudTestKey,
                localWorkingCopyID: snapshot.binding.localWorkingCopyID,
                branchID: cloudTestBranchID,
                lastKnownRemoteHead: nil,
                localHead: revision,
                pendingRevisions: [revision]
            )
        )
        let restored = try await resolved.journal.load(for: cloudTestKey)
        #expect(restored?.localHead == revision)

        let workSnapshot = try WorkSnapshot(
            document: .newDocument(title: "地下鉄で編集する作品")
        )
        let workRevision = try WorkRevision(
            workID: cloudTestWorkID,
            parentRevisionIDs: [],
            branchID: cloudTestBranchID,
            authorReplicaID: bootstrap.replicaID,
            authorSessionID: SyncEditSessionID(),
            snapshot: workSnapshot,
            clientCreatedAt: Date(timeIntervalSince1970: 1_723_000_000)
        )
        let workRecord = try WorkSyncJournalRecord(
            workID: cloudTestWorkID,
            localWorkingCopyID: snapshot.binding.localWorkingCopyID,
            replicaID: bootstrap.replicaID,
            branchID: cloudTestBranchID,
            lastKnownRemoteHead: nil,
            localHead: workRevision,
            outbox: [workRevision]
        )
        try await resolved.workJournal.save(workRecord)
        let restoredWork = try await resolved.workJournal.load(for: cloudTestWorkID)
        #expect(restoredWork?.localHead == workRevision)
        #expect(restoredWork?.localWorkingCopyID == snapshot.binding.localWorkingCopyID)
    }

    @Test("blocked services expose only the existing copy's local journal")
    func blockedServicesExposeExistingCopyLocalJournal() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let bootstrap = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: root)
        _ = try await bootstrap.metadataStore.installAccountScope(
            AppleCloudAccountScope(
                containerIdentifier: "iCloud.dev.serikayuzuki.fuminiwa.sync",
                userRecordName: "account-a"
            )
        )
        let locator = try AppleLocalDocumentLocator(rawValue: "ios.document.blocked-local-first")
        let snapshot = try await bootstrap.metadataStore.bind(
            locator,
            to: cloudTestWorkID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        )
        let blocked = AppleDeviceSyncBlockedServices(
            replicaID: bootstrap.replicaID,
            reason: .differentCloudAccount,
            metadataStore: bootstrap.metadataStore,
            journalFactory: bootstrap.journalFactory
        )

        let resolved = try #require(try await blocked.resolveLocal(locator))

        #expect(resolved.binding == snapshot.binding)
        #expect(try await blocked.resolveLocal(
            AppleLocalDocumentLocator(rawValue: "another-copy")
        ) == nil)
    }

    @Test("an existing holder journal remains durable while account checks are unavailable")
    func existingJournalRemainsDurableWhileAccountIsUnavailable() async throws {
        let fixture = try await makeFixture()
        defer { removeCloudTestDirectory(fixture.root) }
        let remote = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "30303030-3030-4030-8030-303030303030")),
            parents: [],
            content: "remote本文"
        )
        let offlineRevision = try makeCloudTestRevision(
            id: #require(UUID(uuidString: "40404040-4040-4040-8040-404040404040")),
            parents: [remote.revisionID],
            content: "account確認待ちの端末内本文"
        )

        _ = await fixture.gate.blockForAccountChange()
        let offlineRecord = try EpisodeSyncJournalRecord(
            key: cloudTestKey,
            localWorkingCopyID: fixture.binding.localWorkingCopyID,
            branchID: cloudTestBranchID,
            lastKnownRemoteHead: remote,
            localHead: offlineRevision,
            pendingRevisions: [offlineRevision]
        )
        try await fixture.journal.save(offlineRecord)

        let restoredFactory = AppleDeviceSyncJournalFactory(
            rootURL: fixture.journalRoot,
            metadataStore: fixture.store
        )
        let restoredJournal = try await restoredFactory.journal(for: fixture.binding)
        let restored = try await restoredJournal.load(for: cloudTestKey)
        #expect(restored?.localHead == offlineRevision)
        #expect(restored?.pendingRevisions.map(\.content) == [
            "account確認待ちの端末内本文"
        ])
    }

    private func makeFixture() async throws -> OfflineJournalFixture {
        let root = try makeCloudTestDirectory()
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        let scope = AppleCloudAccountScope(
            containerIdentifier: "iCloud.dev.serikayuzuki.fuminiwa.sync",
            userRecordName: "account-a"
        )
        _ = try await store.installAccountScope(scope)
        let locator = try AppleLocalDocumentLocator(rawValue: "mac.document.offline-holder")
        let binding = try await store.bind(
            locator,
            to: cloudTestWorkID,
            allowedEpisodeIDs: [cloudTestEpisodeID]
        ).binding
        let gate = AppleDeviceSyncAccountGate(
            expectedScope: scope,
            scopeResolver: { scope }
        )
        let journalRoot = root.appendingPathComponent("journals-v1", isDirectory: true)
        let factory = AppleDeviceSyncJournalFactory(
            rootURL: journalRoot,
            metadataStore: store
        )
        let journal = try await factory.journal(for: binding)
        return OfflineJournalFixture(
            root: root,
            journalRoot: journalRoot,
            store: store,
            binding: binding,
            gate: gate,
            journal: journal
        )
    }
}

private struct OfflineJournalFixture {
    let root: URL
    let journalRoot: URL
    let store: AppleDeviceSyncMetadataStore
    let binding: SyncWorkingCopyBinding
    let gate: AppleDeviceSyncAccountGate
    let journal: any EpisodeSyncJournal
}
