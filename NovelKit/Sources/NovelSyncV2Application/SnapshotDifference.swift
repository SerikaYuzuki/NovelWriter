import Foundation
import NovelSyncV2

public struct SnapshotEpisodeDifference: Hashable, Sendable, Identifiable {
    public let id: String
    public let number: Int
    public let title: String
    public let beforeCount: Int
    public let afterCount: Int
    public var heading: String {
        "第\(number)話「\(title)」"
    }

    public var line: String {
        "\(heading) \(beforeCount)字 → \(afterCount)字"
    }

    public var greatlyReduced: Bool {
        beforeCount > 0 && afterCount <= beforeCount / 2
    }
}

/// Direction is comparison version → displayed version. Bodies are never retained in a summary.
public struct SnapshotDifference: Hashable, Sendable {
    public let line: String
    public let episodes: [SnapshotEpisodeDifference]
    public let available: Bool
    public var hasLargeReduction: Bool {
        episodes.contains { $0.greatlyReduced || ($0.afterCount > 0 && $0.beforeCount <= $0.afterCount / 2) }
    }

    public var reduction: SnapshotEpisodeDifference? {
        episodes.first(where: \.greatlyReduced)
    }

    public static let unfetched = Self(line: "未取得", episodes: [], available: false)
}

/// Only differing body objects are read. Titles and array-order entities are the
/// minimum context needed to identify those bodies; unchanged manuscript/resources are skipped.
public enum SnapshotDifferenceCalculator {
    public typealias Reader = @Sendable (Bool, SnapshotEntry) async throws -> Data

    public static func compare(before: SnapshotManifest?, after: SnapshotManifest?,
                               read: @escaping Reader) async throws -> SnapshotDifference {
        guard let before, let after else { return .unfetched }
        guard before.workId == after.workId else { throw SyncV2ApplicationError.workNotFound }
        let old = Dictionary(uniqueKeysWithValues: before.entries.map { ($0.entityKey, $0) })
        let new = Dictionary(uniqueKeysWithValues: after.entries.map { ($0.entityKey, $0) })
        let keys = Set(old.keys).union(new.keys).filter { old[$0]?.objectId != new[$0]?.objectId }.sorted()
        guard !keys.isEmpty else { return SnapshotDifference(line: "内容の変更なし", episodes: [], available: true) }
        let bodyKeys = keys.filter { $0.hasPrefix("episode/") && $0.hasSuffix("/body") }
        guard !bodyKeys.isEmpty else {
            return SnapshotDifference(line: metadataLine(keys), episodes: [], available: true)
        }
        let reader = DifferenceObjectReader(read: read)
        let newOrder = try await episodeOrder(new, after: true, reader: reader)
        let oldOrder = try await episodeOrder(old, after: false, reader: reader)
        var episodes: [SnapshotEpisodeDifference] = []
        for key in bodyKeys {
            try Task.checkCancellation()
            let prefix = String(key.dropLast(5))
            let id = String(prefix.dropFirst(8))
            let beforeCount = try await reader.value(old[key], after: false).count
            let afterCount = try await reader.value(new[key], after: true).count
            let titleEntry = new[prefix + "/title"] ?? old[prefix + "/title"]
            let title = try await reader.value(titleEntry, after: new[prefix + "/title"] != nil)
            let number = (newOrder.firstIndex(of: id) ?? oldOrder.firstIndex(of: id) ?? 0) + 1
            episodes.append(SnapshotEpisodeDifference(id: id, number: number, title: title,
                                                      beforeCount: beforeCount, afterCount: afterCount))
        }
        episodes.sort { $0.number == $1.number ? $0.id < $1.id : $0.number < $1.number }
        let largest = episodes.max {
            let left = abs($0.afterCount - $0.beforeCount)
            let right = abs($1.afterCount - $1.beforeCount)
            return left == right ? $0.number > $1.number : left < right
        }
        let suffix = episodes.count > 1 ? " ほか\(episodes.count - 1)件" : ""
        return SnapshotDifference(line: (largest?.line ?? "内容の変更なし") + suffix, episodes: episodes, available: true)
    }

    private static func episodeOrder(_ entries: [String: SnapshotEntry], after: Bool,
                                     reader: DifferenceObjectReader) async throws -> [String] {
        let chapters = try await reader.order(entries["work/chapter-order"], after: after)
        var episodes: [String] = []
        for chapter in chapters {
            episodes += try await reader.order(entries["chapter/\(chapter)/episode-order"], after: after)
        }
        return episodes
    }

    private static func metadataLine(_ keys: [String]) -> String {
        var kinds: [String] = []
        let categories = [("character", "人物"), ("world-note", "設定"), ("plot-card", "プロット"),
                          ("flag", "伏線"), ("attachment", "資料")]
        for (kind, title) in categories where keys.contains(where: { $0.hasPrefix(kind + "/") || $0 == "work/\(kind)-order" }) {
            kinds.append(title)
        }
        if keys.contains(where: { $0 == "work/chapter-order" || $0.hasSuffix("/episode-order") }) {
            kinds.append("話の順序")
        }
        if keys.contains(where: { $0.hasPrefix("episode/") || $0.hasPrefix("chapter/") }), !kinds.contains("話の順序") {
            kinds.append("話・章の情報")
        }
        if keys.contains(where: { $0 == "work/title" || $0 == "work/synopsis" || $0 == "work/document" }) {
            kinds.append("作品情報")
        }
        return (kinds.isEmpty ? "内容" : kinds.prefix(2).joined(separator: "・")) + "の変更"
    }
}

private actor DifferenceObjectReader {
    let read: SnapshotDifferenceCalculator.Reader
    var objects: [ObjectID: Data] = [:]
    init(read: @escaping SnapshotDifferenceCalculator.Reader) {
        self.read = read
    }

    func data(_ entry: SnapshotEntry, after: Bool) async throws -> Data {
        if let cached = objects[entry.objectId] {
            return cached
        }
        let data = try await read(after, entry)
        objects[entry.objectId] = data
        return data
    }

    func value(_ entry: SnapshotEntry?, after: Bool) async throws -> String {
        guard let entry else { return "" }
        return try await SnapshotCodec.valueString(data(entry, after: after))
    }

    func order(_ entry: SnapshotEntry?, after: Bool) async throws -> [String] {
        guard let entry else { throw SyncV2ApplicationError.workNotFound }
        return try await SnapshotCodec.order(data(entry, after: after))
    }
}
