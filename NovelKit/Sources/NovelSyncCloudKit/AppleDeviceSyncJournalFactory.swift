import Foundation
import NovelSync
import NovelSyncLegacy

actor AppleDeviceSyncJournalFactory {
    private let rootURL: URL
    private let metadataStore: AppleDeviceSyncMetadataStore
    private var journals: [LocalWorkingCopyID: AppleDeviceSyncJournalBoundary] = [:]
    private var workJournals: [LocalWorkingCopyID: AppleDeviceSyncWorkJournalBoundary] = [:]

    init(
        rootURL: URL,
        metadataStore: AppleDeviceSyncMetadataStore
    ) {
        self.rootURL = rootURL
        self.metadataStore = metadataStore
    }

    func journal(
        for binding: SyncWorkingCopyBinding
    ) async throws -> any EpisodeSyncJournal {
        // A journal is an app-private durability boundary scoped by the exact
        // local working-copy binding. Cloud account availability only fences
        // remote transport; it must never prevent an existing copy from
        // recording a detached local revision.
        guard await metadataStore.contains(binding) else {
            throw AppleDeviceSyncServicesError.bindingNotFound
        }
        if let existing = journals[binding.localWorkingCopyID] {
            return existing
        }
        let bindingRoot = rootURL.appendingPathComponent(
            binding.localWorkingCopyID.rawValue.uuidString,
            isDirectory: true
        )
        let fileJournal = try FileEpisodeSyncJournal(rootURL: bindingRoot)
        let boundary = AppleDeviceSyncJournalBoundary(
            journal: fileJournal,
            metadataStore: metadataStore,
            binding: binding
        )
        journals[binding.localWorkingCopyID] = boundary
        return boundary
    }

    func workJournal(
        for binding: SyncWorkingCopyBinding
    ) async throws -> any WorkSyncJournal {
        guard await metadataStore.contains(binding) else {
            throw AppleDeviceSyncServicesError.bindingNotFound
        }
        if let existing = workJournals[binding.localWorkingCopyID] {
            return existing
        }
        let bindingRoot = rootURL.appendingPathComponent(
            binding.localWorkingCopyID.rawValue.uuidString,
            isDirectory: true
        )
        let workRoot = bindingRoot.appendingPathComponent("work-v1", isDirectory: true)
        let fileJournal = try FileWorkSyncJournal(rootURL: workRoot)
        let boundary = AppleDeviceSyncWorkJournalBoundary(
            journal: fileJournal,
            metadataStore: metadataStore,
            binding: binding
        )
        workJournals[binding.localWorkingCopyID] = boundary
        return boundary
    }

    func noteStateStore(
        for binding: SyncWorkingCopyBinding
    ) async throws -> any NoteSyncStateStore {
        guard await metadataStore.contains(binding) else {
            throw AppleDeviceSyncServicesError.bindingNotFound
        }
        let bindingRoot = rootURL.appendingPathComponent(
            binding.localWorkingCopyID.rawValue.uuidString,
            isDirectory: true
        )
        let noteRoot = bindingRoot.appendingPathComponent("note-v1", isDirectory: true)
        return try FileNoteSyncStateStore(rootURL: noteRoot)
    }
}
