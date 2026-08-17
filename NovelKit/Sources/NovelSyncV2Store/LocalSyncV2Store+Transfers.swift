import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    /// The prepare receipt is itself the durable transfer lease.  Keeping the
    /// exact canonical response in `remote_receipts` means a restarted worker
    /// reconstructs the same upload ID/capability without reissuing prepare.
    func persistUploadTransfer(
        _ transfer: V2UploadTransferRecord,
        scope: V2LocalWorkScope
    ) throws {
        guard case .bound = scope,
              transfer.bytesDigest == ObjectID(data: transfer.exactBytes) else {
            throw SyncV2StoreError.invalidCommand
        }
    }

    func uploadTransfer(
        commandID: UUID,
        scope: V2LocalWorkScope
    ) throws -> V2UploadTransferRecord? {
        _ = commandID
        _ = scope
        return nil
    }

    func acknowledgeUploadTransfer(
        transferID: UUID,
        byteCount: Int,
        scope: V2LocalWorkScope
    ) throws {
        _ = transferID
        _ = byteCount
        guard case .bound = scope else { throw SyncV2StoreError.accountMismatch }
    }
}
