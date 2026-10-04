import Foundation
import NovelWorkspaceUI
import NovelWritingSupport

private struct AssistantChunkedEdit: Codable {
    let requestId: UUID
    let chunked: Bool
}

@MainActor
extension WritingAssistantHost {
    func appendEdit(_ edit: WritingEdit) async throws {
        let payload = try WritingRecord.payload(edit)
        let recordPayload: String
        if payload.utf8.count <= 1_000_000 {
            recordPayload = payload
        } else {
            for record in try AssistantRecordChunks.records(text: payload, key: "edit:\(edit.id.uuidString.lowercased())", work: workID) {
                try await append(record)
            }
            recordPayload = try WritingRecord.payload(AssistantChunkedEdit(requestId: edit.id, chunked: true))
        }
        try await append(WritingRecord(id: edit.id, workId: workID, kind: "edit", key: edit.id.uuidString.lowercased(), payload: recordPayload))
    }

    func decodedEdit(_ record: WritingRecord, entries: [WritingEnvelope]) throws -> WritingEdit {
        if let edit = try? record.decoded(WritingEdit.self) {
            return edit
        }
        let reference = try record.decoded(AssistantChunkedEdit.self)
        guard reference.chunked else { throw WritingError.invalidRecord }
        let text = try AssistantRecordChunks.text(entries: entries, key: "edit:\(reference.requestId.uuidString.lowercased())")
        return try JSONDecoder().decode(WritingEdit.self, from: Data(text.utf8))
    }
}
