import Foundation
import NovelSyncV2
import NovelSyncV2Application

/// macOS adapter for the shared v2 safe-adoption token.
///
/// The application calls `arm` only from inside the main-actor
/// `DocumentOperationGate` after `beginDocumentTransition()` has made the
/// editor first responder resign and committed the IME boundary.  The arm is
/// single-use: the shared gate still performs the final local-generation and
/// pending-intent CAS in SQLite before installing the staged Inbox.
actor MacSyncV2DocumentGate: SyncV2ArmableDocumentGate {
    private let issuer = InMemorySyncV2DocumentGate()
    private var armed: (
        session: NovelSyncV2Application.DocumentSessionToken,
        version: SyncV2LocalVersion
    )?

    func beginSession(
        workID: NovelSyncV2.WorkID
    ) async -> NovelSyncV2Application.DocumentSessionToken {
        await issuer.beginSession(workID: workID)
    }

    func arm(
        session: NovelSyncV2Application.DocumentSessionToken,
        expectedLocalVersion: SyncV2LocalVersion,
        proof: SyncV2SafeBoundaryProof
    ) async throws {
        guard proof.hasMarkedText == false,
              proof.hasUnsavedChanges == false,
              proof.pendingIntentCleared else {
            armed = nil
            throw SyncV2ApplicationError.safeBoundaryRejected
        }
        armed = (session, expectedLocalVersion)
    }

    func disarm(session: NovelSyncV2Application.DocumentSessionToken) {
        guard armed?.session == session else { return }
        armed = nil
    }

    func issueToken(
        for session: NovelSyncV2Application.DocumentSessionToken,
        expectedLocalVersion: SyncV2LocalVersion
    ) async throws -> DocumentGateToken {
        guard let armed,
              armed.session == session,
              armed.version == expectedLocalVersion else {
            throw SyncV2ApplicationError.safeBoundaryRejected
        }
        return try await issuer.issueToken(
            for: session,
            expectedLocalVersion: expectedLocalVersion
        )
    }

    func validateAndConsume(
        _ gate: DocumentGateToken,
        session: NovelSyncV2Application.DocumentSessionToken
    ) async -> Bool {
        defer { armed = nil }
        guard armed?.session == session else { return false }
        return await issuer.validateAndConsume(gate, session: session)
    }
}
