#if canImport(NovelSyncCloudKit)
import Foundation
import NovelCore
import NovelSync
import NovelSyncCloudKit

/// D-076 R5: compatibility-only Work transport. Normal production composition
/// does not inject this transport; keeping it under Legacy makes the next
/// target split a source exclusion instead of another behavioral rewrite.
extension IOSDeviceSyncProductionRuntimeBox: WorkSyncTransport {
    func fetchSnapshot(for workID: SyncWorkID) async throws -> WorkRemoteSnapshot {
        try await readyServices().workTransport.fetchSnapshot(for: workID)
    }

    func fetchRevision(_ id: SyncRevisionID, for workID: SyncWorkID) async throws -> WorkRevision {
        try await readyServices().workTransport.fetchRevision(id, for: workID)
    }

    func publish(_ request: WorkPublishRequest) async throws -> WorkPublishResult {
        try await readyServices().workTransport.publish(request)
    }
}

#endif
