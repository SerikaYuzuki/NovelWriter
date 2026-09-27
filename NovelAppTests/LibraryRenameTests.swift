import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@MainActor
struct LibraryRenameTests {
    @Test("一覧からの名前変更は編集中本文を保存し、同じ作品と選択を維持する")
    func activeWorkRenamePreservesEditor() async throws {
        let state = try await makeState()
        let chapterID = try #require(state.selectedChapterID)
        let episodeID = try #require(state.selectedEpisodeID)
        state.updateEpisodeContent("変更前の入力", for: episodeID, in: chapterID)
        let session = state.documentSessionToken
        let generation = state.editorContentGeneration
        await state.refreshSnapshotLibrary()
        let work = try #require(state.snapshotSyncLibraryWorks.first { $0.workID == state.currentSnapshotSyncV2WorkID })
        #expect(await state.renameLibraryWork(work, title: "一覧で変更", expectedSession: session,
                                              accountScope: state.snapshotSyncV2AccountScopeToken))
        #expect(state.document.title == "一覧で変更")
        #expect(state.selectedEpisodeID == episodeID)
        #expect(state.documentSessionToken == session)
        #expect(state.editorContentGeneration == generation)
        let application = try #require(state.snapshotSyncV2Application)
        let saved = try await application.openLocal(workID: work.workID)
        #expect(saved.document?.title == "一覧で変更")
        #expect(saved.document?.episode(episodeID)?.episode.content == "変更前の入力")
        #expect(state.snapshotSyncLibraryWorks.first { $0.workID == work.workID }?.title == "一覧で変更")
        let staleAccount = state.snapshotSyncV2AccountScopeToken
        state.snapshotSyncV2AccountScopeGeneration += 1
        #expect(await !(state.renameLibraryWork(work, title: "古いアカウント", expectedSession: session,
                                                accountScope: staleAccount)))
        #expect(state.document.title == "一覧で変更")
    }

    @Test("別の作品の名前を変更しても現在の作品を切り替えない")
    func otherWorkRenameKeepsCurrentWork() async throws {
        let state = try await makeState()
        let application = try #require(state.snapshotSyncV2Application)
        let otherID = WorkID(UUID())
        let other = NovelDocument.newDocument(title: "別作品")
        _ = try await application.checkpoint(workID: otherID, document: other, reason: .explicit,
                                             documentCreatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        await state.refreshSnapshotLibrary()
        let work = try #require(state.snapshotSyncLibraryWorks.first { $0.workID == otherID })
        let document = state.document
        let session = state.documentSessionToken
        #expect(await state.renameLibraryWork(work, title: "別作品の新名", expectedSession: session,
                                              accountScope: state.snapshotSyncV2AccountScopeToken))
        #expect(state.document == document)
        #expect(state.documentSessionToken == session)
        #expect(try await application.openLocal(workID: otherID).document?.title == "別作品の新名")
        state.documentSessionToken.generation += 1
        #expect(await !(state.renameLibraryWork(work, title: "古い画面", expectedSession: session,
                                                accountScope: state.snapshotSyncV2AccountScopeToken)))
    }

    private func makeState() async throws -> AppState {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let state = AppState(dependencies: AppDependencies(
            userDefaults: UserDefaults(suiteName: "LibraryRename.\(UUID())")!,
            snapshotSyncV2Factory: { try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration)) }
        ))
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        return state
    }
}
