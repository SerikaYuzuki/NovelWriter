import Foundation
import NovelCore
import NovelSync
import Testing

@Suite("iOS Device Sync persistence roots")
struct IOSDeviceSyncPersistenceRootTests {
    @Test("iOS merge recovery root rejects intermediate and final symlinks")
    func mergeRecoveryRootRejectsSymlinks() throws {
        let fixture = try IOSRootFixture()
        defer { fixture.remove() }

        let external = fixture.base.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let intermediate = fixture.base.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: intermediate, withDestinationURL: external)
        #expect(throws: IOSDeviceSyncMergeRecoveryStoreError.self) {
            _ = try IOSFileDeviceSyncMergeRecoveryStore(
                rootURL: intermediate.appendingPathComponent("merge", isDirectory: true),
                trustedAncestorURL: fixture.base
            )
        }

        let final = fixture.base.appendingPathComponent("final", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: final, withDestinationURL: external)
        #expect(throws: IOSDeviceSyncMergeRecoveryStoreError.self) {
            _ = try IOSFileDeviceSyncMergeRecoveryStore(
                rootURL: final,
                trustedAncestorURL: fixture.base
            )
        }
    }

    @Test("iOS merge recovery root identity replacement fails closed")
    func mergeRecoveryRootReplacementFailsClosed() async throws {
        let fixture = try IOSRootFixture()
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("merge", isDirectory: true)
        let store = try IOSFileDeviceSyncMergeRecoveryStore(
            rootURL: root,
            trustedAncestorURL: fixture.base
        )
        let displaced = fixture.base.appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: displaced)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        do {
            _ = try await store.load(
                localWorkingCopyID: LocalWorkingCopyID(),
                key: EpisodeSyncKey(workID: SyncWorkID(), episodeID: EpisodeID())
            )
            Issue.record("replaced iOS merge recovery root was accepted")
        } catch let error as IOSDeviceSyncMergeRecoveryStoreError {
            #expect(error == .unsafeRoot)
        }
    }

    @Test("iOS merge recovery record symlink fails closed for every operation")
    func mergeRecoveryRecordSymlinkFailsClosed() async throws {
        let fixture = try IOSRootFixture()
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("merge", isDirectory: true)
        let store = try IOSFileDeviceSyncMergeRecoveryStore(
            rootURL: root,
            trustedAncestorURL: fixture.base
        )
        let record = try makeIOSRecoveryRecord()
        let external = fixture.base.appendingPathComponent("external.json")
        try Data("forged".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: iosRecoveryRecordURL(for: record, root: root),
            withDestinationURL: external
        )

        await expectIOSMergeRecoveryFailure { try await store.save(record) }
        await expectIOSMergeRecoveryFailure {
            try await store.load(localWorkingCopyID: record.localWorkingCopyID, key: record.key)
        }
        await expectIOSMergeRecoveryFailure {
            try await store.remove(localWorkingCopyID: record.localWorkingCopyID, key: record.key)
        }
    }

    @Test("iOS由来未確認の本文WALはreview用に隔離して次の本文を上書きしない")
    func editIntentStorePreservesUnknownMarkerForReview() async throws {
        let fixture = try IOSRootFixture()
        defer { fixture.remove() }
        let store = try IOSFileDeviceSyncEditIntentStore(
            rootURL: fixture.base.appendingPathComponent("edit-intent", isDirectory: true),
            trustedAncestorURL: fixture.base
        )
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

        var second = iosCheckpointMarker(
            content: "現在processの本文",
            sequence: 2,
            documentID: documentID,
            episodeID: episodeID
        )
        second.resolvesPreservedSequences = [first.mutationSequence]
        _ = try await store.save(second, baselinePackageDigest: SyncContentDigest(content: "base"))
        var snapshot = try await store.loadPersistenceSnapshot(
            workingCopyIdentity: first.workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        )
        #expect(snapshot.marker == second)
        #expect(snapshot.marker?.resolvesPreservedSequences == [first.mutationSequence])
        #expect(snapshot.preservedMarkers == [first])
        #expect(try await store.load(
            workingCopyIdentity: first.workingCopyIdentity,
            documentID: documentID,
            episodeID: episodeID
        ) == [second])
    }

    @Test("iOS同一sequenceの異なる本文checkpointを拒否する")
    func editIntentStoreRejectsDifferentCheckpointAtSameSequence() async throws {
        let fixture = try IOSRootFixture()
        defer { fixture.remove() }
        let store = try IOSFileDeviceSyncEditIntentStore(
            rootURL: fixture.base.appendingPathComponent("edit-intent", isDirectory: true),
            trustedAncestorURL: fixture.base
        )
        let documentID = UUID()
        let episodeID = EpisodeID()
        let first = iosCheckpointMarker(
            content: "first",
            sequence: 1,
            documentID: documentID,
            episodeID: episodeID
        )
        let different = iosCheckpointMarker(
            content: "different",
            sequence: 1,
            documentID: documentID,
            episodeID: episodeID
        )
        _ = try await store.save(first, baselinePackageDigest: SyncContentDigest(content: "base"))
        await #expect(throws: IOSDeviceSyncLocalPersistenceError.self) {
            try await store.save(different, baselinePackageDigest: SyncContentDigest(content: "base"))
        }
        try await store.preparePackageSave(iosPackageCheckpoint(for: first))
        await #expect(throws: IOSDeviceSyncLocalPersistenceError.self) {
            try await store.preparePackageSave(iosPackageCheckpoint(for: different))
        }
    }
}

private func expectIOSMergeRecoveryFailure(
    _ operation: () async throws -> some Any
) async {
    do {
        _ = try await operation()
        Issue.record("unsafe iOS merge recovery record was accepted")
    } catch let error as IOSDeviceSyncMergeRecoveryStoreError {
        #expect(error == .invalidFile)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private func makeIOSRecoveryRecord() throws -> IOSDeviceSyncMergeRecoveryRecord {
    let key = EpisodeSyncKey(workID: SyncWorkID(), episodeID: EpisodeID())
    let branchID = SyncBranchID()
    let replicaID = SyncReplicaID()
    let sessionID = SyncEditSessionID()
    let local = try EpisodeRevision(
        key: key,
        parentRevisionIDs: [],
        branchID: branchID,
        authorReplicaID: replicaID,
        authorSessionID: sessionID,
        content: "local",
        clientCreatedAt: Date(timeIntervalSince1970: 1)
    )
    let remote = try EpisodeRevision(
        key: key,
        parentRevisionIDs: [],
        branchID: SyncBranchID(),
        authorReplicaID: SyncReplicaID(),
        authorSessionID: SyncEditSessionID(),
        content: "remote",
        clientCreatedAt: Date(timeIntervalSince1970: 2)
    )
    return IOSDeviceSyncMergeRecoveryRecord(
        localWorkingCopyID: LocalWorkingCopyID(),
        key: key,
        conflict: EpisodeConflict(base: nil, local: local, remote: remote),
        content: "chosen",
        purpose: .acceptedResolution
    )
}

private func iosRecoveryRecordURL(
    for record: IOSDeviceSyncMergeRecoveryRecord,
    root: URL
) -> URL {
    let identity = [
        "fuminiwa-device-sync-merge-recovery-v1",
        record.localWorkingCopyID.rawValue.uuidString,
        record.key.workID.rawValue.uuidString,
        record.key.episodeID.rawValue.uuidString
    ].joined(separator: "\n")
    return root.appendingPathComponent(SyncContentDigest(content: identity).rawValue + ".json")
}

private func iosPackageCheckpoint(
    for marker: IOSDeviceSyncEditIntentMarker
) -> IOSDeviceSyncPackageCheckpoint {
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

private struct IOSRootFixture {
    let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-ios-device-sync-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
