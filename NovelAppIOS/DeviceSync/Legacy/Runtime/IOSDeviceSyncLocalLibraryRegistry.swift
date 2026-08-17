import Darwin
import Foundation
import NovelCore
import NovelLibrary
import NovelSync

/// Durable registry-record persistence for the iOS app-private local library.
/// Package placement and lifecycle transitions remain owned by the actor.
struct IOSDeviceSyncLocalLibraryRegistry {
    private struct RecordEnvelope: Codable {
        static let currentVersion = 1

        let version: Int
        let record: IOSDeviceSyncLocalLibraryRecord
    }

    private struct RootIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
        }
    }

    private static let maximumRecordBytes = 2 * 1024 * 1024
    private static let maximumRecords = 20000

    let rootURL: URL
    private let rootIdentity: RootIdentity
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(
        _ rootURL: URL,
        trustedAncestorURL: URL,
        fileManager: FileManager
    ) throws {
        let root = try Self.prepareRoot(
            rootURL,
            trustedAncestorURL: trustedAncestorURL,
            fileManager: fileManager
        )
        self.rootURL = root.url
        rootIdentity = root.identity
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func readRecord(for workID: SyncWorkID) throws -> IOSDeviceSyncLocalLibraryRecord? {
        let url = recordURL(for: workID)
        guard let status = try pathStatus(url) else { return nil }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              status.st_size <= Self.maximumRecordBytes else {
            throw IOSDeviceSyncLocalLibraryError.invalidRegistry
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw IOSDeviceSyncLocalLibraryError.invalidRegistry }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumRecordBytes + 1) ?? Data()
        guard data.count <= Self.maximumRecordBytes else {
            throw IOSDeviceSyncLocalLibraryError.invalidRegistry
        }
        let envelope = try decoder.decode(RecordEnvelope.self, from: data)
        guard envelope.version == RecordEnvelope.currentVersion,
              envelope.record.workID == workID else {
            throw IOSDeviceSyncLocalLibraryError.invalidRegistry
        }
        try envelope.record.validate()
        return envelope.record
    }

    func writeRecord(_ record: IOSDeviceSyncLocalLibraryRecord) throws {
        try record.validate()
        let data = try encoder.encode(RecordEnvelope(
            version: RecordEnvelope.currentVersion,
            record: record
        ))
        guard data.count <= Self.maximumRecordBytes else {
            throw IOSDeviceSyncLocalLibraryError.invalidRegistry
        }
        let url = recordURL(for: record.workID)
        if let status = try pathStatus(url), status.st_mode & S_IFMT != S_IFREG {
            throw IOSDeviceSyncLocalLibraryError.invalidRegistry
        }
        try data.write(to: url, options: .atomic)
        guard let status = try pathStatus(url), status.st_mode & S_IFMT == S_IFREG else {
            throw IOSDeviceSyncLocalLibraryError.invalidRegistry
        }
    }

    func recordURL(for workID: SyncWorkID) -> URL {
        rootURL.appendingPathComponent(
            "\(workID.rawValue.uuidString).json",
            isDirectory: false
        )
    }

    func canonicalWorkID(for url: URL) -> SyncWorkID? {
        guard url.deletingLastPathComponent().standardizedFileURL == rootURL,
              url.pathExtension == "json",
              let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
              url.lastPathComponent == "\(uuid.uuidString).json" else { return nil }
        return SyncWorkID(rawValue: uuid)
    }

    func packageWorkIDs(
        using location: IOSPrivateWorkingCopyLocation,
        fileManager: FileManager
    ) throws -> Set<SyncWorkID> {
        let urls = try fileManager.contentsOfDirectory(
            at: location.rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard urls.count <= Self.maximumRecords else {
            throw IOSDeviceSyncLocalLibraryError.invalidRegistry
        }
        var workIDs: Set<SyncWorkID> = []
        for url in urls {
            if let workID = try location.workID(for: url) {
                workIDs.insert(workID)
            }
        }
        return workIDs
    }

    func validateRoot() throws {
        var status = stat()
        guard lstat(rootURL.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              RootIdentity(status) == rootIdentity else {
            throw IOSDeviceSyncLocalLibraryError.unsafeRoot
        }
    }

    func pathStatus(_ url: URL) throws -> stat? {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            return status
        }
        guard errno == ENOENT else {
            throw IOSDeviceSyncLocalLibraryError.invalidRegistry
        }
        return nil
    }

    private static func prepareRoot(
        _ requestedURL: URL,
        trustedAncestorURL: URL,
        fileManager: FileManager
    ) throws -> (url: URL, identity: RootIdentity) {
        let requested = requestedURL.standardizedFileURL
        let trusted = trustedAncestorURL.standardizedFileURL.resolvingSymlinksInPath()
        guard requested.isFileURL, trusted.isFileURL,
              requested.path != "/", trusted.path != "/",
              requested.path.hasPrefix(trustedAncestorURL.standardizedFileURL.path + "/") else {
            throw IOSDeviceSyncLocalLibraryError.unsafeRoot
        }
        let relative = requested.pathComponents.dropFirst(
            trustedAncestorURL.standardizedFileURL.pathComponents.count
        )
        guard relative.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".."
                && URL(fileURLWithPath: component).lastPathComponent == component
        }) else {
            throw IOSDeviceSyncLocalLibraryError.unsafeRoot
        }
        var canonical = trusted
        for component in relative {
            canonical.appendPathComponent(component, isDirectory: true)
            var status = stat()
            if lstat(canonical.path, &status) == 0,
               status.st_mode & S_IFMT != S_IFDIR {
                throw IOSDeviceSyncLocalLibraryError.unsafeRoot
            }
        }
        try fileManager.createDirectory(at: canonical, withIntermediateDirectories: true)
        guard canonical.resolvingSymlinksInPath().standardizedFileURL == canonical.standardizedFileURL else {
            throw IOSDeviceSyncLocalLibraryError.unsafeRoot
        }
        var status = stat()
        guard lstat(canonical.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            throw IOSDeviceSyncLocalLibraryError.unsafeRoot
        }
        return (canonical.standardizedFileURL, RootIdentity(status))
    }
}
