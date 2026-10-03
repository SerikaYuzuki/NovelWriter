import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@Suite("Production document gate disarming")
struct ProductionDocumentGateTests {
    private let version = SyncV2LocalVersion(generation: 1, snapshotID: nil)
    private let proof = SyncV2SafeBoundaryProof(
        editorGeneration: 1, hasMarkedText: false,
        hasUnsavedChanges: false, pendingIntentCleared: true
    )

    @Test("matching disarm prevents issuance until the boundary is armed again")
    func matchingDisarmClearsBoundary() async throws {
        let gate = ProductionDocumentGate()
        let session = await gate.beginSession(workID: WorkID(UUID()))
        try await gate.arm(session: session, expectedLocalVersion: version, proof: proof)
        await gate.disarm(session: session)
        await gate.disarm(session: session)
        await #expect(throws: SyncV2ApplicationError.safeBoundaryRejected) {
            try await gate.issueToken(for: session, expectedLocalVersion: version)
        }
        try await gate.arm(session: session, expectedLocalVersion: version, proof: proof)
        let token = try await gate.issueToken(for: session, expectedLocalVersion: version)
        #expect(await gate.validateAndConsume(token, session: session))
    }

    @Test("a stale session cannot disarm the replacement boundary or validate its old token")
    func staleDisarmKeepsNewBoundary() async throws {
        let gate = ProductionDocumentGate()
        let workID = WorkID(UUID())
        let oldSession = await gate.beginSession(workID: workID)
        try await gate.arm(session: oldSession, expectedLocalVersion: version, proof: proof)
        let oldToken = try await gate.issueToken(for: oldSession, expectedLocalVersion: version)
        let newSession = await gate.beginSession(workID: workID)
        try await gate.arm(session: newSession, expectedLocalVersion: version, proof: proof)
        await gate.disarm(session: oldSession)
        #expect(await !gate.validateAndConsume(oldToken, session: oldSession))
        let token = try await gate.issueToken(for: newSession, expectedLocalVersion: version)
        #expect(await gate.validateAndConsume(token, session: newSession))
    }

    @Test("disarming an unarmed Work preserves another Work's boundary")
    func disarmIsScopedToWork() async throws {
        let gate = ProductionDocumentGate()
        let first = await gate.beginSession(workID: WorkID(UUID()))
        let second = await gate.beginSession(workID: WorkID(UUID()))
        try await gate.arm(session: first, expectedLocalVersion: version, proof: proof)
        await gate.disarm(session: second)
        let token = try await gate.issueToken(for: first, expectedLocalVersion: version)
        #expect(await gate.validateAndConsume(token, session: first))
        await #expect(throws: SyncV2ApplicationError.safeBoundaryRejected) {
            try await gate.issueToken(for: second, expectedLocalVersion: version)
        }
    }

    @Test("disarm preserves an issued token's single-use proof")
    func disarmDoesNotRevokeIssuedToken() async throws {
        let gate = ProductionDocumentGate()
        let session = await gate.beginSession(workID: WorkID(UUID()))
        try await gate.arm(session: session, expectedLocalVersion: version, proof: proof)
        let token = try await gate.issueToken(for: session, expectedLocalVersion: version)
        await gate.disarm(session: session)
        await #expect(throws: SyncV2ApplicationError.safeBoundaryRejected) {
            try await gate.issueToken(for: session, expectedLocalVersion: version)
        }
        #expect(await gate.validateAndConsume(token, session: session))
        #expect(await !gate.validateAndConsume(token, session: session))
    }
}
