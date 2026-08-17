import Foundation
import NovelCore
import NovelSync
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
        let original = try await ArchiveReader().inventoryAsync(sourceURL: fixture.source)
        let trustedSource = try fixture.makeTrustedStage(archive: original)
        let inventory = try await ArchiveReader().inventoryAsync(sourceURL: trustedSource)
        let account = MigrationAccountBinding(
            binding: V2AccountBinding(accountID: "acct_unknown", accountFence: String(repeating: "f", count: 64), serverInstanceID: "server"),
            knownAccountIDs: ["acct_other"]
        )
        let target = fixture.root.appendingPathComponent("target")
        let workID = try WorkID(uuidString: inventory.inventory.workID)
        let result = try await MigrationRunner().run(MigrationOptions(sourceURL: trustedSource, targetRoot: target, commit: true, expectedSourceDigest: inventory.inventory.sourceDigest, verifiedMarker: "marker", account: account, workID: workID))
        #expect(result.state == V2MigrationLedgerState.quarantined)
        let store = try LocalSyncV2Store(root: target, policy: .openExisting)
        #expect(try await store.listWorks(scope: .unbound).isEmpty)
        await store.close()
    }

    @Test
    func stagedCheckpointResumesAfterStoreReopen() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let archive = try await ArchiveReader().inventoryAsync(sourceURL: fixture.source)
        let inventory = archive.inventory
        let model = archive.model
        let encoded = archive.encoded
        let target = fixture.root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let store = try LocalSyncV2Store(root: target, policy: .createNew)
        let migrationID = UUID()
        _ = try await store.recordMigrationDiscovered(migrationID: migrationID, sourceKind: "novelpkg", sourceDigest: decodeHex(inventory.sourceDigest), evidenceBytes: inventory.registryEvidence)
        _ = try await store.recordMigrationBackupExported(migrationID: migrationID, exportBackupMarker: "export:\(inventory.sourceDigest)", evidenceBytes: inventory.registryEvidence)
        let workID = try WorkID(uuidString: inventory.workID)
        let staging = V2MigrationStagingInput(migrationID: migrationID, proposedWorkID: workID, proposedDocumentID: DocumentID(model.document.id), snapshotID: encoded.snapshotId, manifestBytes: encoded.manifestBytes, objects: encoded.objects, resources: archive.portableResources)
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
        let originalArchive = try await ArchiveReader().inventoryAsync(sourceURL: fixture.source)
        let trustedSource = try fixture.makeTrustedStage(archive: originalArchive)
        let target = fixture.root.appendingPathComponent("target", isDirectory: true)
        let inventory = try await MigrationRunner().run(MigrationOptions(sourceURL: trustedSource, targetRoot: target)).inventory
        let archive = try await ArchiveReader().inventoryAsync(sourceURL: trustedSource)
        let model = archive.model
        let encoded = archive.encoded
        let decoded = try SnapshotCodec.decode(manifestBytes: encoded.manifestBytes, objects: encoded.objects)
        #expect(decoded.document == model.document)
        #expect(decoded.documentCreatedAt == model.documentCreatedAt)
        let account = MigrationAccountBinding(binding: V2AccountBinding(accountID: "acct_known", accountFence: String(repeating: "f", count: 64), serverInstanceID: "server"), knownAccountIDs: ["acct_known"])
        let workID = try WorkID(uuidString: archive.inventory.workID)
        let options = MigrationOptions(sourceURL: trustedSource, targetRoot: target, commit: true, expectedSourceDigest: inventory.sourceDigest, verifiedMarker: "verified-marker", account: account, workID: workID)
        let first = try await MigrationRunner().run(options)
        #expect(first.state == V2MigrationLedgerState.committed)
        #expect(!first.noChanges)
        let store = try LocalSyncV2Store(root: target, policy: .openExisting)
        let opened = try await store.open(workID: workID, scope: .bound(account.binding))
        #expect(opened.resources == archive.portableResources)
        await store.close()
        let replay = try await MigrationRunner().run(MigrationOptions(sourceURL: trustedSource, targetRoot: target, commit: true, expectedSourceDigest: inventory.sourceDigest, verifiedMarker: "verified-marker", account: account, workID: workID, resume: true))
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

    @Test
    func commitRequiresVerifiedExportStageAndRejectsQuarantine() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let archive = try await ArchiveReader().inventoryAsync(sourceURL: fixture.source)
        let account = knownAccount()
        let workID = try WorkID(uuidString: archive.inventory.workID)
        let directTarget = fixture.root.appendingPathComponent("direct-target")
        do {
            _ = try await MigrationRunner().run(MigrationOptions(
                sourceURL: fixture.source,
                targetRoot: directTarget,
                commit: true,
                expectedSourceDigest: archive.inventory.sourceDigest,
                verifiedMarker: "marker",
                account: account,
                workID: workID
            ))
            Issue.record("an arbitrary package must not be committed")
        } catch let error as MigrationError {
            #expect(String(describing: error).contains("untrustedExportStage"))
        }

        let trusted = try fixture.makeTrustedStage(archive: archive)
        let reportURL = trusted.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("migration-ledger.json")
        var report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
        var entries = try #require(report["entries"] as? [[String: Any]])
        entries[0]["disposition"] = "quarantine"
        entries[0]["outputRelativePath"] = "quarantine/\(trusted.lastPathComponent)"
        report["entries"] = entries
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: reportURL, options: .atomic)
        let target = fixture.root.appendingPathComponent("quarantine-target")
        do {
            _ = try await MigrationRunner().run(MigrationOptions(
                sourceURL: trusted,
                targetRoot: target,
                commit: true,
                expectedSourceDigest: archive.inventory.sourceDigest,
                verifiedMarker: "marker",
                account: account,
                workID: workID
            ))
            Issue.record("quarantine entries must not be committed")
        } catch let error as MigrationError {
            #expect(String(describing: error).contains("exportProvenanceMismatch"))
        }
    }

    @Test
    func commitRechecksExactStageProvenanceAndPackageIdentity() async throws {
        let tamper: [(String, (URL, URL) throws -> Void)] = [
            ("ledger", { _, stage in
                let url = stage.appendingPathComponent("migration-ledger.json")
                var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                var entries = try #require(value["entries"] as? [[String: Any]])
                entries[0]["projectionDigest"] = String(repeating: "0", count: 64)
                value["entries"] = entries
                try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
            }),
            ("marker", { _, stage in
                try Data("COMMITTED\nchanged".utf8).write(to: stage.appendingPathComponent("COMMITTED"), options: .atomic)
            }),
            ("sidecar", { source, stage in
                let workID = source.deletingPathExtension().lastPathComponent
                let url = stage.appendingPathComponent(".state/\(workID).json")
                var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                value["projectionDigest"] = String(repeating: "1", count: 64)
                try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
            }),
            ("package", { source, _ in
                try Data("tampered".utf8).write(to: source.appendingPathComponent("episodes").appendingPathComponent("tampered.md"), options: .atomic)
            }),
            ("filename", { source, _ in
                let renamed = source.deletingLastPathComponent().appendingPathComponent("(UUID().uuidString).novelpkg", isDirectory: true)
                try FileManager.default.moveItem(at: source, to: renamed)
            })
        ]
        for (label, mutate) in tamper {
            let fixture = try Fixture.make()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let archive = try await ArchiveReader().inventoryAsync(sourceURL: fixture.source)
            let trusted = try fixture.makeTrustedStage(archive: archive)
            let stage = trusted.deletingLastPathComponent().deletingLastPathComponent()
            try mutate(trusted, stage)
            let target = fixture.root.appendingPathComponent("target")
            let account = knownAccount()
            let workID = try WorkID(uuidString: archive.inventory.workID)
            do {
                _ = try await MigrationRunner().run(MigrationOptions(
                    sourceURL: trusted,
                    targetRoot: target,
                    commit: true,
                    expectedSourceDigest: archive.inventory.sourceDigest,
                    verifiedMarker: "marker",
                    account: account,
                    workID: workID
                ))
                Issue.record("tampered \(label) stage must be rejected")
            } catch {
                // Any typed provenance/source failure is fail-closed; no Work is created.
                #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("Library/library.sqlite").path))
            }
        }
    }
}

private func knownAccount() -> MigrationAccountBinding {
    MigrationAccountBinding(
        binding: V2AccountBinding(accountID: "acct_known", accountFence: String(repeating: "f", count: 64), serverInstanceID: "server"),
        knownAccountIDs: ["acct_known"]
    )
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
        let resources = source.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("opaque resource".utf8).write(to: resources.appendingPathComponent("cover.txt"))
        return Fixture(root: root, source: source, documentID: documentID)
    }

    func makeTrustedStage(archive: ArchiveReadResult) throws -> URL {
        let workID = try WorkID(uuidString: archive.inventory.workID)
        let filenameWorkID = workID.rawValue.uuidString
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        let destination = stage.appendingPathComponent("verified/\(filenameWorkID).novelpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("quarantine"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("needs-review"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage.appendingPathComponent(".state"), withIntermediateDirectories: true)
        let projectionBytes = try WorkCanonicalJSON.encodeSnapshot(WorkSnapshot(document: archive.model.document))
        let projectionDigest = SHA256Digest.hex(projectionBytes)
        let snapshotID = String(repeating: "d", count: 64)
        let sourceSQLiteDigest = String(repeating: "a", count: 64)
        let archiveDigest = String(repeating: "b", count: 64)
        let classificationDigest = String(repeating: "c", count: 64)
        let exportID = UUID()
        let report: [String: Any] = [
            "formatVersion": 1, "exportID": exportID.uuidString.lowercased(),
            "sourceSQLiteSHA256": sourceSQLiteDigest,
            "sourceArchiveManifestPath": "archive/sha256-manifest.txt",
            "sourceArchiveManifestSHA256": archiveDigest,
            "classificationLedgerSHA256": classificationDigest,
            "sourceWorkCount": 1, "generatedAt": "2026-08-18T00:00:00Z",
            "attachmentsPolicy": "fixture", "objectVerificationIssues": [], "sourceRowIssues": [],
            "entries": [[
                "workID": workID.description, "disposition": "verified",
                "snapshotID": snapshotID, "outputRelativePath": "verified/\(filenameWorkID).novelpkg",
                "outcome": "exported", "note": NSNull(), "projectionDigest": projectionDigest
            ]]
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: stage.appendingPathComponent("migration-ledger.json"), options: .atomic)
        let run: [String: Any] = [
            "exportID": exportID.uuidString.lowercased(), "sourceDigest": sourceSQLiteDigest,
            "archiveManifestDigest": archiveDigest, "classificationLedgerDigest": classificationDigest,
            "status": "committed"
        ]
        try JSONSerialization.data(withJSONObject: run, options: [.sortedKeys]).write(to: stage.appendingPathComponent("migration-run.json"), options: .atomic)
        let state: [String: Any] = ["sourceDigest": sourceSQLiteDigest, "snapshotID": snapshotID, "projectionDigest": projectionDigest]
        try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: stage.appendingPathComponent(".state/\(filenameWorkID).json"), options: .atomic)
        try Data("COMMITTED\n".utf8).write(to: stage.appendingPathComponent("COMMITTED"), options: .atomic)
        return destination
    }
}
