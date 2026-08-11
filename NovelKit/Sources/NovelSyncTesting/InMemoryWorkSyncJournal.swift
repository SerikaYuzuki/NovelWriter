import NovelSync

public enum InMemoryWorkSyncJournalError: Error, Equatable, Sendable {
    case injectedSaveFailure
}

public actor InMemoryWorkSyncJournal: WorkSyncJournal {
    private var records: [SyncWorkID: WorkSyncJournalRecord] = [:]
    private var pauseNextSave = false
    private var pausedSave: CheckedContinuation<Void, Never>?
    private var successfulSavesBeforeFailure: Int?

    public init() {}

    public func load(for workID: SyncWorkID) async throws -> WorkSyncJournalRecord? {
        records[workID]
    }

    public func save(_ record: WorkSyncJournalRecord) async throws {
        try record.validate()
        if let remaining = successfulSavesBeforeFailure {
            if remaining == 0 {
                successfulSavesBeforeFailure = nil
                throw InMemoryWorkSyncJournalError.injectedSaveFailure
            }
            successfulSavesBeforeFailure = remaining - 1
        }
        if pauseNextSave {
            pauseNextSave = false
            await withCheckedContinuation { continuation in
                pausedSave = continuation
            }
        }
        records[record.workID] = record
    }

    public func storedRecord(for workID: SyncWorkID) -> WorkSyncJournalRecord? {
        records[workID]
    }

    public func pauseNextSaveBeforeCommit() {
        pauseNextSave = true
    }

    public func failNextSave() {
        successfulSavesBeforeFailure = 0
    }

    /// Atomicity tests can fail the save after a known number of successful
    /// commits, exposing accidental multi-save state transitions.
    public func failSave(afterSuccessfulSaves count: Int) {
        precondition(count >= 0)
        successfulSavesBeforeFailure = count
    }

    public func cancelScheduledSaveFailure() {
        successfulSavesBeforeFailure = nil
    }

    public func saveIsPaused() -> Bool {
        pausedSave != nil
    }

    @discardableResult
    public func waitUntilSaveIsPaused(maximumPollCount: Int = 2000) async -> Bool {
        for _ in 0 ..< maximumPollCount {
            if pausedSave != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    public func resumePausedSave() {
        let continuation = pausedSave
        pausedSave = nil
        continuation?.resume()
    }
}
