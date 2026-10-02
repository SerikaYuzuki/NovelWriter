import Foundation
import NovelCore
import NovelSyncV2

enum StoreValueCoding {}

extension StoreValueCoding {
    static func now() -> String {
        (try? iso8601(Date())) ?? "1970-01-01T00:00:00Z"
    }
}

extension StoreValueCoding {
    static func iso8601(_ date: Date) throws -> String {
        CanonicalTimestamp.string(date)
    }
}

extension StoreValueCoding {
    static func head(snapshot: Data?, generation: Int64?) throws -> V2RemoteHead? {
        guard let snapshot, let generation else { return nil }
        return try V2RemoteHead(
            snapshotID: SnapshotID(rawValue: snapshot.hexString),
            generation: generation
        )
    }
}

extension SyncV2CommandPayload {
    func remoteHead(_ key: String) throws -> V2RemoteHead? {
        try head(key).map { try V2RemoteHead(snapshotID: $0.snapshotID, generation: $0.generation) }
    }
}

extension Data {
    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
