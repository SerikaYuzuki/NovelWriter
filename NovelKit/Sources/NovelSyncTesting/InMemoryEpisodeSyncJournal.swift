import NovelSync

public actor InMemoryEpisodeSyncJournal: EpisodeSyncJournal {
    private var records: [EpisodeSyncKey: EpisodeSyncJournalRecord] = [:]

    public init() {}

    public func load(for key: EpisodeSyncKey) async throws -> EpisodeSyncJournalRecord? {
        records[key]
    }

    public func save(_ record: EpisodeSyncJournalRecord) async throws {
        try record.validate()
        records[record.key] = record
    }

    public func storedRecord(for key: EpisodeSyncKey) -> EpisodeSyncJournalRecord? {
        records[key]
    }
}
