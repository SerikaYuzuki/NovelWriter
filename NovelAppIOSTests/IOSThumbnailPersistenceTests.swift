import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelThumbnail
import NovelWritingSupport
import Testing

@MainActor
@Suite("iOS thumbnail persistence")
struct IOSThumbnailPersistenceTests {
    @Test func ownersAndThumbnailsShareCheckpointAndOrphansSurvive() async throws {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let defaults = try #require(UserDefaults(suiteName: configuration.defaults.suiteName))
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: configuration.localRoot.url, runtimeComposition: .test(configuration))
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let session = try #require(store.currentDocumentSessionToken)
        let application = try #require(store.snapshotSyncV2Application)
        let work = try #require(store.syncV2ActiveWorkID)
        let account = store.snapshotSyncV2AccountScope
        let character = Character(name: "合成人物"), note = WorldNote(title: "合成世界", content: "合成内容")
        store.document.characters = [character]
        store.document.worldNotes = [note]
        let cover = ThumbnailOwner(.work, store.document.id)
        let avatar = ThumbnailOwner(.character, character.id.rawValue)
        let world = ThumbnailOwner(.worldNote, note.id.rawValue)
        let orphan = ThumbnailOwner(.worldNote, UUID())
        let bytes = try ThumbnailEncoder.encode(SyntheticThumbnailImage.data(), owner: cover)
        for owner in [cover, avatar, world] {
            #expect(await store.setThumbnail(bytes, owner: owner, session: session, account: account))
        }
        #expect(store.referenceAttachments.isEmpty)
        let current = try #require(store.currentV2Attachments())
        #expect(store.adoptV2AttachmentRecords(current + [.init(attachmentId: UUID(), fileName: orphan.fileName, bytes: bytes)]))
        #expect(await store.checkpointSnapshotSyncV2(store.document))
        let host = try #require(store.writingAssistantHost)
        #expect(try host.capture().attachments.isEmpty)
        let before = try await application.openLocal(workID: work)
        #expect(store.deleteCharacter(id: character.id, expectedSession: session))
        #expect(store.deleteWorldNote(id: note.id, expectedSession: session))
        #expect(await store.saveNow())
        let after = try await application.openLocal(workID: work)
        #expect(after.generation == before.generation + 1)
        let names = Set(after.attachments.map(\.fileName))
        #expect(names == [cover.fileName, orphan.fileName])
        #expect(after.document?.characters.isEmpty == true)
        #expect(after.document?.worldNotes.isEmpty == true)
        #expect(store.referenceAttachments.contains { $0.fileName == orphan.fileName })
        let edit = WritingEdit(workId: work.rawValue, documentId: store.document.id,
                               changes: [.init(path: ["title"], before: .string(store.document.title), after: .string("AIからの合成編集"))])
        try await host.apply(edit, .wholeWork)
        #expect(store.thumbnailData(cover) == bytes)
        #expect(store.thumbnailData(orphan) == bytes)
        #expect(await store.setThumbnail(nil, owner: cover, session: session, account: account))
        let reopened = try await application.openLocal(workID: work)
        #expect(reopened.attachments.count == 1)
        #expect(reopened.attachments.first?.fileName == orphan.fileName)
    }
}
