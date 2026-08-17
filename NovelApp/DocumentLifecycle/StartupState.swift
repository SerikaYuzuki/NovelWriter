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

    var isOpenable: Bool {
        availability != .excluded && availability != .parked
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
