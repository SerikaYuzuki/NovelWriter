import Foundation
import NovelCore
import NovelSyncV2

public actor LocalSyncV2Store {
    public let databaseURL: URL
    let executor: SQLiteExecutor

    var lastBackfillWriteDuration: Duration?
    var checkpointValidation: CheckpointValidationStamp?
    var checkpointFullValidationCount = 0
    /// Opt-in phase observation for the synthetic public-path benchmark.
    var checkpointTimingObserver: (@Sendable (String, Duration) -> Void)?

    public init(root: URL, policy: V2StoreOpenPolicy) throws {
        try Self.validateRoot(root)
        databaseURL = root.appendingPathComponent("snapshot-sync-v2.sqlite")
        let exists = FileManager.default.fileExists(atPath: databaseURL.path)
        switch policy {
        case .createNew:
            guard !exists else { throw SyncV2StoreError.databaseAlreadyExists }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        case .openExisting:
            guard exists else { throw SyncV2StoreError.databaseMissing }
        }
        if FileManager.default.fileExists(atPath: databaseURL.path),
           try databaseURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw SyncV2StoreError.invalidRoot
        }

        executor = try SQLiteExecutor(databaseURL: databaseURL, policy: policy)
    }

    public func close() {
        checkpointValidation = nil
        executor.close()
    }
}

public extension LocalSyncV2Store {
    func schemaVersionAndChecksum() throws -> (String, Data) {
        try workRepository.schemaVersionAndChecksum()
    }

    func bootstrap(
        workID: WorkID,
        documentID: DocumentID,
        documentCreatedAt: Date,
        scope: V2LocalWorkScope
    ) throws {
        try deletionRepository.requireNotDeleting(workID)
        try inTransaction {
            let anchor = try StoreValueCoding.iso8601(documentCreatedAt)
            if let row = try workRepository.scopedWorkRow(workID: workID, scope: scope) {
                guard row.documentID == documentID.description,
                      row.documentCreatedAt == anchor else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                return
            }
            guard try !workRepository.workExists(workID: workID) else {
                throw SyncV2StoreError.workNotFound
            }
            try workRepository.insertWork(
                workID: workID,
                documentID: documentID,
                documentCreatedAt: anchor,
                lane: .normal,
                scope: scope
            )
        }
    }

    func listWorks(scope: V2LocalWorkScope) throws -> [V2WorkSummary] {
        try workRepository.listWorks(scope: scope)
    }

    /// Parked works are intentionally a separate projection from ordinary
    /// unbound works. They remain locally editable, but must never look like
    /// an adoptable unbound work to an account-scoped shelf.
    func listParkedWorks() throws -> [V2WorkSummary] {
        try workRepository.listParkedWorks()
    }

    func open(workID: WorkID, scope: V2LocalWorkScope) throws -> V2OpenResult {
        try fullyValidatedOpen(workID: workID, scope: scope)
    }

    func checkpoint(
        _ request: V2CheckpointRequest,
        scope: V2LocalWorkScope
    ) throws -> V2CheckpointResult {
        try deletionRepository.requireNotDeleting(request.workID)
        let existing = try workRepository.scopedWorkRow(workID: request.workID, scope: scope)
        if existing == nil, try workRepository.workExists(workID: request.workID) {
            checkpointValidation = nil
            throw SyncV2StoreError.workNotFound
        }
        let anchor = try StoreValueCoding.iso8601(request.documentCreatedAt)
        var parents: [SnapshotID] = []
        var currentSnapshot: SnapshotID?
        if let existing {
            guard existing.documentID == DocumentID(request.document.id).description,
                  existing.localGeneration == request.expectedGeneration,
                  existing.documentCreatedAt == anchor else {
                checkpointValidation = nil
                throw SyncV2StoreError.generationMismatch
            }
            if let bytes = existing.currentSnapshotID {
                let current = try SnapshotID(rawValue: bytes.hexString)
                currentSnapshot = current
                parents = try workRepository.checkpointParents(workID: request.workID, current: current)
            }
        }
        let dataVersion: Int64
        if let existing {
            dataVersion = try validatedCheckpointBase(workID: request.workID, scope: scope, row: existing).dataVersion
        } else {
            checkpointValidation = nil
            dataVersion = try checkpointDataVersion()
        }
        let encodeStart = checkpointTimingObserver == nil ? nil : ContinuousClock.now
        let encoded = try SnapshotCodec.encode(
            SnapshotModel(
                workId: request.workID,
                document: request.document,
                documentCreatedAt: request.documentCreatedAt,
                attachments: request.attachments
            ),
            parents: parents
        )
        if let encodeStart {
            checkpointTimingObserver?("encode", encodeStart.duration(to: .now))
        }
        let compareStart = checkpointTimingObserver == nil ? nil : ContinuousClock.now
        let resourcesMatch = if let resources = request.resources {
            try workRepository.portableResourcesEqual(workID: request.workID, resources: resources)
        } else {
            true
        }
        if let current = currentSnapshot,
           try workRepository.checkpointContentMatches(
               workID: request.workID,
               current: current,
               candidate: encoded
           ),
           resourcesMatch {
            if let compareStart {
                checkpointTimingObserver?("compare", compareStart.duration(to: .now))
            }
            let result = try commitNoChangeCheckpoint(
                request,
                scope: scope,
                current: current,
                anchor: anchor,
                expectedDataVersion: dataVersion
            )
            if request.reason == .autosave {
                rememberCheckpoint(result, workID: request.workID, scope: scope, dataVersion: dataVersion)
            }
            return result
        }

        if let compareStart {
            checkpointTimingObserver?("compare", compareStart.duration(to: .now))
        }
        let sqliteStart = checkpointTimingObserver == nil ? nil : ContinuousClock.now
        defer {
            if let sqliteStart {
                checkpointTimingObserver?("sqlite", sqliteStart.duration(to: .now))
            }
        }
        let result = try commitCheckpointTransaction(
            request,
            scope: scope,
            createWork: existing == nil,
            encoded: encoded,
            expectedDataVersion: dataVersion
        )
        if request.reason == .autosave {
            rememberCheckpoint(result, workID: request.workID, scope: scope, dataVersion: dataVersion)
        }
        return result
    }

    func pendingIntents(
        scope: V2LocalWorkScope,
        workID: WorkID? = nil
    ) throws -> [V2PendingIntent] {
        try outboxRepository.pendingIntents(scope: scope, workID: workID)
    }

    func prepareExplicitAccountClone(
        sourceWorkID: WorkID,
        sourceScope: V2LocalWorkScope,
        newWorkID: WorkID,
        newDocumentID: DocumentID,
        destination: V2AccountBinding
    ) throws -> V2CheckpointResult {
        try deletionRepository.requireNotDeleting(sourceWorkID)
        try deletionRepository.requireNotDeleting(newWorkID)
        guard sourceWorkID != newWorkID,
              let source = try workRepository.scopedWorkRow(
                  workID: sourceWorkID,
                  scope: sourceScope
              ),
              let sourceSnapshotBytes = source.currentSnapshotID,
              try !workRepository.workExists(workID: newWorkID) else {
            throw SyncV2StoreError.workNotFound
        }
        let sourceSnapshot = try SnapshotID(rawValue: sourceSnapshotBytes.hexString)
        let encoded = try workRepository.loadEncoded(workID: sourceWorkID, snapshotID: sourceSnapshot)
        let sourceResources = try workRepository.loadPortableResources(workID: sourceWorkID)
        let sourceModel = try SnapshotCodec.decode(
            manifestBytes: encoded.manifestBytes,
            objects: encoded.objects
        )
        var clonedDocument = sourceModel.document
        clonedDocument.id = newDocumentID.rawValue
        let clone = try SnapshotCodec.encode(
            SnapshotModel(
                workId: newWorkID,
                document: clonedDocument,
                documentCreatedAt: sourceModel.documentCreatedAt,
                attachments: sourceModel.attachments
            ),
            parents: []
        )
        let intentID = UUID()
        return try inTransaction {
            guard try workRepository.scopedWorkRow(
                workID: sourceWorkID,
                scope: sourceScope
            )?.currentSnapshotID == sourceSnapshotBytes,
                try !workRepository.workExists(workID: newWorkID) else {
                throw SyncV2StoreError.staleCAS
            }
            try workRepository.insertWork(
                workID: newWorkID,
                documentID: newDocumentID,
                documentCreatedAt: StoreValueCoding.iso8601(sourceModel.documentCreatedAt),
                lane: .normal,
                scope: .bound(destination)
            )
            try workRepository.insertEncoded(clone, workID: newWorkID)
            try workRepository.replacePortableResources(
                workID: newWorkID,
                resources: sourceResources
            )
            try workRepository.installExplicitCloneHeadInTransaction(clone: clone, newWorkID: newWorkID)
            try workRepository.insertHistory(
                workID: newWorkID,
                snapshotID: clone.snapshotId,
                reason: "explicitAccountClone",
                pinned: false,
                generation: 1
            )
            try outboxRepository.insertIntent(.init(
                intentID: intentID,
                workID: newWorkID,
                snapshotID: clone.snapshotId,
                generation: 1,
                kind: "checkpoint",
                scope: .bound(destination)
            ))
            return V2CheckpointResult(
                snapshotID: clone.snapshotId,
                generation: 1,
                intentID: intentID,
                noChanges: false
            )
        }
    }

    func historyCount(workID: WorkID, scope: V2LocalWorkScope) throws -> Int {
        try workRepository.historyCount(workID: workID, scope: scope)
    }

    func history(
        workID: WorkID,
        scope: V2LocalWorkScope
    ) throws -> [V2HistoryOccurrence] {
        try workRepository.history(workID: workID, scope: scope)
    }

    /// Returns immutable local occurrences newest-first. The cursor is an
    /// opaque scope-boundary plus `(created_at, local_generation, occurrence_id)`
    /// token, so a cursor from an old account/fence cannot page a new scope.
    func historyPage(
        workID: WorkID,
        scope: V2LocalWorkScope,
        cursor: String? = nil,
        pageSize: Int = 100
    ) throws -> V2HistoryPage {
        try workRepository.historyPage(workID: workID, scope: scope, cursor: cursor, pageSize: pageSize)
    }

    func snapshotParents(
        workID: WorkID,
        snapshotID: SnapshotID,
        scope: V2LocalWorkScope
    ) throws -> [SnapshotID] {
        try workRepository.snapshotParents(workID: workID, snapshotID: snapshotID, scope: scope)
    }
}

extension LocalSyncV2Store {
    func commitCheckpointTransaction(
        _ request: V2CheckpointRequest,
        scope: V2LocalWorkScope,
        createWork: Bool,
        encoded: EncodedSnapshot,
        expectedDataVersion: Int64? = nil
    ) throws -> V2CheckpointResult {
        let anchor = try StoreValueCoding.iso8601(request.documentCreatedAt)
        return try inTransaction {
            if let expectedDataVersion, try checkpointDataVersion() != expectedDataVersion {
                throw SyncV2StoreError.generationMismatch
            }
            if createWork {
                try workRepository.insertWork(
                    workID: request.workID,
                    documentID: DocumentID(request.document.id),
                    documentCreatedAt: anchor,
                    lane: .normal,
                    scope: scope
                )
            }
            guard let current = try workRepository.scopedWorkRow(workID: request.workID, scope: scope),
                  current.localGeneration == request.expectedGeneration,
                  current.documentID == DocumentID(request.document.id).description,
                  current.documentCreatedAt == anchor else {
                throw SyncV2StoreError.generationMismatch
            }
            if let bytes = current.currentSnapshotID {
                let currentID = try SnapshotID(rawValue: bytes.hexString)
                // Another connection may promote without changing generation.
                // Never commit an encoding against the superseded stable parent.
                guard try encoded.manifest.parentSnapshotIds == workRepository.checkpointParents(
                    workID: request.workID, current: currentID
                ) else { throw SyncV2StoreError.generationMismatch }
            }
            try workRepository.insertEncoded(encoded, workID: request.workID)
            if let resources = request.resources {
                try workRepository.replacePortableResources(workID: request.workID, resources: resources)
            }
            let next = request.expectedGeneration + 1
            try workRepository.updateCheckpointHeadInTransaction(encoded: encoded, request: request, next: next)
            try workRepository.insertHistory(
                workID: request.workID,
                snapshotID: encoded.snapshotId,
                reason: request.reason == .autosave ? "autosaveLeaf" : request.reason.rawValue,
                pinned: request.reason.protectsOccurrence,
                generation: next
            )
            let lane = V2SyncLane(rawValue: current.syncLane ?? "")
            if case .parked = scope {
                // A parked Work continues to checkpoint locally, but it must
                // not create an unbound remote lane while no account is
                // attested. Close any legacy unbound intent in this same tx.
                try accountRepository.parkPendingUnboundIntents(workID: request.workID)
            }
            let intentID: UUID? = switch scope {
            case .parked:
                nil
            case .unbound, .bound:
                if lane == .normal, request.reason != .autosave {
                    try outboxRepository.upsertCheckpointIntent(
                        workID: request.workID,
                        snapshotID: encoded.snapshotId,
                        generation: next,
                        scope: scope
                    )
                } else {
                    nil
                }
            }
            return V2CheckpointResult(
                snapshotID: encoded.snapshotId,
                generation: next,
                intentID: intentID,
                noChanges: false
            )
        }
    }
}

extension LocalSyncV2Store {
    static func validateRoot(_ root: URL) throws {
        guard root.isFileURL else { throw SyncV2StoreError.invalidRoot }
        var ancestor = root
        while ancestor.path != "/" {
            let systemAlias = ancestor.path == "/var" || ancestor.path == "/tmp"
            if !systemAlias,
               FileManager.default.fileExists(atPath: ancestor.path),
               try ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw SyncV2StoreError.invalidRoot
            }
            ancestor.deleteLastPathComponent()
        }
    }

    func inTransaction<T>(preservingCheckpoint: Bool = false, _ body: () throws -> T) throws -> T {
        if preservingCheckpoint {
            return try inCheckpointNeutralTransaction(body)
        }
        defer { checkpointValidation = nil }
        return try executor.inTransaction(body)
    }

    func exec(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        try executor.exec(sql, bindings)
    }

    func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try executor.query(sql, bindings)
    }

    func changes() throws -> Int {
        try executor.changes()
    }
}

extension LocalSyncV2Store {
    func commitNoChangeCheckpoint(
        _ request: V2CheckpointRequest,
        scope: V2LocalWorkScope,
        current: SnapshotID,
        anchor: String,
        expectedDataVersion: Int64? = nil
    ) throws -> V2CheckpointResult {
        try inTransaction {
            if let expectedDataVersion, try checkpointDataVersion() != expectedDataVersion {
                throw SyncV2StoreError.generationMismatch
            }
            guard let latest = try workRepository.scopedWorkRow(
                workID: request.workID,
                scope: scope
            ),
                latest.documentID == DocumentID(request.document.id).description,
                latest.localGeneration == request.expectedGeneration,
                latest.currentSnapshotID == current.bytes,
                latest.documentCreatedAt == anchor else {
                throw SyncV2StoreError.generationMismatch
            }
            let promoted = if request.reason != .autosave {
                try workRepository.promoteCurrentLeafTransaction(
                    workID: request.workID, scope: scope, reason: request.reason.rawValue
                )
            } else {
                false
            }
            if request.reason.protectsOccurrence, !promoted {
                try workRepository.insertHistory(
                    workID: request.workID,
                    snapshotID: current,
                    reason: request.reason.rawValue,
                    pinned: true,
                    generation: request.expectedGeneration
                )
            }
            if case .parked = scope {
                try accountRepository.parkPendingUnboundIntents(workID: request.workID)
            }
            let intentID: UUID? = if case .parked = scope {
                nil
            } else {
                try outboxRepository.latestPendingIntentID(
                    workID: request.workID,
                    scope: scope
                )
            }
            return V2CheckpointResult(
                snapshotID: current,
                generation: request.expectedGeneration,
                intentID: intentID,
                noChanges: true,
                promotedLeaf: promoted
            )
        }
    }
}
