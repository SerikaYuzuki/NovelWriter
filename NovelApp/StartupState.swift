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

enum StartupLibraryWorkReference: Hashable {
    case recentDocument(URL)
    case cloudWork(UUID)
}

enum StartupLibraryWorkAvailability: Hashable {
    /// iCloud identityと端末内app-private working copyがexact一致している。
    case cachedRemote
    /// 端末内へ保存済みだが、iCloudへの初回作成または更新をまだ確認できない。
    case localPending
    /// Device Syncを持たないbuildでだけ使うlocal fallback。iCloudと表示しない。
    case localOnly
    /// catalog metadataだけがあり、初回materializationには通信が必要。
    case remoteOnly
    /// exact remote revisionがhidden journalにあり、中断した端末保存を再開できる。
    case remotePending
    /// 端末内packageは読めるが、remote差分の明示統合が必要。
    case needsReview
    /// local packageは検証済みだが、接続中のcurrent catalogに作品が無い。
    /// delete/tombstone意味論が無いMVPではopen/uploadを止める。
    case cloudUnavailable
    /// account相違、破損、head欠損等により自動で開いてはいけない。
    case unavailable
}

struct StartupLibraryWork: Identifiable, Equatable, Hashable {
    let reference: StartupLibraryWorkReference
    let title: String
    let updatedAt: Date?
    let availability: StartupLibraryWorkAvailability
    let isTitleTruncated: Bool

    init(
        reference: StartupLibraryWorkReference,
        title: String,
        updatedAt: Date?,
        availability: StartupLibraryWorkAvailability,
        isTitleTruncated: Bool = false
    ) {
        self.reference = reference
        self.title = title
        self.updatedAt = updatedAt
        self.availability = availability
        self.isTitleTruncated = isTitleTruncated
    }

    var id: StartupLibraryWorkReference {
        reference
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? "名称未設定の作品" : trimmed
        guard isTitleTruncated, !normalized.hasSuffix("…") else { return normalized }
        return normalized + "…"
    }
}

enum StartupLibraryConnection: Equatable {
    case available
    case offline
    case accountRequired
    case differentAccount
    case unavailable(message: String)
}

enum StartupLibraryPresentation: Equatable {
    case cloudLibrary
    case localFallback
}

struct StartupDocumentSelectionContext: Equatable {
    let works: [StartupLibraryWork]
    let connection: StartupLibraryConnection
    let isLoading: Bool
    let presentation: StartupLibraryPresentation

    init(recentDocumentURL: URL?) {
        works = recentDocumentURL.map { url in
            let recent = StartupRecentDocument(url: url)
            return StartupLibraryWork(
                reference: .recentDocument(recent.url),
                title: recent.displayName,
                updatedAt: nil,
                availability: .localOnly
            )
        }.map { [$0] } ?? []
        connection = .available
        isLoading = false
        presentation = .localFallback
    }

    init(
        works: [StartupLibraryWork],
        connection: StartupLibraryConnection,
        isLoading: Bool = false,
        presentation: StartupLibraryPresentation = .cloudLibrary
    ) {
        self.works = works
        self.connection = connection
        self.isLoading = isLoading
        self.presentation = presentation
    }

    var recentDocument: StartupRecentDocument? {
        guard case let .recentDocument(url) = works.first?.reference else { return nil }
        return StartupRecentDocument(url: url)
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
