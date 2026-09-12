import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@Suite("Snapshot Sync v2 library rename")
struct LibraryRenameTests {
    @Test("rename checkpoints only the title and preserves the document identity and history")
    func renamePreservesDocument() async throws {
        let state = InMemorySyncV2RuntimeState(account: nil)
        let app = try applicationTestApp(state: state, remote: ApplicationTestRemote([]))
        let workID = WorkID(UUID())
        let original = applicationTestDocument(title: "元の作品", body: "本文を保持")
        _ = try await app.checkpoint(workID: workID, document: original, reason: .explicit,
                                     documentCreatedAt: applicationTestCreatedAt)
        let before = try await app.openLocal(workID: workID)
        _ = try await app.renameLocalWork(workID: workID, title: "  新しい作品名  ")
        let after = try await app.openLocal(workID: workID)
        var expected = original
        expected.title = "新しい作品名"
        #expect(after.document == expected)
        #expect(after.workID == before.workID)
        #expect(after.documentCreatedAt == before.documentCreatedAt)
        #expect(after.attachments == before.attachments)
        #expect(after.resources == before.resources)
        #expect(after.generation > before.generation)
        #expect(after.snapshotID != before.snapshotID)
        #expect(try await app.library().items.first?.title == "新しい作品名")
    }

    @Test("SQLite rename survives reopen and keeps attachments and portable resources")
    func durableRenamePreservesResources() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let workID = WorkID(UUID())
        let original = applicationTestDocument(title: "元の作品", body: "保存された本文")
        let attachment = SyncAttachment(attachmentId: UUID(), fileName: "資料.txt", bytes: Data("資料の本文".utf8))
        let resource = PortableResource(pathComponents: ["notes", "reference.txt"], kind: .regularFile, bytes: Data("保持する資料".utf8))
        _ = try await app.checkpoint(workID: workID, document: original, reason: .explicit,
                                     documentCreatedAt: applicationTestCreatedAt, attachments: [attachment], resources: [resource])
        let before = try await app.openLocal(workID: workID)
        _ = try await app.renameLocalWork(workID: workID, title: "新しい名前")
        let reopenedApp = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let reopened = try await reopenedApp.openLocal(workID: workID)
        var expected = original
        expected.title = "新しい名前"
        #expect(reopened.document == expected)
        #expect(reopened.attachments == before.attachments)
        #expect(reopened.resources == before.resources)
        #expect(reopened.documentCreatedAt == before.documentCreatedAt)
        #expect(try await reopenedApp.library().items.first { $0.workID == workID }?.title == "新しい名前")
    }

    @Test("remote-only work can be downloaded and renamed without changing its identity")
    func remoteOnlyRename() async throws {
        let state = InMemorySyncV2RuntimeState(account: TestAccount(accountID: "account", accountFence: "fence"))
        let app = try applicationTestApp(state: state, remote: ApplicationTestRemote([.failure(.offline)]))
        let workID = WorkID(UUID())
        let document = applicationTestDocument(title: "サーバーの作品")
        let inbox = try applicationTestInbox(workID: workID, document: document, currentSnapshotID: nil, localGeneration: 0)
        await state.addRemoteOnly(inbox)
        _ = try await app.open(workID: workID)
        _ = try await app.renameLocalWork(workID: workID, title: "新しい作品名")
        let renamed = try await app.openLocal(workID: workID)
        #expect(renamed.workID == workID)
        #expect(renamed.document?.id == document.id)
        #expect(renamed.document?.title == "新しい作品名")
        #expect(renamed.document?.chapters == document.chapters)
    }

    @Test("rename never creates a missing work or accepts a blank title")
    func invalidRenameDoesNotCreateWork() async throws {
        let state = InMemorySyncV2RuntimeState(account: nil)
        let app = try applicationTestApp(state: state, remote: ApplicationTestRemote([]))
        await #expect(throws: SyncV2ApplicationError.self) {
            _ = try await app.renameLocalWork(workID: WorkID(UUID()), title: "作品名")
        }
        await #expect(throws: SyncV2ApplicationError.self) {
            _ = try await app.renameLocalWork(workID: WorkID(UUID()), title: " \n ")
        }
        #expect(try await app.library().items.isEmpty)
    }
}
