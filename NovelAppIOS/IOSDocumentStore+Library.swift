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

private struct IOSAttestedPrivatePackageCandidate: Sendable {
    let url: URL
    let modificationDate: Date?
    let attestation: IOSPrivateWorkingCopyLocation.PackageAttestation
}

extension IOSDocumentStore {
    @discardableResult
    func refreshLibrary() async -> Bool {
        guard !deviceSyncStartupFailedSafely else { return false }
        do {
            guard let privateWorkingCopyLocation else {
                throw IOSPrivateWorkingCopyLocationError.unsafeRoot
            }
            try privateWorkingCopyLocation.validateFixedRoot()
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
            guard isVerified,
                  isAvailable,
                  let privateWorkingCopyLocation,
                  let candidate = try? privateWorkingCopyLocation.attestPackage(for: id) else {
                operationErrorMessage = "選択した作品を安全に開けませんでした。作品一覧を更新して、もう一度お試しください。"
                return false
            }

            if startupState == .ready, documentURL == candidate.url {
                guard (try? privateWorkingCopyLocation.revalidate(candidate)) != nil else {
                    operationErrorMessage = "選択した作品を安全に開けませんでした。作品一覧を更新して、もう一度お試しください。"
                    return false
                }
                userDefaults.set(candidate.url.lastPathComponent, forKey: Self.lastDocumentNameKey)
                operationErrorMessage = nil
                return true
            }

            let transitioned = await performDocumentTransition {
                try privateWorkingCopyLocation.revalidate(candidate)
                let loaded = try await repository.load(from: candidate.url)
                try privateWorkingCopyLocation.revalidate(candidate)
                let loadedAttachments = try await loadAttachmentsForInstall(at: candidate.url)
                try privateWorkingCopyLocation.revalidate(candidate)
                guard !deviceSyncStartupFailedSafely else { throw CancellationError() }
                guard install(loaded, at: candidate.url, attachments: loadedAttachments) else {
                    throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                }
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

        guard refreshGeneration == libraryRefreshGeneration,
              let privateWorkingCopyLocation else { return }
        try privateWorkingCopyLocation.validateFixedRoot()
        refreshedItems.sort(by: Self.libraryItemComesBefore)
        libraryItems = refreshedItems
        verifiedPrivateDocumentIDs = refreshedIDs
    }

    private func libraryItem(
        id: IOSPrivateDocumentID,
        candidate: IOSAttestedPrivatePackageCandidate,
        activeDocumentSnapshot: (url: URL, document: NovelDocument)?
    ) async -> IOSDocumentLibraryItem {
        let isActiveDocument = candidate.url.standardizedFileURL == activeDocumentSnapshot?.url
        if isActiveDocument, let activeDocumentSnapshot {
            guard let privateWorkingCopyLocation,
                  (try? privateWorkingCopyLocation.revalidate(candidate.attestation)) != nil else {
                return IOSDocumentLibraryItem(
                    id: id,
                    title: Self.fallbackLibraryTitle(for: id.packageName),
                    chapterCount: 0,
                    episodeCount: 0,
                    characterCount: 0,
                    modificationDate: candidate.modificationDate,
                    availability: .unreadable,
                    errorMessage: "この作品は安全に確認できません。ほかの作品はそのまま利用できます。"
                )
            }
            return Self.libraryItem(
                id: id,
                document: activeDocumentSnapshot.document,
                modificationDate: candidate.modificationDate
            )
        }

        do {
            guard let privateWorkingCopyLocation else {
                throw IOSPrivateWorkingCopyLocationError.unsafeRoot
            }
            try privateWorkingCopyLocation.revalidate(candidate.attestation)
            let loaded = try await repository.load(from: candidate.url)
            try privateWorkingCopyLocation.revalidate(candidate.attestation)
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
              let privateWorkingCopyLocation,
              let attestation = try? privateWorkingCopyLocation.attestPackage(for: id),
              let loaded = try? await repository.load(from: attestation.url),
              (try? privateWorkingCopyLocation.revalidate(attestation)) != nil,
              let loadedAttachments = try? await loadAttachmentsForInstall(at: attestation.url),
              (try? privateWorkingCopyLocation.revalidate(attestation)) != nil else { return false }
        guard !deviceSyncStartupFailedSafely else { return false }
        return install(
            loaded,
            at: attestation.url,
            attachments: loadedAttachments,
            rememberRecent: rememberRecent
        )
    }

    static func isValidPrivatePackageName(_ name: String) -> Bool {
        IOSPrivateWorkingCopyLocation.isValidPrivatePackageName(name)
    }

    static func copyPackage(from sourceURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }.value
    }

    private func privatePackageCandidates() throws -> [IOSAttestedPrivatePackageCandidate] {
        guard let privateWorkingCopyLocation else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        try privateWorkingCopyLocation.validateFixedRoot()
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ]
        let root = privateWorkingCopyLocation.rootURL
        let urls = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        let candidates = urls.compactMap { url -> IOSAttestedPrivatePackageCandidate? in
            let name = url.lastPathComponent
            guard Self.isValidPrivatePackageName(name),
                  url.standardizedFileURL.deletingLastPathComponent() == root else { return nil }
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            guard let attestation = try? privateWorkingCopyLocation.attestPackage(at: url) else { return nil }
            return IOSAttestedPrivatePackageCandidate(
                url: attestation.url,
                modificationDate: values.contentModificationDate,
                attestation: attestation
            )
        }
        try privateWorkingCopyLocation.validateFixedRoot()
        return candidates
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
