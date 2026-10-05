import Foundation
@testable import FUMINIWAIOS
import NovelWorkspace
import Testing

@MainActor
@Suite("iOS clipboard prompt")
struct IOSClipboardPromptBuilderTests {
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
        let episodeID = try #require(store.workspaceModel.selectedEpisodeID)

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
        let episodeID = try #require(store.workspaceModel.selectedEpisodeID)

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
