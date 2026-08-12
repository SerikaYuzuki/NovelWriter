import Foundation
import NovelCore
import NovelSync
import Testing

@Suite("Device Sync edit intent store")
struct DeviceSyncEditIntentStoreTests {
    @Test("本文WALとpackage checkpointは同一本文へのUndoを世代順で判定する")
    func checkpointPreservesLogicalOrder() async throws {
        let fixture = try EditIntentFixture()
        defer { fixture.remove() }
        let context = try await makeCheckpointContext(fixture: fixture)
        let firstPackage = packageCheckpoint(for: context.first)

        try await verifyAbortedPackageSave(context: context, checkpoint: firstPackage)
        try await commitAndAcknowledgeFirstPackage(context: context, checkpoint: firstPackage)
        try await verifyRevertedPackage(context: context, firstPackage: firstPackage)
    }

    @Test("由来未確認の本文WALはreview用に隔離して次の本文を上書きしない")
    func preservesUnknownMarkerForReview() async throws {
        let fixture = try EditIntentFixture()
        defer { fixture.remove() }
        try await verifyReviewIsolation(fixture: fixture)
    }

    @Test("同一sequenceの異なる本文checkpointを拒否する")
    func rejectsDifferentCheckpointAtSameSequence() async throws {
        let fixture = try EditIntentFixture()
        defer { fixture.remove() }
        try await verifySameSequenceRejection(fixture: fixture)
    }

    @Test("FileとInMemoryはprotocol existential経由でもpackage checkpointを永続化する")
    func protocolExistentialPersistsPackageCheckpoint() async throws {
        let fixture = try EditIntentFixture()
        defer { fixture.remove() }
        let stores: [any DeviceSyncEditIntentStoring] = try [
            fixture.makeStore(),
            InMemoryDeviceSyncEditIntentStore()
        ]
        for store in stores {
            let marker = checkpointMarker(
                content: "existential",
                sequence: 1,
                documentID: UUID(),
                episodeID: EpisodeID()
            )
            let checkpoint = packageCheckpoint(for: marker)
            _ = try await store.save(
                marker,
                baselinePackageDigest: SyncContentDigest(content: "base")
            )
            try await store.preparePackageSave(checkpoint)
            try await store.commitPackageSave(checkpoint)
            let snapshot = try await store.loadPersistenceSnapshot(
                workingCopyIdentity: marker.workingCopyIdentity,
                documentID: marker.documentID,
                episodeID: marker.episodeID
            )
            #expect(snapshot.marker == marker)
            #expect(snapshot.committedPackage == checkpoint)
            #expect(snapshot.preparedPackage == nil)
        }
    }
}

private struct CheckpointContext {
    let store: FileDeviceSyncEditIntentStore
    let documentID: UUID
    let episodeID: EpisodeID
    let initialDigest: SyncContentDigest
    let first: DeviceSyncEditIntentMarker
}

private func makeCheckpointContext(fixture: EditIntentFixture) async throws -> CheckpointContext {
    let store = try fixture.makeStore()
    let documentID = UUID()
    let episodeID = EpisodeID()
    let initialDigest = SyncContentDigest(content: "A")
    let first = checkpointMarker(
        content: "B",
        sequence: 1,
        documentID: documentID,
        episodeID: episodeID
    )
    _ = try await store.save(first, baselinePackageDigest: initialDigest)
    let snapshot = try await store.loadPersistenceSnapshot(
        workingCopyIdentity: first.workingCopyIdentity,
        documentID: documentID,
        episodeID: episodeID
    )
    #expect(snapshot.marker == first)
    #expect(snapshot.committedPackage?.sequence == 0)
    #expect(snapshot.committedPackage?.contentDigest == initialDigest)
    return CheckpointContext(
        store: store,
        documentID: documentID,
        episodeID: episodeID,
        initialDigest: initialDigest,
        first: first
    )
}

private func verifyAbortedPackageSave(
    context: CheckpointContext,
    checkpoint: DeviceSyncPackageCheckpoint
) async throws {
    try await context.store.preparePackageSave(checkpoint)
    let snapshot = try await context.store.reconcilePreparedPackage(
        workingCopyIdentity: context.first.workingCopyIdentity,
        documentID: context.documentID,
        episodeID: context.episodeID,
        actualContentDigest: context.initialDigest
    )
    #expect(snapshot.committedPackage?.sequence == 0)
    #expect(snapshot.preparedPackage == nil)
    #expect(snapshot.marker == context.first)
}

private func commitAndAcknowledgeFirstPackage(
    context: CheckpointContext,
    checkpoint: DeviceSyncPackageCheckpoint
) async throws {
    try await context.store.preparePackageSave(checkpoint)
    var snapshot = try await context.store.reconcilePreparedPackage(
        workingCopyIdentity: context.first.workingCopyIdentity,
        documentID: context.documentID,
        episodeID: context.episodeID,
        actualContentDigest: context.first.contentDigest
    )
    #expect(snapshot.committedPackage == checkpoint)
    snapshot = try await context.store.acknowledgeLocalEditIntent(
        workingCopyIdentity: context.first.workingCopyIdentity,
        documentID: context.documentID,
        episodeID: context.episodeID,
        throughSequence: checkpoint.sequence,
        contentDigest: checkpoint.contentDigest
    )
    #expect(snapshot.committedPackage?.containsLocalEditIntent == false)
    try await context.store.remove(context.first)
}

private func verifyRevertedPackage(
    context: CheckpointContext,
    firstPackage: DeviceSyncPackageCheckpoint
) async throws {
    let reverted = checkpointMarker(
        content: "A",
        sequence: 2,
        documentID: context.documentID,
        episodeID: context.episodeID
    )
    _ = try await context.store.save(reverted, baselinePackageDigest: context.first.contentDigest)
    let revertedPackage = packageCheckpoint(for: reverted)
    try await context.store.preparePackageSave(revertedPackage)
    try await context.store.commitPackageSave(revertedPackage)
    try await context.store.remove(reverted)

    var snapshot = try await context.store.acknowledgeLocalEditIntent(
        workingCopyIdentity: context.first.workingCopyIdentity,
        documentID: context.documentID,
        episodeID: context.episodeID,
        throughSequence: firstPackage.sequence,
        contentDigest: firstPackage.contentDigest
    )
    #expect(snapshot.committedPackage?.containsLocalEditIntent == true)
    snapshot = try await context.store.acknowledgeLocalEditIntent(
        workingCopyIdentity: context.first.workingCopyIdentity,
        documentID: context.documentID,
        episodeID: context.episodeID,
        throughSequence: revertedPackage.sequence,
        contentDigest: revertedPackage.contentDigest
    )
    #expect(snapshot.marker == nil)
    #expect(snapshot.committedPackage == revertedPackage.acknowledgingLocalEditIntent())
    await #expect(throws: DeviceSyncLocalPersistenceError.self) {
        try await context.store.save(context.first, baselinePackageDigest: context.initialDigest)
    }
}

private func verifyReviewIsolation(fixture: EditIntentFixture) async throws {
    let store = try fixture.makeStore()
    let documentID = UUID()
    let episodeID = EpisodeID()
    let first = checkpointMarker(
        content: "前回processの本文",
        sequence: 1,
        documentID: documentID,
        episodeID: episodeID
    )
    _ = try await store.save(first, baselinePackageDigest: SyncContentDigest(content: "base"))
    try await store.preserveForReview(first)
    let second = try await saveResolvingMarker(
        store: store,
        first: first,
        documentID: documentID,
        episodeID: episodeID
    )
    try await verifyResolvingMarker(store: store, first: first, second: second)
    try await verifyAdvancedMarkerCAS(store: store, first: first, second: second)
}

private func saveResolvingMarker(
    store: FileDeviceSyncEditIntentStore,
    first: DeviceSyncEditIntentMarker,
    documentID: UUID,
    episodeID: EpisodeID
) async throws -> DeviceSyncEditIntentMarker {
    var second = checkpointMarker(
        content: "現在processの本文",
        sequence: 2,
        documentID: documentID,
        episodeID: episodeID
    )
    second.resolvesPreservedSequences = [first.mutationSequence]
    _ = try await store.save(second, baselinePackageDigest: SyncContentDigest(content: "base"))
    return second
}

private func verifyResolvingMarker(
    store: FileDeviceSyncEditIntentStore,
    first: DeviceSyncEditIntentMarker,
    second: DeviceSyncEditIntentMarker
) async throws {
    let snapshot = try await store.loadPersistenceSnapshot(
        workingCopyIdentity: first.workingCopyIdentity,
        documentID: first.documentID,
        episodeID: first.episodeID
    )
    #expect(snapshot.marker == second)
    #expect(snapshot.marker?.resolvesPreservedSequences == [first.mutationSequence])
    #expect(snapshot.preservedMarkers == [first])
    #expect(try await store.load(
        workingCopyIdentity: first.workingCopyIdentity,
        documentID: first.documentID,
        episodeID: first.episodeID
    ) == [second])
}

private func verifyAdvancedMarkerCAS(
    store: FileDeviceSyncEditIntentStore,
    first: DeviceSyncEditIntentMarker,
    second: DeviceSyncEditIntentMarker
) async throws {
    await expectPersistenceFailure {
        try await store.removePreservedForReview(
            workingCopyIdentity: first.workingCopyIdentity,
            documentID: first.documentID,
            episodeID: first.episodeID,
            expected: [second],
            expectedResolvingMarker: second
        )
    }
    var tail = checkpointMarker(
        content: "確認後の追加入力",
        sequence: 3,
        documentID: first.documentID,
        episodeID: first.episodeID
    )
    tail.resolvesPreservedSequences = [first.mutationSequence]
    _ = try await store.save(tail, baselinePackageDigest: SyncContentDigest(content: "base"))
    await expectPersistenceFailure {
        try await store.removePreservedForReview(
            workingCopyIdentity: first.workingCopyIdentity,
            documentID: first.documentID,
            episodeID: first.episodeID,
            expected: [first],
            expectedResolvingMarker: second
        )
    }
    let retained = try await store.loadPersistenceSnapshot(
        workingCopyIdentity: first.workingCopyIdentity,
        documentID: first.documentID,
        episodeID: first.episodeID
    )
    #expect(retained.marker == tail)
    #expect(retained.preservedMarkers == [first])
    let cleared = try await store.removePreservedForReview(
        workingCopyIdentity: first.workingCopyIdentity,
        documentID: first.documentID,
        episodeID: first.episodeID,
        expected: [first],
        expectedResolvingMarker: tail
    )
    #expect(cleared.preservedMarkers.isEmpty)
    #expect(cleared.marker == nil)
}

private func verifySameSequenceRejection(fixture: EditIntentFixture) async throws {
    let store = try fixture.makeStore()
    let documentID = UUID()
    let episodeID = EpisodeID()
    let first = checkpointMarker(content: "first", sequence: 1, documentID: documentID, episodeID: episodeID)
    let different = checkpointMarker(
        content: "different",
        sequence: 1,
        documentID: documentID,
        episodeID: episodeID
    )
    _ = try await store.save(first, baselinePackageDigest: SyncContentDigest(content: "base"))
    await expectPersistenceFailure {
        try await store.save(different, baselinePackageDigest: SyncContentDigest(content: "base"))
    }
    try await store.preparePackageSave(packageCheckpoint(for: first))
    await expectPersistenceFailure {
        try await store.preparePackageSave(packageCheckpoint(for: different))
    }
}

private func expectPersistenceFailure(_ operation: () async throws -> some Any) async {
    await #expect(throws: DeviceSyncLocalPersistenceError.self) {
        try await operation()
    }
}

private func checkpointMarker(
    content: String,
    sequence: UInt64,
    documentID: UUID,
    episodeID: EpisodeID
) -> DeviceSyncEditIntentMarker {
    DeviceSyncEditIntentMarker(
        protocolVersion: DeviceSyncEditIntentMarker.currentProtocolVersion,
        workingCopyIdentity: "checkpoint-working-copy",
        documentID: documentID,
        episodeID: episodeID,
        editorContentGeneration: 1,
        mutationSequence: sequence,
        createdAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
        replicaID: SyncReplicaID(),
        localWorkingCopyID: nil,
        workID: nil,
        baseContentDigest: nil,
        acceptedPriorPackageDigests: nil,
        content: content,
        contentDigest: SyncContentDigest(content: content)
    )
}

private func packageCheckpoint(for marker: DeviceSyncEditIntentMarker) -> DeviceSyncPackageCheckpoint {
    DeviceSyncPackageCheckpoint(
        protocolVersion: DeviceSyncPackageCheckpoint.currentProtocolVersion,
        workingCopyIdentity: marker.workingCopyIdentity,
        documentID: marker.documentID,
        episodeID: marker.episodeID,
        sequence: marker.mutationSequence,
        contentDigest: marker.contentDigest,
        containsLocalEditIntent: true
    )
}

private struct EditIntentFixture {
    let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-edit-intent-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
    }

    func makeStore() throws -> FileDeviceSyncEditIntentStore {
        try FileDeviceSyncEditIntentStore(
            rootURL: base.appendingPathComponent("edit-intent", isDirectory: true),
            trustedAncestorURL: base
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
