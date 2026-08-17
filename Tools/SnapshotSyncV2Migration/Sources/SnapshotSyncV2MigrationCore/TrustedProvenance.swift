import Foundation
import NovelSyncV2

/// Evidence produced outside the migration stage by the operator/export
/// authority.  The stage report is deliberately not an authority: it is only
/// an untrusted projection that must match this record exactly.
public struct MigrationTrustedProvenanceAuthority: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let authorityID: String
    public let sourceSQLiteSHA256: String
    public let sourceArchiveManifestSHA256: String
    public let classificationLedgerSHA256: String
    public let entries: [MigrationTrustedProvenanceEntry]
    public let provenanceVersion: Int

    public init(
        formatVersion: Int = 2,
        authorityID: String,
        sourceSQLiteSHA256: String,
        sourceArchiveManifestSHA256: String,
        classificationLedgerSHA256: String,
        entries: [MigrationTrustedProvenanceEntry],
        provenanceVersion: Int = 2
    ) {
        self.formatVersion = formatVersion
        self.authorityID = authorityID
        self.sourceSQLiteSHA256 = sourceSQLiteSHA256
        self.sourceArchiveManifestSHA256 = sourceArchiveManifestSHA256
        self.classificationLedgerSHA256 = classificationLedgerSHA256
        self.entries = entries
        self.provenanceVersion = provenanceVersion
    }
}

public struct MigrationTrustedProvenanceEntry: Codable, Equatable, Sendable {
    public let workID: UUID
    public let disposition: String
    public let packageSHA256: String
    public let sourceSQLiteSHA256: String
    public let sourceArchiveManifestSHA256: String
    public let classificationLedgerSHA256: String
    public let snapshotID: String?
    public let projectionDigest: String?
    public let inventoryEvidenceSHA256: String
    public let provenanceVersion: Int
    public let sourceWireSnapshotID: String?
    public let sourceWireSnapshotDigest: String?
    public let sourceProjectionDigest: String?
    public let sourceProjectionVersion: Int?
    public let adoptionSnapshotID: String?
    public let adoptionProjectionDigest: String?
    public let adoptionProjectionVersion: Int?
    public let sourceObjectClosureSHA256: String?
    public let classificationCreatedAt: String?
    public let classificationLocalGeneration: Int?
    public let classificationHeadSnapshotID: String?
    public let classificationHeadGeneration: Int?
    public let classificationEvidence: String?

    public init(
        workID: UUID,
        disposition: String,
        packageSHA256: String,
        sourceSQLiteSHA256: String,
        sourceArchiveManifestSHA256: String,
        classificationLedgerSHA256: String,
        snapshotID: String?,
        projectionDigest: String?,
        inventoryEvidenceSHA256: String,
        provenanceVersion: Int = 2,
        sourceWireSnapshotID: String? = nil,
        sourceWireSnapshotDigest: String? = nil,
        sourceProjectionDigest: String? = nil,
        sourceProjectionVersion: Int? = nil,
        adoptionSnapshotID: String? = nil,
        adoptionProjectionDigest: String? = nil,
        adoptionProjectionVersion: Int? = nil,
        sourceObjectClosureSHA256: String? = nil,
        classificationCreatedAt: String? = nil,
        classificationLocalGeneration: Int? = nil,
        classificationHeadSnapshotID: String? = nil,
        classificationHeadGeneration: Int? = nil,
        classificationEvidence: String? = nil
    ) {
        self.workID = workID
        self.disposition = disposition
        self.packageSHA256 = packageSHA256
        self.sourceSQLiteSHA256 = sourceSQLiteSHA256
        self.sourceArchiveManifestSHA256 = sourceArchiveManifestSHA256
        self.classificationLedgerSHA256 = classificationLedgerSHA256
        self.snapshotID = snapshotID
        self.projectionDigest = projectionDigest
        self.inventoryEvidenceSHA256 = inventoryEvidenceSHA256
        self.provenanceVersion = provenanceVersion
        self.sourceWireSnapshotID = sourceWireSnapshotID ?? snapshotID
        self.sourceWireSnapshotDigest = sourceWireSnapshotDigest ?? snapshotID
        self.sourceProjectionDigest = sourceProjectionDigest
        self.sourceProjectionVersion = sourceProjectionVersion
        self.adoptionSnapshotID = adoptionSnapshotID ?? snapshotID
        self.adoptionProjectionDigest = adoptionProjectionDigest ?? projectionDigest
        self.adoptionProjectionVersion = adoptionProjectionVersion
        self.sourceObjectClosureSHA256 = sourceObjectClosureSHA256
        self.classificationCreatedAt = classificationCreatedAt
        self.classificationLocalGeneration = classificationLocalGeneration
        self.classificationHeadSnapshotID = classificationHeadSnapshotID
        self.classificationHeadGeneration = classificationHeadGeneration
        self.classificationEvidence = classificationEvidence
    }
}

func migrationInventoryEvidenceDigest(_ inventory: SourceInventory) throws -> String {
    guard var object = try JSONSerialization.jsonObject(with: inventory.registryEvidence) as? [String: Any] else {
        throw TrustedProvenanceBuilderError.invalidInventoryEvidence
    }
    object.removeValue(forKey: "sourcePath")
    let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return SHA256Digest.hex(canonical)
}
