import Foundation
@testable import FUMINIWA
import NovelCore
import NovelWorkspace
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
        #expect(state.workspaceModel.document.worldNotes.map { $0.id } == [firstID, secondID])
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
        #expect(state.workspaceModel.document.worldNotes.map { $0.id } == [firstID])
    }

    @Test("Mac adapterは追加時flush・入力中debounceを維持する", .timeLimit(.minutes(1)))
    func projectFeatureAdapterPreservesSavePolicies() async throws {
        let state = makeState()
        let events = AsyncStream<String>.makeStream()
        defer { events.continuation.finish() }
        state.saveCoordinator = V2DocumentSaveCoordinator(
            debounceSleep: { _ in
                events.continuation.yield("debounced")
                throw CancellationError()
            },
            currentDocument: { state.workspaceModel.document },
            saveOperation: { _ in },
            saveEventHandler: { event in
                if event == .saved {
                    events.continuation.yield("saved")
                }
            }
        )
        var iterator = events.stream.makeAsyncIterator()
        state.addWorldNote()
        #expect(state.selectedWorldNote?.title == "")
        #expect(await iterator.next() == "saved")
        let revision = state.saveCoordinator.lastSavedRevision
        let id = try #require(state.selectedWorldNoteID)
        state.updateWorldNoteTitle("設定", for: id)
        #expect(await iterator.next() == "debounced")
        #expect(state.saveCoordinator.lastSavedRevision == revision)
    }

    private func makeState() -> AppState {
        AppState(
            dependencies: AppDependencies(
                repository: WorldNoteRepository(),
                userDefaults: makeUserDefaults(),
                fileManager: .default
            ),
            initialStartupState: .ready
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "FUMINIWAWorldNotes.\(UUID().uuidString)"
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
