import Foundation
import NovelCore
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("Apple Device Sync cloud library metadata")
struct AppleDeviceSyncLibraryMetadataTests {
    @Test("downloaded old head resumes offline after remote advances and process restarts")
    func downloadedHeadResumesOfflineAcrossConcurrentPublish() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let firstStore = try await preparedStore(root)
        let journalRoot = root.appendingPathComponent("journals-v1", isDirectory: true)
        let firstFactory = AppleDeviceSyncJournalFactory(
            rootURL: journalRoot,
            metadataStore: firstStore
        )
        let revisionA = try makeWorkRevision()
        let entryA = try SyncWorkLibraryEntry(head: revisionA)
        let revisionB = try makeWorkRevision(
            id: #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444")),
            parents: [revisionA.revisionID],
            title: "別端末で更新された作品"
        )
        let entryB = try SyncWorkLibraryEntry(head: revisionB)
        let remote = AdvancingLibraryWorkRemote(
            currentEntry: entryA,
            revisions: [revisionA, revisionB]
        )
        let firstCoordinator = AppleDeviceSyncLibraryOpenCoordinator(
            replicaID: firstStore.replicaID,
            metadataStore: firstStore,
            journalFactory: firstFactory
        )

        let downloaded = try await firstCoordinator.prepareOpen(entryA, remote: remote)
        #expect(downloaded.revision == revisionA)
        await remote.advance(to: entryB)

        // The package was installed and attested, then the process died before
        // bindPreparedOpen. The next launch has no usable account/network.
        let restartedStore = try AppleDeviceSyncMetadataStore(rootURL: root)
        let restartedFactory = AppleDeviceSyncJournalFactory(
            rootURL: journalRoot,
            metadataStore: restartedStore
        )
        let blocked = AppleDeviceSyncBlockedServices(
            replicaID: restartedStore.replicaID,
            reason: .temporarilyUnavailable,
            metadataStore: restartedStore,
            journalFactory: restartedFactory
        )
        let resumed = try await blocked.resumePendingOpen(entryA.workID)
        #expect(resumed.entry == entryA)
        #expect(resumed.revision == revisionA)
        #expect(await blocked.canResumePendingOpenOffline(entryA.workID))
        #expect(await remote.observationCounts() == RemoteObservationCounts(lists: 1, fetches: 1))

        await #expect(throws: AppleDeviceSyncServicesError.packageSnapshotMismatch) {
            try await blocked.bindPreparedOpen(resumed, packageSnapshot: revisionB.snapshot)
        }
        #expect(await restartedStore.pendingLibraryOpen(workID: entryA.workID) != nil)

        let resolved = try await blocked.bindPreparedOpen(
            resumed,
            packageSnapshot: revisionA.snapshot
        )
        #expect(resolved.descriptor.title == "地下鉄で書いた作品")
        #expect(await restartedStore.pendingLibraryOpen(workID: entryA.workID) == nil)
        #expect(try await blocked.resolveLocal(resumed.destinationLocator) != nil)
        #expect(await blocked.canResumePendingOpenOffline(entryA.workID) == false)

        let completedBootstrap = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: root)
        #expect(try await completedBootstrap.resolveLocal(resumed.destinationLocator) != nil)

        let record = try #require(try await resolved.workJournal.load(for: entryA.workID))
        #expect(record.localHead == revisionA)
        #expect(record.lastKnownRemoteHead == revisionA)
        #expect(record.outbox.isEmpty)
        #expect(record.pendingRemoteMaterialization?.revision == revisionA)
    }

    @Test("remote-open intent, locator, binding, and outbox-free bootstrap survive every kill window")
    func remoteOpenTwoPhaseRestartSafety() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let firstStore = try await preparedStore(root)
        let revision = try makeWorkRevision()
        let entry = try SyncWorkLibraryEntry(head: revision)
        let firstIntent = try await firstStore.preparePendingLibraryOpen(entry)

        let afterDownloadRestart = try AppleDeviceSyncMetadataStore(rootURL: root)
        let resumedIntent = try await afterDownloadRestart.preparePendingLibraryOpen(entry)
        #expect(resumedIntent == firstIntent)
        #expect(
            try resumedIntent.locator
                == (AppleLocalDocumentLocator.cloudLibrary(workID: entry.workID))
        )

        let document = try revision.snapshot.materializedDocument()
        let binding = try await afterDownloadRestart.bind(
            resumedIntent.locator,
            to: entry.workID,
            allowedEpisodeIDs: document.chapters.flatMap(\.episodes).map(\.id)
        )
        let unresolvedBootstrap = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: root)
        #expect(try await unresolvedBootstrap.resolveLocal(resumedIntent.locator) == nil)

        let journalStore = try AppleDeviceSyncMetadataStore(rootURL: root)
        let journalFactory = AppleDeviceSyncJournalFactory(
            rootURL: root.appendingPathComponent(
                AppleDeviceSyncServices.journalDirectoryName,
                isDirectory: true
            ),
            metadataStore: journalStore
        )
        let workJournal = try await journalFactory.workJournal(for: binding.binding)
        let coordinator = WorkSyncCoordinator(
            workID: entry.workID,
            localWorkingCopyID: binding.binding.localWorkingCopyID,
            replicaID: journalStore.replicaID,
            sessionID: SyncEditSessionID(),
            transport: UnavailableLibraryWorkTransport(),
            journal: workJournal
        )
        _ = try await coordinator.bootstrapRemoteRevision(revision)

        let afterJournalRestart = try AppleDeviceSyncMetadataStore(rootURL: root)
        let stillPending = try #require(
            await afterJournalRestart.pendingLibraryOpen(token: firstIntent.token)
        )
        #expect(stillPending == firstIntent)
        try await afterJournalRestart.completePendingLibraryOpen(stillPending)

        let completedBootstrap = try AppleDeviceSyncLocalBootstrap.prepare(rootURL: root)
        let resolved = try #require(
            try await completedBootstrap.resolveLocal(firstIntent.locator)
        )
        #expect(resolved.binding == binding.binding)
        let restored = WorkSyncCoordinator(
            workID: entry.workID,
            localWorkingCopyID: binding.binding.localWorkingCopyID,
            replicaID: completedBootstrap.replicaID,
            sessionID: SyncEditSessionID(),
            transport: UnavailableLibraryWorkTransport(),
            journal: resolved.workJournal
        )
        let state = try #require(try await restored.restore())
        #expect(state.localHead == revision)
        #expect(state.lastKnownRemoteHead == revision)
        #expect(state.pendingRevisionCount == 0)
        #expect(state.pendingRemoteMaterialization?.revision == revision)
    }

    @Test("bounded projections cover the maximum offline catalog inside metadata cap")
    func maximumCachedCatalogFitsMetadataCap() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try await preparedStore(root)
        let structure = try SyncWorkStructureDigest(validating: String(repeating: "a", count: 64))
        let title = String(
            repeating: "x",
            count: SyncWorkLibraryEntry.maximumDisplayTitleUTF8Bytes
        )
        let entries = try (0 ..< AppleDeviceSyncMetadataStore.maximumCachedLibraryEntryCount)
            .map { index in
                try SyncWorkLibraryEntry(
                    workID: SyncWorkID(),
                    sourceDocumentID: UUID(),
                    structureDigest: structure,
                    title: title,
                    titleDigest: SyncContentDigest(content: title),
                    fullTitleUTF8ByteCount: title.utf8.count,
                    headRevisionID: SyncRevisionID(),
                    headSnapshotDigest: SyncContentDigest(content: "snapshot-\(index)"),
                    headSnapshotByteCount: 1,
                    headClientCreatedAt: cloudTestDate
                )
            }
        try await store.replaceCachedLibraryEntries(entries)

        let metadataURL = root.appendingPathComponent(
            AppleDeviceSyncMetadataStore.metadataFileName
        )
        let byteCount = try #require(
            metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        #expect(byteCount <= AppleDeviceSyncMetadataStore.maximumMetadataBytes)
        #expect(await store.snapshot().cachedLibraryEntries.count == entries.count)
    }

    @Test("unverified account quarantines cached remote titles and maps temporary loss to offline")
    func blockedLibraryQuarantinesRemoteCatalog() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try await preparedStore(root)
        let entry = try SyncWorkLibraryEntry(head: makeWorkRevision())
        try await store.replaceCachedLibraryEntries([entry])
        _ = try await store.preparePendingLibraryOpen(entry)
        let journalFactory = AppleDeviceSyncJournalFactory(
            rootURL: root.appendingPathComponent("journals-v1", isDirectory: true),
            metadataStore: store
        )
        let temporarilyBlocked = AppleDeviceSyncBlockedServices(
            replicaID: store.replicaID,
            reason: .temporarilyUnavailable,
            metadataStore: store,
            journalFactory: journalFactory
        )
        let differentAccount = AppleDeviceSyncBlockedServices(
            replicaID: store.replicaID,
            reason: .differentCloudAccount,
            metadataStore: store,
            journalFactory: journalFactory
        )

        let offline = await temporarilyBlocked.loadLibrary()
        #expect(offline.connection == .offline)
        #expect(offline.entries.isEmpty)
        let quarantined = await differentAccount.loadLibrary()
        #expect(quarantined.connection == .differentAccount)
        #expect(quarantined.entries.isEmpty)
    }

    private func preparedStore(_ root: URL) async throws -> AppleDeviceSyncMetadataStore {
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        _ = try await store.installAccountScope(
            AppleCloudAccountScope(
                containerIdentifier: "iCloud.dev.serikayuzuki.fuminiwa.sync",
                userRecordName: "library-test-account"
            )
        )
        return store
    }
}

private actor UnavailableLibraryWorkTransport: WorkSyncTransport {
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

private struct RemoteObservationCounts: Equatable {
    let lists: Int
    let fetches: Int
}

private actor AdvancingLibraryWorkRemote: AppleDeviceSyncLibraryRemote {
    private var currentEntry: SyncWorkLibraryEntry
    private let revisions: [SyncRevisionID: WorkRevision]
    private var listCount = 0
    private var fetchCount = 0

    init(currentEntry: SyncWorkLibraryEntry, revisions: [WorkRevision]) {
        self.currentEntry = currentEntry
        self.revisions = Dictionary(uniqueKeysWithValues: revisions.map {
            ($0.revisionID, $0)
        })
    }

    func advance(to entry: SyncWorkLibraryEntry) {
        currentEntry = entry
    }

    func observationCounts() -> RemoteObservationCounts {
        RemoteObservationCounts(lists: listCount, fetches: fetchCount)
    }

    func listLibraryWorks() async throws -> [SyncWorkLibraryEntry] {
        listCount += 1
        return [currentEntry]
    }

    func fetchSnapshot(for _: SyncWorkID) async throws -> WorkRemoteSnapshot {
        guard let headID = currentEntry.headRevisionID,
              let revision = revisions[headID] else {
            return WorkRemoteSnapshot(head: nil)
        }
        return WorkRemoteSnapshot(head: revision)
    }

    func fetchRevision(
        _ id: SyncRevisionID,
        for workID: SyncWorkID
    ) async throws -> WorkRevision {
        fetchCount += 1
        guard let revision = revisions[id], revision.workID == workID else {
            throw WorkSyncTransportError.missingRevision
        }
        return revision
    }

    func publish(_: WorkPublishRequest) async throws -> WorkPublishResult {
        throw WorkSyncTransportError.unavailable
    }
}
