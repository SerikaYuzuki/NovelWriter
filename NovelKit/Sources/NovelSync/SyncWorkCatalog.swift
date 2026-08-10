import Foundation

/// `.novelpkg`由来情報はdiscovery hintに限り、remote identityは`workID`だけを正とする。
public struct SyncWorkDescriptor: Hashable, Codable, Sendable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case workID
        case sourceDocumentID
        case structureDigest
        case title
    }

    public var id: SyncWorkID {
        workID
    }

    public let workID: SyncWorkID
    public let sourceDocumentID: UUID
    public let structureDigest: SyncWorkStructureDigest
    public var title: String

    public init(
        workID: SyncWorkID = SyncWorkID(),
        sourceDocumentID: UUID,
        structureDigest: SyncWorkStructureDigest,
        title: String
    ) {
        self.workID = workID
        self.sourceDocumentID = sourceDocumentID
        self.structureDigest = structureDigest
        self.title = title
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try requireCurrentSyncWireVersion(forKey: .protocolVersion, in: container)
        workID = try container.decode(SyncWorkID.self, forKey: .workID)
        sourceDocumentID = try decodeCanonicalSyncUUID(forKey: .sourceDocumentID, in: container)
        structureDigest = try container.decode(SyncWorkStructureDigest.self, forKey: .structureDigest)
        title = try container.decode(String.self, forKey: .title)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(SyncWireProtocol.currentVersion, forKey: .protocolVersion)
        try container.encode(workID, forKey: .workID)
        try container.encode(sourceDocumentID.uuidString, forKey: .sourceDocumentID)
        try container.encode(structureDigest, forKey: .structureDigest)
        try container.encode(title, forKey: .title)
    }
}

/// 端末内の作業コピーidentity。package basename等を呼び出し側が安定した文字列へ写像する。
/// pathそのものを同期先へ送らない。
public struct LocalWorkingCopyID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }

    public var description: String {
        rawValue.uuidString
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decodeCanonicalSyncUUID(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeCanonicalSyncUUID(rawValue, to: encoder)
    }
}

/// 明示選択後にだけ端末内へ保存するbinding。source document IDの一致から自動生成しない。
public struct SyncWorkingCopyBinding: Hashable, Codable, Sendable {
    public let localWorkingCopyID: LocalWorkingCopyID
    public let workID: SyncWorkID

    public init(localWorkingCopyID: LocalWorkingCopyID, workID: SyncWorkID) {
        self.localWorkingCopyID = localWorkingCopyID
        self.workID = workID
    }
}

public enum SyncCatalogError: Error, Equatable, Sendable {
    case duplicateWorkID
}

/// discovery用catalog。`sourceDocumentID`が同じdescriptorを複数返してよい。
/// どれへlinkするかはUIで利用者が明示選択し、transportは自動統合しない。
public protocol SyncWorkCatalog: Sendable {
    func createWork(_ descriptor: SyncWorkDescriptor) async throws
    func listWorks() async throws -> [SyncWorkDescriptor]
}
