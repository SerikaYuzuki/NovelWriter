import Foundation
import NovelCore
import NovelSyncV2

public enum V2MigrationLedgerState: String, Codable, Sendable {
    case discovered
    case backupExported
    case staged
    case verified
    case committed
    case quarantined
}

public struct V2MigrationLedgerEntry: Equatable, Sendable {
    public let migrationID: UUID
    public let accountID: String?
    public let sourceKind: String
    public let sourceDigest: Data
    public let exportBackupMarker: String?
    public let adoptionMarker: String?
    public let quarantinedFromState: V2MigrationLedgerState?
    public let evidenceBytes: Data
    public let state: V2MigrationLedgerState

    public init(
        migrationID: UUID,
        accountID: String?,
        sourceKind: String,
        sourceDigest: Data,
        exportBackupMarker: String?,
        adoptionMarker: String?,
        quarantinedFromState: V2MigrationLedgerState?,
        evidenceBytes: Data,
        state: V2MigrationLedgerState
    ) {
        self.migrationID = migrationID
        self.accountID = accountID
        self.sourceKind = sourceKind
        self.sourceDigest = sourceDigest
        self.exportBackupMarker = exportBackupMarker
        self.adoptionMarker = adoptionMarker
        self.quarantinedFromState = quarantinedFromState
        self.evidenceBytes = evidenceBytes
        self.state = state
    }
}

public struct V2MigrationStagingInput: Sendable {
    public let migrationID: UUID
    public let proposedWorkID: WorkID
    public let proposedDocumentID: DocumentID
    public let snapshotID: SnapshotID
    public let manifestBytes: Data
    public let objects: [ObjectID: Data]
    public let resources: [PortableResource]

    public init(
        migrationID: UUID,
        proposedWorkID: WorkID,
        proposedDocumentID: DocumentID,
        snapshotID: SnapshotID,
        manifestBytes: Data,
        objects: [ObjectID: Data],
        resources: [PortableResource] = []
    ) {
        self.migrationID = migrationID
        self.proposedWorkID = proposedWorkID
        self.proposedDocumentID = proposedDocumentID
        self.snapshotID = snapshotID
        self.manifestBytes = manifestBytes
        self.objects = objects
        self.resources = resources
    }
}

public struct V2MigrationCommitRequest: Sendable {
    public let staging: V2MigrationStagingInput
    public let binding: V2AccountBinding
    public let expectedSourceDigest: Data
    public let verifiedMarker: String
    public let document: NovelDocument
    public let documentCreatedAt: Date

    public init(
        staging: V2MigrationStagingInput,
        binding: V2AccountBinding,
        expectedSourceDigest: Data,
        verifiedMarker: String,
        document: NovelDocument,
        documentCreatedAt: Date
    ) {
        self.staging = staging
        self.binding = binding
        self.expectedSourceDigest = expectedSourceDigest
        self.verifiedMarker = verifiedMarker
        self.document = document
        self.documentCreatedAt = documentCreatedAt
    }
}

public struct V2MigrationCommitResult: Sendable {
    public let workID: WorkID
    public let snapshotID: SnapshotID
    public let noChanges: Bool

    public init(workID: WorkID, snapshotID: SnapshotID, noChanges: Bool) {
        self.workID = workID
        self.snapshotID = snapshotID
        self.noChanges = noChanges
    }
}
