import Foundation
import NovelSync
import NovelSyncLegacy

actor AppleDeviceSyncJournalBoundary: EpisodeSyncJournal {
    private let journal: FileEpisodeSyncJournal
    private let metadataStore: AppleDeviceSyncMetadataStore
    private let binding: SyncWorkingCopyBinding

    init(
        journal: FileEpisodeSyncJournal,
        metadataStore: AppleDeviceSyncMetadataStore,
        binding: SyncWorkingCopyBinding
    ) {
        self.journal = journal
        self.metadataStore = metadataStore
        self.binding = binding
    }

    func load(for key: EpisodeSyncKey) async throws -> EpisodeSyncJournalRecord? {
        try await requireUsableBinding()
        return try await journal.load(for: key)
    }

    func save(_ record: EpisodeSyncJournalRecord) async throws {
        try await requireUsableBinding()
        try await journal.save(record)
    }

    private func requireUsableBinding() async throws {
        // This boundary is already scoped to a durable local working-copy ID.
        // Remote account availability fences transport creation and writes,
        // but must not disable the current holder's offline fork journal.
        guard await metadataStore.contains(binding) else {
            throw AppleDeviceSyncServicesError.bindingNotFound
        }
    }
}

/// D-061 journalにもEpisode journalと同じdurable binding fenceを適用する。
/// account availabilityはremoteだけを止め、既存copyのoffline保存は止めない。
actor AppleDeviceSyncWorkJournalBoundary: WorkSyncJournal {
    private let journal: FileWorkSyncJournal
    private let metadataStore: AppleDeviceSyncMetadataStore
    private let binding: SyncWorkingCopyBinding

    init(
        journal: FileWorkSyncJournal,
        metadataStore: AppleDeviceSyncMetadataStore,
        binding: SyncWorkingCopyBinding
    ) {
        self.journal = journal
        self.metadataStore = metadataStore
        self.binding = binding
    }

    func load(for workID: SyncWorkID) async throws -> WorkSyncJournalRecord? {
        try await requireUsableBinding()
        guard workID == binding.workID else {
            throw WorkSyncJournalError.workMismatch
        }
        guard let record = try await journal.load(for: workID) else {
            return nil
        }
        guard record.localWorkingCopyID == binding.localWorkingCopyID else {
            throw WorkSyncJournalError.workingCopyMismatch
        }
        return record
    }

    func save(_ record: WorkSyncJournalRecord) async throws {
        try await requireUsableBinding()
        guard record.workID == binding.workID,
              record.localWorkingCopyID == binding.localWorkingCopyID else {
            throw WorkSyncJournalError.workingCopyMismatch
        }
        try await journal.save(record)
    }

    private func requireUsableBinding() async throws {
        guard await metadataStore.contains(binding) else {
            throw AppleDeviceSyncServicesError.bindingNotFound
        }
    }
}
