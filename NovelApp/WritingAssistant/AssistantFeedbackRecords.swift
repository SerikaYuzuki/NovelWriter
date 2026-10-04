import Foundation
import NovelWorkspaceUI
import NovelWritingSupport

@MainActor
extension WritingAssistantHost {
    func recordedFeedback(_ entries: [WritingEnvelope]) -> [AssistantFeedback] {
        AssistantRequestRecord.latest(entries).compactMap { item in
            guard let metadata = try? item.record.decoded(AssistantRequestRecord.self), metadata.purpose == .impressions,
                  ["completed", "historical"].contains(metadata.state), let id = UUID(uuidString: item.record.key),
                  let result = try? AssistantRecordChunks.text(entries: entries, key: "result:\(item.record.key)") else { return nil }
            let date = (try? Date(item.record.createdAt, strategy: .iso8601)) ?? Date.distantPast
            return AssistantFeedback(id: id, purpose: .impressions, scopeTitle: metadata.scope, createdAt: date, markdown: result)
        }
    }
}
