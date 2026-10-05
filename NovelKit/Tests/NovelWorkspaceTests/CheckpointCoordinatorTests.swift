import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
import Testing

@MainActor
struct CheckpointCoordinatorTests {
    private func result(_ host: FakeLibraryHost, progress: SyncV2RemoteProgress = .offline) throws -> SyncV2OperationResult {
        let state = try SyncUIState(
            workID: #require(host.workID),
            localDurability: .saved(generation: 1, snapshotID: SnapshotID(data: Data())),
            remoteProgress: progress, lastTypedResult: .checkpointed
        )
        return SyncV2OperationResult(state: state, typedResult: .checkpointed)
    }

    @Test("checkpoint captures host/candidate and ignores continued editing; no remote wake", arguments: [false, true])
    func localCheckpoint(candidate: Bool) async throws {
        let host = FakeLibraryHost(), committed = try result(host)
        let value = candidate ? NovelDocument.newDocument(title: "候補") : host.document
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = CheckpointCoordinator(checkpoint: { request in
            #expect(request.workID == host.workID)
            #expect(request.document == value)
            #expect(request.reason == .autosave)
            #expect(request.documentCreatedAt == date)
            #expect(request.attachments.isEmpty)
            #expect(request.resources == nil)
            await Task.yield()
            host.generation &+= 1
            return committed
        }, wake: { _ in Issue.record("normal saving must not add a worker wake") })
        let completion = await coordinator.save(host: host, document: candidate ? value : nil,
                                                reason: .autosave, createdAt: date, attachments: [], resources: nil)
        guard case let .committed(result) = completion else { Issue.record("local commit rejected"); return }
        #expect(result.state == committed.state)
        #expect(host.document.title == "編集中")
        #expect(WorkspaceSyncProjection(state: result.state, previous: nil, presentedFailure: nil).localSaveState == .saved)
    }

    @Test("D2 rejects success and errors after work/session/account changes", arguments: ["work", "session", "account"], [false, true])
    func staleCheckpoint(change: String, fails: Bool) async throws {
        let host = FakeLibraryHost(), committed = try result(host)
        let coordinator = CheckpointCoordinator(checkpoint: { _ in
            await Task.yield()
            switch change {
            case "work": host.workID = WorkID(UUID())
            case "session": host.session?.generation &+= 1
            default: host.invalidateAccount()
            }
            if fails {
                throw SyncV2Failure.offline
            }
            return committed
        })
        let completion = await coordinator.save(
            host: host, reason: .autosave, createdAt: Date(), attachments: [], resources: nil,
            applyCommitted: { _ in Issue.record("stale state applied") },
            applyFailure: { Issue.record("stale failure applied") }
        )
        guard case let .stale(committedLocally) = completion else { Issue.record("stale completion escaped"); return }
        #expect(committedLocally == !fails)
    }

    @Test("explicit sync runs local save first; failure or a switch forbids remote", arguments: ["saved", "failed", "switched", "localOnly"])
    func explicitSyncOrder(boundary: String) async throws {
        let host = FakeLibraryHost(), committed = try result(host)
        var events: [String] = []
        let coordinator = CheckpointCoordinator(checkpoint: { _ in committed }, synchronize: { _ in
            #expect(events == ["IME/local-commit", "clean"])
            events.append("remote")
            return committed
        })
        let synced = await coordinator.explicitlySync(
            host: host,
            saveLocally: { _ in
                events.append("IME/local-commit")
                host.generation &+= 1
                if boundary == "switched" {
                    host.invalidateAccount()
                }
                return boundary != "failed"
            },
            didSave: { events.append("clean") },
            requestsRemote: { boundary != "localOnly" },
            didQueue: { _, cleanContext in
                #expect(cleanContext?.editGeneration == host.generation)
                events.append("project")
                return true
            }, localOnly: { events.append("local-only") }, failed: { Issue.record("unexpected sync failure") }
        )
        #expect(synced == (boundary == "saved" || boundary == "localOnly"))
        #expect(events == (boundary == "saved" ? ["IME/local-commit", "clean", "remote", "project"] :
                boundary == "localOnly" ? ["IME/local-commit", "clean", "local-only"] : ["IME/local-commit"]))
    }

    @Test("projection and resume discard old account/session results", arguments: [false, true])
    func projectionAndResumeFences(sessionChange: Bool) async throws {
        let host = FakeLibraryHost(), committed = try result(host)
        let invalidate = {
            if sessionChange {
                host.session?.generation &+= 1
            } else {
                host.invalidateAccount()
            }
        }
        let coordinator = CheckpointCoordinator(checkpoint: { _ in committed }, uiState: { _ in
            await Task.yield()
            invalidate()
            return committed.state
        }, wake: { _ in invalidate() })
        await coordinator.project(host: host) { _ in Issue.record("stale state applied") }
        await coordinator.resume(host: host, reason: .foreground, afterWake: { Issue.record("stale resume applied") })
    }

    @Test("remote errors preserve local durability and failure presentation is deduplicated")
    func projectionEffects() throws {
        let host = FakeLibraryHost(), state = try result(host, progress: .failed(.invalidLocalState)).state
        let first = WorkspaceSyncProjection(state: state, previous: nil, presentedFailure: nil)
        #expect(first.localSaveState == .saved)
        #expect(first.failureMessage == SyncV2FatalReason.invalidLocalState.japaneseDescription)
        #expect(first.presentedFailure == .invalidLocalState)
        #expect(WorkspaceSyncProjection(state: state, previous: state, presentedFailure: .invalidLocalState).failureMessage == nil)
        let clean = try result(host, progress: .noChanges).state
        #expect(WorkspaceSyncProjection(state: clean, previous: state, presentedFailure: .invalidLocalState).clearsPresentedFailure)
        #expect(WorkspaceSyncProjection(state: nil, previous: state, presentedFailure: nil).localSaveState == nil)
    }

    @Test("autosave's terminal callback cannot repaint after D2 rejected the checkpoint", arguments: [false, true])
    func saveEventsAreFenced(fails: Bool) {
        let host = FakeLibraryHost()
        var events: [V2DocumentSaveCoordinator.SaveEvent] = []
        let handler = WorkspaceSaveEventProjection.handler(host: host) { events.append($0) }
        handler(.saving)
        host.invalidateAccount()
        handler(fails ? .failed : .saved)
        #expect(events == [.saving])
        handler(.saving)
        host.generation &+= 1
        handler(.saved)
        #expect(events == [.saving, .saving, .saved])
    }

    @Test("retired UI does not turn a committed local revision into a retry under another account")
    func committedRevisionSurvivesAccountInvalidation() async throws {
        let host = FakeLibraryHost(), committed = try result(host)
        var events: [V2DocumentSaveCoordinator.SaveEvent] = []
        let checkpoint = CheckpointCoordinator(checkpoint: { _ in
            host.invalidateAccount()
            return committed
        })
        let save = V2DocumentSaveCoordinator(
            currentDocument: { host.document },
            saveOperation: { document in
                let completion = await checkpoint.save(host: host, document: document,
                                                       reason: .autosave, createdAt: Date(), attachments: [], resources: nil)
                guard case .stale(committedLocally: true) = completion else { throw SyncV2Failure.offline }
            },
            saveEventHandler: WorkspaceSaveEventProjection.handler(host: host) { events.append($0) }
        )
        save.markDirty()
        #expect(await save.saveNow())
        #expect(!save.hasUnsavedChanges)
        #expect(save.lastSavedRevision == 1)
        #expect(events == [.dirty, .saving])
    }

    @Test("missing current document reports a real save failure without starting a checkpoint")
    func missingDocumentStillProjectsFailure() async {
        let host = FakeLibraryHost()
        var events: [V2DocumentSaveCoordinator.SaveEvent] = []
        let save = V2DocumentSaveCoordinator(
            currentDocument: { nil },
            saveOperation: { _ in Issue.record("unexpected checkpoint") },
            saveEventHandler: WorkspaceSaveEventProjection.handler(host: host) { events.append($0) }
        )
        save.markDirty()
        #expect(await !save.saveNow())
        #expect(save.hasUnsavedChanges)
        #expect(events == [.dirty, .failed])
    }
}
