import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@MainActor
struct LibraryRefreshTransitionTests {
    @Test("a library refresh completing after new work creation keeps the editor ready")
    func refreshDoesNotReplaceCreatedWork() async throws {
        let (state, gate) = try await makeState()
        let refresh = Task { await state.refreshSnapshotLibrary() }
        await gate.waitUntilSuspended()
        let created = await state.createNewDocument()
        let session = state.documentSessionToken
        let workID = state.currentSnapshotSyncV2WorkID
        let wasReady = state.startupState.isReady
        gate.resume()
        await refresh.value

        #expect(created)
        #expect(wasReady)
        #expect(state.startupState.isReady)
        #expect(workID != nil)
        #expect(state.currentSnapshotSyncV2WorkID == workID)
        #expect(state.documentSessionToken == session)
    }

    @Test("a library refresh completing after a local work open keeps the editor ready")
    func refreshDoesNotReplaceOpenedWork() async throws {
        let (state, gate) = try await makeState()
        let application = try #require(state.snapshotSyncV2Application)
        let document = NovelDocument.newDocument()
        let workID = WorkID(UUID())
        _ = try await application.checkpoint(
            workID: workID, document: document, reason: .migration, documentCreatedAt: Date()
        )
        // Populate the selectable shelf before arming the delayed read.
        gate.delaysNextRead = false
        await state.refreshSnapshotLibrary()
        let work = try #require(state.snapshotSyncLibraryWorks.first)
        gate.delaysNextRead = true
        let refresh = Task { await state.refreshSnapshotLibrary() }
        await gate.waitUntilSuspended()
        let opened = await state.openLibraryWork(work)
        let session = state.documentSessionToken
        let wasReady = state.startupState.isReady
        gate.resume()
        await refresh.value

        #expect(opened)
        #expect(wasReady)
        #expect(state.startupState.isReady)
        #expect(state.currentSnapshotSyncV2WorkID == workID)
        #expect(state.document.id == document.id)
        #expect(state.documentSessionToken == session)
    }

    private func makeState() async throws -> (AppState, LibraryReadGate) {
        let configuration = try TestRuntimeConfiguration(account: nil)
        let gate = LibraryReadGate()
        var dependencies = AppDependencies(
            userDefaults: makeIsolatedTestUserDefaults(),
            snapshotSyncV2Factory: {
                try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
            }
        )
        dependencies.snapshotSyncV2LibraryOverride = { application in
            let projection = try await application.library()
            await gate.suspendNextRead()
            return projection
        }
        let state = AppState(dependencies: dependencies, initialStartupState: .documentSelection(.init(
            works: [], presentation: .localAndRemote, connection: .offline
        )))
        try #require(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        return (state, gate)
    }
}

/// Delays exactly one refresh; creation's own background refresh remains free to finish.
@MainActor
private final class LibraryReadGate {
    var delaysNextRead = true
    private var suspended: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func suspendNextRead() async {
        guard delaysNextRead else { return }
        delaysNextRead = false
        await withCheckedContinuation { continuation in
            suspended = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilSuspended() async {
        guard suspended == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        suspended?.resume()
        suspended = nil
    }
}
