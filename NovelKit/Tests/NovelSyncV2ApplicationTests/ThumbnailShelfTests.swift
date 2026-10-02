import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import NovelThumbnail
import Testing

@Test func shelfThumbnailReadDoesNotPromoteLeafOrContactRemote() async throws {
    let fixture = try await LeafRuntimeFixture.make()
    let document = try await fixture.edit("local leaf")
    let name = ThumbnailOwner(.work, document.id).fileName
    _ = try await fixture.app.checkpoint(workID: fixture.workID, document: document, reason: .autosave,
                                         documentCreatedAt: applicationTestCreatedAt,
                                         attachments: [.init(attachmentId: UUID(), fileName: name, bytes: Data([1, 2]))])
    let bytes = try await fixture.app.localCoverThumbnail(workID: fixture.workID)
    #expect(bytes == Data([1, 2]))
    #expect(try await fixture.store.pendingIntents(scope: productionScope, workID: fixture.workID).isEmpty)
    #expect(await fixture.configuration.remote.recordedOperations().isEmpty)
    await fixture.close()
}
