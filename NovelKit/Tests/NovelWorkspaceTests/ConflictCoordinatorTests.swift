import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
import Testing

@MainActor
struct ConflictCoordinatorTests {
    @Test("all three compatibility actions preserve the displayed projection; only keep-both allocates IDs")
    func actionsAndResults() {
        let workID = WorkID(UUID()), conflict = conflict()
        for choice in [SyncV2ConflictChoice.useDevice, .useServer, .keepBoth] {
            let action = ConflictCoordinator.action(workID: workID, conflict: conflict, choice: choice)
            #expect(action.choice == choice && action.workID == workID)
            #expect(action.conflictID == conflict.conflictID && action.revision == conflict.revision)
            #expect(action.localSnapshotID == conflict.localSnapshotID && action.remoteSnapshotID == conflict.remoteSnapshotID)
            #expect(action.sourceGeneration == conflict.sourceGeneration && action.commandID == conflict.commandID)
            #expect((action.newWorkID != nil) == (choice == .keepBoth))
            #expect((action.newDocumentID != nil) == (choice == .keepBoth))
        }
        #expect(ConflictCoordinator.accepts(.queued))
        #expect(ConflictCoordinator.accepts(.noChanges))
        #expect(!ConflictCoordinator.accepts(.staleConflictAction))
    }

    @Test("changed sheet projection or editing generation rejects without saving/resolving", arguments: [false, true])
    func staleSelection(generation: Bool) async throws {
        let host = FakeLibraryHost(), workID = try #require(host.workID), projection = conflict()
        let selection = WorkspaceConflictSelection(context: host.operationContext, conflict: projection)
        var state = state(workID, conflict: projection)
        if generation {
            host.generation += 1
        } else {
            state = self.state(workID, conflict: conflict())
        }
        var prepared = false
        let service = service(resolve: { _, _ in prepared = true; return .init(state: state, typedResult: .queued) })
        let port = WorkspaceConflictPort(isCurrent: { true }, isSaved: { true }, displayedState: { state },
                                         freeze: { _ in }, installClone: { _, _ in false }, project: { _ in }, complete: { _, _ in })
        #expect(try await service.resolveAtPreparedBoundary(host: host, selection: selection, choice: .useServer, port: port) == false)
        #expect(!prepared)
    }

    @Test("keep-both freezes before preparation; install and projection precede resume; failed handoff stays frozen",
          arguments: ["success", "install", "stale-completion"])
    func keepBothHandoff(outcome: String) async throws {
        let host = FakeLibraryHost(), workID = try #require(host.workID), projection = conflict()
        let selection = WorkspaceConflictSelection(context: host.operationContext, conflict: projection)
        let state = state(workID, conflict: projection)
        var frozen: WorkID?, events: [String] = []
        let service = service(resolve: { _, action in
            #expect(frozen == action.newWorkID)
            events.append("prepare")
            await Task.yield()
            if outcome == "stale-completion" {
                host.invalidateAccount()
            }
            var document = host.document
            document.id = action.newDocumentID!.rawValue
            return .init(state: state, typedResult: .queued,
                         openedWork: .init(workID: action.newWorkID!, document: document, documentCreatedAt: Date(), generation: 1, snapshotID: nil))
        })
        let port = WorkspaceConflictPort(
            isCurrent: { true }, isSaved: { true }, displayedState: { state },
            freeze: { frozen = $0; events.append($0 == nil ? "unfreeze" : "freeze") },
            installClone: { opened, _ in
                #expect(frozen == opened.workID)
                events.append("install")
                if outcome == "install" {
                    return false
                }
                host.document = opened.document!
                host.workID = opened.workID
                host.session = .init(generation: 2, documentID: host.document.id, workID: opened.workID)
                return true
            }, project: { _ in events.append("project") }, complete: { _, _ in events.append("resume") }
        )
        #expect(try await service.resolveAtPreparedBoundary(host: host, selection: selection, choice: .keepBoth, port: port) == (outcome == "success"))
        #expect((frozen == nil) == (outcome == "success"))
        if outcome == "success" {
            #expect(events == ["freeze", "prepare", "install", "project", "unfreeze", "resume"])
        } else {
            #expect(!events.contains("resume") && host.workID == workID)
        }
    }

    @Test("whole-work restore saves first, fixes the saved generation and preserves manuscript on failure",
          arguments: ["success", "save", "restore", "open", "failure"])
    func wholeWorkRestore(outcome: String) async throws {
        let host = FakeLibraryHost(), workID = try #require(host.workID), original = host.document
        var restored = original
        restored.title = "履歴の版"
        let snapshot = SnapshotID(data: Data()), state = state(workID)
        let opened = SyncV2OpenedWork(workID: workID, document: restored, documentCreatedAt: Date(), generation: 3, snapshotID: snapshot)
        var events: [String] = []
        let service = ConflictCoordinator(
            resolve: { _, _ in throw SyncV2Failure.offline },
            restore: { _, _ in
                events.append("restore"); await Task.yield()
                if outcome == "restore" {
                    host.generation += 1
                }
                if outcome == "failure" {
                    throw SyncV2Failure.offline
                }
                return .init(state: state, typedResult: .restored)
            }, openLocal: { _ in
                events.append("open"); await Task.yield()
                if outcome == "open" {
                    host.invalidateAccount()
                }
                return opened
            }, uiState: { _ in events.append("projection"); return state }
        )
        let run = {
            try await service.restoreAtPreparedBoundary(
                host: host, workID: workID, snapshotID: snapshot, isCurrent: { true },
                save: { events.append("save"); host.generation += 1; return outcome != "save" },
                install: { opened in events.append("install"); host.document = opened.document!; host.session?.generation += 1; return true },
                project: { _ in events.append("project") }
            )
        }
        if outcome == "failure" {
            await #expect(throws: SyncV2Failure.offline) { _ = try await run() }
        } else {
            #expect(try await run() == (outcome == "success"))
        }
        #expect(host.document == (outcome == "success" ? restored : original))
        if outcome == "success" {
            #expect(events == ["save", "restore", "open", "install", "projection", "project"])
        }
        if outcome == "save" {
            #expect(events == ["save"])
        }
    }

    @Test("server Undo rechecks scope after reading projection before adoption", arguments: [false, true])
    func undoChecksCompletion(stale: Bool) async {
        let workID = WorkID(UUID()), snapshot = SnapshotID(data: Data()), current = SnapshotID(data: Data("other".utf8))
        var valid = true, adopted = false, restored = false
        var service = service(resolve: { _, _ in throw SyncV2Failure.offline })
        let ready = SyncUIState(workID: workID, localDurability: .saved(generation: 1, snapshotID: current),
                                remoteProgress: .readyForSafeAdoption(inboxID: UUID()), lastTypedResult: .adoptionPending)
        service.stateChanges = { _, _ in AsyncStream { $0.yield(.stateChanged(workID, ready)); $0.finish() } }
        service.uiState = {
            _ in await Task.yield(); if stale {
                valid = false
            }; return ready
        }
        service.currentSnapshotID = { _ in current }
        #expect(await service.undo(workID: workID, snapshotID: snapshot, serverChoice: true, isCurrent: { valid },
                                   adopt: { adopted = true; return true }, restore: { _ in restored = true; return true }) == !stale)
        #expect(adopted == !stale && restored == !stale)
    }

    private func service(resolve: @escaping @MainActor (WorkID, SyncV2ConflictAction) async throws -> SyncV2OperationResult) -> ConflictCoordinator {
        ConflictCoordinator(resolve: resolve, restore: { _, _ in throw SyncV2Failure.offline },
                            openLocal: { _ in throw SyncV2Failure.offline }, uiState: { _ in nil })
    }

    private func conflict() -> SyncV2ConflictProjection {
        .init(conflictID: UUID(), revision: 1, baseSnapshotID: nil,
              localSnapshotID: SnapshotID(data: Data("local".utf8)), remoteSnapshotID: SnapshotID(data: Data("remote".utf8)),
              sourceGeneration: 1, commandID: UUID())
    }

    private func state(_ workID: WorkID, conflict: SyncV2ConflictProjection? = nil) -> SyncUIState {
        .init(workID: workID, localDurability: .saved(generation: 1, snapshotID: SnapshotID(data: Data())),
              remoteProgress: .needsChoice, conflict: conflict, lastTypedResult: .conflictPending)
    }
}
