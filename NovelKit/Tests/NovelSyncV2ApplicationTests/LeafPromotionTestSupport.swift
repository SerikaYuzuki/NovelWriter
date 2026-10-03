import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
import NovelSyncV2Store
import NovelTiming
import Testing

/// No wall-clock sleeps: cancellation and time advancement release continuations.
final class LeafTestClock: @unchecked Sendable {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 0)
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelled: Set<UUID> = []

    var clock: SyncV2PromotionClock {
        SyncV2PromotionClock(now: { self.lock.withLock { self.instant } }, sleep: { try await self.sleep($0) })
    }

    var waitingCount: Int {
        lock.withLock { sleepers.count }
    }

    func advance(_ seconds: TimeInterval) {
        let ready = lock.withLock {
            instant.addTimeInterval(seconds)
            let ready = sleepers.filter { $0.value.deadline <= instant }
            for key in ready.keys {
                sleepers.removeValue(forKey: key)
            }
            return ready.values.map(\.continuation)
        }
        for continuation in ready {
            continuation.resume()
        }
    }

    func cancelAll() {
        let waiting = lock.withLock {
            let waiting = Array(sleepers.values)
            sleepers.removeAll()
            return waiting
        }
        for sleeper in waiting {
            sleeper.continuation.resume(throwing: CancellationError())
        }
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if cancelled.remove(id) != nil || Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if seconds <= 0 {
                        continuation.resume()
                    } else {
                        sleepers[id] = Sleeper(deadline: instant.addingTimeInterval(seconds), continuation: continuation)
                    }
                }
            }
        } onCancel: {
            let sleeper = self.lock.withLock {
                self.cancelled.insert(id)
                return self.sleepers.removeValue(forKey: id)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}

struct LeafRuntimeFixture: Sendable {
    let configuration: TestRuntimeConfiguration
    let store: LocalSyncV2Store
    let app: SyncV2Application
    let workID: WorkID
    let baseline: SnapshotID
    let document: NovelDocument
    let clock: LeafTestClock
    let gate: InMemorySyncV2DocumentGate

    static func make(timing: FuminiwaTiming = .init()) async throws -> LeafRuntimeFixture {
        let configuration = try TestRuntimeConfiguration()
        let store = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .createNew)
        let workID = WorkID(UUID())
        let document = applicationTestDocument(title: "baseline", body: "stable body")
        let encoded = try SnapshotCodec.encode(SnapshotModel(
            workId: workID, document: document, documentCreatedAt: applicationTestCreatedAt
        ))
        let inbox = try V2RemoteSnapshot(workID: workID, encoded: encoded,
                                         expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                         expectedRemoteHead: V2RemoteHead(snapshotID: encoded.snapshotId, generation: 1))
        try await store.stageRemote(inbox, scope: productionScope)
        try await store.verifyInbox(inboxID: inbox.inboxID, scope: productionScope)
        try await store.adoptInbox(inboxID: inbox.inboxID, scope: productionScope)
        await configuration.remote.setCommandHandler(leafSuccessResponse)
        let resolver = TestScopeResolver(vault: configuration.vault, store: store)
        let kernel = ProductionSyncV2Kernel(store: store, scope: resolver)
        let clock = LeafTestClock()
        let gate = InMemorySyncV2DocumentGate()
        let app = try SyncV2Application(mode: .test(configuration), composition: SyncV2RuntimeComposition(
            identity: .test, kernel: kernel, planner: ProductionSyncV2Planner(store: store, scope: resolver),
            remote: configuration.remote, gate: gate, library: kernel
        ), timing: timing, promotionClock: clock.clock, automaticSyncSleep: { try await clock.clock.sleep(Double($0) / 1_000_000_000) })
        try await app.resumePending()
        return LeafRuntimeFixture(configuration: configuration, store: store, app: app, workID: workID,
                                  baseline: encoded.snapshotId, document: document, clock: clock, gate: gate)
    }

    func edit(_ text: String) async throws -> NovelDocument {
        var edited = document
        edited.chapters[0].episodes[0].content = text
        _ = try await app.checkpoint(workID: workID, document: edited, reason: .autosave,
                                     documentCreatedAt: applicationTestCreatedAt)
        return edited
    }

    func assertOnePublication(expected: NovelDocument) async throws {
        try await leafEventually {
            let commands = try await store.allSealedCommands(scope: productionScope, workID: workID)
            return commands.contains { $0.commandKind == "publish" && $0.lifecycle == .completed }
        }
        let commands = try await store.allSealedCommands(scope: productionScope, workID: workID)
        let registrations = commands.filter { $0.commandKind == "registerSnapshot" }
        let publications = commands.filter { $0.commandKind == "publish" }
        #expect(registrations.count == 1)
        #expect(publications.count == 1)
        let published = try #require(publications.first)
        #expect(published.sourceSnapshotID == registrations.first?.sourceSnapshotID)
        let encoded = try #require(try await store.committedSnapshot(
            workID: workID, snapshotID: published.sourceSnapshotID, scope: productionScope
        ))
        #expect(encoded.manifest.parentSnapshotIds == [baseline])
        #expect(try SnapshotCodec.decode(encoded).document == expected)
        #expect(try await !store.hasUnpromotedLeaf(workID: workID, scope: productionScope))
    }

    func close() async {
        await app.cancelLeafPromotion(workID: workID)
        await app.cancelWorker(for: workID)
        clock.cancelAll()
        await store.close()
        try? FileManager.default.removeItem(at: configuration.localRoot.url)
    }
}

func leafEventually(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
    for _ in 0 ..< 20000 {
        if try await condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("leaf state did not settle")
}

func leafSuccessResponse(_ command: SyncV2SealedRemoteCommand) throws -> SyncV2RemoteExecution {
    let result: V2CommandTerminalResult = command.kind == .prepareObject ? .noChanges : .applied
    let status = command.kind == .createWork ? 201 : 200
    let head: V2RemoteHead?
    if command.kind == .restore {
        let payload = try productionPayload(command.command)
        head = try V2RemoteHead(snapshotID: SnapshotID(rawValue: productionString(payload, key: "newSnapshotId")),
                                generation: command.command.sourceGeneration + 1)
    } else if command.kind == .publish {
        head = try V2RemoteHead(snapshotID: command.command.sourceSnapshotId, generation: command.command.sourceGeneration)
    } else {
        head = nil
    }
    let response = try productionResponse(command: command.command, result: result, head: head, cloneHead: nil, status: status)
    let envelope = try productionEnvelope(command: command.command, response: response, result: result, status: status)
    return .command(receipt: SyncV2ReceiptReadback(
        commandID: command.command.commandId, requestDigest: command.command.requestDigest,
        responseStatus: status, canonicalResponse: envelope,
        predicates: SyncV2ReadBackPredicates(accountMatched: true, commandDigestMatched: true,
                                             resourceMatched: true, headMatched: true, stateMatched: true),
        result: result == .noChanges ? .noChanges : .applied
    ), remoteInbox: nil)
}
