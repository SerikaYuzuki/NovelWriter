import Foundation
import NovelSync

public struct RemoteSnapshotInstallRequest: Sendable {
    public struct Identity: Sendable {
        public let workID: UUID
        public let documentID: UUID
        public let documentCreatedAt: String

        public init(workID: UUID, documentID: UUID, documentCreatedAt: String) {
            self.workID = workID
            self.documentID = documentID
            self.documentCreatedAt = documentCreatedAt
        }
    }

    public struct Payload: Sendable {
        public let snapshotID: String
        public let parentSnapshotIDs: [String]
        public let manifest: Data
        public let objects: [LocalObject]

        public init(
            snapshotID: String,
            parentSnapshotIDs: [String],
            manifest: Data,
            objects: [LocalObject]
        ) {
            self.snapshotID = snapshotID
            self.parentSnapshotIDs = parentSnapshotIDs
            self.manifest = manifest
            self.objects = objects
        }
    }

    public struct Expectations: Sendable {
        public let remoteGeneration: UInt64
        public let expectedLocalSnapshotID: String?
        public let expectedLocalGeneration: UInt64?

        public init(
            remoteGeneration: UInt64,
            expectedLocalSnapshotID: String?,
            expectedLocalGeneration: UInt64?
        ) {
            self.remoteGeneration = remoteGeneration
            self.expectedLocalSnapshotID = expectedLocalSnapshotID
            self.expectedLocalGeneration = expectedLocalGeneration
        }
    }

    public let identity: Identity
    public let payload: Payload
    public let expectations: Expectations
    public let now: Date

    public init(
        identity: Identity,
        payload: Payload,
        expectations: Expectations,
        now: Date = Date()
    ) {
        self.identity = identity
        self.payload = payload
        self.expectations = expectations
        self.now = now
    }
}

extension LocalSQLiteStore {
    /// Installs an exact remote snapshot without creating a new outbound
    /// intent. The caller must first materialize and save the document, then
    /// pass the local generation/snapshot it observed so a concurrent edit
    /// fails closed instead of being overwritten.
    @discardableResult
    public func installRemoteSnapshot(
        _ request: RemoteSnapshotInstallRequest
    ) throws -> LocalSnapshotRecord {
        let identity = request.identity
        let payload = request.payload
        let expectations = request.expectations
        let workID = identity.workID
        let documentID = identity.documentID
        let documentCreatedAt = identity.documentCreatedAt
        let snapshotID = payload.snapshotID
        let parentSnapshotIDs = payload.parentSnapshotIDs
        let manifest = payload.manifest
        let objects = payload.objects
        let expectedLocalSnapshotID = expectations.expectedLocalSnapshotID
        let expectedLocalGeneration = expectations.expectedLocalGeneration
        let now = request.now
        guard !manifest.isEmpty, snapshotID.count == 64, !documentCreatedAt.isEmpty else {
            throw LocalStoreError.invalidSnapshot
        }
        guard let database else { throw LocalStoreError.statementFailed("database closed") }
        let existingWork = try queryWork(database, workID: workID)
        if let expectedLocalGeneration,
           existingWork?.localGeneration != expectedLocalGeneration {
            throw LocalStoreError.statementFailed("local snapshot changed")
        }
        if let expectedLocalSnapshotID,
           existingWork?.currentLocalSnapshotID != expectedLocalSnapshotID {
            throw LocalStoreError.statementFailed("local snapshot changed")
        }
        try exec(database, "BEGIN IMMEDIATE")
        do {
            // A remote-only work has no local `works` row yet. Create the
            // placeholder before inserting its snapshot because snapshots
            // reference works with a foreign key. The transaction below
            // still publishes the final acknowledged head atomically.
            if existingWork == nil {
                try exec(
                    database,
                    """
                    INSERT INTO works(
                        work_id, document_id, document_created_at,
                        current_local_snapshot_id, acknowledged_head_snapshot_id,
                        acknowledged_head_generation, local_generation
                    ) VALUES (?, ?, ?, NULL, NULL, NULL, 0)
                    """
                ) { statement in
                    try Self.bindText(statement, index: 1, value: workID.uuidString.lowercased())
                    try Self.bindText(statement, index: 2, value: documentID.uuidString.lowercased())
                    try Self.bindText(statement, index: 3, value: documentCreatedAt)
                }
            }
            if let existing = try querySnapshot(database, snapshotID: snapshotID) {
                guard existing.workID == workID else {
                    throw LocalStoreError.invalidSnapshot
                }
                if existing.manifest != manifest {
                    // A previous server version returned JSONB manifests in
                    // a different member order. Recover only that known
                    // cache-corruption case: the incoming bytes must hash to
                    // the immutable snapshot ID while the stored bytes must
                    // not. Any two valid-but-different payloads still fail
                    // closed.
                    guard Self.matchesDigest(manifest, snapshotID: snapshotID),
                          !Self.matchesDigest(existing.manifest, snapshotID: snapshotID) else {
                        throw LocalStoreError.invalidSnapshot
                    }
                    for object in objects {
                        try upsertObject(database, object: object)
                    }
                    try replaceSnapshotPayload(
                        database,
                        snapshotID: snapshotID,
                        parentSnapshotIDs: parentSnapshotIDs,
                        manifest: manifest
                    )
                }
            } else {
                for object in objects {
                    try upsertObject(database, object: object)
                }
                let generation = (existingWork?.localGeneration ?? 0) + 1
                try insertSnapshot(
                    database,
                    snapshotID: snapshotID,
                    workID: workID,
                    parents: parentSnapshotIDs,
                    manifest: manifest,
                    reason: .autosave,
                    generation: generation,
                    pin: false,
                    createdAt: Self.timestamp(now)
                )
            }
            let generation = (existingWork?.localGeneration ?? 0) + 1
            try updateWorkAfterRemoteInstall(database, request: request, generation: generation)
            try exec(database, "COMMIT")
            guard let record = try querySnapshot(database, snapshotID: snapshotID) else {
                throw LocalStoreError.missingSnapshot
            }
            return record
        } catch {
            _ = try? exec(database, "ROLLBACK")
            throw error
        }
    }

    private func updateWorkAfterRemoteInstall(
        _ database: OpaquePointer,
        request: RemoteSnapshotInstallRequest,
        generation: UInt64
    ) throws {
        let workID = request.identity.workID
        let documentID = request.identity.documentID
        let documentCreatedAt = request.identity.documentCreatedAt
        let snapshotID = request.payload.snapshotID
        let remoteGeneration = request.expectations.remoteGeneration
        try exec(
            database,
            """
            INSERT INTO works(
                work_id, document_id, document_created_at,
                current_local_snapshot_id, acknowledged_head_snapshot_id,
                acknowledged_head_generation, local_generation
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(work_id) DO UPDATE SET
                document_id = excluded.document_id,
                document_created_at = excluded.document_created_at,
                current_local_snapshot_id = excluded.current_local_snapshot_id,
                acknowledged_head_snapshot_id = excluded.acknowledged_head_snapshot_id,
                acknowledged_head_generation = excluded.acknowledged_head_generation,
                local_generation = excluded.local_generation
            """
        ) { statement in
            try Self.bindText(statement, index: 1, value: workID.uuidString.lowercased())
            try Self.bindText(statement, index: 2, value: documentID.uuidString.lowercased())
            try Self.bindText(statement, index: 3, value: documentCreatedAt)
            try Self.bindText(statement, index: 4, value: snapshotID)
            try Self.bindText(statement, index: 5, value: snapshotID)
            try Self.bindInt64(statement, index: 6, value: Int64(remoteGeneration))
            try Self.bindInt64(statement, index: 7, value: Int64(generation))
        }
        if let expectedLocalSnapshotID = request.expectations.expectedLocalSnapshotID {
            try exec(
                database,
                """
                UPDATE sync_intents
                SET status = 'acknowledged'
                WHERE work_id = ? AND local_snapshot_id = ?
                  AND status IN ('pending', 'sealed')
                """
            ) { statement in
                try Self.bindText(statement, index: 1, value: workID.uuidString.lowercased())
                try Self.bindText(statement, index: 2, value: expectedLocalSnapshotID)
            }
        }
    }

    private func replaceSnapshotPayload(
        _ database: OpaquePointer,
        snapshotID: String,
        parentSnapshotIDs: [String],
        manifest: Data
    ) throws {
        let parentsData = try JSONEncoder().encode(parentSnapshotIDs)
        try Self.exec(
            database,
            "UPDATE snapshots SET parent_snapshot_ids = ?, manifest = ? WHERE snapshot_id = ?"
        ) { statement in
            try Self.bindText(statement, index: 1, value: String(decoding: parentsData, as: UTF8.self))
            try Self.bindData(statement, index: 2, value: manifest)
            try Self.bindText(statement, index: 3, value: snapshotID)
        }
    }

    private static func matchesDigest(_ data: Data, snapshotID: String) -> Bool {
        guard String(data: data, encoding: .utf8) != nil,
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return SyncContentDigest(content: text).rawValue == snapshotID
    }
}
