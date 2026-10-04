import NovelSyncV2
import NovelSyncV2Application

public extension ConflictCoordinator {
    /// Wait without owning a document gate. Restore enters the OS's existing
    /// IME/save/install boundary; each asynchronous completion is scope checked.
    func undo(
        workID: WorkID, snapshotID: SnapshotID, serverChoice: Bool,
        isCurrent: @escaping () -> Bool, adopt: () async -> Bool,
        restore: (SnapshotID) async -> Bool
    ) async -> Bool {
        let accepts = { !Task.isCancelled && isCurrent() }
        guard accepts() else { return false }
        if serverChoice {
            let events = await stateChanges(workID, .now.advanced(by: .seconds(30)))
            guard accepts() else { return false }
            for await event in events {
                guard accepts() else { return false }
                guard event.concerns(workID) else { continue }
                let state = await uiState(workID)
                guard accepts() else { return false }
                if case .readyForSafeAdoption = state?.remoteProgress {
                    _ = await adopt()
                    guard accepts() else { return false }
                }
                let current = try? await currentSnapshotID(workID)
                guard accepts() else { return false }
                if let current, current != snapshotID {
                    break
                }
            }
            let current = try? await currentSnapshotID(workID)
            guard accepts(), let current, current != snapshotID else { return false }
        }
        guard accepts() else { return false }
        return await restore(snapshotID)
    }
}
