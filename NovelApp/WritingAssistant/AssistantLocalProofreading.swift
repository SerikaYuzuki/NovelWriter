import CryptoKit
import Foundation
import NovelWorkspaceUI
import NovelWritingSupport

/// Only the changes list and an equality fingerprint survive quitting. No prepared input or replacement body.
struct AssistantLocalProofreading: Codable {
    let raw: String
    let fingerprint: String
    let accepted: [ProofreadingChange]
    let rejected: [Rejected]

    struct Rejected: Codable {
        let change: ProofreadingChange
        let explanation: String
    }

    init(raw: String, text: String) throws {
        let application = try AssistantClient.proofreadChanges(raw).application(to: text)
        accepted = application.accepted
        rejected = application.rejected.map { Rejected(change: $0.change, explanation: $0.explanation) }
        self.raw = raw
        fingerprint = Self.digest(text)
    }

    func matches(_ text: String) -> Bool {
        fingerprint == Self.digest(text)
    }

    func display(on text: String, completed: Bool) throws -> ProofreadingChanges.Application {
        let changes = try AssistantClient.proofreadChanges(raw)
        if completed {
            return .init(replacement: text, accepted: accepted, rejected: rejected.map { .init(change: $0.change, explanation: $0.explanation) })
        }
        if matches(text) {
            return try changes.application(to: text)
        }
        return .init(replacement: text, accepted: [], rejected: changes.changes.map {
            .init(change: $0, explanation: "本文が送信時から変わったため反映できません。")
        })
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
extension WritingAssistantHost {
    private var localProofreadingKey: String {
        "assistant.localProofreading.\(localAccountID ?? accountID).\(workID)"
    }

    func saveProofreadingResult(raw: String, input: String, id: UUID, defaults: UserDefaults) throws {
        let result = try AssistantLocalProofreading(raw: raw, text: manuscript(input).content)
        try defaults.set(JSONEncoder().encode(result), forKey: localProofreadingKey + "." + id.uuidString)
    }

    func proofreadingResult(id: UUID, defaults: UserDefaults) -> AssistantLocalProofreading? {
        guard let data = defaults.data(forKey: localProofreadingKey + "." + id.uuidString) else { return nil }
        return try? JSONDecoder().decode(AssistantLocalProofreading.self, from: data)
    }

    func rememberProofreadingEdit(_ id: UUID, defaults: UserDefaults) {
        let key = localProofreadingKey + ".edits"
        var ids = defaults.stringArray(forKey: key) ?? []
        if !ids.contains(id.uuidString) {
            ids.append(id.uuidString)
        }
        defaults.set(ids, forKey: key)
    }

    func proofreadingEditIDs(defaults: UserDefaults) -> [UUID] {
        (defaults.stringArray(forKey: localProofreadingKey + ".edits") ?? []).compactMap(UUID.init(uuidString:))
    }
}
