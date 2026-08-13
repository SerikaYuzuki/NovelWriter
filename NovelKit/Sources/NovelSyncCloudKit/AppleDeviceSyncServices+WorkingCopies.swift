import Foundation
import NovelCore
import NovelSync

public extension AppleDeviceSyncServices {
    /// 新規sync libraryを利用者が明示開始した場合だけzoneを作成する。
    func bootstrapZoneForNewSync() async throws {
        try await accountGate.performMutation { [cloudTransport] in
            try await cloudTransport.bootstrapZoneForNewSync()
        }
    }

    func createWork(_ descriptor: SyncWorkDescriptor) async throws {
        try await remoteBoundary.createWork(descriptor)
    }

    func listWorks() async throws -> [SyncWorkDescriptor] {
        try await remoteBoundary.listWorks()
    }

    /// structure一致だけを候補条件とし、sourceDocumentID一致は表示順hintに限る。
    /// この呼出しはbindingを一切変更しない。
    func workCandidates(
        sourceDocumentIDHint: UUID,
        matching structureDigest: SyncWorkStructureDigest
    ) async throws -> [SyncWorkDescriptor] {
        let works = try await listWorks()
        return AppleDeviceSyncWorkMatcher.candidates(
            from: works,
            sourceDocumentIDHint: sourceDocumentIDHint,
            structureDigest: structureDigest
        )
    }

    func localStatus(
        for locator: AppleLocalDocumentLocator
    ) async -> AppleDeviceSyncLocalBindingStatus {
        guard await metadataStore.containsBindingOrPendingWorkCreation(for: locator) else {
            return .unbound
        }
        switch await accountGate.availability() {
        case .ready:
            return .bound
        case let .blocked(reason):
            return .boundAndBlocked(reason)
        }
    }

    func resolveLocal(
        _ locator: AppleLocalDocumentLocator
    ) async throws -> AppleLocalResolvedWorkingCopy? {
        try await AppleLocalResolvedWorkingCopy.resolve(
            locator,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        )
    }

    /// bindingだけをAppへ渡さず、account/work/source continuity確認と
    /// binding時のepisode allowlist、copy専用journalを一つの境界で組み立てる。
    func resolve(
        _ locator: AppleLocalDocumentLocator,
        localSourceDocumentID: UUID
    ) async throws -> AppleResolvedWorkingCopy? {
        try await accountGate.requireAvailable()
        guard await metadataStore.hasPendingLibraryOpen(for: locator) == false else {
            return nil
        }
        guard let localBinding = await metadataStore.bindingSnapshot(for: locator) else {
            return nil
        }
        let works = try await remoteBoundary.listWorks()
        let descriptor = try AppleDeviceSyncWorkMatcher.requireBoundDescriptor(
            workID: localBinding.binding.workID,
            localSourceDocumentID: localSourceDocumentID,
            in: works
        )
        _ = try await accountGate.performMutation { [metadataStore] in
            try await metadataStore.completePendingWorkCreationIfConfirmed(
                locator,
                remoteDescriptor: descriptor
            )
        }
        let journal = try await journalFactory.journal(for: localBinding.binding)
        let workJournal = try await journalFactory.workJournal(for: localBinding.binding)
        return AppleResolvedWorkingCopy(
            binding: localBinding.binding,
            descriptor: descriptor,
            allowedEpisodeIDs: localBinding.allowedEpisodeIDs,
            journal: journal,
            workJournal: workJournal
        )
    }

    @discardableResult
    func bind(
        _ locator: AppleLocalDocumentLocator,
        to workID: SyncWorkID,
        localSourceDocumentID: UUID,
        allowedEpisodeIDs: [EpisodeID],
        matching structureDigest: SyncWorkStructureDigest
    ) async throws -> AppleResolvedWorkingCopy {
        let descriptor = try await requireRemoteWork(workID, matching: structureDigest)
        try AppleDeviceSyncWorkMatcher.requireSourceContinuity(
            descriptor,
            localSourceDocumentID: localSourceDocumentID
        )
        _ = try await accountGate.performMutation { [metadataStore] in
            try await metadataStore.bind(
                locator,
                to: workID,
                allowedEpisodeIDs: allowedEpisodeIDs
            )
        }
        guard let resolved = try await resolve(
            locator,
            localSourceDocumentID: localSourceDocumentID
        ) else {
            throw AppleDeviceSyncServicesError.bindingNotFound
        }
        return resolved
    }

    /// 新規work作成をlocator単位のdurable intentとして先に保存し、local bind、
    /// remote create、remote descriptorとallowlistの確認後にだけintentを消す。
    /// kill/restart後に新しいworkIDが提案されても、保存済みdescriptorを再利用する。
    @discardableResult
    func createAndBindNewWork(
        _ locator: AppleLocalDocumentLocator,
        proposedDescriptor: SyncWorkDescriptor,
        allowedEpisodeIDs: [EpisodeID]
    ) async throws -> AppleResolvedWorkingCopy {
        let metadata = await metadataStore.snapshot()
        if let existing = try Self.completedCreationBindingToResume(
            metadata: metadata,
            locator: locator,
            proposedDescriptor: proposedDescriptor
        ) {
            // Local bind may already exist while the custom zone / Note type
            // has not been materialized. `resolve` lists the catalog and would
            // fail closed before `bootstrapZoneForNewSync` / `createWork`.
            guard existing.binding.workID == proposedDescriptor.workID else {
                throw AppleDeviceSyncServicesError.pendingWorkCreationMismatch
            }
            try await bootstrapZoneForNewSync()
            try await createWork(proposedDescriptor)
            do {
                guard let resolved = try await resolve(
                    locator,
                    localSourceDocumentID: proposedDescriptor.sourceDocumentID
                ),
                    resolved.binding == existing.binding,
                    resolved.allowedEpisodeIDs == existing.allowedEpisodeIDs else {
                    throw AppleDeviceSyncServicesError.pendingWorkCreationMismatch
                }
                return resolved
            } catch {
                guard Self.canResumeCreationWithoutLiveCatalog(error) else { throw error }
                return try await resolvedWorkingCopy(
                    locator: locator,
                    descriptor: proposedDescriptor,
                    expected: existing
                )
            }
        }
        let intent = try await accountGate.performMutation { [metadataStore] in
            try await metadataStore.preparePendingWorkCreation(
                locator,
                proposedDescriptor: proposedDescriptor,
                allowedEpisodeIDs: allowedEpisodeIDs
            )
        }
        // Establish the durable local identity/journal authority before any
        // zone or remote create call. If the network drops, the exact saved
        // workID remains an offline local outbox and the next retry reuses it.
        _ = try await metadataStore.bind(
            intent.locator,
            to: intent.descriptor.workID,
            allowedEpisodeIDs: Array(intent.allowedEpisodeIDs)
        )
        try await bootstrapZoneForNewSync()
        // CloudKit側は同一workID + exact descriptorだけを冪等再試行として許す。
        try await createWork(intent.descriptor)
        let resolved = try await bindPendingWorkCreation(intent)
        try await accountGate.performMutation { [metadataStore] in
            try await metadataStore.completePendingWorkCreation(intent)
        }
        return resolved
    }

    internal static func completedCreationBindingToResume(
        metadata: AppleDeviceSyncMetadataSnapshot,
        locator: AppleLocalDocumentLocator,
        proposedDescriptor: SyncWorkDescriptor
    ) throws -> AppleDeviceSyncBindingSnapshot? {
        guard metadata.pendingWorkCreations[locator] == nil,
              let existing = metadata.bindings[locator] else { return nil }
        guard existing.binding.workID == proposedDescriptor.workID else {
            throw AppleDeviceSyncServicesError.pendingWorkCreationMismatch
        }
        return existing
    }

    private static func canResumeCreationWithoutLiveCatalog(_ error: any Error) -> Bool {
        if AppleDeviceSyncLibraryBootstrapPolicy.isEmptyCatalogSchemaError(error) {
            return true
        }
        if let servicesError = error as? AppleDeviceSyncServicesError {
            return servicesError == .remoteWorkNotFound || servicesError == .remoteWorkHasNoHead
        }
        return false
    }

    private func resolvedWorkingCopy(
        locator: AppleLocalDocumentLocator,
        descriptor: SyncWorkDescriptor,
        expected: AppleDeviceSyncBindingSnapshot
    ) async throws -> AppleResolvedWorkingCopy {
        guard let local = try await resolveLocal(locator),
              local.binding == expected.binding,
              local.allowedEpisodeIDs == expected.allowedEpisodeIDs else {
            throw AppleDeviceSyncServicesError.pendingWorkCreationMismatch
        }
        return AppleResolvedWorkingCopy(
            binding: local.binding,
            descriptor: descriptor,
            allowedEpisodeIDs: local.allowedEpisodeIDs,
            journal: local.journal,
            workJournal: local.workJournal
        )
    }

    /// 通常bindは既存locatorの行先を変えない。明示的な付け替えだけをこのAPIへ通す。
    @discardableResult
    func rebind(
        _ locator: AppleLocalDocumentLocator,
        to workID: SyncWorkID,
        localSourceDocumentID: UUID,
        allowedEpisodeIDs: [EpisodeID],
        matching structureDigest: SyncWorkStructureDigest
    ) async throws -> AppleResolvedWorkingCopy {
        let descriptor = try await requireRemoteWork(workID, matching: structureDigest)
        try AppleDeviceSyncWorkMatcher.requireSourceContinuity(
            descriptor,
            localSourceDocumentID: localSourceDocumentID
        )
        _ = try await accountGate.performMutation { [metadataStore] in
            try await metadataStore.rebind(
                locator,
                to: workID,
                allowedEpisodeIDs: allowedEpisodeIDs
            )
        }
        guard let resolved = try await resolve(
            locator,
            localSourceDocumentID: localSourceDocumentID
        ) else {
            throw AppleDeviceSyncServicesError.bindingNotFound
        }
        return resolved
    }

    @discardableResult
    func unbind(
        _ locator: AppleLocalDocumentLocator
    ) async throws -> Bool {
        try await accountGate.performMutation { [metadataStore] in
            try await metadataStore.unbind(locator) != nil
        }
    }

    func refreshTrackedChanges() async throws {
        try await accountGate.performOperation { [cloudTransport] in
            try await cloudTransport.refreshTrackedChanges()
        }
    }

    func cancelTrackedChanges() async {
        await cloudTransport.cancelTrackedChanges()
    }

    private func bindPendingWorkCreation(
        _ intent: ApplePendingWorkCreationSnapshot
    ) async throws -> AppleResolvedWorkingCopy {
        let resolved = try await bind(
            intent.locator,
            to: intent.descriptor.workID,
            localSourceDocumentID: intent.descriptor.sourceDocumentID,
            allowedEpisodeIDs: Array(intent.allowedEpisodeIDs),
            matching: intent.descriptor.structureDigest
        )
        guard resolved.descriptor == intent.descriptor,
              resolved.allowedEpisodeIDs == intent.allowedEpisodeIDs else {
            throw AppleDeviceSyncServicesError.pendingWorkCreationMismatch
        }
        return resolved
    }

    private func requireRemoteWork(
        _ workID: SyncWorkID,
        matching structureDigest: SyncWorkStructureDigest
    ) async throws -> SyncWorkDescriptor {
        let works = try await remoteBoundary.listWorks()
        return try AppleDeviceSyncWorkMatcher.requireDescriptor(
            workID: workID,
            structureDigest: structureDigest,
            in: works
        )
    }
}

enum AppleDeviceSyncWorkMatcher {
    static func candidates(
        from works: [SyncWorkDescriptor],
        sourceDocumentIDHint: UUID,
        structureDigest: SyncWorkStructureDigest
    ) -> [SyncWorkDescriptor] {
        works
            .filter { $0.structureDigest == structureDigest }
            .sorted { lhs, rhs in
                let lhsMatchesHint = lhs.sourceDocumentID == sourceDocumentIDHint
                let rhsMatchesHint = rhs.sourceDocumentID == sourceDocumentIDHint
                if lhsMatchesHint != rhsMatchesHint {
                    return lhsMatchesHint
                }
                return lhs.workID.rawValue.uuidString < rhs.workID.rawValue.uuidString
            }
    }

    static func requireDescriptor(
        workID: SyncWorkID,
        structureDigest: SyncWorkStructureDigest,
        in works: [SyncWorkDescriptor]
    ) throws -> SyncWorkDescriptor {
        guard let descriptor = works.first(where: { $0.workID == workID }) else {
            throw AppleDeviceSyncServicesError.remoteWorkNotFound
        }
        guard descriptor.structureDigest == structureDigest else {
            throw AppleDeviceSyncServicesError.structureMismatch
        }
        return descriptor
    }

    static func requireBoundDescriptor(
        workID: SyncWorkID,
        localSourceDocumentID: UUID,
        in works: [SyncWorkDescriptor]
    ) throws -> SyncWorkDescriptor {
        guard let descriptor = works.first(where: { $0.workID == workID }) else {
            throw AppleDeviceSyncServicesError.remoteWorkNotFound
        }
        try requireSourceContinuity(
            descriptor,
            localSourceDocumentID: localSourceDocumentID
        )
        return descriptor
    }

    static func requireSourceContinuity(
        _ descriptor: SyncWorkDescriptor,
        localSourceDocumentID: UUID
    ) throws {
        guard descriptor.sourceDocumentID == localSourceDocumentID else {
            throw AppleDeviceSyncServicesError.sourceDocumentMismatch
        }
    }
}
