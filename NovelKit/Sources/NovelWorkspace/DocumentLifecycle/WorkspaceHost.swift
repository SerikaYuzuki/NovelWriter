import NovelCore

public enum WorkspaceSavePolicy: Equatable, Sendable {
    case flushNow
    case debounced
}

/// Minimum port for local project-feature edits; no editor, sync or authentication operations.
@MainActor
public protocol WorkspaceHost: AnyObject {
    var document: NovelDocument { get set }
    var operationContext: WorkspaceOperationContext { get }
    var permitsLocalMutation: Bool { get }
    func markChanged(policy: WorkspaceSavePolicy)

    /// Remove attached thumbnails and install the owner edit synchronously, before marking dirty.
    func applyOwnerRemoval(_ replacement: NovelDocument)
}
