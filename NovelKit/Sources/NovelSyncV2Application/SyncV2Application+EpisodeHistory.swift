import Foundation
import NovelCore
import NovelSyncV2

public struct EpisodeBodyReference: Hashable, Sendable {
    public let snapshotID: SnapshotID
    public let entry: SnapshotEntry

    public init(snapshotID: SnapshotID, entry: SnapshotEntry) {
        self.snapshotID = snapshotID
        self.entry = entry
    }
}

public struct EpisodeHistoryVersion: Identifiable, Sendable {
    public var occurrences: [SyncV2HistoryItem]
    public let body: EpisodeBodyReference
    public var previous: EpisodeBodyReference?
    public var id: UUID {
        occurrences[0].occurrenceID
    }

    public var item: SyncV2HistoryItem {
        occurrences[0]
    }
}

public struct EpisodeHistory: Sendable {
    public var versions: [EpisodeHistoryVersion] = []
    public var unfetchedCount = 0
    public var onlineFailure: SyncV2Failure?
    public var isLoadingOlder: Bool {
        continuation != nil
    }

    private var adjacent = false
    var continuation: EpisodeHistoryContinuation?

    public init() {}

    /// Input is the existing newest-first occurrence list. A missing episode or
    /// unknown body interrupts adjacency; A → B → A remains three versions.
    public static func project(items: [SyncV2HistoryItem], bodies: [SnapshotID: SnapshotEntry]) -> Self {
        var result = Self()
        result.append(items: items, bodies: bodies)
        return result
    }

    /// Retain adjacency across batches, including unknown/missing-body breaks.
    mutating func append(items: [SyncV2HistoryItem], bodies: [SnapshotID: SnapshotEntry]) {
        for item in items {
            guard let entry = bodies[item.snapshotID] else {
                if item.snapshotAvailability == .unfetched {
                    unfetchedCount += 1
                }
                adjacent = false
                continue
            }
            if adjacent, versions.last?.body.entry.objectId == entry.objectId {
                versions[versions.count - 1].occurrences.append(item)
            } else {
                let reference = EpisodeBodyReference(snapshotID: item.snapshotID, entry: entry)
                if adjacent, !versions.isEmpty {
                    versions[versions.count - 1].previous = reference
                }
                versions.append(EpisodeHistoryVersion(occurrences: [item], body: reference))
            }
            adjacent = true
        }
    }
}

struct EpisodeHistoryContinuation: Sendable {
    let episodeID: EpisodeID
    let bodies: [SnapshotID: SnapshotEntry]
    let localSnapshots: Set<SnapshotID>
    let cursor: HistoryLoadingCursor
}

struct EpisodeBodyCountKey: Hashable, Sendable {
    let workID: WorkID
    let objectID: ObjectID
}

public extension SyncV2Application {
    /// Returns the first local page immediately; older/online rows are fetched
    /// only when the caller continues. No background task outlives the UI owner.
    func episodeHistory(workID: WorkID, episodeID: EpisodeID) async throws -> EpisodeHistory {
        let scope = historyScopeGeneration
        let bodies = try await kernel.episodeBodyVersions(workID: workID, episodeKey: "episode/\(episodeID.rawValue.uuidString.lowercased())/body")
        try Task.checkCancellation()
        guard scope == historyScopeGeneration else { throw SyncV2ApplicationError.invalidHistoryCursor }
        let localSnapshots = Set(bodies.keys)
        let page = try await firstHistoryPage(workID: workID, pageSize: 100, locallyAvailableSnapshots: localSnapshots)
        var result = EpisodeHistory.project(items: page.items, bodies: bodies)
        result.continuation = page.next.map {
            EpisodeHistoryContinuation(episodeID: episodeID, bodies: bodies, localSnapshots: localSnapshots, cursor: $0)
        }
        return result
    }

    func olderEpisodeHistory(_ history: EpisodeHistory) async throws -> EpisodeHistory {
        guard let continuation = history.continuation else { return history }
        let page = try await olderHistoryPage(continuation.cursor, pageSize: 500,
                                              locallyAvailableSnapshots: continuation.localSnapshots)
        var result = page.replacesItems ? EpisodeHistory() : history
        result.append(items: page.items, bodies: continuation.bodies)
        result.onlineFailure = page.onlineFailure
        result.continuation = page.next.map {
            EpisodeHistoryContinuation(episodeID: continuation.episodeID, bodies: continuation.bodies,
                                       localSnapshots: continuation.localSnapshots, cursor: $0)
        }
        return result
    }

    /// Counts only (never manuscript text) are retained, scoped to Work/account.
    /// Visible rows share in-flight reads when a body occurs again later.
    func episodeHistoryCharacterCount(workID: WorkID, body: EpisodeBodyReference, episodeID: EpisodeID) async throws -> Int {
        let scope = historyScopeGeneration
        let key = EpisodeBodyCountKey(workID: workID, objectID: body.entry.objectId)
        if let count = episodeBodyCounts[key] {
            return count
        }
        if let flight = episodeBodyCountFlights[key] {
            let count = try await flight.value
            guard scope == historyScopeGeneration else { throw SyncV2ApplicationError.invalidHistoryCursor }
            return count
        }
        let flight = Task {
            try await self.snapshotEpisodePreview(workID: workID, snapshotID: body.snapshotID, episodeID: episodeID.rawValue.uuidString.lowercased()).count
        }
        episodeBodyCountFlights[key] = flight
        do {
            let count = try await flight.value
            guard scope == historyScopeGeneration else { throw SyncV2ApplicationError.invalidHistoryCursor }
            episodeBodyCountFlights[key] = nil
            if episodeBodyCounts.count >= 4096 {
                episodeBodyCounts.removeAll(keepingCapacity: true)
            }
            episodeBodyCounts[key] = count
            return count
        } catch {
            if scope == historyScopeGeneration {
                episodeBodyCountFlights[key] = nil
            }
            throw error
        }
    }
}
