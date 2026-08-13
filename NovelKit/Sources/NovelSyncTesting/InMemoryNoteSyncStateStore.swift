import NovelSync

public actor InMemoryNoteSyncStateStore: NoteSyncStateStore {
    private var states: [SyncWorkID: NoteSyncState] = [:]

    public init() {}

    public func load(for workID: SyncWorkID) async throws -> NoteSyncState? {
        states[workID]
    }

    public func save(_ state: NoteSyncState) async throws {
        try state.validate()
        states[state.workID] = state
    }
}
