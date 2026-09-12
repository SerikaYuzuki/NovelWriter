import Foundation
import NovelSyncV2

public extension SyncV2Application {
    /// Metadata-only local edit. The captured generation prevents a newer
    /// checkpoint or adoption from being replaced by the shelf's read.
    /// Callers serialize active-editor saves before entering this boundary.
    func renameLocalWork(workID: WorkID, title: String) async throws -> SyncV2OperationResult {
        guard runtimeIdentity != .preview else { throw SyncV2ApplicationError.previewReadOnly }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw SyncV2ApplicationError.safeBoundaryRejected }
        let opened = try await kernel.open(workID: workID)
        guard var document = opened.document else { throw SyncV2ApplicationError.safeBoundaryRejected }
        document.title = title
        let local = try await kernel.checkpoint(SyncV2CheckpointCapture(
            workID: workID,
            document: document,
            documentCreatedAt: opened.documentCreatedAt,
            expectedGeneration: opened.generation,
            reason: .explicit,
            attachments: opened.attachments,
            resources: opened.resources
        ))
        return try await finishCheckpoint(local, workID: workID)
    }
}
