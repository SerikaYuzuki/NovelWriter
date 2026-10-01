import Foundation
@testable import NovelSyncV2Store

extension LocalSyncV2Store {
    func prepareLegacyRecoveryApplicationFixture() throws {
        let sql = try String(decoding: SnapshotSyncV2SchemaContract.resourceSQL(), as: UTF8.self)
        let old = Data(sql.components(separatedBy: "\n-- Legacy unexpected-command recovery (D-107).")[0].utf8)
        try inTransaction {
            try exec("DROP TABLE legacy_command_recovery")
            try exec("UPDATE schema_meta SET checksum=? WHERE key='schema'", [.blob(SnapshotSyncV2SchemaContract.checksum(old))])
        }
    }
}
