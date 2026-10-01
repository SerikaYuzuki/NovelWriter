import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelWritingSupport

/// Explicit capabilities of this test double.
extension BlockingHistoryProjectionRemote {
    func backfillHistory(workID: WorkID, manual _: Bool, allowConstrained _: Bool = false, progress: @escaping @Sendable () async -> Void) async throws {
        try await backfillHistory(workID: workID, progress: progress)
    }

    func backfillWorkIDs() async throws -> [WorkID] {
        []
    }

    func backfillHistory(workID _: WorkID, progress _: @escaping @Sendable () async -> Void) async throws {}

    func deleteWork(workID _: WorkID, binding _: SyncV2AccountScopeBinding) async throws {
        throw SyncV2Failure.fatal(.unexpected)
    }

    func downloadRemoteOnly(workID: WorkID) async throws -> SyncV2RemoteInbox {
        _ = workID
        throw SyncV2ApplicationError.workNotFound
    }

    func catalogPage(cursor: String?, pageSize: Int) async throws -> SyncV2RemoteCatalogPage {
        _ = cursor; _ = pageSize
        throw SyncV2Failure.authenticationRequired
    }

    func remoteHead(workID: WorkID) async throws -> SyncV2RemoteHead? {
        _ = workID
        throw SyncV2Failure.authenticationRequired
    }

    func remoteConflict(workID: WorkID) async throws -> SyncV2ConflictProjection? {
        _ = workID
        throw SyncV2Failure.authenticationRequired
    }

    func protectedWorks() async throws -> [SyncV2ProtectedWork] {
        throw SyncV2Failure.authenticationRequired
    }

    func recoveryPoints(workID _: WorkID) async throws -> [SyncV2RecoveryPoint] {
        throw SyncV2Failure.authenticationRequired
    }

    func recoverWork(workID _: WorkID, request _: SyncV2RecoveryRequest) async throws {
        throw SyncV2Failure.authenticationRequired
    }

    func appendWritingRecord(_: WritingRecord, binding _: SyncV2AccountScopeBinding) async throws -> WritingEnvelope {
        throw WritingError.unavailable
    }

    func writingRecordPage(workID _: UUID?, after _: Int64, binding _: SyncV2AccountScopeBinding) async throws -> WritingRecordPage {
        throw WritingError.unavailable
    }
}
