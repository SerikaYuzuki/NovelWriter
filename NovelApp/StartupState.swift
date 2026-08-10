import Foundation

enum StartupDocumentSource: Equatable {
    case recentDocument
    case finder
    case chosenDocument
    case initialDocument
}

enum StartupRecoveryReason: Equatable {
    case cannotOpenDocument
    case cannotCreateDocument
    case protectedLocationInDebugBuild
    case deviceSyncSafetyUnavailable
}

struct StartupRecoveryContext: Equatable {
    var reason: StartupRecoveryReason
    var source: StartupDocumentSource
    var documentURL: URL?

    var documentDisplayName: String? {
        documentURL?.lastPathComponent
    }
}

enum AppStartupState: Equatable {
    case loading
    case ready
    case recovery(StartupRecoveryContext)

    var isReady: Bool {
        self == .ready
    }

    var permitsDocumentChoice: Bool {
        self != .loading
    }
}
