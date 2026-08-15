import Foundation
import NovelCore

public enum WorkEntityKind: String, Codable, Sendable {
    case document
    case chapter
    case episode
    case character
    case plotCard
    case flag
    case worldNote
    case order
}

public enum WorkConflictReason: String, Codable, Sendable {
    case commonAncestorUnknown
    case sameFieldChanged
    case textOverlap
    case textInputLimitExceeded
    case mergeBudgetExceeded
    case deleteVersusEdit
    case addedDifferently
    case bothOrdersChanged
}

/// UIが差分箇所を示すためのportable conflict descriptor。
/// 完全な三者の値は`WorkConflictReview`のrevision/snapshot側が保持する。
public struct WorkFieldConflict: Hashable, Codable, Sendable, Identifiable {
    public static let maximumValueUTF8Bytes = 1 * 1024
    public static let maximumPathUTF8Bytes = 512
    public static let maximumFieldUTF8Bytes = 128

    public var id: String {
        path
    }

    public let path: String
    public let entityKind: WorkEntityKind
    public let entityID: WorkStableID?
    public let field: String
    public let reason: WorkConflictReason
    public let baseValue: String?
    public let localValue: String?
    public let remoteValue: String?
    public let proposedValue: String?

    public init(
        path: String,
        entityKind: WorkEntityKind,
        entityID: WorkStableID?,
        field: String,
        reason: WorkConflictReason,
        baseValue: String?,
        localValue: String?,
        remoteValue: String?,
        proposedValue: String?
    ) {
        self.path = path
        self.entityKind = entityKind
        self.entityID = entityID
        self.field = field
        self.reason = reason
        self.baseValue = Self.bounded(baseValue)
        self.localValue = Self.bounded(localValue)
        self.remoteValue = Self.bounded(remoteValue)
        self.proposedValue = Self.bounded(proposedValue)
    }

    public func validate() throws {
        guard path.utf8.count <= Self.maximumPathUTF8Bytes,
              field.utf8.count <= Self.maximumFieldUTF8Bytes,
              [baseValue, localValue, remoteValue, proposedValue]
              .compactMap(\.self)
              .allSatisfy({ $0.utf8.count <= Self.maximumValueUTF8Bytes }) else {
            throw WorkSyncJournalError.reviewMismatch
        }
    }

    private static func bounded(_ value: String?) -> String? {
        guard let value, value.utf8.count > maximumValueUTF8Bytes else { return value }
        let digest = SyncContentDigest(content: value).rawValue
        let suffix = "\n… [sha256:\(digest)]"
        let prefixBudget = maximumValueUTF8Bytes - suffix.utf8.count
        var prefix = ""
        prefix.reserveCapacity(prefixBudget)
        for scalar in value.unicodeScalars {
            let candidate = String(scalar)
            guard prefix.utf8.count + candidate.utf8.count <= prefixBudget else { break }
            prefix.append(candidate)
        }
        return prefix + suffix
    }
}
