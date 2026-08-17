import Foundation
import NovelSyncV2
import NovelSyncV2Application

/// Fail-closed until NovelApp/NovelAppIOS supply a bridge that proves their
/// actual DocumentOperationGate is held and IME/unsaved state is safe.
actor ProductionDocumentGate: SyncV2DocumentGate {
    private var revisions: [WorkID: UInt64] = [:]

    func beginSession(workID: WorkID) -> DocumentSessionToken {
        let revision = (revisions[workID] ?? 0) + 1
        revisions[workID] = revision
        return DocumentSessionToken(
            workID: workID,
            identity: UUID(),
            revision: revision
        )
    }

    func issueToken(
        for session: DocumentSessionToken,
        expectedLocalVersion: SyncV2LocalVersion
    ) throws -> DocumentGateToken {
        _ = session
        _ = expectedLocalVersion
        throw SyncV2ApplicationError.safeBoundaryRejected
    }

    func validateAndConsume(
        _ gate: DocumentGateToken,
        session: DocumentSessionToken
    ) -> Bool {
        _ = gate
        _ = session
        return false
    }
}
