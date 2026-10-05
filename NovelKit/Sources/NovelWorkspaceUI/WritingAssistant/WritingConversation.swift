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

    /// Titles are revisions on existing conversation records. Message keys keep the root ID.
    public static func displayed(_ entries: [WritingEnvelope]) -> [WritingEnvelope] {
        entries.filter { $0.record.kind == "conversation" && $0.record.parentId == nil }.map { root in
            var item = root
            if let revision = entries.last(where: { $0.record.kind == "conversation" && $0.record.key == root.id.uuidString.lowercased() }) {
                item.record.payload = revision.record.payload
            }
            return item
        }
    }

    public static func messages(_ entries: [WritingEnvelope], conversation: UUID) -> [WritingMessage] {
        entries.compactMap { item in
            guard item.record.kind == "message", item.record.key == conversation.uuidString.lowercased(),
                  let message = try? item.record.decoded(WritingMessage.self), ["user", "assistant"].contains(message.role) else { return nil }
            return message
        }
    }

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
