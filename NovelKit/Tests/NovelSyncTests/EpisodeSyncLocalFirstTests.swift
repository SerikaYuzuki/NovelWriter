import Foundation
import NovelSync
import NovelSyncTesting
import Testing

@Suite("Episode sync local-first editing")
struct EpisodeSyncLocalFirstTests {
    @Test("reconciliation facet distinguishes online CAS wait from offline durability")
    func reconciliationFacetDistinguishesConnectivity() async throws {
        let base = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666680",
            parents: [],
            content: "base"
        )
        let authority = try SyncTestValues.authority(
            replica: SyncTestValues.replicaA,
            session: SyncTestValues.sessionA,
            epoch: 1
        )
        let lease = EpisodeLease(authority: authority, expiresAt: SyncTestValues.expiry)
        let heldSnapshot = try EpisodeRemoteSnapshot(head: base, leaseEpoch: 1, lease: lease)
        let deniedTransport = AdversarialEpisodeSyncTransport(snapshot: heldSnapshot)
        let onlineJournal = InMemoryEpisodeSyncJournal()
        let online = EpisodeSyncCoordinator(
            key: SyncTestValues.key,
            localWorkingCopyID: SyncTestValues.localWorkingCopyID,
            replicaID: SyncTestValues.replicaB,
            sessionID: SyncTestValues.sessionB,
            transport: deniedTransport,
            journal: onlineJournal
        )
        _ = try await online.observeRemoteBase(localContent: "base", createdAt: SyncTestValues.date)
        _ = try await online.recordLocalEdit(
            "base local",
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        let waiting = try await online.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date.addingTimeInterval(2)
        )
        #expect(syncContext(from: waiting)?.reconciliationStatus == .pending)

        let offlineServer = InMemoryEpisodeSyncServer()
        await offlineServer.setOnline(false)
        let offline = makeCoordinator(
            server: offlineServer,
            journal: InMemoryEpisodeSyncJournal(),
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        _ = try await offline.recordLocalEdit("local", createdAt: SyncTestValues.date)
        let unavailable = try await offline.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date
        )
        #expect(syncContext(from: unavailable)?.reconciliationStatus == .offline)
    }

    @Test("a cross-episode remote head is rejected before ancestry or merge")
    func wrongKeyRemoteHeadIsRejected() async throws {
        let otherEpisodeID = try #require(UUID(uuidString: "12121212-1212-1212-1212-121212121212"))
        let otherKey = EpisodeSyncKey(
            workID: SyncTestValues.workID,
            episodeID: .init(rawValue: otherEpisodeID)
        )
        let wrongHead = try EpisodeRevision(
            key: otherKey,
            parentRevisionIDs: [],
            branchID: SyncTestValues.branchID,
            authorReplicaID: SyncTestValues.replicaA,
            authorSessionID: SyncTestValues.sessionA,
            content: "wrong episode",
            clientCreatedAt: SyncTestValues.date
        )
        let snapshot = try EpisodeRemoteSnapshot(head: wrongHead, leaseEpoch: 0, lease: nil)
        let transport = AdversarialEpisodeSyncTransport(snapshot: snapshot)
        let journal = InMemoryEpisodeSyncJournal()
        let coordinator = EpisodeSyncCoordinator(
            key: SyncTestValues.key,
            localWorkingCopyID: SyncTestValues.localWorkingCopyID,
            replicaID: SyncTestValues.replicaB,
            sessionID: SyncTestValues.sessionB,
            transport: transport,
            journal: journal
        )
        _ = try await coordinator.recordLocalEdit("local", createdAt: SyncTestValues.date)

        await #expect(throws: EpisodeSyncCoordinatorError.self) {
            _ = try await coordinator.synchronizeLocalFirst(
                expiresAt: SyncTestValues.expiry,
                createdAt: SyncTestValues.date
            )
        }
        #expect(await journal.storedRecord(for: SyncTestValues.key)?.localHead.content == "local")
    }

    @Test("wrong-ID and changed-digest ancestor responses never prove common ancestry")
    func adversarialAncestorCannotEnableAutoMerge() async throws {
        let history = try makeAdversarialHistory()
        let wrongID = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666684",
            parents: [],
            content: "base"
        )
        let wrongIDSetup = try await makeAdversarialCoordinator(history: history, fetched: wrongID)
        await #expect(throws: EpisodeSyncCoordinatorError.self) {
            _ = try await wrongIDSetup.coordinator.synchronizeLocalFirst(
                expiresAt: SyncTestValues.expiry,
                createdAt: SyncTestValues.date
            )
        }

        let changedDigest = try EpisodeRevision(
            key: SyncTestValues.key,
            revisionID: history.base.revisionID,
            parentRevisionIDs: [],
            branchID: history.base.branchID,
            authorReplicaID: history.base.authorReplicaID,
            authorSessionID: history.base.authorSessionID,
            content: "different base",
            clientCreatedAt: history.base.clientCreatedAt
        )
        let changedSetup = try await makeAdversarialCoordinator(history: history, fetched: changedDigest)
        let state = try await changedSetup.coordinator.synchronizeLocalFirst(
            expiresAt: SyncTestValues.expiry,
            createdAt: SyncTestValues.date
        )
        #expect(syncConflict(from: state)?.base == nil)
        #expect(await changedSetup.transport.publishInvocationCount() == 0)
    }

    private struct AdversarialHistory {
        let base: EpisodeRevision
        let local: EpisodeRevision
        let remote: EpisodeRevision
    }

    private func makeAdversarialHistory() throws -> AdversarialHistory {
        let base = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666681",
            parents: [],
            content: "base"
        )
        let local = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666682",
            parents: [base.revisionID],
            content: "base local",
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB
        )
        let remote = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666683",
            parents: [base.revisionID],
            content: "base remote"
        )
        return AdversarialHistory(base: base, local: local, remote: remote)
    }

    private func makeAdversarialCoordinator(
        history: AdversarialHistory,
        fetched: EpisodeRevision
    ) async throws -> (coordinator: EpisodeSyncCoordinator, transport: AdversarialEpisodeSyncTransport) {
        let snapshot = try EpisodeRemoteSnapshot(head: history.remote, leaseEpoch: 0, lease: nil)
        let transport = AdversarialEpisodeSyncTransport(snapshot: snapshot, fetchedRevision: fetched)
        let journal = InMemoryEpisodeSyncJournal()
        try await journal.save(
            EpisodeSyncJournalRecord(
                key: SyncTestValues.key,
                localWorkingCopyID: SyncTestValues.localWorkingCopyID,
                replicaID: SyncTestValues.replicaB,
                branchID: SyncTestValues.branchID,
                lastKnownRemoteHead: history.base,
                localHead: history.local,
                pendingRevisions: [history.local]
            )
        )
        return (
            EpisodeSyncCoordinator(
                key: SyncTestValues.key,
                localWorkingCopyID: SyncTestValues.localWorkingCopyID,
                replicaID: SyncTestValues.replicaB,
                sessionID: SyncTestValues.sessionB,
                transport: transport,
                journal: journal
            ),
            transport
        )
    }
}

private actor AdversarialEpisodeSyncTransport: EpisodeSyncTransport {
    let snapshot: EpisodeRemoteSnapshot
    let fetchedRevision: EpisodeRevision?
    private var publishCount = 0

    init(snapshot: EpisodeRemoteSnapshot, fetchedRevision: EpisodeRevision? = nil) {
        self.snapshot = snapshot
        self.fetchedRevision = fetchedRevision
    }

    func fetchSnapshot(for _: EpisodeSyncKey) async throws -> EpisodeRemoteSnapshot {
        snapshot
    }

    func fetchRevision(
        _ id: SyncRevisionID,
        for _: EpisodeSyncKey
    ) async throws -> EpisodeRevision {
        guard let fetchedRevision else { throw EpisodeSyncTransportError.missingRevision }
        _ = id
        return fetchedRevision
    }

    func claimLease(_ request: EpisodeLeaseClaimRequest) async throws -> EpisodeLeaseClaimResult {
        _ = request
        return .changed(snapshot)
    }

    func releaseLease(
        key: EpisodeSyncKey,
        expectedAuthority: EpisodeLeaseAuthority
    ) async throws -> EpisodeRemoteSnapshot {
        _ = key
        _ = expectedAuthority
        return snapshot
    }

    func publish(_ request: EpisodePublishRequest) async throws -> EpisodePublishResult {
        _ = request
        publishCount += 1
        return .diverged(snapshot)
    }

    func publishInvocationCount() -> Int {
        publishCount
    }
}
