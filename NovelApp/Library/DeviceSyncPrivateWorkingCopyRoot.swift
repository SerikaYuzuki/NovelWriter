#if canImport(NovelSyncCloudKit)
import Darwin
import Foundation
import NovelSync
import NovelSyncCloudKit

struct DeviceSyncPrivateWorkingCopyRoot: @unchecked Sendable {
    struct Identity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    let url: URL
    let identity: Identity

    static func prepare(_ requestedURL: URL, fileManager: FileManager) throws -> Self {
        let requested = requestedURL.standardizedFileURL
        guard requested.isFileURL, requested.path != "/" else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        try validateNoSymlinkComponents(requested)
        try fileManager.createDirectory(at: requested, withIntermediateDirectories: true)
        try validateNoSymlinkComponents(requested)
        let root = requested.resolvingSymlinksInPath().standardizedFileURL
        guard root.path == requested.path,
              let status = try pathStatus(root),
              status.st_mode & S_IFMT == S_IFDIR else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        return Self(
            url: root,
            identity: Identity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
        )
    }

    func destination(for session: DocumentSessionToken) throws -> URL? {
        try validateFixedRoot()
        guard try isEligible(session) == false else { return nil }
        return try destinationForNewWork()
    }

    func destinationForNewWork() throws -> URL {
        try validateFixedRoot()
        return url.appendingPathComponent("\(UUID().uuidString).novelpkg", isDirectory: true)
    }

    /// D-063のcloud libraryでは作品identityから保存先を一意に導出する。
    /// package URLをmetadataへ保存せず、同じworkは再起動後も同じ隠しcopyへ戻る。
    func destination(for workID: SyncWorkID) throws -> URL {
        try validateFixedRoot()
        return url.appendingPathComponent(
            "\(workID.rawValue.uuidString).novelpkg",
            isDirectory: true
        )
    }

    func stagingDestination(for workID: SyncWorkID) throws -> URL {
        try validateFixedRoot()
        return url.appendingPathComponent(
            ".\(workID.rawValue.uuidString).staging.novelpkg",
            isDirectory: true
        )
    }

    func validateStagingPackage(at stagingURL: URL, for workID: SyncWorkID) throws {
        let requested = stagingURL.standardizedFileURL
        let expectedName = ".\(workID.rawValue.uuidString).staging.novelpkg"
        guard requested.deletingLastPathComponent() == url,
              requested.lastPathComponent == expectedName else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        try validateCopiedPackage(at: requested)
    }

    func installStagingPackage(_ stagingURL: URL, for workID: SyncWorkID) throws -> URL {
        try validateStagingPackage(at: stagingURL, for: workID)
        let finalURL = try destination(for: workID)
        guard try Self.pathStatus(finalURL) == nil else {
            throw AppleDeviceSyncServicesError.locatorAlreadyBound
        }
        guard renamex_np(stagingURL.path, finalURL.path, UInt32(RENAME_EXCL)) == 0 else {
            throw errno == EEXIST
                ? AppleDeviceSyncServicesError.locatorAlreadyBound
                : AppleDeviceSyncServicesError.unsafeRoot
        }
        try validateCopiedPackage(at: finalURL, for: workID)
        return finalURL
    }

    func validateCopiedPackage(at packageURL: URL, for workID: SyncWorkID) throws {
        guard try packageURL.standardizedFileURL == destination(for: workID).standardizedFileURL else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        try validateCopiedPackage(at: packageURL)
    }

    /// D-072: this-device copy only. Does not delete CloudKit records.
    func removePackages(for workID: SyncWorkID, fileManager: FileManager) throws {
        try validateFixedRoot()
        let staging = try stagingDestination(for: workID)
        if try Self.pathStatus(staging) != nil {
            try validateStagingPackage(at: staging, for: workID)
            try fileManager.removeItem(at: staging)
            try validateFixedRoot()
        }
        let final = try destination(for: workID)
        if try Self.pathStatus(final) != nil {
            try validateCopiedPackage(at: final, for: workID)
            try fileManager.removeItem(at: final)
            try validateFixedRoot()
        }
    }

    func workID(for packageURL: URL) throws -> SyncWorkID? {
        try validateFixedRoot()
        let requested = packageURL.standardizedFileURL
        guard requested.deletingLastPathComponent() == url,
              requested.pathExtension == "novelpkg",
              let uuid = UUID(uuidString: requested.deletingPathExtension().lastPathComponent),
              requested.lastPathComponent == "\(uuid.uuidString).novelpkg" else { return nil }
        return SyncWorkID(rawValue: uuid)
    }

    func isEligible(_ session: DocumentSessionToken) throws -> Bool {
        try validateFixedRoot()
        let requested = session.documentURL.standardizedFileURL
        guard requested.isFileURL,
              requested.path != url.path,
              requested.path.hasPrefix(url.path + "/"),
              requested.deletingLastPathComponent().path == url.path else { return false }
        try validateCopiedPackage(at: requested)
        return true
    }

    func validateCopiedPackage(at packageURL: URL) throws {
        try validateFixedRoot()
        let requested = packageURL.standardizedFileURL
        guard requested.isFileURL,
              requested.path != url.path,
              requested.deletingLastPathComponent().path == url.path else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        try Self.validateNoSymlinkComponents(requested)
        guard let initial = try Self.pathStatus(requested),
              initial.st_mode & S_IFMT == S_IFDIR else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == requested.path,
              resolved.path.hasPrefix(url.path + "/") else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        try validateFixedRoot()
        guard let final = try Self.pathStatus(requested),
              final.st_mode & S_IFMT == S_IFDIR,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
    }

    func validateFixedRoot() throws {
        try Self.validateNoSymlinkComponents(url)
        guard let status = try Self.pathStatus(url),
              status.st_mode & S_IFMT == S_IFDIR,
              UInt64(status.st_dev) == identity.device,
              UInt64(status.st_ino) == identity.inode else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
    }

    private static func validateNoSymlinkComponents(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            guard let status = try pathStatus(current) else { return }
            guard status.st_mode & S_IFMT != S_IFLNK else {
                throw AppleDeviceSyncServicesError.unsafeRoot
            }
        }
    }

    private static func pathStatus(_ url: URL) throws -> stat? {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            return status
        }
        guard errno == ENOENT else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        return nil
    }
}
#endif
