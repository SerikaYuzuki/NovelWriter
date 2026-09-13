import Foundation
@testable import FUMINIWAIOS
import Testing

@MainActor
@Suite("iOS clipboard prompt")
struct IOSClipboardPromptBuilderTests {
    @Test("選択・話・章をAI依頼文なしでコピーする")
    func buildsPlainTextForEveryScope() throws {
        let cases: [(ManuscriptCopySource, String)] = [
            (.selection(text: "選択本文😀"), "選択本文😀"),
            (.episode(title: "第一話", content: "話本文"), "第一話\n\n話本文"),
            (.chapter(title: "第一章", episodes: [.init(title: "第一話", content: "章内本文")]),
             "第一章\n\n第一話\n\n章内本文")
        ]
        for (source, expected) in cases {
            #expect(try ManuscriptCopyBuilder.make(source: source).text == expected)
        }
    }

    @Test("空本文はclipboardへ書かない")
    func emptySourceDoesNotWriteClipboard() async throws {
        let suiteName = "jp.fuminiwa.ios.clipboard-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-ios-clipboard-\(UUID())", isDirectory: true)
        defer {
            IOSDocumentStore.testRuntimeConfigurations.removeValue(forKey: root.standardizedFileURL)
            IOSDocumentStore.testRuntimeApplications.removeValue(forKey: root.standardizedFileURL)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let writer = RecordingIOSClipboardWriter()
        let store = IOSDocumentStore(
            userDefaults: defaults,
            clipboardWriter: writer,
            libraryRoot: root
        )
        #expect(await store.configureSnapshotSyncV2())
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let episodeID = try #require(store.selectedEpisodeID)

        store.copySelectionManuscript(
            text: " \n　",

            expectedEpisodeID: episodeID
        )

        #expect(writer.values.isEmpty)
        #expect(store.manuscriptCopyNotice?.failure == .emptyContent)
    }

    @Test("明示した選択promptだけをclipboardへ1回書く")
    func explicitSelectionWritesExactlyOnce() async throws {
        let suiteName = "jp.fuminiwa.ios.clipboard-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-ios-clipboard-\(UUID())", isDirectory: true)
        defer {
            IOSDocumentStore.testRuntimeConfigurations.removeValue(forKey: root.standardizedFileURL)
            IOSDocumentStore.testRuntimeApplications.removeValue(forKey: root.standardizedFileURL)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let writer = RecordingIOSClipboardWriter()
        let store = IOSDocumentStore(
            userDefaults: defaults,
            clipboardWriter: writer,
            libraryRoot: root
        )
        #expect(await store.configureSnapshotSyncV2())
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let episodeID = try #require(store.selectedEpisodeID)

        store.copySelectionManuscript(
            text: "コピー対象",

            expectedEpisodeID: episodeID
        )

        let copied = try #require(writer.values.first)
        #expect(writer.values.count == 1)
        #expect(copied == "コピー対象")
        #expect(store.manuscriptCopyNotice?.failure == nil)
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
