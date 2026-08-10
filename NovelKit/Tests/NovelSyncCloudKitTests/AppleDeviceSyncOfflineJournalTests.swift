import Foundation
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("Apple Device Sync offline journal")
struct AppleDeviceSyncOfflineJournalTests {
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
            branchID: cloudTestBranchID,
            lastKnownRemoteHead: remote,
            localHead: offlineRevision,
            pendingRevisions: [offlineRevision]
        )
        try await fixture.journal.save(offlineRecord)

        let restoredGate = AppleDeviceSyncAccountGate(
            expectedScope: fixture.scope,
            scopeResolver: { fixture.scope }
        )
        let restoredFactory = AppleDeviceSyncJournalFactory(
            rootURL: fixture.journalRoot,
            accountGate: restoredGate,
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
            accountGate: gate,
            metadataStore: store
        )
        let journal = try await factory.journal(for: binding)
        return OfflineJournalFixture(
            root: root,
            journalRoot: journalRoot,
            scope: scope,
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
    let scope: AppleCloudAccountScope
    let store: AppleDeviceSyncMetadataStore
    let binding: SyncWorkingCopyBinding
    let gate: AppleDeviceSyncAccountGate
    let journal: any EpisodeSyncJournal
}
