import Foundation
import NovelCore
import NovelStorage
import NovelSync
import NovelSyncV2
import NovelSyncV2PortableBridge
import NovelSyncV2Store

public enum MigrationError: Error, Equatable, Sendable {
    case invalidSource(String)
    case invalidTarget(String)
    case sourceDigestMismatch
    case accountRequired
    case unknownAccount
    case ambiguousAccount
    case commitRequiresVerifiedMarker
    case targetAlreadyExists
    case targetOverlapsSource
    case productionRootRejected
    case invalidWorkID
    case invalidCreatedAt
    case sourceChangedDuringRead
    case invalidBindingFile
    case quarantined(String)
    case untrustedExportStage(String)
    case exportProvenanceMismatch(String)
}

public struct MigrationAccountBinding: Equatable, Sendable {
    public let binding: V2AccountBinding
    public let knownAccountIDs: Set<String>
    public let candidates: [String]

    public init(binding: V2AccountBinding, knownAccountIDs: Set<String>, candidates: [String] = []) {
        self.binding = binding
        self.knownAccountIDs = knownAccountIDs
        self.candidates = candidates
    }
}

public struct MigrationOptions: Sendable {
    public let sourceURL: URL
    public let targetRoot: URL
    public let commit: Bool
    public let expectedSourceDigest: String?
    public let verifiedMarker: String?
    public let account: MigrationAccountBinding?
    public let workID: WorkID?
    public let resume: Bool
    public let trustedAuthorityRootURL: URL?
    public let trustedAuthorityURL: URL?
    public let expectedAuthorityDigest: String?
    public let expectedAuthorityID: String?

    public init(
        sourceURL: URL,
        targetRoot: URL,
        commit: Bool = false,
        expectedSourceDigest: String? = nil,
        verifiedMarker: String? = nil,
        account: MigrationAccountBinding? = nil,
        workID: WorkID? = nil,
        resume: Bool = false,
        trustedAuthorityRootURL: URL? = nil,
        trustedAuthorityURL: URL? = nil,
        expectedAuthorityDigest: String? = nil,
        expectedAuthorityID: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.targetRoot = targetRoot
        self.commit = commit
        self.expectedSourceDigest = expectedSourceDigest
        self.verifiedMarker = verifiedMarker
        self.account = account
        self.workID = workID
        self.resume = resume
        self.trustedAuthorityRootURL = trustedAuthorityRootURL
        self.trustedAuthorityURL = trustedAuthorityURL
        self.expectedAuthorityDigest = expectedAuthorityDigest
        self.expectedAuthorityID = expectedAuthorityID
    }
}

/// The export report is intentionally decoded again by the adoption tool.  The
/// exporter and the adopter are separate products; sharing an in-memory report
/// would make a changed or hand-written stage indistinguishable from the
/// exporter output.
private struct VerifiedExportReport: Decodable, Equatable {
    let formatVersion: Int
    let exportID: UUID
    let sourceSQLiteSHA256: String
    let sourceArchiveManifestSHA256: String
    let classificationLedgerSHA256: String
    let entries: [VerifiedExportEntry]
}

private struct VerifiedExportEntry: Decodable, Equatable {
    let workID: UUID
    let disposition: String
    let snapshotID: String?
    let outputRelativePath: String?
    let outcome: String
    let projectionDigest: String?
}

private struct VerifiedRunState: Decodable, Equatable {
    let exportID: UUID
    let sourceDigest: String
    let archiveManifestDigest: String
    let classificationLedgerDigest: String
    let status: String
}

private struct VerifiedProjectionState: Decodable, Equatable {
    let sourceDigest: String
    let snapshotID: String?
    let projectionDigest: String?
}

private struct VerifiedExportStageAttestation: Equatable {
    let exportID: UUID
    let workID: UUID
    let sourceSQLiteDigest: String
    let archiveManifestDigest: String
    let classificationDigest: String
    let reportDigest: String
    let runDigest: String
    let markerDigest: String
    let sidecarDigest: String
}

private struct LoadedTrustedProvenance: Equatable {
    let authority: MigrationTrustedProvenanceAuthority
    let canonicalData: Data
    let digest: String
}

public struct SourceInventory: Codable, Equatable, Sendable {
    public let sourceKind: String
    public let sourceURL: String
    public let sourceDigest: String
    public let workID: String
    public let documentID: String
    public let createdAt: String
    public let fileCount: Int
    public let byteCount: Int64
    public let registryEvidence: Data
    public let portableResources: [MigrationPortableResource]

    public init(
        sourceKind: String,
        sourceURL: String,
        sourceDigest: String,
        workID: String,
        documentID: String,
        createdAt: String,
        fileCount: Int,
        byteCount: Int64,
        registryEvidence: Data,
        portableResources: [MigrationPortableResource] = []
    ) {
        self.sourceKind = sourceKind
        self.sourceURL = sourceURL
        self.sourceDigest = sourceDigest
        self.workID = workID
        self.documentID = documentID
        self.createdAt = createdAt
        self.fileCount = fileCount
        self.byteCount = byteCount
        self.registryEvidence = registryEvidence
        self.portableResources = portableResources
    }
}

public struct MigrationPortableResource: Codable, Equatable, Sendable {
    public let path: String
    public let kind: String
    public let byteCount: Int64
    public let digest: String
    public let objectID: String?
    public let emptyDirectory: Bool

    public init(path: String, kind: String, byteCount: Int64, digest: String, objectID: String?, emptyDirectory: Bool) {
        self.path = path
        self.kind = kind
        self.byteCount = byteCount
        self.digest = digest
        self.objectID = objectID
        self.emptyDirectory = emptyDirectory
    }
}

public struct ArchiveReadResult: Sendable {
    public let inventory: SourceInventory
    public let model: SnapshotModel
    public let encoded: EncodedSnapshot
    public let portableResources: [NovelCore.PortableResource]

    public init(
        inventory: SourceInventory,
        model: SnapshotModel,
        encoded: EncodedSnapshot,
        portableResources: [NovelCore.PortableResource]
    ) {
        self.inventory = inventory
        self.model = model
        self.encoded = encoded
        self.portableResources = portableResources
    }
}

public struct MigrationRunResult: Sendable {
    public let inventory: SourceInventory
    public let state: V2MigrationLedgerState?
    public let noChanges: Bool
    public let quarantineReason: String?

    public init(inventory: SourceInventory, state: V2MigrationLedgerState?, noChanges: Bool, quarantineReason: String? = nil) {
        self.inventory = inventory
        self.state = state
        self.noChanges = noChanges
        self.quarantineReason = quarantineReason
    }
}

public struct ArchiveReader: Sendable {
    public init() {}

    public func inventoryAsync(sourceURL: URL, proposedWorkID: WorkID? = nil) async throws -> ArchiveReadResult {
        try validateSourceRoot(sourceURL)
        let before = try digestRoot(sourceURL)
        let files = try readFiles(sourceURL)
        guard let manifestData = files.first(where: { $0.path == "manifest.json" })?.data else {
            throw MigrationError.invalidSource("manifestMissing")
        }
        let manifest = try decodeManifest(manifestData)
        let document: NovelDocument
        do {
            document = try await NovelpkgRepository().load(from: sourceURL)
        } catch {
            throw MigrationError.invalidSource("packageValidation:\(error)")
        }
        guard let manifestDocumentID = UUID(uuidString: manifest.documentID),
              document.id == manifestDocumentID else { throw MigrationError.invalidSource("documentIDMismatch") }
        let createdAt = try parseCreatedAt(manifest.createdAt)
        let sourceDigest = digest(files: files)
        guard before == sourceDigest else { throw MigrationError.sourceChangedDuringRead }
        let workID = proposedWorkID ?? deterministicWorkID(sourceDigest: sourceDigest)
        let attachments = try readAttachments(sourceURL, sourceDigest: sourceDigest)
        for attachment in attachments {
            guard files.first(where: { $0.path == "attachments/\(attachment.fileName)" && !$0.isDirectory })?.data == attachment.bytes else {
                throw MigrationError.sourceChangedDuringRead
            }
        }
        let portableImport: SyncV2PortableImport
        do {
            portableImport = try await SyncV2PortableBridge().importExplicitPackage(from: sourceURL)
        } catch {
            throw MigrationError.invalidSource("portableBridge:(error)")
        }
        guard portableImport.document == document,
              portableImport.documentCreatedAt == createdAt,
              portableImport.attachments == attachments else {
            throw MigrationError.invalidSource("portableBridgeMismatch")
        }
        let model = SnapshotModel(workId: workID, document: document, documentCreatedAt: createdAt, attachments: attachments)
        let encoded: EncodedSnapshot
        do {
            encoded = try SnapshotCodec.encode(model)
            try SnapshotValidator.validateObjects(encoded)
        } catch {
            throw MigrationError.invalidSource("snapshotValidation:\(error)")
        }
        let resources = portableImport.resources.map { resource in
            MigrationPortableResource(
                path: resource.pathComponents.joined(separator: "/"),
                kind: resource.kind.rawValue,
                byteCount: Int64(resource.bytes?.count ?? 0),
                digest: resource.bytes.map { SHA256Digest.hex($0) } ?? SHA256Digest.hex(Data()),
                objectID: resource.bytes.map { ObjectID(data: $0).description },
                emptyDirectory: resource.kind == .directory
            )
        }
        guard try digestRoot(sourceURL) == sourceDigest else { throw MigrationError.sourceChangedDuringRead }
        let evidence = try evidenceBytes(sourceURL: sourceURL, sourceDigest: sourceDigest, manifest: manifest, files: files, workID: workID, encoded: encoded, resources: resources)
        let inventory = SourceInventory(
            sourceKind: "novelpkg", sourceURL: sourceURL.standardizedFileURL.path,
            sourceDigest: sourceDigest.hex, workID: workID.description,
            documentID: document.id.uuidString.lowercased(),
            createdAt: makeISO8601().string(from: createdAt),
            fileCount: files.count, byteCount: files.reduce(0) { $0 + Int64($1.data.count) },
            registryEvidence: evidence, portableResources: resources
        )
        return ArchiveReadResult(
            inventory: inventory,
            model: model,
            encoded: encoded,
            portableResources: portableImport.resources
        )
    }
}

public actor MigrationRunner {
    private let reader: ArchiveReader
    private let finalCommitHook: (@Sendable () async throws -> Void)?

    public init(reader: ArchiveReader = ArchiveReader()) {
        self.reader = reader
        finalCommitHook = nil
    }

    init(reader: ArchiveReader = ArchiveReader(), finalCommitHook: (@Sendable () async throws -> Void)?) {
        self.reader = reader
        self.finalCommitHook = finalCommitHook
    }

    public func run(_ options: MigrationOptions) async throws -> MigrationRunResult {
        let archive = try await reader.inventoryAsync(
            sourceURL: options.sourceURL,
            proposedWorkID: options.workID
        )
        let inventory = archive.inventory
        let model = archive.model
        let encoded = archive.encoded
        if options.commit, options.workID == nil {
            throw MigrationError.invalidWorkID
        }
        let initialAuthority: LoadedTrustedProvenance? = if options.commit {
            try loadTrustedProvenance(options, sourceURL: options.sourceURL)
        } else {
            nil
        }
        let initialStageAttestation: VerifiedExportStageAttestation?
        if options.commit {
            let authority = try requireAuthority(initialAuthority)
            initialStageAttestation = try attestVerifiedExportStage(
                sourceURL: options.sourceURL,
                archive: archive,
                authority: authority
            )
        } else {
            initialStageAttestation = nil
        }
        try validateTargetRoot(options.targetRoot, sourceURL: options.sourceURL)
        guard let expected = options.expectedSourceDigest else {
            guard !options.commit else { throw MigrationError.sourceDigestMismatch }
            return MigrationRunResult(inventory: inventory, state: nil, noChanges: false)
        }
        guard expected == inventory.sourceDigest else { throw MigrationError.sourceDigestMismatch }
        guard options.commit else { return MigrationRunResult(inventory: inventory, state: nil, noChanges: false) }
        let manager = FileManager.default
        let targetExists = manager.fileExists(atPath: options.targetRoot.path)
        if targetExists && !options.resume {
            throw MigrationError.targetAlreadyExists
        }
        if !targetExists {
            try manager.createDirectory(at: options.targetRoot, withIntermediateDirectories: true)
        }
        let store = try LocalSyncV2Store(root: options.targetRoot, policy: targetExists ? .openExisting : .createNew)
        defer { Task { await store.close() } }
        let sourceDigest = Data(hex: inventory.sourceDigest)
        let existingLedger = try await store.migrationLedgerEntry(sourceKind: inventory.sourceKind, sourceDigest: sourceDigest)
        guard !targetExists || existingLedger != nil else { throw MigrationError.targetAlreadyExists }
        let discovered: V2MigrationLedgerEntry = if let existing = existingLedger {
            existing
        } else {
            try await store.recordMigrationDiscovered(
                migrationID: UUID(), sourceKind: inventory.sourceKind,
                sourceDigest: sourceDigest, evidenceBytes: inventory.registryEvidence
            )
        }
        let migrationID = discovered.migrationID
        guard discovered.evidenceBytes == inventory.registryEvidence else { throw MigrationError.sourceDigestMismatch }
        guard discovered.state != .quarantined else {
            return MigrationRunResult(inventory: inventory, state: .quarantined, noChanges: false, quarantineReason: "alreadyQuarantined")
        }
        let workID = options.workID ?? (try? WorkID(uuidString: inventory.workID))
        guard let workID else { throw MigrationError.invalidWorkID }
        let staging = V2MigrationStagingInput(
            migrationID: migrationID,
            proposedWorkID: workID,
            proposedDocumentID: DocumentID(model.document.id),
            snapshotID: encoded.snapshotId,
            manifestBytes: encoded.manifestBytes,
            objects: encoded.objects,
            resources: archive.portableResources
        )
        var ledger = discovered
        if ledger.state == .discovered {
            ledger = try await store.recordMigrationBackupExported(
                migrationID: migrationID,
                exportBackupMarker: "export:\(inventory.sourceDigest)",
                evidenceBytes: inventory.registryEvidence
            )
        }
        if ledger.state == .backupExported || ledger.state == .staged {
            ledger = try await store.stageMigration(staging)
        }
        if ledger.state == .quarantined {
            return MigrationRunResult(inventory: inventory, state: .quarantined, noChanges: false, quarantineReason: "alreadyQuarantined")
        }
        if ledger.state == .committed {
            guard let account = options.account,
                  account.candidates.count <= 1,
                  account.knownAccountIDs.contains(account.binding.accountID),
                  let verifiedMarker = options.verifiedMarker, !verifiedMarker.isEmpty else {
                throw MigrationError.accountRequired
            }
            let authority = try requireAuthority(initialAuthority)
            _ = try await revalidatedArchive(
                sourceURL: options.sourceURL,
                initial: archive,
                initialAttestation: initialStageAttestation,
                authority: authority
            )
            try await finalCommitHook?()
            try revalidateTrustedProvenance(options, initial: authority, sourceURL: options.sourceURL)
            let replay = try await store.commitMigration(
                V2MigrationCommitRequest(
                    staging: staging,
                    binding: account.binding,
                    expectedSourceDigest: Data(hex: inventory.sourceDigest),
                    verifiedMarker: verifiedMarker,
                    document: model.document,
                    documentCreatedAt: model.documentCreatedAt
                )
            )
            return MigrationRunResult(inventory: inventory, state: .committed, noChanges: replay.noChanges)
        }
        let invalidReason: String? = if options.account == nil {
            "accountRequired"
        } else if let account = options.account,
                  account.binding.accountID.isEmpty || account.binding.accountFence.isEmpty
                  || account.binding.serverInstanceID.isEmpty || account.binding.protocolEpoch <= 0 {
            "invalidAccountBinding"
        } else if options.account?.candidates.count ?? 0 > 1 {
            "ambiguousAccount"
        } else if let account = options.account, !account.knownAccountIDs.contains(account.binding.accountID) {
            "unknownAccount"
        } else if options.verifiedMarker?.isEmpty != false {
            "commitRequiresVerifiedMarker"
        } else {
            nil
        }
        if let invalidReason {
            let quarantined = try await store.quarantineMigration(migrationID: migrationID, reason: invalidReason, evidenceBytes: inventory.registryEvidence)
            return MigrationRunResult(inventory: inventory, state: quarantined.state, noChanges: false, quarantineReason: invalidReason)
        }
        guard let account = options.account, let verifiedMarker = options.verifiedMarker else {
            throw MigrationError.accountRequired
        }
        ledger = try await store.verifyMigration(
            migrationID: migrationID,
            accountID: account.binding.accountID,
            evidenceBytes: inventory.registryEvidence
        )

        // Re-read both the package and the external authority immediately
        // before the SQLite transaction. Stage report bytes are not an
        // authority; a package, report, or authority changed during this run
        // must never be adopted from the bytes read earlier.
        let authority = try requireAuthority(initialAuthority)
        _ = try await revalidatedArchive(
            sourceURL: options.sourceURL,
            initial: archive,
            initialAttestation: initialStageAttestation,
            authority: authority
        )
        try await finalCommitHook?()
        try revalidateTrustedProvenance(options, initial: authority, sourceURL: options.sourceURL)
        let result = try await store.commitMigration(
            V2MigrationCommitRequest(
                staging: staging,
                binding: account.binding,
                expectedSourceDigest: Data(hex: inventory.sourceDigest),
                verifiedMarker: verifiedMarker,
                document: model.document,
                documentCreatedAt: model.documentCreatedAt
            )
        )
        _ = ledger
        return MigrationRunResult(inventory: inventory, state: .committed, noChanges: result.noChanges)
    }

    private func revalidatedArchive(
        sourceURL: URL,
        initial: ArchiveReadResult,
        initialAttestation: VerifiedExportStageAttestation?,
        authority: LoadedTrustedProvenance
    ) async throws -> ArchiveReadResult {
        guard let initialAttestation else {
            throw MigrationError.untrustedExportStage("missingInitialAttestation")
        }
        let workID = try WorkID(uuidString: initial.inventory.workID)
        let final = try await reader.inventoryAsync(
            sourceURL: sourceURL,
            proposedWorkID: workID
        )
        guard final.inventory.sourceDigest == initial.inventory.sourceDigest,
              final.inventory.workID == initial.inventory.workID,
              final.inventory.documentID == initial.inventory.documentID,
              final.encoded.manifestBytes == initial.encoded.manifestBytes,
              final.encoded.objects == initial.encoded.objects,
              final.model.document == initial.model.document,
              final.model.documentCreatedAt == initial.model.documentCreatedAt,
              try attestVerifiedExportStage(sourceURL: sourceURL, archive: final, authority: authority) == initialAttestation else {
            throw MigrationError.sourceChangedDuringRead
        }
        return final
    }

    private func attestVerifiedExportStage(
        sourceURL: URL,
        archive: ArchiveReadResult,
        authority: LoadedTrustedProvenance
    ) throws -> VerifiedExportStageAttestation {
        let fileManager = FileManager.default
        let package = sourceURL.standardizedFileURL
        let packageParent = package.deletingLastPathComponent()
        let stageRoot = packageParent.deletingLastPathComponent()
        guard package.pathExtension == "novelpkg",
              packageParent.lastPathComponent == "verified",
              isSafePath(package), isSafePath(stageRoot) else {
            throw MigrationError.untrustedExportStage("packagePath")
        }

        let reportURL = stageRoot.appendingPathComponent("migration-ledger.json")
        let runURL = stageRoot.appendingPathComponent("migration-run.json")
        let markerURL = stageRoot.appendingPathComponent("COMMITTED")
        let reportData = try trustedRegularFile(reportURL, fileManager: fileManager)
        let runData = try trustedRegularFile(runURL, fileManager: fileManager)
        let markerData = try trustedRegularFile(markerURL, fileManager: fileManager)
        guard markerData == Data("COMMITTED\n".utf8) else {
            throw MigrationError.untrustedExportStage("committedMarker")
        }
        let report = try decode(VerifiedExportReport.self, data: reportData, reason: "ledger")
        let run = try decode(VerifiedRunState.self, data: runData, reason: "runState")
        guard report.formatVersion == 1,
              run.status == "committed",
              run.exportID == report.exportID,
              isDigest(report.sourceSQLiteSHA256),
              isDigest(report.sourceArchiveManifestSHA256),
              isDigest(report.classificationLedgerSHA256),
              run.sourceDigest == report.sourceSQLiteSHA256,
              run.archiveManifestDigest == report.sourceArchiveManifestSHA256,
              run.classificationLedgerDigest == report.classificationLedgerSHA256 else {
            throw MigrationError.exportProvenanceMismatch("runOrLedger")
        }

        guard report.sourceSQLiteSHA256 == authority.authority.sourceSQLiteSHA256,
              report.sourceArchiveManifestSHA256 == authority.authority.sourceArchiveManifestSHA256,
              report.classificationLedgerSHA256 == authority.authority.classificationLedgerSHA256 else {
            throw MigrationError.exportProvenanceMismatch("externalAuthority")
        }

        let logicalWorkID = try WorkID(uuidString: archive.inventory.workID)
        guard let entry = report.entries.first(where: { $0.workID.uuidString.lowercased() == logicalWorkID.description }),
              entry.disposition == "verified",
              entry.outcome == "exported",
              entry.outputRelativePath == "verified/\(entry.workID.uuidString).novelpkg",
              entry.outputRelativePath == package.path.replacingOccurrences(of: stageRoot.path + "/", with: ""),
              entry.snapshotID.map(isDigest) == true,
              entry.projectionDigest.map(isDigest) == true,
              report.entries.count(where: { $0.workID == entry.workID }) == 1 else {
            throw MigrationError.exportProvenanceMismatch("verifiedEntry")
        }
        guard logicalWorkID.description == entry.workID.uuidString.lowercased() else {
            throw MigrationError.exportProvenanceMismatch("workID")
        }
        let evidenceDigest = try inventoryEvidenceDigest(archive.inventory)
        guard let trustedEntry = authority.authority.entries.first(where: { $0.workID == entry.workID }),
              authority.authority.entries.count(where: { $0.workID == entry.workID }) == 1,
              trustedEntry.disposition == "verified",
              trustedEntry.packageSHA256 == archive.inventory.sourceDigest,
              trustedEntry.sourceSQLiteSHA256 == authority.authority.sourceSQLiteSHA256,
              trustedEntry.sourceArchiveManifestSHA256 == authority.authority.sourceArchiveManifestSHA256,
              trustedEntry.classificationLedgerSHA256 == authority.authority.classificationLedgerSHA256,
              entry.snapshotID == archive.encoded.snapshotId.description,
              entry.projectionDigest != nil,
              trustedEntry.snapshotID == entry.snapshotID,
              trustedEntry.projectionDigest == entry.projectionDigest,
              trustedEntry.inventoryEvidenceSHA256 == evidenceDigest else {
            throw MigrationError.exportProvenanceMismatch("externalAuthorityEntry")
        }

        let stateURL = stageRoot.appendingPathComponent(".state/\(entry.workID.uuidString).json")
        let stateData = try trustedRegularFile(stateURL, fileManager: fileManager)
        let state = try decode(VerifiedProjectionState.self, data: stateData, reason: "sidecar")
        guard state.sourceDigest == report.sourceSQLiteSHA256,
              state.snapshotID == entry.snapshotID,
              state.projectionDigest == entry.projectionDigest else {
            throw MigrationError.exportProvenanceMismatch("sidecar")
        }

        let projection = try SHA256Digest.hex(
            WorkCanonicalJSON.encodeSnapshot(WorkSnapshot(document: archive.model.document))
        )
        guard projection == entry.projectionDigest else {
            throw MigrationError.exportProvenanceMismatch("packageProjection")
        }
        return VerifiedExportStageAttestation(
            exportID: report.exportID,
            workID: entry.workID,
            sourceSQLiteDigest: report.sourceSQLiteSHA256,
            archiveManifestDigest: report.sourceArchiveManifestSHA256,
            classificationDigest: report.classificationLedgerSHA256,
            reportDigest: SHA256Digest.hex(reportData),
            runDigest: SHA256Digest.hex(runData),
            markerDigest: SHA256Digest.hex(markerData),
            sidecarDigest: SHA256Digest.hex(stateData)
        )
    }

    private func requireAuthority(_ authority: LoadedTrustedProvenance?) throws -> LoadedTrustedProvenance {
        guard let authority else { throw MigrationError.untrustedExportStage("missingTrustedAuthority") }
        return authority
    }

    private func loadTrustedProvenance(
        _ options: MigrationOptions,
        sourceURL: URL
    ) throws -> LoadedTrustedProvenance {
        guard let rootURL = options.trustedAuthorityRootURL,
              let authorityURL = options.trustedAuthorityURL,
              let expectedDigest = options.expectedAuthorityDigest,
              let expectedID = options.expectedAuthorityID,
              isDigest(expectedDigest), !expectedID.isEmpty else {
            throw MigrationError.untrustedExportStage("missingTrustedAuthority")
        }
        let stageRoot = sourceURL.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let targetPath = options.targetRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = try trustedAuthorityRootPath(rootURL)
        let authorityPath = try trustedAuthorityFilePath(authorityURL, rootPath: rootPath)
        guard !pathsOverlap(rootPath, stageRoot.resolvingSymlinksInPath().standardizedFileURL.path),
              !pathsOverlap(rootPath, targetPath),
              !pathsOverlap(authorityPath, sourceURL.resolvingSymlinksInPath().standardizedFileURL.path) else {
            throw MigrationError.untrustedExportStage("authorityOverlapsMigration")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: authorityPath), options: [.mappedIfSafe])
        let canonical = try canonicalJSON(data)
        guard data == canonical, SHA256Digest.hex(canonical) == expectedDigest else {
            throw MigrationError.exportProvenanceMismatch("authorityDigest")
        }
        let authority: MigrationTrustedProvenanceAuthority
        do {
            authority = try JSONDecoder().decode(MigrationTrustedProvenanceAuthority.self, from: canonical)
        } catch {
            throw MigrationError.exportProvenanceMismatch("authoritySchema")
        }
        guard authority.formatVersion == 1,
              authority.authorityID == expectedID,
              isDigest(authority.sourceSQLiteSHA256),
              isDigest(authority.sourceArchiveManifestSHA256),
              isDigest(authority.classificationLedgerSHA256),
              !authority.entries.isEmpty,
              Set(authority.entries.map(\.workID)).count == authority.entries.count,
              authority.entries.allSatisfy({
                  isDigest($0.packageSHA256) && isDigest($0.sourceSQLiteSHA256)
                      && isDigest($0.sourceArchiveManifestSHA256) && isDigest($0.classificationLedgerSHA256)
                      && isDigest($0.inventoryEvidenceSHA256)
                      && isDigest($0.snapshotID ?? "")
                      && isDigest($0.projectionDigest ?? "")
              }) else {
            throw MigrationError.exportProvenanceMismatch("authorityFields")
        }
        return LoadedTrustedProvenance(authority: authority, canonicalData: canonical, digest: expectedDigest)
    }

    private func revalidateTrustedProvenance(
        _ options: MigrationOptions,
        initial: LoadedTrustedProvenance,
        sourceURL: URL
    ) throws {
        let current = try loadTrustedProvenance(options, sourceURL: sourceURL)
        guard current == initial else { throw MigrationError.sourceChangedDuringRead }
    }

    private func trustedAuthorityRootPath(_ url: URL) throws -> String {
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard standardized.path == resolved.path else { throw MigrationError.untrustedExportStage("authorityRootSymlink") }
        let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MigrationError.untrustedExportStage("authorityRoot")
        }
        return resolved.path
    }

    private func trustedAuthorityFilePath(_ url: URL, rootPath: String) throws -> String {
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard standardized.path == resolved.path,
              resolved.path.hasPrefix(rootPath + "/") else {
            throw MigrationError.untrustedExportStage("authorityPath")
        }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MigrationError.untrustedExportStage("authorityFile")
        }
        return resolved.path
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              JSONSerialization.isValidJSONObject(object) else {
            throw MigrationError.exportProvenanceMismatch("authorityJSON")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func inventoryEvidenceDigest(_ inventory: SourceInventory) throws -> String {
        guard var object = try JSONSerialization.jsonObject(with: inventory.registryEvidence) as? [String: Any] else {
            throw MigrationError.exportProvenanceMismatch("inventoryEvidence")
        }
        object.removeValue(forKey: "sourcePath")
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return SHA256Digest.hex(canonical)
    }

    private func trustedRegularFile(_ url: URL, fileManager: FileManager) throws -> Data {
        guard isSafePath(url), fileManager.fileExists(atPath: url.path) else {
            throw MigrationError.untrustedExportStage("missing:\(url.lastPathComponent)")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MigrationError.untrustedExportStage("unsafe:\(url.lastPathComponent)")
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func isSafePath(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        return standardized.path == url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data, reason: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MigrationError.exportProvenanceMismatch("\(reason):\(error)")
        }
    }

    private func validateTargetRoot(_ target: URL, sourceURL: URL) throws {
        guard target.isFileURL else { throw MigrationError.invalidTarget("notFileURL") }
        let targetPath = target.resolvingSymlinksInPath().standardizedFileURL.path
        let sourcePath = sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
        if targetPath == sourcePath || targetPath.hasPrefix(sourcePath + "/") || sourcePath.hasPrefix(targetPath + "/") {
            throw MigrationError.targetOverlapsSource
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .standardizedFileURL.path
        if targetPath == support || targetPath.hasPrefix(support + "/") {
            throw MigrationError.productionRootRejected
        }
        var cursor = target
        while cursor.path != "/" {
            if !["/var", "/tmp"].contains(cursor.path),
               FileManager.default.fileExists(atPath: cursor.path),
               try cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw MigrationError.invalidTarget("symlink")
            }
            cursor.deleteLastPathComponent()
        }
    }
}

private struct SourceManifest: Decodable {
    let formatVersion: String
    let documentID: String
    let title: String
    let chapters: [SourceChapter]
    let createdAt: String
    let updatedAt: String
}

private struct SourceChapter: Decodable {
    let id: UUID
    let title: String
    let episodes: [SourceEpisode]?
}

private struct SourceEpisode: Decodable {
    let id: UUID
    let title: String
}

private struct SourceFile {
    let path: String
    let data: Data
    let isDirectory: Bool
}

private extension ArchiveReader {
    func validateSourceRoot(_ url: URL) throws {
        guard url.isFileURL else { throw MigrationError.invalidSource("notFileURL") }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw MigrationError.invalidSource("packageMissing")
        }
        var cursor = url
        while cursor.path != "/" {
            if !["/var", "/tmp"].contains(cursor.path),
               try cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw MigrationError.invalidSource("symlink")
            }
            cursor.deleteLastPathComponent()
        }
    }

    func readFiles(_ root: URL) throws -> [SourceFile] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let rootPath = root.standardizedFileURL.path
        let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [])
        var result: [SourceFile] = []
        var normalizedPaths: Set<String> = []
        while let url = urls?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                throw MigrationError.invalidSource("symlink:\(url.lastPathComponent)")
            }
            let relative = url.standardizedFileURL.path.replacingOccurrences(of: rootPath + "/", with: "")
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !relative.hasPrefix("/"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw MigrationError.invalidSource("pathNormalization")
            }
            let folded = relative.precomposedStringWithCanonicalMapping.lowercased()
            guard normalizedPaths.insert(folded).inserted else {
                throw MigrationError.invalidSource("pathCollision")
            }
            if values.isDirectory == true {
                result.append(SourceFile(path: relative, data: Data(), isDirectory: true))
                continue
            }
            guard values.isRegularFile == true else { throw MigrationError.invalidSource("nonRegularFile") }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            if relative == "manifest.json" || relative.hasSuffix(".json") || relative.hasSuffix(".md") {
                guard String(data: data, encoding: .utf8) != nil else {
                    throw MigrationError.invalidSource("invalidUTF8:\(relative)")
                }
            }
            result.append(SourceFile(path: relative, data: data, isDirectory: false))
        }
        return result.sorted { $0.path < $1.path }
    }

    func decodeManifest(_ data: Data) throws -> SourceManifest {
        do {
            let value = try JSONDecoder().decode(SourceManifest.self, from: data)
            guard ["1", "2", "3"].contains(value.formatVersion) else {
                throw MigrationError.invalidSource("manifestSchema")
            }
            guard UUID(uuidString: value.documentID) != nil else {
                throw MigrationError.invalidSource("manifestDocumentID")
            }
            _ = value.title
            _ = value.updatedAt
            return value
        } catch let error as MigrationError {
            throw error
        } catch {
            throw MigrationError.invalidSource("manifestSchema:\(error)")
        }
    }

    func parseCreatedAt(_ string: String) throws -> Date {
        let formatter = makeISO8601()
        guard let date = formatter.date(from: string) ?? makeISO8601WithoutFraction().date(from: string) else {
            throw MigrationError.invalidCreatedAt
        }
        return date
    }

    func readAttachments(_ root: URL, sourceDigest: Data) throws -> [SyncAttachment] {
        let directory = root.appendingPathComponent("attachments", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        return try entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw MigrationError.invalidSource("attachment") }
            let bytes = try Data(contentsOf: url)
            var identity = sourceDigest
            identity.append(contentsOf: Data("attachments/\(url.lastPathComponent)".utf8))
            return SyncAttachment(attachmentId: deterministicUUID(identity), fileName: url.lastPathComponent, bytes: bytes)
        }
    }

    func digest(files: [SourceFile]) -> Data {
        var bytes = Data()
        for file in files {
            let path = Data(file.path.utf8)
            bytes.append(file.isDirectory ? 0x44 : 0x46)
            var pathCount = UInt64(path.count).bigEndian
            var dataCount = UInt64(file.data.count).bigEndian
            withUnsafeBytes(of: &pathCount) { bytes.append(contentsOf: $0) }
            bytes.append(path)
            withUnsafeBytes(of: &dataCount) { bytes.append(contentsOf: $0) }
            bytes.append(file.data)
        }
        return Data(hex: SHA256Digest.hex(bytes))
    }

    func digestRoot(_ root: URL) throws -> Data {
        try digest(files: readFiles(root))
    }

    func evidenceBytes(sourceURL: URL, sourceDigest: Data, manifest: SourceManifest, files: [SourceFile], workID: WorkID, encoded: EncodedSnapshot, resources: [MigrationPortableResource]) throws -> Data {
        let value: [String: Any] = [
            "sourceKind": "novelpkg", "sourcePath": sourceURL.standardizedFileURL.path,
            "sourceDigest": sourceDigest.hex, "workId": workID.description,
            "documentId": manifest.documentID,
            "createdAt": manifest.createdAt, "fileCount": files.count,
            "byteCount": files.reduce(0) { $0 + $1.data.count },
            "snapshotId": encoded.snapshotId.description,
            "objectCount": encoded.objects.count,
            "portableResourceCount": resources.count,
            "portableResources": resources.map { ["path": $0.path, "kind": $0.kind, "byteCount": $0.byteCount, "digest": $0.digest, "objectID": $0.objectID as Any, "emptyDirectory": $0.emptyDirectory] }
        ]
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    func deterministicWorkID(sourceDigest: Data) -> WorkID {
        var raw = Array(sourceDigest.prefix(16))
        raw[6] = (raw[6] & 0x0F) | 0x50
        raw[8] = (raw[8] & 0x3F) | 0x80
        return WorkID(rawValue: UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15])))
    }
}

private func makeISO8601() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime, .withFractionalSeconds]
    return formatter
}

private func makeISO8601WithoutFraction() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
    return formatter
}

private extension Data {
    init(hex: String) {
        self.init((0 ..< hex.count / 2).compactMap { index in
            let start = hex.index(hex.startIndex, offsetBy: index * 2)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start ..< end], radix: 16)
        })
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private func deterministicUUID(_ data: Data) -> UUID {
    let digest = Data(hex: SHA256Digest.hex(data))
    var raw = Array(digest.prefix(16))
    raw[6] = (raw[6] & 0x0F) | 0x50
    raw[8] = (raw[8] & 0x3F) | 0x80
    return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
}
