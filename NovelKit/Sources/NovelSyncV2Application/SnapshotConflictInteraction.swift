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
