import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import NovelSyncV2Store
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
        let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .openExisting)
        let planner = ProductionSyncV2Planner(
            store: store, scope: TestScopeResolver(vault: configuration.vault, store: store)
        )
        guard case .idle = try await planner.nextCommand(workID: workID) else {
            Issue.record("local-only work incorrectly requires authentication")
            return
        }
        #expect(try await store.pendingIntents(scope: .unbound, workID: workID).count == 1)
        await store.close()
        let library = try await app.library()
        #expect(library.items.first(where: { $0.workID == workID })?.accountState == .unbound)
    }
}

@Test("signed-in account does not turn a local-only work into an auth failure")
func signedInLocalOnlyWorkHasNoRemotePlan() async throws {
    let configuration = try TestRuntimeConfiguration()
    let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .createNew)
    let workID = WorkID(UUID())
    _ = try await store.checkpoint(V2CheckpointRequest(
        workID: workID, document: applicationTestDocument(title: "端末だけ"),
        documentCreatedAt: applicationTestCreatedAt, expectedGeneration: 0, reason: .explicit
    ), scope: .unbound)
    let planner = ProductionSyncV2Planner(
        store: store, scope: TestScopeResolver(vault: configuration.vault, store: store)
    )
    guard case .idle = try await planner.nextCommand(workID: workID) else {
        Issue.record("signed-in account incorrectly schedules a local-only work")
        return
    }
    #expect(try await store.pendingIntents(scope: .unbound, workID: workID).count == 1)
    await store.close()
}
