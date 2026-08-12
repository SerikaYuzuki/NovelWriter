import Foundation
@testable import FUMINIWAIOS
import NovelCore
import Testing

@MainActor
@Suite("iOS project metadata features")
struct IOSProjectMetadataFeatureTests {
    @Test("登場人物CRUDはdirty/save経路で永続化する")
    func characterCRUDPersists() async throws {
        let environment = makeProjectFeatureEnvironment(prefix: "characters")
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let session = try #require(store.currentDocumentSessionToken)

        let firstID = try #require(store.addCharacter(name: "主人公", expectedSession: session))
        let secondID = try #require(store.addCharacter(name: "相棒", expectedSession: session))
        #expect(store.saveState == .dirty)

        var first = try #require(store.document.characters.first(where: { $0.id == firstID }))
        first.kana = "しゅじんこう"
        first.role = "語り手"
        first.memo = "人物メモ"
        #expect(store.updateCharacter(first, expectedSession: session))
        #expect(store.moveCharacters(fromOffsets: IndexSet(integer: 1), toOffset: 0, expectedSession: session))
        #expect(store.document.characters.first?.id == secondID)
        #expect(store.deleteCharacter(id: secondID, expectedSession: session))
        #expect(!(store.deleteCharacter(id: secondID, expectedSession: session)))
        #expect(await store.saveNow())

        let reopened = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await reopened.bootstrap()
        #expect(reopened.document.characters == [first])
    }

    @Test("プロットカードと伏線を同じ作品でCRUDできる")
    func plotCardsAndFlagsPersistTogether() async throws {
        let environment = makeProjectFeatureEnvironment(prefix: "plot-flags")
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let session = try #require(store.currentDocumentSessionToken)
        let chapterID = try #require(store.selectedChapterID)

        let firstCardID = try #require(
            store.addPlotCard(title: "導入", chapterID: chapterID, expectedSession: session)
        )
        let secondCardID = try #require(store.addPlotCard(title: "転換", expectedSession: session))
        var firstCard = try #require(store.document.plotCards.first(where: { $0.id == firstCardID }))
        firstCard.memo = "事件が始まる"
        #expect(store.updatePlotCard(firstCard, expectedSession: session))
        #expect(store.movePlotCards(fromOffsets: IndexSet(integer: 1), toOffset: 0, expectedSession: session))
        #expect(store.document.plotCards.first?.id == secondCardID)
        #expect(store.deletePlotCard(id: secondCardID, expectedSession: session))
        #expect(store.addPlotCard(title: "不正", chapterID: ChapterID(), expectedSession: session) == nil)

        let firstFlagID = try #require(store.addFlag(title: "消えた鍵", expectedSession: session))
        let secondFlagID = try #require(store.addFlag(title: "古い手紙", expectedSession: session))
        var firstFlag = try #require(store.document.flags.first(where: { $0.id == firstFlagID }))
        firstFlag.note = "終盤で回収"
        firstFlag.plantedChapterID = chapterID
        firstFlag.resolvedChapterID = chapterID
        firstFlag.isResolved = true
        #expect(store.updateFlag(firstFlag, expectedSession: session))
        #expect(store.moveFlags(fromOffsets: IndexSet(integer: 1), toOffset: 0, expectedSession: session))
        #expect(store.document.flags.first?.id == secondFlagID)
        #expect(store.deleteFlag(id: secondFlagID, expectedSession: session))
        #expect(await store.saveNow())

        let reopened = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await reopened.bootstrap()
        #expect(reopened.document.plotCards == [firstCard])
        #expect(reopened.document.flags == [firstFlag])
    }

    @Test("世界観ノートCRUDは配列順と本文を保存する")
    func worldNoteCRUDPersists() async throws {
        let environment = makeProjectFeatureEnvironment(prefix: "world")
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let session = try #require(store.currentDocumentSessionToken)

        let firstID = try #require(store.addWorldNote(title: "王都", expectedSession: session))
        let secondID = try #require(store.addWorldNote(title: "魔法", expectedSession: session))
        var first = try #require(store.document.worldNotes.first(where: { $0.id == firstID }))
        first.content = "城壁に囲まれた都市。"
        #expect(store.updateWorldNote(first, expectedSession: session))
        #expect(store.moveWorldNotes(fromOffsets: IndexSet(integer: 1), toOffset: 0, expectedSession: session))
        #expect(store.document.worldNotes.first?.id == secondID)
        #expect(store.deleteWorldNote(id: secondID, expectedSession: session))
        #expect(await store.saveNow())

        let reopened = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await reopened.bootstrap()
        #expect(reopened.document.worldNotes == [first])
    }

    @Test("作品未選択中のmetadata mutationを拒否する")
    func metadataMutationsRequireActiveWorkingCopy() async {
        let environment = makeProjectFeatureEnvironment(prefix: "inactive")
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        let unavailableSession = IOSDocumentSessionToken(
            workingCopyID: IOSPrivateDocumentID(packageName: "missing.novelpkg"),
            generation: 0
        )

        #expect(store.startupState == .library)
        #expect(store.addCharacter(expectedSession: unavailableSession) == nil)
        #expect(store.addPlotCard(expectedSession: unavailableSession) == nil)
        #expect(store.addFlag(expectedSession: unavailableSession) == nil)
        #expect(store.addWorldNote(expectedSession: unavailableSession) == nil)
        #expect(store.document.characters.isEmpty)
        #expect(store.document.plotCards.isEmpty)
        #expect(store.document.flags.isEmpty)
        #expect(store.document.worldNotes.isEmpty)
    }

    @Test("A→B→A後の古いmetadata操作は同じ子IDへ適用しない")
    func staleMetadataMutationIsRejectedAfterReturningToWorkingCopy() async throws {
        let environment = makeProjectFeatureEnvironment(prefix: "stale-delete")
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        defer { store.dismissExport() }
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let originalDocumentID = try #require(store.currentPrivateDocumentID)
        let originalSession = try #require(store.currentDocumentSessionToken)

        _ = try #require(
            store.addCharacter(name: "複製される人物", expectedSession: originalSession)
        )
        _ = try #require(
            store.addPlotCard(title: "複製されるカード", expectedSession: originalSession)
        )
        _ = try #require(store.addFlag(title: "複製される伏線", expectedSession: originalSession))
        _ = try #require(
            store.addWorldNote(title: "複製されるノート", expectedSession: originalSession)
        )
        #expect(await store.saveNow())

        await store.requestExport()
        let exportedPackageURL = try #require(store.pendingExportURL)
        #expect(await store.importPackage(from: exportedPackageURL))
        let duplicatedDocumentID = try #require(store.currentPrivateDocumentID)
        #expect(duplicatedDocumentID != originalDocumentID)
        #expect(await store.openPrivateDocument(id: originalDocumentID))
        let returnedSession = try #require(store.currentDocumentSessionToken)
        #expect(returnedSession.workingCopyID == originalDocumentID)
        #expect(returnedSession != originalSession)

        let snapshot = IOSMetadataSnapshot(document: store.document)
        try expectStaleMetadataAddsAndUpdatesRejected(
            store: store,
            session: originalSession,
            snapshot: snapshot
        )
        try expectStaleMetadataMovesAndDeletesRejected(
            store: store,
            session: originalSession,
            snapshot: snapshot
        )
        #expect(IOSMetadataSnapshot(document: store.document) == snapshot)
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
        #expect(secondSession.workingCopyID != firstDocumentID)
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
        #expect(returnedFirstSession.workingCopyID == firstDocumentID)
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

private struct IOSMetadataSnapshot: Equatable {
    let characters: [NovelCore.Character]
    let plotCards: [PlotCard]
    let flags: [Flag]
    let worldNotes: [WorldNote]

    init(document: NovelDocument) {
        characters = document.characters
        plotCards = document.plotCards
        flags = document.flags
        worldNotes = document.worldNotes
    }
}

@MainActor
private func expectStaleMetadataAddsAndUpdatesRejected(
    store: IOSDocumentStore,
    session: IOSDocumentSessionToken,
    snapshot: IOSMetadataSnapshot
) throws {
    var character = try #require(snapshot.characters.first)
    character.name = "遅延更新"
    var plotCard = try #require(snapshot.plotCards.first)
    plotCard.title = "遅延更新"
    var flag = try #require(snapshot.flags.first)
    flag.title = "遅延更新"
    var worldNote = try #require(snapshot.worldNotes.first)
    worldNote.title = "遅延更新"

    #expect(store.addCharacter(name: "遅延追加", expectedSession: session) == nil)
    #expect(store.addPlotCard(title: "遅延追加", expectedSession: session) == nil)
    #expect(store.addFlag(title: "遅延追加", expectedSession: session) == nil)
    #expect(store.addWorldNote(title: "遅延追加", expectedSession: session) == nil)
    #expect(!store.updateCharacter(character, expectedSession: session))
    #expect(!store.updatePlotCard(plotCard, expectedSession: session))
    #expect(!store.updateFlag(flag, expectedSession: session))
    #expect(!store.updateWorldNote(worldNote, expectedSession: session))
}

@MainActor
private func expectStaleMetadataMovesAndDeletesRejected(
    store: IOSDocumentStore,
    session: IOSDocumentSessionToken,
    snapshot: IOSMetadataSnapshot
) throws {
    let characterID = try #require(snapshot.characters.first?.id)
    let plotCardID = try #require(snapshot.plotCards.first?.id)
    let flagID = try #require(snapshot.flags.first?.id)
    let worldNoteID = try #require(snapshot.worldNotes.first?.id)
    let firstIndex = IndexSet(integer: 0)
    #expect(!store.moveCharacters(fromOffsets: firstIndex, toOffset: 1, expectedSession: session))
    #expect(!store.movePlotCards(fromOffsets: firstIndex, toOffset: 1, expectedSession: session))
    #expect(!store.moveFlags(fromOffsets: firstIndex, toOffset: 1, expectedSession: session))
    #expect(!store.moveWorldNotes(fromOffsets: firstIndex, toOffset: 1, expectedSession: session))
    #expect(!store.deleteCharacter(id: characterID, expectedSession: session))
    #expect(!store.deletePlotCard(id: plotCardID, expectedSession: session))
    #expect(!store.deleteFlag(id: flagID, expectedSession: session))
    #expect(!store.deleteWorldNote(id: worldNoteID, expectedSession: session))
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
