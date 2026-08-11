// The actor owns one audited state machine; splitting mutation paths across types would weaken invariants.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable file_length type_body_length function_body_length
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable cyclomatic_complexity for_where
import Foundation

public enum WorkSyncCoordinatorError: Error, Equatable, Sendable {
    case notBootstrapped
    case alreadyBootstrapped
    case workingCopyMismatch
    case replicaMismatch
    case localStagePending
    case materializationPending
    case noConflictReview
    case revisionMismatch
    case packageSnapshotMismatch
    case remoteSnapshotMalformed
    case remoteHeadMissing
}

public struct WorkSyncState: Sendable, Equatable {
    public let workID: SyncWorkID
    public let localHead: WorkRevision
    public let lastKnownRemoteHead: WorkRevision?
    public let stagedLocalRevision: WorkRevision?
    public let pendingRemoteMaterialization: WorkPendingMaterialization?
    public let retainedLocalRecoveryRevision: WorkRevision?
    public let conflictReview: WorkConflictReview?
    public let reconciliationStatus: WorkReconciliationStatus
    public let pendingRevisionCount: Int
}

public enum WorkSyncOutcome: Sendable, Equatable {
    case upToDate(WorkRevision)
    case uploaded(WorkRevision)
    case offline(WorkRevision)
    /// 通信は成功しているが、その最中の追加入力を優先して再同期待ちにした。
    case localPending(WorkRevision)
    case remoteFastForward(WorkRevision)
    case automaticallyMerged(WorkRevision)
    case reviewRequired(WorkConflictReview)
    case materializationRequired(WorkPendingMaterialization)
}

public struct WorkLocalRecoveryReview: Sendable, Equatable {
    public let materializedRevision: WorkRevision
    public let stagedLocalRevision: WorkRevision?
    public let pendingRemoteMaterialization: WorkPendingMaterialization?
    public let observedPackageSnapshot: WorkSnapshot
}

public enum WorkLocalRecoveryOutcome: Sendable, Equatable {
    case consistent(WorkRevision)
    case confirmedStaged(WorkRevision)
    case materializeStaged(WorkRevision)
    case materializeRemote(WorkPendingMaterialization)
    case acknowledgedRemote(WorkRevision)
    case capturedUnstagedPackage(WorkRevision)
    case reviewRequired(WorkLocalRecoveryReview)
}

public enum WorkLocalRecoveryChoice: Sendable {
    case keepObservedPackage
    case materializeStaged
    case materializePendingRemote
}

private struct WorkRemoteRevisionGraph: Sendable {
    let revisions: [WorkRevision]

    func contains(_ revisionID: SyncRevisionID) -> Bool {
        revisions.contains { $0.revisionID == revisionID }
    }
}

private enum WorkSynchronizationPreparation: Sendable {
    case outcome(WorkSyncOutcome)
    case publish(WorkPublishRequest)
}

private enum WorkPublishApplication: Sendable {
    case outcome(WorkSyncOutcome)
    case retry(WorkRemoteSnapshot?)
}

/// 作品全体をlocal-firstで調停するtransport非依存coordinator。
public actor WorkSyncCoordinator {
    public static let maximumRemoteAncestryFetchCount = 16

    private let workID: SyncWorkID
    private let localWorkingCopyID: LocalWorkingCopyID
    private let replicaID: SyncReplicaID
    private let sessionID: SyncEditSessionID
    private let transport: any WorkSyncTransport
    private let journal: any WorkSyncJournal
    private let mutationLane = WorkSyncMutationLane()
    private var record: WorkSyncJournalRecord?

    public init(
        workID: SyncWorkID,
        localWorkingCopyID: LocalWorkingCopyID,
        replicaID: SyncReplicaID,
        sessionID: SyncEditSessionID,
        transport: any WorkSyncTransport,
        journal: any WorkSyncJournal
    ) {
        self.workID = workID
        self.localWorkingCopyID = localWorkingCopyID
        self.replicaID = replicaID
        self.sessionID = sessionID
        self.transport = transport
        self.journal = journal
    }

    @discardableResult
    public func restore() async throws -> WorkSyncState? {
        try await withMutationLane { try await self.restoreLocked() }
    }

    public func bootstrapLocalSnapshot(
        _ snapshot: WorkSnapshot,
        at date: Date
    ) async throws -> WorkRevision {
        try await withMutationLane {
            try await self.bootstrapLocalSnapshotLocked(snapshot, at: date)
        }
    }

    /// 新端末がremote headを初めてmaterializeするための明示bootstrap。
    public func bootstrapRemoteRevision(_ remoteRevision: WorkRevision) async throws -> WorkPendingMaterialization {
        try await withMutationLane {
            try await self.bootstrapRemoteRevisionLocked(remoteRevision)
        }
    }

    public func stageLocalSnapshot(
        _ snapshot: WorkSnapshot,
        at date: Date
    ) async throws -> WorkRevision {
        try await withMutationLane {
            try await self.stageLocalSnapshotLocked(snapshot, at: date)
        }
    }

    public func confirmLocalSnapshotMaterialized(
        _ revisionID: SyncRevisionID,
        packageSnapshot: WorkSnapshot
    ) async throws {
        try await withMutationLane {
            try await self.confirmLocalSnapshotMaterializedLocked(
                revisionID,
                packageSnapshot: packageSnapshot
            )
        }
    }

    public func reconcileLocalMaterialization(
        packageSnapshot: WorkSnapshot,
        at date: Date
    ) async throws -> WorkLocalRecoveryOutcome {
        try await withMutationLane {
            try await self.reconcileLocalMaterializationLocked(
                packageSnapshot: packageSnapshot,
                at: date
            )
        }
    }

    public func resolveLocalRecovery(
        _ choice: WorkLocalRecoveryChoice,
        observedPackageSnapshot: WorkSnapshot,
        at date: Date
    ) async throws -> WorkLocalRecoveryOutcome {
        try await withMutationLane {
            try await self.resolveLocalRecoveryLocked(
                choice,
                observedPackageSnapshot: observedPackageSnapshot,
                at: date
            )
        }
    }

    public func acknowledgeRemoteMaterialization(
        _ revisionID: SyncRevisionID,
        packageSnapshot: WorkSnapshot
    ) async throws {
        try await withMutationLane {
            try await self.acknowledgeRemoteMaterializationLocked(
                revisionID,
                packageSnapshot: packageSnapshot
            )
        }
    }

    public func resolveConflict(
        _ choice: WorkConflictResolutionChoice,
        at date: Date
    ) async throws -> WorkRevision {
        try await withMutationLane {
            try await self.resolveConflictLocked(choice, at: date)
        }
    }

    /// journalを読むだけで、閲覧によるrevision生成は行わない。
    @discardableResult
    private func restoreLocked() async throws -> WorkSyncState? {
        guard let restored = try await journal.load(for: workID) else {
            record = nil
            return nil
        }
        guard restored.localWorkingCopyID == localWorkingCopyID else {
            throw WorkSyncCoordinatorError.workingCopyMismatch
        }
        guard restored.replicaID == replicaID else {
            throw WorkSyncCoordinatorError.replicaMismatch
        }
        try restored.validate()
        record = restored
        return makeState(restored)
    }

    /// D-061 migrationまたは新規remote work作成時だけ呼ぶ明示seed。
    private func bootstrapLocalSnapshotLocked(
        _ snapshot: WorkSnapshot,
        at date: Date
    ) async throws -> WorkRevision {
        guard record == nil, try await journal.load(for: workID) == nil else {
            throw WorkSyncCoordinatorError.alreadyBootstrapped
        }
        let branchID = SyncBranchID()
        let revision = try WorkRevision(
            workID: workID,
            parentRevisionIDs: [],
            branchID: branchID,
            authorReplicaID: replicaID,
            authorSessionID: sessionID,
            snapshot: snapshot,
            clientCreatedAt: date
        )
        let created = try WorkSyncJournalRecord(
            workID: workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            branchID: branchID,
            lastKnownRemoteHead: nil,
            localHead: revision,
            outbox: [revision],
            reconciliationStatus: .pending
        )
        try await journal.save(created)
        record = created
        return revision
    }

    private func bootstrapRemoteRevisionLocked(
        _ remoteRevision: WorkRevision
    ) async throws -> WorkPendingMaterialization {
        guard record == nil, try await journal.load(for: workID) == nil else {
            throw WorkSyncCoordinatorError.alreadyBootstrapped
        }
        guard remoteRevision.workID == workID else {
            throw WorkSyncCoordinatorError.remoteSnapshotMalformed
        }
        try remoteRevision.validate()
        let pending = WorkPendingMaterialization(
            kind: .remoteBootstrap,
            sourceLocalRevisionID: remoteRevision.revisionID,
            revision: remoteRevision
        )
        let created = try WorkSyncJournalRecord(
            workID: workID,
            localWorkingCopyID: localWorkingCopyID,
            replicaID: replicaID,
            branchID: SyncBranchID(),
            lastKnownRemoteHead: remoteRevision,
            localHead: remoteRevision,
            outbox: [],
            pendingRemoteMaterialization: pending,
            reconciliationStatus: .materializationRequired
        )
        try await journal.save(created)
        record = created
        return pending
    }

    /// package保存前にexact snapshotをjournalへ先行保存する。まだpublish対象ではない。
    private func stageLocalSnapshotLocked(
        _ snapshot: WorkSnapshot,
        at date: Date
    ) async throws -> WorkRevision {
        var record = try requireRecord()
        guard snapshot.documentID == record.localHead.snapshot.documentID else {
            throw WorkSnapshotError.documentIdentityMismatch
        }
        if let staged = record.stagedLocalRevision, staged.snapshot == snapshot {
            return staged
        }
        if record.localHead.snapshot == snapshot {
            if record.stagedLocalRevision != nil {
                // A save back to the exact materialized head is an explicit
                // cancellation of the older staged intent. Persist that
                // cancellation before the package save, otherwise restart may
                // incorrectly reinstall the stale staged snapshot.
                record.stagedLocalRevision = nil
                record.reconciliationStatus = statusAfterClearingLocalStage(in: record)
                try await save(record)
            }
            return record.localHead
        }
        let parents = nextLocalParentIDs(in: record)
        let staged = try WorkRevision(
            workID: workID,
            parentRevisionIDs: parents,
            branchID: record.branchID,
            authorReplicaID: replicaID,
            authorSessionID: sessionID,
            snapshot: snapshot,
            clientCreatedAt: date
        )
        record.stagedLocalRevision = staged
        record.reconciliationStatus = .materializationRequired
        try await save(record)
        return staged
    }

    /// package atomic save後にだけ、staged revisionをpublish可能なlocal headへ昇格する。
    private func confirmLocalSnapshotMaterializedLocked(
        _ revisionID: SyncRevisionID,
        packageSnapshot: WorkSnapshot
    ) async throws {
        var record = try requireRecord()
        guard let staged = record.stagedLocalRevision,
              staged.revisionID == revisionID else {
            throw WorkSyncCoordinatorError.revisionMismatch
        }
        guard staged.snapshot == packageSnapshot else {
            throw WorkSyncCoordinatorError.packageSnapshotMismatch
        }
        try promoteMaterializedLocalRevision(staged, in: &record)
        try await save(record)
    }

    /// packageへ既にmaterialize済みのrevisionを、関連するoutbox／pending／reviewと
    /// 同じjournal commitでlocal headへ昇格する。
    private func promoteMaterializedLocalRevision(
        _ revision: WorkRevision,
        in record: inout WorkSyncJournalRecord
    ) throws {
        let previousLocalHead = record.localHead
        let previousOutbox = record.outbox
        let pendingBeforeLocalEdit = record.pendingRemoteMaterialization
        record.localHead = revision
        if let sealed = record.sealedPublish,
           revision.parentRevisionIDs == [sealed.candidateHeadRevisionID] {
            let sealedRevisions = sealed.revisionIDs.compactMap { id in
                previousOutbox.first { $0.revisionID == id }
            }
            record.outbox = sealedRevisions + [revision]
        } else if revision.parentRevisionIDs == [previousLocalHead.revisionID] {
            if previousOutbox.isEmpty {
                record.outbox = [revision]
            } else if previousOutbox.count < WorkSyncJournalRecord.maximumOutboxRevisionCount {
                record.outbox = previousOutbox + [revision]
            } else {
                // in-flight candidateを親として残し、それより古いwhole snapshotはcoalesceする。
                record.outbox = [previousLocalHead, revision]
            }
        } else {
            record.outbox = [revision]
        }
        record.stagedLocalRevision = nil
        if let sealed = record.sealedPublish,
           !sealed.revisionIDs.allSatisfy(Set(record.outbox.map(\.revisionID)).contains) {
            // responseはobservation-CASでretryされる。server側commit済みでも次fetchで追従できる。
            record.sealedPublish = nil
        }
        record.reconciliationStatus = .pending
        if let pendingBeforeLocalEdit {
            try reconcilePendingAfterLocalEdit(
                &record,
                previousLocalHead: previousLocalHead,
                pending: pendingBeforeLocalEdit
            )
        } else if let review = record.conflictReview {
            try updateReviewAfterLocalEdit(&record, previous: review)
        }
    }

    /// process再開時にpackageと二相markerを照合する。marker save失敗→package成功もlocal revision化する。
    private func reconcileLocalMaterializationLocked(
        packageSnapshot: WorkSnapshot,
        at date: Date
    ) async throws -> WorkLocalRecoveryOutcome {
        let record = try requireRecord()
        if let staged = record.stagedLocalRevision, staged.snapshot == packageSnapshot {
            try await confirmLocalSnapshotMaterializedLocked(
                staged.revisionID,
                packageSnapshot: packageSnapshot
            )
            return .confirmedStaged(staged)
        }
        if let pending = record.pendingRemoteMaterialization,
           pending.revision.snapshot == packageSnapshot {
            try await acknowledgeRemoteMaterializationLocked(
                pending.revision.revisionID,
                packageSnapshot: packageSnapshot
            )
            return .acknowledgedRemote(pending.revision)
        }
        if record.localHead.snapshot == packageSnapshot {
            if let staged = record.stagedLocalRevision {
                return .materializeStaged(staged)
            }
            if let pending = record.pendingRemoteMaterialization {
                return .materializeRemote(pending)
            }
            return .consistent(record.localHead)
        }
        guard record.stagedLocalRevision == nil,
              record.pendingRemoteMaterialization == nil else {
            return .reviewRequired(
                WorkLocalRecoveryReview(
                    materializedRevision: record.localHead,
                    stagedLocalRevision: record.stagedLocalRevision,
                    pendingRemoteMaterialization: record.pendingRemoteMaterialization,
                    observedPackageSnapshot: packageSnapshot
                )
            )
        }
        let captured = try await captureUnstagedPackageLocked(packageSnapshot, at: date)
        return .capturedUnstagedPackage(captured)
    }

    /// `reviewRequired`で利用者が選んだ版を明示する。選ばれなかったremote版はserverに残り、
    /// 次回syncで再度3-way対象になるため暗黙破棄しない。
    private func resolveLocalRecoveryLocked(
        _ choice: WorkLocalRecoveryChoice,
        observedPackageSnapshot: WorkSnapshot,
        at date: Date
    ) async throws -> WorkLocalRecoveryOutcome {
        var record = try requireRecord()
        guard observedPackageSnapshot.documentID == record.localHead.snapshot.documentID else {
            throw WorkSnapshotError.documentIdentityMismatch
        }
        switch choice {
        case .materializeStaged:
            guard let staged = record.stagedLocalRevision else {
                throw WorkSyncCoordinatorError.revisionMismatch
            }
            record.reconciliationStatus = .materializationRequired
            try await save(record)
            return .materializeStaged(staged)
        case .materializePendingRemote:
            guard let pending = record.pendingRemoteMaterialization else {
                throw WorkSyncCoordinatorError.revisionMismatch
            }
            if record.retainedLocalRecoveryRevision == nil {
                record.retainedLocalRecoveryRevision = record.stagedLocalRevision
            }
            record.reconciliationStatus = .materializationRequired
            try await save(record)
            return .materializeRemote(pending)
        case .keepObservedPackage:
            let unselectedStaged = record.stagedLocalRevision
            let parents = nextLocalParentIDs(in: record)
            let revision = try WorkRevision(
                workID: workID,
                parentRevisionIDs: parents,
                branchID: record.branchID,
                authorReplicaID: replicaID,
                authorSessionID: sessionID,
                snapshot: observedPackageSnapshot,
                clientCreatedAt: date
            )
            if let unselectedStaged {
                record.retainedLocalRecoveryRevision = unselectedStaged
            }
            try promoteMaterializedLocalRevision(revision, in: &record)
            try await save(record)
            return .capturedUnstagedPackage(revision)
        }
    }

    public func synchronize(at date: Date) async throws -> WorkSyncOutcome {
        var suppliedRemote: WorkRemoteSnapshot?
        for _ in 0 ..< 4 {
            if let blocked = try await withMutationLane({
                try await self.blockingOutcomeForSynchronization()
            }) {
                return blocked
            }
            let remote: WorkRemoteSnapshot
            do {
                remote = if let suppliedRemote {
                    suppliedRemote
                } else {
                    try await transport.fetchSnapshot(for: workID)
                }
            } catch WorkSyncTransportError.unavailable {
                return try await markOfflineWithoutOverwritingLocalState()
            }
            guard remote.head?.workID == workID || remote.head == nil else {
                throw WorkSyncCoordinatorError.remoteSnapshotMalformed
            }
            let graph: WorkRemoteRevisionGraph
            do {
                graph = try await fetchRemoteGraph(from: remote.head)
            } catch WorkSyncTransportError.unavailable {
                return try await markOfflineWithoutOverwritingLocalState()
            }
            let preparation = try await withMutationLane {
                try await self.prepareSynchronization(remote: remote, graph: graph, at: date)
            }
            switch preparation {
            case let .outcome(outcome):
                return outcome
            case let .publish(request):
                let result: WorkPublishResult
                do {
                    result = try await transport.publish(request)
                } catch WorkSyncTransportError.unavailable {
                    return try await markOfflineWithoutOverwritingLocalState()
                }
                switch try await withMutationLane({
                    try await self.applyPublishResult(result, request: request)
                }) {
                case let .outcome(outcome):
                    return outcome
                case let .retry(remote):
                    suppliedRemote = remote
                }
            }
        }
        return try await markLocalPendingWithoutOverwritingLocalState()
    }

    private func acknowledgeRemoteMaterializationLocked(
        _ revisionID: SyncRevisionID,
        packageSnapshot: WorkSnapshot
    ) async throws {
        var record = try requireRecord()
        guard let pending = record.pendingRemoteMaterialization,
              pending.revision.revisionID == revisionID else {
            throw WorkSyncCoordinatorError.revisionMismatch
        }
        guard pending.revision.snapshot == packageSnapshot else {
            throw WorkSyncCoordinatorError.packageSnapshotMismatch
        }
        let discardedStagedAfterExplicitRemoteChoice = record.stagedLocalRevision != nil
        record.localHead = pending.revision
        switch pending.kind {
        case .remoteBootstrap, .remoteFastForward:
            record.lastKnownRemoteHead = pending.revision
            record.outbox = []
            record.reconciliationStatus = .synchronized
            record.retainedLocalRecoveryRevision = nil
        case .automaticMerge, .conflictResolution:
            if record.retainedLocalRecoveryRevision == nil,
               let staged = record.stagedLocalRevision {
                record.retainedLocalRecoveryRevision = staged
            }
            let unpublished = record.outbox.filter { $0.revisionID != pending.revision.revisionID }
            record.outbox = Array((unpublished + [pending.revision]).suffix(
                WorkSyncJournalRecord.maximumOutboxRevisionCount
            ))
            record.reconciliationStatus = .pending
        }
        record.pendingRemoteMaterialization = nil
        if discardedStagedAfterExplicitRemoteChoice {
            record.stagedLocalRevision = nil
        }
        record.sealedPublish = nil
        try await save(record)
    }

    private func resolveConflictLocked(
        _ choice: WorkConflictResolutionChoice,
        at date: Date
    ) async throws -> WorkRevision {
        var record = try requireRecord()
        guard let review = record.conflictReview else {
            throw WorkSyncCoordinatorError.noConflictReview
        }
        let snapshot: WorkSnapshot
        switch choice {
        case .keepLocal:
            snapshot = record.localHead.snapshot
        case .keepRemote:
            snapshot = review.remote.snapshot
        case .useProposed:
            snapshot = review.proposedSnapshot
        case let .custom(custom):
            guard custom.documentID == record.localHead.snapshot.documentID else {
                throw WorkSnapshotError.documentIdentityMismatch
            }
            snapshot = custom
        }
        let revision = try WorkRevision(
            workID: workID,
            parentRevisionIDs: [
                record.localHead.revisionID,
                record.lastKnownRemoteHead?.revisionID ?? review.remote.revisionID
            ],
            branchID: record.branchID,
            authorReplicaID: replicaID,
            authorSessionID: sessionID,
            snapshot: snapshot,
            clientCreatedAt: date
        )
        record.pendingRemoteMaterialization = WorkPendingMaterialization(
            kind: .conflictResolution,
            sourceLocalRevisionID: record.localHead.revisionID,
            revision: revision
        )
        record.conflictReview = nil
        record.reconciliationStatus = .materializationRequired
        try await save(record)
        return revision
    }

    public func currentState() throws -> WorkSyncState {
        try makeState(requireRecord())
    }

    private func blockingOutcomeForSynchronization() async throws -> WorkSyncOutcome? {
        var record = try requireRecord()
        if let staged = record.stagedLocalRevision {
            record.reconciliationStatus = .materializationRequired
            try await save(record)
            return .materializationRequired(
                WorkPendingMaterialization(
                    kind: .automaticMerge,
                    sourceLocalRevisionID: record.localHead.revisionID,
                    revision: staged
                )
            )
        }
        if let pending = record.pendingRemoteMaterialization {
            return .materializationRequired(pending)
        }
        if let review = record.conflictReview {
            return .reviewRequired(review)
        }
        return nil
    }

    private func markOfflineWithoutOverwritingLocalState() async throws -> WorkSyncOutcome {
        try await withMutationLane {
            var latest = try self.requireRecord()
            if let blocked = try await self.blockingOutcomeForSynchronization() {
                return blocked
            }
            latest.reconciliationStatus = .offline
            try await self.save(latest)
            return .offline(latest.localHead)
        }
    }

    private func markLocalPendingWithoutOverwritingLocalState() async throws -> WorkSyncOutcome {
        try await withMutationLane {
            var latest = try self.requireRecord()
            if let blocked = try await self.blockingOutcomeForSynchronization() {
                return blocked
            }
            latest.reconciliationStatus = .pending
            try await self.save(latest)
            return .localPending(latest.localHead)
        }
    }

    private func fetchRemoteGraph(from head: WorkRevision?) async throws -> WorkRemoteRevisionGraph {
        guard let head else { return WorkRemoteRevisionGraph(revisions: []) }
        var revisions: [WorkRevision] = []
        var known: Set<SyncRevisionID> = []
        var frontier = [head]
        while let revision = frontier.first,
              revisions.count < Self.maximumRemoteAncestryFetchCount {
            frontier.removeFirst()
            guard known.insert(revision.revisionID).inserted else { continue }
            guard revision.workID == workID,
                  revision.snapshot.documentID == head.snapshot.documentID else {
                throw WorkSyncCoordinatorError.remoteSnapshotMalformed
            }
            revisions.append(revision)
            for parentID in revision.parentRevisionIDs where !known.contains(parentID) {
                try await frontier.append(transport.fetchRevision(parentID, for: workID))
            }
        }
        return WorkRemoteRevisionGraph(revisions: revisions)
    }

    private func prepareSynchronization(
        remote: WorkRemoteSnapshot,
        graph: WorkRemoteRevisionGraph,
        at date: Date
    ) async throws -> WorkSynchronizationPreparation {
        if let blocked = try await blockingOutcomeForSynchronization() {
            return .outcome(blocked)
        }
        var record = try requireRecord()
        guard let remoteHead = remote.head else {
            if record.lastKnownRemoteHead != nil {
                // A missing head is valid only for an initial publish. Once an exact
                // remote head has been acknowledged, treating nil as an empty server
                // could silently recreate a deleted or inaccessible work. Keep every
                // local revision and the last remote evidence for explicit recovery.
                record.reconciliationStatus = .pending
                try await save(record)
                throw WorkSyncCoordinatorError.remoteHeadMissing
            }
            guard !record.outbox.isEmpty else {
                record.reconciliationStatus = .pending
                try await save(record)
                return .outcome(.upToDate(record.localHead))
            }
            return try await .publish(preparePublish(record: &record, expectedRemote: nil))
        }
        guard remoteHead.snapshot.documentID == record.localHead.snapshot.documentID else {
            throw WorkSnapshotError.documentIdentityMismatch
        }
        if remoteHead.snapshotDigest == record.localHead.snapshotDigest,
           remoteHead.snapshot == record.localHead.snapshot {
            // 既存packageを別端末で初めてbindした際の同一内容・別root IDを安全に収束する。
            record.lastKnownRemoteHead = remoteHead
            record.localHead = remoteHead
            record.outbox = []
            record.sealedPublish = nil
            record.retainedLocalRecoveryRevision = nil
            record.reconciliationStatus = .synchronized
            try await save(record)
            return .outcome(.upToDate(remoteHead))
        }
        if remoteHead.revisionID == record.localHead.revisionID {
            guard remoteHead.snapshotDigest == record.localHead.snapshotDigest,
                  remoteHead.snapshot == record.localHead.snapshot else {
                throw WorkSyncCoordinatorError.remoteSnapshotMalformed
            }
            record.lastKnownRemoteHead = remoteHead
            record.localHead = remoteHead
            record.outbox = []
            record.sealedPublish = nil
            record.retainedLocalRecoveryRevision = nil
            record.reconciliationStatus = .synchronized
            try await save(record)
            return .outcome(.upToDate(remoteHead))
        }
        if record.outbox.isEmpty, graph.contains(record.localHead.revisionID) {
            record.lastKnownRemoteHead = remoteHead
            record.pendingRemoteMaterialization = WorkPendingMaterialization(
                kind: .remoteFastForward,
                sourceLocalRevisionID: record.localHead.revisionID,
                revision: remoteHead
            )
            record.reconciliationStatus = .materializationRequired
            try await save(record)
            return .outcome(.remoteFastForward(remoteHead))
        }
        if let known = record.lastKnownRemoteHead,
           known.revisionID == remoteHead.revisionID,
           known.snapshotDigest == remoteHead.snapshotDigest,
           !record.outbox.isEmpty {
            return try await .publish(preparePublish(record: &record, expectedRemote: remoteHead))
        }
        if record.outbox.contains(where: {
            $0.revisionID == remoteHead.revisionID && $0.snapshotDigest == remoteHead.snapshotDigest
        }) {
            record.lastKnownRemoteHead = remoteHead
            return try await .publish(preparePublish(record: &record, expectedRemote: remoteHead))
        }
        guard let base = commonAncestor(local: record, remoteGraph: graph) else {
            let review = try unknownAncestorReview(local: record.localHead, remote: remoteHead)
            record.lastKnownRemoteHead = remoteHead
            record.conflictReview = review
            record.reconciliationStatus = .reviewRequired
            try await save(record)
            return .outcome(.reviewRequired(review))
        }
        try coalesceLocalBranchForDivergence(&record, onto: base)
        switch try WorkSnapshotMerger.merge(
            base: base.snapshot,
            local: record.localHead.snapshot,
            remote: remoteHead.snapshot
        ) {
        case let .merged(snapshot):
            let merged = try WorkRevision(
                workID: workID,
                parentRevisionIDs: [record.localHead.revisionID, remoteHead.revisionID],
                branchID: record.branchID,
                authorReplicaID: replicaID,
                authorSessionID: sessionID,
                snapshot: snapshot,
                clientCreatedAt: date
            )
            record.lastKnownRemoteHead = remoteHead
            record.pendingRemoteMaterialization = WorkPendingMaterialization(
                kind: .automaticMerge,
                sourceLocalRevisionID: record.localHead.revisionID,
                revision: merged
            )
            record.reconciliationStatus = .materializationRequired
            try await save(record)
            return .outcome(.automaticallyMerged(merged))
        case let .conflicted(proposed, conflicts):
            let review = try WorkConflictReview(
                base: base,
                local: record.localHead,
                remote: remoteHead,
                proposedSnapshot: proposed,
                conflicts: conflicts
            )
            record.lastKnownRemoteHead = remoteHead
            record.conflictReview = review
            record.reconciliationStatus = .reviewRequired
            try await save(record)
            return .outcome(.reviewRequired(review))
        }
    }

    /// whole snapshotのlocal intentをknown common base直下1件へ畳む。これにより
    /// 2-parent merge + active-editor tailをoutbox cap内で完全な親graphとして送れる。
    private func coalesceLocalBranchForDivergence(
        _ record: inout WorkSyncJournalRecord,
        onto base: WorkRevision
    ) throws {
        guard record.outbox.count != 1
            || record.localHead.parentRevisionIDs != [base.revisionID] else { return }
        let coalesced = try WorkRevision(
            workID: workID,
            parentRevisionIDs: [base.revisionID],
            branchID: record.branchID,
            authorReplicaID: replicaID,
            authorSessionID: sessionID,
            snapshot: record.localHead.snapshot,
            clientCreatedAt: record.localHead.clientCreatedAt
        )
        record.localHead = coalesced
        record.outbox = [coalesced]
        record.sealedPublish = nil
    }

    private func preparePublish(
        record: inout WorkSyncJournalRecord,
        expectedRemote: WorkRevision?
    ) async throws -> WorkPublishRequest {
        let expectedIndex = expectedRemote.flatMap { remote in
            record.outbox.firstIndex { $0.revisionID == remote.revisionID }
        }
        let revisions: [WorkRevision] = if let index = expectedIndex {
            Array(record.outbox.suffix(from: record.outbox.index(after: index)))
        } else {
            record.outbox
        }
        guard !revisions.isEmpty else {
            throw WorkSyncTransportError.invalidPublishRequest
        }
        let reusable = record.sealedPublish.flatMap { sealed in
            sealed.revisionIDs == revisions.map(\.revisionID)
                && sealed.expectedHeadRevisionID == expectedRemote?.revisionID
                && sealed.expectedHeadSnapshotDigest == expectedRemote?.snapshotDigest
                ? sealed : nil
        }
        let sealed = reusable ?? WorkSealedPublish(
            mutationID: SyncMutationID(),
            revisionIDs: revisions.map(\.revisionID),
            candidateHeadRevisionID: record.localHead.revisionID,
            expectedHeadRevisionID: expectedRemote?.revisionID,
            expectedHeadSnapshotDigest: expectedRemote?.snapshotDigest
        )
        record.sealedPublish = sealed
        record.reconciliationStatus = .pending
        try await save(record)
        return try WorkPublishRequest(
            mutationID: sealed.mutationID,
            workID: workID,
            revisions: sealed.revisionIDs.compactMap { id in
                record.outbox.first { $0.revisionID == id }
            },
            candidateHeadRevisionID: sealed.candidateHeadRevisionID,
            expectedHeadRevisionID: sealed.expectedHeadRevisionID,
            expectedHeadSnapshotDigest: sealed.expectedHeadSnapshotDigest
        )
    }

    private func applyPublishResult(
        _ result: WorkPublishResult,
        request: WorkPublishRequest
    ) async throws -> WorkPublishApplication {
        var record = try requireRecord()
        guard record.sealedPublish?.mutationID == request.mutationID,
              record.sealedPublish?.revisionIDs == request.revisions.map(\.revisionID),
              request.revisions.allSatisfy({ requestRevision in
                  record.outbox.contains(requestRevision)
              }) else {
            return .retry(nil)
        }
        switch result {
        case let .acknowledged(committedHead, current):
            guard committedHead.revisionID == request.candidateHeadRevisionID,
                  committedHead.snapshotDigest == request.revisions.last?.snapshotDigest else {
                throw WorkSyncCoordinatorError.remoteSnapshotMalformed
            }
            let acknowledgedIDs = Set(request.revisions.map(\.revisionID))
            record.outbox.removeAll { acknowledgedIDs.contains($0.revisionID) }
            record.lastKnownRemoteHead = committedHead
            record.sealedPublish = nil
            if record.localHead.revisionID == committedHead.revisionID {
                record.localHead = committedHead
            }
            let currentIsCommitted = current.head?.revisionID == committedHead.revisionID
                && current.head?.snapshotDigest == committedHead.snapshotDigest
            record.reconciliationStatus = record.outbox.isEmpty && currentIsCommitted
                ? .synchronized : .pending
            try await save(record)
            if record.outbox.isEmpty, currentIsCommitted {
                record.retainedLocalRecoveryRevision = nil
                try await save(record)
                return .outcome(.uploaded(committedHead))
            }
            return .retry(currentIsCommitted ? nil : current)
        case let .diverged(current):
            record.sealedPublish = nil
            try await save(record)
            return .retry(current)
        }
    }

    private func commonAncestor(
        local record: WorkSyncJournalRecord,
        remoteGraph: WorkRemoteRevisionGraph
    ) -> WorkRevision? {
        var localRevisions: [SyncRevisionID: WorkRevision] = [:]
        for revision in record.outbox + [record.localHead] + [record.lastKnownRemoteHead].compactMap(\.self) {
            if localRevisions[revision.revisionID] == nil {
                localRevisions[revision.revisionID] = revision
            }
        }
        var localIDs: Set<SyncRevisionID> = []
        var frontier = [record.localHead.revisionID]
        while let id = frontier.popLast(), localIDs.insert(id).inserted {
            frontier.append(contentsOf: localRevisions[id]?.parentRevisionIDs ?? [])
        }
        for revision in remoteGraph.revisions where localIDs.contains(revision.revisionID) {
            return localRevisions[revision.revisionID] ?? revision
        }
        return nil
    }

    private func unknownAncestorReview(
        local: WorkRevision,
        remote: WorkRevision
    ) throws -> WorkConflictReview {
        try WorkConflictReview(
            base: nil,
            local: local,
            remote: remote,
            proposedSnapshot: local.snapshot,
            conflicts: [
                WorkFieldConflict(
                    path: "document.$ancestry",
                    entityKind: .document,
                    entityID: nil,
                    field: "$ancestry",
                    reason: .commonAncestorUnknown,
                    baseValue: nil,
                    localValue: local.revisionID.description,
                    remoteValue: remote.revisionID.description,
                    proposedValue: "local"
                )
            ]
        )
    }

    private func updateReviewAfterLocalEdit(
        _ record: inout WorkSyncJournalRecord,
        previous: WorkConflictReview
    ) throws {
        guard let base = previous.base else {
            record.conflictReview = try WorkConflictReview(
                base: nil,
                local: record.localHead,
                remote: previous.remote,
                proposedSnapshot: record.localHead.snapshot,
                conflicts: previous.conflicts
            )
            record.reconciliationStatus = .reviewRequired
            return
        }
        switch try WorkSnapshotMerger.merge(
            base: base.snapshot,
            local: record.localHead.snapshot,
            remote: previous.remote.snapshot
        ) {
        case let .merged(snapshot):
            let revision = try WorkRevision(
                workID: workID,
                parentRevisionIDs: [
                    record.localHead.revisionID,
                    record.lastKnownRemoteHead?.revisionID ?? previous.remote.revisionID
                ],
                branchID: record.branchID,
                authorReplicaID: replicaID,
                authorSessionID: sessionID,
                snapshot: snapshot,
                clientCreatedAt: record.localHead.clientCreatedAt
            )
            record.conflictReview = nil
            record.pendingRemoteMaterialization = WorkPendingMaterialization(
                kind: .automaticMerge,
                sourceLocalRevisionID: record.localHead.revisionID,
                revision: revision
            )
            record.reconciliationStatus = .materializationRequired
        case let .conflicted(proposed, conflicts):
            record.conflictReview = try WorkConflictReview(
                base: base,
                local: record.localHead,
                remote: previous.remote,
                proposedSnapshot: proposed,
                conflicts: conflicts
            )
            record.reconciliationStatus = .reviewRequired
        }
    }

    private func reconcilePendingAfterLocalEdit(
        _ record: inout WorkSyncJournalRecord,
        previousLocalHead: WorkRevision,
        pending: WorkPendingMaterialization
    ) throws {
        record.pendingRemoteMaterialization = nil
        switch try WorkSnapshotMerger.merge(
            base: previousLocalHead.snapshot,
            local: record.localHead.snapshot,
            remote: pending.revision.snapshot
        ) {
        case let .merged(snapshot):
            // pending automatic merge自体はまだserverに存在しない。tailの親へ置くと
            // restart後に欠落親となるため、actual remote headへ直接畳み直す。
            let actualRemoteParentID = record.lastKnownRemoteHead?.revisionID
                ?? pending.revision.parentRevisionIDs.first {
                    $0 != pending.sourceLocalRevisionID
                }
                ?? pending.revision.revisionID
            let revision = try WorkRevision(
                workID: workID,
                parentRevisionIDs: [record.localHead.revisionID, actualRemoteParentID],
                branchID: record.branchID,
                authorReplicaID: replicaID,
                authorSessionID: sessionID,
                snapshot: snapshot,
                clientCreatedAt: record.localHead.clientCreatedAt
            )
            record.pendingRemoteMaterialization = WorkPendingMaterialization(
                kind: .automaticMerge,
                sourceLocalRevisionID: record.localHead.revisionID,
                revision: revision
            )
            record.reconciliationStatus = .materializationRequired
        case let .conflicted(proposed, conflicts):
            record.conflictReview = try WorkConflictReview(
                base: previousLocalHead,
                local: record.localHead,
                remote: pending.revision,
                proposedSnapshot: proposed,
                conflicts: conflicts
            )
            record.reconciliationStatus = .reviewRequired
        }
    }

    private func captureUnstagedPackageLocked(
        _ snapshot: WorkSnapshot,
        at date: Date
    ) async throws -> WorkRevision {
        var record = try requireRecord()
        let previousReview = record.conflictReview
        let previousLocalHead = record.localHead
        let previousOutbox = record.outbox
        let parents = nextLocalParentIDs(in: record)
        let revision = try WorkRevision(
            workID: workID,
            parentRevisionIDs: parents,
            branchID: record.branchID,
            authorReplicaID: replicaID,
            authorSessionID: sessionID,
            snapshot: snapshot,
            clientCreatedAt: date
        )
        record.localHead = revision
        if let sealed = record.sealedPublish,
           parents == [sealed.candidateHeadRevisionID] {
            let sealedRevisions = sealed.revisionIDs.compactMap { id in
                previousOutbox.first { $0.revisionID == id }
            }
            record.outbox = sealedRevisions + [revision]
        } else if parents == [previousLocalHead.revisionID] {
            if previousOutbox.isEmpty {
                record.outbox = [revision]
            } else if previousOutbox.count < WorkSyncJournalRecord.maximumOutboxRevisionCount {
                record.outbox = previousOutbox + [revision]
            } else {
                record.outbox = [previousLocalHead, revision]
            }
        } else {
            record.outbox = [revision]
        }
        if let sealed = record.sealedPublish,
           !sealed.revisionIDs.allSatisfy(Set(record.outbox.map(\.revisionID)).contains) {
            record.sealedPublish = nil
        }
        record.reconciliationStatus = .pending
        if let previousReview {
            try updateReviewAfterLocalEdit(&record, previous: previousReview)
        }
        try await save(record)
        return revision
    }

    /// network中のcandidateや未解決reviewは親として保持する。通常の未publish chainは
    /// last known remoteへwhole-snapshot coalesceし、outboxをboundedに保つ。
    private func nextLocalParentIDs(in record: WorkSyncJournalRecord) -> [SyncRevisionID] {
        if let sealed = record.sealedPublish {
            return [sealed.candidateHeadRevisionID]
        }
        if let review = record.conflictReview {
            return review.base.map { [$0.revisionID] } ?? []
        }
        if record.pendingRemoteMaterialization != nil {
            if let source = record.outbox.first {
                return source.parentRevisionIDs
            }
            return [record.localHead.revisionID]
        }
        if record.outbox.isEmpty {
            return [record.localHead.revisionID]
        }
        return record.lastKnownRemoteHead.map { [$0.revisionID] } ?? []
    }

    private func statusAfterClearingLocalStage(
        in record: WorkSyncJournalRecord
    ) -> WorkReconciliationStatus {
        if record.pendingRemoteMaterialization != nil {
            return .materializationRequired
        }
        if record.conflictReview != nil {
            return .reviewRequired
        }
        if record.outbox.isEmpty,
           record.lastKnownRemoteHead?.revisionID == record.localHead.revisionID {
            return .synchronized
        }
        return .pending
    }

    private func save(_ updated: WorkSyncJournalRecord) async throws {
        try updated.validate()
        try await journal.save(updated)
        record = updated
    }

    private func withMutationLane<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        await mutationLane.acquire()
        do {
            let value = try await operation()
            await mutationLane.release()
            return value
        } catch {
            await mutationLane.release()
            throw error
        }
    }

    private func requireRecord() throws -> WorkSyncJournalRecord {
        guard let record else { throw WorkSyncCoordinatorError.notBootstrapped }
        return record
    }

    private func makeState(_ record: WorkSyncJournalRecord) -> WorkSyncState {
        WorkSyncState(
            workID: record.workID,
            localHead: record.localHead,
            lastKnownRemoteHead: record.lastKnownRemoteHead,
            stagedLocalRevision: record.stagedLocalRevision,
            pendingRemoteMaterialization: record.pendingRemoteMaterialization,
            retainedLocalRecoveryRevision: record.retainedLocalRecoveryRevision,
            conflictReview: record.conflictReview,
            reconciliationStatus: record.reconciliationStatus,
            pendingRevisionCount: record.outbox.count
        )
    }
}
