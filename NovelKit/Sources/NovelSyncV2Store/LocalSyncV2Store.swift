import CSQLite
import Foundation
import NovelCore
import NovelSyncV2

public enum SyncV2StoreError: Error, Equatable, Sendable {
    case invalidRoot
    case sqlite(String)
    case schemaMismatch
    case workNotFound
    case generationMismatch
    case snapshotNotFound
    case invalidSnapshot
    case invalidCommand
    case commandAlreadySealed
    case accountMismatch
    case staleCAS
    case inboxNotFound
    case conflictNotFound
    case staleConflictAction
}

public struct V2AccountBinding: Hashable, Sendable {
    public let accountID: String
    public let accountFence: String
    public let serverInstanceID: String
    public let protocolEpoch: Int64
    public init(accountID: String, accountFence: String, serverInstanceID: String, protocolEpoch: Int64 = 2) {
        self.accountID = accountID; self.accountFence = accountFence; self.serverInstanceID = serverInstanceID; self.protocolEpoch = protocolEpoch
    }
}

public enum V2LocalWorkScope: Hashable, Sendable {
    case unbound
    case bound(V2AccountBinding)
}

public struct V2WorkSummary: Hashable, Sendable {
    public let workID: WorkID
    public let documentID: DocumentID
    public let localGeneration: Int64
    public let currentSnapshotID: SnapshotID?
    public let acknowledgedHeadGeneration: Int64?
    public init(workID: WorkID, documentID: DocumentID, localGeneration: Int64, currentSnapshotID: SnapshotID?, acknowledgedHeadGeneration: Int64?) {
        self.workID = workID; self.documentID = documentID; self.localGeneration = localGeneration; self.currentSnapshotID = currentSnapshotID; self.acknowledgedHeadGeneration = acknowledgedHeadGeneration
    }
}

public enum V2CheckpointReason: String, Codable, Sendable {
    case autosave
    case explicit
    case navigation
    case close
    case restore
    case migration
}

public struct V2OpenResult: Sendable {
    public let summary: V2WorkSummary
    public let document: NovelDocument?
    public init(summary: V2WorkSummary, document: NovelDocument?) {
        self.summary = summary; self.document = document
    }
}

public struct V2CheckpointRequest: Sendable {
    public let workID: WorkID
    public let document: NovelDocument
    public let documentCreatedAt: Date
    public let expectedGeneration: Int64
    public let reason: V2CheckpointReason
    public let attachments: [SyncAttachment]
    public init(workID: WorkID, document: NovelDocument, documentCreatedAt: Date, expectedGeneration: Int64, reason: V2CheckpointReason = .autosave, attachments: [SyncAttachment] = []) {
        self.workID = workID; self.document = document; self.documentCreatedAt = documentCreatedAt; self.expectedGeneration = expectedGeneration; self.reason = reason; self.attachments = attachments
    }
}

public struct V2CheckpointResult: Sendable {
    public let snapshotID: SnapshotID
    public let generation: Int64
    public let intentID: UUID?
    public let noChanges: Bool
    public init(snapshotID: SnapshotID, generation: Int64, intentID: UUID?, noChanges: Bool = false) {
        self.snapshotID = snapshotID; self.generation = generation; self.intentID = intentID; self.noChanges = noChanges
    }
}

public struct V2PendingIntent: Hashable, Sendable {
    public let intentID: UUID
    public let workID: WorkID
    public let sourceSnapshotID: SnapshotID
    public let sourceGeneration: Int64
    public let kind: String
    public let status: String
}

public struct V2RemoteHead: Hashable, Sendable {
    public let snapshotID: SnapshotID
    public let generation: Int64

    public init(snapshotID: SnapshotID, generation: Int64) {
        self.snapshotID = snapshotID
        self.generation = generation
        precondition(generation > 0)
    }
}

public struct V2RemoteSnapshot: Sendable {
    public let inboxID: UUID
    public let workID: WorkID
    public let encoded: EncodedSnapshot
    public let expectedCurrentSnapshotID: SnapshotID?
    public let expectedLocalGeneration: Int64
    public let expectedRemoteHead: V2RemoteHead?
    public init(inboxID: UUID = UUID(), workID: WorkID, encoded: EncodedSnapshot, expectedCurrentSnapshotID: SnapshotID?, expectedLocalGeneration: Int64, expectedRemoteHead: V2RemoteHead? = nil) {
        self.inboxID = inboxID; self.workID = workID; self.encoded = encoded; self.expectedCurrentSnapshotID = expectedCurrentSnapshotID; self.expectedLocalGeneration = expectedLocalGeneration; self.expectedRemoteHead = expectedRemoteHead
    }
}

public struct V2ConflictCandidate: Hashable, Sendable {
    public let conflictID: UUID
    public let revision: Int64
    public let workID: WorkID
    public let baseSnapshotID: SnapshotID?
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let sourceGeneration: Int64
}

public struct V2ServerResolutionRequest: Hashable, Sendable {
    public let workID: WorkID
    public let conflictID: UUID
    public let revision: Int64
    public let sourceGeneration: Int64
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let inboxID: UUID
    public let expectedRemoteHead: V2RemoteHead?

    public init(workID: WorkID, conflictID: UUID, revision: Int64, sourceGeneration: Int64, localSnapshotID: SnapshotID, remoteSnapshotID: SnapshotID, inboxID: UUID, expectedRemoteHead: V2RemoteHead? = nil) {
        self.workID = workID; self.conflictID = conflictID; self.revision = revision; self.sourceGeneration = sourceGeneration; self.localSnapshotID = localSnapshotID; self.remoteSnapshotID = remoteSnapshotID; self.inboxID = inboxID; self.expectedRemoteHead = expectedRemoteHead
    }
}

public struct V2DeviceResolutionRequest: Sendable {
    public let workID: WorkID
    public let conflictID: UUID
    public let revision: Int64
    public let sourceGeneration: Int64
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let remoteHead: V2RemoteHead
    public let document: NovelDocument
    public let documentCreatedAt: Date
    public let attachments: [SyncAttachment]

    public init(workID: WorkID, conflictID: UUID, revision: Int64, sourceGeneration: Int64, localSnapshotID: SnapshotID, remoteSnapshotID: SnapshotID, remoteHead: V2RemoteHead, document: NovelDocument, documentCreatedAt: Date, attachments: [SyncAttachment] = []) {
        self.workID = workID; self.conflictID = conflictID; self.revision = revision; self.sourceGeneration = sourceGeneration; self.localSnapshotID = localSnapshotID; self.remoteSnapshotID = remoteSnapshotID; self.remoteHead = remoteHead; self.document = document; self.documentCreatedAt = documentCreatedAt; self.attachments = attachments
    }
}

public struct V2KeepBothPreparationRequest: Sendable {
    public let workID: WorkID
    public let conflictID: UUID
    public let revision: Int64
    public let sourceGeneration: Int64
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let newWorkID: WorkID
    public let document: NovelDocument
    public let documentCreatedAt: Date
    public let attachments: [SyncAttachment]

    public init(workID: WorkID, conflictID: UUID, revision: Int64, sourceGeneration: Int64, localSnapshotID: SnapshotID, remoteSnapshotID: SnapshotID, newWorkID: WorkID, document: NovelDocument, documentCreatedAt: Date, attachments: [SyncAttachment] = []) {
        self.workID = workID; self.conflictID = conflictID; self.revision = revision; self.sourceGeneration = sourceGeneration; self.localSnapshotID = localSnapshotID; self.remoteSnapshotID = remoteSnapshotID; self.newWorkID = newWorkID; self.document = document; self.documentCreatedAt = documentCreatedAt; self.attachments = attachments
    }
}

public struct V2RestorePreparationRequest: Sendable {
    public let workID: WorkID
    public let selectedSnapshotID: SnapshotID
    public let expectedLocalGeneration: Int64
    public init(workID: WorkID, selectedSnapshotID: SnapshotID, expectedLocalGeneration: Int64) {
        self.workID = workID; self.selectedSnapshotID = selectedSnapshotID; self.expectedLocalGeneration = expectedLocalGeneration
    }
}

public actor LocalSyncV2Store {
    public let databaseURL: URL
    public let scope: V2LocalWorkScope
    public var binding: V2AccountBinding? {
        if case let .bound(value) = scope {
            return value
        }
        return nil
    }

    private var db: OpaquePointer?

    public init(root: URL, binding: V2AccountBinding) throws {
        try self.init(root: root, scope: .bound(binding))
    }

    public init(root: URL, scope: V2LocalWorkScope = .unbound) throws {
        guard root.isFileURL else { throw SyncV2StoreError.invalidRoot }
        var ancestor = root
        while ancestor.path != "/" {
            let isSystemAlias = ancestor.path == "/var" || ancestor.path == "/tmp"
            if !isSystemAlias, FileManager.default.fileExists(atPath: ancestor.path), try (ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false) {
                throw SyncV2StoreError.invalidRoot
            }
            ancestor.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseURL = root.appendingPathComponent("snapshot-sync-v2.sqlite")
        if FileManager.default.fileExists(atPath: databaseURL.path), try (databaseURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false) {
            throw SyncV2StoreError.invalidRoot
        }
        self.scope = scope
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else { throw SyncV2StoreError.sqlite("open \(result)") }
        db = handle
        sqlite3_busy_timeout(handle, 5000)
        do { try Self.bootstrapSchema(handle) } catch { sqlite3_close(handle); db = nil; throw error }
    }

    // SQLite connections are closed by process teardown. Swift 6 actor
    // deinit is nonisolated and cannot safely touch the C pointer.

    public func schemaVersionAndChecksum() throws -> (String, Data) {
        let row = try query("SELECT value, checksum FROM schema_meta WHERE key='schema'").first
        guard let row, let version = row[0].text, let checksum = row[1].blob else { throw SyncV2StoreError.schemaMismatch }
        return (version, checksum)
    }

    public func close() {
        if let db {
            sqlite3_close(db); self.db = nil
        }
    }

    public func bootstrap(workID: WorkID, documentID: DocumentID, documentCreatedAt: Date) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            let date = try Self.iso8601(documentCreatedAt)
            if let work = try scopedWorkRow(workID: workID) {
                guard work[1].text == documentID.description else { throw SyncV2StoreError.sqlite("document identity changed") }
            } else if try workExists(workID: workID) {
                throw SyncV2StoreError.workNotFound
            } else {
                try exec("INSERT INTO works(work_id,document_id,document_created_at) VALUES(?,?,?)", [.text(workID.description), .text(documentID.description), .text(date)])
            }
            if let b = binding {
                if let existing = try query("SELECT server_instance_id,protocol_epoch,account_id,account_fence,state FROM account_bindings WHERE work_id=? AND account_id=? AND account_fence=? AND server_instance_id=?", [.text(workID.description), .text(b.accountID), .text(b.accountFence), .text(b.serverInstanceID)]).first {
                    guard existing[1].int64 == b.protocolEpoch, existing[4].text == "bound" else { throw SyncV2StoreError.accountMismatch }
                } else if try query("SELECT 1 FROM account_bindings WHERE work_id=?", [.text(workID.description)]).isEmpty {
                    try exec("INSERT INTO account_bindings(work_id,server_instance_id,protocol_epoch,account_id,account_fence,state) VALUES(?,?,?,?,?,'bound')", [.text(workID.description), .text(b.serverInstanceID), .int(b.protocolEpoch), .text(b.accountID), .text(b.accountFence)])
                } else {
                    throw SyncV2StoreError.accountMismatch
                }
            } else if try !(query("SELECT 1 FROM account_bindings WHERE work_id=?", [.text(workID.description)]).isEmpty) {
                throw SyncV2StoreError.accountMismatch
            }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    public func listWorks() throws -> [V2WorkSummary] {
        if let b = binding {
            return try query("SELECT w.work_id,w.document_id,w.local_generation,w.current_snapshot_id,w.acknowledged_head_generation FROM works w JOIN account_bindings b ON b.work_id=w.work_id WHERE b.account_id=? AND b.account_fence=? AND b.server_instance_id=? AND b.state='bound' ORDER BY lower(w.work_id)", [.text(b.accountID), .text(b.accountFence), .text(b.serverInstanceID)]).map(Self.summary)
        }
        return try query("SELECT w.work_id,w.document_id,w.local_generation,w.current_snapshot_id,w.acknowledged_head_generation FROM works w LEFT JOIN account_bindings b ON b.work_id=w.work_id WHERE b.work_id IS NULL ORDER BY lower(w.work_id)").map(Self.summary)
    }

    public func open(workID: WorkID) throws -> V2OpenResult {
        guard let row = try scopedWorkRow(workID: workID) else { throw SyncV2StoreError.workNotFound }
        let summary = try Self.summary(row)
        guard let sid = summary.currentSnapshotID else { return V2OpenResult(summary: summary, document: nil) }
        let encoded = try loadEncoded(workID: workID, snapshotID: sid)
        return try V2OpenResult(summary: summary, document: SnapshotCodec.decode(manifestBytes: encoded.manifestBytes, objects: encoded.objects).document)
    }

    public func checkpoint(_ request: V2CheckpointRequest) throws -> V2CheckpointResult {
        var parents: [SnapshotID] = []
        let existingWork = try scopedWorkRow(workID: request.workID)
        if existingWork == nil, try workExists(workID: request.workID) {
            throw SyncV2StoreError.workNotFound
        }
        if let current = existingWork {
            guard let generation = current[2].int64, generation == request.expectedGeneration else { throw SyncV2StoreError.generationMismatch }
            guard current[1].text == request.document.id.uuidString.lowercased() else { throw SyncV2StoreError.sqlite("document identity changed") }
            if let bytes = current[3].blob, bytes.count == 32 {
                let id = try SnapshotID(rawValue: bytes.hexString); parents = [id]
            }
        }
        let encoded = try SnapshotCodec.encode(SnapshotModel(workId: request.workID, document: request.document, documentCreatedAt: request.documentCreatedAt, attachments: request.attachments), parents: parents)
        if let current = existingWork, let currentBytes = current[3].blob, currentBytes.count == 32 {
            let currentID = try SnapshotID(rawValue: currentBytes.hexString)
            let previous = try loadEncoded(workID: request.workID, snapshotID: currentID)
            if previous.manifest.entries == encoded.manifest.entries, previous.objects == encoded.objects {
                return V2CheckpointResult(snapshotID: currentID, generation: request.expectedGeneration, intentID: nil, noChanges: true)
            }
        }
        var intentID = UUID()
        try exec("BEGIN IMMEDIATE")
        do {
            if existingWork == nil {
                let date = try Self.iso8601(request.documentCreatedAt)
                try exec("INSERT INTO works(work_id,document_id,document_created_at) VALUES(?,?,?)", [.text(request.workID.description), .text(request.document.id.uuidString.lowercased()), .text(date)])
                if let b = binding {
                    try exec("INSERT INTO account_bindings(work_id,server_instance_id,protocol_epoch,account_id,account_fence,state) VALUES(?,?,?,?,?,'bound')", [.text(request.workID.description), .text(b.serverInstanceID), .int(b.protocolEpoch), .text(b.accountID), .text(b.accountFence)])
                }
            }
            if let b = binding {
                guard let bindingRow = try query("SELECT server_instance_id,protocol_epoch,account_id,account_fence,state FROM account_bindings WHERE work_id=? AND account_id=? AND account_fence=? AND server_instance_id=?", [.text(request.workID.description), .text(b.accountID), .text(b.accountFence), .text(b.serverInstanceID)]).first,
                      bindingRow[1].int64 == b.protocolEpoch, bindingRow[4].text == "bound" else { throw SyncV2StoreError.accountMismatch }
            } else if try !(query("SELECT 1 FROM account_bindings WHERE work_id=?", [.text(request.workID.description)]).isEmpty) {
                throw SyncV2StoreError.accountMismatch
            }
            guard let row = try query("SELECT local_generation FROM works WHERE work_id=?", [.text(request.workID.description)]).first, row[0].int64 == request.expectedGeneration else { throw SyncV2StoreError.generationMismatch }
            try insertEncoded(encoded, workID: request.workID)
            let next = request.expectedGeneration + 1
            try exec("UPDATE works SET current_snapshot_id=?,local_generation=? WHERE work_id=? AND local_generation=?", [.blob(encoded.snapshotIDBytes), .int(next), .text(request.workID.description), .int(request.expectedGeneration)])
            guard try changes() == 1 else { throw SyncV2StoreError.generationMismatch }
            try exec("INSERT INTO history_occurrences(occurrence_id,work_id,snapshot_id,reason,pinned,local_generation,created_at) VALUES(?,?,?,?,?,?,?)", [.text(UUID().uuidString.lowercased()), .text(request.workID.description), .blob(encoded.snapshotIDBytes), .text(request.reason.rawValue), .int(0), .int(next), .text(Self.now())])
            if let existing = try query("SELECT intent_id FROM sync_intents WHERE work_id=? AND kind='checkpoint' AND status='pending' ORDER BY source_generation DESC LIMIT 1", [.text(request.workID.description)]).first, let existingID = existing[0].text, let parsedID = UUID(uuidString: existingID) {
                intentID = parsedID
                try exec("UPDATE sync_intents SET source_snapshot_id=?,source_generation=? WHERE intent_id=? AND status='pending'", [.blob(encoded.snapshotIDBytes), .int(next), .text(existingID)])
            } else {
                try exec("INSERT INTO sync_intents(intent_id,work_id,source_snapshot_id,source_generation,kind,status,created_at) VALUES(?,?,?,?,?,'pending',?)", [.text(intentID.uuidString.lowercased()), .text(request.workID.description), .blob(encoded.snapshotIDBytes), .int(next), .text("checkpoint"), .text(Self.now())])
            }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
        return V2CheckpointResult(snapshotID: encoded.snapshotId, generation: request.expectedGeneration + 1, intentID: intentID)
    }

    public func pendingIntents(workID: WorkID? = nil) throws -> [V2PendingIntent] {
        let rows: [[SQLiteValue]] = if let b = binding {
            try workID.map { try query("SELECT i.intent_id,i.work_id,i.source_snapshot_id,i.source_generation,i.kind,i.status FROM sync_intents i JOIN account_bindings b ON b.work_id=i.work_id WHERE i.work_id=? AND b.account_id=? AND b.account_fence=? AND b.server_instance_id=? AND b.state='bound' AND i.status IN('pending','sealed') ORDER BY i.source_generation", [.text($0.description), .text(b.accountID), .text(b.accountFence), .text(b.serverInstanceID)]) } ?? query("SELECT i.intent_id,i.work_id,i.source_snapshot_id,i.source_generation,i.kind,i.status FROM sync_intents i JOIN account_bindings b ON b.work_id=i.work_id WHERE b.account_id=? AND b.account_fence=? AND b.server_instance_id=? AND b.state='bound' AND i.status IN('pending','sealed') ORDER BY i.work_id,i.source_generation", [.text(b.accountID), .text(b.accountFence), .text(b.serverInstanceID)])
        } else {
            try workID.map { try query("SELECT i.intent_id,i.work_id,i.source_snapshot_id,i.source_generation,i.kind,i.status FROM sync_intents i LEFT JOIN account_bindings b ON b.work_id=i.work_id WHERE i.work_id=? AND b.work_id IS NULL AND i.status IN('pending','sealed') ORDER BY i.source_generation", [.text($0.description)]) } ?? query("SELECT i.intent_id,i.work_id,i.source_snapshot_id,i.source_generation,i.kind,i.status FROM sync_intents i LEFT JOIN account_bindings b ON b.work_id=i.work_id WHERE b.work_id IS NULL AND i.status IN('pending','sealed') ORDER BY i.work_id,i.source_generation")
        }
        return try rows.map { row in guard let i = row[0].text, let w = row[1].text, let sb = row[2].blob, let sg = row[3].int64, let kind = row[4].text, let status = row[5].text else { throw SyncV2StoreError.sqlite("intent") }; return try V2PendingIntent(intentID: UUID(uuidString: i)!, workID: WorkID(uuidString: w), sourceSnapshotID: SnapshotID(rawValue: sb.hexString), sourceGeneration: sg, kind: kind, status: status) }
    }

    public func seal(_ command: SealedCommand, intentID: UUID? = nil) throws {
        guard let b = binding, command.binding.accountId == b.accountID, command.binding.accountFence == b.accountFence, command.binding.protocolEpoch == b.protocolEpoch, command.binding.serverInstanceId == b.serverInstanceID else { throw SyncV2StoreError.accountMismatch }
        guard SealedCommand.requestDigest(for: command.canonicalBytes) == command.requestDigest, SealedCommand.isCanonical(command.canonicalBytes) else { throw SyncV2StoreError.invalidCommand }
        let exists = try query("SELECT request_digest,canonical_request FROM sealed_commands WHERE account_id=? AND command_id=?", [.text(b.accountID), .text(command.commandId.uuidString.lowercased())]).first
        if let exists {
            if exists[0].blob?.hexString == command.requestDigest.rawValue, exists[1].blob == command.canonicalBytes {
                return
            }; throw SyncV2StoreError.commandAlreadySealed
        }
        let workID = command.payloadWorkID ?? ""
        try exec("BEGIN IMMEDIATE")
        do {
            if let intentID {
                guard let intent = try query("SELECT i.work_id,i.source_snapshot_id,i.source_generation,i.status FROM sync_intents i JOIN account_bindings b ON b.work_id=i.work_id WHERE i.intent_id=? AND b.account_id=? AND b.account_fence=? AND b.server_instance_id=?", [.text(intentID.uuidString.lowercased()), .text(b.accountID), .text(b.accountFence), .text(b.serverInstanceID)]).first,
                      intent[0].text == workID, intent[1].blob?.hexString == command.sourceSnapshotId.rawValue,
                      intent[2].int64 == command.sourceGeneration, intent[3].text == "pending" else { throw SyncV2StoreError.invalidCommand }
            }
            guard let source = try query("SELECT local_generation FROM works w JOIN account_bindings b ON b.work_id=w.work_id WHERE w.work_id=? AND b.account_id=? AND b.account_fence=? AND b.server_instance_id=? AND b.state='bound'", [.text(workID), .text(b.accountID), .text(b.accountFence), .text(b.serverInstanceID)]).first else { throw SyncV2StoreError.accountMismatch }
            guard source[0].int64 ?? 0 >= command.sourceGeneration else { throw SyncV2StoreError.invalidCommand }
            try exec("INSERT INTO sealed_commands(command_id,work_id,intent_id,account_id,account_fence,command_kind,canonical_request,request_digest,source_snapshot_id,source_generation,status) VALUES(?,?,?,?,?,?,?,?,?,?, 'sealed')", [.text(command.commandId.uuidString.lowercased()), .text(workID), intentID.map { .text($0.uuidString.lowercased()) } ?? .null, .text(b.accountID), .text(b.accountFence), .text(command.commandKind), .blob(command.canonicalBytes), .blob(command.requestDigestBytes), .blob(command.sourceSnapshotIdBytes), .int(command.sourceGeneration)])
            if let intentID {
                try exec("UPDATE sync_intents SET status='sealed' WHERE intent_id=? AND status='pending'", [.text(intentID.uuidString.lowercased())])
            }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    public func acknowledge(commandID: UUID, responseStatus: Int, canonicalResponse: Data, remoteHead: V2RemoteHead?, readBackVerified: Bool = true) throws {
        guard let b = binding else { throw SyncV2StoreError.accountMismatch }
        try CanonicalJSON.validate(canonicalResponse)
        guard let row = try query("SELECT work_id,command_kind,request_digest,source_generation FROM sealed_commands WHERE account_id=? AND account_fence=? AND command_id=?", [.text(b.accountID), .text(b.accountFence), .text(commandID.uuidString.lowercased())]).first, let work = row[0].text, let kind = row[1].text, let digest = row[2].blob, let sealedGeneration = row[3].int64 else { throw SyncV2StoreError.invalidCommand }
        if let receipt = try query("SELECT request_digest,response_status,canonical_response,read_back_verified FROM remote_receipts WHERE account_id=? AND command_id=?", [.text(b.accountID), .text(commandID.uuidString.lowercased())]).first {
            guard receipt[0].blob == digest, receipt[1].int64 == Int64(responseStatus), receipt[2].blob == canonicalResponse, receipt[3].int64 == (readBackVerified ? 1 : 0) else { throw SyncV2StoreError.invalidCommand }
            return
        }
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("UPDATE sealed_commands SET status='completed',response_status=?,canonical_response=?,receipt_verified=? WHERE account_id=? AND account_fence=? AND command_id=?", [.int(Int64(responseStatus)), .blob(canonicalResponse), .int(readBackVerified ? 1 : 0), .text(b.accountID), .text(b.accountFence), .text(commandID.uuidString.lowercased())])
            try exec("INSERT INTO remote_receipts(account_id,work_id,command_id,command_kind,request_digest,response_status,canonical_response,read_back_verified) VALUES(?,?,?,?,?,?,?,?)", [.text(b.accountID), .text(work), .text(commandID.uuidString.lowercased()), .text(kind), .blob(digest), .int(Int64(responseStatus)), .blob(canonicalResponse), .int(readBackVerified ? 1 : 0)])
            if let head = remoteHead {
                try exec("UPDATE works SET acknowledged_head_snapshot_id=?,acknowledged_head_generation=? WHERE work_id=? AND local_generation>=? AND (acknowledged_head_generation IS NULL OR acknowledged_head_generation<=?)", [.blob(head.snapshotID.bytes), .int(head.generation), .text(work), .int(sealedGeneration), .int(head.generation)])
            }
            try exec("UPDATE sync_intents SET status='acknowledged' WHERE work_id=? AND source_generation<=? AND status IN('pending','sealed')", [.text(work), .int(sealedGeneration)])
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    public func stageRemote(_ remote: V2RemoteSnapshot) throws {
        guard let b = binding else { throw SyncV2StoreError.accountMismatch }
        try SnapshotValidator.validate(remote.encoded.manifest); try SnapshotValidator.validateObjects(remote.encoded)
        guard remote.encoded.manifest.workId == remote.workID else { throw SyncV2StoreError.invalidSnapshot }
        let model = try SnapshotCodec.decode(manifestBytes: remote.encoded.manifestBytes, objects: remote.encoded.objects)
        let inbox = remote.inboxID.uuidString.lowercased()
        try exec("BEGIN IMMEDIATE")
        do {
            try ensureRemoteWork(workID: remote.workID, documentID: DocumentID(model.document.id), documentCreatedAt: model.documentCreatedAt)
            if let existing = try query("SELECT i.manifest_bytes FROM inbox_batches i JOIN account_bindings b ON b.work_id=i.work_id WHERE i.inbox_id=? AND i.account_id=? AND i.account_fence=? AND b.server_instance_id=? AND b.state='bound'", [.text(inbox), .text(b.accountID), .text(b.accountFence), .text(b.serverInstanceID)]).first {
                guard existing[0].blob == remote.encoded.manifestBytes else { throw SyncV2StoreError.invalidSnapshot }
            } else {
                try exec("INSERT INTO inbox_batches(inbox_id,work_id,account_id,account_fence,snapshot_id,manifest_bytes,expected_current_snapshot_id,expected_local_generation,expected_remote_head_snapshot_id,expected_remote_head_generation,state) VALUES(?,?,?,?,?,?,?,?,?,?, 'staged')", [.text(inbox), .text(remote.workID.description), .text(b.accountID), .text(b.accountFence), .blob(remote.encoded.snapshotIDBytes), .blob(remote.encoded.manifestBytes), remote.expectedCurrentSnapshotID.map { .blob($0.bytes) } ?? .null, .int(remote.expectedLocalGeneration), remote.expectedRemoteHead.map { .blob($0.snapshotID.bytes) } ?? .null, remote.expectedRemoteHead.map { .int($0.generation) } ?? .null])
            }
            for (id, bytes) in remote.encoded.objects {
                if let existing = try query("SELECT bytes,byte_count FROM inbox_objects WHERE inbox_id=? AND object_id=?", [.text(inbox), .blob(id.bytes)]).first {
                    guard existing[0].blob == bytes, existing[1].int64 == Int64(bytes.count) else { throw SyncV2StoreError.invalidSnapshot }
                } else {
                    try exec("INSERT INTO inbox_objects(inbox_id,object_id,byte_count,bytes,verified) VALUES(?,?,?,?,0)", [.text(inbox), .blob(id.bytes), .int(Int64(bytes.count)), .blob(bytes)])
                }
            }
            for entry in remote.encoded.manifest.entries {
                if let existing = try query("SELECT object_id FROM inbox_closure WHERE inbox_id=? AND entity_key=?", [.text(inbox), .text(entry.entityKey)]).first {
                    guard existing[0].blob == entry.objectId.bytes else { throw SyncV2StoreError.invalidSnapshot }
                } else {
                    try exec("INSERT INTO inbox_closure(inbox_id,entity_key,object_id) VALUES(?,?,?)", [.text(inbox), .text(entry.entityKey), .blob(entry.objectId.bytes)])
                }
            }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    public func verifyInbox(inboxID: UUID) throws {
        guard let b = binding else { throw SyncV2StoreError.accountMismatch }
        guard let row = try query("SELECT i.work_id,i.snapshot_id,i.manifest_bytes,i.state FROM inbox_batches i JOIN account_bindings b ON b.work_id=i.work_id WHERE i.inbox_id=? AND i.account_id=? AND i.account_fence=? AND b.server_instance_id=? AND b.state='bound'", [.text(inboxID.uuidString.lowercased()), .text(b.accountID), .text(b.accountFence), .text(b.serverInstanceID)]).first, let bytes = row[2].blob, row[3].text == "staged" else { throw SyncV2StoreError.inboxNotFound }
        let parsed = try SnapshotValidator.validate(manifestBytes: bytes)
        guard row[1].blob?.hexString == SnapshotID(data: bytes).rawValue, parsed.workId.description == row[0].text else { throw SyncV2StoreError.invalidSnapshot }
        let encoded = try loadInboxEncoded(inboxID: inboxID, manifestBytes: bytes, verifiedOnly: false)
        try SnapshotValidator.validateObjects(encoded)
        let inbox = inboxID.uuidString.lowercased()
        guard try query("SELECT COUNT(*) FROM inbox_closure WHERE inbox_id=?", [.text(inbox)]).first?[0].int64 == Int64(parsed.entries.count) else { throw SyncV2StoreError.invalidSnapshot }
        guard try query("SELECT COUNT(*) FROM inbox_objects WHERE inbox_id=?", [.text(inbox)]).first?[0].int64 == Int64(Set(parsed.entries.map(\.objectId)).count) else { throw SyncV2StoreError.invalidSnapshot }
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("UPDATE inbox_objects SET verified=1 WHERE inbox_id=?", [.text(inbox)])
            try exec("UPDATE inbox_batches SET state='verified' WHERE inbox_id=? AND state='staged'", [.text(inbox)])
            guard try changes() == 1 else { throw SyncV2StoreError.inboxNotFound }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    public func adoptInbox(inboxID: UUID, expectedConflict: V2ServerResolutionRequest? = nil) throws {
        guard let b = binding else { throw SyncV2StoreError.accountMismatch }
        guard let row = try query("SELECT i.work_id,i.snapshot_id,i.manifest_bytes,i.expected_current_snapshot_id,i.expected_local_generation,i.expected_remote_head_snapshot_id,i.expected_remote_head_generation,i.state FROM inbox_batches i JOIN account_bindings b ON b.work_id=i.work_id WHERE i.inbox_id=? AND i.account_id=? AND i.account_fence=? AND b.server_instance_id=? AND b.state='bound'", [.text(inboxID.uuidString.lowercased()), .text(b.accountID), .text(b.accountFence), .text(b.serverInstanceID)]).first, let work = row[0].text, let sb = row[1].blob, let manifest = row[2].blob, row[7].text == "verified" else { throw SyncV2StoreError.inboxNotFound }
        let expected = row[3].blob?.hexString; let expectedGeneration = row[4].int64 ?? 0
        let expectedRemoteHead = row[5].blob.flatMap { snapshot -> V2RemoteHead? in guard let generation = row[6].int64, let id = try? SnapshotID(rawValue: snapshot.hexString) else { return nil }; return V2RemoteHead(snapshotID: id, generation: generation) }
        if let request = expectedConflict, request.expectedRemoteHead != expectedRemoteHead {
            throw SyncV2StoreError.staleConflictAction
        }
        let encoded = try loadInboxEncoded(inboxID: inboxID, manifestBytes: manifest)
        try exec("BEGIN IMMEDIATE")
        do {
            guard let current = try query("SELECT current_snapshot_id,local_generation FROM works WHERE work_id=?", [.text(work)]).first, current[0].blob?.hexString == expected, current[1].int64 == expectedGeneration else { throw SyncV2StoreError.staleCAS }
            if let expectedConflict {
                guard let candidate = try query("SELECT c.conflict_id,c.current_revision,k.source_generation,k.local_snapshot_id,k.remote_snapshot_id,k.remote_inbox_id FROM conflicts c JOIN conflict_candidates k ON k.conflict_id=c.conflict_id AND k.revision=c.current_revision WHERE c.work_id=? AND c.state='active'", [.text(work)]).first,
                      candidate[0].text == expectedConflict.conflictID.uuidString.lowercased(), candidate[1].int64 == expectedConflict.revision, candidate[2].int64 == expectedConflict.sourceGeneration, candidate[3].blob?.hexString == expectedConflict.localSnapshotID.rawValue, candidate[4].blob?.hexString == expectedConflict.remoteSnapshotID.rawValue, candidate[5].text == expectedConflict.inboxID.uuidString.lowercased() else { throw SyncV2StoreError.staleConflictAction }
            }
            let workID = try WorkID(uuidString: work)
            if let previous = current[0].blob, expectedGeneration > 0 {
                try exec("INSERT INTO history_occurrences(occurrence_id,work_id,snapshot_id,reason,pinned,local_generation,created_at) VALUES(?,?,?,?,?,?,?)", [.text(UUID().uuidString.lowercased()), .text(work), .blob(previous), .text("preRemoteAdoption"), .int(1), .int(expectedGeneration), .text(Self.now())])
            }
            try insertEncoded(encoded, workID: workID)
            let next = expectedGeneration + 1
            try exec("INSERT INTO history_occurrences(occurrence_id,work_id,snapshot_id,reason,pinned,local_generation,created_at) VALUES(?,?,?,?,?,?,?)", [.text(UUID().uuidString.lowercased()), .text(work), .blob(sb), .text("remoteAdoption"), .int(0), .int(next), .text(Self.now())])
            try exec("UPDATE works SET current_snapshot_id=?,local_generation=? WHERE work_id=? AND local_generation=?", [.blob(sb), .int(next), .text(work), .int(expectedGeneration)])
            guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
            if let head = expectedRemoteHead {
                try exec("UPDATE works SET acknowledged_head_snapshot_id=?,acknowledged_head_generation=? WHERE work_id=? AND (acknowledged_head_generation IS NULL OR acknowledged_head_generation<=?)", [.blob(head.snapshotID.bytes), .int(head.generation), .text(work), .int(head.generation)])
            }
            try exec("UPDATE conflicts SET state='resolved' WHERE work_id=? AND state='active' AND conflict_id IN (SELECT conflict_id FROM conflict_candidates WHERE remote_inbox_id=? AND remote_snapshot_id=? )", [.text(work), .text(inboxID.uuidString.lowercased()), .blob(sb)])
            try exec("UPDATE inbox_batches SET state='adopted' WHERE inbox_id=?", [.text(inboxID.uuidString.lowercased())]); try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }

    public func prepareUseDevice(_ request: V2DeviceResolutionRequest) throws -> V2CheckpointResult {
        guard let active = try activeConflict(workID: request.workID), active.conflictID == request.conflictID, active.revision == request.revision, active.sourceGeneration == request.sourceGeneration, active.localSnapshotID == request.localSnapshotID, active.remoteSnapshotID == request.remoteSnapshotID else { throw SyncV2StoreError.staleConflictAction }
        guard let current = try scopedWorkRow(workID: request.workID), current[3].blob?.hexString == request.localSnapshotID.rawValue, current[2].int64 == request.sourceGeneration else { throw SyncV2StoreError.staleConflictAction }
        guard let conflictRow = try query("SELECT remote_inbox_id,manifest_bytes FROM conflict_candidates k JOIN inbox_batches i ON i.inbox_id=k.remote_inbox_id WHERE k.conflict_id=? AND k.revision=? AND i.state='verified'", [.text(request.conflictID.uuidString.lowercased()), .int(request.revision)]).first, let inboxString = conflictRow[0].text, let inboxID = UUID(uuidString: inboxString), let manifest = conflictRow[1].blob else { throw SyncV2StoreError.inboxNotFound }
        let remoteEncoded = try loadInboxEncoded(inboxID: inboxID, manifestBytes: manifest)
        let parents = [request.localSnapshotID, request.remoteSnapshotID].sorted { $0.rawValue < $1.rawValue }
        let encoded = try SnapshotCodec.encode(SnapshotModel(workId: request.workID, document: request.document, documentCreatedAt: request.documentCreatedAt, attachments: request.attachments), parents: parents)
        let next = request.sourceGeneration + 1
        let intentID = UUID()
        try exec("BEGIN IMMEDIATE")
        do {
            try insertEncoded(remoteEncoded, workID: request.workID)
            try insertEncoded(encoded, workID: request.workID)
            try exec("UPDATE works SET current_snapshot_id=?,local_generation=? WHERE work_id=? AND local_generation=?", [.blob(encoded.snapshotIDBytes), .int(next), .text(request.workID.description), .int(request.sourceGeneration)])
            guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
            try exec("INSERT INTO history_occurrences(occurrence_id,work_id,snapshot_id,reason,pinned,local_generation,created_at) VALUES(?,?,?,?,?,?,?)", [.text(UUID().uuidString.lowercased()), .text(request.workID.description), .blob(encoded.snapshotIDBytes), .text("conflictResolution"), .int(0), .int(next), .text(Self.now())])
            try exec("INSERT INTO sync_intents(intent_id,work_id,source_snapshot_id,source_generation,kind,status,created_at) VALUES(?,?,?,?,?,'pending',?)", [.text(intentID.uuidString.lowercased()), .text(request.workID.description), .blob(encoded.snapshotIDBytes), .int(next), .text("conflictResolution"), .text(Self.now())])
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
        return V2CheckpointResult(snapshotID: encoded.snapshotId, generation: next, intentID: intentID)
    }

    public func prepareKeepBoth(_ request: V2KeepBothPreparationRequest) throws -> V2CheckpointResult {
        guard let active = try activeConflict(workID: request.workID), active.conflictID == request.conflictID, active.revision == request.revision, active.sourceGeneration == request.sourceGeneration, active.localSnapshotID == request.localSnapshotID, active.remoteSnapshotID == request.remoteSnapshotID else { throw SyncV2StoreError.staleConflictAction }
        guard request.newWorkID != request.workID, try !workExists(workID: request.newWorkID) else { throw SyncV2StoreError.accountMismatch }
        guard binding != nil else { throw SyncV2StoreError.accountMismatch }
        let encoded = try SnapshotCodec.encode(SnapshotModel(workId: request.newWorkID, document: request.document, documentCreatedAt: request.documentCreatedAt, attachments: request.attachments), parents: [])
        let intentID = UUID()
        try exec("BEGIN IMMEDIATE")
        do {
            try ensureRemoteWork(workID: request.newWorkID, documentID: DocumentID(request.document.id), documentCreatedAt: request.documentCreatedAt)
            try insertEncoded(encoded, workID: request.newWorkID)
            try exec("UPDATE works SET current_snapshot_id=?,local_generation=1 WHERE work_id=? AND local_generation=0", [.blob(encoded.snapshotIDBytes), .text(request.newWorkID.description)])
            guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
            try exec("INSERT INTO history_occurrences(occurrence_id,work_id,snapshot_id,reason,pinned,local_generation,created_at) VALUES(?,?,?,?,?,?,?)", [.text(UUID().uuidString.lowercased()), .text(request.newWorkID.description), .blob(encoded.snapshotIDBytes), .text("keepBoth"), .int(0), .int(1), .text(Self.now())])
            try exec("INSERT INTO sync_intents(intent_id,work_id,source_snapshot_id,source_generation,kind,status,created_at) VALUES(?,?,?,?,?,'pending',?)", [.text(intentID.uuidString.lowercased()), .text(request.newWorkID.description), .blob(encoded.snapshotIDBytes), .int(1), .text("checkpoint"), .text(Self.now())])
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
        return V2CheckpointResult(snapshotID: encoded.snapshotId, generation: 1, intentID: intentID)
    }

    public func prepareRestore(_ request: V2RestorePreparationRequest) throws -> V2CheckpointResult {
        guard let current = try scopedWorkRow(workID: request.workID), let currentBytes = current[3].blob, current[2].int64 == request.expectedLocalGeneration else { throw SyncV2StoreError.staleCAS }
        let currentID = try SnapshotID(rawValue: currentBytes.hexString)
        let selected = try loadEncoded(workID: request.workID, snapshotID: request.selectedSnapshotID)
        let model = try SnapshotCodec.decode(manifestBytes: selected.manifestBytes, objects: selected.objects)
        let encoded = try SnapshotCodec.encode(model, parents: [currentID])
        let next = request.expectedLocalGeneration + 1
        let intentID = UUID()
        try exec("BEGIN IMMEDIATE")
        do {
            try insertEncoded(encoded, workID: request.workID)
            try exec("INSERT INTO history_occurrences(occurrence_id,work_id,snapshot_id,reason,pinned,local_generation,created_at) VALUES(?,?,?,?,?,?,?)", [.text(UUID().uuidString.lowercased()), .text(request.workID.description), .blob(request.selectedSnapshotID.bytes), .text("preRestore"), .int(1), .int(request.expectedLocalGeneration), .text(Self.now())])
            try exec("UPDATE works SET current_snapshot_id=?,local_generation=? WHERE work_id=? AND local_generation=?", [.blob(encoded.snapshotIDBytes), .int(next), .text(request.workID.description), .int(request.expectedLocalGeneration)])
            guard try changes() == 1 else { throw SyncV2StoreError.staleCAS }
            try exec("INSERT INTO history_occurrences(occurrence_id,work_id,snapshot_id,reason,pinned,local_generation,created_at) VALUES(?,?,?,?,?,?,?)", [.text(UUID().uuidString.lowercased()), .text(request.workID.description), .blob(encoded.snapshotIDBytes), .text("restore"), .int(0), .int(next), .text(Self.now())])
            try exec("INSERT INTO sync_intents(intent_id,work_id,source_snapshot_id,source_generation,kind,status,created_at) VALUES(?,?,?,?,?,'pending',?)", [.text(intentID.uuidString.lowercased()), .text(request.workID.description), .blob(encoded.snapshotIDBytes), .int(next), .text("restore"), .text(Self.now())])
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
        return V2CheckpointResult(snapshotID: encoded.snapshotId, generation: next, intentID: intentID)
    }

    public func resolveServer(_ request: V2ServerResolutionRequest) throws {
        guard let active = try activeConflict(workID: request.workID), active.conflictID == request.conflictID, active.revision == request.revision, active.sourceGeneration == request.sourceGeneration, active.localSnapshotID == request.localSnapshotID, active.remoteSnapshotID == request.remoteSnapshotID else { throw SyncV2StoreError.staleConflictAction }
        try adoptInbox(inboxID: request.inboxID, expectedConflict: request)
    }

    public func appendConflict(workID: WorkID, baseSnapshotID: SnapshotID?, localSnapshotID: SnapshotID, remote: V2RemoteSnapshot, sourceGeneration: Int64) throws -> V2ConflictCandidate {
        guard let b = binding, try !query("SELECT 1 FROM account_bindings WHERE work_id=? AND account_id=? AND account_fence=? AND server_instance_id=? AND state='bound'", [.text(workID.description), .text(b.accountID), .text(b.accountFence), .text(b.serverInstanceID)]).isEmpty else { throw SyncV2StoreError.workNotFound }
        try stageRemote(remote); try verifyInbox(inboxID: remote.inboxID)
        let active = try query("SELECT conflict_id,current_revision FROM conflicts WHERE work_id=? AND state='active'", [.text(workID.description)]).first
        if let active,
           let existing = try query("SELECT base_snapshot_id,local_snapshot_id,remote_snapshot_id,remote_inbox_id,source_generation FROM conflict_candidates WHERE conflict_id=? AND revision=?", [.text(active[0].text ?? ""), .int(active[1].int64 ?? 0)]).first,
           existing[0].blob?.hexString == baseSnapshotID?.rawValue,
           existing[1].blob?.hexString == localSnapshotID.rawValue,
           existing[2].blob?.hexString == remote.encoded.snapshotId.rawValue,
           existing[3].text == remote.inboxID.uuidString.lowercased(),
           existing[4].int64 == sourceGeneration {
            return V2ConflictCandidate(conflictID: UUID(uuidString: active[0].text!)!, revision: active[1].int64!, workID: workID, baseSnapshotID: baseSnapshotID, localSnapshotID: localSnapshotID, remoteSnapshotID: remote.encoded.snapshotId, sourceGeneration: sourceGeneration)
        }
        let conflictID = active.flatMap { $0[0].text }.flatMap(UUID.init(uuidString:)) ?? UUID(); let revision = (active?[1].int64 ?? 0) + 1
        try exec("BEGIN IMMEDIATE")
        do {
            if active == nil {
                try exec("INSERT INTO conflicts(conflict_id,work_id,current_revision,source_generation,state) VALUES(?,?,?,?, 'active')", [.text(conflictID.uuidString.lowercased()), .text(workID.description), .int(revision), .int(sourceGeneration)])
            } else {
                try exec("UPDATE conflicts SET current_revision=?,source_generation=? WHERE conflict_id=? AND state='active'", [.int(revision), .int(sourceGeneration), .text(conflictID.uuidString.lowercased())])
            }
            try exec("INSERT INTO conflict_candidates(conflict_id,work_id,revision,base_snapshot_id,local_snapshot_id,remote_snapshot_id,remote_inbox_id,source_generation,pinned) VALUES(?,?,?,?,?,?,?,?,0)", [.text(conflictID.uuidString.lowercased()), .text(workID.description), .int(revision), baseSnapshotID.map { .blob($0.bytes) } ?? .null, .blob(localSnapshotID.bytes), .blob(remote.encoded.snapshotIDBytes), .text(remote.inboxID.uuidString.lowercased()), .int(sourceGeneration)])
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
        return V2ConflictCandidate(conflictID: conflictID, revision: revision, workID: workID, baseSnapshotID: baseSnapshotID, localSnapshotID: localSnapshotID, remoteSnapshotID: remote.encoded.snapshotId, sourceGeneration: sourceGeneration)
    }

    public func activeConflict(workID: WorkID) throws -> V2ConflictCandidate? {
        guard let b = binding, try !query("SELECT 1 FROM account_bindings WHERE work_id=? AND account_id=? AND account_fence=? AND server_instance_id=? AND state='bound'", [.text(workID.description), .text(b.accountID), .text(b.accountFence), .text(b.serverInstanceID)]).isEmpty else { throw SyncV2StoreError.workNotFound }
        guard let row = try query("SELECT c.conflict_id,c.current_revision,k.base_snapshot_id,k.local_snapshot_id,k.remote_snapshot_id,k.source_generation FROM conflicts c JOIN conflict_candidates k ON k.conflict_id=c.conflict_id AND k.revision=c.current_revision WHERE c.work_id=? AND c.state='active'", [.text(workID.description)]).first, let conflict = row[0].text, let revision = row[1].int64, let local = row[3].blob, let remote = row[4].blob, let generation = row[5].int64 else { return nil }
        return try V2ConflictCandidate(conflictID: UUID(uuidString: conflict)!, revision: revision, workID: workID, baseSnapshotID: row[2].blob.map { try SnapshotID(rawValue: $0.hexString) }, localSnapshotID: SnapshotID(rawValue: local.hexString), remoteSnapshotID: SnapshotID(rawValue: remote.hexString), sourceGeneration: generation)
    }

    public func historyCount(workID: WorkID) throws -> Int {
        guard let b = binding, try !query("SELECT 1 FROM account_bindings WHERE work_id=? AND account_id=? AND account_fence=? AND server_instance_id=? AND state='bound'", [.text(workID.description), .text(b.accountID), .text(b.accountFence), .text(b.serverInstanceID)]).isEmpty else { throw SyncV2StoreError.workNotFound }
        return try Int(query("SELECT COUNT(*) FROM history_occurrences WHERE work_id=?", [.text(workID.description)]).first?[0].int64 ?? 0)
    }
}

private extension LocalSyncV2Store {
    func scopedWorkRow(workID: WorkID) throws -> [SQLiteValue]? {
        if let b = binding {
            return try query("SELECT w.work_id,w.document_id,w.local_generation,w.current_snapshot_id,w.acknowledged_head_generation FROM works w JOIN account_bindings b ON b.work_id=w.work_id WHERE w.work_id=? AND b.account_id=? AND b.account_fence=? AND b.server_instance_id=? AND b.state='bound'", [.text(workID.description), .text(b.accountID), .text(b.accountFence), .text(b.serverInstanceID)]).first
        }
        return try query("SELECT w.work_id,w.document_id,w.local_generation,w.current_snapshot_id,w.acknowledged_head_generation FROM works w LEFT JOIN account_bindings b ON b.work_id=w.work_id WHERE w.work_id=? AND b.work_id IS NULL", [.text(workID.description)]).first
    }

    func workExists(workID: WorkID) throws -> Bool {
        try !query("SELECT 1 FROM works WHERE work_id=?", [.text(workID.description)]).isEmpty
    }

    func ensureRemoteWork(workID: WorkID, documentID: DocumentID, documentCreatedAt: Date) throws {
        guard let b = binding else { throw SyncV2StoreError.accountMismatch }
        if try workExists(workID: workID) {
            guard let row = try scopedWorkRow(workID: workID), row[1].text == documentID.description else { throw SyncV2StoreError.workNotFound }
            return
        }
        try exec("INSERT INTO works(work_id,document_id,document_created_at) VALUES(?,?,?)", [.text(workID.description), .text(documentID.description), .text(Self.iso8601(documentCreatedAt))])
        try exec("INSERT INTO account_bindings(work_id,server_instance_id,protocol_epoch,account_id,account_fence,state) VALUES(?,?,?,?,?,'bound')", [.text(workID.description), .text(b.serverInstanceID), .int(b.protocolEpoch), .text(b.accountID), .text(b.accountFence)])
    }

    static func bootstrapSchema(_ db: OpaquePointer) throws {
        let sql = try V2StoreSchema.resourceSQL()
        let expectedChecksum = V2StoreSchema.checksum(sql)
        var probe: OpaquePointer?
        let probeStatus = sqlite3_prepare_v2(db, "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='schema_meta'), EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name <> 'schema_meta')", -1, &probe, nil)
        guard probeStatus == SQLITE_OK else { throw probeStatus == SQLITE_NOTADB ? SyncV2StoreError.schemaMismatch : SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        defer {
            if let probe {
                sqlite3_finalize(probe)
            }
        }
        let probeResult = sqlite3_step(probe)
        let hasSchema = probeResult == SQLITE_ROW && sqlite3_column_int(probe, 0) != 0
        if probeResult == SQLITE_ROW, !hasSchema, sqlite3_column_int(probe, 1) != 0 {
            throw SyncV2StoreError.schemaMismatch
        }
        sqlite3_finalize(probe)
        probe = nil
        if !hasSchema {
            guard sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil) == SQLITE_OK else { throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
            guard sqlite3_exec(db, "PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;", nil, nil, nil) == SQLITE_OK else { throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
            let ddl = String(decoding: sql, as: UTF8.self).replacingOccurrences(of: "PRAGMA foreign_keys = ON;", with: "").replacingOccurrences(of: "PRAGMA journal_mode = WAL;", with: "").replacingOccurrences(of: "PRAGMA synchronous = FULL;", with: "")
            guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else { throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value,checksum FROM schema_meta WHERE key='schema'", -1, &statement, nil) == SQLITE_OK else { throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW {
            let version = String(cString: sqlite3_column_text(statement, 0)); let checksum = Data(bytes: sqlite3_column_blob(statement, 1), count: Int(sqlite3_column_bytes(statement, 1)))
            guard version == V2StoreSchema.version, checksum == expectedChecksum else { throw SyncV2StoreError.schemaMismatch }
        } else {
            var insert: OpaquePointer?; guard sqlite3_prepare_v2(db, "INSERT INTO schema_meta(key,value,checksum) VALUES('schema',?,?)", -1, &insert, nil) == SQLITE_OK else { throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }; defer { sqlite3_finalize(insert) }
            sqlite3_bind_text(insert, 1, V2StoreSchema.version, -1, sqliteTransient); _ = expectedChecksum.withUnsafeBytes { sqlite3_bind_blob(insert, 2, $0.baseAddress, Int32(expectedChecksum.count), sqliteTransient) }; guard sqlite3_step(insert) == SQLITE_DONE else { throw SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
        let requiredTables = ["schema_meta", "works", "account_bindings", "objects", "snapshots", "snapshot_parents", "snapshot_entries", "history_occurrences", "sync_intents", "sealed_commands", "remote_receipts", "inbox_batches", "inbox_objects", "inbox_closure", "conflicts", "conflict_candidates", "restore_records", "migration_ledger", "migration_staging_batches", "migration_staging_objects", "quarantine_records"]
        for table in requiredTables where !schemaObjectExists(db, name: table, type: "table") {
            throw SyncV2StoreError.schemaMismatch
        }
        guard schemaObjectExists(db, name: "one_active_conflict_per_work", type: "index"),
              try schemaSignature(db) == schemaSignature(for: sql) else { throw SyncV2StoreError.schemaMismatch }
    }

    static func schemaSignature(for sql: Data) throws -> Data {
        var memory: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &memory, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let memory else { throw SyncV2StoreError.schemaMismatch }
        defer { sqlite3_close(memory) }
        let ddl = String(decoding: sql, as: UTF8.self)
            .replacingOccurrences(of: "PRAGMA foreign_keys = ON;", with: "")
            .replacingOccurrences(of: "PRAGMA journal_mode = WAL;", with: "")
            .replacingOccurrences(of: "PRAGMA synchronous = FULL;", with: "")
        guard sqlite3_exec(memory, ddl, nil, nil, nil) == SQLITE_OK else { throw SyncV2StoreError.schemaMismatch }
        return try schemaSignature(memory)
    }

    static func schemaSignature(_ db: OpaquePointer) throws -> Data {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT type,name,tbl_name,COALESCE(sql,'') FROM sqlite_master WHERE type IN ('table','index') ORDER BY type,name", -1, &statement, nil) == SQLITE_OK else { throw SyncV2StoreError.schemaMismatch }
        defer { sqlite3_finalize(statement) }
        var bytes = Data()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            for index in 0 ..< 4 {
                let text = sqlite3_column_text(statement, Int32(index)).map { String(cString: $0) } ?? ""
                bytes.append(contentsOf: text.utf8); bytes.append(0)
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw SyncV2StoreError.schemaMismatch }
        return Data(hex: SHA256Digest.hex(bytes))
    }

    static func schemaObjectExists(_ db: OpaquePointer, name: String, type: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type=? AND name=?", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, type, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, name, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func insertEncoded(_ encoded: EncodedSnapshot, workID: WorkID) throws {
        for (id, bytes) in encoded.objects {
            if let existing = try query("SELECT byte_count,bytes FROM objects WHERE object_id=?", [.blob(id.bytes)]).first {
                guard existing[0].int64 == Int64(bytes.count), existing[1].blob == bytes else { throw SyncV2StoreError.invalidSnapshot }
            } else {
                try exec("INSERT INTO objects(object_id,byte_count,bytes) VALUES(?,?,?)", [.blob(id.bytes), .int(Int64(bytes.count)), .blob(bytes)])
            }
        }
        if let existing = try query("SELECT work_id,manifest_bytes,manifest_digest FROM snapshots WHERE snapshot_id=?", [.blob(encoded.snapshotIDBytes)]).first {
            guard existing[0].text == workID.description, existing[1].blob == encoded.manifestBytes, existing[2].blob == encoded.snapshotIDBytes else { throw SyncV2StoreError.invalidSnapshot }
        } else {
            try exec("INSERT INTO snapshots(snapshot_id,work_id,manifest_bytes,manifest_digest,created_at) VALUES(?,?,?,?,?)", [.blob(encoded.snapshotIDBytes), .text(workID.description), .blob(encoded.manifestBytes), .blob(encoded.snapshotIDBytes), .text(Self.now())])
        }
        for parent in encoded.manifest.parentSnapshotIds {
            if try query("SELECT 1 FROM snapshot_parents WHERE snapshot_id=? AND parent_snapshot_id=?", [.blob(encoded.snapshotIDBytes), .blob(parent.bytes)]).isEmpty {
                try exec("INSERT INTO snapshot_parents(work_id,snapshot_id,parent_snapshot_id) VALUES(?,?,?)", [.text(workID.description), .blob(encoded.snapshotIDBytes), .blob(parent.bytes)])
            }
        }
        for entry in encoded.manifest.entries {
            if let existing = try query("SELECT object_id,byte_count,content_type FROM snapshot_entries WHERE snapshot_id=? AND entity_key=?", [.blob(encoded.snapshotIDBytes), .text(entry.entityKey)]).first {
                guard existing[0].blob == entry.objectId.bytes, existing[1].int64 == Int64(entry.byteCount), existing[2].text == entry.contentType.rawValue else { throw SyncV2StoreError.invalidSnapshot }
            } else {
                try exec("INSERT INTO snapshot_entries(snapshot_id,entity_key,object_id,byte_count,content_type) VALUES(?,?,?,?,?)", [.blob(encoded.snapshotIDBytes), .text(entry.entityKey), .blob(entry.objectId.bytes), .int(Int64(entry.byteCount)), .text(entry.contentType.rawValue)])
            }
        }
        guard try query("SELECT COUNT(*) FROM snapshot_entries WHERE snapshot_id=?", [.blob(encoded.snapshotIDBytes)]).first?[0].int64 == Int64(encoded.manifest.entries.count),
              try query("SELECT COUNT(*) FROM snapshot_parents WHERE snapshot_id=?", [.blob(encoded.snapshotIDBytes)]).first?[0].int64 == Int64(encoded.manifest.parentSnapshotIds.count) else {
            throw SyncV2StoreError.invalidSnapshot
        }
    }

    func loadEncoded(workID: WorkID, snapshotID: SnapshotID) throws -> EncodedSnapshot {
        guard let row = try query("SELECT manifest_bytes FROM snapshots WHERE work_id=? AND snapshot_id=?", [.text(workID.description), .blob(snapshotID.bytes)]).first, let manifest = row[0].blob else { throw SyncV2StoreError.snapshotNotFound }
        let parsed = try SnapshotValidator.validate(manifestBytes: manifest); var objects: [ObjectID: Data] = [:]
        for entry in parsed.entries {
            guard let row = try query("SELECT bytes FROM objects WHERE object_id=?", [.blob(entry.objectId.bytes)]).first, let bytes = row[0].blob else { throw SyncV2StoreError.invalidSnapshot }; objects[entry.objectId] = bytes
        }
        return EncodedSnapshot(manifest: parsed, manifestBytes: manifest, objects: objects)
    }

    func loadInboxEncoded(inboxID: UUID, manifestBytes: Data, verifiedOnly: Bool = true) throws -> EncodedSnapshot {
        let parsed = try SnapshotValidator.validate(manifestBytes: manifestBytes); var objects: [ObjectID: Data] = [:]
        for entry in parsed.entries {
            let sql = verifiedOnly ? "SELECT bytes FROM inbox_objects WHERE inbox_id=? AND object_id=? AND verified=1" : "SELECT bytes FROM inbox_objects WHERE inbox_id=? AND object_id=?"
            guard let row = try query(sql, [.text(inboxID.uuidString.lowercased()), .blob(entry.objectId.bytes)]).first, let bytes = row[0].blob else { throw SyncV2StoreError.invalidSnapshot }; objects[entry.objectId] = bytes
        }
        let encoded = EncodedSnapshot(manifest: parsed, manifestBytes: manifestBytes, objects: objects); try SnapshotValidator.validateObjects(encoded); return encoded
    }

    static func summary(_ row: [SQLiteValue]) throws -> V2WorkSummary {
        guard let w = row[0].text, let d = row[1].text, let generation = row[2].int64 else { throw SyncV2StoreError.sqlite("work") }
        return try V2WorkSummary(workID: WorkID(uuidString: w), documentID: DocumentID(uuidString: d), localGeneration: generation, currentSnapshotID: row[3].blob.map { try SnapshotID(rawValue: $0.hexString) }, acknowledgedHeadGeneration: row[4].int64)
    }

    static func now() -> String {
        (try? iso8601(Date())) ?? "1970-01-01T00:00:00Z"
    }

    static func iso8601(_ date: Date) throws -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 0); f.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime, .withFractionalSeconds]; return f.string(from: date)
    }

    func changes() throws -> Int {
        Int(sqlite3_changes(db))
    }

    func exec(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        guard let db else { throw SyncV2StoreError.sqlite("closed") }; var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqliteError() }; defer { sqlite3_finalize(statement) }; try bind(statement, bindings); guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        guard let db else { throw SyncV2StoreError.sqlite("closed") }; var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqliteError() }; defer { sqlite3_finalize(statement) }; try bind(statement, bindings); var result: [[SQLiteValue]] = []; var rc = sqlite3_step(statement); while rc == SQLITE_ROW {
            result.append((0 ..< sqlite3_column_count(statement)).map { SQLiteValue(statement: statement!, index: Int32($0)) }); rc = sqlite3_step(statement)
        }; guard rc == SQLITE_DONE else { throw sqliteError() }; return result
    }

    func bind(_ statement: OpaquePointer?, _ values: [SQLiteValue]) throws {
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1); let result: Int32; switch value { case .null: result = sqlite3_bind_null(statement, i); case let .text(v): result = sqlite3_bind_text(statement, i, v, -1, sqliteTransient); case let .blob(v): result = v.withUnsafeBytes { sqlite3_bind_blob(statement, i, $0.baseAddress, Int32(v.count), sqliteTransient) }; case let .int(v): result = sqlite3_bind_int64(statement, i, v) }; guard result == SQLITE_OK else { throw sqliteError() }
        }
    }

    func sqliteError() -> SyncV2StoreError {
        SyncV2StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
    }
}

private enum SQLiteValue {
    case null, text(String), blob(Data), int(Int64)
    init(statement: OpaquePointer, index: Int32) {
        switch sqlite3_column_type(statement, index) { case SQLITE_NULL: self = .null; case SQLITE_INTEGER: self = .int(sqlite3_column_int64(statement, index)); case SQLITE_BLOB: self = .blob(Data(bytes: sqlite3_column_blob(statement, index), count: Int(sqlite3_column_bytes(statement, index)))); default: self = .text(String(cString: sqlite3_column_text(statement, index))) }
    }

    var text: String? {
        if case let .text(v) = self {
            return v
        }; return nil
    }

    var blob: Data? {
        if case let .blob(v) = self {
            return v
        }; return nil
    }

    var int64: Int64? {
        if case let .int(v) = self {
            return v
        }; return nil
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension ObjectID { var bytes: Data {
    Data(hex: rawValue)
} }
private extension SnapshotID { var bytes: Data {
    Data(hex: rawValue)
} }
private extension EncodedSnapshot { var snapshotIDBytes: Data {
    Data(hex: snapshotId.rawValue)
} }
private extension Data { init(hex: String) {
    self.init((0 ..< hex.count / 2).map { let start = String.Index(utf16Offset: $0 * 2, in: hex); let end = String.Index(utf16Offset: $0 * 2 + 2, in: hex); return UInt8(String(hex[start ..< end]), radix: 16)! })
} }
private extension SealedCommand {
    var requestDigestBytes: Data {
        Data(hex: requestDigest.rawValue)
    }

    var sourceSnapshotIdBytes: Data {
        Data(hex: sourceSnapshotId.rawValue)
    }

    var payloadWorkID: String? {
        guard let json = try? JSONSerialization.jsonObject(with: payloadBytes) as? [String: Any] else { return nil }
        return (json["workId"] as? String) ?? (json["sourceWorkId"] as? String)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
