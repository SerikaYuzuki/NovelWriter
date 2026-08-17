import Foundation
import NovelSync
import NovelSyncV2

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

    public init() {
        beforeOutputHook = nil
    }

    init(beforeOutputHook: (@Sendable () async throws -> Void)?) {
        self.beforeOutputHook = beforeOutputHook
    }

    public func build(_ options: TrustedProvenanceBuilderOptions) async throws -> TrustedProvenanceBuilderResult {
        try validateArguments(options)
        let expected = try validateInputs(options)
        let classifications = try loadClassifications(options.classificationLedgerURL)
        let stage = try loadStageReport(options.stageRootURL)
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
              Set(report.entries.map(\.workID)) == Set(classifications.keys) else {
            throw TrustedProvenanceBuilderError.invalidStage("workCountOrIdentity")
        }

        var authorityEntries: [MigrationTrustedProvenanceEntry] = []
        for reportEntry in report.entries.sorted(by: { $0.workID.uuidString < $1.workID.uuidString }) {
            guard let classification = classifications[reportEntry.workID],
                  reportEntry.outcome == "exported",
                  let relativePath = reportEntry.outputRelativePath,
                  let snapshotID = reportEntry.snapshotID,
                  let projectionDigest = reportEntry.projectionDigest else {
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
            let stateURL = options.stageRootURL.appendingPathComponent(".state/\(reportEntry.workID.uuidString).json")
            let state = try JSONDecoder().decode(StageProjectionState.self, from: Data(contentsOf: stateURL))
            guard archive.inventory.workID == reportEntry.workID.uuidString.lowercased(),
                  snapshotID == archive.encoded.snapshotId.description,
                  projectionDigest == expectedProjection,
                  reportEntry.projectionDigest == projectionDigest,
                  classification.snapshotID == snapshotID,
                  state.sourceDigest == expected.sourceSQLiteDigest,
                  state.snapshotID == snapshotID,
                  state.projectionDigest == projectionDigest else {
                throw TrustedProvenanceBuilderError.invalidStage("packageEvidence:\(reportEntry.workID.uuidString)")
            }
            let inventoryEvidenceDigest = try migrationInventoryEvidenceDigest(archive.inventory)
            authorityEntries.append(
                MigrationTrustedProvenanceEntry(
                    workID: reportEntry.workID,
                    disposition: literalDisposition,
                    packageSHA256: archive.inventory.sourceDigest,
                    sourceSQLiteSHA256: expected.sourceSQLiteDigest,
                    sourceArchiveManifestSHA256: expected.archiveManifestDigest,
                    classificationLedgerSHA256: expected.classificationDigest,
                    snapshotID: snapshotID,
                    projectionDigest: projectionDigest,
                    inventoryEvidenceSHA256: inventoryEvidenceDigest
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
    }

    private struct StageReport: Decodable {
        let formatVersion: Int
        let exportID: UUID
        let sourceSQLiteSHA256: String
        let sourceArchiveManifestSHA256: String
        let classificationLedgerSHA256: String
        let sourceWorkCount: Int
        let entries: [StageEntry]
    }

    private struct StageEntry: Decodable {
        let workID: UUID
        let disposition: String
        let snapshotID: String?
        let outputRelativePath: String?
        let outcome: String
        let projectionDigest: String?
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
    }

    private struct ClassificationRecord {
        let disposition: String
        let snapshotID: String
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
        try validateArchiveManifest(rootPath: archivePath, manifestPath: manifestPath)
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
        let outputPath = options.outputRootURL.resolvingSymlinksInPath().standardizedFileURL.path
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
            archiveManifestDigest: archiveManifestDigest
        )
    }

    private func loadStageReport(_ root: URL) throws -> (report: StageReport, run: StageRun) {
        let marker = root.appendingPathComponent("COMMITTED")
        guard try String(contentsOf: marker, encoding: .utf8) == "COMMITTED\n" else {
            throw TrustedProvenanceBuilderError.invalidStage("committedMarker")
        }
        let report = try JSONDecoder().decode(StageReport.self, from: Data(contentsOf: root.appendingPathComponent("migration-ledger.json")))
        let run = try JSONDecoder().decode(StageRun.self, from: Data(contentsOf: root.appendingPathComponent("migration-run.json")))
        guard report.formatVersion == 1,
              report.exportID == run.exportID,
              run.status == "committed" else {
            throw TrustedProvenanceBuilderError.invalidStage("runState")
        }
        return (report, run)
    }

    private func loadClassifications(_ url: URL) throws -> [UUID: ClassificationRecord] {
        var records: [UUID: ClassificationRecord] = [:]
        let text = try String(contentsOf: url, encoding: .utf8)
        for rawLine in text.components(separatedBy: .newlines) where !rawLine.isEmpty {
            let fields = try parseCSV(rawLine)
            if fields == ["workID", "classification", "currentSnapshotID", "currentSnapshotCreatedAt", "currentSnapshotLocalGeneration", "acknowledgedHeadSnapshotID", "acknowledgedHeadGeneration", "evidence"] {
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
            records[workID] = ClassificationRecord(disposition: fields[1], snapshotID: fields[2])
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
        let parent = options.outputRootURL.deletingLastPathComponent()
        try requireReadOnlyAncestors(parent, label: "outputParent", allowWritableFinal: true)
        let output = options.outputRootURL.appendingPathComponent("provenance.json")
        let temporary = options.outputRootURL.appendingPathComponent(".provenance.\(UUID().uuidString).tmp")
        do {
            try fileManager.createDirectory(at: options.outputRootURL, withIntermediateDirectories: false)
            try data.write(to: temporary, options: [.atomic])
            guard !fileManager.fileExists(atPath: output.path) else {
                throw TrustedProvenanceBuilderError.outputAlreadyExists
            }
            try fileManager.moveItem(at: temporary, to: output)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw TrustedProvenanceBuilderError.outputWriteFailed(String(describing: error))
        }
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
        guard values.isDirectory == true || values.isRegularFile == true, values.isSymbolicLink != true,
              allowWritableFinal || values.isWritable != true else {
            throw TrustedProvenanceBuilderError.unsafeInput(label)
        }
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrustedProvenanceBuilderError.outputWriteFailed("authorityJSON")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func validateArchiveManifest(rootPath: String, manifestPath: String) throws {
        let text = try String(contentsOf: URL(fileURLWithPath: manifestPath), encoding: .utf8)
        var entries: [String: String] = [:]
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
        }
        guard !entries.isEmpty else { throw TrustedProvenanceBuilderError.unsafeInput("archiveManifestEmpty") }
        let rootURL = URL(fileURLWithPath: rootPath)
        let expectedPaths = Set(entries.keys.map { rootURL.appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL.path })
        let manifestRelative = String(manifestPath.dropFirst(rootPath.count + 1))
        guard manifestRelative == URL(fileURLWithPath: manifestPath).lastPathComponent else {
            throw TrustedProvenanceBuilderError.unsafeInput("archiveManifestContainment")
        }
        for (path, expectedDigest) in entries {
            let candidate = URL(fileURLWithPath: rootPath).appendingPathComponent(path)
            let candidatePath = try requireReadOnlyFile(candidate, label: "archiveEntry")
            let bytes = try Data(contentsOf: URL(fileURLWithPath: candidatePath))
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

    private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
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
