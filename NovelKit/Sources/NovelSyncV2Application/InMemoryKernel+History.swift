import Foundation
import NovelSyncV2

private struct InMemoryHistoryBoundary {
    let createdAt: Date
    let occurrenceID: UUID
    let localGeneration: Int64
}

public extension InMemorySyncV2RuntimeState {
    func localHistoryPage(
        workID: WorkID,
        cursor: String?,
        pageSize: Int
    ) throws -> SyncV2LocalHistoryPage {
        guard (1 ... 500).contains(pageSize) else {
            throw SyncV2ApplicationError.invalidHistoryCursor
        }
        guard let work = works[workID] else {
            throw SyncV2ApplicationError.workNotFound
        }
        let boundary = try cursor.map(InMemoryHistoryBoundary.decode)
        let sorted = work.history.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            if lhs.localGeneration != rhs.localGeneration {
                return lhs.localGeneration > rhs.localGeneration
            }
            return lhs.occurrenceID.uuidString.lowercased() > rhs.occurrenceID.uuidString.lowercased()
        }
        let filtered = sorted.filter { item in
            guard let boundary else { return true }
            return item.createdAt < boundary.createdAt ||
                (item.createdAt == boundary.createdAt &&
                    (item.localGeneration < boundary.localGeneration ||
                        (item.localGeneration == boundary.localGeneration &&
                            item.occurrenceID.uuidString.lowercased() < boundary.occurrenceID.uuidString.lowercased())))
        }
        let items = Array(filtered.prefix(pageSize))
        let nextCursor = items.count == pageSize
            ? items.last.map(InMemoryHistoryBoundary.encode)
            : nil
        return SyncV2LocalHistoryPage(items: items, nextCursor: nextCursor)
    }
}

private extension InMemoryHistoryBoundary {
    static func decode(_ value: String) throws -> Self {
        guard let data = Data(base64Encoded: value),
              let raw = String(data: data, encoding: .utf8),
              let lastSeparator = raw.lastIndex(of: "|"),
              let firstSeparator = raw[..<lastSeparator].lastIndex(of: "|"),
              let timestamp = Double(raw[..<firstSeparator]),
              let generation = Int64(raw[raw.index(after: firstSeparator) ..< lastSeparator]),
              let occurrenceID = UUID(uuidString: String(raw[raw.index(after: lastSeparator)...])) else {
            throw SyncV2ApplicationError.invalidHistoryCursor
        }
        return Self(
            createdAt: Date(timeIntervalSince1970: timestamp),
            occurrenceID: occurrenceID,
            localGeneration: generation
        )
    }

    static func encode(_ item: SyncV2LocalHistoryOccurrence) -> String {
        Data("\(item.createdAt.timeIntervalSince1970)|\(item.localGeneration)|\(item.occurrenceID.uuidString.lowercased())".utf8)
            .base64EncodedString()
    }
}
