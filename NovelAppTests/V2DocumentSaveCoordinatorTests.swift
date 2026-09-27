import Foundation
#if os(macOS)
@testable import FUMINIWA
#else
@testable import FUMINIWAIOS
#endif
import NovelCore
import Testing

@Suite("Local save revision ownership")
@MainActor
struct V2DocumentSaveCoordinatorTests {
    @Test("typing during an awaited checkpoint is saved in a second checkpoint")
    func savesEditsArrivingDuringCheckpoint() async {
        var document = NovelDocument.newDocument()
        document.title = "before"
        var saved: [String] = []
        var coordinator: V2DocumentSaveCoordinator!
        coordinator = V2DocumentSaveCoordinator(
            debounceNanoseconds: 1,
            currentDocument: { document },
            saveOperation: { snapshot in
                saved.append(snapshot.title)
                if saved.count == 1 {
                    document.title = "after"
                    coordinator.markDirty()
                    await Task.yield()
                }
            }
        )
        coordinator.markDirty()
        #expect(await coordinator.saveNow())
        #expect(saved == ["before", "after"])
        #expect(await coordinator.saveNow())
        #expect(saved.count == 2)
    }

    @Test("failed follow-up checkpoint remains dirty and is retried")
    func retriesUnsavedFollowUp() async {
        var document = NovelDocument.newDocument()
        document.title = "before"
        var saved: [String] = []
        var attempts = 0
        var coordinator: V2DocumentSaveCoordinator!
        coordinator = V2DocumentSaveCoordinator(
            debounceNanoseconds: 1,
            currentDocument: { document },
            saveOperation: { snapshot in
                attempts += 1
                if attempts == 2 {
                    throw CocoaError(.fileWriteUnknown)
                }
                saved.append(snapshot.title)
                if attempts == 1 {
                    document.title = "after"
                    coordinator.markDirty()
                }
            }
        )
        coordinator.markDirty()
        #expect(await coordinator.saveNow() == false)
        #expect(saved == ["before"])
        #expect(await coordinator.saveNow())
        #expect(saved == ["before", "after"])
    }

    @Test("debounced autosave does not cancel its own checkpoint")
    func autosaveDoesNotCancelItself() async throws {
        let document = NovelDocument.newDocument()
        var saved = false
        let coordinator = V2DocumentSaveCoordinator(
            debounceNanoseconds: 1_000_000,
            currentDocument: { document },
            saveOperation: { _ in
                try Task.checkCancellation()
                saved = true
            }
        )
        coordinator.markDirty()
        coordinator.scheduleDebouncedSave()
        for _ in 0 ..< 100 where !saved {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(saved)
    }
}
