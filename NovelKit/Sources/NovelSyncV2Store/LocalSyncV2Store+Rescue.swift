import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    /// Explicit rescue never inherits an account binding or resumes an old outbox.
    func rescueLocalWork(
        sourceWorkID: WorkID, sourceScope: V2LocalWorkScope,
        newWorkID: WorkID, newDocumentID: DocumentID
    ) throws -> V2OpenResult {
        guard sourceWorkID != newWorkID, try !workExists(workID: newWorkID) else {
            throw SyncV2StoreError.staleCAS
        }
        let source = try open(workID: sourceWorkID, scope: sourceScope)
        guard var document = source.document else { throw SyncV2StoreError.workNotFound }
        document.id = newDocumentID.rawValue
        _ = try checkpoint(V2CheckpointRequest(
            workID: newWorkID, document: document, documentCreatedAt: source.documentCreatedAt,
            expectedGeneration: 0, attachments: source.attachments, resources: source.resources
        ), scope: .unbound)
        return try open(workID: newWorkID, scope: .unbound)
    }
}
