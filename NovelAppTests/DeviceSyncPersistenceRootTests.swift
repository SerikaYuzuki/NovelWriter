import Foundation
import NovelCore
import NovelSync
import Testing

@Suite("Device Sync persistence roots")
struct DeviceSyncPersistenceRootTests {
    @Test("merge recovery root rejects intermediate and final symlinks")
    func mergeRecoveryRootRejectsSymlinks() throws {
        let fixture = try RootFixture()
        defer { fixture.remove() }

        let external = fixture.base.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let intermediate = fixture.base.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: intermediate, withDestinationURL: external)
        #expect(throws: DeviceSyncMergeRecoveryStoreError.self) {
            _ = try FileDeviceSyncMergeRecoveryStore(
                rootURL: intermediate.appendingPathComponent("merge", isDirectory: true),
                trustedAncestorURL: fixture.base
            )
        }

        let final = fixture.base.appendingPathComponent("final", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: final, withDestinationURL: external)
        #expect(throws: DeviceSyncMergeRecoveryStoreError.self) {
            _ = try FileDeviceSyncMergeRecoveryStore(
                rootURL: final,
                trustedAncestorURL: fixture.base
            )
        }
    }

    @Test("merge recovery root identity replacement fails closed")
    func mergeRecoveryRootReplacementFailsClosed() async throws {
        let fixture = try RootFixture()
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("merge", isDirectory: true)
        let store = try FileDeviceSyncMergeRecoveryStore(
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
            Issue.record("replaced merge recovery root was accepted")
        } catch let error as DeviceSyncMergeRecoveryStoreError {
            #expect(error == .unsafeRoot)
        }
    }

    @Test("merge recovery record symlink fails closed for every operation")
    func mergeRecoveryRecordSymlinkFailsClosed() async throws {
        let fixture = try RootFixture()
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("merge", isDirectory: true)
        let store = try FileDeviceSyncMergeRecoveryStore(
            rootURL: root,
            trustedAncestorURL: fixture.base
        )
        let record = try makeRecoveryRecord()
        let external = fixture.base.appendingPathComponent("external.json")
        try Data("forged".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: recoveryRecordURL(for: record, root: root),
            withDestinationURL: external
        )

        await expectMergeRecoveryFailure { try await store.save(record) }
        await expectMergeRecoveryFailure {
            try await store.load(localWorkingCopyID: record.localWorkingCopyID, key: record.key)
        }
        await expectMergeRecoveryFailure {
            try await store.remove(localWorkingCopyID: record.localWorkingCopyID, key: record.key)
        }
    }
}

private func expectMergeRecoveryFailure(
    _ operation: () async throws -> some Any
) async {
    do {
        _ = try await operation()
        Issue.record("unsafe merge recovery record was accepted")
    } catch let error as DeviceSyncMergeRecoveryStoreError {
        #expect(error == .invalidFile)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private func makeRecoveryRecord() throws -> DeviceSyncMergeRecoveryRecord {
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
    return DeviceSyncMergeRecoveryRecord(
        localWorkingCopyID: LocalWorkingCopyID(),
        key: key,
        conflict: EpisodeConflict(base: nil, local: local, remote: remote),
        content: "chosen",
        purpose: .acceptedResolution
    )
}

private func recoveryRecordURL(
    for record: DeviceSyncMergeRecoveryRecord,
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

private struct RootFixture {
    let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-device-sync-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
