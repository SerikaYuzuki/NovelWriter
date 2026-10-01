import Foundation
import NovelSyncV2
import NovelThumbnail

public extension SyncV2Application {
    /// Shelf presentation must not open an editing session or promote an autosave leaf.
    func localCoverThumbnail(workID: WorkID) async throws -> Data? {
        let scope = historyScopeGeneration
        let opened = try await kernel.open(workID: workID)
        guard scope == historyScopeGeneration, !Task.isCancelled else { return nil }
        guard let document = opened.document else { return nil }
        let name = ThumbnailOwner(.work, document.id).fileName
        return opened.attachments.first { $0.fileName == name }?.bytes
    }
}
