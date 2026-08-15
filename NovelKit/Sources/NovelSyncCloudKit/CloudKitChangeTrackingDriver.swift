import CloudKit
import Foundation

public enum CloudKitAccountChangeKind: Equatable, Sendable {
    case signIn
    case signOut
    case switchAccounts
}

public enum CloudKitSyncSignal: Equatable, Sendable {
    case remoteChangesAvailable
    case accountChanged(CloudKitAccountChangeKind)
    case zoneReset
    case stateSerializationFailed
}

/// CKSyncEngineはNote entityのpending save／deleteとfetch、change token、
/// state serializationを担当する。D-059／D-061のEpisode／Work CAS recordは
/// このpending queueへ載せない。
public final class CloudKitChangeTrackingDriver: @unchecked Sendable {
    public typealias StateSerializationHandler = @Sendable (Data) async -> Void
    public typealias SignalHandler = @Sendable (CloudKitSyncSignal) async -> Void

    static let automaticallyFetchesPushChanges = true
    static let sendsPendingRecordChanges = true

    private let engine: CKSyncEngine
    private let delegate: CloudKitChangeTrackingDelegate
    let pendingMailbox: CloudKitNotePendingMailbox

    init(
        database: CKDatabase,
        restoredState: Data?,
        stateSerializationHandler: StateSerializationHandler?,
        signalHandler: SignalHandler?,
        pendingMailbox: CloudKitNotePendingMailbox = CloudKitNotePendingMailbox()
    ) throws {
        let serialization = try Self.decodeRestoredState(restoredState)
        let delegate = CloudKitChangeTrackingDelegate(
            stateSerializationHandler: stateSerializationHandler,
            signalHandler: signalHandler,
            pendingMailbox: pendingMailbox
        )
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: serialization,
            delegate: delegate
        )
        configuration.automaticallySync = Self.automaticallyFetchesPushChanges
        configuration.subscriptionID = CloudKitSyncSchema.subscriptionID
        self.delegate = delegate
        self.pendingMailbox = pendingMailbox
        engine = CKSyncEngine(configuration)
    }

    static func decodeRestoredState(
        _ restoredState: Data?
    ) throws -> CKSyncEngine.State.Serialization? {
        guard let restoredState else { return nil }
        do {
            return try JSONDecoder().decode(
                CKSyncEngine.State.Serialization.self,
                from: restoredState
            )
        } catch {
            throw CloudKitSyncAdapterError.invalidRestoredEngineState
        }
    }

    func enqueueNoteSaves(_ records: [CKRecord]) {
        let ordered = CloudKitNotePendingQueue.orderedSaveRecords(records)
        pendingMailbox.store(ordered)
        engine.state.add(pendingRecordZoneChanges: ordered.map { .saveRecord($0.recordID) })
    }

    func enqueueNoteDeletes(_ recordIDs: [CKRecord.ID]) {
        pendingMailbox.remove(ids: recordIDs)
        engine.state.add(pendingRecordZoneChanges: recordIDs.map { .deleteRecord($0) })
    }

    func sendPendingChanges() async throws {
        pendingMailbox.beginSend()
        let options = CKSyncEngine.SendChangesOptions(
            scope: .zoneIDs([CloudKitSyncSchema.zoneID])
        )
        do {
            try await engine.sendChanges(options)
        } catch {
            CloudKitSyncDiagnostic.log("cloudkit sendPendingChanges failed", error: error)
            throw CloudKitErrorMapper.map(error)
        }
    }

    func takeNoteSendOutcome() -> CloudKitNoteSendOutcome {
        pendingMailbox.takeSendOutcome()
    }

    public func fetchChanges() async throws {
        var options = CKSyncEngine.FetchChangesOptions(
            scope: .zoneIDs([CloudKitSyncSchema.zoneID])
        )
        options.prioritizedZoneIDs = [CloudKitSyncSchema.zoneID]
        do {
            try await engine.fetchChanges(options)
        } catch {
            let mapped = CloudKitErrorMapper.map(error)
            if CloudKitErrorMapper.isTransient(error) {
                throw mapped
            }
            throw mapped
        }
    }

    public func cancel() async {
        await engine.cancelOperations()
    }
}

private final class CloudKitChangeTrackingDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    private let stateSerializationHandler: CloudKitChangeTrackingDriver.StateSerializationHandler?
    private let signalHandler: CloudKitChangeTrackingDriver.SignalHandler?
    private let pendingMailbox: CloudKitNotePendingMailbox

    init(
        stateSerializationHandler: CloudKitChangeTrackingDriver.StateSerializationHandler?,
        signalHandler: CloudKitChangeTrackingDriver.SignalHandler?,
        pendingMailbox: CloudKitNotePendingMailbox
    ) {
        self.stateSerializationHandler = stateSerializationHandler
        self.signalHandler = signalHandler
        self.pendingMailbox = pendingMailbox
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(update):
            guard let stateSerializationHandler else { return }
            do {
                let data = try JSONEncoder().encode(update.stateSerialization)
                await stateSerializationHandler(data)
            } catch {
                await signalHandler?(.stateSerializationFailed)
            }
        case let .accountChange(change):
            let kind = Self.accountChangeKind(change)
            pendingMailbox.clearObservedNoteWorkIDs()
            async let cancellation: Void = syncEngine.cancelOperations()
            await signalHandler?(.accountChanged(kind))
            await cancellation
        case let .fetchedDatabaseChanges(changes):
            if changes.deletions.contains(where: { $0.zoneID == CloudKitSyncSchema.zoneID }) {
                await signalHandler?(.zoneReset)
            }
        case let .fetchedRecordZoneChanges(changes):
            pendingMailbox.recordObservedNoteWorkIDs(
                fromRecordNames: changes.modifications.map(\.record.recordID.recordName)
            )
            let hasRelevantModification = changes.modifications.contains {
                $0.record.recordID.zoneID == CloudKitSyncSchema.zoneID
            }
            let hasRelevantDeletion = changes.deletions.contains {
                $0.recordID.zoneID == CloudKitSyncSchema.zoneID
            }
            if hasRelevantModification || hasRelevantDeletion {
                await signalHandler?(.remoteChangesAvailable)
            }
        case let .sentRecordZoneChanges(sent):
            pendingMailbox.recordSendOutcome(sent)
        default:
            break
        }
    }

    private static func accountChangeKind(
        _ change: CKSyncEngine.Event.AccountChange
    ) -> CloudKitAccountChangeKind {
        switch change.changeType {
        case .signIn:
            .signIn
        case .signOut:
            .signOut
        case .switchAccounts:
            .switchAccounts
        @unknown default:
            // An unknown account transition must never be treated as the
            // harmless initial sign-in bootstrap case.
            .switchAccounts
        }
    }

    func nextRecordZoneChangeBatch(
        _: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = CloudKitNotePendingQueue.noteChanges(
            from: syncEngine.state.pendingRecordZoneChanges
        )
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [pendingMailbox] recordID in
            pendingMailbox.record(for: recordID)
        }
    }

    func nextFetchChangesOptions(
        _: CKSyncEngine.FetchChangesContext,
        syncEngine _: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        var options = CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([CloudKitSyncSchema.zoneID]))
        options.prioritizedZoneIDs = [CloudKitSyncSchema.zoneID]
        return options
    }
}
