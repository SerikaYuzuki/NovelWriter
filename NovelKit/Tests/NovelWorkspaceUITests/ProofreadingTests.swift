import Foundation
import NovelCore
@testable import NovelWorkspaceUI
import NovelWritingSupport
import Testing

@Suite("Proofreading checklist and safe changes")
struct ProofreadingTests {
    @Test func checklistRendersOnlySelectedItemsAndKeepsNamesInQuotedData() throws {
        let defaults = ProofreadingChecklist.defaults
        #expect(Set(defaults.checks) == ["typo", "grammar", "readability", "jpPunctuation", "keepDialogue", "keepStyle"])
        #expect(defaults.instructions.contains("今回確認する項目:\n- [typo]"))
        #expect(defaults.instructions.contains("直さないもの:\n- [keepDialogue]"))
        #expect(!defaults.instructions.contains("[leaderDash]"))
        #expect(defaults.reference(characters: [.init(name: "遥", kana: "はるか")]) == nil)
        let selected = ProofreadingChecklist(selection: ["characterNames", "keepStyle", "futureCheck"])
        let reference = try #require(selected.reference(characters: [.init(name: "遥", kana: "はるか", memo: "秘密")]))
        #expect(reference.contains("遥 / 読み: はるか"))
        #expect(!reference.contains("秘密"))
        let config = try AssistantConfiguration(endpoint: "https://api.openai.com/v1/responses", model: "test",
                                                prompt: "基底\n" + selected.instructions + "\n" + ProofreadingChanges.outputInstruction,
                                                replacesManuscript: true)
        let request = try config.request(manuscript: .init(title: "話", content: "本文", reference: reference), apiKey: "synthetic")
        let requestBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let quoted = try #require(body["input"] as? String)
        let input = try #require(try JSONSerialization.jsonObject(with: Data(quoted.utf8)) as? [String: String])
        #expect(input["content"] == "本文")
        #expect(input["reference"] == reference)
        #expect((body["instructions"] as? String) == config.instructions)
        #expect(selected.checks.contains("futureCheck"))
        #expect(!ProofreadingChecklist(checks: []).instructions.contains("[typo]"))
    }

    @Test func checklistUsesWorkOverrideAndIgnoresConflicts() throws {
        let common = try WritingRecord(workId: nil, kind: "prompt", key: ProofreadingChecklist.key,
                                       payload: WritingRecord.payload(ProofreadingChecklist(checks: ["typo"])))
        let work = try WritingRecord(workId: UUID(), kind: "prompt", key: ProofreadingChecklist.key,
                                     payload: WritingRecord.payload(ProofreadingChecklist(checks: [])))
        #expect(try ProofreadingChecklist.effective(common: [], work: []) == .defaults)
        #expect(try ProofreadingChecklist.effective(common: [.init(record: common)], work: []).checks == ["typo"])
        #expect(try ProofreadingChecklist.effective(common: [.init(record: common)], work: [.init(record: work)]).checks.isEmpty)
        #expect(try ProofreadingChecklist.effective(common: [.init(record: common)], work: [.init(record: work, conflicted: true)]).checks == ["typo"])
    }

    @Test func changesApplyAgainstOriginalTextAndPreserveReasons() throws {
        let changes = try AssistantClient.proofreadChanges(#"""
        {"changes":[
          {"before":"後半，","after":"後半、","reason":"句読点を統一","check":"jpPunctuation"},
          {"before":"🌸前半の誤字","after":"🌸前半の正字","reason":"誤字","check":"typo"}
        ]}
        """#)
        let result = try changes.application(to: "　🌸前半の誤字\r\nそのまま。後半，最後。")
        #expect(result.replacement == "　🌸前半の正字\r\nそのまま。後半、最後。")
        #expect(result.accepted.map { $0.reason } == ["句読点を統一", "誤字"])
        #expect(result.rejected.isEmpty)
        #expect(try AssistantClient.proofreadChanges(#"{"changes":[]}"#).application(to: "原文").replacement == "原文")
        #expect(throws: AssistantError.self) { try AssistantClient.proofreadChanges(#"{"content":"旧形式"}"#) }
    }

    @Test func rejectsMissingAmbiguousAndAllOverlappingChanges() throws {
        let changes = [
            ProofreadingChange(before: "ああ", after: "重複", reason: "r", check: "other"),
            ProofreadingChange(before: "ない", after: "一致なし", reason: "r", check: "typo"),
            ProofreadingChange(before: "", after: "挿入不可", reason: "r", check: "other"),
            ProofreadingChange(before: "abcdef", after: "大きい範囲", reason: "r", check: "other"),
            ProofreadingChange(before: "bc", after: "内側1", reason: "r", check: "other"),
            ProofreadingChange(before: "ef", after: "内側2", reason: "r", check: "other"),
            ProofreadingChange(before: "末尾", after: "", reason: "削除", check: "other")
        ]
        let json = try JSONEncoder().encode(["changes": changes])
        let result = try AssistantClient.proofreadChanges(String(decoding: json, as: UTF8.self)).application(to: "あああabcdef末尾")
        #expect(result.replacement == "あああabcdef")
        #expect(result.accepted == [changes[6]])
        #expect(result.rejected.count == 6)
        #expect(result.rejected[0].explanation.contains("複数回"))
        #expect(result.rejected[3].explanation.contains("重なって"))
    }

    @Test func feedbackReferenceContainsOnlyEnabledContextAndSelectedPositions() throws {
        let first = Episode(title: "一", content: "非選択本文"), second = Episode(title: "二", content: "本文")
        let document = NovelDocument(title: "作品", synopsis: "あらすじ", chapters: [.init(title: "章", episodes: [first, second])],
                                     characters: [.init(name: "遥", kana: "はるか", memo: "秘密メモ", role: "主人公")])
        let reference = try #require(AssistantFeedbackContext.reference(document: document, episodeIDs: [second.id],
                                                                        selected: Set(AssistantFeedbackContext.allCases)))
        #expect(reference.contains("作品名: 作品\nあらすじ: あらすじ"))
        #expect(reference.contains("遥: 主人公"))
        #expect(reference.contains("第1章「章」 第2話「二」"))
        #expect(!reference.contains("非選択本文"))
        #expect(!reference.contains("秘密メモ"))
        #expect(!reference.contains("第1話"))
        #expect(AssistantFeedbackContext.reference(document: document, episodeIDs: [second.id], selected: []) == nil)
        let positionOnly = try #require(AssistantFeedbackContext.reference(document: document, episodeIDs: [second.id], selected: [.position]))
        #expect(!positionOnly.contains("作品名:"))
        #expect(!positionOnly.contains("遥"))
    }
}
