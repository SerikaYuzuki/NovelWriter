import NovelSync

public actor InMemoryEpisodeSyncJournal: EpisodeSyncJournal {
    private var records: [EpisodeSyncKey: EpisodeSyncJournalRecord] = [:]
    private var shouldPauseNextLoad = false
    private var pausedLoadContinuation: CheckedContinuation<Void, Never>?
    private var loadPauseObservers: [CheckedContinuation<Void, Never>] = []
    private var shouldPauseNextSave = false
    private var pausedSaveContinuation: CheckedContinuation<Void, Never>?
    private var savePauseObservers: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func load(for key: EpisodeSyncKey) async throws -> EpisodeSyncJournalRecord? {
        let captured = records[key]
        if shouldPauseNextLoad {
            shouldPauseNextLoad = false
            let observers = loadPauseObservers
            loadPauseObservers.removeAll()
            await withCheckedContinuation { continuation in
                pausedLoadContinuation = continuation
                for observer in observers {
                    observer.resume()
                }
            }
        }
        return captured
    }

    public func save(_ record: EpisodeSyncJournalRecord) async throws {
        try record.validate()
        if shouldPauseNextSave {
            shouldPauseNextSave = false
            let observers = savePauseObservers
            savePauseObservers.removeAll()
            await withCheckedContinuation { continuation in
                pausedSaveContinuation = continuation
                for observer in observers {
                    observer.resume()
                }
            }
        }
        records[record.key] = record
    }

    public func storedRecord(for key: EpisodeSyncKey) -> EpisodeSyncJournalRecord? {
        records[key]
    }

    public func pauseNextLoadAfterCapture() {
        shouldPauseNextLoad = true
    }

    public func waitUntilLoadIsPaused() async {
        if pausedLoadContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            loadPauseObservers.append(continuation)
        }
    }

    public func resumePausedLoad() {
        let continuation = pausedLoadContinuation
        pausedLoadContinuation = nil
        continuation?.resume()
    }

    public func pauseNextSaveBeforeCommit() {
        shouldPauseNextSave = true
    }

    public func waitUntilSaveIsPaused() async {
        if pausedSaveContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            savePauseObservers.append(continuation)
        }
    }

    public func resumePausedSave() {
        let continuation = pausedSaveContinuation
        pausedSaveContinuation = nil
        continuation?.resume()
    }
}
