import Darwin
import Foundation
import NovelCore
import NovelLibrary
import NovelSync

#if canImport(NovelSyncCloudKit)
/// Durable registry-record persistence for the app-private local library.
/// Package placement and lifecycle transitions remain owned by the actor.
struct DeviceSyncLocalLibraryRegistry {
    private struct RecordEnvelope: Codable {
        static let currentVersion = 1

        let version: Int
        let record: DeviceSyncLocalLibraryRecord
    }

    private static let maximumRecordBytes = 2 * 1024 * 1024
    private static let maximumRecords = 20000

    let rootURL: URL
    private let rootIdentity: FileDeviceSyncMergeRecoveryStore.RootIdentity
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(
        _ rootURL: URL,
        trustedAncestorURL: URL,
        fileManager: FileManager
    ) throws {
        let prepared = try FileDeviceSyncMergeRecoveryStore.prepareAnchoredRoot(
            rootURL,
            trustedAncestorURL: trustedAncestorURL,
            fileManager: fileManager
        )
        self.rootURL = prepared.url
        rootIdentity = prepared.identity
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func readRecord(for workID: SyncWorkID) throws -> DeviceSyncLocalLibraryRecord? {
        let url = recordURL(for: workID)
        guard let status = try pathStatus(url) else { return nil }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              status.st_size <= Self.maximumRecordBytes else {
            throw DeviceSyncLocalLibraryError.invalidRegistry
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DeviceSyncLocalLibraryError.invalidRegistry }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumRecordBytes + 1) ?? Data()
        guard data.count <= Self.maximumRecordBytes else {
            throw DeviceSyncLocalLibraryError.invalidRegistry
        }
        let envelope = try decoder.decode(RecordEnvelope.self, from: data)
        guard envelope.version == RecordEnvelope.currentVersion,
              envelope.record.workID == workID else {
            throw DeviceSyncLocalLibraryError.invalidRegistry
        }
        try envelope.record.validate()
        return envelope.record
    }

    func writeRecord(_ record: DeviceSyncLocalLibraryRecord) throws {
        try record.validate()
        let envelope = RecordEnvelope(version: RecordEnvelope.currentVersion, record: record)
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumRecordBytes else {
            throw DeviceSyncLocalLibraryError.invalidRegistry
        }
        let url = recordURL(for: record.workID)
        if let status = try pathStatus(url), status.st_mode & S_IFMT != S_IFREG {
            throw DeviceSyncLocalLibraryError.invalidRegistry
        }
        try data.write(to: url, options: .atomic)
        guard let status = try pathStatus(url), status.st_mode & S_IFMT == S_IFREG else {
            throw DeviceSyncLocalLibraryError.invalidRegistry
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
        at rootURL: URL,
        fileManager: FileManager
    ) throws -> Set<SyncWorkID> {
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard urls.count <= Self.maximumRecords else {
            throw DeviceSyncLocalLibraryError.invalidRegistry
        }
        return Set(urls.compactMap { url in
            guard url.deletingLastPathComponent().standardizedFileURL == rootURL,
                  url.pathExtension == "novelpkg",
                  let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  url.lastPathComponent == "\(uuid.uuidString).novelpkg" else { return nil }
            return SyncWorkID(rawValue: uuid)
        })
    }

    func validateRoot() throws {
        var status = stat()
        guard lstat(rootURL.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              FileDeviceSyncMergeRecoveryStore.RootIdentity(status) == rootIdentity else {
            throw DeviceSyncLocalLibraryError.unsafeRoot
        }
    }

    func pathStatus(_ url: URL) throws -> stat? {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            return status
        }
        guard errno == ENOENT else { throw DeviceSyncLocalLibraryError.invalidRegistry }
        return nil
    }
}
#endif
