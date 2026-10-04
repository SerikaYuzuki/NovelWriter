import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2Application
import NovelSyncV2Runtime
import NovelTiming
import NovelWorkspace
import Testing

@MainActor
struct SnapshotMutationBoundaryTests {
    @Test("snapshot and attachments wait for an active autosave and preserve later input")
    func mutationsWaitForAutosave() async throws {
        let config = try TestRuntimeConfiguration(account: nil)
        let state = AppState(dependencies: AppDependencies(
            userDefaults: makeIsolatedTestUserDefaults(),
            snapshotSyncV2Factory: { try await SnapshotSyncV2Runtime.makeApplication(mode: .test(config)) }
        ))
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        let workID = try #require(state.currentSnapshotSyncV2WorkID)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("attachment".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var first = true
        state.saveCoordinator = V2DocumentSaveCoordinator(
            timing: FuminiwaTiming(autosaveDebounceSeconds: 60, autosavePostSaveWaitSeconds: 60),
            currentDocument: { state.document },
            saveOperation: { document in
                if first {
                    first = false
                    started.continuation.yield(())
                    for await _ in release.stream {
                        break
                    }
                }
                guard await state.checkpointSnapshotSyncV2(document) else {
                    throw NSError(domain: "SnapshotMutationTest", code: 1)
                }
            }
        )
        state.document.title = "first revision"
        state.markDocumentDirty()
        let saving = Task { await state.saveNow() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        var snapshotFinished = false
        var attachmentFinished = false
        let snapshot = Task {
            let result = await state.saveExplicitSnapshot()
            snapshotFinished = true
            return result
        }
        let attaching = Task {
            let result = await state.addAttachment(from: source)
            attachmentFinished = true
            return result
        }
        await Task.yield()
        #expect(!snapshotFinished && !attachmentFinished)
        state.document.title = "input during save"
        state.markDocumentDirty()
        release.continuation.finish()
        #expect(await saving.value)
        #expect(await snapshot.value)
        let attachment = try #require(await attaching.value)
        let opened = try #require(try await state.snapshotSyncV2Application?.open(workID: workID))
        #expect(opened.document?.title == "input during save")
        #expect(opened.attachments.first?.bytes == Data("attachment".utf8))
        #expect(await state.deleteAttachment(attachment))
        #expect(await state.saveBeforeTermination())
        let final = try await state.snapshotSyncV2Application?.open(workID: workID)
        #expect(final?.attachments.isEmpty == true)
        #expect(final?.document?.title == "input during save")
        started.continuation.finish()
    }
}
