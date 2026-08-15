import Foundation

/// Episode wire / Work wire とは独立してversionを進めるメモ型entity同期protocol。
public enum NoteSyncWireProtocol {
    public static let currentVersion = 1
}

func requireCurrentNoteSyncWireVersion<Key: CodingKey>(
    forKey key: Key,
    in container: KeyedDecodingContainer<Key>
) throws {
    let version = try container.decode(Int.self, forKey: key)
    guard version == NoteSyncWireProtocol.currentVersion else {
        throw SyncWireError.unsupportedProtocolVersion(version)
    }
}
