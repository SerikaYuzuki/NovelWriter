import Foundation
import NovelSyncV2

public extension SyncV2Application {
    /// Explicitly copies an unbound local Work into the active account.  The
    /// source remains untouched; only the new bound Work enters the outbox.
    func cloneWorkIntoActiveAccount(
        sourceWorkID: WorkID,
        newWorkID: WorkID = WorkID(UUID()),
        newDocumentID: DocumentID = DocumentID(UUID())
    ) async throws -> SyncV2ExplicitAccountClone {
        guard runtimeIdentity != .preview else { throw SyncV2ApplicationError.previewReadOnly }
        let result = try await kernel.prepareExplicitAccountClone(
            sourceWorkID: sourceWorkID,
            newWorkID: newWorkID,
            newDocumentID: newDocumentID
        )
        scheduleWorker(for: result.newWorkID)
        return result
    }
}
