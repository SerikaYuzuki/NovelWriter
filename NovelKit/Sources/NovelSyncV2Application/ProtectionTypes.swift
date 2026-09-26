import Foundation
import NovelSyncV2

public struct SyncV2ProtectedWork: Identifiable, Sendable {
    public var id: String {
        workID.description + (localRescue ? "-local" : "-server")
    }

    public let workID: WorkID
    public let title: String
    public let deletedAt: Date?
    public let localRescue: Bool

    public init(workID: WorkID, title: String, deletedAt: Date?, localRescue: Bool = false) {
        self.workID = workID
        self.title = title
        self.deletedAt = deletedAt
        self.localRescue = localRescue
    }
}

public struct SyncV2RecoveryPoint: Identifiable, Sendable {
    public var id: Int64 {
        eventID
    }

    public let eventID: Int64
    public let snapshotID: SnapshotID
    public let createdAt: Date

    public init(eventID: Int64, snapshotID: SnapshotID, createdAt: Date) {
        self.eventID = eventID
        self.snapshotID = snapshotID
        self.createdAt = createdAt
    }
}

public struct SyncV2RecoveryRequest: Codable, Sendable {
    public let operationId: UUID
    public let snapshotId: String
    public let newWorkId: UUID
    public let newDocumentId: UUID

    public init(snapshotID: SnapshotID) {
        operationId = UUID()
        snapshotId = snapshotID.rawValue
        newWorkId = UUID()
        newDocumentId = UUID()
    }
}

public extension SyncV2RemoteClient {
    func protectedWorks() async throws -> [SyncV2ProtectedWork] {
        throw SyncV2Failure.authenticationRequired
    }

    func recoveryPoints(workID _: WorkID) async throws -> [SyncV2RecoveryPoint] {
        throw SyncV2Failure.authenticationRequired
    }

    func recoverWork(workID _: WorkID, request _: SyncV2RecoveryRequest) async throws {
        throw SyncV2Failure.authenticationRequired
    }
}

public extension SyncV2LocalKernel {
    func localRescuableWorks() async throws -> [SyncV2ProtectedWork] {
        []
    }
}

public extension SyncV2Application {
    func protectedWorks() async throws -> [SyncV2ProtectedWork] {
        let generation = historyScopeGeneration
        let local = try await kernel.localRescuableWorks()
        let remoteItems: [SyncV2ProtectedWork]
        do {
            remoteItems = try await remote.protectedWorks()
        } catch {
            if local.isEmpty {
                throw error
            }
            remoteItems = []
        }
        guard generation == historyScopeGeneration else { throw SyncV2Failure.accountFenceChanged }
        // Both copies may be useful: server receipt and the last unsent local checkpoint.
        return remoteItems + local
    }

    func recoveryPoints(workID: WorkID) async throws -> [SyncV2RecoveryPoint] {
        let generation = historyScopeGeneration
        let points = try await remote.recoveryPoints(workID: workID)
        guard generation == historyScopeGeneration else { throw SyncV2Failure.accountFenceChanged }
        return points.sorted { $0.createdAt > $1.createdAt }
    }

    func recoverWork(workID: WorkID, request: SyncV2RecoveryRequest) async throws {
        guard runtimeIdentity != .preview, remoteSchedulingSuspensions.isEmpty else {
            throw SyncV2ApplicationError.safeBoundaryRejected
        }
        let generation = historyScopeGeneration
        try await remote.recoverWork(workID: workID, request: request)
        guard generation == historyScopeGeneration else { throw SyncV2Failure.accountFenceChanged }
    }
}
