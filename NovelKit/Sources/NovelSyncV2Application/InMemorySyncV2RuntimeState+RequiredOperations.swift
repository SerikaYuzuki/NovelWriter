import Foundation
import NovelSyncV2
import NovelWritingSupport

/// Explicit capabilities of this runtime implementation.
public extension InMemorySyncV2RuntimeState {
    func automaticSyncCandidate(workID _: WorkID) async throws -> SyncV2AutomaticSyncCandidate? {
        nil
    }

    func requestAutomaticSynchronization(workID _: WorkID, candidate _: SyncV2AutomaticSyncCandidate) async throws -> Bool {
        false
    }

    func historyFetchState(workID _: WorkID) async throws -> SyncV2HistoryFetchState {
        .complete
    }

    func snapshotAvailability(workID _: WorkID, snapshotID _: SnapshotID) async throws -> SyncV2SnapshotAvailability {
        .local
    }

    func rescueLocalWork(sourceWorkID _: WorkID, newWorkID _: WorkID, newDocumentID _: DocumentID) async throws -> SyncV2OpenedWork {
        throw SyncV2ApplicationError.safeBoundaryRejected
    }

    func oldestUnreceivedChange(workID _: WorkID) async throws -> Date? {
        nil
    }

    func currentVersion(workID: WorkID) async throws -> SyncV2LocalVersion {
        let opened = try open(workID: workID)
        guard let snapshotID = opened.snapshotID else { throw SyncV2ApplicationError.safeBoundaryRejected }
        return SyncV2LocalVersion(generation: opened.generation, snapshotID: snapshotID)
    }

    func currentGeneration(workID: WorkID) async throws -> Int64 {
        try open(workID: workID).generation
    }

    func prepareWorkDeletion(workID _: WorkID) async throws -> SyncV2WorkDeletion {
        throw SyncV2ApplicationError.safeBoundaryRejected
    }

    func completeWorkDeletion(_: SyncV2WorkDeletion) async throws {
        throw SyncV2ApplicationError.safeBoundaryRejected
    }

    func workDeletions() async throws -> [SyncV2WorkDeletion] {
        []
    }

    func localRescuableWorks() async throws -> [SyncV2ProtectedWork] {
        []
    }

    func writingContext(workID: WorkID) async throws -> SyncV2WritingContext {
        SyncV2WritingContext(workID: workID, commonNamespace: "local:common", binding: nil)
    }
}
