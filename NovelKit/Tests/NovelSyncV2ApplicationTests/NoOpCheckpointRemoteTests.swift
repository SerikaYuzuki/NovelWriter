import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
import NovelThumbnail
import Testing

struct NoOpCheckpointRemoteTests {
    @Test("an unchanged checkpoint with a pending offline intent never wakes the worker", arguments: [false, true])
    func noOpDoesNotRetryOfflineCommand(withThumbnail: Bool) async throws {
        let fixture = try await LeafRuntimeFixture.make()
        await fixture.configuration.remote.setCommandHandler(nil)
        var document = fixture.document
        document.title = "changed"
        let attachments: [SyncAttachment] = withThumbnail ? [
            .init(attachmentId: UUID(), fileName: ThumbnailOwner(.work, document.id).fileName, bytes: Data([1, 2]))
        ] : []
        _ = try await fixture.app.checkpoint(workID: fixture.workID, document: document, reason: .explicit,
                                             documentCreatedAt: applicationTestCreatedAt, attachments: attachments)
        try await leafEventually {
            let offline = await fixture.app.uiState(workID: fixture.workID)?.remoteProgress == .offline
            let stopped = await fixture.app.workerTasks[fixture.workID] == nil
            return offline && stopped
        }
        let before = await fixture.configuration.remote.recordedOperations().count
        let wakeBefore = await fixture.app.wakeEpochs[fixture.workID]
        #expect(before > 0)
        for reason in [SyncV2CheckpointReason.autosave, .explicit] {
            let result = try await fixture.app.checkpoint(workID: fixture.workID, document: document, reason: reason,
                                                          documentCreatedAt: applicationTestCreatedAt, attachments: attachments)
            #expect(result.typedResult == .noChanges)
            #expect(result.state.remoteProgress == .offline)
            try await fixture.app.promoteCheckpoint(workID: fixture.workID)
            #expect(await fixture.app.wakeEpochs[fixture.workID] == wakeBefore)
            #expect(await fixture.configuration.remote.recordedOperations().count == before)
        }
        await fixture.close()
    }

    @Test("an identical explicit checkpoint still publishes a newly promoted leaf")
    func unchangedContentPromotionWakesWorker() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        let document = try await fixture.edit("durable leaf")
        let result = try await fixture.app.checkpoint(workID: fixture.workID, document: document, reason: .explicit,
                                                      documentCreatedAt: applicationTestCreatedAt)
        #expect(result.typedResult == .noChanges)
        try await fixture.assertOnePublication(expected: document)
        await fixture.close()
    }
}
