import Foundation

/// `await`をまたぐdocument操作のsession／lifecycle判定を純粋な値として表す。
///
/// UI状態の所有者はAppStateのままだが、判定規則はI/OやMainActorから分離して
/// call siteとunit testだけで確認できるようにする。
enum DocumentLifecyclePermissionPolicy {
    static func permitsMutation(
        currentSession: DocumentSessionToken,
        expectedSession: DocumentSessionToken?,
        isTerminationPending: Bool,
        isDocumentTransitionInProgress: Bool
    ) -> Bool {
        guard !isTerminationPending, !isDocumentTransitionInProgress else { return false }
        guard let expectedSession else { return true }
        return currentSession == expectedSession
    }

    static func permitsEditorSynchronization(
        currentSession: DocumentSessionToken,
        expectedSession: DocumentSessionToken?,
        isTerminationPending: Bool,
        isDocumentTransitionInProgress: Bool
    ) -> Bool {
        guard !isDocumentTransitionInProgress else { return false }
        guard let expectedSession else { return !isTerminationPending }
        return currentSession == expectedSession
    }
}
