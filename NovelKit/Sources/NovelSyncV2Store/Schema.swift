import Foundation
import NovelSyncV2

enum V2StoreSchema {
    static let version = "2"

    static func resourceSQL() throws -> Data {
        guard let url = Bundle.module.url(forResource: "sqlite", withExtension: "sql") else {
            throw SyncV2StoreError.schemaMismatch
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    static func checksum(_ sql: Data) -> Data {
        Data(hex: SHA256Digest.hex(sql))
    }
}

public enum SnapshotSyncV2SchemaContract {
    public static let version = V2StoreSchema.version

    public static func resourceSQL() throws -> Data {
        try V2StoreSchema.resourceSQL()
    }

    public static func checksum(_ sql: Data) -> Data {
        V2StoreSchema.checksum(sql)
    }
}

private extension Data {
    init(hex: String) {
        self.init((0 ..< hex.count / 2).map { index in
            let start = String.Index(utf16Offset: index * 2, in: hex)
            let end = String.Index(utf16Offset: index * 2 + 2, in: hex)
            return UInt8(String(hex[start ..< end]), radix: 16)!
        })
    }
}
