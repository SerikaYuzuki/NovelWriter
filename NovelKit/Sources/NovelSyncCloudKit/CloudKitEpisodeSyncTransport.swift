import CloudKit
import Foundation
import NovelSync

/// Apple private CloudKit databaseへNovelSyncのportable transport contractを写像する。
/// CKRecord/change tag/asset/zoneはこのtargetから外へ出さない。
public actor CloudKitEpisodeSyncTransport: EpisodeSyncTransport, SyncWorkCatalog, WorkSyncTransport {
    enum ZoneLifecycle {
        case unknown
        case ready
        case blocked(CloudKitSyncAdapterError)
    }

    let container: CKContainer
    let database: CKDatabase
    let codec: CloudKitRecordCodec
    let planner: CloudKitPublishPlanner
    let workPlanner: CloudKitWorkPublishPlanner
    let changeDriver: CloudKitChangeTrackingDriver
    var zoneLifecycle = ZoneLifecycle.unknown

    public init(
        containerIdentifier: String,
        assetRootURL: URL,
        restoredEngineState: Data? = nil,
        stateSerializationHandler: CloudKitChangeTrackingDriver.StateSerializationHandler? = nil,
        signalHandler: CloudKitChangeTrackingDriver.SignalHandler? = nil
    ) throws {
        guard containerIdentifier.hasPrefix("iCloud."),
              containerIdentifier.utf8.count <= 255 else {
            throw CloudKitSyncAdapterError.invalidConfiguration
        }
        let container = CKContainer(identifier: containerIdentifier)
        let database = container.privateCloudDatabase
        let assetStore = try CloudKitAssetStore(rootURL: assetRootURL)
        let codec = CloudKitRecordCodec(assetStore: assetStore)
        self.container = container
        self.database = database
        self.codec = codec
        planner = CloudKitPublishPlanner(codec: codec)
        workPlanner = CloudKitWorkPublishPlanner(codec: codec)
        changeDriver = try CloudKitChangeTrackingDriver(
            database: database,
            restoredState: restoredEngineState,
            stateSerializationHandler: stateSerializationHandler,
            signalHandler: signalHandler
        )
    }

    public func verifyAccountAvailability() async throws {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            throw mappedOperationError(error)
        }
        switch status {
        case .available:
            return
        case .noAccount:
            throw CloudKitSyncAdapterError.accountUnavailable(.noAccount)
        case .restricted:
            throw CloudKitSyncAdapterError.accountUnavailable(.restricted)
        case .couldNotDetermine:
            throw CloudKitSyncAdapterError.accountUnavailable(.couldNotDetermine)
        case .temporarilyUnavailable:
            throw CloudKitSyncAdapterError.accountUnavailable(.temporarilyUnavailable)
        @unknown default:
            throw CloudKitSyncAdapterError.accountUnavailable(.couldNotDetermine)
        }
    }

    /// push、起動、foreground復帰時のcontent-free wakeup。fetch後もCAS判断はtransportが行う。
    public func refreshTrackedChanges() async throws {
        do {
            try await changeDriver.fetchChanges()
        } catch {
            throw mappedOperationError(error)
        }
    }

    public func cancelTrackedChanges() async {
        await changeDriver.cancel()
    }

    /// 新しいsync graphを作ると利用者が明示した時だけ呼ぶ。通常fetch/publishは
    /// missing/deleted zoneを自動再作成せずblockedにする。
    public func bootstrapZoneForNewSync() async throws {
        if case .ready = zoneLifecycle {
            return
        }
        do {
            _ = try await database.recordZone(for: CloudKitSyncSchema.zoneID)
            zoneLifecycle = .ready
            return
        } catch {
            guard CloudKitErrorMapper.isUnknownItem(error)
                || CloudKitErrorMapper.isZoneMissing(error)
                || CloudKitErrorMapper.isZoneReset(error) else {
                throw mappedOperationError(error)
            }
        }

        let zone = CKRecordZone(zoneID: CloudKitSyncSchema.zoneID)
        do {
            _ = try await database.save(zone)
            zoneLifecycle = .ready
        } catch {
            if CloudKitErrorMapper.containsServerRecordChanged(error) {
                _ = try await database.recordZone(for: CloudKitSyncSchema.zoneID)
                zoneLifecycle = .ready
            } else {
                throw mappedOperationError(error)
            }
        }
    }

    public func fetchSnapshot(for key: EpisodeSyncKey) async throws -> EpisodeRemoteSnapshot {
        try await ensureZone()
        try await requireWorkExists(key.workID)
        let control = try await fetchControl(for: key)
        return try await materializeSnapshot(control)
    }

    public func fetchRevision(
        _ id: SyncRevisionID,
        for key: EpisodeSyncKey
    ) async throws -> EpisodeRevision {
        try await ensureZone()
        try await requireWorkExists(key.workID)
        let recordID = CKRecord.ID.episodeRevision(id, key: key)
        guard let record = try await fetchRecordIfPresent(recordID) else {
            throw EpisodeSyncTransportError.missingRevision
        }
        return try codec.decodeRevisionRecord(record, expectedKey: key, expectedRevisionID: id)
    }

    func ensureZone() async throws {
        switch zoneLifecycle {
        case .ready:
            return
        case let .blocked(error):
            throw error
        case .unknown:
            break
        }
        do {
            _ = try await database.recordZone(for: CloudKitSyncSchema.zoneID)
            zoneLifecycle = .ready
        } catch {
            if CloudKitErrorMapper.isZoneReset(error) {
                zoneLifecycle = .blocked(.zoneReset)
                throw CloudKitSyncAdapterError.zoneReset
            }
            if CloudKitErrorMapper.isUnknownItem(error) || CloudKitErrorMapper.isZoneMissing(error) {
                zoneLifecycle = .blocked(.zoneUnavailable)
                throw CloudKitSyncAdapterError.zoneUnavailable
            }
            // account/networkの一時失敗ではactorを永久にblockedにしない。
            // 次の明示操作でzone存在確認から安全に再試行する。
            throw mappedOperationError(error)
        }
    }

    func fetchControl(for key: EpisodeSyncKey) async throws -> CloudKitEpisodeControl {
        let recordID = CKRecord.ID.episodeControl(key)
        guard let record = try await fetchRecordIfPresent(recordID) else {
            return CloudKitEpisodeControl(
                record: nil,
                key: key,
                headRevisionID: nil,
                leaseEpoch: 0,
                lease: nil
            )
        }
        return try codec.decodeControlRecord(record, expectedKey: key)
    }

    func materializeSnapshot(_ control: CloudKitEpisodeControl) async throws -> EpisodeRemoteSnapshot {
        let head: EpisodeRevision? = if let headID = control.headRevisionID {
            try await fetchRevision(headID, for: control.key)
        } else {
            nil
        }
        return try EpisodeRemoteSnapshot(
            head: head,
            leaseEpoch: control.leaseEpoch,
            lease: control.lease
        )
    }

    func acknowledgement(from receipt: CloudKitMutationReceipt) async throws -> EpisodePublishResult {
        let committedHead = try await fetchRevision(receipt.resultHeadRevisionID, for: receipt.key)
        // receipt当時のlease/headをcurrentとして返さない。response loss後にforce/publishが
        // 進んでいても、最新controlを最後にfetchしてfencing判断をdomainへ渡す。
        let current = try await fetchSnapshot(for: receipt.key)
        return try CloudKitReceiptResolver.resolve(
            receipt: receipt,
            committedHead: committedHead,
            current: current
        )
    }

    func fetchMutationReceipt(
        _ mutationID: SyncMutationID,
        key: EpisodeSyncKey
    ) async throws -> CloudKitMutationReceipt? {
        let recordID = CKRecord.ID.mutationReceipt(mutationID, key: key)
        guard let record = try await fetchRecordIfPresent(recordID) else { return nil }
        return try codec.decodeMutationReceipt(
            record,
            expectedKey: key,
            expectedMutationID: mutationID
        )
    }

    func fetchRecordIfPresent(_ recordID: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await database.record(for: recordID)
        } catch {
            if CloudKitErrorMapper.isUnknownItem(error) {
                return nil
            }
            throw mappedOperationError(error)
        }
    }

    func reconcilePublishAfterConflict(
        _ request: EpisodePublishRequest,
        commandDigest: SyncContentDigest
    ) async throws -> EpisodePublishResult {
        if let receipt = try await fetchMutationReceipt(request.mutationID, key: request.key) {
            guard receipt.commandDigest == commandDigest else {
                throw EpisodeSyncTransportError.mutationReuse
            }
            return try await acknowledgement(from: receipt)
        }
        let current = try await fetchSnapshot(for: request.key)
        if current.lease?.authority != request.expectedLeaseAuthority {
            return .staleLease(current)
        }
        if current.head?.revisionID != request.expectedHeadRevisionID {
            return .diverged(current)
        }
        throw EpisodeSyncTransportError.revisionCollision
    }

    func incrementedEpoch(_ current: UInt64) throws -> UInt64 {
        guard current < EpisodeLeaseAuthority.maximumEpoch else {
            throw EpisodeSyncTransportError.leaseEpochOverflow
        }
        return current + 1
    }

    func mappedOperationError(_ error: any Error) -> any Error {
        if error is EpisodeSyncTransportError || error is SyncCatalogError {
            return error
        }
        if let adapterError = error as? CloudKitSyncAdapterError {
            if adapterError.isTransientTransportFailure {
                return EpisodeSyncTransportError.unavailable
            }
            if adapterError == .zoneUnavailable || adapterError == .zoneReset {
                zoneLifecycle = .blocked(adapterError)
            }
            return adapterError
        }
        if CloudKitErrorMapper.isTransient(error) {
            return EpisodeSyncTransportError.unavailable
        }
        let mapped: CloudKitSyncAdapterError = if CloudKitErrorMapper.isZoneReset(error) {
            .zoneReset
        } else if CloudKitErrorMapper.isZoneMissing(error) {
            .zoneUnavailable
        } else {
            CloudKitErrorMapper.map(error)
        }
        if mapped == .zoneUnavailable || mapped == .zoneReset {
            zoneLifecycle = .blocked(mapped)
        }
        return mapped
    }
}
