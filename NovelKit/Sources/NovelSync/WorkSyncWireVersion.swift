import Foundation

/// Episode wireとは独立してversionを進める作品全体同期protocol。
public enum WorkSyncWireProtocol {
    public static let currentVersion = 1
}

func requireCurrentWorkSyncWireVersion<Key: CodingKey>(
    forKey key: Key,
    in container: KeyedDecodingContainer<Key>
) throws {
    let version = try container.decode(Int.self, forKey: key)
    guard version == WorkSyncWireProtocol.currentVersion else {
        throw SyncWireError.unsupportedProtocolVersion(version)
    }
}
