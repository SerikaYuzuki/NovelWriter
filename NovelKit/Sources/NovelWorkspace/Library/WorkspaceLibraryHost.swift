import NovelSyncV2

public enum WorkspaceLibraryMutation: Sendable {
    case rename, deletion
}

/// The platform retains its document gate, IME commit and exclusive local save
/// lane. The operation runs only after that boundary has committed local input.
@MainActor
public protocol WorkspaceLibraryHost: WorkspaceHost {
    func permitsLibraryMutation(_ mutation: WorkspaceLibraryMutation, workID: WorkID) -> Bool
    func libraryMutationBoundary(
        _ mutation: WorkspaceLibraryMutation, workID: WorkID, context: WorkspaceOperationContext,
        operation: @MainActor () async throws -> Void
    ) async -> Bool
    var permitsLibraryLocalCompletion: Bool { get }
    var permitsLibraryDeletionSending: Bool { get }
    func cancelLibraryBackgroundOperations()
    func retireLibraryWork(_ workID: WorkID)
    func refreshWorkspaceLibrary() async
    func removeDeletedLibraryWork(_ workID: WorkID)
    func willSendLibraryDeletion(_ workID: WorkID)
    /// iOS projects a durable intent before HTTP; macOS projects after the result.
    var projectsDeletionBeforeSending: Bool { get }
}
