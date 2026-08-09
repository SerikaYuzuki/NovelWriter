import EditorKit
import Foundation
@testable import FUMINIWA
import NovelCore
import Testing

@MainActor
struct AIClipboardPromptAppStateTests {
    @Test("選択範囲はexact Unicodeを一度だけclipboardへ書き本文を状態に保持しない")
    func selectionCopiesExactTextWithoutDocumentMutation() throws {
        let harness = makeHarness(capture: .captured("Editor確定全文"))
        let state = harness.state
        let chapterID = try #require(state.selectedChapterID)
        let episodeID = try #require(state.selectedEpisodeID)
        let session = state.documentSessionToken
        let exactSelection = "  e\u{301}😀\r\n選択本文  "
        let documentBefore = state.document
        let saveStateBefore = state.saveState

        let didCopy = state.copySelectionAIChatPrompt(
            purpose: .advice,
            selectedText: exactSelection,
            episodeID: episodeID,
            in: chapterID,
            expectedSession: session
        )

        #expect(didCopy)
        #expect(harness.clipboard.receivedTexts.count == 1)
        #expect(try selectionText(in: #require(harness.clipboard.receivedTexts.first)) == exactSelection)
        #expect(state.aiClipboardPromptCopyNotice?.outcome == .success)
        #expect(
            state.aiClipboardPromptCopyNotice?.message ==
                "プロンプトをシステムクリップボードへコピーしました。AIチャットには送信していません。"
        )
        #expect(state.document == documentBefore)
        #expect(state.saveState == saveStateBefore)
        #expect(state.documentSessionToken == session)

        state.dismissAIClipboardPromptCopyNotice()
        #expect(state.aiClipboardPromptCopyNotice == nil)
    }

    @Test("現在話はEditorの確定本文をモデルより優先し許可外fieldを含めない")
    func currentEpisodeUsesEditorTextAndExcludesPrivateFields() throws {
        let harness = makeHarness(capture: .captured("Editor側の確定本文\n"))
        let state = harness.state
        let chapterID = try #require(state.selectedChapterID)
        let episodeID = try #require(state.selectedEpisodeID)
        state.updateChapterTitle("章SECRET", for: chapterID)
        state.updateEpisodeTitle("公開する話題", for: episodeID, in: chapterID)
        state.updateSelectedEpisodeContent("モデル側の古い本文")
        state.updateSelectedEpisodeMemo("MEMO_FORBIDDEN_57A9")
        state.updateDocumentSynopsis("SYNOPSIS_FORBIDDEN_57A9")
        let documentBefore = state.document

        #expect(state.copyEpisodeAIChatPrompt(
            purpose: .proofreading,
            episodeID: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken
        ))

        let prompt = try #require(harness.clipboard.receivedTexts.first)
        let manuscript = try manuscript(in: prompt)
        #expect(manuscript["title"] as? String == "公開する話題")
        #expect(manuscript["content"] as? String == "Editor側の確定本文\n")
        #expect(Set(manuscript.keys) == ["title", "content"])
        #expect(!prompt.contains("モデル側の古い本文"))
        #expect(!prompt.contains("章SECRET"))
        #expect(!prompt.contains("MEMO_FORBIDDEN_57A9"))
        #expect(!prompt.contains("SYNOPSIS_FORBIDDEN_57A9"))
        #expect(!prompt.contains(chapterID.rawValue.uuidString))
        #expect(!prompt.contains(episodeID.rawValue.uuidString))
        #expect(state.document == documentBefore)
    }

    @Test("Editorが非activeなら話promptはモデル本文へ安全にfallbackする")
    func inactiveEditorFallsBackToEpisodeModel() throws {
        let harness = makeHarness(capture: .notActive)
        let state = harness.state
        let chapterID = try #require(state.selectedChapterID)
        let episodeID = try #require(state.selectedEpisodeID)
        state.updateEpisodeTitle("対象話", for: episodeID, in: chapterID)
        state.updateSelectedEpisodeContent("モデル確定本文")

        #expect(state.copyEpisodeAIChatPrompt(
            purpose: .advice,
            episodeID: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken
        ))

        let prompt = try #require(harness.clipboard.receivedTexts.first)
        #expect(try manuscript(in: prompt)["content"] as? String == "モデル確定本文")
    }

    @Test("世界観Editorのcaptureは本文scopeへ混入せずselectionを拒否しモデルへfallbackする")
    func worldbuildingCaptureCannotEnterManuscriptPrompt() throws {
        let harness = makeHarness(capture: .captured("WORLD_EDITOR_FORBIDDEN_57A9"))
        let state = harness.state
        let chapterID = try #require(state.selectedChapterID)
        let episodeID = try #require(state.selectedEpisodeID)
        state.updateSelectedEpisodeContent("本文モデル")
        state.selectProjectSection(.worldbuilding)
        let session = state.documentSessionToken

        #expect(!state.copySelectionAIChatPrompt(
            purpose: .advice,
            selectedText: "世界観の選択範囲",
            episodeID: episodeID,
            in: chapterID,
            expectedSession: session
        ))
        #expect(harness.clipboard.receivedTexts.isEmpty)

        #expect(state.copyEpisodeAIChatPrompt(
            purpose: .proofreading,
            episodeID: episodeID,
            in: chapterID,
            expectedSession: session
        ))

        let prompt = try #require(harness.clipboard.receivedTexts.first)
        #expect(try manuscript(in: prompt)["content"] as? String == "本文モデル")
        #expect(!prompt.contains("WORLD_EDITOR_FORBIDDEN_57A9"))
        #expect(!prompt.contains("世界観の選択範囲"))
    }

    @Test("章promptは話の配列順を保ち現在話だけEditor確定本文を使う")
    func chapterKeepsEpisodeOrderAndUsesCurrentEditorText() throws {
        let harness = makeHarness(capture: .captured("二話のEditor確定本文"))
        let state = harness.state
        let chapterID = try #require(state.selectedChapterID)
        let firstEpisodeID = try #require(state.selectedEpisodeID)
        state.updateChapterTitle("対象章", for: chapterID)
        state.updateEpisodeTitle("第一話", for: firstEpisodeID, in: chapterID)
        state.updateSelectedEpisodeContent("一話のモデル本文")
        state.addEpisode(to: chapterID, title: "第二話")
        let secondEpisodeID = try #require(state.selectedEpisodeID)
        state.updateSelectedEpisodeContent("二話の古いモデル本文")

        #expect(state.copyChapterAIChatPrompt(
            purpose: .proofreading,
            chapterID: chapterID,
            expectedSession: state.documentSessionToken
        ))

        let prompt = try #require(harness.clipboard.receivedTexts.first)
        let chapter = try manuscript(in: prompt)
        let episodes = try #require(chapter["episodes"] as? [[String: Any]])
        #expect(chapter["title"] as? String == "対象章")
        #expect(episodes.count == 2)
        #expect(episodes[0]["title"] as? String == "第一話")
        #expect(episodes[0]["content"] as? String == "一話のモデル本文")
        #expect(episodes[1]["title"] as? String == "第二話")
        #expect(episodes[1]["content"] as? String == "二話のEditor確定本文")
        #expect(!prompt.contains("二話の古いモデル本文"))
        #expect(secondEpisodeID == state.selectedEpisodeID)
    }
}

@MainActor
struct AIClipboardPromptAppStateFailureTests {
    @Test("IME変換中は選択・話・章の全copyを拒否しclipboardへ一度も書かない")
    func compositionInProgressRejectsEveryScope() throws {
        let harness = makeHarness(capture: .compositionInProgress)
        let state = harness.state
        let chapterID = try #require(state.selectedChapterID)
        let episodeID = try #require(state.selectedEpisodeID)
        state.updateSelectedEpisodeContent("確定済みモデル本文")
        let session = state.documentSessionToken

        #expect(!state.copySelectionAIChatPrompt(
            purpose: .proofreading,
            selectedText: "選択本文",
            episodeID: episodeID,
            in: chapterID,
            expectedSession: session
        ))
        #expect(!state.copyEpisodeAIChatPrompt(
            purpose: .proofreading,
            episodeID: episodeID,
            in: chapterID,
            expectedSession: session
        ))
        #expect(!state.copyChapterAIChatPrompt(
            purpose: .advice,
            chapterID: chapterID,
            expectedSession: session
        ))

        #expect(harness.clipboard.receivedTexts.isEmpty)
        #expect(state.aiClipboardPromptCopyNotice?.outcome == .failure(.compositionInProgress))
    }

    @Test("古い作品sessionと右クリック後に変わった話選択を再検査してzero writeにする")
    func staleSessionAndSelectionAreRejectedBeforeClipboardWrite() throws {
        let harness = makeHarness(capture: .captured("Editor本文"))
        let state = harness.state
        let chapterID = try #require(state.selectedChapterID)
        let oldEpisodeID = try #require(state.selectedEpisodeID)
        let session = state.documentSessionToken
        var staleSession = session
        staleSession.generation &+= 1

        #expect(!state.copyEpisodeAIChatPrompt(
            purpose: .advice,
            episodeID: oldEpisodeID,
            in: chapterID,
            expectedSession: staleSession
        ))

        state.addEpisode(to: chapterID, title: "切替先")
        #expect(state.selectedEpisodeID != oldEpisodeID)
        #expect(!state.copySelectionAIChatPrompt(
            purpose: .advice,
            selectedText: "古いmenuの選択",
            episodeID: oldEpisodeID,
            in: chapterID,
            expectedSession: session
        ))

        #expect(harness.clipboard.receivedTexts.isEmpty)
        #expect(state.aiClipboardPromptCopyNotice?.outcome == .failure(.staleContext))
    }

    @Test("同じcurrent sessionでも存在しない章・話IDは再解決してzero writeにする")
    func missingChapterAndEpisodeAreRejectedBeforeClipboardWrite() throws {
        let harness = makeHarness(capture: .captured("Editor本文"))
        let state = harness.state
        let chapterID = try #require(state.selectedChapterID)
        let missingEpisodeID = EpisodeID()
        let missingChapterID = ChapterID()
        let session = state.documentSessionToken

        #expect(!state.copyEpisodeAIChatPrompt(
            purpose: .proofreading,
            episodeID: missingEpisodeID,
            in: chapterID,
            expectedSession: session
        ))
        #expect(!state.copyChapterAIChatPrompt(
            purpose: .advice,
            chapterID: missingChapterID,
            expectedSession: session
        ))

        #expect(harness.clipboard.receivedTexts.isEmpty)
        #expect(state.aiClipboardPromptCopyNotice?.outcome == .failure(.staleContext))
    }

    @Test("空本文はclipboardを呼ばずfailure noticeにしprompt本文を保持しない")
    func emptyContentFailsBeforeClipboardWrite() throws {
        let harness = makeHarness(capture: .notActive)
        let state = harness.state
        let chapterID = try #require(state.selectedChapterID)
        let episodeID = try #require(state.selectedEpisodeID)
        state.updateEpisodeTitle("タイトルだけ", for: episodeID, in: chapterID)
        state.updateSelectedEpisodeContent(" \n　")

        #expect(!state.copyEpisodeAIChatPrompt(
            purpose: .proofreading,
            episodeID: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken
        ))

        #expect(harness.clipboard.receivedTexts.isEmpty)
        #expect(state.aiClipboardPromptCopyNotice?.outcome == .failure(.emptyContent))
        #expect(state.aiClipboardPromptCopyNotice?.message.contains("タイトルだけ") == false)
        #expect(state.aiClipboardPromptCopyNotice?.message.contains(" \n　") == false)
    }

    @Test("clipboard failureはfalseを返し作品状態を変更しない")
    func clipboardFailureLeavesDocumentUntouched() throws {
        let harness = makeHarness(capture: .captured("Editor確定本文"), clipboardSucceeds: false)
        let state = harness.state
        let chapterID = try #require(state.selectedChapterID)
        let episodeID = try #require(state.selectedEpisodeID)
        let documentBefore = state.document
        let saveStateBefore = state.saveState

        #expect(!state.copyEpisodeAIChatPrompt(
            purpose: .advice,
            episodeID: episodeID,
            in: chapterID,
            expectedSession: state.documentSessionToken
        ))

        #expect(harness.clipboard.receivedTexts.count == 1)
        #expect(state.aiClipboardPromptCopyNotice?.outcome == .failure(.clipboardWriteFailed))
        #expect(state.document == documentBefore)
        #expect(state.saveState == saveStateBefore)
    }
}

@MainActor
private func makeHarness(
    capture: EditorCommittedTextCaptureResult,
    clipboardSucceeds: Bool = true
) -> AIClipboardPromptTestHarness {
    let clipboard = RecordingPlainTextClipboardWriter(succeeds: clipboardSucceeds)
    let captureStub = CommittedTextCaptureStub(result: capture)
    let suiteName = "FUMINIWAAIClipboardPrompt.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let state = AppState(
        dependencies: AppDependencies(
            repository: AIClipboardPromptRepository(),
            userDefaults: defaults,
            clipboardWriter: clipboard,
            activeCommittedTextCapture: { captureStub.result }
        ),
        initialStartupState: .ready
    )
    return AIClipboardPromptTestHarness(
        state: state,
        clipboard: clipboard,
        captureStub: captureStub
    )
}

private func selectionText(in prompt: String) throws -> String {
    try #require(manuscript(in: prompt)["text"] as? String)
}

private func manuscript(in prompt: String) throws -> [String: Any] {
    let beginning = "--- BEGIN FUMINIWA MANUSCRIPT JSON ---\n\n"
    let ending = "\n\n--- END FUMINIWA MANUSCRIPT JSON ---"
    let beginningRange = try #require(prompt.range(of: beginning))
    let jsonStart = beginningRange.upperBound
    let endingRange = try #require(prompt.range(of: ending, range: jsonStart ..< prompt.endIndex))
    let data = Data(prompt[jsonStart ..< endingRange.lowerBound].utf8)
    let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(envelope["manuscript"] as? [String: Any])
}

@MainActor
private final class RecordingPlainTextClipboardWriter: PlainTextClipboardWriting {
    private let succeeds: Bool
    private(set) var receivedTexts: [String] = []

    init(succeeds: Bool) {
        self.succeeds = succeeds
    }

    func writePlainText(_ text: String) -> Bool {
        receivedTexts.append(text)
        return succeeds
    }
}

@MainActor
private final class CommittedTextCaptureStub {
    var result: EditorCommittedTextCaptureResult

    init(result: EditorCommittedTextCaptureResult) {
        self.result = result
    }
}

@MainActor
private struct AIClipboardPromptTestHarness {
    let state: AppState
    let clipboard: RecordingPlainTextClipboardWriter
    let captureStub: CommittedTextCaptureStub
}

private actor AIClipboardPromptRepository: DocumentRepository {
    func load(from _: URL) async throws -> NovelDocument {
        .newDocument()
    }

    func save(_: NovelDocument, to _: URL) async throws {}
}
