import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import SnapshotSyncV2MigrationCore
import Testing

@Suite("Snapshot Sync v2 migration")
struct MigrationTests {
    @Test
    func inventoryIsDryRunAndDoesNotCreateTarget() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = fixture.root.appendingPathComponent("target", isDirectory: true)
        let result = try await MigrationRunner().run(MigrationOptions(sourceURL: fixture.source, targetRoot: target))
        #expect(result.state == nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(result.inventory.documentID == fixture.documentID.uuidString.lowercased())
    }

    @Test
    func uppercaseManifestUUIDIsCanonicalizedToLowercaseIdentity() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manifestURL = fixture.source.appendingPathComponent("manifest.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        object["documentID"] = fixture.documentID.uuidString.uppercased()
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
        let result = try await MigrationRunner().run(MigrationOptions(sourceURL: fixture.source, targetRoot: fixture.root.appendingPathComponent("target")))
        #expect(result.inventory.documentID == fixture.documentID.uuidString.lowercased())
    }

    @Test
    func unknownAccountIsQuarantinedWithoutCreatingWork() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inventory = try await MigrationRunner().run(MigrationOptions(sourceURL: fixture.source, targetRoot: fixture.root.appendingPathComponent("dry"))).inventory
        let account = MigrationAccountBinding(
            binding: V2AccountBinding(accountID: "acct_unknown", accountFence: String(repeating: "f", count: 64), serverInstanceID: "server"),
            knownAccountIDs: ["acct_other"]
        )
        let target = fixture.root.appendingPathComponent("target")
        let result = try await MigrationRunner().run(MigrationOptions(sourceURL: fixture.source, targetRoot: target, commit: true, expectedSourceDigest: inventory.sourceDigest, verifiedMarker: "marker", account: account))
        #expect(result.state == V2MigrationLedgerState.quarantined)
        let store = try LocalSyncV2Store(root: target, policy: .openExisting)
        #expect(try await store.listWorks(scope: .unbound).isEmpty)
        await store.close()
    }

    @Test
    func stagedCheckpointResumesAfterStoreReopen() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (inventory, model, encoded) = try await ArchiveReader().inventoryAsync(sourceURL: fixture.source)
        let target = fixture.root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = try LocalSyncV2Store(root: target, policy: .createNew)
        let migrationID = UUID()
        _ = try await store.recordMigrationDiscovered(migrationID: migrationID, sourceKind: "novelpkg", sourceDigest: decodeHex(inventory.sourceDigest), evidenceBytes: inventory.registryEvidence)
        _ = try await store.recordMigrationBackupExported(migrationID: migrationID, exportBackupMarker: "export:\(inventory.sourceDigest)", evidenceBytes: inventory.registryEvidence)
        let workID = try WorkID(uuidString: inventory.workID)
        let staging = V2MigrationStagingInput(migrationID: migrationID, proposedWorkID: workID, proposedDocumentID: DocumentID(model.document.id), snapshotID: encoded.snapshotId, manifestBytes: encoded.manifestBytes, objects: encoded.objects)
        _ = try await store.stageMigration(staging)
        let account = V2AccountBinding(accountID: "acct_known", accountFence: String(repeating: "f", count: 64), serverInstanceID: "server")
        _ = try await store.verifyMigration(migrationID: migrationID, accountID: account.accountID, evidenceBytes: inventory.registryEvidence)
        await store.close()
        let reopened = try LocalSyncV2Store(root: target, policy: .openExisting)
        let result = try await reopened.commitMigration(V2MigrationCommitRequest(staging: staging, binding: account, expectedSourceDigest: decodeHex(inventory.sourceDigest), verifiedMarker: "marker", document: model.document, documentCreatedAt: model.documentCreatedAt))
        #expect(!result.noChanges)
        await reopened.close()
    }

    @Test
    func commitAndExactReplayAreIdempotent() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = fixture.root.appendingPathComponent("target", isDirectory: true)
        let inventory = try await MigrationRunner().run(MigrationOptions(sourceURL: fixture.source, targetRoot: target)).inventory
        let (_, model, encoded) = try await ArchiveReader().inventoryAsync(sourceURL: fixture.source)
        let decoded = try SnapshotCodec.decode(manifestBytes: encoded.manifestBytes, objects: encoded.objects)
        #expect(decoded.document == model.document)
        #expect(decoded.documentCreatedAt == model.documentCreatedAt)
        let account = MigrationAccountBinding(binding: V2AccountBinding(accountID: "acct_known", accountFence: String(repeating: "f", count: 64), serverInstanceID: "server"), knownAccountIDs: ["acct_known"])
        let options = MigrationOptions(sourceURL: fixture.source, targetRoot: target, commit: true, expectedSourceDigest: inventory.sourceDigest, verifiedMarker: "verified-marker", account: account)
        let first = try await MigrationRunner().run(options)
        #expect(first.state == V2MigrationLedgerState.committed)
        #expect(!first.noChanges)
        let replay = try await MigrationRunner().run(MigrationOptions(sourceURL: fixture.source, targetRoot: target, commit: true, expectedSourceDigest: inventory.sourceDigest, verifiedMarker: "verified-marker", account: account, resume: true))
        #expect(replay.state == V2MigrationLedgerState.committed)
        #expect(replay.noChanges)
    }

    @Test
    func symlinkAndProductionTargetsAreRejected() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let symlink = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.root)
        await #expect(throws: MigrationError.invalidTarget("symlink")) {
            try await MigrationRunner().run(MigrationOptions(sourceURL: fixture.source, targetRoot: symlink.appendingPathComponent("target")))
        }
        let production = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SnapshotSyncV2MigrationTest")
        await #expect(throws: MigrationError.productionRootRejected) {
            try await MigrationRunner().run(MigrationOptions(sourceURL: fixture.source, targetRoot: production))
        }
    }
}

private func decodeHex(_ value: String) -> Data {
    Data((0 ..< value.count / 2).compactMap { index in
        let start = value.index(value.startIndex, offsetBy: index * 2)
        return UInt8(value[start ..< value.index(start, offsetBy: 2)], radix: 16)
    })
}

private struct Fixture {
    let root: URL
    let source: URL
    let documentID: UUID

    static func make() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.novelpkg", isDirectory: true)
        let documentID = UUID()
        try FileManager.default.createDirectory(at: source.appendingPathComponent("episodes", isDirectory: true), withIntermediateDirectories: true)
        let chapterID = UUID()
        let episodeID = UUID()
        let manifest: [String: Any] = [
            "formatVersion": "3", "documentID": documentID.uuidString.lowercased(), "title": "fixture",
            "chapters": [["id": chapterID.uuidString.lowercased(), "title": "chapter", "episodes": [["id": episodeID.uuidString.lowercased(), "title": "episode"]]]],
            "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z"
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: source.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        try Data("本文".utf8).write(to: source.appendingPathComponent("episodes").appendingPathComponent("\(episodeID.uuidString.lowercased()).md"))
        return Fixture(root: root, source: source, documentID: documentID)
    }
}
