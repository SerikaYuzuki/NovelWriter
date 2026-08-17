import Foundation
import NovelCore
import NovelSyncV2

/// Process-local test kernel. It shares intent and command state so focused
/// restart tests exercise the same once-only sealing contract as SQLite.
public actor InMemorySyncV2RuntimeState: SyncV2LocalKernel,
    SyncV2CommandPlanner, SyncV2LibraryProvider {
    struct Intent: Sendable {
        enum Kind: Sendable {
            case checkpoint
            case conflict(SyncV2ConflictAction)
            case restore(selected: SnapshotID, previous: SnapshotID)
        }

        let id: UUID
        let snapshotID: SnapshotID
        let generation: Int64
        let kind: Kind
    }

    struct Work: Sendable {
        var document: NovelDocument
        let documentCreatedAt: Date
        var attachments: [SyncAttachment]
        var resources: [PortableResource]
        var keepBothReserved: Bool
        var generation: Int64
        var snapshotID: SnapshotID
        var encoded: [SnapshotID: EncodedSnapshot]
        var intents: [Intent]
        var conflict: SyncV2ConflictProjection?
        var history: [SyncV2LocalHistoryOccurrence]
    }

    private struct PendingCommand: Sendable {
        let command: SealedCommand
        let intentID: UUID
        var sending: Bool
    }

    private let account: TestAccount?
    private let readOnly: Bool
    var works: [WorkID: Work] = [:]
    private var commands: [WorkID: [PendingCommand]] = [:]
    private var blocked: [WorkID: SyncV2Failure] = [:]
    private var inboxes: [UUID: SyncV2RemoteInbox] = [:]
    private var verifiedInboxes: Set<UUID> = []
    private var remoteOnly: [WorkID: SyncV2RemoteInbox] = [:]
    private var pendingAdoptions: [WorkID: SyncV2PendingAdoption] = [:]

    public init(account: TestAccount? = nil, readOnly: Bool = false) {
        self.account = account
        self.readOnly = readOnly
    }

    public func checkpoint(
        _ capture: SyncV2CheckpointCapture
    ) throws -> SyncV2LocalCheckpoint {
        guard !readOnly else { throw SyncV2ApplicationError.previewReadOnly }
        if var work = works[capture.workID] {
            guard work.document.id == capture.document.id,
                  work.documentCreatedAt == capture.documentCreatedAt,
                  work.generation == capture.expectedGeneration else {
                throw SyncV2Failure.fatal(.invalidLocalState)
            }
            if work.document == capture.document,
               attachmentsEqual(work.attachments, capture.attachments),
               capture.resources.map({ work.resources == $0 }) ?? true {
                return SyncV2LocalCheckpoint(
                    snapshotID: work.snapshotID,
                    generation: work.generation,
                    intentID: work.intents.last?.id,
                    noChanges: true
                )
            }
            let encoded = try encode(capture, parent: work.snapshotID)
            work.document = capture.document
            work.attachments = capture.attachments
            if let resources = capture.resources {
                work.resources = resources
            }
            work.generation += 1
            work.snapshotID = encoded.snapshotId
            work.encoded[encoded.snapshotId] = encoded
            work.history.append(
                SyncV2LocalHistoryOccurrence(
                    occurrenceID: UUID(),
                    snapshotID: encoded.snapshotId,
                    reason: capture.reason.rawValue,
                    pinned: capture.reason == .explicit || capture.reason == .navigation || capture.reason == .close || capture.reason == .migration,
                    localGeneration: work.generation,
                    createdAt: Date()
                )
            )
            let intent = coalescedIntent(for: work)
            work.intents = intent.intents
            works[capture.workID] = work
            return SyncV2LocalCheckpoint(
                snapshotID: work.snapshotID,
                generation: work.generation,
                intentID: intent.id,
                noChanges: false
            )
        }

        guard capture.expectedGeneration == 0 else {
            throw SyncV2Failure.fatal(.invalidLocalState)
        }
        let encoded = try encode(capture, parent: nil)
        let intent = Intent(
            id: UUID(),
            snapshotID: encoded.snapshotId,
            generation: 1,
            kind: .checkpoint
        )
        works[capture.workID] = Work(
            document: capture.document,
            documentCreatedAt: capture.documentCreatedAt,
            attachments: capture.attachments,
            resources: capture.resources ?? [],
            keepBothReserved: false,
            generation: 1,
            snapshotID: encoded.snapshotId,
            encoded: [encoded.snapshotId: encoded],
            intents: [intent],
            conflict: nil,
            history: [
                SyncV2LocalHistoryOccurrence(
                    occurrenceID: UUID(),
                    snapshotID: encoded.snapshotId,
                    reason: capture.reason.rawValue,
                    pinned: capture.reason == .explicit || capture.reason == .navigation || capture.reason == .close || capture.reason == .migration,
                    localGeneration: 1,
                    createdAt: Date()
                )
            ]
        )
        return SyncV2LocalCheckpoint(
            snapshotID: encoded.snapshotId,
            generation: 1,
            intentID: intent.id,
            noChanges: false
        )
    }

    public func activeConflict(workID: WorkID) throws -> SyncV2ConflictProjection? {
        works[workID]?.conflict
    }

    public func open(workID: WorkID) throws -> SyncV2OpenedWork {
        guard let work = works[workID] else {
            throw SyncV2ApplicationError.workNotFound
        }
        return opened(workID: workID, work: work)
    }

    public func parkAccountScope(workID: WorkID, binding _: SyncV2AccountScopeBinding) throws {
        // The in-memory test kernel has no persisted account-binding rows. A
        // Work remains local and its fake remote lane is already isolated by
        // the fixed test composition.
        guard works[workID] != nil else { throw SyncV2ApplicationError.workNotFound }
    }

    public func rebindAccountScope(
        workID: WorkID,
        from _: SyncV2AccountScopeBinding,
        to _: SyncV2AccountScopeBinding
    ) throws {
        guard works[workID] != nil else { throw SyncV2ApplicationError.workNotFound }
    }

    public func prepareRestore(
        _ request: SyncV2RestoreRequest
    ) throws -> SyncV2Preparation {
        guard !readOnly else { throw SyncV2ApplicationError.previewReadOnly }
        guard var work = works[request.workID] else {
            throw SyncV2ApplicationError.workNotFound
        }
        guard work.snapshotID != request.snapshotID else {
            return SyncV2Preparation(intentID: nil, noChanges: true)
        }
        guard let selected = work.encoded[request.snapshotID] else {
            throw SyncV2ApplicationError.workNotFound
        }
        let model = try SnapshotCodec.decode(
            manifestBytes: selected.manifestBytes,
            objects: selected.objects
        )
        let previous = work.snapshotID
        let restored = try SnapshotCodec.encode(
            model,
            parents: [previous, request.snapshotID].sorted {
                $0.rawValue < $1.rawValue
            }
        )
        work.document = model.document
        work.attachments = model.attachments
        work.generation += 1
        work.snapshotID = restored.snapshotId
        work.encoded[restored.snapshotId] = restored
        let intent = Intent(
            id: UUID(),
            snapshotID: restored.snapshotId,
            generation: work.generation,
            kind: .restore(selected: request.snapshotID, previous: previous)
        )
        work.intents.append(intent)
        works[request.workID] = work
        return SyncV2Preparation(intentID: intent.id, noChanges: false)
    }

    public func prepareExplicitAccountClone(
        sourceWorkID: WorkID,
        newWorkID: WorkID,
        newDocumentID: DocumentID
    ) throws -> SyncV2ExplicitAccountClone {
        _ = sourceWorkID; _ = newWorkID; _ = newDocumentID
        throw SyncV2ApplicationError.workNotFound
    }

    public func stageRemote(_ inbox: SyncV2RemoteInbox) throws {
        guard !readOnly else { throw SyncV2ApplicationError.previewReadOnly }
        inboxes[inbox.inboxID] = inbox
    }

    public func verifyRemote(inboxID: UUID, workID: WorkID) throws {
        guard inboxes[inboxID]?.workID == workID else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        verifiedInboxes.insert(inboxID)
    }

    public func recordConflict(
        _ conflict: SyncV2ConflictProjection,
        workID: WorkID,
        inboxID: UUID
    ) throws {
        guard verifiedInboxes.contains(inboxID), let inbox = inboxes[inboxID] else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        guard inbox.workID == workID else { throw SyncV2Failure.quarantined(.invalidRemoteData) }
        works[workID]?.conflict = conflict
    }

    public func pendingAdoption(
        workID: WorkID
    ) -> SyncV2PendingAdoption? {
        pendingAdoptions[workID]
    }

    public func applyStagedRemote(
        _ transaction: SyncV2AdoptionTransaction
    ) throws -> SyncV2OpenedWork {
        let boundary = transaction.boundary
        guard var work = works[boundary.workID],
              work.generation == boundary.gate.expectedLocalVersion.generation,
              work.snapshotID == boundary.gate.expectedLocalVersion.snapshotID,
              !transaction.requireNoPendingIntent || work.intents.isEmpty,
              boundary.session.workID == boundary.workID,
              boundary.gate.workID == boundary.workID,
              boundary.gate.sessionIdentity == boundary.session.identity,
              boundary.gate.sessionRevision == boundary.session.revision,
              let inbox = inboxes[boundary.inboxID],
              inbox.workID == boundary.workID,
              verifiedInboxes.contains(boundary.inboxID),
              let encoded = inbox.snapshots.first(where: {
                  $0.snapshotId == inbox.headSnapshotID
              }) else {
            throw SyncV2ApplicationError.safeBoundaryRejected
        }
        let model = try SnapshotCodec.decode(
            manifestBytes: encoded.manifestBytes,
            objects: encoded.objects
        )
        work.document = model.document
        work.attachments = model.attachments
        work.generation += 1
        work.snapshotID = encoded.snapshotId
        work.encoded[encoded.snapshotId] = encoded
        work.history.append(
            SyncV2LocalHistoryOccurrence(
                occurrenceID: UUID(),
                snapshotID: encoded.snapshotId,
                reason: SyncV2CheckpointReason.restore.rawValue,
                pinned: false,
                localGeneration: work.generation,
                createdAt: Date()
            )
        )
        works[boundary.workID] = work
        pendingAdoptions[boundary.workID] = nil
        return opened(workID: boundary.workID, work: work)
    }

    public func installRemoteOnly(
        _ inbox: SyncV2RemoteInbox
    ) throws -> SyncV2OpenedWork {
        guard !readOnly, works[inbox.workID] == nil,
              let encoded = inbox.snapshots.first(where: {
                  $0.snapshotId == inbox.headSnapshotID
              }) else {
            throw SyncV2ApplicationError.remoteOnlyInstallRejected
        }
        let model = try SnapshotCodec.decode(
            manifestBytes: encoded.manifestBytes,
            objects: encoded.objects
        )
        let work = Work(
            document: model.document,
            documentCreatedAt: model.documentCreatedAt,
            attachments: model.attachments,
            resources: [],
            keepBothReserved: false,
            generation: 1,
            snapshotID: encoded.snapshotId,
            encoded: [encoded.snapshotId: encoded],
            intents: [],
            conflict: nil,
            history: []
        )
        works[inbox.workID] = work
        return opened(workID: inbox.workID, work: work)
    }
}

public extension InMemorySyncV2RuntimeState {
    func nextCommand(workID: WorkID) throws -> SyncV2CommandPlan {
        if let failure = blocked[workID] {
            return .blocked(failure)
        }
        if let command = commands[workID]?.first {
            return .command(command.command)
        }
        guard works[workID]?.keepBothReserved != true else { return .idle }
        guard let intent = works[workID]?.intents.first else { return .idle }
        guard let account else {
            return .blocked(.authenticationRequired)
        }
        let command = try makeCommand(
            workID: workID,
            intent: intent,
            account: account
        )
        commands[workID, default: []].append(
            PendingCommand(command: command, intentID: intent.id, sending: false)
        )
        return .command(command)
    }

    func pendingWorkIDs() -> [WorkID] {
        Array(Set(works.keys.filter { workID in
            (!(commands[workID] ?? []).isEmpty || !(works[workID]?.intents.isEmpty ?? true)) &&
                works[workID]?.keepBothReserved != true
        }))
    }

    func markSending(
        _ operation: SyncV2RemoteOperation,
        workID: WorkID
    ) throws -> SyncV2RemoteOperation {
        guard case let .command(candidate) = operation,
              var pending = commands[workID],
              let index = pending.firstIndex(where: {
                  $0.command.commandId == candidate.command.commandId
              }),
              pending[index].command == candidate.command else {
            throw SyncV2Failure.fatal(.invalidLocalState)
        }
        pending[index].sending = true
        commands[workID] = pending
        return operation
    }

    func recordFailure(
        operation: SyncV2RemoteOperation,
        workID: WorkID,
        disposition: SyncV2CommandFailureDisposition
    ) throws {
        switch disposition {
        case .requeue:
            guard case let .command(candidate) = operation,
                  var pending = commands[workID],
                  let index = pending.firstIndex(where: {
                      $0.command.commandId == candidate.command.commandId
                  }) else { return }
            pending[index].sending = false
            commands[workID] = pending
        case .quarantine:
            blocked[workID] = .quarantined(.unsafeLocalState)
        case .park:
            blocked[workID] = .quarantined(.differentAccount)
        }
    }

    func acknowledgeCommand(
        _ receipt: SyncV2ReceiptReadback,
        command: SealedCommand,
        verifiedInboxID: UUID?
    ) throws {
        _ = verifiedInboxID
        guard receipt.commandID == command.commandId,
              receipt.requestDigest == command.requestDigest,
              receipt.predicates.allVerified,
              let workID = commands.first(where: { entry in
                  entry.value.contains { $0.command.commandId == command.commandId }
              })?.key,
              var work = works[workID],
              let linked = commands[workID]?.first(where: {
                  $0.command.commandId == command.commandId
              }),
              let linkedIntent = work.intents.first(where: {
                  $0.id == linked.intentID
              }) else {
            throw SyncV2Failure.receiptMismatch
        }
        commands[workID]?.removeAll { $0.command.commandId == command.commandId }
        work.intents.removeAll { $0.id == linked.intentID }
        if receipt.result == .conflictPending {
            guard let conflict = receipt.conflict else {
                throw SyncV2Failure.receiptMismatch
            }
            work.conflict = conflict
        } else if case let .conflict(action) = linkedIntent.kind {
            if action.choice == .keepBoth, let cloneWorkID = action.newWorkID {
                works[cloneWorkID]?.keepBothReserved = false
            }
            if action.choice == .useServer, let inboxID = verifiedInboxID {
                pendingAdoptions[workID] = SyncV2PendingAdoption(
                    workID: workID,
                    inboxID: inboxID,
                    expectedLocalVersion: SyncV2LocalVersion(
                        generation: action.sourceGeneration,
                        snapshotID: action.localSnapshotID
                    ),
                    conflictID: action.conflictID,
                    conflictRevision: action.revision
                )
            } else {
                work.conflict = nil
            }
        }
        works[workID] = work
    }

    func acknowledgeUpload(_ completion: SyncV2UploadCompletion) throws {
        _ = completion
        throw SyncV2Failure.fatal(.unsupportedCommand)
    }
}

public extension InMemorySyncV2RuntimeState {
    func library() -> SyncV2LibraryProjection {
        SyncV2LibraryProjection(items: works.map { workID, work in
            if let adoption = pendingAdoptions[workID] {
                return SyncV2LibraryItem(
                    workID: workID,
                    title: work.document.title,
                    availability: .localOnly,
                    accountState: account == nil ? .unbound : .active,
                    localGeneration: work.generation,
                    conflict: nil,
                    remoteProgress: .readyForSafeAdoption(inboxID: adoption.inboxID)
                )
            }
            return SyncV2LibraryItem(
                workID: workID,
                title: work.document.title,
                availability: .localOnly,
                accountState: account == nil ? .unbound : .active,
                localGeneration: work.generation,
                conflict: work.conflict,
                remoteProgress: work.conflict == nil ? .idle : .needsChoice
            )
        } + remoteOnly.compactMap { workID, inbox in
            guard works[workID] == nil,
                  let encoded = inbox.snapshots.first(where: {
                      $0.snapshotId == inbox.headSnapshotID
                  }),
                  let model = try? SnapshotCodec.decode(
                      manifestBytes: encoded.manifestBytes,
                      objects: encoded.objects
                  ) else { return nil }
            return SyncV2LibraryItem(
                workID: workID,
                title: model.document.title,
                availability: .remoteOnly,
                accountState: .active,
                remoteHead: inbox.expectedRemoteHead
            )
        })
    }

    func downloadRemoteOnly(
        workID: WorkID
    ) throws -> SyncV2RemoteInbox {
        guard let inbox = remoteOnly[workID] else {
            throw SyncV2ApplicationError.workNotFound
        }
        return inbox
    }

    func addRemoteOnly(_ inbox: SyncV2RemoteInbox) {
        remoteOnly[inbox.workID] = inbox
    }

    func setBlocked(_ failure: SyncV2Failure?, workID: WorkID) {
        blocked[workID] = failure
    }

    func setConflict(
        _ conflict: SyncV2ConflictProjection?,
        workID: WorkID
    ) {
        works[workID]?.conflict = conflict
    }

    func pendingIntentCount(workID: WorkID) -> Int {
        works[workID]?.intents.count ?? 0
    }
}

extension InMemorySyncV2RuntimeState {
    public func prepareConflict(
        _ action: SyncV2ConflictAction
    ) throws -> SyncV2Preparation {
        guard !readOnly else { throw SyncV2ApplicationError.previewReadOnly }
        guard let conflict = works[action.workID]?.conflict,
              conflict.conflictID == action.conflictID,
              conflict.revision == action.revision,
              conflict.sourceGeneration == action.sourceGeneration else {
            throw SyncV2ApplicationError.staleConflictAction
        }
        guard var work = works[action.workID],
              work.generation == action.sourceGeneration,
              work.snapshotID == action.localSnapshotID else {
            throw SyncV2ApplicationError.staleConflictAction
        }
        if action.choice == .keepBoth {
            if let existingIntent = work.intents.first(where: {
                guard case let .conflict(existingAction) = $0.kind else { return false }
                return existingAction.conflictID == action.conflictID &&
                    existingAction.choice == .keepBoth
            }), case let .conflict(existingAction) = existingIntent.kind,
            let existingWorkID = existingAction.newWorkID,
            works[existingWorkID] != nil {
                return SyncV2Preparation(
                    intentID: existingIntent.id,
                    noChanges: false,
                    preparedWorkID: existingWorkID
                )
            }
            guard let newWorkID = action.newWorkID,
                  let newDocumentID = action.newDocumentID,
                  newWorkID != action.workID else {
                throw SyncV2ApplicationError.staleConflictAction
            }
            if let existing = works[newWorkID] {
                guard existing.document.id == newDocumentID.rawValue else {
                    throw SyncV2ApplicationError.staleConflictAction
                }
                throw SyncV2ApplicationError.staleConflictAction
            }
            var cloneDocument = work.document
            cloneDocument.id = newDocumentID.rawValue
            let clone = try SnapshotCodec.encode(
                SnapshotModel(
                    workId: newWorkID,
                    document: cloneDocument,
                    documentCreatedAt: work.documentCreatedAt,
                    attachments: work.attachments
                ),
                parents: []
            )
            works[newWorkID] = Work(
                document: cloneDocument,
                documentCreatedAt: work.documentCreatedAt,
                attachments: work.attachments,
                resources: work.resources,
                keepBothReserved: true,
                generation: 1,
                snapshotID: clone.snapshotId,
                encoded: [clone.snapshotId: clone],
                intents: [],
                conflict: nil,
                history: [
                    SyncV2LocalHistoryOccurrence(
                        occurrenceID: UUID(),
                        snapshotID: clone.snapshotId,
                        reason: SyncV2CheckpointReason.keepBoth.rawValue,
                        pinned: false,
                        localGeneration: 1,
                        createdAt: Date()
                    )
                ]
            )
            let intent = Intent(
                id: UUID(),
                snapshotID: work.snapshotID,
                generation: work.generation,
                kind: .conflict(action)
            )
            work.intents.append(intent)
            works[action.workID] = work
            return SyncV2Preparation(
                intentID: intent.id,
                noChanges: false,
                preparedWorkID: newWorkID
            )
        }
        if action.choice == .useDevice {
            work = try deviceDecisionWork(
                work,
                action: action
            )
        }
        let intent = Intent(
            id: UUID(),
            snapshotID: work.snapshotID,
            generation: work.generation,
            kind: .conflict(action)
        )
        work.intents.append(intent)
        works[action.workID] = work
        return SyncV2Preparation(intentID: intent.id, noChanges: false)
    }

    private func deviceDecisionWork(
        _ original: Work,
        action: SyncV2ConflictAction
    ) throws -> Work {
        var work = original
        let decision = try SnapshotCodec.encode(
            SnapshotModel(
                workId: action.workID,
                document: work.document,
                documentCreatedAt: work.documentCreatedAt,
                attachments: work.attachments
            ),
            parents: [action.localSnapshotID, action.remoteSnapshotID].sorted {
                $0.rawValue < $1.rawValue
            }
        )
        work.generation += 1
        work.snapshotID = decision.snapshotId
        work.encoded[decision.snapshotId] = decision
        return work
    }
}

private extension InMemorySyncV2RuntimeState {
    func encode(
        _ capture: SyncV2CheckpointCapture,
        parent: SnapshotID?
    ) throws -> EncodedSnapshot {
        try SnapshotCodec.encode(
            SnapshotModel(
                workId: capture.workID,
                document: capture.document,
                documentCreatedAt: capture.documentCreatedAt,
                attachments: capture.attachments
            ),
            parents: parent.map { [$0] } ?? []
        )
    }

    func attachmentsEqual(
        _ lhs: [SyncAttachment],
        _ rhs: [SyncAttachment]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.attachmentId == right.attachmentId &&
                left.fileName == right.fileName && left.bytes == right.bytes
        }
    }

    private func coalescedIntent(for work: Work) -> (id: UUID, intents: [Intent]) {
        let sealedIDs = Set(commands.values.flatMap { $0.map(\.intentID) })
        if let last = work.intents.last, !sealedIDs.contains(last.id) {
            let replacement = Intent(
                id: last.id,
                snapshotID: work.snapshotID,
                generation: work.generation,
                kind: .checkpoint
            )
            return (last.id, Array(work.intents.dropLast()) + [replacement])
        }
        let intent = Intent(
            id: UUID(),
            snapshotID: work.snapshotID,
            generation: work.generation,
            kind: .checkpoint
        )
        return (intent.id, work.intents + [intent])
    }

    private func opened(workID: WorkID, work: Work) -> SyncV2OpenedWork {
        SyncV2OpenedWork(
            workID: workID,
            document: work.document,
            documentCreatedAt: work.documentCreatedAt,
            attachments: work.attachments,
            resources: work.resources,
            generation: work.generation,
            snapshotID: work.snapshotID
        )
    }
}
