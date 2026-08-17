import Foundation
import NovelCore
import NovelSync

enum IOSCloudLibraryConnection: Equatable, Sendable {
    case checking
    case available
    case offline
    case accountRequired
    case differentAccount
    case unavailable

    var allowsExplicitCloudPublish: Bool {
        switch self {
        case .available, .unavailable:
            true
        case .checking, .offline, .accountRequired, .differentAccount:
            false
        }
    }
}

enum IOSCloudLibraryAvailability: Equatable, Sendable {
    case cachedRemote
    case localPending
    case localOnly
    case accountQuarantined
    case legacyLocal
    case remoteOnly
    case remotePending
    case needsReview
    case cloudUnavailable
    case unavailable
}

extension IOSCloudLibraryAvailability {
    func canPublishToCloud(connection: IOSCloudLibraryConnection) -> Bool {
        guard connection.allowsExplicitCloudPublish else { return false }
        return switch self {
        case .localOnly, .localPending:
            true
        case .cachedRemote, .accountQuarantined, .legacyLocal, .remoteOnly, .remotePending,
             .needsReview, .cloudUnavailable, .unavailable:
            false
        }
    }

    var canDuplicateLocalCopy: Bool {
        switch self {
        case .localOnly, .localPending, .cachedRemote, .needsReview, .cloudUnavailable:
            true
        case .accountQuarantined, .legacyLocal, .remoteOnly, .remotePending, .unavailable:
            false
        }
    }

    var canRemoveLocalCopy: Bool {
        switch self {
        case .localOnly, .localPending, .cachedRemote, .accountQuarantined, .needsReview,
             .cloudUnavailable, .unavailable:
            true
        case .legacyLocal, .remoteOnly, .remotePending:
            false
        }
    }
}

struct IOSCloudLibraryItem: Identifiable, Equatable, Sendable {
    let id: SyncWorkID
    let title: String
    let updatedAt: Date?
    let availability: IOSCloudLibraryAvailability
    let isTitleTruncated: Bool

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? "名称未設定の作品" : trimmed
        guard isTitleTruncated, !normalized.hasSuffix("…") else { return normalized }
        return normalized + "…"
    }
}

struct IOSVerifiedCloudLibraryItem {
    let record: IOSDeviceSyncLocalLibraryRecord?
    let attestation: IOSDeviceSyncLocalPackageAttestation?
    let row: IOSCloudLibraryItem
}

struct IOSVerifiedCloudLibrarySnapshot {
    let items: [SyncWorkID: IOSVerifiedCloudLibraryItem]

    var rows: [IOSCloudLibraryItem] {
        items.values.compactMap { item in
            guard item.record?.state != .legacyPreserved else { return nil }
            guard item.attestation != nil
                || item.record?.state != .remoteOpenPending else { return nil }
            return item.row
        }
    }
}

enum IOSCloudLibraryOperationError: Error {
    case unavailable
    case staleSelection
    case packageMismatch
}
