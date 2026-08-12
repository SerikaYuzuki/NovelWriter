import Foundation
import NovelCore
import NovelSync

public struct AppleDeviceSyncPendingOpenToken: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum AppleDeviceSyncLibraryConnection: Equatable, Sendable {
    case available
    case offline
    case accountRequired
    case differentAccount
}

public enum AppleDeviceSyncLibraryCacheStatus: Equatable, Sendable {
    case current
    case stale
}

/// `locallyBound` is deliberately not named `cached`: the App must load the
/// app-private package and compare its `WorkSnapshot` before showing cached-exact.
public enum AppleDeviceSyncLibraryAvailability: Equatable, Sendable {
    case locallyBound
    case remoteOnly
    case remoteDownloadPending
    case publishPending
}

public enum AppleDeviceSyncRemoteContentScope: Equatable, Sendable {
    /// NovelDocument fields in WorkSnapshot v1 only. Attachments, saved package
    /// snapshots, device settings, and unknown root items are not downloaded.
    case workSnapshotV1ExcludingPackageResources
}

public struct AppleDeviceSyncLibraryEntry: Identifiable, Equatable, Sendable {
    public var id: SyncWorkID {
        work.workID
    }

    public let work: SyncWorkLibraryEntry
    public let availability: AppleDeviceSyncLibraryAvailability

    public init(
        work: SyncWorkLibraryEntry,
        availability: AppleDeviceSyncLibraryAvailability
    ) {
        self.work = work
        self.availability = availability
    }
}

public struct AppleDeviceSyncLibrarySnapshot: Equatable, Sendable {
    public let entries: [AppleDeviceSyncLibraryEntry]
    public let connection: AppleDeviceSyncLibraryConnection
    public let cacheStatus: AppleDeviceSyncLibraryCacheStatus

    public init(
        entries: [AppleDeviceSyncLibraryEntry],
        connection: AppleDeviceSyncLibraryConnection,
        cacheStatus: AppleDeviceSyncLibraryCacheStatus = .current
    ) {
        self.entries = entries
        self.connection = connection
        self.cacheStatus = cacheStatus
    }
}

/// Downloaded WorkSnapshot only. D-061 does not include attachments, package
/// snapshots, device settings, or unknown package-root items.
public struct AppleDeviceSyncPreparedRemoteWork: Sendable {
    public let token: AppleDeviceSyncPendingOpenToken
    public let destinationLocator: AppleLocalDocumentLocator
    public let entry: SyncWorkLibraryEntry
    public let revision: WorkRevision
    public let contentScope = AppleDeviceSyncRemoteContentScope
        .workSnapshotV1ExcludingPackageResources

    public func materializedDocument() throws -> NovelDocument {
        try revision.snapshot.materializedDocument()
    }
}

struct ApplePendingLibraryOpenSnapshot: Equatable, Sendable {
    let token: AppleDeviceSyncPendingOpenToken
    let locator: AppleLocalDocumentLocator
    let entry: SyncWorkLibraryEntry
}

extension AppleDeviceSyncMetadataSnapshot {
    /// A missing zone is an initial empty-library state only when this account
    /// has no evidence of a previously published/downloaded remote graph.
    /// Unconfirmed local create intents may resume because their exact WorkID
    /// and binding are already durable and `bootstrapZoneForNewSync` is the only
    /// path that can create the zone. Confirmed bindings, cached remote heads,
    /// and pending downloads keep the old fail-closed zone-reset behavior.
    var permitsInitialZoneCreation: Bool {
        guard accountScope != nil,
              cachedLibraryEntries.isEmpty,
              pendingLibraryOpens.isEmpty else { return false }

        for (locator, binding) in bindings {
            guard let pending = pendingWorkCreations[locator],
                  pending.descriptor.workID == binding.binding.workID else {
                return false
            }
        }
        return true
    }

    /// Development can report `invalidArguments` when the custom zone exists
    /// but the first WorkControl record type has not been materialized yet.
    /// Only an exact durable create intent may cross that bootstrap window.
    var permitsPendingCreateSchemaBootstrap: Bool {
        guard accountScope != nil,
              cachedLibraryEntries.isEmpty,
              pendingLibraryOpens.isEmpty,
              !pendingWorkCreations.isEmpty,
              bindings.count == pendingWorkCreations.count else { return false }

        for (locator, binding) in bindings {
            guard let pending = pendingWorkCreations[locator],
                  pending.descriptor.workID == binding.binding.workID else {
                return false
            }
        }
        return true
    }
}

enum AppleDeviceSyncLibraryBootstrapPolicy {
    static func permitsEmptyAvailableCatalog(
        for error: any Error,
        metadata: AppleDeviceSyncMetadataSnapshot
    ) -> Bool {
        guard let adapterError = error as? CloudKitSyncAdapterError else { return false }
        return switch adapterError {
        case .zoneUnavailable:
            metadata.permitsInitialZoneCreation
        case .invalidArguments:
            metadata.permitsPendingCreateSchemaBootstrap
        default:
            false
        }
    }
}

protocol AppleDeviceSyncLibraryRemote: SyncWorkLibraryCatalog, WorkSyncTransport {}

extension AppleDeviceSyncRemoteBoundary: AppleDeviceSyncLibraryRemote {}

struct AppleDeviceSyncLibraryOpenCoordinator: Sendable {
    let replicaID: SyncReplicaID
    let metadataStore: AppleDeviceSyncMetadataStore
    let journalFactory: AppleDeviceSyncJournalFactory

    func prepareOpen(
        _ expected: SyncWorkLibraryEntry,
        remote: any AppleDeviceSyncLibraryRemote
    ) async throws -> AppleDeviceSyncPreparedRemoteWork {
        if let pending = await metadataStore.pendingLibraryOpen(workID: expected.workID) {
            guard pending.entry == expected else {
                throw AppleDeviceSyncServicesError.pendingLibraryOpenMismatch
            }
            return try await resume(pending, remote: remote)
        }

        // A catalog read is validation, not an asset fetch. Persist the exact
        // intent after validating the moving head and before fetching its asset.
        let currentEntries = try await remote.listLibraryWorks()
        guard let current = currentEntries.first(where: { $0.workID == expected.workID }) else {
            throw AppleDeviceSyncServicesError.remoteWorkNotFound
        }
        guard current == expected else {
            throw AppleDeviceSyncServicesError.libraryEntryChanged
        }
        let intent = try await metadataStore.preparePendingLibraryOpen(current)
        return try await downloadAndStage(intent, remote: remote)
    }

    func resumePendingOpen(
        _ workID: SyncWorkID,
        remote: (any AppleDeviceSyncLibraryRemote)?
    ) async throws -> AppleDeviceSyncPreparedRemoteWork {
        guard let intent = await metadataStore.pendingLibraryOpen(workID: workID) else {
            throw AppleDeviceSyncServicesError.pendingLibraryOpenMismatch
        }
        return try await resume(intent, remote: remote)
    }

    func completePreparedOpen(
        _ prepared: AppleDeviceSyncPreparedRemoteWork,
        packageSnapshot: WorkSnapshot
    ) async throws -> AppleResolvedWorkingCopy {
        guard let intent = await metadataStore.pendingLibraryOpen(token: prepared.token),
              intent.locator == prepared.destinationLocator,
              intent.entry == prepared.entry else {
            throw AppleDeviceSyncServicesError.pendingLibraryOpenMismatch
        }
        try packageSnapshot.validate()
        guard packageSnapshot == prepared.revision.snapshot else {
            throw AppleDeviceSyncServicesError.packageSnapshotMismatch
        }
        do {
            try prepared.entry.requireExactHead(prepared.revision)
        } catch {
            throw AppleDeviceSyncServicesError.packageSnapshotMismatch
        }
        guard let staged = try await restoredPreparedOpen(intent),
              staged.revision == prepared.revision else {
            throw AppleDeviceSyncServicesError.pendingLibraryOpenMismatch
        }

        let binding = try await requireBinding(for: intent)
        let workJournal = try await journalFactory.workJournal(for: binding.binding)
        let episodeJournal = try await journalFactory.journal(for: binding.binding)
        let document = try packageSnapshot.materializedDocument()
        let resolved = try AppleResolvedWorkingCopy(
            binding: binding.binding,
            descriptor: SyncWorkDescriptor(
                workID: prepared.entry.workID,
                sourceDocumentID: document.id,
                structureDigest: SyncWorkStructureDigest(chapters: document.chapters),
                title: document.title
            ),
            allowedEpisodeIDs: binding.allowedEpisodeIDs,
            journal: episodeJournal,
            workJournal: workJournal
        )
        // Clearing the intent exposes the binding to normal local resolution.
        // It is deliberately the final fallible operation: after this atomic
        // commit succeeds, a crash cannot strand an unresumable half-result.
        try await metadataStore.completePendingLibraryOpen(intent)
        return resolved
    }

    func canResumePendingOpenOffline(_ workID: SyncWorkID) async -> Bool {
        guard let intent = await metadataStore.pendingLibraryOpen(workID: workID) else {
            return false
        }
        do {
            return try await restoredPreparedOpen(intent) != nil
        } catch {
            return false
        }
    }

    private func resume(
        _ intent: ApplePendingLibraryOpenSnapshot,
        remote: (any AppleDeviceSyncLibraryRemote)?
    ) async throws -> AppleDeviceSyncPreparedRemoteWork {
        if let restored = try await restoredPreparedOpen(intent) {
            return restored
        }
        guard let remote else {
            throw WorkSyncTransportError.unavailable
        }
        return try await downloadAndStage(intent, remote: remote)
    }

    private func downloadAndStage(
        _ intent: ApplePendingLibraryOpenSnapshot,
        remote: any AppleDeviceSyncLibraryRemote
    ) async throws -> AppleDeviceSyncPreparedRemoteWork {
        guard let headID = intent.entry.headRevisionID else {
            throw AppleDeviceSyncServicesError.remoteWorkHasNoHead
        }
        let revision = try await remote.fetchRevision(headID, for: intent.entry.workID)
        do {
            try intent.entry.requireExactHead(revision)
        } catch {
            throw AppleDeviceSyncServicesError.libraryEntryChanged
        }

        // Bind and persist the full immutable revision before returning it to
        // the App. The pending intent keeps this locator invisible until the
        // package is atomically installed and read back. This makes every
        // post-download crash window resumable without network.
        let document = try revision.snapshot.materializedDocument()
        let binding = try await metadataStore.bind(
            intent.locator,
            to: intent.entry.workID,
            allowedEpisodeIDs: document.chapters.flatMap(\.episodes).map(\.id)
        )
        let workJournal = try await journalFactory.workJournal(for: binding.binding)
        let coordinator = WorkSyncCoordinator(
            workID: binding.binding.workID,
            localWorkingCopyID: binding.binding.localWorkingCopyID,
            replicaID: replicaID,
            sessionID: SyncEditSessionID(),
            transport: remote,
            journal: workJournal
        )
        if try await coordinator.restore() == nil {
            _ = try await coordinator.bootstrapRemoteRevision(revision)
        }
        guard let prepared = try await restoredPreparedOpen(intent),
              prepared.revision == revision else {
            throw AppleDeviceSyncServicesError.pendingLibraryOpenMismatch
        }
        return prepared
    }

    private func restoredPreparedOpen(
        _ intent: ApplePendingLibraryOpenSnapshot
    ) async throws -> AppleDeviceSyncPreparedRemoteWork? {
        guard let binding = await metadataStore.bindingSnapshot(for: intent.locator) else {
            return nil
        }
        guard binding.binding.workID == intent.entry.workID else {
            throw AppleDeviceSyncServicesError.pendingLibraryOpenMismatch
        }
        let workJournal = try await journalFactory.workJournal(for: binding.binding)
        guard let record = try await workJournal.load(for: intent.entry.workID) else {
            return nil
        }
        try record.validate()
        guard record.workID == intent.entry.workID,
              record.localWorkingCopyID == binding.binding.localWorkingCopyID,
              record.replicaID == replicaID,
              record.lastKnownRemoteHead == record.localHead,
              record.outbox.isEmpty,
              record.sealedPublish == nil,
              record.stagedLocalRevision == nil,
              record.retainedLocalRecoveryRevision == nil,
              record.conflictReview == nil,
              record.pendingRemoteMaterialization?.kind == .remoteBootstrap,
              record.pendingRemoteMaterialization?.revision == record.localHead,
              record.reconciliationStatus == .materializationRequired else {
            throw AppleDeviceSyncServicesError.pendingLibraryOpenMismatch
        }
        do {
            try intent.entry.requireExactHead(record.localHead)
        } catch {
            throw AppleDeviceSyncServicesError.pendingLibraryOpenMismatch
        }
        return AppleDeviceSyncPreparedRemoteWork(
            token: intent.token,
            destinationLocator: intent.locator,
            entry: intent.entry,
            revision: record.localHead
        )
    }

    private func requireBinding(
        for intent: ApplePendingLibraryOpenSnapshot
    ) async throws -> AppleDeviceSyncBindingSnapshot {
        guard let binding = await metadataStore.bindingSnapshot(for: intent.locator),
              binding.binding.workID == intent.entry.workID else {
            throw AppleDeviceSyncServicesError.pendingLibraryOpenMismatch
        }
        return binding
    }
}

public extension AppleDeviceSyncServices {
    func loadLibrary() async throws -> AppleDeviceSyncLibrarySnapshot {
        let remoteEntries: [SyncWorkLibraryEntry]
        do {
            remoteEntries = try await remoteBoundary.listLibraryWorks()
            try await accountGate.requireAvailable()
        } catch {
            let metadata = await metadataStore.snapshot()
            if AppleDeviceSyncLibraryBootstrapPolicy.permitsEmptyAvailableCatalog(
                for: error,
                metadata: metadata
            ) {
                // `listLibraryWorks` runs behind the live account gate. A clean
                // container may have neither the custom zone nor, after a kill
                // between zone and first-record creation, the WorkControl type.
                // Only the exact initial states accepted above break that
                // list-before-create cycle. Prior remote evidence stays closed.
                try await accountGate.requireAvailable()
                return makeLibrarySnapshot(
                    metadata: metadata,
                    remoteEntries: [],
                    connection: .available,
                    includeRemoteOnly: false
                )
            }
            if CloudKitErrorMapper.isTransient(error) {
                return makeLibrarySnapshot(
                    metadata: metadata,
                    remoteEntries: Array(metadata.cachedLibraryEntries.values),
                    connection: .offline,
                    includeRemoteOnly: true
                )
            }
            if let servicesError = error as? AppleDeviceSyncServicesError,
               case let .blocked(reason) = servicesError {
                return await makeLibrarySnapshot(
                    metadata: metadataStore.snapshot(),
                    remoteEntries: [],
                    connection: reason == .differentCloudAccount
                        ? .differentAccount
                        : .accountRequired,
                    includeRemoteOnly: false
                )
            }
            throw error
        }

        let metadata = await metadataStore.snapshot()
        let entriesToCache = prioritizedLibraryCache(
            remoteEntries,
            metadata: metadata
        )
        let cacheStatus: AppleDeviceSyncLibraryCacheStatus
        do {
            try await metadataStore.replaceCachedLibraryEntries(entriesToCache)
            cacheStatus = .current
        } catch {
            // Remote truth is still usable. The metadata commit is atomic, so
            // preserving the previous cache is safer than failing the live shelf.
            cacheStatus = .stale
        }
        do {
            try await accountGate.requireAvailable()
        } catch {
            let connection: AppleDeviceSyncLibraryConnection = if let servicesError = error as? AppleDeviceSyncServicesError,
                                                                  case let .blocked(reason) = servicesError,
                                                                  reason == .differentCloudAccount {
                .differentAccount
            } else {
                .accountRequired
            }
            return await makeLibrarySnapshot(
                metadata: metadataStore.snapshot(),
                remoteEntries: [],
                connection: connection,
                includeRemoteOnly: false,
                cacheStatus: .stale
            )
        }
        return await makeLibrarySnapshot(
            metadata: metadataStore.snapshot(),
            remoteEntries: remoteEntries,
            connection: .available,
            includeRemoteOnly: true,
            cacheStatus: cacheStatus
        )
    }

    /// Persists the exact-head/destination intent before any asset fetch. The
    /// immutable revision is staged in the hidden work journal before return.
    func prepareOpen(
        _ expected: SyncWorkLibraryEntry
    ) async throws -> AppleDeviceSyncPreparedRemoteWork {
        try await AppleDeviceSyncLibraryOpenCoordinator(
            replicaID: replicaID,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        ).prepareOpen(
            expected,
            remote: remoteBoundary
        )
    }

    /// Resumes the durable exact revision. If its work journal was staged by a
    /// prior successful download, no moving-head catalog read is performed.
    func resumePendingOpen(
        _ workID: SyncWorkID
    ) async throws -> AppleDeviceSyncPreparedRemoteWork {
        try await AppleDeviceSyncLibraryOpenCoordinator(
            replicaID: replicaID,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        ).resumePendingOpen(workID, remote: remoteBoundary)
    }

    /// True only when the full exact revision is already durable in the hidden
    /// work journal. The App must still attest its installed package snapshot.
    func canResumePendingOpenOffline(_ workID: SyncWorkID) async -> Bool {
        await AppleDeviceSyncLibraryOpenCoordinator(
            replicaID: replicaID,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        ).canResumePendingOpenOffline(workID)
    }

    /// Called only after the App atomically installed and read back the private
    /// package. The exact package snapshot is fenced to the prepared remote head
    /// before binding; the initial work journal is a remote bootstrap with no outbox.
    @discardableResult
    func bindPreparedOpen(
        _ prepared: AppleDeviceSyncPreparedRemoteWork,
        packageSnapshot: WorkSnapshot
    ) async throws -> AppleResolvedWorkingCopy {
        try await AppleDeviceSyncLibraryOpenCoordinator(
            replicaID: replicaID,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        ).completePreparedOpen(prepared, packageSnapshot: packageSnapshot)
    }

    private func makeLibrarySnapshot(
        metadata: AppleDeviceSyncMetadataSnapshot,
        remoteEntries: [SyncWorkLibraryEntry],
        connection: AppleDeviceSyncLibraryConnection,
        includeRemoteOnly: Bool,
        cacheStatus: AppleDeviceSyncLibraryCacheStatus = .current
    ) -> AppleDeviceSyncLibrarySnapshot {
        var entriesByWorkID: [SyncWorkID: AppleDeviceSyncLibraryEntry] = [:]
        let boundWorkIDs = Set(metadata.bindings.values.map(\.binding.workID))

        for pending in metadata.pendingWorkCreations.values {
            if let entry = try? SyncWorkLibraryEntry(descriptor: pending.descriptor) {
                entriesByWorkID[entry.workID] = AppleDeviceSyncLibraryEntry(
                    work: entry,
                    availability: .publishPending
                )
            }
        }
        if includeRemoteOnly {
            for pending in metadata.pendingLibraryOpens.values {
                entriesByWorkID[pending.entry.workID] = AppleDeviceSyncLibraryEntry(
                    work: pending.entry,
                    availability: .remoteDownloadPending
                )
            }
        }
        for entry in remoteEntries {
            if metadata.pendingWorkCreations.values.contains(where: {
                $0.descriptor.workID == entry.workID
            }) {
                // Until remote confirmation clears the durable creation intent,
                // the verified local package title remains the display truth.
                continue
            }
            if metadata.pendingLibraryOpens[entry.workID] != nil {
                // A newer moving remote head must not replace an attested
                // downloaded revision while its two-phase open is incomplete.
                continue
            }
            let availability: AppleDeviceSyncLibraryAvailability
            if boundWorkIDs.contains(entry.workID) {
                availability = .locallyBound
            } else if includeRemoteOnly {
                availability = .remoteOnly
            } else {
                continue
            }
            entriesByWorkID[entry.workID] = AppleDeviceSyncLibraryEntry(
                work: entry,
                availability: availability
            )
        }
        let sorted = entriesByWorkID.values.sorted { lhs, rhs in
            switch (lhs.work.headClientCreatedAt, rhs.work.headClientCreatedAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                lhsDate > rhsDate
            case (nil, _?):
                false
            case (_?, nil):
                true
            default:
                lhs.work.workID.rawValue.uuidString
                    < rhs.work.workID.rawValue.uuidString
            }
        }
        return AppleDeviceSyncLibrarySnapshot(
            entries: sorted,
            connection: connection,
            cacheStatus: cacheStatus
        )
    }

    private func prioritizedLibraryCache(
        _ entries: [SyncWorkLibraryEntry],
        metadata: AppleDeviceSyncMetadataSnapshot
    ) -> [SyncWorkLibraryEntry] {
        let localWorkIDs = Set(metadata.bindings.values.map(\.binding.workID))
            .union(metadata.pendingLibraryOpens.keys)
        let ordered = entries.sorted { lhs, rhs in
            let lhsIsLocal = localWorkIDs.contains(lhs.workID)
            let rhsIsLocal = localWorkIDs.contains(rhs.workID)
            if lhsIsLocal != rhsIsLocal {
                return lhsIsLocal
            }
            switch (lhs.headClientCreatedAt, rhs.headClientCreatedAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                return lhs.workID.rawValue.uuidString < rhs.workID.rawValue.uuidString
            }
        }
        return Array(ordered.prefix(AppleDeviceSyncMetadataStore.maximumCachedLibraryEntryCount))
    }
}

public extension AppleDeviceSyncBlockedServices {
    /// Remote catalog titles are quarantined while account identity is not
    /// verified. Only locally originated pending-create metadata may be shown.
    func loadLibrary() async -> AppleDeviceSyncLibrarySnapshot {
        let metadata = await metadataStore.snapshot()
        var entries: [AppleDeviceSyncLibraryEntry] = []
        for pending in metadata.pendingWorkCreations.values {
            if let entry = try? SyncWorkLibraryEntry(descriptor: pending.descriptor) {
                entries.append(
                    AppleDeviceSyncLibraryEntry(work: entry, availability: .publishPending)
                )
            }
        }
        entries.sort {
            $0.work.workID.rawValue.uuidString < $1.work.workID.rawValue.uuidString
        }
        let connection: AppleDeviceSyncLibraryConnection = switch reason {
        case .temporarilyUnavailable:
            .offline
        case .differentCloudAccount:
            .differentAccount
        case .accountUnavailable, .runtimeInitializationFailed:
            .accountRequired
        }
        return AppleDeviceSyncLibrarySnapshot(entries: entries, connection: connection)
    }

    /// A previously downloaded revision is held in the app-private journal and
    /// may be resumed without exposing the quarantined remote catalog.
    func resumePendingOpen(
        _ workID: SyncWorkID
    ) async throws -> AppleDeviceSyncPreparedRemoteWork {
        try await AppleDeviceSyncLibraryOpenCoordinator(
            replicaID: replicaID,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        ).resumePendingOpen(workID, remote: nil)
    }

    /// Does not expose cached catalog metadata; it only reports whether the
    /// exact full revision is present in this account-scoped local journal.
    func canResumePendingOpenOffline(_ workID: SyncWorkID) async -> Bool {
        await AppleDeviceSyncLibraryOpenCoordinator(
            replicaID: replicaID,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        ).canResumePendingOpenOffline(workID)
    }

    /// Completes package attestation locally. This does not authorize upload
    /// under an unverified or different iCloud account.
    @discardableResult
    func bindPreparedOpen(
        _ prepared: AppleDeviceSyncPreparedRemoteWork,
        packageSnapshot: WorkSnapshot
    ) async throws -> AppleResolvedWorkingCopy {
        try await AppleDeviceSyncLibraryOpenCoordinator(
            replicaID: replicaID,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        ).completePreparedOpen(prepared, packageSnapshot: packageSnapshot)
    }
}
