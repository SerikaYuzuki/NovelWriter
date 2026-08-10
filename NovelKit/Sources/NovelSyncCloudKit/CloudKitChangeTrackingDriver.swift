import CloudKit
import Foundation

public enum CloudKitSyncSignal: Equatable, Sendable {
    case remoteChangesAvailable
    case accountChanged
    case zoneReset
    case stateSerializationFailed
}

/// CKSyncEngineはpush後のfetch、change token、state serializationだけを担当する。
/// lease/head CASのwriteはこのdriverへenqueueせず、CloudKitEpisodeSyncTransportが
/// CKDatabaseのatomic conditional modifyを直接使う。
public final class CloudKitChangeTrackingDriver: @unchecked Sendable {
    public typealias StateSerializationHandler = @Sendable (Data) async -> Void
    public typealias SignalHandler = @Sendable (CloudKitSyncSignal) async -> Void

    static let automaticallyFetchesPushChanges = true
    static let sendsPendingRecordChanges = false

    private let engine: CKSyncEngine
    private let delegate: CloudKitChangeTrackingDelegate

    init(
        database: CKDatabase,
        restoredState: Data?,
        stateSerializationHandler: StateSerializationHandler?,
        signalHandler: SignalHandler?
    ) throws {
        let serialization: CKSyncEngine.State.Serialization?
        if let restoredState {
            do {
                serialization = try JSONDecoder().decode(
                    CKSyncEngine.State.Serialization.self,
                    from: restoredState
                )
            } catch {
                throw CloudKitSyncAdapterError.invalidConfiguration
            }
        } else {
            serialization = nil
        }
        let delegate = CloudKitChangeTrackingDelegate(
            stateSerializationHandler: stateSerializationHandler,
            signalHandler: signalHandler
        )
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: serialization,
            delegate: delegate
        )
        // push到着時は自動fetchする。write pendingを一切登録せず、batch providerもnilを返すため、
        // lease/head CASがCKSyncEngineの通常saveへ迂回することはない。
        configuration.automaticallySync = Self.automaticallyFetchesPushChanges
        configuration.subscriptionID = CloudKitSyncSchema.subscriptionID
        self.delegate = delegate
        engine = CKSyncEngine(configuration)
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

    init(
        stateSerializationHandler: CloudKitChangeTrackingDriver.StateSerializationHandler?,
        signalHandler: CloudKitChangeTrackingDriver.SignalHandler?
    ) {
        self.stateSerializationHandler = stateSerializationHandler
        self.signalHandler = signalHandler
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine _: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(update):
            guard let stateSerializationHandler else { return }
            do {
                let data = try JSONEncoder().encode(update.stateSerialization)
                await stateSerializationHandler(data)
            } catch {
                await signalHandler?(.stateSerializationFailed)
            }
        case .accountChange:
            await signalHandler?(.accountChanged)
        case let .fetchedDatabaseChanges(changes):
            if changes.deletions.contains(where: { $0.zoneID == CloudKitSyncSchema.zoneID }) {
                await signalHandler?(.zoneReset)
            }
        case let .fetchedRecordZoneChanges(changes):
            let hasRelevantModification = changes.modifications.contains {
                $0.record.recordID.zoneID == CloudKitSyncSchema.zoneID
            }
            let hasRelevantDeletion = changes.deletions.contains {
                $0.recordID.zoneID == CloudKitSyncSchema.zoneID
            }
            if hasRelevantModification || hasRelevantDeletion {
                await signalHandler?(.remoteChangesAvailable)
            }
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _: CKSyncEngine.SendChangesContext,
        syncEngine _: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // Direct CKDatabase CASだけがwrite authority。engineのpending queueは送らない。
        nil
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
