import Foundation
import NovelWritingStore
import NovelWritingSupport
import Testing

struct WritingSQLiteStoreTests {
    @Test func editRetryKeepsOriginalTimestampAndRejectsChangedPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WritingSQLiteStore(root: root)
        let record = WritingRecord(workId: UUID(), kind: "edit", key: "retry", payload: "{\"before\":\"原文\"}")
        try await store.append(record, namespace: "work")
        var retry = record; retry.createdAt = "2026-09-26T12:34:56.123Z"
        try await store.append(retry, namespace: "work")
        #expect(try await store.pending(namespace: "work") == [record])
        retry.payload = "{\"before\":\"変更\"}"
        await #expect(throws: WritingError.invalidRecord) { try await store.append(retry, namespace: "work") }
    }

    @Test func recoveryRemapsRecordsWithoutCopyingClaimsAndDoesNotDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WritingSQLiteStore(root: root), source = UUID(), destination = UUID(), conversation = UUID()
        let record = WritingRecord(workId: source, kind: "request", key: conversation.uuidString,
                                   payload: "{\"state\":\"running\",\"conversationId\":\"\(conversation.uuidString)\"}")
        try await store.append(record, namespace: "source")
        _ = try await store.claimEdit(id: record.id, namespace: "source", payload: "claim")
        // A user can add new history before the deferred copy succeeds.
        try await store.append(WritingRecord(workId: destination, kind: "message", key: "new", payload: "{}"), namespace: "destination")
        let intentRoot = root.appendingPathComponent("writing-history-copies")
        try FileManager.default.createDirectory(at: intentRoot, withIntermediateDirectories: true)
        let intent: [String: String] = ["source": "source", "destination": "destination", "newWorkID": destination.uuidString]
        try JSONSerialization.data(withJSONObject: intent).write(to: intentRoot.appendingPathComponent(destination.uuidString + ".json"))
        let reopened = try WritingSQLiteStore(root: root)
        try await reopened.retryHistoryCopies()
        try await store.copyHistory(source: "source", destination: "destination", newWorkID: destination)
        let copied = try #require(try await store.records(namespace: "destination").first { $0.record.kind == "request" })
        #expect(copied.id != record.id)
        #expect(copied.record.workId == destination)
        #expect(copied.record.key != record.key)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(copied.record.payload.utf8)) as? [String: Any])
        #expect(payload["state"] as? String == "historical")
        #expect(payload["conversationId"] as? String == copied.record.key)
        #expect(try await store.edit(id: copied.id, namespace: "destination") == nil)
        #expect(try await store.records(namespace: "destination").count == 2)
    }

    @Test func restartOutboxIsolationAndIdempotence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WritingSQLiteStore(root: root)
        let record = WritingRecord(workId: UUID(), kind: "message", key: "chat", payload: "{\"text\":\"原文\"}")
        try await store.append(record, namespace: "A")
        try await store.append(record, namespace: "A")
        #expect(try await store.pending(namespace: "A").count == 1)
        #expect(try await store.records(namespace: "B").isEmpty)
        let reopened = try WritingSQLiteStore(root: root)
        #expect(try await reopened.records(namespace: "A").first?.record == record)
        try await reopened.accept(WritingEnvelope(record: record, sequence: 42, conflicted: true), namespace: "A")
        #expect(try await store.pending(namespace: "A").isEmpty)
        #expect(try await store.records(namespace: "A").first?.conflicted == true)
        var reused = record; reused.payload = "{\"text\":\"別の内容\"}"
        await #expect(throws: WritingError.invalidRecord) { try await store.append(reused, namespace: "A") }
        await #expect(throws: WritingError.invalidRecord) { try await store.accept(WritingEnvelope(record: reused, sequence: 42), namespace: "A") }
        try await store.advance(42, namespace: "A", remote: "account1")
        #expect(try await store.cursor(namespace: "A", remote: "account2") == 0)
    }

    @Test func editClaimSurvivesCrashAndDoesNotReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WritingSQLiteStore(root: root), id = UUID()
        #expect(try await store.claimEdit(id: id, namespace: "work", payload: "original"))
        let reopened = try WritingSQLiteStore(root: root)
        #expect(try await reopened.claimEdit(id: id, namespace: "work", payload: "original") == false)
        #expect(try await reopened.edit(id: id, namespace: "work")?.state == "prepared")
        await #expect(throws: WritingError.invalidEdit) { try await reopened.claimEdit(id: id, namespace: "work", payload: "changed") }
        try await store.finishEdit(id: id, namespace: "work", state: "applied")
        #expect(try await reopened.edit(id: id, namespace: "work")?.state == "applied")
    }
}
