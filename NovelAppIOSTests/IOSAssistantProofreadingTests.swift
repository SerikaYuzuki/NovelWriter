@testable import EditorKit
import Foundation
@testable import FUMINIWAIOS
import Testing

@MainActor
struct IOSAssistantProofreadingTests {
    @Test("iOS校正の応答は取得した話・account・編集世代にだけ反映する")
    func appliesOnlyToCapturedContext() async throws {
        try await withStore { store in
            let editing = try #require(store.currentEpisodeEditingToken)
            let account = store.snapshotSyncV2AccountScope
            let surface = EditorSurfaceToken()
            store.editorCommandSession.activateEditorSurface(surface)
            var applied: [String] = []
            store.editorCommandSession.registerProofreadingHandler(for: surface, apply: { expected, replacement in
                applied.append("\(expected)→\(replacement)"); return true
            }, clear: {})
            let manuscript = AssistantManuscript(title: "第一話", content: "本文")
            #expect(store.applyAssistantProofreading(manuscript, replacement: "校正本文", editingToken: editing, account: account))
            let otherAccount = IOSSnapshotSyncV2AccountScope(accountID: "other", accountFence: nil, serverInstanceID: nil, protocolEpoch: nil)
            #expect(!store.applyAssistantProofreading(manuscript, replacement: "別account", editingToken: editing, account: otherAccount))
            store.editorContentGeneration &+= 1
            #expect(!store.applyAssistantProofreading(manuscript, replacement: "旧世代", editingToken: editing, account: account))
            let newEditing = try #require(store.currentEpisodeEditingToken)
            store.addEpisode()
            #expect(!store.applyAssistantProofreading(manuscript, replacement: "別の話", editingToken: newEditing, account: account))
            #expect(applied == ["本文→校正本文"])
            #expect(await store.saveNow())
        }
    }

    @Test("iOS校正の色は通常保存で残り、明示checkpointの成功後だけ消える", arguments: [false, true])
    func clearsOnlyAfterSuccessfulExplicitCheckpoint(fails: Bool) async throws {
        try await withStore { store in
            let surface = EditorSurfaceToken()
            store.editorCommandSession.activateEditorSurface(surface)
            var clearCount = 0
            store.editorCommandSession.registerProofreadingHandler(for: surface, apply: { _, _ in true }, clear: {
                #expect(store.editorCommandSession.isDocumentTransitionPrepared)
                clearCount += 1
            })
            store.saveCoordinator = V2DocumentSaveCoordinator(
                debounceNanoseconds: 60_000_000_000,
                currentDocument: { store.document },
                saveOperation: { _ in if fails { throw CocoaError(.fileWriteUnknown) } }
            )
            store.saveCoordinator.markDirty()
            #expect(await store.saveNow() == !fails)
            #expect(clearCount == 0)
            #expect(await store.prepareForEditorSurfaceDeparture(clearProofreadingHighlights: true) == !fails)
            #expect(clearCount == (fails ? 0 : 1))
            #expect(!store.editorCommandSession.isDocumentTransitionPrepared)
        }
    }

    private func withStore(_ body: @MainActor (IOSDocumentStore) async throws -> Void) async throws {
        let suite = "proofreading-ios.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        try await body(store)
    }
}
