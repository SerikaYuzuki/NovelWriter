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

struct StartupRecentDocument: Identifiable, Equatable, Hashable {
    let url: URL

    init(url: URL) {
        self.url = url.standardizedFileURL
    }

    var id: String {
        url.path
    }

    var displayName: String {
        let name = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "名称未設定の作品" : name
    }

    var locationDescription: String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}

struct StartupDocumentSelectionContext: Equatable {
    let recentDocument: StartupRecentDocument?

    init(recentDocumentURL: URL?) {
        recentDocument = recentDocumentURL.map(StartupRecentDocument.init(url:))
    }
}

enum AppStartupState: Equatable {
    case loading
    case documentSelection(StartupDocumentSelectionContext)
    case ready
    case recovery(StartupRecoveryContext)

    var isReady: Bool {
        self == .ready
    }

    var permitsDocumentChoice: Bool {
        switch self {
        case .loading:
            false
        case .documentSelection, .ready, .recovery:
            true
        }
    }
}
