import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
import Testing

@Suite("Snapshot Sync v2 library and restore")
struct LibraryRestoreTests {
    @Test("remote-only shelf item downloads and installs atomically on open")
    func remoteOnlyOpen() async throws {
        let state = InMemorySyncV2RuntimeState(
            account: TestAccount(accountID: "account", accountFence: "fence")
        )
        let remote = ApplicationTestRemote([.failure(.offline)])
        let app = try applicationTestApp(state: state, remote: remote)
        let workID = WorkID(UUID())
        let document = applicationTestDocument(title: "サーバーだけの作品")
        let inbox = try applicationTestInbox(
            workID: workID,
            document: document,
            currentSnapshotID: nil,
            localGeneration: 0
        )
        await state.addRemoteOnly(inbox)

        let shelf = try await app.library()
        let item = try #require(shelf.items.first { $0.workID == workID })
        #expect(item.availability == .remoteOnly)
        let opened = try await app.open(workID: workID)

        #expect(opened.document == document)
        #expect(opened.documentCreatedAt == applicationTestCreatedAt)
        #expect(try await state.open(workID: workID).snapshotID == inbox.headSnapshotID)
        #expect(await remote.recordedOperations().isEmpty)
    }

    @Test("restore creates a durable restore command and keeps the restored model local")
    func restoreIsDurable() async throws {
        let state = InMemorySyncV2RuntimeState(
            account: TestAccount(accountID: "account", accountFence: "fence")
        )
        let remote = ApplicationTestRemote([.applied(), .applied(), .applied()])
        let app = try applicationTestApp(state: state, remote: remote)
        let workID = WorkID(UUID())
        let documentID = UUID()

        let first = try await app.checkpoint(
            workID: workID,
            document: applicationTestDocument(
                id: documentID,
                title: "最初の版",
                body: "first"
            ),
            reason: .explicit,
            documentCreatedAt: applicationTestCreatedAt
        )
        guard case let .saved(_, firstSnapshotID) = first.state.localDurability else {
            Issue.record("first checkpoint was not durable")
            return
        }
        try await eventually { await state.pendingIntentCount(workID: workID) == 0 }
        _ = try await app.checkpoint(
            workID: workID,
            document: applicationTestDocument(
                id: documentID,
                title: "二番目の版",
                body: "second"
            ),
            reason: .explicit,
            documentCreatedAt: applicationTestCreatedAt
        )
        try await eventually { await state.pendingIntentCount(workID: workID) == 0 }

        let result = try await app.restore(
            workID: workID,
            snapshotID: firstSnapshotID
        )
        #expect(result.typedResult == .restored)
        try await eventually { await remote.recordedOperations().count == 3 }
        let operations = await remote.recordedOperations()

        #expect(commandKind(operations[2]) == .restore)
        #expect(try await state.open(workID: workID).document?.title == "最初の版")
        try await eventually { await state.pendingIntentCount(workID: workID) == 0 }
    }

    @Test("unbound local work remains visible without authentication")
    func unboundWorkIsVisibleOffline() async throws {
        let state = InMemorySyncV2RuntimeState(account: nil)
        let remote = ApplicationTestRemote([.failure(.authenticationRequired)])
        let app = try applicationTestApp(state: state, remote: remote)
        let workID = WorkID(UUID())

        _ = try await app.checkpoint(
            workID: workID,
            document: applicationTestDocument(title: "未サインイン原稿"),
            reason: .autosave,
            documentCreatedAt: applicationTestCreatedAt
        )
        let item = try #require(
            try await app.library().items.first { $0.workID == workID }
        )

        #expect(item.accountState == .unbound)
        #expect(item.availability == .localOnly)
        #expect(item.remoteProgress == .pending)
    }
}
