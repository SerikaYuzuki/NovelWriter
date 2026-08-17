import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import Testing

@Suite("Snapshot Sync v2 unbound production work")
struct ProductionUnboundAttachmentTests {
    @Test("signed-out production checkpoints an unbound work with attachments")
    func signedOutUnboundCheckpointRoundTripsAttachments() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let workID = WorkID(UUID())
        let document = applicationTestDocument(title: "端末だけの作品")
        let attachment = SyncAttachment(
            attachmentId: UUID(),
            fileName: "資料.txt",
            bytes: Data("添付本文".utf8)
        )

        let checkpoint = try await app.checkpoint(
            workID: workID,
            document: document,
            reason: .autosave,
            documentCreatedAt: applicationTestCreatedAt,
            attachments: [attachment]
        )
        #expect(checkpoint.typedResult == .checkpointed)
        let opened = try await app.open(workID: workID)
        #expect(opened.document == document)
        #expect(opened.attachments == [attachment])
        let library = try await app.library()
        #expect(library.items.first(where: { $0.workID == workID })?.accountState == .unbound)
    }
}
