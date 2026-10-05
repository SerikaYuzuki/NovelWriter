/// Fences the save coordinator's terminal event as well as the checkpoint itself.
/// A stale checkpoint returns false; its resulting `.failed` event must not repaint
/// the new work through the autosave callback.
@MainActor
public final class WorkspaceSaveEventProjection {
    private weak var host: (any WorkspaceHost)?
    private var context: WorkspaceOperationContext?
    private let apply: @MainActor @Sendable (V2DocumentSaveCoordinator.SaveEvent) -> Void

    private init(host: any WorkspaceHost, apply: @escaping @MainActor @Sendable (V2DocumentSaveCoordinator.SaveEvent) -> Void) {
        self.host = host
        self.apply = apply
    }

    public static func handler(
        host: any WorkspaceHost,
        apply: @escaping @MainActor @Sendable (V2DocumentSaveCoordinator.SaveEvent) -> Void
    ) -> @MainActor @Sendable (V2DocumentSaveCoordinator.SaveEvent) -> Void {
        let projection = Self(host: host, apply: apply)
        return { projection.handle($0) }
    }

    private func handle(_ event: V2DocumentSaveCoordinator.SaveEvent) {
        guard let host else { return }
        switch event {
        case .saving:
            context = CheckpointCoordinator.context(of: host)
        case .saved, .failed:
            let expected = context
            context = nil
            if let expected, !CheckpointCoordinator.matches(expected, host: host) {
                return
            }
        case .dirty:
            break
        }
        apply(event)
    }
}
