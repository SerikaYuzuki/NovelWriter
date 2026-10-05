import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
import Testing

@MainActor
struct AdoptionCoordinatorTests {
    @Test("prepared adoption injects its gate, rechecks every await and reprojects installed identity",
          arguments: ["success", "pending", "state", "session", "arm", "token", "apply", "disarm", "projection", "failure"])
    func preparedAdoption(step: String) async throws {
        let host = FakeLibraryHost(), original = host.document
        let workID = try #require(host.workID)
        let pending = SyncV2PendingAdoption(workID: workID, inboxID: UUID(),
                                            expectedLocalVersion: .init(generation: 1, snapshotID: nil))
        let state = SyncUIState(workID: workID, localDurability: .saved(generation: 1, snapshotID: SnapshotID(data: Data())),
                                remoteProgress: .readyForSafeAdoption(inboxID: pending.inboxID), lastTypedResult: .adoptionPending)
        let session = DocumentSessionToken(workID: workID, identity: UUID(), revision: 1)
        let token = DocumentGateToken(workID: workID, sessionIdentity: session.identity, gateIdentity: UUID(),
                                      sessionRevision: 1, expectedLocalVersion: pending.expectedLocalVersion)
        var value = original
        value.title = "サーバー版"
        let opened = SyncV2OpenedWork(workID: workID, document: value, documentCreatedAt: Date(), generation: 2, snapshotID: nil)
        var events: [String] = [], projected = 0, disarmed = 0, failedAttempt = false, installed = false
        let suspend = { (at: String) in
            await Task.yield()
            events.append(at)
            if step == at {
                host.generation += 1
            }
        }
        let service = AdoptionCoordinator(
            pendingAdoption: { _ in await suspend("pending"); return pending },
            uiState: { _ in await suspend(installed ? "projection" : "state"); return state },
            gateToken: { _ in await suspend("token"); return token },
            applyStaged: { boundary in
                #expect(boundary.workID == workID && boundary.inboxID == pending.inboxID)
                await suspend("apply")
                if step == "failure" {
                    throw SyncV2Failure.offline
                }
                return opened
            }
        )
        let port = WorkspaceAdoptionPort(
            isCurrent: { true }, session: { _ in await suspend("session"); return session },
            arm: { _, candidate, _ in
                #expect(candidate.expectedLocalVersion == pending.expectedLocalVersion)
                await suspend("arm")
            }, disarm: { _ in disarmed += 1; await suspend("disarm") },
            finishAttempt: { _, failed in failedAttempt = failed },
            install: { candidate in
                events.append("install"); installed = true
                host.document = candidate.document!
                host.session?.generation += 1
                return true
            }, project: { _ in projected += 1 }
        )
        if step == "failure" {
            await #expect(throws: SyncV2Failure.offline) {
                _ = try await service.adoptAtPreparedBoundary(host: host, workID: workID, port: port)
            }
            #expect(failedAttempt)
        } else {
            #expect(try await service.adoptAtPreparedBoundary(host: host, workID: workID, port: port) == (step == "success"))
        }
        #expect(host.document == (step == "success" || step == "projection" ? value : original))
        #expect(projected == (step == "success" ? 2 : step == "pending" || step == "state" ? 0 : 1))
        #expect(disarmed == (step == "pending" || step == "state" ? 0 : 1))
        if step == "success" {
            #expect(events == ["pending", "state", "session", "arm", "token", "apply", "disarm", "install", "projection"])
        }
    }

    @Test("explicit-confirmation/different inbox or host identity blocks automatic adoption",
          arguments: ["confirmation", "inbox", "work", "session", "account"])
    func unsafeAcquisition(reason: String) async throws {
        let host = FakeLibraryHost(), workID = try #require(host.workID), original = host.document
        let pending = SyncV2PendingAdoption(workID: workID, inboxID: UUID(), expectedLocalVersion: .init(generation: 1, snapshotID: nil),
                                            requiresExplicitConfirmation: reason == "confirmation")
        let state = SyncUIState(workID: workID, localDurability: .saved(generation: 1, snapshotID: SnapshotID(data: Data())),
                                remoteProgress: .readyForSafeAdoption(inboxID: reason == "inbox" ? UUID() : pending.inboxID),
                                lastTypedResult: .adoptionPending)
        let service = AdoptionCoordinator(pendingAdoption: { _ in
            await Task.yield()
            if reason == "work" {
                host.workID = WorkID(UUID())
            }
            if reason == "session" {
                host.session?.generation += 1
            }
            if reason == "account" {
                host.invalidateAccount()
            }
            return pending
        }, uiState: { _ in state }, gateToken: { _ in throw SyncV2ApplicationError.safeBoundaryRejected },
        applyStaged: { _ in throw SyncV2ApplicationError.safeBoundaryRejected })
        let port = WorkspaceAdoptionPort(
            isCurrent: { true }, session: { _ in Issue.record("unsafe session"); return .init(workID: workID, identity: UUID(), revision: 1) },
            arm: { _, _, _ in Issue.record("unsafe arm") }, disarm: { _ in },
            claim: { !$0.requiresExplicitConfirmation }, install: { _ in Issue.record("unsafe install"); return true }, project: { _ in }
        )
        #expect(try await service.adoptAtPreparedBoundary(host: host, workID: workID, port: port) == false)
        #expect(host.document == original)
    }

    @Test("reprojection ignores unrelated events and rechecks identity after reading state", arguments: [false, true])
    func reprojection(stale: Bool) async throws {
        let host = FakeLibraryHost(), workID = try #require(host.workID)
        let state = SyncUIState(workID: workID, localDurability: .saved(generation: 1, snapshotID: SnapshotID(data: Data())),
                                remoteProgress: .idle, lastTypedResult: .noChanges)
        var projected = 0
        let service = AdoptionCoordinator(
            pendingAdoption: { _ in nil }, uiState: { _ in
                await Task.yield()
                if stale {
                    host.invalidateAccount()
                }
                return state
            }, gateToken: { _ in throw SyncV2ApplicationError.safeBoundaryRejected },
            applyStaged: { _ in throw SyncV2ApplicationError.safeBoundaryRejected },
            stateChanges: { requested, deadline in
                #expect(requested == workID)
                #expect(deadline > .now)
                return AsyncStream {
                    $0.yield(.adoptionAvailable(WorkID(UUID())))
                    $0.yield(.stateChanged(workID, state))
                    $0.finish()
                }
            }
        )
        await service.reproject(host: host, workID: workID, isCurrent: { true }, receive: { _ in
            projected += 1
            return false
        })
        #expect(projected == (stale ? 0 : 1))
    }
}
