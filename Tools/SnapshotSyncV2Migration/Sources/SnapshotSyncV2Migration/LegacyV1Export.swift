import CryptoKit
import Foundation
import NovelCore
import NovelStorage
import NovelSync
import SQLite3

/// 旧v1 SQLiteを読み取り、v2切替前の検証済みportable backupを作る移行専用API。
///
/// このモジュールは通常のアプリtargetから参照しない。入力DBは`SQLITE_OPEN_READONLY`
/// で開き、出力は指定されたstage rootだけへ書き込む。stage rootにあるpackageは
/// adoption markerを持たないため、途中終了してもlive libraryへ取り込まれない。
public struct LegacyV1ExportOptions: Sendable {
    public let sourceSQLiteURL: URL
    public let classificationLedgerURL: URL
    public let stageRootURL: URL
    public let sourceArchiveRootURL: URL
    public let archiveManifestURL: URL
    public let sourceIsVerifiedArchive: Bool
    public let expectedWorkCount: Int

    public init(
        sourceSQLiteURL: URL,
        classificationLedgerURL: URL,
        stageRootURL: URL,
        sourceArchiveRootURL: URL,
        archiveManifestURL: URL,
        sourceIsVerifiedArchive: Bool,
        expectedWorkCount: Int
    ) {
        self.sourceSQLiteURL = sourceSQLiteURL
        self.classificationLedgerURL = classificationLedgerURL
        self.stageRootURL = stageRootURL
        self.sourceArchiveRootURL = sourceArchiveRootURL
        self.archiveManifestURL = archiveManifestURL
        self.sourceIsVerifiedArchive = sourceIsVerifiedArchive
        self.expectedWorkCount = expectedWorkCount
    }
}

public enum LegacyV1Disposition: String, Codable, Sendable {
    case verified
    case quarantine
    case needsReview = "needs-review"
}

public struct LegacyV1ExportEntry: Codable, Equatable, Sendable {
    public let workID: UUID
    public let disposition: LegacyV1Disposition
    public let snapshotID: String?
    public let outputRelativePath: String?
    public let outcome: String
    public let note: String?
    public let projectionDigest: String?

    public init(
        workID: UUID,
        disposition: LegacyV1Disposition,
        snapshotID: String?,
        outputRelativePath: String?,
        outcome: String,
        note: String?,
        projectionDigest: String? = nil
    ) {
        self.workID = workID
        self.disposition = disposition
        self.snapshotID = snapshotID
        self.outputRelativePath = outputRelativePath
        self.outcome = outcome
        self.note = note
        self.projectionDigest = projectionDigest
    }
}

public struct LegacyV1ExportReport: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let exportID: UUID
    public let sourceSQLiteSHA256: String
    public let sourceArchiveManifestPath: String
    public let sourceArchiveManifestSHA256: String
    public let classificationLedgerSHA256: String
    public let sourceWorkCount: Int
    public let generatedAt: String
    public let attachmentsPolicy: String
    public let objectVerificationIssues: [String]
    public let sourceRowIssues: [String]
    public let entries: [LegacyV1ExportEntry]

    public init(
        exportID: UUID = UUID(),
        sourceSQLiteSHA256: String,
        sourceArchiveManifestPath: String,
        sourceArchiveManifestSHA256: String,
        classificationLedgerSHA256: String = "",
        sourceWorkCount: Int = 0,
        generatedAt: String,
        attachmentsPolicy: String,
        objectVerificationIssues: [String],
        sourceRowIssues: [String] = [],
        entries: [LegacyV1ExportEntry]
    ) {
        formatVersion = 1
        self.exportID = exportID
        self.sourceSQLiteSHA256 = sourceSQLiteSHA256
        self.sourceArchiveManifestPath = sourceArchiveManifestPath
        self.sourceArchiveManifestSHA256 = sourceArchiveManifestSHA256
        self.classificationLedgerSHA256 = classificationLedgerSHA256
        self.sourceWorkCount = sourceWorkCount
        self.generatedAt = generatedAt
        self.attachmentsPolicy = attachmentsPolicy
        self.objectVerificationIssues = objectVerificationIssues
        self.sourceRowIssues = sourceRowIssues
        self.entries = entries
    }
}

public enum LegacyV1ExportError: Error, Equatable, Sendable {
    case sourceNotFound(URL)
    case ledgerNotFound(URL)
    case sqliteOpenFailed(String)
    case sqliteQueryFailed(String)
    case sourceIsNotVerifiedArchive
    case unsafeArchivePath(URL)
    case sourceArchiveManifestMismatch(String)
    case sourceChanged
    case stageOverlapsSource
    case stageNotEmpty(URL)
    case sourceSidecarPresent(URL)
    case workCountMismatch(expected: Int, actual: Int)
    case malformedClassification(workID: String, value: String)
    case duplicateClassification(UUID)
    case missingClassification(UUID)
    case invalidManifest(workID: UUID, reason: String)
    case invalidObject(objectID: String, reason: String)
    case writeFailed(String)
}

public struct LegacyV1Exporter: Sendable {
    public init() {}

    func classificationCountForValidation(at url: URL) throws -> Int {
        try ClassificationLedger.load(from: url).count
    }

    /// 全workをWorkID順に処理し、classification ledgerの分類先へstageする。
    /// 同一入力を再実行した場合は、既存packageをlogical read-backして再利用する。
    public func export(options: LegacyV1ExportOptions) async throws -> LegacyV1ExportReport {
        let evidence = try validateInput(options)
        let fileManager = FileManager.default
        let classifications = try ClassificationLedger.load(from: options.classificationLedgerURL)
        let classificationDigest = try SHA256Hex.digest(fileAt: options.classificationLedgerURL)
        let sourceDigest = evidence.sourceDigest
        let database = try ReadOnlyV1Database(url: options.sourceSQLiteURL)
        defer { database.close() }
        let works = try database.works()
        guard options.expectedWorkCount > 0, works.count == options.expectedWorkCount else {
            throw LegacyV1ExportError.workCountMismatch(expected: options.expectedWorkCount, actual: works.count)
        }
        let sourceRowIssues = try database.malformedWorkRows()
        let workIDs = Set(works.map(\.workID))
        if let extra = classifications.keys.first(where: { !workIDs.contains($0) }) {
            throw LegacyV1ExportError.malformedClassification(
                workID: extra.uuidString,
                value: "classification ledger contains a work absent from source SQLite"
            )
        }
        for work in works {
            guard classifications[work.workID] != nil else {
                throw LegacyV1ExportError.missingClassification(work.workID)
            }
        }
        try database.verifySourceEvidence(works: works, classifications: classifications)
        if let existing = try await existingCommittedStage(
            options: options,
            evidence: evidence,
            classifications: classifications,
            classificationDigest: classificationDigest,
            workIDs: workIDs,
            database: database,
            works: works
        ) {
            return existing
        }
        let exportID = UUID()
        try prepareNewStage(at: options.stageRootURL)
        try writeRunState(
            exportID: exportID,
            sourceDigest: evidence.sourceDigest,
            archiveManifestDigest: evidence.archiveManifestDigest,
            classificationLedgerDigest: classificationDigest,
            status: "running",
            to: options.stageRootURL.appendingPathComponent("migration-run.json")
        )
        for disposition in LegacyV1Disposition.allCases {
            try fileManager.createDirectory(
                at: options.stageRootURL.appendingPathComponent(disposition.directoryName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let objectIssues = try database.verifyObjects()
        var entries: [LegacyV1ExportEntry] = []

        for work in works.sorted(by: { $0.workID.uuidString < $1.workID.uuidString }) {
            guard let classification = classifications[work.workID] else {
                throw LegacyV1ExportError.missingClassification(work.workID)
            }

            do {
                guard let snapshot = try database.snapshot(id: work.currentSnapshotID, workID: work.workID) else {
                    throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "current snapshot is missing")
                }
                let expected = SHA256Hex.digest(snapshot.manifest)
                guard expected == snapshot.snapshotID else {
                    throw LegacyV1ExportError.invalidManifest(
                        workID: work.workID,
                        reason: "snapshot digest \(expected) != \(snapshot.snapshotID)"
                    )
                }
                guard snapshot.manifestModel.workID.uuidString.caseInsensitiveCompare(work.workID.uuidString) == .orderedSame,
                      snapshot.manifestModel.entries.count(where: { $0.entityKey == "work/document" }) == 1 else {
                    throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "manifest work identity or document entry is invalid")
                }
                for entry in snapshot.manifestModel.entries {
                    guard let object = try database.object(id: entry.objectID) else {
                        throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "referenced object is missing: \(entry.objectID)")
                    }
                    guard object.byteCount == entry.byteCount,
                          SHA256Hex.digest(object.bytes) == entry.objectID else {
                        throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "referenced object is invalid: \(entry.objectID)")
                    }
                }
                guard let documentEntry = snapshot.manifestModel.entries.first(where: { $0.entityKey == "work/document" }),
                      ["application/json", "application/vnd.fuminiwa.entity+json;version=1"].contains(documentEntry.contentType),
                      let documentObject = try database.object(id: documentEntry.objectID) else {
                    throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "work/document object is missing")
                }
                let wireSnapshot: WorkSnapshot
                do {
                    wireSnapshot = try WorkCanonicalJSON.decodeSnapshot(documentObject.bytes)
                } catch {
                    throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "work/document decode failed: \(error)")
                }
                let document = try wireSnapshot.materializedDocument()
                guard document.id == work.documentID, wireSnapshot.documentID.rawValue == work.documentID else {
                    throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "document identity mismatch")
                }

                let relative = classification.disposition.directoryName + "/" + work.workID.uuidString + ".novelpkg"
                let destination = options.stageRootURL.appendingPathComponent(relative)
                let projectionDigest = try SHA256Hex.digest(WorkCanonicalJSON.encodeSnapshot(wireSnapshot))
                try await writeIdempotently(
                    document: document,
                    destination: destination,
                    sourceDigest: sourceDigest,
                    snapshotID: snapshot.snapshotID,
                    projectionDigest: projectionDigest,
                    stateURL: options.stageRootURL.appendingPathComponent(".state", isDirectory: true)
                        .appendingPathComponent(work.workID.uuidString + ".json")
                )
                entries.append(
                    LegacyV1ExportEntry(
                        workID: work.workID,
                        disposition: classification.disposition,
                        snapshotID: snapshot.snapshotID,
                        outputRelativePath: relative,
                        outcome: "exported",
                        note: "attachments and opaque resources are not present in v1 SQLite; raw archive is authoritative",
                        projectionDigest: projectionDigest
                    )
                )
            } catch {
                entries.append(
                    LegacyV1ExportEntry(
                        workID: work.workID,
                        disposition: classification.disposition,
                        snapshotID: nil,
                        outputRelativePath: nil,
                        outcome: "blocked",
                        note: String(describing: error)
                    )
                )
            }
        }

        let report = LegacyV1ExportReport(
            exportID: exportID,
            sourceSQLiteSHA256: sourceDigest,
            sourceArchiveManifestPath: options.archiveManifestURL.path,
            sourceArchiveManifestSHA256: evidence.archiveManifestDigest,
            classificationLedgerSHA256: classificationDigest,
            sourceWorkCount: works.count,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            attachmentsPolicy: "SQLite v1 contains no attachment or opaque-resource payload; no automatic reconstruction is performed. Preserve the raw read-only archive.",
            objectVerificationIssues: objectIssues,
            sourceRowIssues: sourceRowIssues,
            entries: entries
        )
        try writeReport(report, to: options.stageRootURL.appendingPathComponent("migration-ledger.json"))
        let endingDigest = try SHA256Hex.digest(fileAt: options.sourceSQLiteURL)
        guard endingDigest == sourceDigest else { throw LegacyV1ExportError.sourceChanged }
        guard report.entries.allSatisfy({ $0.outcome == "exported" }),
              report.objectVerificationIssues.isEmpty,
              report.sourceRowIssues.isEmpty else {
            return report
        }
        let finalDigest = try SHA256Hex.digest(fileAt: options.sourceSQLiteURL)
        guard finalDigest == sourceDigest else { throw LegacyV1ExportError.sourceChanged }
        let finalEvidence = try validateInput(options)
        let finalClassificationDigest = try SHA256Hex.digest(fileAt: options.classificationLedgerURL)
        guard finalEvidence.sourceDigest == sourceDigest,
              finalEvidence.archiveManifestDigest == evidence.archiveManifestDigest,
              finalClassificationDigest == classificationDigest else {
            throw LegacyV1ExportError.sourceChanged
        }
        try writeRunState(
            exportID: report.exportID,
            sourceDigest: report.sourceSQLiteSHA256,
            archiveManifestDigest: report.sourceArchiveManifestSHA256,
            classificationLedgerDigest: report.classificationLedgerSHA256,
            status: "committed",
            to: options.stageRootURL.appendingPathComponent("migration-run.json")
        )
        try Data("COMMITTED\n".utf8).write(
            to: options.stageRootURL.appendingPathComponent("COMMITTED"),
            options: .atomic
        )
        return report
    }

    private func validateInput(_ options: LegacyV1ExportOptions) throws -> ArchiveEvidence {
        guard options.sourceIsVerifiedArchive else { throw LegacyV1ExportError.sourceIsNotVerifiedArchive }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: options.sourceSQLiteURL.path) else {
            throw LegacyV1ExportError.sourceNotFound(options.sourceSQLiteURL)
        }
        guard fileManager.fileExists(atPath: options.classificationLedgerURL.path) else {
            throw LegacyV1ExportError.ledgerNotFound(options.classificationLedgerURL)
        }
        try requireRegularFile(options.classificationLedgerURL)
        try requireSafeRegularFile(options.sourceSQLiteURL)
        try requireSafeRegularFile(options.archiveManifestURL)
        try requireSafeDirectory(options.sourceArchiveRootURL)
        try requireSafeAncestors(options.stageRootURL, allowMissingFinal: true)
        let sourceRoot = canonicalPath(options.sourceArchiveRootURL)
        let stagePath = canonicalPath(options.stageRootURL)
        guard !pathsOverlap(stagePath, sourceRoot) else {
            throw LegacyV1ExportError.stageOverlapsSource
        }
        let sourcePath = canonicalPath(options.sourceSQLiteURL)
        guard sourcePath == sourceRoot || sourcePath.hasPrefix(sourceRoot + "/") else {
            throw LegacyV1ExportError.sourceArchiveManifestMismatch("SQLite is outside the verified archive root")
        }
        let manifestRoot = canonicalPath(options.archiveManifestURL.deletingLastPathComponent())
        guard manifestRoot == sourceRoot else { throw LegacyV1ExportError.unsafeArchivePath(options.archiveManifestURL) }
        let relative = String(sourcePath.dropFirst(sourceRoot.count + 1))
        let sourceDigest = try SHA256Hex.digest(fileAt: options.sourceSQLiteURL)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: options.sourceSQLiteURL.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                throw LegacyV1ExportError.sourceSidecarPresent(sidecar)
            }
        }
        let journal = URL(fileURLWithPath: options.sourceSQLiteURL.path + "-journal")
        if fileManager.fileExists(atPath: journal.path) {
            throw LegacyV1ExportError.sourceSidecarPresent(journal)
        }
        let archiveEnumerator = fileManager.enumerator(
            at: options.sourceArchiveRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        while let item = archiveEnumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LegacyV1ExportError.unsafeArchivePath(item) }
            if values.isRegularFile == true,
               item.lastPathComponent.hasSuffix("-journal") || item.lastPathComponent.contains("-mj") {
                throw LegacyV1ExportError.sourceSidecarPresent(item)
            }
        }
        let archiveManifest = try ArchiveManifest.load(from: options.archiveManifestURL)
        var permittedPaths: Set<String> = []
        let classificationPath = canonicalPath(options.classificationLedgerURL)
        if classificationPath.hasPrefix(sourceRoot + "/") {
            permittedPaths.insert(String(classificationPath.dropFirst(sourceRoot.count + 1)))
        }
        try archiveManifest.verify(
            root: options.sourceArchiveRootURL,
            manifestURL: options.archiveManifestURL,
            permittedPaths: permittedPaths
        )
        guard archiveManifest.entries[relative] == sourceDigest else {
            throw LegacyV1ExportError.sourceArchiveManifestMismatch("SQLite digest is absent or differs (actual=\(sourceDigest), relative=\(relative))")
        }
        return try ArchiveEvidence(
            sourceDigest: sourceDigest,
            archiveManifestDigest: SHA256Hex.digest(Data(contentsOf: options.archiveManifestURL))
        )
    }

    fileprivate func requireSafeRegularFile(_ url: URL) throws {
        try requireSafeAncestors(url, allowMissingFinal: false)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isWritableKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.isWritable != true else {
            throw LegacyV1ExportError.unsafeArchivePath(url)
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        try requireSafeAncestors(url, allowMissingFinal: false)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LegacyV1ExportError.unsafeArchivePath(url)
        }
    }

    private func requireSafeDirectory(_ url: URL) throws {
        try requireSafeAncestors(url, allowMissingFinal: false)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LegacyV1ExportError.unsafeArchivePath(url)
        }
    }

    private func requireSafeAncestors(_ url: URL, allowMissingFinal: Bool) throws {
        let fileManager = FileManager.default
        let path = url.standardizedFileURL.path
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var current = URL(fileURLWithPath: "/")
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component))
            guard fileManager.fileExists(atPath: current.path) else {
                guard allowMissingFinal, index == components.count - 1 else {
                    throw LegacyV1ExportError.unsafeArchivePath(current)
                }
                continue
            }
            let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || index == components.count - 1 else {
                throw LegacyV1ExportError.unsafeArchivePath(current)
            }
            if index == components.count - 1, allowMissingFinal == false,
               values.isDirectory != true, values.isRegularFile != true {
                throw LegacyV1ExportError.unsafeArchivePath(current)
            }
        }
    }

    fileprivate func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    private func prepareNewStage(at url: URL) throws {
        let fileManager = FileManager.default
        try requireSafeAncestors(url, allowMissingFinal: true)
        if fileManager.fileExists(atPath: url.path) {
            try requireSafeDirectory(url)
            let contents = try fileManager.contentsOfDirectory(atPath: url.path)
            guard contents.isEmpty else { throw LegacyV1ExportError.stageNotEmpty(url) }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }

    private func existingCommittedStage(
        options: LegacyV1ExportOptions,
        evidence: ArchiveEvidence,
        classifications: [UUID: ClassificationRecord],
        classificationDigest: String,
        workIDs: Set<UUID>,
        database: ReadOnlyV1Database,
        works: [LegacyWork]
    ) async throws -> LegacyV1ExportReport? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: options.stageRootURL.path) else { return nil }
        try requireSafeDirectory(options.stageRootURL)
        let children = try fileManager.contentsOfDirectory(atPath: options.stageRootURL.path)
        guard !children.isEmpty else { return nil }
        let marker = options.stageRootURL.appendingPathComponent("COMMITTED")
        guard fileManager.fileExists(atPath: marker.path) else {
            throw LegacyV1ExportError.stageNotEmpty(options.stageRootURL)
        }
        try requireRegularFile(marker)
        guard try String(contentsOf: marker, encoding: .utf8) == "COMMITTED\n" else {
            throw LegacyV1ExportError.stageNotEmpty(options.stageRootURL)
        }
        let reportURL = options.stageRootURL.appendingPathComponent("migration-ledger.json")
        let runURL = options.stageRootURL.appendingPathComponent("migration-run.json")
        try requireRegularFile(reportURL)
        try requireRegularFile(runURL)
        let report = try JSONDecoder().decode(LegacyV1ExportReport.self, from: Data(contentsOf: reportURL))
        let run = try JSONDecoder().decode(RunState.self, from: Data(contentsOf: runURL))
        guard run.status == "committed",
              run.exportID == report.exportID,
              run.sourceDigest == evidence.sourceDigest,
              run.archiveManifestDigest == evidence.archiveManifestDigest,
              run.classificationLedgerDigest == classificationDigest,
              report.sourceSQLiteSHA256 == evidence.sourceDigest,
              report.sourceArchiveManifestSHA256 == evidence.archiveManifestDigest,
              report.classificationLedgerSHA256 == classificationDigest,
              report.sourceWorkCount == works.count,
              report.sourceWorkCount == workIDs.count,
              Set(report.entries.map(\.workID)).count == report.entries.count,
              Set(report.entries.map(\.workID)) == workIDs,
              Set(report.entries.map(\.workID)) == Set(classifications.keys),
              report.entries.allSatisfy({ classifications[$0.workID]?.disposition == $0.disposition && $0.outcome == "exported" }),
              report.entries.allSatisfy({ $0.outputRelativePath == "\($0.disposition.rawValue)/\($0.workID.uuidString).novelpkg" }) else {
            throw LegacyV1ExportError.stageNotEmpty(options.stageRootURL)
        }
        try database.verifySourceEvidence(works: works, classifications: classifications)
        for work in works {
            guard let entry = report.entries.first(where: { $0.workID == work.workID }),
                  let projection = entry.projectionDigest,
                  let snapshotID = entry.snapshotID else {
                throw LegacyV1ExportError.stageNotEmpty(options.stageRootURL)
            }
            let source = try database.verifyProjection(for: work)
            guard source.snapshotID == snapshotID, source.projectionDigest == projection else {
                throw LegacyV1ExportError.stageNotEmpty(options.stageRootURL)
            }
        }
        try validateStageInventory(report: report, root: options.stageRootURL)
        let repository = NovelpkgRepository()
        for entry in report.entries {
            guard let relative = entry.outputRelativePath,
                  let expectedProjection = entry.projectionDigest else {
                throw LegacyV1ExportError.stageNotEmpty(options.stageRootURL)
            }
            let stateURL = options.stageRootURL.appendingPathComponent(".state/\(entry.workID.uuidString).json")
            let state = try JSONDecoder().decode(ProjectionState.self, from: Data(contentsOf: stateURL))
            guard state.sourceDigest == evidence.sourceDigest,
                  state.snapshotID == entry.snapshotID,
                  state.projectionDigest == expectedProjection else {
                throw LegacyV1ExportError.stageNotEmpty(options.stageRootURL)
            }
            let document = try await repository.load(from: options.stageRootURL.appendingPathComponent(relative))
            let projection = try SHA256Hex.digest(WorkCanonicalJSON.encodeSnapshot(WorkSnapshot(document: document)))
            guard projection == expectedProjection else { throw LegacyV1ExportError.stageNotEmpty(options.stageRootURL) }
        }
        return report
    }

    private func validateStageInventory(report: LegacyV1ExportReport, root: URL) throws {
        let fileManager = FileManager.default
        var expectedFiles: Set = ["COMMITTED", "migration-run.json", "migration-ledger.json"]
        var expectedDirectories: Set = ["verified", "quarantine", "needs-review", ".state"]
        let packagePaths = Set(report.entries.compactMap(\.outputRelativePath))
        for entry in report.entries {
            guard let output = entry.outputRelativePath, let projection = entry.projectionDigest else {
                throw LegacyV1ExportError.stageNotEmpty(root)
            }
            expectedFiles.insert(output)
            expectedFiles.insert(".state/\(entry.workID.uuidString).json")
            _ = projection
            let components = output.split(separator: "/")
            guard components.count == 2, expectedDirectories.contains(String(components[0])) else {
                throw LegacyV1ExportError.stageNotEmpty(root)
            }
            try requireSafeDirectory(root.appendingPathComponent(output))
            try requireRegularFile(root.appendingPathComponent(".state/\(entry.workID.uuidString).json"))
        }
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [])
        while let item = enumerator?.nextObject() as? URL {
            let relative = String(item.path.dropFirst(root.path.count + 1))
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LegacyV1ExportError.unsafeArchivePath(item) }
            if values.isDirectory == true {
                if packagePaths.contains(relative) {
                    expectedFiles.remove(relative)
                } else if packagePaths.contains(where: { relative.hasPrefix($0 + "/") }) {
                    continue
                } else if expectedDirectories.contains(relative) {
                    expectedDirectories.remove(relative)
                } else {
                    throw LegacyV1ExportError.stageNotEmpty(item)
                }
            } else if values.isRegularFile == true {
                if packagePaths.contains(where: { relative.hasPrefix($0 + "/") }) {
                    continue
                }
                guard expectedFiles.remove(relative) != nil else { throw LegacyV1ExportError.stageNotEmpty(item) }
            } else {
                throw LegacyV1ExportError.unsafeArchivePath(item)
            }
        }
        guard expectedFiles.isEmpty, expectedDirectories.isEmpty else {
            throw LegacyV1ExportError.stageNotEmpty(root)
        }
    }

    private func writeIdempotently(
        document: NovelDocument,
        destination: URL,
        sourceDigest: String,
        snapshotID: String,
        projectionDigest: String,
        stateURL: URL
    ) async throws {
        let repository = NovelpkgRepository()
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            do {
                guard let stateData = try? Data(contentsOf: stateURL),
                      let state = try? JSONDecoder().decode(ProjectionState.self, from: stateData),
                      state.sourceDigest == sourceDigest,
                      state.snapshotID == snapshotID,
                      state.projectionDigest == projectionDigest else {
                    throw LegacyV1ExportError.writeFailed("existing package state differs at \(destination.path)")
                }
                let existing = try await repository.load(from: destination)
                guard existing == document else {
                    throw LegacyV1ExportError.writeFailed("existing package differs at \(destination.path)")
                }
                return
            } catch let error as LegacyV1ExportError {
                throw error
            } catch {
                throw LegacyV1ExportError.writeFailed("read-back failed at \(destination.path): \(error)")
            }
        }
        do {
            try await repository.save(document, to: destination)
            let readBack = try await repository.load(from: destination)
            guard readBack == document else {
                throw LegacyV1ExportError.writeFailed("logical read-back mismatch at \(destination.path)")
            }
            try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let state = ProjectionState(
                sourceDigest: sourceDigest,
                snapshotID: snapshotID,
                projectionDigest: projectionDigest
            )
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch let error as LegacyV1ExportError {
            throw error
        } catch {
            throw LegacyV1ExportError.writeFailed(String(describing: error))
        }
    }

    private func writeRunState(
        exportID: UUID,
        sourceDigest: String,
        archiveManifestDigest: String,
        classificationLedgerDigest: String,
        status: String,
        to url: URL
    ) throws {
        let state = RunState(
            exportID: exportID,
            sourceDigest: sourceDigest,
            archiveManifestDigest: archiveManifestDigest,
            classificationLedgerDigest: classificationLedgerDigest,
            status: status
        )
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    private func writeReport(_ report: LegacyV1ExportReport, to url: URL) throws {
        let data = try JSONEncoder.prettySorted.encode(report)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".migration-ledger.\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw LegacyV1ExportError.writeFailed("ledger: \(error)")
        }
    }
}

private extension LegacyV1Disposition {
    static var allCases: [Self] {
        [.verified, .quarantine, .needsReview]
    }

    var directoryName: String {
        switch self {
        case .verified: "verified"
        case .quarantine: "quarantine"
        case .needsReview: "needs-review"
        }
    }
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private enum ClassificationLedger {
    static func load(from url: URL) throws -> [UUID: ClassificationRecord] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var values: [UUID: ClassificationRecord] = [:]
        guard !text.isEmpty else {
            throw LegacyV1ExportError.malformedClassification(workID: "<empty>", value: "empty CSV")
        }
        let lines = text.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            var line = rawLine
            if index < lines.count - 1, line.unicodeScalars.last?.value == 13 {
                line.removeLast()
            }
            guard !line.contains("\r") else {
                throw LegacyV1ExportError.malformedClassification(workID: "<unknown>", value: "bare or internal CR")
            }
            if line.isEmpty {
                if index == lines.count - 1, text.unicodeScalars.last?.value == 10 {
                    continue
                }
                throw LegacyV1ExportError.malformedClassification(workID: "<empty>", value: "empty CSV row")
            }
            let fields: [String]
            do {
                fields = try CSV.parse(line)
            } catch {
                throw LegacyV1ExportError.malformedClassification(workID: "<unknown>", value: "unclosed quote")
            }
            let knownHeader = ["workID", "classification", "currentSnapshotID", "currentSnapshotCreatedAt", "currentSnapshotLocalGeneration", "acknowledgedHeadSnapshotID", "acknowledgedHeadGeneration", "evidence"]
            if fields == knownHeader {
                continue
            }
            guard fields.count == 8 else {
                throw LegacyV1ExportError.malformedClassification(
                    workID: fields.first ?? "<missing>",
                    value: "expected exactly 8 columns, actual \(fields.count)"
                )
            }
            guard let workID = UUID(uuidString: fields[0]) else {
                throw LegacyV1ExportError.malformedClassification(workID: fields[0], value: "invalid UUID")
            }
            guard fields.dropFirst().allSatisfy({ !$0.isEmpty }) else {
                throw LegacyV1ExportError.malformedClassification(workID: fields[0], value: "evidence column is empty")
            }
            guard let disposition = disposition(value: fields[1]) else {
                throw LegacyV1ExportError.malformedClassification(workID: fields[0], value: fields[1])
            }
            guard fields[2].count == 64,
                  fields[2].utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }),
                  fields[5] == fields[2],
                  ISO8601DateFormatter().date(from: fields[3]) != nil,
                  Int(fields[4]) != nil,
                  Int(fields[6]) != nil else {
                throw LegacyV1ExportError.malformedClassification(workID: fields[0], value: "invalid evidence columns")
            }
            let record = ClassificationRecord(
                disposition: disposition,
                snapshotID: fields[2],
                createdAt: fields[3],
                currentSnapshotLocalGeneration: Int(fields[4])!,
                headSnapshotID: fields[5],
                headGeneration: Int(fields[6])!
            )
            guard values.updateValue(record, forKey: workID) == nil else {
                throw LegacyV1ExportError.duplicateClassification(workID)
            }
        }
        return values
    }

    private static func disposition(value: String) -> LegacyV1Disposition? {
        switch value {
        case "verified", "verified_candidate":
            .verified
        case "quarantine", "legacy_quarantine_test_batch":
            .quarantine
        case "needs-review", "needs_review", "legacy_quarantine_ambiguous_user_touched":
            .needsReview
        default:
            nil
        }
    }
}

private struct ClassificationRecord: Equatable {
    let disposition: LegacyV1Disposition
    let snapshotID: String
    let createdAt: String
    let currentSnapshotLocalGeneration: Int
    let headSnapshotID: String
    let headGeneration: Int
}

private enum CSV {
    static func parse(_ line: String) throws -> [String] {
        var result: [String] = []
        var field = ""
        var quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                if quoted, line.index(after: index) < line.endIndex,
                   line[line.index(after: index)] == "\"" {
                    field.append("\"")
                    index = line.index(after: index)
                } else {
                    quoted.toggle()
                }
            } else if character == ",", !quoted {
                result.append(field)
                field = ""
            } else {
                field.append(character)
            }
            index = line.index(after: index)
        }
        guard !quoted else { throw CSVError.unclosedQuote }
        result.append(field)
        return result
    }
}

private enum CSVError: Error {
    case unclosedQuote
}

private struct LegacyWork {
    let workID: UUID
    let documentID: UUID
    let currentSnapshotID: String
    let acknowledgedHeadSnapshotID: String
    let acknowledgedHeadGeneration: Int
}

private struct ArchiveEvidence {
    let sourceDigest: String
    let archiveManifestDigest: String
}

private struct ArchiveManifest {
    let entries: [String: String]

    static func load(from url: URL) throws -> Self {
        let text = try String(contentsOf: url, encoding: .utf8)
        var entries: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2 else {
                throw LegacyV1ExportError.sourceArchiveManifestMismatch("malformed sha256 manifest line")
            }
            let digest = String(fields[0])
            guard digest.count == 64,
                  digest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
                throw LegacyV1ExportError.sourceArchiveManifestMismatch("digest is not lowercase 64-hex")
            }
            var path = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("./") {
                path.removeFirst(2)
            }
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
                throw LegacyV1ExportError.sourceArchiveManifestMismatch("manifest path is not relative")
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty,
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw LegacyV1ExportError.sourceArchiveManifestMismatch("manifest path is not normalized")
            }
            guard entries.updateValue(digest, forKey: path) == nil else {
                throw LegacyV1ExportError.sourceArchiveManifestMismatch("duplicate manifest path: \(path)")
            }
        }
        guard !entries.isEmpty else {
            throw LegacyV1ExportError.sourceArchiveManifestMismatch("manifest is empty")
        }
        return Self(entries: entries)
    }

    func verify(root: URL, manifestURL: URL, permittedPaths: Set<String> = []) throws {
        let exporter = LegacyV1Exporter()
        let rootPath = exporter.canonicalPath(root)
        let manifestPath = exporter.canonicalPath(manifestURL)
        let manifestRelative = String(manifestPath.dropFirst(rootPath.count + 1))
        guard manifestRelative == manifestURL.lastPathComponent else {
            throw LegacyV1ExportError.sourceArchiveManifestMismatch("manifest must be a direct child of archive root")
        }
        for (path, expected) in entries {
            let candidate = root.appendingPathComponent(path)
            try exporter.requireSafeRegularFile(candidate)
            guard try SHA256Hex.digest(fileAt: candidate) == expected else {
                throw LegacyV1ExportError.sourceArchiveManifestMismatch("digest mismatch: \(path)")
            }
        }
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        while let item = enumerator?.nextObject() as? URL {
            let relative = String(item.path.dropFirst(root.path.count + 1))
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LegacyV1ExportError.unsafeArchivePath(item) }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else { throw LegacyV1ExportError.unsafeArchivePath(item) }
            if relative == manifestRelative {
                continue
            }
            guard entries[relative] != nil || permittedPaths.contains(relative) else {
                throw LegacyV1ExportError.sourceArchiveManifestMismatch("unlisted archive file: \(relative)")
            }
        }
    }
}

private struct ProjectionState: Codable {
    let sourceDigest: String
    let snapshotID: String
    let projectionDigest: String
}

private struct RunState: Codable {
    let exportID: UUID
    let sourceDigest: String
    let archiveManifestDigest: String
    let classificationLedgerDigest: String
    let status: String
}

private struct LegacySnapshot {
    let snapshotID: String
    let manifest: Data
    let manifestModel: LegacyV1Manifest
    let createdAt: String
    let localGeneration: Int
    let pinned: Int
}

private struct LegacyV1Manifest: Decodable {
    let schemaVersion: Int
    let workID: UUID
    let parentSnapshotIDs: [String]
    let entries: [LegacyV1Entry]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case workID = "workId"
        case parentSnapshotIDs = "parentSnapshotIds"
        case entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let all = try decoder.container(keyedBy: DynamicCodingKey.self)
        let expected = Set(CodingKeys.allCases.map(\.stringValue))
        guard Set(all.allKeys.map(\.stringValue)) == expected else {
            throw LegacyV1DecodeError.nonCanonical("unknown or missing manifest member")
        }
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        workID = try container.decode(UUID.self, forKey: .workID)
        parentSnapshotIDs = try container.decode([String].self, forKey: .parentSnapshotIDs)
        entries = try container.decode([LegacyV1Entry].self, forKey: .entries)
        guard schemaVersion == 1, parentSnapshotIDs.count <= 2,
              parentSnapshotIDs == parentSnapshotIDs.sorted(),
              Set(parentSnapshotIDs).count == parentSnapshotIDs.count,
              entries.map(\.entityKey).isStrictlySortedUTF8,
              Set(entries.map(\.entityKey)).count == entries.count,
              entries.count(where: { $0.entityKey == "work/document" }) == 1 else {
            throw LegacyV1DecodeError.nonCanonical("manifest ordering, uniqueness, or required document entry failed")
        }
    }
}

private struct LegacyV1Entry: Decodable {
    let byteCount: Int
    let contentType: String
    let entityKey: String
    let objectID: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case byteCount
        case contentType
        case entityKey
        case objectID = "objectId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let all = try decoder.container(keyedBy: DynamicCodingKey.self)
        let expected = Set(CodingKeys.allCases.map(\.stringValue))
        guard Set(all.allKeys.map(\.stringValue)) == expected else {
            throw LegacyV1DecodeError.nonCanonical("unknown or missing entry member")
        }
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        contentType = try container.decode(String.self, forKey: .contentType)
        entityKey = try container.decode(String.self, forKey: .entityKey)
        objectID = try container.decode(String.self, forKey: .objectID)
        guard byteCount >= 0, objectID.count == 64,
              objectID.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
            throw LegacyV1DecodeError.nonCanonical("invalid entry digest or byte count")
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

private enum LegacyV1DecodeError: Error {
    case nonCanonical(String)
}

private extension [String] {
    var isStrictlySortedUTF8: Bool {
        zip(self, dropFirst()).allSatisfy { left, right in
            left.utf8.lexicographicallyPrecedes(right.utf8)
        }
    }
}

private final class ReadOnlyV1Database: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var database: OpaquePointer?
        let encodedPath = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let immutableURI = "file:\(encodedPath)?mode=ro&immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        guard sqlite3_open_v2(immutableURI, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let database {
                sqlite3_close(database)
            }
            throw LegacyV1ExportError.sqliteOpenFailed(message)
        }
        handle = database
        sqlite3_busy_timeout(database, 5000)
        do {
            try quickCheck()
        } catch {
            sqlite3_close(database)
            handle = nil
            throw error
        }
    }

    func close() {
        if let handle {
            sqlite3_close(handle); self.handle = nil
        }
    }

    private func quickCheck() throws {
        guard let handle else { throw LegacyV1ExportError.sqliteOpenFailed("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LegacyV1ExportError.sqliteQueryFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let result = sqlite3_column_text(statement, 0),
              String(cString: result) == "ok" else {
            throw LegacyV1ExportError.sqliteQueryFailed("PRAGMA quick_check did not return ok")
        }
    }

    func works() throws -> [LegacyWork] {
        try rows(sql: "SELECT work_id, document_id, current_local_snapshot_id, acknowledged_head_snapshot_id, acknowledged_head_generation FROM works ORDER BY work_id") { statement -> LegacyWork? in
            guard let work = text(statement, 0), let workID = UUID(uuidString: work),
                  let document = text(statement, 1), let documentID = UUID(uuidString: document),
                  let snapshot = text(statement, 2), !snapshot.isEmpty else { return nil }
            return LegacyWork(
                workID: workID,
                documentID: documentID,
                currentSnapshotID: snapshot,
                acknowledgedHeadSnapshotID: text(statement, 3) ?? "",
                acknowledgedHeadGeneration: Int(sqlite3_column_int64(statement, 4))
            )
        }
    }

    func malformedWorkRows() throws -> [String] {
        try rows(sql: "SELECT work_id, document_id, current_local_snapshot_id, acknowledged_head_snapshot_id, acknowledged_head_generation FROM works ORDER BY work_id") { statement in
            let work = text(statement, 0) ?? "<null>"
            let document = text(statement, 1) ?? "<null>"
            let snapshot = text(statement, 2) ?? "<null>"
            let acknowledged = text(statement, 3) ?? "<null>"
            guard UUID(uuidString: work) != nil,
                  UUID(uuidString: document) != nil,
                  !snapshot.isEmpty,
                  snapshot != "<null>",
                  acknowledged.count == 64 else {
                return "works row malformed: work_id=\(work), document_id=\(document), current_local_snapshot_id=\(snapshot)"
            }
            return nil
        }
    }

    func snapshot(id: String, workID: UUID) throws -> LegacySnapshot? {
        try one(sql: "SELECT snapshot_id, manifest, created_at, local_generation, pinned FROM snapshots WHERE snapshot_id = ? AND work_id = ?", binds: [id, workID.uuidString.lowercased()]) { statement in
            guard let snapshotID = text(statement, 0), let manifest = data(statement, 1) else { return nil }
            let manifestModel: LegacyV1Manifest
            do {
                manifestModel = try JSONDecoder().decode(LegacyV1Manifest.self, from: manifest)
            } catch {
                throw LegacyV1DecodeError.nonCanonical(String(describing: error))
            }
            return LegacySnapshot(
                snapshotID: snapshotID,
                manifest: manifest,
                manifestModel: manifestModel,
                createdAt: text(statement, 2) ?? "",
                localGeneration: Int(sqlite3_column_int64(statement, 3)),
                pinned: Int(sqlite3_column_int(statement, 4))
            )
        }
    }

    func verifySourceEvidence(works: [LegacyWork], classifications: [UUID: ClassificationRecord]) throws {
        for work in works {
            guard let classification = classifications[work.workID],
                  classification.snapshotID == work.currentSnapshotID,
                  classification.headSnapshotID == work.acknowledgedHeadSnapshotID,
                  classification.headGeneration == work.acknowledgedHeadGeneration else {
                throw LegacyV1ExportError.malformedClassification(
                    workID: work.workID.uuidString,
                    value: "currentSnapshotID or acknowledged head evidence does not match works"
                )
            }
            guard let snapshot = try snapshot(id: work.currentSnapshotID, workID: work.workID),
                  classification.createdAt == snapshot.createdAt else {
                throw LegacyV1ExportError.malformedClassification(
                    workID: work.workID.uuidString,
                    value: "currentSnapshotCreatedAt does not match snapshots.created_at"
                )
            }
            guard classification.currentSnapshotLocalGeneration == snapshot.localGeneration else {
                throw LegacyV1ExportError.malformedClassification(
                    workID: work.workID.uuidString,
                    value: "currentSnapshotLocalGeneration does not match snapshots.local_generation"
                )
            }
        }
    }

    func verifyProjection(for work: LegacyWork) throws -> (snapshotID: String, projectionDigest: String) {
        guard let snapshot = try snapshot(id: work.currentSnapshotID, workID: work.workID) else {
            throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "current snapshot is missing")
        }
        guard SHA256Hex.digest(snapshot.manifest) == snapshot.snapshotID else {
            throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "snapshot digest does not match snapshot ID")
        }
        guard snapshot.manifestModel.workID == work.workID,
              snapshot.manifestModel.entries.count(where: { $0.entityKey == "work/document" }) == 1 else {
            throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "manifest work identity or document entry is invalid")
        }
        for entry in snapshot.manifestModel.entries {
            guard let object = try object(id: entry.objectID),
                  object.byteCount == entry.byteCount,
                  SHA256Hex.digest(object.bytes) == entry.objectID else {
                throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "referenced object is invalid: \(entry.objectID)")
            }
        }
        guard let documentEntry = snapshot.manifestModel.entries.first(where: { $0.entityKey == "work/document" }),
              ["application/json", "application/vnd.fuminiwa.entity+json;version=1"].contains(documentEntry.contentType),
              let documentObject = try object(id: documentEntry.objectID) else {
            throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "work/document object is missing")
        }
        let wireSnapshot = try WorkCanonicalJSON.decodeSnapshot(documentObject.bytes)
        let document = try wireSnapshot.materializedDocument()
        guard document.id == work.documentID, wireSnapshot.documentID.rawValue == work.documentID else {
            throw LegacyV1ExportError.invalidManifest(workID: work.workID, reason: "document identity mismatch")
        }
        return try (
            snapshot.snapshotID,
            SHA256Hex.digest(WorkCanonicalJSON.encodeSnapshot(wireSnapshot))
        )
    }

    func object(id: String) throws -> LegacyObject? {
        try one(sql: "SELECT object_id, byte_count, bytes FROM objects WHERE object_id = ?", binds: [id]) { statement in
            guard let objectID = text(statement, 0), let bytes = data(statement, 2) else { return nil }
            return LegacyObject(objectID: objectID, byteCount: sqlite3_column_int64(statement, 1), bytes: bytes)
        }
    }

    func verifyObjects() throws -> [String] {
        try rows(sql: "SELECT object_id, byte_count, bytes FROM objects ORDER BY object_id") { statement in
            guard let objectID = text(statement, 0), let bytes = data(statement, 2) else { return "invalid object row \(sqlite3_column_int(statement, 0))" }
            let count = sqlite3_column_int64(statement, 1)
            let digest = SHA256Hex.digest(bytes)
            guard count == Int64(bytes.count), digest == objectID else {
                return "object \(objectID): byte_count/digest mismatch (actual \(digest), count \(bytes.count))"
            }
            return nil
        }
    }

    private func rows<T>(sql: String, _ decode: (OpaquePointer) throws -> T?) throws -> [T] {
        guard let handle else { throw LegacyV1ExportError.sqliteOpenFailed("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LegacyV1ExportError.sqliteQueryFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                if let value = try decode(statement) {
                    result.append(value)
                }
            } else if step == SQLITE_DONE {
                break
            } else {
                throw LegacyV1ExportError.sqliteQueryFailed(String(cString: sqlite3_errmsg(handle)))
            }
        }
        return result
    }

    private func one<T>(sql: String, binds: [String], _ decode: (OpaquePointer) throws -> T?) throws -> T? {
        guard let handle else { throw LegacyV1ExportError.sqliteOpenFailed("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LegacyV1ExportError.sqliteQueryFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, bind) in binds.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), bind, -1, SQLITE_TRANSIENT)
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw LegacyV1ExportError.sqliteQueryFailed(String(cString: sqlite3_errmsg(handle)))
        }
        guard result == SQLITE_ROW else { return nil }
        return try decode(statement)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func data(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return Data() }
        guard let value = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: value, count: count)
    }
}

private struct LegacyObject {
    let objectID: String
    let byteCount: Int64
    let bytes: Data
}

private enum SHA256Hex {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(fileAt url: URL) throws -> String {
        try digest(Data(contentsOf: url, options: [.mappedIfSafe]))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
