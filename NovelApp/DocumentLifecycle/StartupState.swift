import AppKit
import Foundation
import NovelSyncV2
import NovelSyncV2Application
import OSLog

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
    var historyBackfillNote: String?
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

    var diagnosticName: String {
        switch self {
        case .loading: "loading"
        case .documentSelection: "documentSelection"
        case .ready: "ready"
        case .recovery: "recovery"
        }
    }
}

extension AppState {
    private static let startupLog = Logger(subsystem: "dev.serikayuzuki.fuminiwa", category: "startup-state")

    /// Records each root-screen change so a bounce back to the library or a
    /// launch-time screen swap can be read later with
    /// `log show --last 10m --predicate 'category == "startup-state"'`.
    /// Only case names and counters are logged; no titles or text.
    func logStartupTransition(from oldValue: AppStartupState) {
        let old = oldValue.diagnosticName
        let new = startupState.diagnosticName
        guard old != new else { return }
        let transition = workspaceModel.isDocumentTransitionInProgress
        let windows = NSApp?.windows.filter(\.isVisible).count ?? -1
        Self.startupLog.notice(
            "\(old, privacy: .public) -> \(new, privacy: .public) transition=\(transition, privacy: .public) windows=\(windows, privacy: .public)"
        )
    }
}
