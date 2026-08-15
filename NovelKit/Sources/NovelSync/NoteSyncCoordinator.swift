import Foundation
import NovelCore

public struct NoteSyncSendResult: Equatable, Sendable {
    public var acceptedSaves: [NoteSyncRecord]
    public var acceptedDeletes: [NoteSyncEntityKey]
    public var conflictedKeys: Set<NoteSyncEntityKey>
    public var conflictedRemoteRecords: [NoteSyncRecord]

    public init(
        acceptedSaves: [NoteSyncRecord] = [],
        acceptedDeletes: [NoteSyncEntityKey] = [],
        conflictedKeys: Set<NoteSyncEntityKey> = [],
        conflictedRemoteRecords: [NoteSyncRecord] = []
    ) {
        self.acceptedSaves = acceptedSaves
        self.acceptedDeletes = acceptedDeletes
        self.conflictedKeys = conflictedKeys
        self.conflictedRemoteRecords = conflictedRemoteRecords
    }

    public var hasConflicts: Bool {
        !conflictedKeys.isEmpty
    }
}

/// CloudKit等の具象型を出さない、entity recordの送受信境界。
public protocol NoteSyncCloudStore: Sendable {
    func save(
        _ records: [NoteSyncRecord],
        expectedDigests: [NoteSyncEntityKey: SyncContentDigest],
        forceOverwrite: Set<NoteSyncEntityKey>
    ) async throws -> NoteSyncSendResult

    func delete(
        _ keys: [NoteSyncEntityKey],
        expectedDigests: [NoteSyncEntityKey: SyncContentDigest],
        forceOverwrite: Set<NoteSyncEntityKey>
    ) async throws -> NoteSyncSendResult

    func fetchAll(for workID: SyncWorkID) async throws -> [NoteSyncRecord]

    func listWorkRecords() async throws -> [NoteSyncRecord]
}

public actor NoteSyncCoordinator {
    public let workID: SyncWorkID
    private let session: NoteSyncSession
    private let cloud: any NoteSyncCloudStore

    public init(workID: SyncWorkID, store: any NoteSyncStateStore, cloud: any NoteSyncCloudStore) {
        self.workID = workID
        session = NoteSyncSession(workID: workID, store: store)
        self.cloud = cloud
    }

    public func state() async throws -> NoteSyncState {
        try await session.state()
    }

    public func recordPackageSave(_ snapshot: WorkSnapshot) async throws -> NoteSyncDirtySet {
        try await session.recordLocalSnapshot(snapshot)
    }

    public func publishLocal(_ snapshot: WorkSnapshot) async throws -> NoteSyncSendResult {
        let dirty = try await session.recordLocalSnapshot(snapshot)
        let records = try NoteSyncProjection.records(workID: workID, snapshot: snapshot)
        let state = try await session.state()
        let expectedGenerations = try await session.dirtyGenerations(
            for: dirty.saves.union(dirty.deletes)
        )
        let saves = records.filter { dirty.saves.contains($0.key) }
        var result = try await cloud.save(
            saves,
            expectedDigests: state.lastAckedDigests,
            forceOverwrite: state.forceSendKeys
        )
        if !dirty.deletes.isEmpty {
            let deleted = try await cloud.delete(
                Array(dirty.deletes),
                expectedDigests: state.lastAckedDigests,
                forceOverwrite: state.forceSendKeys
            )
            result.acceptedDeletes.append(contentsOf: deleted.acceptedDeletes)
            result.conflictedKeys.formUnion(deleted.conflictedKeys)
            result.conflictedRemoteRecords.append(contentsOf: deleted.conflictedRemoteRecords)
        }
        try await session.acknowledge(
            sent: result.acceptedSaves,
            deletedKeys: result.acceptedDeletes,
            expectedGenerations: expectedGenerations
        )
        if result.hasConflicts {
            let delta = NoteSyncRemoteDelta(
                upserts: result.conflictedRemoteRecords,
                deletedKeys: result.conflictedKeys.filter { key in
                    !result.conflictedRemoteRecords.contains { $0.key == key }
                }
            )
            let recon = try await session.reconcile(local: snapshot, remote: delta)
            if recon.conflict == nil {
                result = try await acknowledgeIdenticalCloudConflicts(
                    result,
                    localRecords: records
                )
            }
        }
        return result
    }

    private func acknowledgeIdenticalCloudConflicts(
        _ result: NoteSyncSendResult,
        localRecords: [NoteSyncRecord]
    ) async throws -> NoteSyncSendResult {
        let localByKey = Dictionary(uniqueKeysWithValues: localRecords.map { ($0.key, $0) })
        let identical = result.conflictedRemoteRecords.filter { remote in
            localByKey[remote.key]?.digest == remote.digest
        }
        guard !identical.isEmpty else { return result }
        let generations = try await session.dirtyGenerations(for: Set(identical.map(\.key)))
        try await session.acknowledge(applied: identical, expectedGenerations: generations)
        let identicalKeys = Set(identical.map(\.key))
        var cleared = result
        cleared.acceptedSaves.append(contentsOf: identical)
        cleared.conflictedKeys.subtract(identicalKeys)
        cleared.conflictedRemoteRecords.removeAll { identicalKeys.contains($0.key) }
        return cleared
    }

    public func pullRemote(onto local: WorkSnapshot) async throws -> NoteSyncReconcileResult {
        let remoteRecords = try await cloud.fetchAll(for: workID)
        // An empty or work-less fetch is incomplete, not "delete the whole work".
        guard remoteRecords.contains(where: { $0.key.kind == .work }) else {
            return try await session.reconcile(local: local, remote: .none)
        }
        let state = try await session.state()
        let ackedKeys = Set(state.lastAckedDigests.keys)
        let remoteKeys = Set(remoteRecords.map(\.key))
        let delta = NoteSyncRemoteDelta(
            upserts: remoteRecords,
            deletedKeys: ackedKeys.subtracting(remoteKeys).sorted()
        )
        return try await session.reconcile(local: local, remote: delta)
    }

    public func acknowledgeReconcile(_ result: NoteSyncReconcileResult) async throws {
        guard result.conflict == nil else {
            let keys = Set(result.recordsToSend.map(\.key)).union(result.keysToDelete)
            let generations = try await session.dirtyGenerations(for: keys)
            try await session.acknowledge(
                sent: result.recordsToSend,
                deletedKeys: result.keysToDelete,
                expectedGenerations: generations
            )
            return
        }
        let state = try await session.state()
        let localDirtyKeys = state.dirty.saves.union(state.dirty.deletes)
        let applied = try NoteSyncProjection.records(
            workID: workID,
            snapshot: result.appliedSnapshot
        ).filter { !localDirtyKeys.contains($0.key) }
        let appliedDeletedKeys = result.appliedDeletedKeys.filter {
            !localDirtyKeys.contains($0)
        }
        // Only locally-produced sends/deletes need generation guards. Remote
        // records are safe to acknowledge here because local dirty keys were
        // filtered above; otherwise a stale pull could acknowledge a newer
        // local edit that was not actually uploaded.
        let keys = Set(result.recordsToSend.map(\.key)).union(result.keysToDelete)
        let generations = try await session.dirtyGenerations(for: keys)
        try await session.acknowledge(
            sent: result.recordsToSend,
            deletedKeys: result.keysToDelete + appliedDeletedKeys,
            applied: applied,
            expectedGenerations: generations
        )
    }

    public func acknowledgeApplied(
        _ records: [NoteSyncRecord],
        deletedKeys: [NoteSyncEntityKey] = []
    ) async throws {
        let keys = Set(records.map(\.key)).union(deletedKeys)
        let generations = try await session.dirtyGenerations(for: keys)
        try await session.acknowledge(
            deletedKeys: deletedKeys,
            applied: records,
            expectedGenerations: generations
        )
    }

    public func resolve(
        _ choice: NoteSyncConflictChoice,
        local: WorkSnapshot,
        newWorkID: SyncWorkID,
        expectedKeys: Set<NoteSyncEntityKey> = []
    ) async throws -> NoteSyncResolution {
        let state = try await session.state()
        let remoteRecords = try await cloud.fetchAll(for: workID)
        let remoteKeys = Set(remoteRecords.map(\.key))
        let remoteDeletes = Set(state.lastAckedDigests.keys).subtracting(remoteKeys).sorted()
        let resolution = try await session.resolve(
            choice,
            local: local,
            remote: NoteSyncRemoteDelta(upserts: remoteRecords, deletedKeys: remoteDeletes),
            newWorkID: newWorkID,
            expectedKeys: expectedKeys
        )
        if choice == .keepLocal {
            let saved = try await cloud.save(
                resolution.currentSend,
                expectedDigests: [:],
                forceOverwrite: resolution.currentForceSendKeys
            )
            let deleted = try await cloud.delete(
                resolution.currentDeletes,
                expectedDigests: [:],
                forceOverwrite: resolution.currentForceSendKeys
            )
            guard !saved.hasConflicts,
                  !deleted.hasConflicts,
                  Set(saved.acceptedSaves.map(\.key)) == Set(resolution.currentSend.map(\.key)),
                  Set(deleted.acceptedDeletes) == Set(resolution.currentDeletes) else {
                throw NoteSyncReconcileError.remoteWriteConflict
            }
            try await session.commitResolution(resolution)
        }
        return resolution
    }

    /// Commits the state half only after the app has installed and read back
    /// the selected package/fork.
    public func commitResolution(_ resolution: NoteSyncResolution) async throws {
        try await session.commitResolution(resolution)
    }

    public func installFromRemote() async throws -> WorkSnapshot {
        let records = try await cloud.fetchAll(for: workID)
        return try await session.installFromRemote(records)
    }
}

public extension SyncWorkDescriptor {
    init(noteWork record: NoteSyncRecord) throws {
        guard record.key.kind == .work, case let .work(payload) = record.payload else {
            throw SyncWorkLibraryError.workMismatch
        }
        let chapters = payload.chapterOrder.map { id in
            Chapter(id: ChapterID(rawValue: id.rawValue), title: "", episodes: [])
        }
        try self.init(
            workID: record.key.workID,
            sourceDocumentID: payload.documentID.rawValue,
            structureDigest: SyncWorkStructureDigest(chapters: chapters),
            title: payload.title
        )
    }
}

public extension SyncWorkLibraryEntry {
    init(noteWork record: NoteSyncRecord) throws {
        guard record.key.kind == .work, case let .work(payload) = record.payload else {
            throw SyncWorkLibraryError.workMismatch
        }
        let chapters = payload.chapterOrder.map { id in
            Chapter(id: ChapterID(rawValue: id.rawValue), title: "", episodes: [])
        }
        try self.init(
            workID: record.key.workID,
            sourceDocumentID: payload.documentID.rawValue,
            structureDigest: SyncWorkStructureDigest(chapters: chapters),
            title: Self.displayTitleProjection(payload.title),
            titleDigest: SyncContentDigest(content: payload.title),
            fullTitleUTF8ByteCount: payload.title.utf8.count,
            headRevisionID: nil,
            headSnapshotDigest: nil,
            headSnapshotByteCount: nil,
            headClientCreatedAt: nil
        )
    }
}
