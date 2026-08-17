import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application

struct IOSPrivateDocumentID: Hashable, Sendable {
    let packageName: String
    let workID: WorkID?

    init(packageName: String) {
        self.packageName = packageName
        let basename = packageName.replacingOccurrences(of: ".novelpkg", with: "")
        workID = UUID(uuidString: basename).map { WorkID($0) }
    }

    init(workID: WorkID) {
        packageName = workID.rawValue.uuidString
        self.workID = workID
    }
}

struct IOSDocumentSessionToken: Hashable, Sendable {
    let workingCopyID: IOSPrivateDocumentID
    let generation: UInt64
}

enum IOSDocumentLibraryAvailability: Equatable, Sendable {
    case available, unreadable, local, server, pending, offline, conflict
}

struct IOSDocumentLibraryItem: Identifiable, Equatable, Sendable {
    let id: IOSPrivateDocumentID
    let title: String
    let chapterCount: Int
    let episodeCount: Int
    let characterCount: Int
    let modificationDate: Date?
    let availability: IOSDocumentLibraryAvailability
    let errorMessage: String?
}

extension IOSDocumentStore {
    var usesSnapshotSyncRuntime: Bool {
        snapshotSyncV2Application != nil
    }

    var canExplicitlySyncCurrentWork: Bool {
        snapshotSyncV2Application != nil && startupState == .ready
    }

    var canPublishCurrentWorkToCloud: Bool {
        canExplicitlySyncCurrentWork
    }

    var isExplicitSyncInFlight: Bool {
        isSnapshotSyncInFlight
    }

    var activeCloudWorkID: WorkID? {
        startupState == .ready ? WorkID(document.id) : nil
    }

    @discardableResult
    func refreshLibrary() async -> Bool {
        do {
            try await reloadLibraryItems()
            return true
        } catch {
            operationErrorMessage = "作品一覧を読み込めませんでした。"
            return false
        }
    }

    func reloadLibraryItems() async throws {
        guard let application = snapshotSyncV2Application else {
            throw SyncV2ApplicationError.invalidRuntimeMode
        }
        let projection = try await application.library()
        syncV2LibraryItems = projection.items
        libraryItems = []
        verifiedPrivateDocumentIDs = []
    }

    @discardableResult
    func openPrivateDocument(id: IOSPrivateDocumentID) async -> Bool {
        if snapshotSyncV2Application != nil, let workID = id.workID {
            return await openSnapshotSyncV2(workID: workID.rawValue)
        }
        return false
    }

    func openRemoteOnly(workID: WorkID) async -> Bool {
        await openSnapshotSyncV2(workID: workID.rawValue)
    }
}
