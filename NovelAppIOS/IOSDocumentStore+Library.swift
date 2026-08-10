import Foundation
import NovelCore

struct IOSPrivateDocumentID: Hashable, Sendable {
    let packageName: String
}

struct IOSDocumentSessionToken: Hashable, Sendable {
    let workingCopyID: IOSPrivateDocumentID
    let generation: UInt64
}

enum IOSDocumentLibraryAvailability: Equatable, Sendable {
    case available
    case unreadable
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
    @discardableResult
    func refreshLibrary() async -> Bool {
        guard !deviceSyncStartupFailedSafely else { return false }
        do {
            try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            try await reloadLibraryItems()
            return true
        } catch {
            operationErrorMessage = "作品一覧を読み込めませんでした。既存の作品は変更していません。"
            return false
        }
    }

    @discardableResult
    func openPrivateDocument(id: IOSPrivateDocumentID) async -> Bool {
        guard !deviceSyncStartupFailedSafely else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self else { return false }
            let isVerified = verifiedPrivateDocumentIDs.contains(id)
            let isAvailable = libraryItems.contains { $0.id == id && $0.availability == .available }
            guard isVerified, isAvailable, let candidateURL = verifiedPrivatePackageURL(for: id) else {
                operationErrorMessage = "選択した作品を安全に開けませんでした。作品一覧を更新して、もう一度お試しください。"
                return false
            }

            if startupState == .ready, documentURL == candidateURL {
                userDefaults.set(candidateURL.lastPathComponent, forKey: Self.lastDocumentNameKey)
                operationErrorMessage = nil
                return true
            }

            let transitioned = await performDocumentTransition {
                let loaded = try await repository.load(from: candidateURL)
                let loadedAttachments = try await loadAttachmentsForInstall(at: candidateURL)
                guard !deviceSyncStartupFailedSafely else { throw CancellationError() }
                install(loaded, at: candidateURL, attachments: loadedAttachments)
                startupState = .ready
                saveState = .saved
            }
            if transitioned {
                _ = await refreshLibrary()
            }
            return transitioned
        }
    }

    func reloadLibraryItems() async throws {
        libraryRefreshGeneration += 1
        let refreshGeneration = libraryRefreshGeneration
        let candidates = try privatePackageCandidates()
        let activeDocumentSnapshot: (url: URL, document: NovelDocument)? = if startupState == .ready {
            (documentURL.standardizedFileURL, document)
        } else {
            nil
        }
        var refreshedItems: [IOSDocumentLibraryItem] = []
        var refreshedIDs: Set<IOSPrivateDocumentID> = []

        for candidate in candidates {
            let id = IOSPrivateDocumentID(packageName: candidate.url.lastPathComponent)
            refreshedIDs.insert(id)
            await refreshedItems.append(
                libraryItem(
                    id: id,
                    candidate: candidate,
                    activeDocumentSnapshot: activeDocumentSnapshot
                )
            )
        }

        guard refreshGeneration == libraryRefreshGeneration else { return }
        refreshedItems.sort(by: Self.libraryItemComesBefore)
        libraryItems = refreshedItems
        verifiedPrivateDocumentIDs = refreshedIDs
    }

    private func libraryItem(
        id: IOSPrivateDocumentID,
        candidate: (url: URL, modificationDate: Date?),
        activeDocumentSnapshot: (url: URL, document: NovelDocument)?
    ) async -> IOSDocumentLibraryItem {
        let isActiveDocument = candidate.url.standardizedFileURL == activeDocumentSnapshot?.url
        if isActiveDocument, let activeDocumentSnapshot {
            return Self.libraryItem(
                id: id,
                document: activeDocumentSnapshot.document,
                modificationDate: candidate.modificationDate
            )
        }

        do {
            let loaded = try await repository.load(from: candidate.url)
            return Self.libraryItem(
                id: id,
                document: loaded,
                modificationDate: candidate.modificationDate
            )
        } catch {
            return IOSDocumentLibraryItem(
                id: id,
                title: Self.fallbackLibraryTitle(for: id.packageName),
                chapterCount: 0,
                episodeCount: 0,
                characterCount: 0,
                modificationDate: candidate.modificationDate,
                availability: .unreadable,
                errorMessage: "この作品は読み込めません。ほかの作品はそのまま利用できます。"
            )
        }
    }

    func activatePrivateDocumentIfAvailable(
        id: IOSPrivateDocumentID,
        rememberRecent: Bool = true
    ) async -> Bool {
        guard !deviceSyncStartupFailedSafely else { return false }
        guard verifiedPrivateDocumentIDs.contains(id),
              libraryItems.contains(where: { $0.id == id && $0.availability == .available }),
              let url = verifiedPrivatePackageURL(for: id),
              let loaded = try? await repository.load(from: url),
              let loadedAttachments = try? await loadAttachmentsForInstall(at: url) else { return false }
        guard !deviceSyncStartupFailedSafely else { return false }
        install(loaded, at: url, attachments: loadedAttachments, rememberRecent: rememberRecent)
        return true
    }

    static func isValidPrivatePackageName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), name.hasSuffix(".novelpkg") else { return false }
        return URL(fileURLWithPath: name).lastPathComponent == name
    }

    static func copyPackage(from sourceURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }.value
    }

    private func privatePackageCandidates() throws -> [(url: URL, modificationDate: Date?)] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ]
        let root = libraryRoot.standardizedFileURL
        let urls = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard Self.isValidPrivatePackageName(name),
                  url.standardizedFileURL.deletingLastPathComponent() == root else { return nil }
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return (url.standardizedFileURL, values.contentModificationDate)
        }
    }

    private func verifiedPrivatePackageURL(for id: IOSPrivateDocumentID) -> URL? {
        guard Self.isValidPrivatePackageName(id.packageName) else { return nil }
        let root = libraryRoot.standardizedFileURL
        let candidate = root.appendingPathComponent(id.packageName, isDirectory: true).standardizedFileURL
        guard candidate.deletingLastPathComponent() == root else { return nil }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? candidate.resourceValues(forKeys: keys),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return nil }
        return candidate
    }

    private static func libraryItem(
        id: IOSPrivateDocumentID,
        document: NovelDocument,
        modificationDate: Date?
    ) -> IOSDocumentLibraryItem {
        let episodes = document.chapters.flatMap(\.episodes)
        return IOSDocumentLibraryItem(
            id: id,
            title: document.title,
            chapterCount: document.chapters.count,
            episodeCount: episodes.count,
            characterCount: episodes.reduce(into: 0) { count, episode in
                count += ManuscriptMetrics.countCharacters(in: episode.content)
            },
            modificationDate: modificationDate,
            availability: .available,
            errorMessage: nil
        )
    }

    private static func fallbackLibraryTitle(for packageName: String) -> String {
        let title = URL(fileURLWithPath: packageName).deletingPathExtension().lastPathComponent
        return title.isEmpty ? "読み込めない作品" : title
    }

    private static func libraryItemComesBefore(
        _ lhs: IOSDocumentLibraryItem,
        _ rhs: IOSDocumentLibraryItem
    ) -> Bool {
        switch (lhs.modificationDate, rhs.modificationDate) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.id.packageName < rhs.id.packageName
        }
    }
}
