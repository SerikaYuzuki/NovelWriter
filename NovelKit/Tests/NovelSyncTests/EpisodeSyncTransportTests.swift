import Foundation
import NovelSync
import NovelSyncTesting
import Testing

@Suite("Episode sync transport contract")
struct EpisodeSyncTransportTests {
    @Test("catalog permits duplicate discovery hints but keeps remote works distinct")
    func duplicateSourceDocumentHintsRemainDistinct() async throws {
        let server = InMemoryEpisodeSyncServer()
        let sourceDocumentID = try #require(UUID(uuidString: "99999999-9999-9999-9999-999999999999"))
        let first = try SyncWorkDescriptor(
            workID: SyncWorkID(rawValue: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1"))),
            sourceDocumentID: sourceDocumentID,
            structureDigest: SyncTestValues.structureDigest(),
            title: "同じpackageから一つ目"
        )
        let second = try SyncWorkDescriptor(
            workID: SyncWorkID(rawValue: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA2"))),
            sourceDocumentID: sourceDocumentID,
            structureDigest: SyncTestValues.structureDigest(),
            title: "同じpackageから二つ目"
        )
        try await server.createWork(first)
        try await server.createWork(second)

        let listed = try await server.listWorks()
        #expect(Set(listed.map(\.workID)) == Set([first.workID, second.workID]))
        #expect(listed.allSatisfy { $0.sourceDocumentID == sourceDocumentID })
    }

    @Test("lease expiry is UX-only, force increments epoch, and release never rewinds it")
    func leaseLifecycle() async throws {
        let server = InMemoryEpisodeSyncServer()
        let expired = SyncTestValues.date.addingTimeInterval(-1)
        let acquired = try await server.claimLease(
            claimRequest(
                replica: SyncTestValues.replicaA,
                session: SyncTestValues.sessionA,
                expectedEpoch: 0,
                expiresAt: expired,
                kind: .acquireOrRenew
            )
        )
        let leaseA = try #require(acquired.snapshot?.lease)
        #expect(leaseA.authority.epoch == 1)
        #expect(leaseA.appearsExpired(at: SyncTestValues.date))

        let denied = try await server.claimLease(
            claimRequest(
                replica: SyncTestValues.replicaB,
                session: SyncTestValues.sessionB,
                expectedEpoch: 1,
                expiresAt: SyncTestValues.expiry,
                kind: .acquireOrRenew
            )
        )
        guard case .denied = denied else {
            Issue.record("UX expiry incorrectly transferred authority")
            return
        }

        let forced = try await server.claimLease(
            claimRequest(
                replica: SyncTestValues.replicaB,
                session: SyncTestValues.sessionB,
                expectedEpoch: 1,
                expiresAt: SyncTestValues.expiry,
                kind: .forceTakeover
            )
        )
        let leaseB = try #require(forced.snapshot?.lease)
        #expect(leaseB.authority.epoch == 2)
        _ = try await server.releaseLease(
            key: SyncTestValues.key,
            expectedAuthority: leaseA.authority
        )
        #expect(await server.currentLease(for: SyncTestValues.key) == leaseB)

        let released = try await server.releaseLease(
            key: SyncTestValues.key,
            expectedAuthority: leaseB.authority
        )
        #expect(released.lease == nil)
        #expect(released.leaseEpoch == 2)
        #expect(await server.currentLeaseEpoch(for: SyncTestValues.key) == 2)
    }

    @Test("client clocks never beat CAS head and lease authority")
    // Scenario keeps both stale-authority and current-authority writes visible together.
    // swiftlint:disable:next function_body_length
    func clockDoesNotChooseWinner() async throws {
        let server = InMemoryEpisodeSyncServer()
        let leaseA = try #require(
            try await server.claimLease(
                claimRequest(
                    replica: SyncTestValues.replicaA,
                    session: SyncTestValues.sessionA,
                    expectedEpoch: 0,
                    expiresAt: SyncTestValues.expiry,
                    kind: .acquireOrRenew
                )
            ).snapshot?.lease
        )
        let genesis = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666681",
            parents: [],
            content: "base",
            createdAt: Date.distantFuture
        )
        let genesisRequest = try EpisodePublishRequest(
            key: SyncTestValues.key,
            revisions: [genesis],
            candidateHeadRevisionID: genesis.revisionID,
            expectedHeadRevisionID: nil,
            expectedLeaseAuthority: leaseA.authority
        )
        _ = try await server.publish(genesisRequest)

        let leaseB = try #require(
            try await server.claimLease(
                claimRequest(
                    replica: SyncTestValues.replicaB,
                    session: SyncTestValues.sessionB,
                    expectedEpoch: 1,
                    expiresAt: SyncTestValues.expiry,
                    kind: .forceTakeover
                )
            ).snapshot?.lease
        )
        let staleFuture = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666682",
            parents: [genesis.revisionID],
            content: "future clock loses",
            createdAt: Date.distantFuture
        )
        let staleResult = try await server.publish(
            EpisodePublishRequest(
                key: SyncTestValues.key,
                revisions: [staleFuture],
                candidateHeadRevisionID: staleFuture.revisionID,
                expectedHeadRevisionID: genesis.revisionID,
                expectedLeaseAuthority: leaseA.authority
            )
        )
        guard case .staleLease = staleResult else {
            Issue.record("stale future clock unexpectedly won")
            return
        }

        let currentPast = try SyncTestValues.revision(
            id: "66666666-6666-6666-6666-666666666683",
            parents: [genesis.revisionID],
            content: "past clock wins by CAS",
            replica: SyncTestValues.replicaB,
            session: SyncTestValues.sessionB,
            createdAt: Date.distantPast
        )
        _ = try await server.publish(
            EpisodePublishRequest(
                key: SyncTestValues.key,
                revisions: [currentPast],
                candidateHeadRevisionID: currentPast.revisionID,
                expectedHeadRevisionID: genesis.revisionID,
                expectedLeaseAuthority: leaseB.authority
            )
        )
        #expect(await server.currentHead(for: SyncTestValues.key) == currentPast)
    }

    @Test("publish batch above 64 and revision above two parents fail closed")
    func resourceCaps() throws {
        let authority = try SyncTestValues.authority(epoch: 1)
        var revisions: [EpisodeRevision] = []
        for index in 0 ... EpisodePublishRequest.maximumRevisionCount {
            let revisionID = SyncRevisionID()
            let revision = try EpisodeRevision(
                key: SyncTestValues.key,
                revisionID: revisionID,
                parentRevisionIDs: revisions.last.map { [$0.revisionID] } ?? [],
                branchID: SyncTestValues.branchID,
                authorReplicaID: SyncTestValues.replicaA,
                authorSessionID: SyncTestValues.sessionA,
                content: "revision \(index)",
                clientCreatedAt: SyncTestValues.date
            )
            revisions.append(revision)
        }
        #expect(throws: EpisodeSyncTransportError.self) {
            _ = try EpisodePublishRequest(
                key: SyncTestValues.key,
                revisions: revisions,
                candidateHeadRevisionID: #require(revisions.last?.revisionID),
                expectedHeadRevisionID: nil,
                expectedLeaseAuthority: authority
            )
        }

        let parentIDs = [SyncRevisionID(), SyncRevisionID(), SyncRevisionID()]
        #expect(throws: EpisodeRevisionError.self) {
            _ = try EpisodeRevision(
                key: SyncTestValues.key,
                parentRevisionIDs: parentIDs,
                branchID: SyncTestValues.branchID,
                authorReplicaID: SyncTestValues.replicaA,
                authorSessionID: SyncTestValues.sessionA,
                content: "too many parents",
                clientCreatedAt: SyncTestValues.date
            )
        }
    }

    private func claimRequest(
        replica: SyncReplicaID,
        session: SyncEditSessionID,
        expectedEpoch: UInt64,
        expiresAt: Date,
        kind: EpisodeLeaseClaimKind
    ) throws -> EpisodeLeaseClaimRequest {
        try EpisodeLeaseClaimRequest(
            key: SyncTestValues.key,
            requesterReplicaID: replica,
            requesterSessionID: session,
            expectedEpoch: expectedEpoch,
            expiresAt: expiresAt,
            kind: kind
        )
    }
}

private extension EpisodeLeaseClaimResult {
    var snapshot: EpisodeRemoteSnapshot? {
        switch self {
        case let .granted(snapshot), let .denied(snapshot), let .changed(snapshot):
            snapshot
        }
    }
}
