import Foundation
import NovelCore
import NovelSync
import NovelSyncV2
import NovelSyncV2Store
@testable import SnapshotSyncV2MigrationCore
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
        let options = try fixture.commitOptions(sourceURL: trustedSource, targetRoot: target, expectedSourceDigest: inventory.inventory.sourceDigest, verifiedMarker: "marker", account: account, workID: workID)
        let result = try await MigrationRunner().run(options)
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
        let options = try fixture.commitOptions(sourceURL: trustedSource, targetRoot: target, expectedSourceDigest: inventory.sourceDigest, verifiedMarker: "verified-marker", account: account, workID: workID)
        let first = try await MigrationRunner().run(options)
        #expect(first.state == V2MigrationLedgerState.committed)
        #expect(!first.noChanges)
        let store = try LocalSyncV2Store(root: target, policy: .openExisting)
        let opened = try await store.open(workID: workID, scope: .bound(account.binding))
        #expect(opened.resources == archive.portableResources)
        await store.close()
        let replayOptions = try fixture.commitOptions(sourceURL: trustedSource, targetRoot: target, expectedSourceDigest: inventory.sourceDigest, verifiedMarker: "verified-marker", account: account, workID: workID, resume: true)
        let replay = try await MigrationRunner().run(replayOptions)
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
            let options = try fixture.commitOptions(
                sourceURL: trusted,
                targetRoot: target,
                commit: true,
                expectedSourceDigest: archive.inventory.sourceDigest,
                verifiedMarker: "marker",
                account: account,
                workID: workID
            )
            _ = try await MigrationRunner().run(options)
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
                let options = try fixture.commitOptions(
                    sourceURL: trusted,
                    targetRoot: target,
                    commit: true,
                    expectedSourceDigest: archive.inventory.sourceDigest,
                    verifiedMarker: "marker",
                    account: account,
                    workID: workID
                )
                _ = try await MigrationRunner().run(options)
                Issue.record("tampered \(label) stage must be rejected")
            } catch {
                // Any typed provenance/source failure is fail-closed; no Work is created.
                #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("Library/library.sqlite").path))
            }
        }
    }

    @Test
    func quarantineCopiedIntoVerifiedRejectsSelfGeneratedProvenance() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let archive = try await ArchiveReader().inventoryAsync(sourceURL: fixture.source)
        let trusted = try fixture.makeTrustedStage(archive: archive)
        try fixture.rewriteAuthority(disposition: "quarantine")
        let account = knownAccount()
        let workID = try WorkID(uuidString: archive.inventory.workID)
        let target = fixture.root.appendingPathComponent("target")
        do {
            let options = try fixture.commitOptions(
                sourceURL: trusted,
                targetRoot: target,
                expectedSourceDigest: archive.inventory.sourceDigest,
                verifiedMarker: "marker",
                account: account,
                workID: workID
            )
            _ = try await MigrationRunner().run(options)
            Issue.record("external quarantine authority must reject a copied verified package")
        } catch let error as MigrationError {
            #expect(String(describing: error).contains("externalAuthorityEntry"))
            #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("Library/library.sqlite").path))
        }
    }

    @Test
    func authorityTamperAndPathSwapAreRejected() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let archive = try await ArchiveReader().inventoryAsync(sourceURL: fixture.source)
        let trusted = try fixture.makeTrustedStage(archive: archive)
        var authority = try fixture.readAuthority()
        authority = MigrationTrustedProvenanceAuthority(
            authorityID: authority.authorityID,
            sourceSQLiteSHA256: String(repeating: "0", count: 64),
            sourceArchiveManifestSHA256: authority.sourceArchiveManifestSHA256,
            classificationLedgerSHA256: authority.classificationLedgerSHA256,
            entries: authority.entries
        )
        try fixture.writeAuthority(authority)
        let account = knownAccount()
        let workID = try WorkID(uuidString: archive.inventory.workID)
        let target = fixture.root.appendingPathComponent("target")
        do {
            let options = try fixture.commitOptions(
                sourceURL: trusted,
                targetRoot: target,
                expectedSourceDigest: archive.inventory.sourceDigest,
                verifiedMarker: "marker",
                account: account,
                workID: workID
            )
            _ = try await MigrationRunner().run(options)
            Issue.record("authority tamper must be rejected")
        } catch let error as MigrationError {
            #expect(String(describing: error).contains("externalAuthority"))
        }

        let swapped = fixture.root.appendingPathComponent("swapped-authority.json")
        try FileManager.default.copyItem(at: fixture.authorityURL, to: swapped)
        let swappedData = try Data(contentsOf: swapped)
        let swappedDigest = SHA256Digest.hex(swappedData)
        let swapOptions = MigrationOptions(
            sourceURL: trusted,
            targetRoot: fixture.root.appendingPathComponent("swap-target"),
            commit: true,
            expectedSourceDigest: archive.inventory.sourceDigest,
            verifiedMarker: "marker",
            account: account,
            workID: workID,
            trustedAuthorityRootURL: fixture.root,
            trustedAuthorityURL: swapped,
            expectedAuthorityDigest: swappedDigest,
            expectedAuthorityID: "different-authority"
        )
        await #expect(throws: MigrationError.self) {
            try await MigrationRunner().run(swapOptions)
        }
    }

    @Test
    func authoritySymlinkIsRejected() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let archive = try await ArchiveReader().inventoryAsync(sourceURL: fixture.source)
        let trusted = try fixture.makeTrustedStage(archive: archive)
        let symlink = fixture.authorityRoot.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.authorityURL)
        let account = knownAccount()
        let workID = try WorkID(uuidString: archive.inventory.workID)
        let authorityData = try Data(contentsOf: fixture.authorityURL)
        let authorityDigest = SHA256Digest.hex(authorityData)
        let options = MigrationOptions(
            sourceURL: trusted,
            targetRoot: fixture.root.appendingPathComponent("target"),
            commit: true,
            expectedSourceDigest: archive.inventory.sourceDigest,
            verifiedMarker: "marker",
            account: account,
            workID: workID,
            trustedAuthorityRootURL: fixture.authorityRoot,
            trustedAuthorityURL: symlink,
            expectedAuthorityDigest: authorityDigest,
            expectedAuthorityID: fixture.authorityID
        )
        await #expect(throws: MigrationError.self) {
            try await MigrationRunner().run(options)
        }
    }

    @Test
    func authorityRehashImmediatelyBeforeCommitRejectsTOCTOU() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let archive = try await ArchiveReader().inventoryAsync(sourceURL: fixture.source)
        let trusted = try fixture.makeTrustedStage(archive: archive)
        let account = knownAccount()
        let workID = try WorkID(uuidString: archive.inventory.workID)
        let options = try fixture.commitOptions(
            sourceURL: trusted,
            targetRoot: fixture.root.appendingPathComponent("target"),
            expectedSourceDigest: archive.inventory.sourceDigest,
            verifiedMarker: "marker",
            account: account,
            workID: workID
        )
        let runner = MigrationRunner(finalCommitHook: {
            var authority = try fixture.readAuthority()
            authority = MigrationTrustedProvenanceAuthority(
                authorityID: authority.authorityID,
                sourceSQLiteSHA256: String(repeating: "1", count: 64),
                sourceArchiveManifestSHA256: authority.sourceArchiveManifestSHA256,
                classificationLedgerSHA256: authority.classificationLedgerSHA256,
                entries: authority.entries
            )
            try fixture.writeAuthority(authority)
        })
        await #expect(throws: MigrationError.self) {
            try await runner.run(options)
        }
        #expect(!FileManager.default.fileExists(atPath: options.targetRoot.appendingPathComponent("Library/library.sqlite").path))
    }

    @Test
    func authorityBuilderCreatesExternalAuthorityAndAdopterUsesIt() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let archive = try await ArchiveReader().inventoryAsync(sourceURL: fixture.source)
        let trusted = try fixture.makeTrustedStage(archive: archive)
        let builderOptions = try fixture.makeBuilderOptions(archive: archive, stage: trusted, disposition: "verified")
        let built = try await TrustedProvenanceBuilder().build(builderOptions)
        #expect(FileManager.default.fileExists(atPath: built.authorityURL.path))
        let authorityData = try Data(contentsOf: built.authorityURL)
        #expect(built.authorityDigest == SHA256Digest.hex(authorityData))
        let account = knownAccount()
        let workID = try WorkID(uuidString: archive.inventory.workID)
        let adoption = MigrationOptions(
            sourceURL: trusted,
            targetRoot: fixture.root.appendingPathComponent("builder-target"),
            commit: true,
            expectedSourceDigest: archive.inventory.sourceDigest,
            verifiedMarker: "builder-marker",
            account: account,
            workID: workID,
            trustedAuthorityRootURL: builderOptions.outputRootURL,
            trustedAuthorityURL: built.authorityURL,
            expectedAuthorityDigest: built.authorityDigest,
            expectedAuthorityID: built.authorityID
        )
        let result = try await MigrationRunner().run(adoption)
        #expect(result.state == .committed)
    }

    @Test
    func authorityBuilderPreservesCandidateAndRejectsSelfReportSpoof() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let archive = try await ArchiveReader().inventoryAsync(sourceURL: fixture.source)
        let trusted = try fixture.makeTrustedStage(archive: archive)
        let builderOptions = try fixture.makeBuilderOptions(archive: archive, stage: trusted, disposition: "verified_candidate")
        let built = try await TrustedProvenanceBuilder().build(builderOptions)
        let authority = try JSONDecoder().decode(MigrationTrustedProvenanceAuthority.self, from: Data(contentsOf: built.authorityURL))
        #expect(authority.entries.first?.disposition == "verified_candidate")
        let account = knownAccount()
        let workID = try WorkID(uuidString: archive.inventory.workID)
        let adoption = MigrationOptions(
            sourceURL: trusted,
            targetRoot: fixture.root.appendingPathComponent("candidate-target"),
            commit: true,
            expectedSourceDigest: archive.inventory.sourceDigest,
            verifiedMarker: "candidate-marker",
            account: account,
            workID: workID,
            trustedAuthorityRootURL: builderOptions.outputRootURL,
            trustedAuthorityURL: built.authorityURL,
            expectedAuthorityDigest: built.authorityDigest,
            expectedAuthorityID: built.authorityID
        )
        await #expect(throws: MigrationError.self) {
            try await MigrationRunner().run(adoption)
        }
        #expect(!FileManager.default.fileExists(atPath: adoption.targetRoot.appendingPathComponent("Library/library.sqlite").path))
    }

    @Test
    func authorityBuilderRejectsTamperExistingOutputSymlinkAndTOCTOU() async throws {
        let fixture = try Fixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let archive = try await ArchiveReader().inventoryAsync(sourceURL: fixture.source)
        let trusted = try fixture.makeTrustedStage(archive: archive)
        let builderOptions = try fixture.makeBuilderOptions(archive: archive, stage: trusted, disposition: "verified")
        let first = try await TrustedProvenanceBuilder().build(builderOptions)
        await #expect(throws: TrustedProvenanceBuilderError.self) {
            try await TrustedProvenanceBuilder().build(builderOptions)
        }
        let tampered = try fixture.makeBuilderOptions(archive: archive, stage: trusted, disposition: "verified", outputName: "tampered-authority", setReadOnly: false)
        try Data("tampered".utf8).write(to: tampered.classificationLedgerURL, options: .atomic)
        try fixture.makeReadOnly(tampered.classificationLedgerURL)
        await #expect(throws: TrustedProvenanceBuilderError.self) {
            try await TrustedProvenanceBuilder().build(tampered)
        }
        _ = first

        let symlinkRoot = fixture.root.appendingPathComponent("symlink-authority")
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: builderOptions.outputRootURL)
        let symlinkOptions = TrustedProvenanceBuilderOptions(
            stageRootURL: builderOptions.stageRootURL,
            classificationLedgerURL: builderOptions.classificationLedgerURL,
            sourceArchiveRootURL: builderOptions.sourceArchiveRootURL,
            archiveManifestURL: builderOptions.archiveManifestURL,
            sourceSQLiteURL: builderOptions.sourceSQLiteURL,
            expectedClassificationDigest: builderOptions.expectedClassificationDigest,
            expectedSourceSQLiteDigest: builderOptions.expectedSourceSQLiteDigest,
            expectedArchiveManifestDigest: builderOptions.expectedArchiveManifestDigest,
            expectedWorkCount: builderOptions.expectedWorkCount,
            authorityID: builderOptions.authorityID,
            outputRootURL: symlinkRoot
        )
        await #expect(throws: TrustedProvenanceBuilderError.self) {
            try await TrustedProvenanceBuilder().build(symlinkOptions)
        }

        let toctou = try fixture.makeBuilderOptions(archive: archive, stage: trusted, disposition: "verified", outputName: "toctou-authority")
        let builder = TrustedProvenanceBuilder(beforeOutputHook: {
            try fixture.makeWritable(toctou.classificationLedgerURL)
            try Data("changed".utf8).write(to: toctou.classificationLedgerURL, options: .atomic)
            try fixture.makeReadOnly(toctou.classificationLedgerURL)
        })
        await #expect(throws: TrustedProvenanceBuilderError.self) {
            try await builder.build(toctou)
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
    let authorityRoot: URL
    let authorityURL: URL
    let authorityID: String

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
        let authorityRoot = root.appendingPathComponent("trusted-authority", isDirectory: true)
        let authorityURL = authorityRoot.appendingPathComponent("provenance.json")
        return Fixture(root: root, source: source, documentID: documentID, authorityRoot: authorityRoot, authorityURL: authorityURL, authorityID: "authority-fixture")
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
        let snapshotID = archive.encoded.snapshotId.description
        let sourceSQLiteDigest = String(repeating: "a", count: 64)
        let archiveDigest = String(repeating: "b", count: 64)
        let classificationDigest = String(repeating: "c", count: 64)
        let exportID = UUID()
        let evidenceDigest = try inventoryEvidenceDigest(archive.inventory)
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
        try FileManager.default.createDirectory(at: authorityRoot, withIntermediateDirectories: true)
        let authority = MigrationTrustedProvenanceAuthority(
            authorityID: authorityID,
            sourceSQLiteSHA256: sourceSQLiteDigest,
            sourceArchiveManifestSHA256: archiveDigest,
            classificationLedgerSHA256: classificationDigest,
            entries: [MigrationTrustedProvenanceEntry(
                workID: workID.rawValue,
                disposition: "verified",
                packageSHA256: archive.inventory.sourceDigest,
                sourceSQLiteSHA256: sourceSQLiteDigest,
                sourceArchiveManifestSHA256: archiveDigest,
                classificationLedgerSHA256: classificationDigest,
                snapshotID: snapshotID,
                projectionDigest: projectionDigest,
                inventoryEvidenceSHA256: evidenceDigest
            )]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(authority).write(to: authorityURL, options: .atomic)
        return destination
    }

    func commitOptions(
        sourceURL: URL,
        targetRoot: URL,
        commit: Bool = true,
        expectedSourceDigest: String,
        verifiedMarker: String,
        account: MigrationAccountBinding,
        workID: WorkID,
        resume: Bool = false
    ) throws -> MigrationOptions {
        let authorityData = try Data(contentsOf: authorityURL)
        return MigrationOptions(
            sourceURL: sourceURL,
            targetRoot: targetRoot,
            commit: commit,
            expectedSourceDigest: expectedSourceDigest,
            verifiedMarker: verifiedMarker,
            account: account,
            workID: workID,
            resume: resume,
            trustedAuthorityRootURL: authorityRoot,
            trustedAuthorityURL: authorityURL,
            expectedAuthorityDigest: SHA256Digest.hex(authorityData),
            expectedAuthorityID: authorityID
        )
    }

    func readAuthority() throws -> MigrationTrustedProvenanceAuthority {
        try JSONDecoder().decode(MigrationTrustedProvenanceAuthority.self, from: Data(contentsOf: authorityURL))
    }

    func writeAuthority(_ authority: MigrationTrustedProvenanceAuthority) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(authority).write(to: authorityURL, options: .atomic)
    }

    func rewriteAuthority(disposition: String) throws {
        let authority = try readAuthority()
        try writeAuthority(MigrationTrustedProvenanceAuthority(
            authorityID: authority.authorityID,
            sourceSQLiteSHA256: authority.sourceSQLiteSHA256,
            sourceArchiveManifestSHA256: authority.sourceArchiveManifestSHA256,
            classificationLedgerSHA256: authority.classificationLedgerSHA256,
            entries: authority.entries.map { entry in
                MigrationTrustedProvenanceEntry(
                    workID: entry.workID,
                    disposition: disposition,
                    packageSHA256: entry.packageSHA256,
                    sourceSQLiteSHA256: entry.sourceSQLiteSHA256,
                    sourceArchiveManifestSHA256: entry.sourceArchiveManifestSHA256,
                    classificationLedgerSHA256: entry.classificationLedgerSHA256,
                    snapshotID: entry.snapshotID,
                    projectionDigest: entry.projectionDigest,
                    inventoryEvidenceSHA256: entry.inventoryEvidenceSHA256
                )
            }
        ))
    }

    func makeBuilderOptions(
        archive: ArchiveReadResult,
        stage: URL,
        disposition: String,
        outputName: String = "builder-authority",
        setReadOnly: Bool = true
    ) throws -> TrustedProvenanceBuilderOptions {
        let stageRoot = stage.lastPathComponent == "verified" || stage.pathExtension == "novelpkg"
            ? stage.deletingLastPathComponent().deletingLastPathComponent()
            : stage
        let archiveRoot = root.appendingPathComponent("legacy-archive", isDirectory: true)
        if FileManager.default.fileExists(atPath: stageRoot.path) {
            try makeWritableTree(stageRoot)
        }
        if FileManager.default.fileExists(atPath: archiveRoot.path) {
            try makeWritableTree(archiveRoot)
        }
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let sqliteURL = archiveRoot.appendingPathComponent("library.sqlite")
        let manifestURL = archiveRoot.appendingPathComponent("sha256-manifest.txt")
        try Data("legacy sqlite fixture".utf8).write(to: sqliteURL, options: .atomic)
        let sqliteData = try Data(contentsOf: sqliteURL)
        let manifest = "\(SHA256Digest.hex(sqliteData)) library.sqlite\n"
        try Data(manifest.utf8).write(to: manifestURL, options: .atomic)
        let classificationURL = root.appendingPathComponent("classification.csv")
        if FileManager.default.fileExists(atPath: classificationURL.path) {
            try makeWritable(classificationURL)
        }
        let workID = try WorkID(uuidString: archive.inventory.workID)
        let classification = "\(workID.description),\(disposition),\(archive.encoded.snapshotId.description),2026-01-01T00:00:00Z,1,\(archive.encoded.snapshotId.description),1,operator-evidence\n"
        try classification.write(to: classificationURL, atomically: true, encoding: .utf8)
        let manifestData = try Data(contentsOf: manifestURL)
        let classificationData = try Data(contentsOf: classificationURL)
        let sourceSQLiteDigest = SHA256Digest.hex(sqliteData)
        let archiveManifestDigest = SHA256Digest.hex(manifestData)
        let classificationDigest = SHA256Digest.hex(classificationData)
        try updateStageEvidence(
            stage: stageRoot,
            sourceSQLiteDigest: sourceSQLiteDigest,
            archiveManifestDigest: archiveManifestDigest,
            classificationDigest: classificationDigest
        )
        if setReadOnly {
            try makeReadOnly(stageRoot)
            try makeReadOnly(archiveRoot)
            try makeReadOnly(classificationURL)
        }
        return TrustedProvenanceBuilderOptions(
            stageRootURL: stageRoot,
            classificationLedgerURL: classificationURL,
            sourceArchiveRootURL: archiveRoot,
            archiveManifestURL: manifestURL,
            sourceSQLiteURL: sqliteURL,
            expectedClassificationDigest: classificationDigest,
            expectedSourceSQLiteDigest: sourceSQLiteDigest,
            expectedArchiveManifestDigest: archiveManifestDigest,
            expectedWorkCount: 1,
            authorityID: "builder-authority",
            outputRootURL: root.appendingPathComponent(outputName, isDirectory: true)
        )
    }

    private func updateStageEvidence(
        stage: URL,
        sourceSQLiteDigest: String,
        archiveManifestDigest: String,
        classificationDigest: String
    ) throws {
        let reportURL = stage.appendingPathComponent("migration-ledger.json")
        var report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
        report["sourceSQLiteSHA256"] = sourceSQLiteDigest
        report["sourceArchiveManifestSHA256"] = archiveManifestDigest
        report["classificationLedgerSHA256"] = classificationDigest
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: reportURL, options: .atomic)
        let runURL = stage.appendingPathComponent("migration-run.json")
        var run = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: runURL)) as? [String: Any])
        run["sourceDigest"] = sourceSQLiteDigest
        run["archiveManifestDigest"] = archiveManifestDigest
        run["classificationLedgerDigest"] = classificationDigest
        try JSONSerialization.data(withJSONObject: run, options: [.sortedKeys]).write(to: runURL, options: .atomic)
        let workID = try #require((report["entries"] as? [[String: Any]])?.first?["workID"] as? String)
        let stateURL = stage.appendingPathComponent(".state/\(workID).json")
        var state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        state["sourceDigest"] = sourceSQLiteDigest
        try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: stateURL, options: .atomic)
    }

    func makeWritable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    func makeWritableTree(_ url: URL) throws {
        let fileManager = FileManager.default
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            while let item = enumerator?.nextObject() as? URL {
                let itemValues = try item.resourceValues(forKeys: [.isDirectoryKey])
                try fileManager.setAttributes([.posixPermissions: itemValues.isDirectory == true ? 0o755 : 0o644], ofItemAtPath: item.path)
            }
        } else {
            try makeWritable(url)
        }
    }

    func makeReadOnly(_ url: URL) throws {
        let fileManager = FileManager.default
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            while let item = enumerator?.nextObject() as? URL {
                let itemValues = try item.resourceValues(forKeys: [.isDirectoryKey])
                try fileManager.setAttributes([.posixPermissions: itemValues.isDirectory == true ? 0o555 : 0o444], ofItemAtPath: item.path)
            }
            try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        } else {
            try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        }
    }
}

private func inventoryEvidenceDigest(_ inventory: SourceInventory) throws -> String {
    var object = try #require(JSONSerialization.jsonObject(with: inventory.registryEvidence) as? [String: Any])
    object.removeValue(forKey: "sourcePath")
    let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return SHA256Digest.hex(canonical)
}
