import Foundation
@testable import FUMINIWAIOS
import Testing

@MainActor
@Suite("iOS clipboard prompt")
struct IOSClipboardPromptBuilderTests {
    @Test("校正とアドバイスを選択・話・章の全scopeで生成する")
    func buildsAllPurposeAndScopeCombinations() throws {
        let purposes: [AIClipboardPromptPurpose] = [.proofreading, .advice]
        let sources: [AIClipboardPromptSource] = [
            .selection(text: "選択本文😀"),
            .episode(title: "第一話", content: "話本文"),
            .chapter(
                title: "第一章",
                episodes: [
                    AIClipboardPromptEpisode(title: "第一話", content: "章内本文")
                ]
            )
        ]

        for purpose in purposes {
            for source in sources {
                let prompt = try AIClipboardPromptBuilder.make(purpose: purpose, source: source)

                #expect(prompt.purpose == purpose)
                #expect(prompt.scope == source.scope)
                #expect(prompt.text.contains("fuminiwa-manuscript-prompt-v1"))
                #expect(prompt.text.contains("AIチャットへ送信") == false)
            }
        }
    }

    @Test("空本文はclipboardへ書かない")
    func emptySourceDoesNotWriteClipboard() throws {
        let suiteName = "jp.fuminiwa.ios.clipboard-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writer = RecordingIOSClipboardWriter()
        let store = IOSDocumentStore(userDefaults: defaults, clipboardWriter: writer)
        let episodeID = try #require(store.selectedEpisodeID)

        store.copySelectionPrompt(
            text: " \n　",
            purpose: .proofreading,
            expectedEpisodeID: episodeID
        )

        #expect(writer.values.isEmpty)
        #expect(store.promptCopyNotice?.failure == .emptyContent)
    }

    @Test("明示した選択promptだけをclipboardへ1回書く")
    func explicitSelectionWritesExactlyOnce() throws {
        let suiteName = "jp.fuminiwa.ios.clipboard-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writer = RecordingIOSClipboardWriter()
        let store = IOSDocumentStore(userDefaults: defaults, clipboardWriter: writer)
        let episodeID = try #require(store.selectedEpisodeID)

        store.copySelectionPrompt(
            text: "コピー対象",
            purpose: .advice,
            expectedEpisodeID: episodeID
        )

        #expect(writer.values.count == 1)
        #expect(writer.values[0].contains("コピー対象"))
        #expect(store.promptCopyNotice?.failure == nil)
    }
}

@MainActor
private final class RecordingIOSClipboardWriter: IOSPlainTextClipboardWriting {
    private(set) var values: [String] = []

    func writePlainText(_ text: String) -> Bool {
        values.append(text)
        return true
    }
}
