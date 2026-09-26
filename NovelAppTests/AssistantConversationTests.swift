import Foundation
@testable import FUMINIWA
import NovelCore
import NovelWritingSupport
import Testing

struct AssistantConversationTests {
    @Test("最初の送信は参照確認を待たずに現在の作品の会話を準備する")
    func preparesNewConversation() throws {
        let capture = makeCapture()
        let record = try WritingConversation.recordForSending(selectedID: nil, conversations: [], capture: capture)
        let conversation = try record.decoded(WritingConversation.self)
        #expect(record.kind == "conversation")
        #expect(record.workId == capture.workId)
        #expect(conversation.documentId == capture.document.id)
        #expect(conversation.readConsent)
    }

    @Test("既存の会話はIDを保って続けられ、過去の参照確認フラグで入力を止めない", arguments: [false, true])
    func reusesConversation(legacyConsent: Bool) throws {
        let capture = makeCapture()
        let record = try WritingRecord(workId: capture.workId, kind: "conversation", key: "conversation",
                                       payload: WritingRecord.payload(WritingConversation(
                                           title: "保存済みの会話", documentId: capture.document.id, readConsent: legacyConsent
                                       )))
        let records = [WritingEnvelope(record: record)]
        #expect(try WritingConversation.recordForSending(selectedID: record.id, conversations: records, capture: capture) == record)
        let new = try WritingConversation.recordForSending(selectedID: nil, conversations: records, capture: capture)
        #expect(new.id != record.id)
    }

    @Test("確認UIを外しても別作品・別document・欠損した会話へは送信しない")
    func rejectsUnrelatedConversation() throws {
        let capture = makeCapture()
        let record = try WritingConversation.recordForSending(selectedID: nil, conversations: [], capture: capture)
        let records = [WritingEnvelope(record: record)]
        for other in [WritingCapture(workId: UUID(), document: capture.document, episodeId: nil),
                      WritingCapture(workId: capture.workId, document: NovelDocument(title: "別作品", chapters: []), episodeId: nil)] {
            #expect(throws: WritingError.changedScope) {
                try WritingConversation.recordForSending(selectedID: record.id, conversations: records, capture: other)
            }
        }
        #expect(throws: WritingError.changedScope) {
            try WritingConversation.recordForSending(selectedID: UUID(), conversations: records, capture: capture)
        }
        var invalid = record
        invalid.payload = "{}"
        #expect(throws: WritingError.changedScope) {
            try WritingConversation.recordForSending(selectedID: record.id, conversations: [WritingEnvelope(record: invalid)], capture: capture)
        }
    }

    private func makeCapture() -> WritingCapture {
        WritingCapture(workId: UUID(), document: NovelDocument(title: "会話の試験", chapters: []), episodeId: nil)
    }
}
