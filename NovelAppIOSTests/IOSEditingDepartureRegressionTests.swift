import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelTiming
import NovelWorkspace
import Testing

@MainActor
@Suite("iOS editing departure identity")
struct IOSEditingDepartureRegressionTests {
    @Test("waiting deletion keeps its episode IDs when the array changes", arguments: [false, true])
    func stalePositionsDoNotApplyToDifferentEpisodes(reordering: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try #require(UserDefaults(suiteName: "editing-departure-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        store.addEpisode()
        store.addEpisode()
        #expect(await store.saveNow())
        let chapter = try #require(store.selectedChapter)
        let ids = chapter.episodes.map(\.id)
        #expect(ids.count == 3)
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        store.saveCoordinator = V2DocumentSaveCoordinator(
            timing: FuminiwaTiming(autosaveDebounceSeconds: 60, autosavePostSaveWaitSeconds: 60),
            currentDocument: { store.document },
            saveOperation: { _ in
                started.continuation.yield(())
                for await _ in release.stream {
                    break
                }
            }
        )
        store.saveCoordinator.markDirty()
        let pending = Task {
            if reordering {
                return await store.moveEpisodesAfterDeviceSyncDeparture(in: chapter.id, fromOffsets: IndexSet(integer: 0), toOffset: 3)
            }
            return await store.deleteEpisodesAfterDeviceSyncDeparture(at: IndexSet(integer: 0), chapterID: chapter.id)
        }
        var start = started.stream.makeAsyncIterator()
        _ = await start.next()
        // A different already-accepted operation changes the positions during the save.
        store.deleteEpisodes(at: IndexSet(integer: 0), chapterID: chapter.id)
        release.continuation.finish()
        #expect(await pending.value == !reordering)
        #expect(store.selectedChapter?.episodes.map { $0.id } == Array(ids.dropFirst()))
        #expect(await store.saveNow())
        started.continuation.finish()
    }
}
