import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2
import NovelWorkspace
import Testing

@MainActor
@Suite("iOS project-feature adapter")
struct IOSProjectMetadataFeatureTests {
    @Test("共有コマンドの4種の編集はdebounce経路とcheckpointへ接続する")
    func sharedCommandsPersistThroughAdapter() async throws {
        let environment = makeProjectFeatureEnvironment(prefix: "adapter")
        defer { environment.cleanup() }
        let store = IOSDocumentStore(userDefaults: environment.defaults, libraryRoot: environment.root)
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let session = try #require(store.currentDocumentSessionToken)
        let revision = store.saveCoordinator.lastSavedRevision
        _ = try #require(store.addCharacter(name: "主人公", expectedSession: session))
        _ = try #require(store.addPlotCard(title: "導入", expectedSession: session))
        _ = try #require(store.addFlag(title: "鍵", expectedSession: session))
        _ = try #require(store.addWorldNote(title: "  王都  ", expectedSession: session))
        #expect(store.document.worldNotes.first?.title == "王都")
        #expect(store.saveState == .dirty)
        #expect(store.saveCoordinator.lastSavedRevision == revision)
        let expected = store.document
        #expect(await store.saveNow())
        let reopened = IOSDocumentStore(userDefaults: environment.defaults, libraryRoot: environment.root)
        await reopened.bootstrap()
        #expect(reopened.document.characters == expected.characters)
        #expect(reopened.document.plotCards == expected.plotCards)
        #expect(reopened.document.flags == expected.flags)
        #expect(reopened.document.worldNotes == expected.worldNotes)
    }

    @Test("adapterは未選択・古いsessionを拒否し切替エラーを提示する")
    func adapterRejectsUnavailableAndStaleSession() async throws {
        let environment = makeProjectFeatureEnvironment(prefix: "session")
        defer { environment.cleanup() }
        let store = IOSDocumentStore(userDefaults: environment.defaults, libraryRoot: environment.root)
        await store.bootstrap()
        let unavailable = WorkspaceSessionToken(generation: 0, documentID: UUID(), workID: WorkID(UUID()))
        #expect(store.addCharacter(expectedSession: unavailable) == nil)
        #expect(await store.makeNewDocument())
        let original = try #require(store.currentDocumentSessionToken)
        let id = try #require(store.addCharacter(expectedSession: original))
        store.advanceDocumentSessionGeneration()
        #expect(!store.deleteCharacter(id: id, expectedSession: original))
        #expect(store.document.characters.first?.id == id)
        #expect(store.operationErrorMessage == "作品が切り替わったため、この操作を中止しました。")
    }
}

@MainActor
@Suite("iOS attachment working-copy boundary")
struct IOSAttachmentFeatureTests {
    @Test("資料は現在作品へ取り込み、切替時に一覧を差し替える")
    func attachmentImportSwitchReloadAndDelete() async throws {
        let environment = makeProjectFeatureEnvironment(prefix: "attachments")
        defer { environment.cleanup() }
        let sourceURL = environment.root
            .deletingLastPathComponent()
            .appendingPathComponent("source-\(UUID().uuidString).txt")
        try Data("reference".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        #expect(store.supportsAttachments)
        let firstDocumentID = try #require(store.currentPrivateDocumentID)
        let firstSession = try #require(store.currentDocumentSessionToken)

        let attachment = try #require(
            await store.importAttachment(from: sourceURL, expectedSession: firstSession)
        )
        #expect(store.attachments == [attachment])
        let previewURL = try #require(
            store.attachmentPreviewURL(for: attachment, expectedSession: firstSession)
        )
        #expect(FileManager.default.fileExists(atPath: previewURL.path))

        #expect(await store.makeNewDocument())
        let secondSession = try #require(store.currentDocumentSessionToken)
        #expect(IOSPrivateDocumentID(workID: secondSession.workID) != firstDocumentID)
        #expect(store.attachments.isEmpty)
        store.operationErrorMessage = nil
        #expect(store.attachmentPreviewURL(for: attachment, expectedSession: firstSession) == nil)
        #expect(store.operationErrorMessage == nil)
        #expect(await !(store.deleteAttachment(attachment, expectedSession: firstSession)))
        #expect(
            await store.importAttachment(from: sourceURL, expectedSession: firstSession) == nil
        )
        #expect(store.attachments.isEmpty)

        #expect(await store.openPrivateDocument(id: firstDocumentID))
        let returnedFirstSession = try #require(store.currentDocumentSessionToken)
        #expect(IOSPrivateDocumentID(workID: returnedFirstSession.workID) == firstDocumentID)
        #expect(returnedFirstSession != firstSession)
        #expect(store.attachments == [attachment])
        #expect(store.attachmentPreviewURL(for: attachment, expectedSession: firstSession) == nil)
        #expect(await store.importAttachment(from: sourceURL, expectedSession: firstSession) == nil)
        #expect(store.attachments == [attachment])
        #expect(await !(store.deleteAttachment(attachment, expectedSession: firstSession)))
        #expect(await store.deleteAttachment(attachment, expectedSession: returnedFirstSession))
        #expect(store.attachments.isEmpty)
        #expect(store.attachmentPreviewURL(for: attachment, expectedSession: returnedFirstSession) == nil)
    }

    @Test("資料一覧refreshは別作品のidentityを拒否する")
    func attachmentRefreshRejectsStaleWorkingCopy() async throws {
        let environment = makeProjectFeatureEnvironment(prefix: "attachment-refresh")
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let firstSession = try #require(store.currentDocumentSessionToken)
        #expect(await store.makeNewDocument())
        let secondSession = try #require(store.currentDocumentSessionToken)

        #expect(await !(store.refreshAttachments(expectedSession: firstSession)))
        #expect(await store.refreshAttachments(expectedSession: secondSession))
    }
}

private func makeProjectFeatureEnvironment(prefix: String) -> IOSProjectFeatureTestEnvironment {
    let id = UUID().uuidString
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FUMINIWA-iOS-\(prefix)-Tests-\(id)", isDirectory: true)
    let suiteName = "dev.serikayuzuki.fuminiwa.ios.\(prefix)-tests.\(id)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return IOSProjectFeatureTestEnvironment(root: root, defaults: defaults, suiteName: suiteName)
}

private struct IOSProjectFeatureTestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
