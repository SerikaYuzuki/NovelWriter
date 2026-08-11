import Foundation
import NovelCore
import NovelSync
import Testing

@Suite("iOS Device Sync edit intent store")
struct IOSDeviceSyncEditIntentStoreTests {
    @Test("iOS本文WALとpackage checkpointは同一本文へのUndoを世代順で判定する")
    func checkpointPreservesLogicalOrder() async throws {
        let fixture = try IOSEditIntentFixture()
        defer { fixture.remove() }
        let context = try await makeIOSCheckpointContext(fixture: fixture)
        let firstPackage = iosPackageCheckpoint(for: context.first)

        try await verifyIOSAbortedPackageSave(context: context, checkpoint: firstPackage)
        try await commitAndAcknowledgeIOSFirstPackage(context: context, checkpoint: firstPackage)
        try await verifyIOSRevertedPackage(context: context, firstPackage: firstPackage)
    }

    @Test("iOS由来未確認の本文WALはreview用に隔離して次の本文を上書きしない")
    func preservesUnknownMarkerForReview() async throws {
        let fixture = try IOSEditIntentFixture()
        defer { fixture.remove() }
        try await verifyIOSReviewIsolation(fixture: fixture)
    }

    @Test("iOS同一sequenceの異なる本文checkpointを拒否する")
    func rejectsDifferentCheckpointAtSameSequence() async throws {
        let fixture = try IOSEditIntentFixture()
        defer { fixture.remove() }
        try await verifyIOSSameSequenceRejection(fixture: fixture)
    }

    @Test("iOS FileとInMemoryはprotocol existential経由でもpackage checkpointを永続化する")
    func protocolExistentialPersistsPackageCheckpoint() async throws {
        let fixture = try IOSEditIntentFixture()
        defer { fixture.remove() }
        let stores: [any IOSDeviceSyncEditIntentStoring] = try [
            fixture.makeStore(),
            IOSInMemoryDeviceSyncEditIntentStore()
        ]
        for store in stores {
            let marker = iosCheckpointMarker(
                content: "existential",
                sequence: 1,
                documentID: UUID(),
                episodeID: EpisodeID()
            )
            let checkpoint = iosPackageCheckpoint(for: marker)
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

private struct IOSCheckpointContext {
    let store: IOSFileDeviceSyncEditIntentStore
    let documentID: UUID
    let episodeID: EpisodeID
    let initialDigest: SyncContentDigest
    let first: IOSDeviceSyncEditIntentMarker
}

private func makeIOSCheckpointContext(fixture: IOSEditIntentFixture) async throws -> IOSCheckpointContext {
    let store = try fixture.makeStore()
    let documentID = UUID()
    let episodeID = EpisodeID()
    let initialDigest = SyncContentDigest(content: "A")
    let first = iosCheckpointMarker(
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
    return IOSCheckpointContext(
        store: store,
        documentID: documentID,
        episodeID: episodeID,
        initialDigest: initialDigest,
        first: first
    )
}

private func verifyIOSAbortedPackageSave(
    context: IOSCheckpointContext,
    checkpoint: IOSDeviceSyncPackageCheckpoint
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

private func commitAndAcknowledgeIOSFirstPackage(
    context: IOSCheckpointContext,
    checkpoint: IOSDeviceSyncPackageCheckpoint
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

private func verifyIOSRevertedPackage(
    context: IOSCheckpointContext,
    firstPackage: IOSDeviceSyncPackageCheckpoint
) async throws {
    let reverted = iosCheckpointMarker(
        content: "A",
        sequence: 2,
        documentID: context.documentID,
        episodeID: context.episodeID
    )
    _ = try await context.store.save(reverted, baselinePackageDigest: context.first.contentDigest)
    let revertedPackage = iosPackageCheckpoint(for: reverted)
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
    await #expect(throws: IOSDeviceSyncLocalPersistenceError.self) {
        try await context.store.save(context.first, baselinePackageDigest: context.initialDigest)
    }
}

private func verifyIOSReviewIsolation(fixture: IOSEditIntentFixture) async throws {
    let store = try fixture.makeStore()
    let documentID = UUID()
    let episodeID = EpisodeID()
    let first = iosCheckpointMarker(
        content: "前回processの本文",
        sequence: 1,
        documentID: documentID,
        episodeID: episodeID
    )
    _ = try await store.save(first, baselinePackageDigest: SyncContentDigest(content: "base"))
    try await store.preserveForReview(first)
    let second = try await saveIOSResolvingMarker(
        store: store,
        first: first,
        documentID: documentID,
        episodeID: episodeID
    )
    try await verifyIOSResolvingMarker(store: store, first: first, second: second)
    try await verifyIOSAdvancedMarkerCAS(store: store, first: first, second: second)
}

private func saveIOSResolvingMarker(
    store: IOSFileDeviceSyncEditIntentStore,
    first: IOSDeviceSyncEditIntentMarker,
    documentID: UUID,
    episodeID: EpisodeID
) async throws -> IOSDeviceSyncEditIntentMarker {
    var second = iosCheckpointMarker(
        content: "現在processの本文",
        sequence: 2,
        documentID: documentID,
        episodeID: episodeID
    )
    second.resolvesPreservedSequences = [first.mutationSequence]
    _ = try await store.save(second, baselinePackageDigest: SyncContentDigest(content: "base"))
    return second
}

private func verifyIOSResolvingMarker(
    store: IOSFileDeviceSyncEditIntentStore,
    first: IOSDeviceSyncEditIntentMarker,
    second: IOSDeviceSyncEditIntentMarker
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

private func verifyIOSAdvancedMarkerCAS(
    store: IOSFileDeviceSyncEditIntentStore,
    first: IOSDeviceSyncEditIntentMarker,
    second: IOSDeviceSyncEditIntentMarker
) async throws {
    await expectIOSPersistenceFailure {
        try await store.removePreservedForReview(
            workingCopyIdentity: first.workingCopyIdentity,
            documentID: first.documentID,
            episodeID: first.episodeID,
            expected: [second],
            expectedResolvingMarker: second
        )
    }
    var tail = iosCheckpointMarker(
        content: "確認後の追加入力",
        sequence: 3,
        documentID: first.documentID,
        episodeID: first.episodeID
    )
    tail.resolvesPreservedSequences = [first.mutationSequence]
    _ = try await store.save(tail, baselinePackageDigest: SyncContentDigest(content: "base"))
    await expectIOSPersistenceFailure {
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

private func verifyIOSSameSequenceRejection(fixture: IOSEditIntentFixture) async throws {
    let store = try fixture.makeStore()
    let documentID = UUID()
    let episodeID = EpisodeID()
    let first = iosCheckpointMarker(content: "first", sequence: 1, documentID: documentID, episodeID: episodeID)
    let different = iosCheckpointMarker(
        content: "different",
        sequence: 1,
        documentID: documentID,
        episodeID: episodeID
    )
    _ = try await store.save(first, baselinePackageDigest: SyncContentDigest(content: "base"))
    await expectIOSPersistenceFailure {
        try await store.save(different, baselinePackageDigest: SyncContentDigest(content: "base"))
    }
    try await store.preparePackageSave(iosPackageCheckpoint(for: first))
    await expectIOSPersistenceFailure {
        try await store.preparePackageSave(iosPackageCheckpoint(for: different))
    }
}

private func expectIOSPersistenceFailure(_ operation: () async throws -> some Any) async {
    await #expect(throws: IOSDeviceSyncLocalPersistenceError.self) {
        try await operation()
    }
}

func iosCheckpointMarker(
    content: String,
    sequence: UInt64,
    documentID: UUID,
    episodeID: EpisodeID
) -> IOSDeviceSyncEditIntentMarker {
    IOSDeviceSyncEditIntentMarker(
        protocolVersion: IOSDeviceSyncEditIntentMarker.currentProtocolVersion,
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

private func iosPackageCheckpoint(for marker: IOSDeviceSyncEditIntentMarker) -> IOSDeviceSyncPackageCheckpoint {
    IOSDeviceSyncPackageCheckpoint(
        protocolVersion: IOSDeviceSyncPackageCheckpoint.currentProtocolVersion,
        workingCopyIdentity: marker.workingCopyIdentity,
        documentID: marker.documentID,
        episodeID: marker.episodeID,
        sequence: marker.mutationSequence,
        contentDigest: marker.contentDigest,
        containsLocalEditIntent: true
    )
}

private struct IOSEditIntentFixture {
    let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-ios-edit-intent-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
    }

    func makeStore() throws -> IOSFileDeviceSyncEditIntentStore {
        try IOSFileDeviceSyncEditIntentStore(
            rootURL: base.appendingPathComponent("edit-intent", isDirectory: true),
            trustedAncestorURL: base
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
