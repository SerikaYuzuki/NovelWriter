import Foundation
import NovelSyncV2

public enum SyncV2LibraryAvailability: String, Hashable, Sendable {
    case localOnly
    case cached
    case remoteOnly
}

public enum SyncV2LibraryAccountState: String, Hashable, Sendable {
    case unbound
    case active
    case quarantined
    case parkedDifferentAccount
}

public struct SyncV2LibraryItem: Sendable {
    public let workID: WorkID
    public let title: String
    public let availability: SyncV2LibraryAvailability
    public let accountState: SyncV2LibraryAccountState
    public let localGeneration: Int64?
    public let remoteHead: SyncV2RemoteHead?
    public let conflict: SyncV2ConflictProjection?
    public let remoteProgress: SyncV2RemoteProgress

    public init(
        workID: WorkID,
        title: String,
        availability: SyncV2LibraryAvailability,
        accountState: SyncV2LibraryAccountState,
        localGeneration: Int64? = nil,
        remoteHead: SyncV2RemoteHead? = nil,
        conflict: SyncV2ConflictProjection? = nil,
        remoteProgress: SyncV2RemoteProgress = .idle
    ) {
        self.workID = workID
        self.title = title
        self.availability = availability
        self.accountState = accountState
        self.localGeneration = localGeneration
        self.remoteHead = remoteHead
        self.conflict = conflict
        self.remoteProgress = remoteProgress
    }
}

public struct SyncV2LibraryProjection: Sendable {
    public let items: [SyncV2LibraryItem]

    public init(items: [SyncV2LibraryItem]) {
        self.items = items.sorted { $0.workID.description < $1.workID.description }
    }
}

/// Produces the already account-scoped shelf. Implementations must not return
/// titles or identities belonging to another account/fence. Quarantined local
/// works remain visible but are never included in an automatic download.
public protocol SyncV2LibraryProvider: Sendable {
    func library() async throws -> SyncV2LibraryProjection
    func downloadRemoteOnly(workID: WorkID) async throws -> SyncV2RemoteInbox
    func catalogPage(cursor: String?, pageSize: Int) async throws -> SyncV2RemoteCatalogPage
    func remoteHead(workID: WorkID) async throws -> SyncV2RemoteHead?
    func historyPage(workID: WorkID, cursor: String?, pageSize: Int) async throws -> SyncV2RemoteHistoryPage
    func remoteConflict(workID: WorkID) async throws -> SyncV2ConflictProjection?
}

public extension SyncV2LibraryProvider {
    func catalogPage(cursor: String?, pageSize: Int) async throws -> SyncV2RemoteCatalogPage {
        _ = cursor
        _ = pageSize
        throw SyncV2Failure.authenticationRequired
    }

    func remoteHead(workID: WorkID) async throws -> SyncV2RemoteHead? {
        _ = workID
        throw SyncV2Failure.authenticationRequired
    }

    func historyPage(workID: WorkID, cursor: String?, pageSize: Int) async throws -> SyncV2RemoteHistoryPage {
        _ = workID
        _ = cursor
        _ = pageSize
        throw SyncV2Failure.authenticationRequired
    }

    func remoteConflict(workID: WorkID) async throws -> SyncV2ConflictProjection? {
        _ = workID
        throw SyncV2Failure.authenticationRequired
    }
}
