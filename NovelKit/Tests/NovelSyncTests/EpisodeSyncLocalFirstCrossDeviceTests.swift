import Foundation
import NovelSync
import NovelSyncTesting
import Testing

extension EpisodeSyncLocalFirstTests {
    @Test("MacとiPhoneが同じ話を開いたままlocal-firstで往復編集できる")
    func macAndPhoneAlternateEditsWithoutClosingEitherEpisode() async throws {
        let scenario = try await makeCrossDeviceScenario()
        let macFirst = try await publishDurableEdit(
            on: scenario.mac,
            in: scenario,
            content: "Macから一度目",
            createdAt: SyncTestValues.date.addingTimeInterval(1)
        )
        try await materializeRemote(
            macFirst.head,
            replacing: "共通本文",
            on: scenario.phone,
            createdAt: SyncTestValues.date.addingTimeInterval(2)
        )

        let phoneReply = try await publishDurableEdit(
            on: scenario.phone,
            in: scenario,
            content: "iPhoneから返信",
            createdAt: SyncTestValues.date.addingTimeInterval(3)
        )
        let macOldAuthority = try #require(macFirst.authorityBeforeSync)
        try await assertDelayedPublishIsFenced(
            authority: macOldAuthority,
            staleParent: macFirst.head,
            currentHead: phoneReply.head,
            in: scenario,
            createdAt: SyncTestValues.date.addingTimeInterval(4)
        )
        try await materializeRemote(
            phoneReply.head,
            replacing: macFirst.head.content,
            on: scenario.mac,
            createdAt: SyncTestValues.date.addingTimeInterval(5)
        )

        let macFinal = try await publishDurableEdit(
            on: scenario.mac,
            in: scenario,
            content: "Macから最終稿",
            createdAt: SyncTestValues.date.addingTimeInterval(6)
        )
        try await materializeRemote(
            macFinal.head,
            replacing: phoneReply.head.content,
            on: scenario.phone,
            createdAt: SyncTestValues.date.addingTimeInterval(7)
        )

        #expect(phoneReply.epoch == macFirst.epoch + 1)
        #expect(macFinal.epoch == phoneReply.epoch + 1)
        try await assertConverged(on: macFinal.head, in: scenario)
    }
}

private struct CrossDeviceEndpoint {
    let coordinator: EpisodeSyncCoordinator
    let journal: InMemoryEpisodeSyncJournal
    let localWorkingCopyID: LocalWorkingCopyID
    let replicaID: SyncReplicaID
    let sessionID: SyncEditSessionID
}

private struct CrossDeviceScenario {
    let server: InMemoryEpisodeSyncServer
    let mac: CrossDeviceEndpoint
    let phone: CrossDeviceEndpoint
}

private struct CrossDevicePublishStep {
    let head: EpisodeRevision
    let epoch: UInt64
    let authorityBeforeSync: EpisodeLeaseAuthority?
}

private func makeCrossDeviceScenario() async throws -> CrossDeviceScenario {
    let server = InMemoryEpisodeSyncServer()
    let mac = makeCrossDeviceEndpoint(
        server: server,
        localWorkingCopyID: LocalWorkingCopyID(),
        replicaID: SyncTestValues.replicaA,
        sessionID: SyncTestValues.sessionA
    )
    let phone = makeCrossDeviceEndpoint(
        server: server,
        localWorkingCopyID: LocalWorkingCopyID(),
        replicaID: SyncTestValues.replicaB,
        sessionID: SyncTestValues.sessionB
    )
    #expect(mac.localWorkingCopyID != phone.localWorkingCopyID)

    _ = try await mac.coordinator.link(
        localContent: "共通本文",
        createdAt: SyncTestValues.date,
        leaseExpiresAt: SyncTestValues.expiry
    )
    let base = try #require(await server.currentHead(for: SyncTestValues.key))
    _ = try await phone.coordinator.observeRemoteBase(
        localContent: base.content,
        createdAt: SyncTestValues.date
    )
    try await assertObservedBase(base, on: mac)
    try await assertObservedBase(base, on: phone)
    return CrossDeviceScenario(server: server, mac: mac, phone: phone)
}

private func makeCrossDeviceEndpoint(
    server: InMemoryEpisodeSyncServer,
    localWorkingCopyID: LocalWorkingCopyID,
    replicaID: SyncReplicaID,
    sessionID: SyncEditSessionID
) -> CrossDeviceEndpoint {
    let journal = InMemoryEpisodeSyncJournal()
    let coordinator = EpisodeSyncCoordinator(
        key: SyncTestValues.key,
        localWorkingCopyID: localWorkingCopyID,
        replicaID: replicaID,
        sessionID: sessionID,
        transport: server,
        journal: journal
    )
    return CrossDeviceEndpoint(
        coordinator: coordinator,
        journal: journal,
        localWorkingCopyID: localWorkingCopyID,
        replicaID: replicaID,
        sessionID: sessionID
    )
}

private func assertObservedBase(
    _ base: EpisodeRevision,
    on endpoint: CrossDeviceEndpoint
) async throws {
    let record = try #require(await endpoint.journal.storedRecord(for: SyncTestValues.key))
    #expect(record.localWorkingCopyID == endpoint.localWorkingCopyID)
    #expect(record.localHead == base)
    #expect(record.localEditIntent == .observed)
    #expect(record.pendingRevisions.isEmpty)
}

private func publishDurableEdit(
    on endpoint: CrossDeviceEndpoint,
    in scenario: CrossDeviceScenario,
    content: String,
    createdAt: Date
) async throws -> CrossDevicePublishStep {
    let remoteBefore = try #require(await scenario.server.currentHead(for: SyncTestValues.key))
    let epochBefore = await scenario.server.currentLeaseEpoch(for: SyncTestValues.key)
    let receipt = try await endpoint.coordinator.recordLocalEdit(content, createdAt: createdAt)
    let durable = try #require(await endpoint.journal.storedRecord(for: SyncTestValues.key))
    #expect(receipt.localWorkingCopyID == endpoint.localWorkingCopyID)
    #expect(receipt.revisionID == durable.localHead.revisionID)
    #expect(receipt.contentDigest == durable.localHead.contentDigest)
    #expect(durable.localHead.content == content)
    #expect(durable.localEditIntent == .explicit)
    #expect(durable.pendingRevisions.contains(durable.localHead))
    #expect(await scenario.server.currentHead(for: SyncTestValues.key) == remoteBefore)
    #expect(await scenario.server.currentLeaseEpoch(for: SyncTestValues.key) == epochBefore)

    _ = try await endpoint.coordinator.synchronizeLocalFirst(
        expiresAt: SyncTestValues.expiry,
        createdAt: createdAt.addingTimeInterval(0.25)
    )
    let head = try #require(await scenario.server.currentHead(for: SyncTestValues.key))
    #expect(head.content == content)
    let published = try #require(await endpoint.journal.storedRecord(for: SyncTestValues.key))
    #expect(published.localHead == head)
    #expect(published.pendingRevisions.isEmpty)
    #expect(published.remoteConfirmation == .confirmed)
    return await CrossDevicePublishStep(
        head: head,
        epoch: scenario.server.currentLeaseEpoch(for: SyncTestValues.key),
        authorityBeforeSync: durable.lease?.authority
    )
}

private func materializeRemote(
    _ remote: EpisodeRevision,
    replacing localContent: String,
    on endpoint: CrossDeviceEndpoint,
    createdAt: Date
) async throws {
    let observed = try await endpoint.coordinator.observeRemoteBase(
        localContent: localContent,
        createdAt: createdAt
    )
    let pending = try #require(syncContext(from: observed)?.pendingMaterialization)
    #expect(pending.integratedRevision == remote)
    let confirmed = try await endpoint.coordinator.confirmIntegratedContentMaterialized(
        pending,
        installedContentDigest: remote.contentDigest
    )
    #expect(syncContext(from: confirmed)?.localHead == remote)
    #expect(syncContext(from: confirmed)?.remoteConfirmation == .confirmed)
    let record = try #require(await endpoint.journal.storedRecord(for: SyncTestValues.key))
    #expect(record.localHead == remote)
    #expect(record.pendingMaterialization == nil)
}

private func assertDelayedPublishIsFenced(
    authority: EpisodeLeaseAuthority,
    staleParent: EpisodeRevision,
    currentHead: EpisodeRevision,
    in scenario: CrossDeviceScenario,
    createdAt: Date
) async throws {
    let delayed = try EpisodeRevision(
        key: SyncTestValues.key,
        parentRevisionIDs: [staleParent.revisionID],
        branchID: SyncBranchID(),
        authorReplicaID: scenario.mac.replicaID,
        authorSessionID: scenario.mac.sessionID,
        content: "古いepochからの遅延本文",
        clientCreatedAt: createdAt
    )
    let request = try EpisodePublishRequest(
        key: SyncTestValues.key,
        revisions: [delayed],
        candidateHeadRevisionID: delayed.revisionID,
        expectedHeadRevisionID: staleParent.revisionID,
        expectedLeaseAuthority: authority
    )
    let result = try await scenario.server.publish(request)
    guard case let .staleLease(snapshot) = result else {
        Issue.record("古いepochの遅延publishが拒否されませんでした")
        return
    }
    #expect(snapshot.head == currentHead)
    #expect(await scenario.server.currentHead(for: SyncTestValues.key) == currentHead)
}

private func assertConverged(
    on finalHead: EpisodeRevision,
    in scenario: CrossDeviceScenario
) async throws {
    #expect(await scenario.server.currentHead(for: SyncTestValues.key) == finalHead)
    for endpoint in [scenario.mac, scenario.phone] {
        let record = try #require(await endpoint.journal.storedRecord(for: SyncTestValues.key))
        #expect(record.localWorkingCopyID == endpoint.localWorkingCopyID)
        #expect(record.localHead == finalHead)
        #expect(record.pendingRevisions.isEmpty)
        #expect(record.pendingMaterialization == nil)
        #expect(record.remoteConfirmation == .confirmed)
    }
}
