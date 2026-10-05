import EditorKit
import Foundation
@testable import FUMINIWA
import NovelCore
import Testing

@MainActor
struct ManuscriptCopyAppStateTests {
    @Test("選択範囲はexact Unicodeを一度だけclipboardへ書き本文を状態に保持しない")
    func selectionCopiesExactTextWithoutDocumentMutation() throws {
        let harness = makeHarness(capture: .captured("Editor確定全文"))
        let state = harness.state
        let chapterID = try #require(state.workspaceModel.selectedChapterID)
        let episodeID = try #require(state.workspaceModel.selectedEpisodeID)
        let session = state.workspaceModel.documentSessionToken
        let exactSelection = "  e\u{301}😀\r\n選択本文  "
        let documentBefore = state.workspaceModel.document
        let saveStateBefore = state.workspaceModel.saveState

        let didCopy = state.copySelectionManuscript(
            selectedText: exactSelection,
            episodeID: episodeID,
            in: chapterID,
            expectedSession: session
        )

        #expect(didCopy)
        #expect(harness.clipboard.receivedTexts.count == 1)
        let copiedSelection = try #require(harness.clipboard.receivedTexts.first)
        #expect(copiedSelection == exactSelection)
        #expect(state.manuscriptCopyNotice?.outcome == .success)
        #expect(
            state.manuscriptCopyNotice?.message ==
                "クリップボードへコピーしました。"
        )
        #expect(state.workspaceModel.document == documentBefore)
        #expect(state.workspaceModel.saveState == saveStateBefore)
        #expect(state.workspaceModel.documentSessionToken == session)

        state.dismissManuscriptCopyNotice()
        #expect(state.manuscriptCopyNotice == nil)
    }

    @Test("現在話はEditorの確定本文をモデルより優先し許可外fieldを含めない")
    func currentEpisodeUsesEditorTextAndExcludesPrivateFields() throws {
        let harness = makeHarness(capture: .captured("Editor側の確定本文\n"))
        let state = harness.state
        let chapterID = try #require(state.workspaceModel.selectedChapterID)
        let episodeID = try #require(state.workspaceModel.selectedEpisodeID)
        state.updateChapterTitle("章SECRET", for: chapterID)
        state.updateEpisodeTitle("公開する話題", for: episodeID, in: chapterID)
        state.updateSelectedEpisodeContent("モデル側の古い本文")
        state.updateSelectedEpisodeMemo("MEMO_FORBIDDEN_57A9")
        state.updateDocumentSynopsis("SYNOPSIS_FORBIDDEN_57A9")
        let documentBefore = state.workspaceModel.document

        #expect(state.copyEpisodeManuscript(
            episodeID: episodeID,
            in: chapterID,
            expectedSession: state.workspaceModel.documentSessionToken
        ))

        let prompt = try #require(harness.clipboard.receivedTexts.first)
        #expect(prompt == "公開する話題\n\nEditor側の確定本文\n")
        #expect(!prompt.contains("モデル側の古い本文"))
        #expect(!prompt.contains("章SECRET"))
        #expect(!prompt.contains("MEMO_FORBIDDEN_57A9"))
        #expect(!prompt.contains("SYNOPSIS_FORBIDDEN_57A9"))
        #expect(!prompt.contains(chapterID.rawValue.uuidString))
        #expect(!prompt.contains(episodeID.rawValue.uuidString))
        #expect(state.workspaceModel.document == documentBefore)
    }

    @Test("Editorが非activeなら話promptはモデル本文へ安全にfallbackする")
    func inactiveEditorFallsBackToEpisodeModel() throws {
        let harness = makeHarness(capture: .notActive)
        let state = harness.state
        let chapterID = try #require(state.workspaceModel.selectedChapterID)
        let episodeID = try #require(state.workspaceModel.selectedEpisodeID)
        state.updateEpisodeTitle("対象話", for: episodeID, in: chapterID)
        state.updateSelectedEpisodeContent("モデル確定本文")

        #expect(state.copyEpisodeManuscript(
            episodeID: episodeID,
            in: chapterID,
            expectedSession: state.workspaceModel.documentSessionToken
        ))

        let prompt = try #require(harness.clipboard.receivedTexts.first)
        #expect(prompt == "対象話\n\nモデル確定本文")
    }

    @Test("世界観Editorのcaptureは本文scopeへ混入せずselectionを拒否しモデルへfallbackする")
    func worldbuildingCaptureCannotEnterManuscriptPrompt() throws {
        let harness = makeHarness(capture: .captured("WORLD_EDITOR_FORBIDDEN_57A9"))
        let state = harness.state
        let chapterID = try #require(state.workspaceModel.selectedChapterID)
        let episodeID = try #require(state.workspaceModel.selectedEpisodeID)
        state.updateSelectedEpisodeContent("本文モデル")
        state.selectProjectSection(.worldbuilding)
        let session = state.workspaceModel.documentSessionToken

        #expect(!state.copySelectionManuscript(
            selectedText: "世界観の選択範囲",
            episodeID: episodeID,
            in: chapterID,
            expectedSession: session
        ))
        #expect(harness.clipboard.receivedTexts.isEmpty)

        #expect(state.copyEpisodeManuscript(
            episodeID: episodeID,
            in: chapterID,
            expectedSession: session
        ))

        let prompt = try #require(harness.clipboard.receivedTexts.first)
        #expect(prompt == state.workspaceModel.document.episode(episodeID)?.episode.title.appending("\n\n本文モデル"))
        #expect(!prompt.contains("WORLD_EDITOR_FORBIDDEN_57A9"))
        #expect(!prompt.contains("世界観の選択範囲"))
    }

    @Test("章promptは話の配列順を保ち現在話だけEditor確定本文を使う")
    func chapterKeepsEpisodeOrderAndUsesCurrentEditorText() throws {
        let harness = makeHarness(capture: .captured("二話のEditor確定本文"))
        let state = harness.state
        let chapterID = try #require(state.workspaceModel.selectedChapterID)
        let firstEpisodeID = try #require(state.workspaceModel.selectedEpisodeID)
        state.updateChapterTitle("対象章", for: chapterID)
        state.updateEpisodeTitle("第一話", for: firstEpisodeID, in: chapterID)
        state.updateSelectedEpisodeContent("一話のモデル本文")
        state.addEpisode(to: chapterID, title: "第二話")
        let secondEpisodeID = try #require(state.workspaceModel.selectedEpisodeID)
        state.updateSelectedEpisodeContent("二話の古いモデル本文")

        #expect(state.copyChapterManuscript(
            chapterID: chapterID,
            expectedSession: state.workspaceModel.documentSessionToken
        ))

        let prompt = try #require(harness.clipboard.receivedTexts.first)
        #expect(prompt == "対象章\n\n第一話\n\n一話のモデル本文\n\n第二話\n\n二話のEditor確定本文")
        #expect(!prompt.contains("二話の古いモデル本文"))
        #expect(secondEpisodeID == state.workspaceModel.selectedEpisodeID)
    }
}

@MainActor
struct ManuscriptCopyAppStateFailureTests {
    @Test("IME変換中は選択・話・章の全copyを拒否しclipboardへ一度も書かない")
    func compositionInProgressRejectsEveryScope() throws {
        let harness = makeHarness(capture: .compositionInProgress)
        let state = harness.state
        let chapterID = try #require(state.workspaceModel.selectedChapterID)
        let episodeID = try #require(state.workspaceModel.selectedEpisodeID)
        state.updateSelectedEpisodeContent("確定済みモデル本文")
        let session = state.workspaceModel.documentSessionToken

        #expect(!state.copySelectionManuscript(
            selectedText: "選択本文",
            episodeID: episodeID,
            in: chapterID,
            expectedSession: session
        ))
        #expect(!state.copyEpisodeManuscript(
            episodeID: episodeID,
            in: chapterID,
            expectedSession: session
        ))
        #expect(!state.copyChapterManuscript(
            chapterID: chapterID,
            expectedSession: session
        ))

        #expect(harness.clipboard.receivedTexts.isEmpty)
        #expect(state.manuscriptCopyNotice?.outcome == .failure(.compositionInProgress))
    }

    @Test("古い作品sessionと右クリック後に変わった話選択を再検査してzero writeにする")
    func staleSessionAndSelectionAreRejectedBeforeClipboardWrite() throws {
        let harness = makeHarness(capture: .captured("Editor本文"))
        let state = harness.state
        let chapterID = try #require(state.workspaceModel.selectedChapterID)
        let oldEpisodeID = try #require(state.workspaceModel.selectedEpisodeID)
        let session = state.workspaceModel.documentSessionToken
        var staleSession = session
        staleSession.generation &+= 1

        #expect(!state.copyEpisodeManuscript(
            episodeID: oldEpisodeID,
            in: chapterID,
            expectedSession: staleSession
        ))

        state.addEpisode(to: chapterID, title: "切替先")
        #expect(state.workspaceModel.selectedEpisodeID != oldEpisodeID)
        #expect(!state.copySelectionManuscript(
            selectedText: "古いmenuの選択",
            episodeID: oldEpisodeID,
            in: chapterID,
            expectedSession: session
        ))

        #expect(harness.clipboard.receivedTexts.isEmpty)
        #expect(state.manuscriptCopyNotice?.outcome == .failure(.staleContext))
    }

    @Test("同じcurrent sessionでも存在しない章・話IDは再解決してzero writeにする")
    func missingChapterAndEpisodeAreRejectedBeforeClipboardWrite() throws {
        let harness = makeHarness(capture: .captured("Editor本文"))
        let state = harness.state
        let chapterID = try #require(state.workspaceModel.selectedChapterID)
        let missingEpisodeID = EpisodeID()
        let missingChapterID = ChapterID()
        let session = state.workspaceModel.documentSessionToken

        #expect(!state.copyEpisodeManuscript(
            episodeID: missingEpisodeID,
            in: chapterID,
            expectedSession: session
        ))
        #expect(!state.copyChapterManuscript(
            chapterID: missingChapterID,
            expectedSession: session
        ))

        #expect(harness.clipboard.receivedTexts.isEmpty)
        #expect(state.manuscriptCopyNotice?.outcome == .failure(.staleContext))
    }

    @Test("空本文はclipboardを呼ばずfailure noticeにしprompt本文を保持しない")
    func emptyContentFailsBeforeClipboardWrite() throws {
        let harness = makeHarness(capture: .notActive)
        let state = harness.state
        let chapterID = try #require(state.workspaceModel.selectedChapterID)
        let episodeID = try #require(state.workspaceModel.selectedEpisodeID)
        state.updateEpisodeTitle("タイトルだけ", for: episodeID, in: chapterID)
        state.updateSelectedEpisodeContent(" \n　")

        #expect(!state.copyEpisodeManuscript(
            episodeID: episodeID,
            in: chapterID,
            expectedSession: state.workspaceModel.documentSessionToken
        ))

        #expect(harness.clipboard.receivedTexts.isEmpty)
        #expect(state.manuscriptCopyNotice?.outcome == .failure(.emptyContent))
        #expect(state.manuscriptCopyNotice?.message.contains("タイトルだけ") == false)
        #expect(state.manuscriptCopyNotice?.message.contains(" \n　") == false)
    }

    @Test("clipboard failureはfalseを返し作品状態を変更しない")
    func clipboardFailureLeavesDocumentUntouched() throws {
        let harness = makeHarness(capture: .captured("Editor確定本文"), clipboardSucceeds: false)
        let state = harness.state
        let chapterID = try #require(state.workspaceModel.selectedChapterID)
        let episodeID = try #require(state.workspaceModel.selectedEpisodeID)
        let documentBefore = state.workspaceModel.document
        let saveStateBefore = state.workspaceModel.saveState

        #expect(!state.copyEpisodeManuscript(
            episodeID: episodeID,
            in: chapterID,
            expectedSession: state.workspaceModel.documentSessionToken
        ))

        #expect(harness.clipboard.receivedTexts.count == 1)
        #expect(state.manuscriptCopyNotice?.outcome == .failure(.clipboardWriteFailed))
        #expect(state.workspaceModel.document == documentBefore)
        #expect(state.workspaceModel.saveState == saveStateBefore)
    }
}

@MainActor
private func makeHarness(
    capture: EditorCommittedTextCaptureResult,
    clipboardSucceeds: Bool = true
) -> ManuscriptCopyTestHarness {
    let clipboard = RecordingPlainTextClipboardWriter(succeeds: clipboardSucceeds)
    let captureStub = CommittedTextCaptureStub(result: capture)
    let suiteName = "FUMINIWAManuscriptCopy.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let state = AppState(
        dependencies: AppDependencies(
            repository: ManuscriptCopyRepository(),
            userDefaults: defaults,
            clipboardWriter: clipboard,
            activeCommittedTextCapture: { captureStub.result }
        ),
        initialStartupState: .ready
    )
    return ManuscriptCopyTestHarness(
        state: state,
        clipboard: clipboard,
        captureStub: captureStub
    )
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
private struct ManuscriptCopyTestHarness {
    let state: AppState
    let clipboard: RecordingPlainTextClipboardWriter
    let captureStub: CommittedTextCaptureStub
}

private actor ManuscriptCopyRepository: DocumentRepository {
    func load(from _: URL) async throws -> NovelDocument {
        .newDocument()
    }

    func save(_: NovelDocument, to _: URL) async throws {}
}
