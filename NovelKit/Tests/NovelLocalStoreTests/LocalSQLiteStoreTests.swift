import Foundation
import NovelLocalStore
import Testing

@Suite("SQLite local canonical store")
struct LocalSQLiteStoreTests {
    @Test("commit is atomic and creates a durable latest intent")
    func commitAndIntent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-local-store-\(UUID().uuidString)", isDirectory: true)
        let store = try LocalSQLiteStore(url: directory.appendingPathComponent("library.sqlite"))
        let workID = UUID()
        let documentID = UUID()
        let bytes = Data(#"{"title":"offline"}"#.utf8)
        let objectID = String(repeating: "a", count: 64)
        let snapshotID = String(repeating: "b", count: 64)

        let record = try await store.commitSnapshot(
            workID: workID,
            documentID: documentID,
            documentCreatedAt: "2026-08-16T00:00:00Z",
            snapshotID: snapshotID,
            parentSnapshotIDs: [],
            manifest: Data(#"{"schemaVersion":1}"#.utf8),
            objects: [LocalObject(objectID: objectID, bytes: bytes)],
            reason: .autosave
        )

        #expect(record.id == snapshotID)
        #expect(record.localGeneration == 1)
        #expect(try await store.object(id: objectID) == bytes)
        let state = try await store.workState(for: workID)
        #expect(state?.currentLocalSnapshotID == snapshotID)
        #expect(state?.localGeneration == 1)
        #expect(try await store.pendingIntents(for: workID).count == 1)
    }

    @Test("newer local edits survive an acknowledgement of an older intent")
    func acknowledgementDoesNotClearNewerEdit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-local-store-\(UUID().uuidString)", isDirectory: true)
        let store = try LocalSQLiteStore(url: directory.appendingPathComponent("library.sqlite"))
        let workID = UUID()
        let documentID = UUID()
        let firstObjectID = String(repeating: "c", count: 64)
        let secondObjectID = String(repeating: "f", count: 64)

        _ = try await store.commitSnapshot(
            workID: workID,
            documentID: documentID,
            documentCreatedAt: "2026-08-16T00:00:00Z",
            snapshotID: String(repeating: "d", count: 64),
            parentSnapshotIDs: [],
            manifest: Data("one".utf8),
            objects: [LocalObject(objectID: firstObjectID, bytes: Data("one".utf8))],
            reason: .autosave,
            intentKind: .checkpoint
        )
        let firstIntent = try #require(await store.pendingIntents(for: workID).first)
        _ = try await store.commitSnapshot(
            workID: workID,
            documentID: documentID,
            documentCreatedAt: "2026-08-16T00:00:00Z",
            snapshotID: String(repeating: "e", count: 64),
            parentSnapshotIDs: [firstIntent.localSnapshotID],
            manifest: Data("two".utf8),
            objects: [LocalObject(objectID: secondObjectID, bytes: Data("two".utf8))],
            reason: .autosave
        )

        let cleared = try await store.acknowledge(
            intentID: firstIntent.id,
            remoteSnapshotID: firstIntent.localSnapshotID,
            remoteGeneration: 1
        )
        #expect(cleared == false)
        let pending = try await store.pendingIntents(for: workID)
        #expect(pending.contains(where: { $0.localSnapshotID == String(repeating: "e", count: 64) }))
    }

    @Test("remote snapshot install creates a missing local work atomically")
    func installRemoteSnapshotForRemoteOnlyWork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuminiwa-local-store-\(UUID().uuidString)", isDirectory: true)
        let store = try LocalSQLiteStore(url: directory.appendingPathComponent("library.sqlite"))
        let workID = UUID()
        let documentID = UUID()
        let objectID = String(repeating: "1", count: 64)
        let snapshotID = String(repeating: "2", count: 64)
        let manifest = Data(#"{"schemaVersion":1}"#.utf8)

        let record = try await store.installRemoteSnapshot(
            workID: workID,
            documentID: documentID,
            documentCreatedAt: "2026-08-16T00:00:00Z",
            snapshotID: snapshotID,
            parentSnapshotIDs: [],
            manifest: manifest,
            objects: [LocalObject(objectID: objectID, bytes: Data("remote".utf8))],
            remoteGeneration: 7,
            expectedLocalSnapshotID: nil,
            expectedLocalGeneration: nil
        )

        #expect(record.id == snapshotID)
        #expect(try await store.snapshot(id: snapshotID)?.manifest == manifest)
        let state = try #require(try await store.workState(for: workID))
        #expect(state.documentID == documentID)
        #expect(state.currentLocalSnapshotID == snapshotID)
        #expect(state.acknowledgedHeadSnapshotID == snapshotID)
        #expect(state.acknowledgedHeadGeneration == 7)
        #expect(try await store.pendingIntents(for: workID).isEmpty)
    }
}
