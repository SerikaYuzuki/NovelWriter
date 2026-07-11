import Foundation
import NovelCore
@testable import NovelWriter
import Testing

@MainActor
struct AppStateWorldNoteTests {
    @Test("世界観ノートの追加・選択・本文更新を行える")
    func worldNoteOperationsUpdateDocument() throws {
        let state = makeState()

        state.addWorldNote()
        let firstID = try #require(state.selectedWorldNoteID)
        state.updateWorldNoteTitle("魔法体系", for: firstID)
        state.updateWorldNoteContent("月光を媒介にする。", for: firstID)

        state.addWorldNote()
        let secondID = try #require(state.selectedWorldNoteID)
        state.updateWorldNoteTitle("年表", for: secondID)
        state.selectWorldNote(firstID)

        #expect(state.selectedWorldNoteID == firstID)
        #expect(state.selectedWorldNote?.title == "魔法体系")
        #expect(state.selectedWorldNote?.content == "月光を媒介にする。")
        #expect(state.document.worldNotes.map(\.id) == [firstID, secondID])
    }

    @Test("世界観ノート削除後は隣接ノートへ選択を移す")
    func deletingWorldNoteFallsBackToNeighbor() throws {
        let state = makeState()
        state.addWorldNote()
        let firstID = try #require(state.selectedWorldNoteID)
        state.addWorldNote()
        let secondID = try #require(state.selectedWorldNoteID)

        state.deleteWorldNote(id: secondID)

        #expect(state.selectedWorldNoteID == firstID)
        #expect(state.document.worldNotes.map(\.id) == [firstID])
    }

    private func makeState() -> AppState {
        AppState(
            dependencies: AppDependencies(
                repository: WorldNoteRepository(),
                userDefaults: makeUserDefaults(),
                fileManager: .default
            )
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "NovelWriterWorldNotes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private actor WorldNoteRepository: DocumentRepository {
    func load(from _: URL) async throws -> NovelDocument {
        NovelDocument.newDocument()
    }

    func save(_: NovelDocument, to _: URL) async throws {}
}
