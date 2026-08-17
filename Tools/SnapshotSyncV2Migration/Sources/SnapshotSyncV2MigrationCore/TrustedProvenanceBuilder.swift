import Foundation
import NovelSync
import NovelSyncV2
import SnapshotSyncV2Migration

public enum TrustedProvenanceBuilderError: Error, Equatable, Sendable {
    case invalidArgument(String)
    case unsafeInput(String)
    case digestMismatch(String)
    case invalidStage(String)
    case invalidClassification(String)
    case invalidInventoryEvidence
    case outputAlreadyExists
    case outputOverlapsInput
    case outputWriteFailed(String)
}

public struct TrustedProvenanceBuilderOptions: Sendable {
    public let stageRootURL: URL
    public let classificationLedgerURL: URL
    public let sourceArchiveRootURL: URL
    public let archiveManifestURL: URL
    public let sourceSQLiteURL: URL
    public let expectedClassificationDigest: String
    public let expectedSourceSQLiteDigest: String
    public let expectedArchiveManifestDigest: String
    public let expectedWorkCount: Int
    public let authorityID: String
    public let outputRootURL: URL

    public init(
        stageRootURL: URL,
        classificationLedgerURL: URL,
        sourceArchiveRootURL: URL,
        archiveManifestURL: URL,
        sourceSQLiteURL: URL,
        expectedClassificationDigest: String,
        expectedSourceSQLiteDigest: String,
        expectedArchiveManifestDigest: String,
        expectedWorkCount: Int,
        authorityID: String,
        outputRootURL: URL
    ) {
        self.stageRootURL = stageRootURL
        self.classificationLedgerURL = classificationLedgerURL
        self.sourceArchiveRootURL = sourceArchiveRootURL
        self.archiveManifestURL = archiveManifestURL
        self.sourceSQLiteURL = sourceSQLiteURL
        self.expectedClassificationDigest = expectedClassificationDigest
        self.expectedSourceSQLiteDigest = expectedSourceSQLiteDigest
        self.expectedArchiveManifestDigest = expectedArchiveManifestDigest
        self.expectedWorkCount = expectedWorkCount
        self.authorityID = authorityID
        self.outputRootURL = outputRootURL
    }
}

public struct TrustedProvenanceBuilderResult: Sendable {
    public let authorityURL: URL
    public let authorityID: String
    public let authorityDigest: String

    public init(authorityURL: URL, authorityID: String, authorityDigest: String) {
        self.authorityURL = authorityURL
        self.authorityID = authorityID
        self.authorityDigest = authorityDigest
    }
}

public struct TrustedProvenanceBuilder: Sendable {
    private let beforeOutputHook: (@Sendable () async throws -> Void)?
    private let beforeOutputRenameHook: (@Sendable (URL) throws -> Void)?

    public init() {
        beforeOutputHook = nil
        beforeOutputRenameHook = nil
    }

    init(
        beforeOutputHook: (@Sendable () async throws -> Void)?,
        beforeOutputRenameHook: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.beforeOutputHook = beforeOutputHook
        self.beforeOutputRenameHook = beforeOutputRenameHook
    }

    public func build(_ options: TrustedProvenanceBuilderOptions) async throws -> TrustedProvenanceBuilderResult {
        try validateArguments(options)
        let expected = try validateInputs(options)
        let classifications = try loadClassifications(options.classificationLedgerURL)
        let stage = try loadStageReport(options.stageRootURL)
        let sourceEvidence = try LegacyV1Exporter().readSourceSQLiteEvidence(at: options.sourceSQLiteURL)
        let report = stage.report
        guard report.sourceWorkCount == options.expectedWorkCount,
              report.sourceSQLiteSHA256 == expected.sourceSQLiteDigest,
              report.sourceArchiveManifestSHA256 == expected.archiveManifestDigest,
              report.classificationLedgerSHA256 == expected.classificationDigest,
              stage.run.sourceDigest == expected.sourceSQLiteDigest,
              stage.run.archiveManifestDigest == expected.archiveManifestDigest,
              stage.run.classificationLedgerDigest == expected.classificationDigest,
              report.entries.count == options.expectedWorkCount,
              classifications.count == options.expectedWorkCount,
              Set(report.entries.map(\.workID)) == Set(classifications.keys),
              sourceEvidence.objectVerificationIssues.isEmpty,
              sourceEvidence.sourceRowIssues.isEmpty,
              sourceEvidence.rows.count == options.expectedWorkCount,
              Set(sourceEvidence.rows.map(\.workID)) == Set(classifications.keys) else {
            throw TrustedProvenanceBuilderError.invalidStage("workCountOrIdentity")
        }

        let sourceRows = Dictionary(uniqueKeysWithValues: sourceEvidence.rows.map { ($0.workID, $0) })

        var authorityEntries: [MigrationTrustedProvenanceEntry] = []
        for reportEntry in report.entries.sorted(by: { $0.workID.uuidString < $1.workID.uuidString }) {
            guard let classification = classifications[reportEntry.workID],
                  let sourceRow = sourceRows[reportEntry.workID],
                  reportEntry.outcome == "exported",
                  let relativePath = reportEntry.outputRelativePath,
                  let sourceWireSnapshotID = reportEntry.sourceWireSnapshotID,
                  let sourceWireSnapshotDigest = reportEntry.sourceWireSnapshotDigest,
                  let sourceProjectionDigest = reportEntry.sourceProjectionDigest,
                  let sourceProjectionVersion = reportEntry.sourceProjectionVersion,
                  let adoptionSnapshotID = reportEntry.adoptionSnapshotID,
                  let adoptionProjectionDigest = reportEntry.adoptionProjectionDigest,
                  let adoptionProjectionVersion = reportEntry.adoptionProjectionVersion,
                  let inventoryEvidenceSHA256 = reportEntry.inventoryEvidenceSHA256,
                  let sourceObjectClosureSHA256 = reportEntry.sourceObjectClosureSHA256,
                  let classificationCreatedAt = reportEntry.classificationCreatedAt,
                  let classificationLocalGeneration = reportEntry.classificationLocalGeneration,
                  let classificationHeadSnapshotID = reportEntry.classificationHeadSnapshotID,
                  let classificationHeadGeneration = reportEntry.classificationHeadGeneration,
                  let classificationEvidence = reportEntry.classificationEvidence else {
                throw TrustedProvenanceBuilderError.invalidStage("entry:\(reportEntry.workID.uuidString)")
            }
            let literalDisposition = classification.disposition
            let expectedDirectory = normalizedDirectory(for: literalDisposition)
            guard reportEntry.disposition == expectedDirectory,
                  relativePath == "\(expectedDirectory)/\(reportEntry.workID.uuidString).novelpkg" else {
                throw TrustedProvenanceBuilderError.invalidClassification("\(reportEntry.workID.uuidString):\(literalDisposition):\(reportEntry.disposition):\(relativePath)")
            }
            let package = options.stageRootURL.appendingPathComponent(relativePath, isDirectory: true)
            try requireReadOnlyTree(package, label: "stagePackage")
            let proposedWorkID = try WorkID(uuidString: reportEntry.workID.uuidString.lowercased())
            let archive = try await ArchiveReader().inventoryAsync(
                sourceURL: package,
                proposedWorkID: proposedWorkID
            )
            let expectedProjection = try projectionDigestFor(archive)
            let expectedAdoptionSnapshotID = archive.encoded.snapshotId.description
            let expectedEvidence = try migrationInventoryEvidenceDigest(archive.inventory)
            let stateURL = options.stageRootURL.appendingPathComponent(".state/\(reportEntry.workID.uuidString).json")
            let state = try JSONDecoder().decode(StageProjectionState.self, from: Data(contentsOf: stateURL))
            let evidencePrefix = "packageEvidence:\(reportEntry.workID.uuidString)"
            guard archive.inventory.workID == reportEntry.workID.uuidString.lowercased() else {
                throw TrustedProvenanceBuilderError.invalidStage("\(evidencePrefix):workID")
            }
            guard sourceWireSnapshotID == sourceRow.sourceWireSnapshotID,
                  sourceWireSnapshotDigest == sourceRow.sourceWireSnapshotDigest,
                  sourceProjectionDigest == sourceRow.sourceProjectionDigest,
                  sourceProjectionVersion == sourceRow.sourceProjectionVersion,
                  sourceObjectClosureSHA256 == sourceRow.objectClosureDigest else {
                throw TrustedProvenanceBuilderError.invalidStage("\(evidencePrefix):sourceRow")
            }
            guard sourceRow.documentID == archive.model.document.id,
                  sourceRow.sourceWireSnapshotDigest == sourceRow.sourceWireSnapshotID,
                  classification.snapshotID == sourceWireSnapshotID,
                  classificationCreatedAt == classification.createdAt,
                  classificationLocalGeneration == classification.currentSnapshotLocalGeneration,
                  classificationHeadSnapshotID == classification.headSnapshotID,
                  classificationHeadGeneration == classification.headGeneration,
                  classificationEvidence == classification.evidence,
                  classification.createdAt == sourceRow.sourceCreatedAt,
                  classification.currentSnapshotLocalGeneration == sourceRow.sourceLocalGeneration,
                  classification.headSnapshotID == sourceRow.sourceHeadSnapshotID,
                  classification.headGeneration == sourceRow.sourceHeadGeneration else {
                throw TrustedProvenanceBuilderError.invalidStage("\(evidencePrefix):sourceProjection")
            }
            guard reportEntry.provenanceVersion == LegacyV1ProvenanceContract.formatVersion,
                  sourceProjectionVersion == LegacyV1ProvenanceContract.sourceProjectionVersion,
                  adoptionProjectionVersion == LegacyV1ProvenanceContract.adoptionProjectionVersion else {
                throw TrustedProvenanceBuilderError.invalidStage("\(evidencePrefix):evidenceVersion")
            }
            guard adoptionSnapshotID == expectedAdoptionSnapshotID else {
                throw TrustedProvenanceBuilderError.invalidStage("\(evidencePrefix):adoptionSnapshot")
            }
            guard adoptionProjectionDigest == expectedProjection,
                  adoptionProjectionVersion == LegacyV1ProvenanceContract.adoptionProjectionVersion,
                  reportEntry.snapshotID == sourceWireSnapshotID,
                  reportEntry.projectionDigest == adoptionProjectionDigest else {
                throw TrustedProvenanceBuilderError.invalidStage("\(evidencePrefix):projection")
            }
            guard inventoryEvidenceSHA256 == expectedEvidence else {
                throw TrustedProvenanceBuilderError.invalidStage("\(evidencePrefix):inventoryEvidence")
            }
            guard state.sourceDigest == expected.sourceSQLiteDigest,
                  state.provenanceVersion == LegacyV1ProvenanceContract.formatVersion,
                  state.sourceWireSnapshotID == sourceWireSnapshotID,
                  state.sourceWireSnapshotDigest == sourceWireSnapshotDigest,
                  state.sourceProjectionDigest == sourceProjectionDigest,
                  state.sourceProjectionVersion == sourceProjectionVersion,
                  state.adoptionSnapshotID == adoptionSnapshotID,
                  state.adoptionProjectionDigest == adoptionProjectionDigest,
                  state.adoptionProjectionVersion == adoptionProjectionVersion,
                  state.inventoryEvidenceSHA256 == inventoryEvidenceSHA256,
                  state.snapshotID == sourceWireSnapshotID,
                  state.projectionDigest == adoptionProjectionDigest,
                  state.classificationCreatedAt == classificationCreatedAt,
                  state.classificationLocalGeneration == classificationLocalGeneration,
                  state.classificationHeadSnapshotID == classificationHeadSnapshotID,
                  state.classificationHeadGeneration == classificationHeadGeneration,
                  state.classificationEvidence == classificationEvidence else {
                throw TrustedProvenanceBuilderError.invalidStage("\(evidencePrefix):state")
            }
            let inventoryEvidenceDigest = expectedEvidence
            authorityEntries.append(
                MigrationTrustedProvenanceEntry(
                    workID: reportEntry.workID,
                    disposition: literalDisposition,
                    packageSHA256: archive.inventory.sourceDigest,
                    sourceSQLiteSHA256: expected.sourceSQLiteDigest,
                    sourceArchiveManifestSHA256: expected.archiveManifestDigest,
                    classificationLedgerSHA256: expected.classificationDigest,
                    snapshotID: sourceWireSnapshotID,
                    projectionDigest: adoptionProjectionDigest,
                    inventoryEvidenceSHA256: inventoryEvidenceDigest,
                    provenanceVersion: LegacyV1ProvenanceContract.formatVersion,
                    sourceWireSnapshotID: sourceWireSnapshotID,
                    sourceWireSnapshotDigest: sourceWireSnapshotDigest,
                    sourceProjectionDigest: sourceProjectionDigest,
                    sourceProjectionVersion: sourceProjectionVersion,
                    adoptionSnapshotID: adoptionSnapshotID,
                    adoptionProjectionDigest: adoptionProjectionDigest,
                    adoptionProjectionVersion: adoptionProjectionVersion,
                    sourceObjectClosureSHA256: sourceObjectClosureSHA256,
                    classificationCreatedAt: classificationCreatedAt,
                    classificationLocalGeneration: classificationLocalGeneration,
                    classificationHeadSnapshotID: classificationHeadSnapshotID,
                    classificationHeadGeneration: classificationHeadGeneration,
                    classificationEvidence: classificationEvidence
                )
            )
        }

        let authority = MigrationTrustedProvenanceAuthority(
            authorityID: options.authorityID,
            sourceSQLiteSHA256: expected.sourceSQLiteDigest,
            sourceArchiveManifestSHA256: expected.archiveManifestDigest,
            classificationLedgerSHA256: expected.classificationDigest,
            entries: authorityEntries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(authority)
        let canonical = try canonicalJSON(data)
        guard data == canonical else {
            throw TrustedProvenanceBuilderError.outputWriteFailed("nonCanonicalAuthority")
        }
        try await beforeOutputHook?()
        let finalExpected = try validateInputs(options)
        guard finalExpected == expected else {
            throw TrustedProvenanceBuilderError.digestMismatch("inputChangedBeforeOutput")
        }
        try createAuthorityOutput(data: data, options: options)
        let authorityURL = options.outputRootURL.appendingPathComponent("provenance.json")
        return TrustedProvenanceBuilderResult(
            authorityURL: authorityURL,
            authorityID: options.authorityID,
            authorityDigest: SHA256Digest.hex(data)
        )
    }

    private struct ExpectedDigests: Equatable {
        let classificationDigest: String
        let sourceSQLiteDigest: String
        let archiveManifestDigest: String
        let stageTreeDigest: String
    }

    private struct StageReport: Decodable {
        let formatVersion: Int
        let provenanceVersion: Int
        let exportID: UUID
        let sourceSQLiteSHA256: String
        let sourceArchiveManifestSHA256: String
        let classificationLedgerSHA256: String
        let sourceWorkCount: Int
        let objectVerificationIssues: [String]
        let sourceRowIssues: [String]
        let entries: [StageEntry]
    }

    private struct StageEntry: Decodable {
        let workID: UUID
        let disposition: String
        let snapshotID: String?
        let outputRelativePath: String?
        let outcome: String
        let projectionDigest: String?
        let provenanceVersion: Int
        let sourceWireSnapshotID: String?
        let sourceWireSnapshotDigest: String?
        let sourceProjectionDigest: String?
        let sourceProjectionVersion: Int?
        let adoptionSnapshotID: String?
        let adoptionProjectionDigest: String?
        let adoptionProjectionVersion: Int?
        let inventoryEvidenceSHA256: String?
        let sourceObjectClosureSHA256: String?
        let classificationCreatedAt: String?
        let classificationLocalGeneration: Int?
        let classificationHeadSnapshotID: String?
        let classificationHeadGeneration: Int?
        let classificationEvidence: String?
    }

    private struct StageRun: Decodable {
        let exportID: UUID
        let sourceDigest: String
        let archiveManifestDigest: String
        let classificationLedgerDigest: String
        let status: String
    }

    private struct StageProjectionState: Decodable {
        let sourceDigest: String
        let snapshotID: String
        let projectionDigest: String
        let provenanceVersion: Int
        let sourceWireSnapshotID: String
        let sourceWireSnapshotDigest: String
        let sourceProjectionDigest: String
        let sourceProjectionVersion: Int
        let adoptionSnapshotID: String
        let adoptionProjectionDigest: String
        let adoptionProjectionVersion: Int
        let inventoryEvidenceSHA256: String
        let classificationCreatedAt: String
        let classificationLocalGeneration: Int
        let classificationHeadSnapshotID: String
        let classificationHeadGeneration: Int
        let classificationEvidence: String
    }

    private struct ClassificationRecord {
        let disposition: String
        let snapshotID: String
        let createdAt: String
        let currentSnapshotLocalGeneration: Int
        let headSnapshotID: String
        let headGeneration: Int
        let evidence: String
    }

    private func validateArguments(_ options: TrustedProvenanceBuilderOptions) throws {
        guard options.expectedWorkCount > 0, !options.authorityID.isEmpty else {
            throw TrustedProvenanceBuilderError.invalidArgument("workCountOrAuthorityID")
        }
        for digest in [options.expectedClassificationDigest, options.expectedSourceSQLiteDigest, options.expectedArchiveManifestDigest] {
            guard isDigest(digest) else { throw TrustedProvenanceBuilderError.invalidArgument("digest") }
        }
    }

    private func validateInputs(_ options: TrustedProvenanceBuilderOptions) throws -> ExpectedDigests {
        let stagePath = try requireReadOnlyDirectory(options.stageRootURL, label: "stageRoot")
        try requireReadOnlyTree(options.stageRootURL, label: "stageRoot")
        let archivePath = try requireReadOnlyDirectory(options.sourceArchiveRootURL, label: "archiveRoot")
        try requireReadOnlyTree(options.sourceArchiveRootURL, label: "archiveRoot")
        let classificationPath = try requireReadOnlyFile(options.classificationLedgerURL, label: "classification")
        let manifestPath = try requireReadOnlyFile(options.archiveManifestURL, label: "archiveManifest")
        let sqlitePath = try requireReadOnlyFile(options.sourceSQLiteURL, label: "sourceSQLite")
        guard manifestPath == archivePath + "/" + options.archiveManifestURL.lastPathComponent,
              sqlitePath.hasPrefix(archivePath + "/") else {
            throw TrustedProvenanceBuilderError.unsafeInput("archiveContainment")
        }
        let sourceSQLiteRelativePath = String(sqlitePath.dropFirst(archivePath.count + 1))
        try validateArchiveManifest(
            rootPath: archivePath,
            manifestPath: manifestPath,
            sourceSQLiteRelativePath: sourceSQLiteRelativePath,
            sourceSQLiteDigest: options.expectedSourceSQLiteDigest
        )
        let classificationDigest = try SHA256Digest.hex(Data(contentsOf: URL(fileURLWithPath: classificationPath)))
        let sourceSQLiteDigest = try SHA256Digest.hex(Data(contentsOf: URL(fileURLWithPath: sqlitePath)))
        let archiveManifestDigest = try SHA256Digest.hex(Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        guard classificationDigest == options.expectedClassificationDigest else {
            throw TrustedProvenanceBuilderError.digestMismatch("classification")
        }
        guard sourceSQLiteDigest == options.expectedSourceSQLiteDigest else {
            throw TrustedProvenanceBuilderError.digestMismatch("sourceSQLite")
        }
        guard archiveManifestDigest == options.expectedArchiveManifestDigest else {
            throw TrustedProvenanceBuilderError.digestMismatch("archiveManifest")
        }
        guard !pathsOverlap(stagePath, archivePath),
              !pathsOverlap(stagePath, classificationPath),
              !pathsOverlap(stagePath, manifestPath),
              !pathsOverlap(stagePath, sqlitePath),
              !pathsOverlap(archivePath, classificationPath),
              !pathsOverlap(classificationPath, manifestPath),
              !pathsOverlap(classificationPath, sqlitePath),
              !pathsOverlap(manifestPath, sqlitePath) else {
            throw TrustedProvenanceBuilderError.unsafeInput("inputOverlap")
        }
        let stageTreeDigest = try digestTree(options.stageRootURL)
        let outputStandardized = options.outputRootURL.standardizedFileURL
        let outputResolved = options.outputRootURL.resolvingSymlinksInPath().standardizedFileURL
        guard outputStandardized.path == outputResolved.path else {
            throw TrustedProvenanceBuilderError.unsafeInput("outputSymlink")
        }
        let outputPath = outputResolved.path
        guard !FileManager.default.fileExists(atPath: outputPath) else {
            throw TrustedProvenanceBuilderError.outputAlreadyExists
        }
        guard !pathsOverlap(outputPath, stagePath),
              !pathsOverlap(outputPath, archivePath),
              !pathsOverlap(outputPath, classificationPath),
              !pathsOverlap(outputPath, manifestPath),
              !pathsOverlap(outputPath, sqlitePath) else {
            throw TrustedProvenanceBuilderError.outputOverlapsInput
        }
        _ = stagePath
        return ExpectedDigests(
            classificationDigest: classificationDigest,
            sourceSQLiteDigest: sourceSQLiteDigest,
            archiveManifestDigest: archiveManifestDigest,
            stageTreeDigest: stageTreeDigest
        )
    }

    private func loadStageReport(_ root: URL) throws -> (report: StageReport, run: StageRun) {
        let marker = root.appendingPathComponent("COMMITTED")
        guard try String(contentsOf: marker, encoding: .utf8) == "COMMITTED\n" else {
            throw TrustedProvenanceBuilderError.invalidStage("committedMarker")
        }
        let report = try JSONDecoder().decode(StageReport.self, from: Data(contentsOf: root.appendingPathComponent("migration-ledger.json")))
        let run = try JSONDecoder().decode(StageRun.self, from: Data(contentsOf: root.appendingPathComponent("migration-run.json")))
        guard report.formatVersion == LegacyV1ProvenanceContract.formatVersion,
              report.provenanceVersion == LegacyV1ProvenanceContract.formatVersion,
              report.exportID == run.exportID,
              run.status == "committed",
              report.objectVerificationIssues.isEmpty,
              report.sourceRowIssues.isEmpty else {
            throw TrustedProvenanceBuilderError.invalidStage("runState")
        }
        return (report, run)
    }

    private func loadClassifications(_ url: URL) throws -> [UUID: ClassificationRecord] {
        var records: [UUID: ClassificationRecord] = [:]
        let text = try String(contentsOf: url, encoding: .utf8)
        let header = [
            "workID", "classification", "currentSnapshotID", "currentSnapshotCreatedAt",
            "currentSnapshotLocalGeneration", "acknowledgedHeadSnapshotID",
            "acknowledgedHeadGeneration", "evidence"
        ]
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine
            if line.last == "\r" {
                line.removeLast()
            }
            guard !line.isEmpty else { continue }
            let fields = try parseCSV(line)
            if fields == header {
                continue
            }
            guard fields.count == 8 else {
                throw TrustedProvenanceBuilderError.invalidClassification("\(fields.first ?? "empty"):columns=\(fields.count)")
            }
            guard let workID = UUID(uuidString: fields[0]), !fields[1].isEmpty,
                  fields.dropFirst().allSatisfy({ !$0.isEmpty }) else {
                throw TrustedProvenanceBuilderError.invalidClassification("\(fields.first ?? "empty"):fields=\(fields)")
            }
            guard records[workID] == nil else {
                throw TrustedProvenanceBuilderError.invalidClassification("duplicate:\(fields[0])")
            }
            guard ["verified", "verified_candidate", "quarantine", "legacy_quarantine_test_batch", "needs-review", "needs_review", "legacy_quarantine_ambiguous_user_touched"].contains(fields[1]) else {
                throw TrustedProvenanceBuilderError.invalidClassification(fields[1])
            }
            guard isDigest(fields[2]),
                  fields[5] == fields[2],
                  ISO8601DateFormatter().date(from: fields[3]) != nil,
                  let localGeneration = Int(fields[4]),
                  let headGeneration = Int(fields[6]) else {
                throw TrustedProvenanceBuilderError.invalidClassification("\(fields[0]):evidence")
            }
            records[workID] = ClassificationRecord(
                disposition: fields[1],
                snapshotID: fields[2],
                createdAt: fields[3],
                currentSnapshotLocalGeneration: localGeneration,
                headSnapshotID: fields[5],
                headGeneration: headGeneration,
                evidence: fields[7]
            )
        }
        return records
    }

    private func normalizedDirectory(for literal: String) -> String {
        switch literal {
        case "verified", "verified_candidate":
            "verified"
        case "quarantine", "legacy_quarantine_test_batch":
            "quarantine"
        default:
            "needs-review"
        }
    }

    private func projectionDigestFor(_ archive: ArchiveReadResult) throws -> String {
        let snapshot = try WorkCanonicalJSON.encodeSnapshot(WorkSnapshot(document: archive.model.document))
        return SHA256Digest.hex(snapshot)
    }

    private func createAuthorityOutput(data: Data, options: TrustedProvenanceBuilderOptions) throws {
        let fileManager = FileManager.default
        let finalRoot = options.outputRootURL.standardizedFileURL
        let parent = finalRoot.deletingLastPathComponent()
        try requireReadOnlyAncestors(parent, label: "outputParent", allowWritableFinal: true)
        let temporaryRoot = parent.appendingPathComponent(
            ".\(finalRoot.lastPathComponent).authority-\(UUID().uuidString).tmp",
            isDirectory: true
        )
        let temporary = temporaryRoot.appendingPathComponent("provenance.json")
        guard !fileManager.fileExists(atPath: finalRoot.path),
              !fileManager.fileExists(atPath: temporaryRoot.path) else {
            throw TrustedProvenanceBuilderError.outputAlreadyExists
        }
        var ownsTemporaryRoot = false
        do {
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
            ownsTemporaryRoot = true
            try data.write(to: temporary, options: [.withoutOverwriting])
            let readBack = try Data(contentsOf: temporary, options: [.mappedIfSafe])
            guard readBack == data,
                  SHA256Digest.hex(readBack) == SHA256Digest.hex(data),
                  try canonicalJSON(readBack) == readBack else {
                throw TrustedProvenanceBuilderError.outputWriteFailed("authorityReadBack")
            }
            try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: temporary.path)
            try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: temporaryRoot.path)
            let outputValues = try temporary.resourceValues(forKeys: [.isRegularFileKey, .isWritableKey, .isSymbolicLinkKey])
            let rootValues = try temporaryRoot.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey, .isSymbolicLinkKey])
            guard outputValues.isRegularFile == true, outputValues.isWritable != true,
                  outputValues.isSymbolicLink != true,
                  rootValues.isDirectory == true, rootValues.isWritable != true,
                  rootValues.isSymbolicLink != true else {
                throw TrustedProvenanceBuilderError.outputWriteFailed("authoritySeal")
            }
            try beforeOutputRenameHook?(finalRoot)
            guard !fileManager.fileExists(atPath: finalRoot.path) else {
                throw TrustedProvenanceBuilderError.outputAlreadyExists
            }
            // The temporary root is a sibling on the same filesystem.  A
            // single rename publishes the already rehashed and sealed tree;
            // the final path is never a partially-created authority.
            try fileManager.moveItem(at: temporaryRoot, to: finalRoot)
            ownsTemporaryRoot = false
        } catch {
            if ownsTemporaryRoot {
                cleanupOwnedTemporaryRoot(temporaryRoot)
            }
            if let error = error as? TrustedProvenanceBuilderError {
                throw error
            }
            throw TrustedProvenanceBuilderError.outputWriteFailed(String(describing: error))
        }
    }

    private func cleanupOwnedTemporaryRoot(_ root: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return }
        let urls = [root] + (fileManager.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
        for url in urls.reversed() {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try? fileManager.removeItem(at: root)
    }

    private func requireReadOnlyTree(_ url: URL, label: String) throws {
        _ = try requireReadOnlyDirectory(url, label: label)
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isWritableKey])
        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isWritableKey])
            guard values.isSymbolicLink != true, values.isWritable != true,
                  values.isDirectory == true || values.isRegularFile == true else {
                throw TrustedProvenanceBuilderError.unsafeInput("\(label):\(item.path)")
            }
        }
    }

    private func requireReadOnlyDirectory(_ url: URL, label: String) throws -> String {
        try requireReadOnlyAncestors(url, label: label, allowWritableFinal: false)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isWritableKey])
        guard values.isDirectory == true, values.isSymbolicLink != true, values.isWritable != true else {
            throw TrustedProvenanceBuilderError.unsafeInput(label)
        }
        return resolved.path
    }

    private func requireReadOnlyFile(_ url: URL, label: String) throws -> String {
        try requireReadOnlyAncestors(url, label: label, allowWritableFinal: false)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isWritableKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.isWritable != true else {
            throw TrustedProvenanceBuilderError.unsafeInput(label)
        }
        return resolved.path
    }

    private func requireReadOnlyAncestors(_ url: URL, label: String, allowWritableFinal: Bool) throws {
        let standardized = url.standardizedFileURL
        guard standardized.path == standardized.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw TrustedProvenanceBuilderError.unsafeInput("\(label):symlink")
        }
        let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isWritableKey])
        let systemAlias = standardized.path == "/tmp" || standardized.path == "/var"
        guard values.isDirectory == true || values.isRegularFile == true || systemAlias,
              values.isSymbolicLink != true || systemAlias,
              allowWritableFinal || values.isWritable != true else {
            throw TrustedProvenanceBuilderError.unsafeInput(label)
        }
        // System temporary roots such as /var -> /private/var are legitimate
        // mount aliases.  The input itself was already required to be the
        // exact realpath above; ancestor aliases must not be mistaken for a
        // symlink inside the trusted input tree.
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrustedProvenanceBuilderError.outputWriteFailed("authorityJSON")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func validateArchiveManifest(
        rootPath: String,
        manifestPath: String,
        sourceSQLiteRelativePath: String,
        sourceSQLiteDigest: String
    ) throws {
        let text = try String(contentsOf: URL(fileURLWithPath: manifestPath), encoding: .utf8)
        var entries: [String: String] = [:]
        var portableKeys: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2 else { throw TrustedProvenanceBuilderError.unsafeInput("archiveManifestLine") }
            let digest = String(fields[0])
            guard isDigest(digest) else { throw TrustedProvenanceBuilderError.digestMismatch("archiveManifestEntry") }
            var path = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("./") {
                path.removeFirst(2)
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  entries.updateValue(digest, forKey: path) == nil else {
                throw TrustedProvenanceBuilderError.unsafeInput("archiveManifestPath")
            }
            let portableKey = portablePathKey(path)
            guard portableKeys.updateValue(path, forKey: portableKey) == nil else {
                throw TrustedProvenanceBuilderError.unsafeInput("archiveManifestPathCollision:\(path)")
            }
        }
        guard !entries.isEmpty else { throw TrustedProvenanceBuilderError.unsafeInput("archiveManifestEmpty") }
        let sourceSQLiteKey = portablePathKey(sourceSQLiteRelativePath)
        let sourceSQLiteMatches = entries.keys.filter { portablePathKey($0) == sourceSQLiteKey }
        guard sourceSQLiteMatches.count == 1,
              sourceSQLiteMatches[0] == sourceSQLiteRelativePath,
              entries[sourceSQLiteRelativePath] == sourceSQLiteDigest else {
            throw TrustedProvenanceBuilderError.digestMismatch("archiveManifestSourceSQLite")
        }
        let rootURL = URL(fileURLWithPath: rootPath)
        var filesystemIdentities: [String: String] = [:]
        var expectedPaths: Set<String> = []
        let manifestRelative = String(manifestPath.dropFirst(rootPath.count + 1))
        guard manifestPath.hasPrefix(rootPath + "/"),
              manifestRelative == URL(fileURLWithPath: manifestPath).lastPathComponent else {
            throw TrustedProvenanceBuilderError.unsafeInput("archiveManifestContainment")
        }
        for (path, expectedDigest) in entries {
            let candidate = URL(fileURLWithPath: rootPath).appendingPathComponent(path)
            let candidatePath = try requireReadOnlyFile(candidate, label: "archiveEntry")
            let realPath = URL(fileURLWithPath: candidatePath).resolvingSymlinksInPath().standardizedFileURL.path
            guard candidate.standardizedFileURL.path == realPath,
                  realPath == rootURL.appendingPathComponent(path).standardizedFileURL.path else {
                throw TrustedProvenanceBuilderError.unsafeInput("archiveEntrySymlink:\(path)")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: realPath)
            guard let device = (attributes[.systemNumber] as? NSNumber)?.int64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value else {
                throw TrustedProvenanceBuilderError.unsafeInput("archiveEntryIdentity:\(path)")
            }
            let identity = "\(device):\(inode)"
            guard filesystemIdentities.updateValue(path, forKey: identity) == nil else {
                throw TrustedProvenanceBuilderError.unsafeInput("archiveEntryAlias:\(path)")
            }
            expectedPaths.insert(realPath)
            let bytes = try Data(contentsOf: URL(fileURLWithPath: realPath))
            guard SHA256Digest.hex(bytes) == expectedDigest else {
                throw TrustedProvenanceBuilderError.digestMismatch("archiveEntry:\(path)")
            }
        }
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isWritableKey]
        )
        while let item = enumerator?.nextObject() as? URL {
            let itemPath = item.resolvingSymlinksInPath().standardizedFileURL.path
            let relative = String(itemPath.dropFirst(rootPath.count + 1))
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isWritableKey])
            guard values.isSymbolicLink != true, values.isWritable != true else {
                throw TrustedProvenanceBuilderError.unsafeInput("archiveEntry:\(relative)")
            }
            if values.isDirectory == true {
                continue
            }
            if itemPath == manifestPath || expectedPaths.contains(itemPath) {
                continue
            }
            guard values.isRegularFile == true, entries[relative] != nil else {
                throw TrustedProvenanceBuilderError.unsafeInput("archiveUnlisted:\(relative)")
            }
        }
    }

    private func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private func portablePathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    private func digestTree(_ root: URL) throws -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: rootPath),
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isWritableKey]
        )
        var items: [(path: String, data: Data, isDirectory: Bool)] = []
        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isWritableKey])
            guard values.isSymbolicLink != true, values.isWritable != true,
                  values.isDirectory == true || values.isRegularFile == true else {
                throw TrustedProvenanceBuilderError.unsafeInput("stageTree:\(item.path)")
            }
            let relative = item.resolvingSymlinksInPath().standardizedFileURL.path
                .replacingOccurrences(of: rootPath + "/", with: "")
            let data = values.isDirectory == true ? Data() : try Data(contentsOf: item, options: [.mappedIfSafe])
            items.append((relative, data, values.isDirectory == true))
        }
        var bytes = Data()
        for item in items.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            let path = Data(item.path.utf8)
            bytes.append(item.isDirectory ? 0x44 : 0x46)
            var pathCount = UInt64(path.count).bigEndian
            var dataCount = UInt64(item.data.count).bigEndian
            withUnsafeBytes(of: &pathCount) { bytes.append(contentsOf: $0) }
            bytes.append(path)
            withUnsafeBytes(of: &dataCount) { bytes.append(contentsOf: $0) }
            bytes.append(item.data)
        }
        return SHA256Digest.hex(bytes)
    }

    private func parseCSV(_ line: String) throws -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                if quoted, line.index(after: index) < line.endIndex, line[line.index(after: index)] == "\"" {
                    field.append("\"")
                    index = line.index(after: index)
                } else {
                    quoted.toggle()
                }
            } else if character == ",", !quoted {
                fields.append(field)
                field = ""
            } else {
                field.append(character)
            }
            index = line.index(after: index)
        }
        guard !quoted else { throw TrustedProvenanceBuilderError.invalidClassification("unclosedQuote") }
        fields.append(field)
        return fields
    }
}
