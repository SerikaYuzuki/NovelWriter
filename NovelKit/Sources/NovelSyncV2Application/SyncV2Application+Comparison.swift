import Foundation
import NovelSyncV2

struct SnapshotComparisonKey: Hashable, Sendable {
    let workID: WorkID
    let before: SnapshotID
    let after: SnapshotID
}

public extension SyncV2Application {
    func currentSnapshotID(workID: WorkID) async throws -> SnapshotID? {
        let scope = historyScopeGeneration
        let version = try await kernel.currentVersion(workID: workID)
        guard scope == historyScopeGeneration else { throw SyncV2ApplicationError.invalidHistoryCursor }
        return version.snapshotID
    }

    /// Shared in-flight tasks and a bounded cache keep List row tasks cheap.
    /// Unfetched/error results are not cached, so backfill can immediately make them readable.
    func snapshotDifference(workID: WorkID, before: SnapshotID, after: SnapshotID) async throws -> SnapshotDifference {
        let scope = historyScopeGeneration
        let key = SnapshotComparisonKey(workID: workID, before: before, after: after)
        if let cached = snapshotDifferences[key] {
            return cached
        }
        if let flight = snapshotDifferenceFlights[key] {
            let result = try await flight.value
            guard scope == historyScopeGeneration else { throw SyncV2ApplicationError.invalidHistoryCursor }
            return result
        }
        let kernel = kernel
        let flight = Task {
            let old = try await kernel.localSnapshotManifest(workID: workID, snapshotID: before)
            let new = try await kernel.localSnapshotManifest(workID: workID, snapshotID: after)
            return try await SnapshotDifferenceCalculator.compare(before: old, after: new) { isAfter, entry in
                try await kernel.localSnapshotObject(workID: workID, snapshotID: isAfter ? after : before, entry: entry)
            }
        }
        snapshotDifferenceFlights[key] = flight
        do {
            let result = try await flight.value
            guard scope == historyScopeGeneration else { throw SyncV2ApplicationError.invalidHistoryCursor }
            snapshotDifferenceFlights[key] = nil
            if result.available {
                let episodeCost = snapshotDifferences.values.reduce(result.episodes.count) { $0 + $1.episodes.count }
                if snapshotDifferences.count >= 256 || episodeCost > 32768 {
                    snapshotDifferences.removeAll(keepingCapacity: true)
                }
                snapshotDifferences[key] = result
            }
            return result
        } catch {
            if scope == historyScopeGeneration {
                snapshotDifferenceFlights[key] = nil
            }
            throw error
        }
    }

    func snapshotEpisodePreview(workID: WorkID, snapshotID: SnapshotID, episodeID: String) async throws -> String {
        let scope = historyScopeGeneration
        guard let manifest = try await kernel.localSnapshotManifest(workID: workID, snapshotID: snapshotID) else {
            throw SyncV2ApplicationError.workNotFound
        }
        let entry = manifest.entries.first { $0.entityKey == "episode/\(episodeID)/body" }
        let body: String = if let entry {
            try await SnapshotCodec.valueString(kernel.localSnapshotObject(workID: workID, snapshotID: snapshotID, entry: entry))
        } else {
            ""
        }
        guard scope == historyScopeGeneration else { throw SyncV2ApplicationError.invalidHistoryCursor }
        return body
    }

    /// A missing predecessor at a pagination boundary must not look like a root.
    func snapshotHasParents(workID: WorkID, snapshotID: SnapshotID) async throws -> Bool? {
        let scope = historyScopeGeneration
        let manifest = try await kernel.localSnapshotManifest(workID: workID, snapshotID: snapshotID)
        guard scope == historyScopeGeneration else { throw SyncV2ApplicationError.invalidHistoryCursor }
        return manifest.map { !$0.parentSnapshotIds.isEmpty }
    }

    /// Date lookup is separate from the strictly local comparison reader.
    func remoteSnapshotDate(workID: WorkID, snapshotID: SnapshotID) async throws -> Date? {
        let scope = historyScopeGeneration
        let page = try await remoteReads.historyPage(workID: workID, cursor: nil, pageSize: 100)
        guard scope == historyScopeGeneration else { throw SyncV2ApplicationError.invalidHistoryCursor }
        return page.items.first { $0.snapshotID == snapshotID }?.createdAt
    }

    /// Dates are history occurrences, not document creation time. Missing dates remain explicit.
    func localSnapshotDate(workID: WorkID, snapshotID: SnapshotID) async throws -> Date? {
        let scope = historyScopeGeneration
        let syntheticReasons: Set = ["conflictLocal", "conflictRemote", "preRestore", "preRemoteAdoption", "multipleResolutionRecovery", "remoteBaseline"]
        var cursor: String?
        repeat {
            let page = try await kernel.localHistoryPage(workID: workID, cursor: cursor, pageSize: 500)
            guard scope == historyScopeGeneration else { throw SyncV2ApplicationError.invalidHistoryCursor }
            if let item = page.items.first(where: { $0.snapshotID == snapshotID && !syntheticReasons.contains($0.reason) }) {
                return item.createdAt
            }
            cursor = page.nextCursor
        } while cursor != nil
        return nil
    }
}
