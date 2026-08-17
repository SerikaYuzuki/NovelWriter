import Foundation
import NovelSyncV2
import NovelSyncV2Application

/// Production gate adapter. The host arms it only after its document gate and
/// editor/IME safe boundary have been proven.
public actor ProductionDocumentGate: SyncV2ArmableDocumentGate {
    public struct ArmedBoundary: Sendable {
        let session: DocumentSessionToken
        let expectedVersion: SyncV2LocalVersion
        let editorGeneration: UInt64
    }

    private var revisions: [WorkID: UInt64] = [:]
    private var sessions: [WorkID: DocumentSessionToken] = [:]
    private var armed: [WorkID: ArmedBoundary] = [:]
    private var issued: Set<UUID> = []

    public init() {}

    public func beginSession(workID: WorkID) -> DocumentSessionToken {
        let revision = (revisions[workID] ?? 0) + 1
        revisions[workID] = revision
        let session = DocumentSessionToken(
            workID: workID,
            identity: UUID(),
            revision: revision
        )
        sessions[workID] = session
        armed[workID] = nil
        return session
    }

    public func issueToken(
        for session: DocumentSessionToken,
        expectedLocalVersion: SyncV2LocalVersion
    ) throws -> DocumentGateToken {
        guard let boundary = armed[session.workID],
              boundary.session == session,
              boundary.expectedVersion == expectedLocalVersion,
              sessions[session.workID] == session else {
            throw SyncV2ApplicationError.safeBoundaryRejected
        }
        let identity = UUID()
        issued.insert(identity)
        return DocumentGateToken(
            workID: session.workID,
            sessionIdentity: session.identity,
            gateIdentity: identity,
            sessionRevision: session.revision,
            expectedLocalVersion: expectedLocalVersion
        )
    }

    public func validateAndConsume(
        _ gate: DocumentGateToken,
        session: DocumentSessionToken
    ) -> Bool {
        guard sessions[session.workID] == session,
              gate.workID == session.workID,
              gate.sessionIdentity == session.identity,
              gate.sessionRevision == session.revision,
              issued.remove(gate.gateIdentity) != nil else { return false }
        armed[session.workID] = nil
        return true
    }

    public func arm(
        session: DocumentSessionToken,
        expectedLocalVersion: SyncV2LocalVersion,
        proof: SyncV2SafeBoundaryProof
    ) throws {
        guard !proof.hasMarkedText,
              !proof.hasUnsavedChanges,
              proof.pendingIntentCleared,
              sessions[session.workID] == session else {
            throw SyncV2ApplicationError.safeBoundaryRejected
        }
        armed[session.workID] = ArmedBoundary(
            session: session,
            expectedVersion: expectedLocalVersion,
            editorGeneration: proof.editorGeneration
        )
    }
}
