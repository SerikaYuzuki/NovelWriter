import Foundation
import NovelCore
import NovelSyncV2
import NovelWorkspace
import Testing

@MainActor
@Suite("Shared project-feature commands")
struct ProjectFeatureCommandsTests {
    @Test("登場人物CRUDは値と配列順を更新する")
    func characterCRUDUpdatesValues() throws {
        let host = FakeWorkspaceHost()
        let store = ProjectFeatureCommands(host: host, policy: .debounced)
        let session = host.session

        let firstID = try #require(store.addCharacter(name: "主人公", expectedSession: session))
        let secondID = try #require(store.addCharacter(name: "相棒", expectedSession: session))
        #expect(host.policies == [.debounced, .debounced])

        var first = try #require(host.document.characters.first(where: { $0.id == firstID }))
        first.kana = "しゅじんこう"
        first.role = "語り手"
        first.memo = "人物メモ"
        #expect(store.updateCharacter(first, expectedSession: session))
        #expect(store.moveCharacters(fromOffsets: IndexSet(integer: 1), toOffset: 0, expectedSession: session))
        #expect(host.document.characters.first?.id == secondID)
        #expect(store.deleteCharacter(id: secondID, expectedSession: session))
        #expect(!(store.deleteCharacter(id: secondID, expectedSession: session)))

        #expect(host.document.characters == [first])
    }

    @Test("プロットカードと伏線を同じ作品でCRUDできる")
    func plotCardsAndFlagsUpdateTogether() throws {
        let host = FakeWorkspaceHost()
        let store = ProjectFeatureCommands(host: host, policy: .debounced)
        let session = host.session
        let chapterID = try #require(host.document.chapters.first?.id)

        let firstCardID = try #require(
            store.addPlotCard(title: "導入", chapterID: chapterID, expectedSession: session)
        )
        let secondCardID = try #require(store.addPlotCard(title: "転換", expectedSession: session))
        var firstCard = try #require(host.document.plotCards.first(where: { $0.id == firstCardID }))
        firstCard.memo = "事件が始まる"
        #expect(store.updatePlotCard(firstCard, expectedSession: session))
        #expect(store.movePlotCards(fromOffsets: IndexSet(integer: 1), toOffset: 0, expectedSession: session))
        #expect(host.document.plotCards.first?.id == secondCardID)
        #expect(store.deletePlotCard(id: secondCardID, expectedSession: session))
        #expect(store.addPlotCard(title: "不正", chapterID: ChapterID(), expectedSession: session) == nil)

        let firstFlagID = try #require(store.addFlag(title: "消えた鍵", expectedSession: session))
        let secondFlagID = try #require(store.addFlag(title: "古い手紙", expectedSession: session))
        var firstFlag = try #require(host.document.flags.first(where: { $0.id == firstFlagID }))
        firstFlag.note = "終盤で回収"
        firstFlag.plantedChapterID = chapterID
        firstFlag.resolvedChapterID = chapterID
        firstFlag.isResolved = true
        #expect(store.updateFlag(firstFlag, expectedSession: session))
        #expect(store.moveFlags(fromOffsets: IndexSet(integer: 1), toOffset: 0, expectedSession: session))
        #expect(host.document.flags.first?.id == secondFlagID)
        #expect(store.deleteFlag(id: secondFlagID, expectedSession: session))

        #expect(host.document.plotCards == [firstCard])
        #expect(host.document.flags == [firstFlag])
    }

    @Test("世界観ノートCRUDは配列順と本文を更新する")
    func worldNoteCRUDUpdatesValues() throws {
        let host = FakeWorkspaceHost()
        let store = ProjectFeatureCommands(host: host, policy: .debounced)
        let session = host.session

        let firstID = try #require(store.addWorldNote(WorldNote(title: "王都"), expectedSession: session))
        let secondID = try #require(store.addWorldNote(WorldNote(title: "魔法"), expectedSession: session))
        var first = try #require(host.document.worldNotes.first(where: { $0.id == firstID }))
        first.content = "城壁に囲まれた都市。"
        #expect(store.updateWorldNote(first, expectedSession: session))
        #expect(store.moveWorldNotes(fromOffsets: IndexSet(integer: 1), toOffset: 0, expectedSession: session))
        #expect(host.document.worldNotes.first?.id == secondID)
        #expect(store.deleteWorldNote(id: secondID, expectedSession: session))

        #expect(host.document.worldNotes == [first])
    }

    @Test("作品未選択中のmetadata mutationを拒否する")
    func metadataMutationsRequireActiveWorkingCopy() {
        let host = FakeWorkspaceHost()
        host.permitsLocalMutation = false
        let store = ProjectFeatureCommands(host: host, policy: .debounced)
        let unavailableSession = host.session

        #expect(store.addCharacter(expectedSession: unavailableSession) == nil)
        #expect(store.addPlotCard(expectedSession: unavailableSession) == nil)
        #expect(store.addFlag(expectedSession: unavailableSession) == nil)
        #expect(store.addWorldNote(WorldNote(title: ""), expectedSession: unavailableSession) == nil)
        #expect(host.document.characters.isEmpty)
        #expect(host.document.plotCards.isEmpty)
        #expect(host.document.flags.isEmpty)
        #expect(host.document.worldNotes.isEmpty)
    }

    @Test("A→B→A後の古いmetadata操作は同じ子IDへ適用しない")
    func staleMetadataMutationIsRejectedAfterReturningToWorkingCopy() throws {
        let host = FakeWorkspaceHost()
        let store = ProjectFeatureCommands(host: host, policy: .debounced)
        let originalSession = host.session
        _ = try #require(store.addCharacter(expectedSession: originalSession))
        _ = try #require(store.addPlotCard(expectedSession: originalSession))
        _ = try #require(store.addFlag(expectedSession: originalSession))
        _ = try #require(store.addWorldNote(WorldNote(title: ""), expectedSession: originalSession))
        host.session.generation += 2
        let policies = host.policies

        let snapshot = ProjectMetadataSnapshot(document: host.document)
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
        #expect(ProjectMetadataSnapshot(document: host.document) == snapshot)
        #expect(host.policies == policies)
    }

    @Test("無効なmove・章・同値更新は保存通知しない")
    func invalidInputsDoNotMarkChanged() throws {
        let host = FakeWorkspaceHost()
        let commands = ProjectFeatureCommands(host: host, policy: .debounced)
        let session = host.session
        _ = try #require(commands.addCharacter(expectedSession: session))
        _ = try #require(commands.addPlotCard(expectedSession: session))
        _ = try #require(commands.addFlag(expectedSession: session))
        _ = try #require(commands.addWorldNote(WorldNote(title: ""), expectedSession: session))
        let snapshot = ProjectMetadataSnapshot(document: host.document)
        let policies = host.policies
        for (offsets, destination) in [(IndexSet(), 0), (IndexSet(integer: 99), 0),
                                       (IndexSet(integer: 1), 0), (IndexSet(integer: 0), -1),
                                       (IndexSet(integer: 0), 2)] {
            #expect(!commands.moveCharacters(fromOffsets: offsets, toOffset: destination, expectedSession: session))
            #expect(!commands.movePlotCards(fromOffsets: offsets, toOffset: destination, expectedSession: session))
            #expect(!commands.moveFlags(fromOffsets: offsets, toOffset: destination, expectedSession: session))
            #expect(!commands.moveWorldNotes(fromOffsets: offsets, toOffset: destination, expectedSession: session))
        }
        let missingChapter = ChapterID()
        #expect(commands.addPlotCard(chapterID: missingChapter, expectedSession: session) == nil)
        #expect(commands.addFlag(plantedChapterID: missingChapter, expectedSession: session) == nil)
        var card = try #require(snapshot.plotCards.first)
        var flag = try #require(snapshot.flags.first)
        #expect(!commands.updatePlotCard(card, expectedSession: session))
        #expect(!commands.updateFlag(flag, expectedSession: session))
        #expect(try !commands.updateCharacter(#require(snapshot.characters.first), expectedSession: session))
        #expect(try !commands.updateWorldNote(#require(snapshot.worldNotes.first), expectedSession: session))
        card.chapterID = missingChapter
        #expect(!commands.updatePlotCard(card, expectedSession: session))
        flag.plantedChapterID = missingChapter
        #expect(!commands.updateFlag(flag, expectedSession: session))
        flag.plantedChapterID = nil
        flag.resolvedChapterID = missingChapter
        #expect(!commands.updateFlag(flag, expectedSession: session))
        #expect(!commands.movePlotCard(id: card.id, toChapter: missingChapter, expectedSession: session))
        #expect(ProjectMetadataSnapshot(document: host.document) == snapshot)
        #expect(host.policies == policies)
    }

    @Test("owner削除はcleanupとinstall後に指定policyで保存通知する")
    func ownerRemovalPrecedesSaveNotification() throws {
        let host = FakeWorkspaceHost()
        let session = host.session
        let commands = ProjectFeatureCommands(host: host, policy: .flushNow)
        let characterID = try #require(commands.addCharacter(expectedSession: session))
        let noteID = try #require(commands.addWorldNote(WorldNote(title: ""), expectedSession: session))
        #expect(commands.deleteCharacter(id: characterID, expectedSession: session))
        #expect(commands.deleteWorldNote(id: noteID, expectedSession: session))
        #expect(host.ownerRemovals.count == 2)
        #expect(host.ownerRemovals[0].characters.isEmpty)
        #expect(host.ownerRemovals[1].worldNotes.isEmpty)
        #expect(host.markedDocuments[2].characters.isEmpty)
        #expect(host.markedDocuments[3].worldNotes.isEmpty)
        #expect(host.policies == [.flushNow, .flushNow, .flushNow, .flushNow])
    }
}

private struct ProjectMetadataSnapshot: Equatable {
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
    store: ProjectFeatureCommands,
    session: WorkspaceSessionToken,
    snapshot: ProjectMetadataSnapshot
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
    #expect(store.addWorldNote(WorldNote(title: "遅延追加"), expectedSession: session) == nil)
    #expect(!store.updateCharacter(character, expectedSession: session))
    #expect(!store.updatePlotCard(plotCard, expectedSession: session))
    #expect(!store.updateFlag(flag, expectedSession: session))
    #expect(!store.updateWorldNote(worldNote, expectedSession: session))
}

@MainActor
private func expectStaleMetadataMovesAndDeletesRejected(
    store: ProjectFeatureCommands,
    session: WorkspaceSessionToken,
    snapshot: ProjectMetadataSnapshot
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
