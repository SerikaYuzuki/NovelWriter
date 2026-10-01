import Foundation
import NovelSyncV2
import NovelSyncV2Application

enum StartupLibraryConnection: Equatable {
    case available
    case offline
    case accountRequired
    case differentAccount
    case unavailable(String)

    var allowsExplicitRemotePublish: Bool {
        self == .available
    }
}

enum StartupLibraryWorkAvailability: Equatable {
    case local
    case cached
    case remoteOnly
    case pending
    case conflict
    case parked
    case excluded
}

struct StartupLibraryWork: Identifiable, Equatable {
    let id: UUID
    let title: String
    let availability: StartupLibraryWorkAvailability
    let workID: WorkID
    let remoteProgress: SyncV2RemoteProgress
    var oldestUnreceivedAt: Date?
    var accountState: SyncV2LibraryAccountState = .unbound
    var remoteHeadConfirmed = false
    var localGeneration: Int64?

    var status: SyncV2LibraryStatus {
        let value = SyncV2LibraryStatus.resolve(availability: availability == .remoteOnly ? .remoteOnly : .localOnly,
                                                accountState: accountState, remoteHeadConfirmed: remoteHeadConfirmed, progress: remoteProgress)
        return accountState == .active && availability != .remoteOnly
            ? value.delayed(since: oldestUnreceivedAt, now: Date()) : value
    }

    var isOpenable: Bool {
        // Parked works remain local-first and editable.  They are projected
        // separately and never take the remote-only/adoption path.
        availability != .excluded
    }
}

enum StartupLibraryPresentation: Equatable {
    case localAndRemote
}

struct StartupDocumentSelectionContext: Equatable {
    let works: [StartupLibraryWork]
    let presentation: StartupLibraryPresentation
    let connection: StartupLibraryConnection
}

struct StartupRecoveryContext: Equatable {
    let message: String
}

enum AppStartupState: Equatable {
    case loading
    case documentSelection(StartupDocumentSelectionContext)
    case ready
    case recovery(StartupRecoveryContext)

    var isReady: Bool {
        self == .ready
    }
}
