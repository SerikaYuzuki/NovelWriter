import Foundation
import NovelCore
import NovelWritingSupport

/// Opaque payloads on the existing request/message lane; no wire or record-kind changes.
public struct AssistantRequestRecord: Codable {
    public var state: String
    public let purpose: AssistantPurpose
    public let documentId: UUID
    public let episodeId: EpisodeID?
    public let conversationId: UUID?
    public let scope: String
    public let permission: String
    public let grant: WritingGrant
    public var detail: String?
    public init(state: String = "sent", purpose: AssistantPurpose, documentId: UUID, episodeId: EpisodeID?,
                conversationId: UUID? = nil, scope: String, permission: String, grant: WritingGrant = .readOnly, detail: String? = nil) {
        self.state = state; self.purpose = purpose; self.documentId = documentId; self.episodeId = episodeId
        self.conversationId = conversationId; self.scope = scope; self.permission = permission; self.grant = grant; self.detail = detail
    }

    public var caption: String {
        "送る範囲：\(scope) · \(permission)"
    }

    public static func latest(_ entries: [WritingEnvelope]) -> [WritingEnvelope] {
        let requests = entries.filter { $0.record.kind == "request" }
        return Dictionary(grouping: requests, by: { $0.record.key }).values.compactMap { group in
            // Edit journal outcomes use the same request key but do not contain runtime metadata.
            group.last { (try? $0.record.decoded(Self.self)) != nil } ?? group.last
        }
    }
}

public enum AssistantRecordChunks {
    private struct Chunk: Codable {
        let index: Int
        let text: String
        let requestId: UUID?
        let source: String?
    }

    public static func records(text: String, key: String, work: UUID) throws -> [WritingRecord] {
        var parts: [String] = [], part = "", bytes = 0
        for character in text.unicodeScalars {
            let size = String(character).utf8.count
            if bytes + size > 120_000, !part.isEmpty {
                parts.append(part); part = ""; bytes = 0
            }
            part.unicodeScalars.append(character); bytes += size
        }
        parts.append(part)
        let address = key.split(separator: ":", maxSplits: 1).map(String.init)
        let requestID = address.count == 2 ? UUID(uuidString: address[1]) : nil
        let source = requestID == nil ? nil : address[0]
        return try parts.enumerated().map { index, text in
            try WritingRecord(workId: work, kind: "message", key: requestID?.uuidString.lowercased() ?? key,
                              payload: WritingRecord.payload(Chunk(index: index, text: text, requestId: requestID, source: source)))
        }
    }

    public static func text(entries: [WritingEnvelope], key: String) throws -> String {
        let address = key.split(separator: ":", maxSplits: 1).map(String.init)
        let requestID = address.count == 2 ? UUID(uuidString: address[1]) : nil
        let chunks = entries.filter { $0.record.kind == "message" }.compactMap { item -> Chunk? in
            guard let chunk = try? item.record.decoded(Chunk.self) else { return nil }
            if item.record.key == key {
                return chunk
            }
            guard let requestID, chunk.requestId == requestID, chunk.source == address[0] else { return nil }
            return chunk
        }.sorted { $0.index < $1.index }
        guard !chunks.isEmpty, chunks.enumerated().allSatisfy({ $0.offset == $0.element.index }) else { throw WritingError.invalidRecord }
        return chunks.map(\.text).joined()
    }
}
