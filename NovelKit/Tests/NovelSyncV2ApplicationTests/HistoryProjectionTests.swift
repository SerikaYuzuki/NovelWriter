import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
import Testing

private actor HistoryProjectionRemote: SyncV2RemoteClient {
    var entries: [SyncV2RemoteHistoryEntry] = []
    var failure: SyncV2Failure?

    func execute(_ operation: SyncV2RemoteOperation) async throws -> SyncV2RemoteExecution {
        _ = operation
        throw failure ?? .offline
    }

    func historyPage(
        workID: WorkID,
        cursor: String?,
        pageSize: Int
    ) async throws -> SyncV2RemoteHistoryPage {
        _ = workID
        if let failure {
            throw failure
        }
        let offset = cursor.flatMap(Int.init) ?? 0
        let page = Array(entries.dropFirst(offset).prefix(pageSize))
        let next = offset + page.count < entries.count ? String(offset + page.count) : nil
        return SyncV2RemoteHistoryPage(items: page, nextCursor: next)
    }

    func set(entries: [SyncV2RemoteHistoryEntry], failure: SyncV2Failure? = nil) {
        self.entries = entries
        self.failure = failure
    }
}

@Test
func applicationHistoryKeepsLocalRowsWhenRemoteFails() async throws {
    let state = InMemorySyncV2RuntimeState(account: nil)
    let remote = HistoryProjectionRemote()
    let app = try applicationTestApp(state: state, remote: remote)
    await remote.set(entries: [], failure: .offline)
    let workID = WorkID(UUID())
    _ = try await app.checkpoint(
        workID: workID,
        document: applicationTestDocument(title: "local"),
        reason: .explicit,
        documentCreatedAt: applicationTestCreatedAt
    )
    let page = try await app.historyPage(workID: workID, pageSize: 10)

    #expect(page.items.count == 1)
    #expect(page.items[0].source == .local)
    #expect(page.localAvailability == .available)
    #expect(page.onlineAvailability == .unavailable)
    #expect(page.onlineFailure == .offline)
}

@Test
func applicationHistoryExposesRemoteOnlyRowsOnline() async throws {
    let state = InMemorySyncV2RuntimeState(account: nil)
    let remote = HistoryProjectionRemote()
    let app = try applicationTestApp(state: state, remote: remote)
    let workID = WorkID(UUID())
    let snapshotID = try SnapshotID(rawValue: String(repeating: "a", count: 64))
    await remote.set(entries: [
        SyncV2RemoteHistoryEntry(
            occurrenceID: UUID(),
            snapshotID: snapshotID,
            reason: "published",
            pinned: true,
            createdAt: applicationTestCreatedAt
        )
    ])

    let page = try await app.historyPage(workID: workID, pageSize: 10)
    #expect(page.items.count == 1)
    #expect(page.items[0].source == .remote)
    #expect(page.items[0].snapshotID == snapshotID)
    #expect(page.items[0].localGeneration == nil)
    #expect(page.localAvailability == .unavailable)
    #expect(page.onlineAvailability == .available)
}

@Test
func applicationHistoryDoesNotMergeSameSnapshotOccurrences() async throws {
    let state = InMemorySyncV2RuntimeState(account: nil)
    let remote = HistoryProjectionRemote()
    let app = try applicationTestApp(state: state, remote: remote)
    let workID = WorkID(UUID())
    let checkpoint = try await app.checkpoint(
        workID: workID,
        document: applicationTestDocument(title: "same snapshot"),
        reason: .explicit,
        documentCreatedAt: applicationTestCreatedAt
    )
    guard case let .saved(_, snapshotID) = checkpoint.state.localDurability else {
        Issue.record("checkpoint did not expose a local SnapshotID")
        return
    }
    let remoteOccurrenceID = UUID()
    await remote.set(entries: [
        SyncV2RemoteHistoryEntry(
            occurrenceID: remoteOccurrenceID,
            snapshotID: snapshotID,
            reason: "published",
            pinned: true,
            createdAt: applicationTestCreatedAt
        )
    ])

    let page = try await app.historyPage(workID: workID, pageSize: 10)
    #expect(page.items.count == 2)
    #expect(Set(page.items.map(\.source)) == [.local, .remote])
    #expect(Set(page.items.map(\.occurrenceID)).count == 2)
    #expect(page.items.allSatisfy { $0.snapshotID == snapshotID })
}
