import Foundation
import NovelWritingSupport

public struct WritingConversation: Codable {
    public init(title: String, documentId: UUID, readConsent: Bool) {
        self.title = title
        self.documentId = documentId
        self.readConsent = readConsent
    }

    public let title: String
    public let documentId: UUID
    /// Retained for compatibility with existing conversation records.
    public let readConsent: Bool

    public static func recordForSending(selectedID: UUID?, conversations: [WritingEnvelope], capture: WritingCapture) throws -> WritingRecord {
        if let selectedID {
            guard let item = conversations.first(where: { $0.id == selectedID }),
                  item.record.kind == "conversation", item.record.workId == capture.workId,
                  let conversation = try? item.record.decoded(Self.self),
                  conversation.documentId == capture.document.id else { throw WritingError.changedScope }
            return item.record
        }
        return try WritingRecord(workId: capture.workId, kind: "conversation", key: "conversation",
                                 payload: WritingRecord.payload(Self(
                                     title: "会話 \(Date().formatted(date: .abbreviated, time: .shortened))",
                                     documentId: capture.document.id,
                                     readConsent: true
                                 )))
    }
}
