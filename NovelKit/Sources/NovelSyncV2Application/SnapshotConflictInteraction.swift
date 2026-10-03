import NovelSyncV2

/// Acquired synchronously by the button before starting its asynchronous action.
public struct SnapshotConflictChoiceGate: Sendable {
    public private(set) var isInFlight = false
    public init() {}
    public mutating func begin() -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        return true
    }

    public mutating func retryAfterFailure() {
        isInFlight = false
    }
}

public enum SnapshotConflictUndo {
    /// The network wait owns no document gate. Only the final restore callback
    /// enters the platform's IME/save/install boundary.
    @MainActor
    public static func restore(application: SyncV2Application, workID: WorkID,
                               snapshotID: SnapshotID, serverChoice: Bool,
                               isCurrent: () -> Bool,
                               adopt: () async -> Bool,
                               restore: (SnapshotID) async -> Bool) async -> Bool {
        if serverChoice {
            let events = await application.stateChanges(for: workID, until: .now.advanced(by: .seconds(30)))
            for await _ in events {
                guard !Task.isCancelled, isCurrent() else { return false }
                if case .readyForSafeAdoption = await application.uiState(workID: workID)?.remoteProgress {
                    _ = await adopt()
                }
                if let current = try? await application.currentSnapshotID(workID: workID), current != snapshotID {
                    break
                }
            }
            guard let current = try? await application.currentSnapshotID(workID: workID), current != snapshotID else { return false }
        }
        guard !Task.isCancelled, isCurrent() else { return false }
        return await restore(snapshotID)
    }
}
