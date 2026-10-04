import Foundation
import NovelCore
import NovelWorkspaceUI
import NovelWritingSupport

enum ChatEditScope: String, CaseIterable, Identifiable {
    case advice = "相談だけ", continuation = "選択中の話に追記", episode = "選択中の話を編集"
    case plots = "プロット", characters = "登場人物", materials = "設定・資料", whole = "作品全体"
    var id: String {
        rawValue
    }

    func grant(_ capture: WritingCapture) throws -> WritingGrant {
        switch self {
        case .advice: return .readOnly
        case .continuation, .episode:
            guard let path = capture.episodePath else { throw AssistantError.emptyContent }
            return WritingGrant(paths: [path + ["content"]], appendOnly: self == .continuation)
        case .plots: return WritingGrant(paths: [["plotCards"]])
        case .characters: return WritingGrant(paths: [["characters"]])
        case .materials: return WritingGrant(paths: [["characters"], ["plotCards"], ["flags"], ["worldNotes"]])
        case .whole: return .wholeWork
        }
    }
}

@MainActor
extension WritingAssistantHost {
    @discardableResult
    func sendChat(question: String, conversation: UUID, isNew: Bool, history: [WritingMessage],
                  scope: ChatEditScope, reference: AssistantScope, defaults: UserDefaults, reusingQuestion: Bool = false) throws -> Bool {
        let capture = try capture()
        let grant = try scope.grant(capture)
        let metadata = AssistantRequestRecord(purpose: .advice, documentId: capture.document.id, episodeId: capture.episodeId,
                                              conversationId: conversation, scope: reference.summary(chapters: capture.document.chapters, currentID: capture.episodeId),
                                              permission: scope.rawValue, grant: grant)
        return startRequest(metadata: metadata, input: "", defaults: defaults, preparedInput: { id in
            try await WritingPrompts.migrateIfNeeded(host: self, defaults: defaults)
            let prompt = try await WritingPrompts.effective(host: self, defaults: defaults, purpose: .advice)
            try Task.checkCancellation()
            let preferences = AssistantPreferences(defaults: defaults)
            let config = try preferences.configuration(.advice)
            let message = WritingMessage(role: "user", text: question, requestId: id)
            // Validate size/schema before adding the conversation or user message.
            let request = try config.chatRequest(capture: capture, grant: grant, messages: history + [message], apiKey: "validation-only",
                                                 effectivePrompt: prompt, referenceScope: reference)
            let input = try savedInput(request)
            let saved = try await records(false)
            if isNew, !saved.contains(where: { $0.id == conversation }) {
                let title = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20)).replacingOccurrences(of: "\n", with: " ")
                try await append(WritingRecord(id: conversation, workId: workID, kind: "conversation", key: "conversation",
                                               payload: WritingRecord.payload(WritingConversation(title: title, documentId: capture.document.id, readConsent: true))))
            }
            if !reusingQuestion, !saved.contains(where: { $0.record.kind == "message" && (try? $0.record.decoded(WritingMessage.self).requestId) == id }) {
                try await append(WritingRecord(workId: workID, kind: "message", key: conversation.uuidString.lowercased(), payload: WritingRecord.payload(message)))
            }
            requestCenter.changed()
            return (metadata, input)
        })
    }
}
