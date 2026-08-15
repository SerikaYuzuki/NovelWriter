import Darwin
import Foundation
import NovelCore
import NovelLibrary
import NovelSync

typealias IOSDeviceSyncLocalLibraryError = LibraryRegistryError
typealias IOSDeviceSyncLocalLibraryState = LibraryRecordState
typealias IOSDeviceSyncLocalPackageAttestation = LocalPackageAttestation
typealias IOSDeviceSyncLocalLibraryRecord = LibraryRecord
typealias IOSDeviceSyncLocalLibraryInventory = LibraryInventory
/// Cloud accountに依存しないapp-private working-copy inventory。
/// URLは保存せず、WorkIDから固定package名を毎回導出する。
actor IOSDeviceSyncLocalLibraryStore {
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

    private let registryRootURL: URL
    private let registryRootIdentity: RootIdentity
    private let workingCopyLocation: IOSPrivateWorkingCopyLocation
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(
        registryRootURL: URL,
        trustedAncestorURL: URL,
        workingCopyLocation: IOSPrivateWorkingCopyLocation,
        fileManager: FileManager = .default
    ) throws {
        let root = try Self.prepareRoot(
            registryRootURL,
            trustedAncestorURL: trustedAncestorURL,
            fileManager: fileManager
        )
        self.registryRootURL = root.url
        registryRootIdentity = root.identity
        self.workingCopyLocation = workingCopyLocation
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func inventory() throws -> IOSDeviceSyncLocalLibraryInventory {
        try validateRoots()
        let urls = try fileManager.contentsOfDirectory(
            at: registryRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard urls.count <= Self.maximumRecords else {
            throw IOSDeviceSyncLocalLibraryError.invalidRegistry
        }
        var records: [IOSDeviceSyncLocalLibraryRecord] = []
        var unreadable: Set<SyncWorkID> = []
        for url in urls {
            guard let workID = canonicalWorkID(for: url) else { continue }
            do {
                guard let record = try readRecord(for: workID) else {
                    unreadable.insert(workID)
                    continue
                }
                records.append(record)
            } catch {
                unreadable.insert(workID)
            }
        }
        let registered = Set(records.map(\.workID)).union(unreadable)
        let unregistered = try packageWorkIDs().subtracting(registered)
        try validateRoots()
        records.sort { $0.workID.rawValue.uuidString < $1.workID.rawValue.uuidString }
        return IOSDeviceSyncLocalLibraryInventory(
            records: records,
            unreadableWorkIDs: unreadable,
            unregisteredPackageWorkIDs: unregistered
        )
    }

    func record(for workID: SyncWorkID) throws -> IOSDeviceSyncLocalLibraryRecord? {
        try readRecord(for: workID)
    }

    func packageURL(for workID: SyncWorkID) throws -> URL {
        try validateRoots()
        return try workingCopyLocation.packageURL(for: workID)
    }

    func workID(for packageURL: URL) throws -> SyncWorkID? {
        try validateRoots()
        return try workingCopyLocation.workID(for: packageURL)
    }

    func stagingPackageURL(for workID: SyncWorkID) throws -> URL {
        try validateRoots()
        return try workingCopyLocation.stagingPackageURL(for: workID)
    }

    func validateStagingPackage(at url: URL, for workID: SyncWorkID) throws {
        try validateRoots()
        try workingCopyLocation.validateStagingPackage(at: url, for: workID)
    }

    func installStagingPackage(_ url: URL, for workID: SyncWorkID) throws -> URL {
        try validateRoots()
        let installed = try workingCopyLocation.installStagingPackage(url, for: workID)
        try validateRoots()
        return installed
    }

    func discardStagingPackage(_ url: URL, for workID: SyncWorkID) throws {
        try validateRoots()
        try workingCopyLocation.validateStagingPackage(at: url, for: workID)
        try fileManager.removeItem(at: url)
        try validateRoots()
    }

    func validateInstalledPackage(for workID: SyncWorkID) throws {
        try validateRoots()
        try workingCopyLocation.validateInstalledPackage(for: workID)
    }

    func reserveForPublish(
        workID: SyncWorkID,
        expectedPackage: IOSDeviceSyncLocalPackageAttestation
    ) throws {
        try expectedPackage.validate()
        guard try readRecord(for: workID) == nil,
              try pathStatus(packageURL(for: workID)) == nil else {
            throw IOSDeviceSyncLocalLibraryError.duplicateWork
        }
        try writeRecord(IOSDeviceSyncLocalLibraryRecord(
            workID: workID,
            expectedDocumentID: expectedPackage.documentID,
            state: .reservedForPublish,
            package: expectedPackage,
            acknowledgedRemote: nil,
            pendingRemote: nil
        ))
    }

    func removeLocalWork(workID: SyncWorkID) throws {
        try validateRoots()
        let recordURL = recordURL(for: workID)
        let package = try packageURL(for: workID)
        let staging = try stagingPackageURL(for: workID)
        let hadRecord = try pathStatus(recordURL) != nil
        let hadPackage = try pathStatus(package) != nil
        let hadStaging = try pathStatus(staging) != nil
        guard hadRecord || hadPackage || hadStaging else {
            throw IOSDeviceSyncLocalLibraryError.missingWork
        }
        try workingCopyLocation.removePackages(for: workID)
        if let status = try pathStatus(recordURL) {
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw IOSDeviceSyncLocalLibraryError.invalidRegistry
            }
            try fileManager.removeItem(at: recordURL)
        }
        try validateRoots()
    }

    func abortPublishReservation(workID: SyncWorkID) throws {
        guard let record = try readRecord(for: workID) else { return }
        let staging = try stagingPackageURL(for: workID)
        guard record.state == .reservedForPublish,
              try pathStatus(packageURL(for: workID)) == nil,
              try pathStatus(staging) == nil else {
            throw IOSDeviceSyncLocalLibraryError.invalidTransition
        }
        let url = recordURL(for: workID)
        guard let status = try pathStatus(url), status.st_mode & S_IFMT == S_IFREG else {
            throw IOSDeviceSyncLocalLibraryError.invalidRegistry
        }
        try fileManager.removeItem(at: url)
        try validateRoots()
    }

    func confirmPublishPackage(
        workID: SyncWorkID,
        package: IOSDeviceSyncLocalPackageAttestation
    ) throws {
        try package.validate()
        try validateInstalledPackage(for: workID)
        guard let existing = try readRecord(for: workID),
              existing.state == .reservedForPublish,
              existing.expectedDocumentID == package.documentID,
              existing.package == package else {
            throw IOSDeviceSyncLocalLibraryError.invalidTransition
        }
        try writeRecord(IOSDeviceSyncLocalLibraryRecord(
            workID: workID,
            expectedDocumentID: existing.expectedDocumentID,
            state: .publishPending,
            package: package,
            acknowledgedRemote: nil,
            pendingRemote: nil
        ))
    }

    func beginRemoteOpen(_ remote: SyncWorkLibraryEntry) throws {
        try remote.validate()
        if let existing = try readRecord(for: remote.workID) {
            guard existing.state == .remoteOpenPending,
                  existing.pendingRemote == remote else {
                throw IOSDeviceSyncLocalLibraryError.invalidTransition
            }
            return
        }
        guard try pathStatus(packageURL(for: remote.workID)) == nil else {
            throw IOSDeviceSyncLocalLibraryError.invalidTransition
        }
        try writeRecord(IOSDeviceSyncLocalLibraryRecord(
            workID: remote.workID,
            expectedDocumentID: remote.sourceDocumentID,
            state: .remoteOpenPending,
            package: nil,
            acknowledgedRemote: nil,
            pendingRemote: remote
        ))
    }

    func attestRemotePackage(
        workID: SyncWorkID,
        package: IOSDeviceSyncLocalPackageAttestation,
        expectedRemote: SyncWorkLibraryEntry
    ) throws {
        try package.validate()
        try expectedRemote.validate()
        guard package.matches(expectedRemote), expectedRemote.workID == workID else {
            throw IOSDeviceSyncLocalLibraryError.packageMismatch
        }
        try validateInstalledPackage(for: workID)
        guard let existing = try readRecord(for: workID),
              existing.state == .remoteOpenPending,
              existing.pendingRemote == expectedRemote else {
            throw IOSDeviceSyncLocalLibraryError.invalidTransition
        }
        try writeRecord(IOSDeviceSyncLocalLibraryRecord(
            workID: workID,
            expectedDocumentID: existing.expectedDocumentID,
            state: .remoteOpenPending,
            package: package,
            acknowledgedRemote: nil,
            pendingRemote: expectedRemote
        ))
    }

    func markSynced(workID: SyncWorkID, acknowledgedRemote: SyncWorkLibraryEntry) throws {
        try acknowledgedRemote.validate()
        guard var record = try readRecord(for: workID),
              let package = record.package,
              package.matches(acknowledgedRemote),
              acknowledgedRemote.workID == workID else {
            throw IOSDeviceSyncLocalLibraryError.packageMismatch
        }
        record.state = .synced
        record.acknowledgedRemote = acknowledgedRemote
        record.pendingRemote = nil
        try writeRecord(record)
    }

    func markNeedsReview(workID: SyncWorkID) throws {
        guard var record = try readRecord(for: workID), record.package != nil else {
            throw IOSDeviceSyncLocalLibraryError.missingWork
        }
        record.state = .needsReview
        record.acknowledgedRemote = nil
        record.pendingRemote = nil
        try writeRecord(record)
    }

    func quarantineInstalledPackage(
        workID: SyncWorkID,
        package: IOSDeviceSyncLocalPackageAttestation
    ) throws {
        try package.validate()
        try validateInstalledPackage(for: workID)
        guard let existing = try readRecord(for: workID),
              existing.expectedDocumentID == package.documentID else {
            throw IOSDeviceSyncLocalLibraryError.packageMismatch
        }
        try writeRecord(IOSDeviceSyncLocalLibraryRecord(
            workID: workID,
            expectedDocumentID: existing.expectedDocumentID,
            state: .needsReview,
            package: package,
            acknowledgedRemote: nil,
            pendingRemote: nil
        ))
    }

    func quarantineForAccount(
        workID: SyncWorkID,
        package: IOSDeviceSyncLocalPackageAttestation
    ) throws {
        try package.validate()
        try validateInstalledPackage(for: workID)
        guard let existing = try readRecord(for: workID),
              existing.expectedDocumentID == package.documentID,
              existing.package == package,
              existing.state == .remoteOpenPending else {
            throw IOSDeviceSyncLocalLibraryError.invalidTransition
        }
        try writeRecord(IOSDeviceSyncLocalLibraryRecord(
            workID: workID,
            expectedDocumentID: existing.expectedDocumentID,
            state: .accountQuarantined,
            package: package,
            acknowledgedRemote: nil,
            pendingRemote: existing.pendingRemote
        ))
    }

    func restoreRemoteOpenPending(
        workID: SyncWorkID,
        expectedRemote: SyncWorkLibraryEntry
    ) throws {
        try expectedRemote.validate()
        guard var existing = try readRecord(for: workID),
              existing.state == .accountQuarantined,
              existing.pendingRemote == expectedRemote,
              existing.package?.matches(expectedRemote) == true else {
            throw IOSDeviceSyncLocalLibraryError.invalidTransition
        }
        existing.state = .remoteOpenPending
        try writeRecord(existing)
    }

    func markLegacyPackageRecovered(
        workID: SyncWorkID,
        package: IOSDeviceSyncLocalPackageAttestation
    ) throws {
        try package.validate()
        try validateInstalledPackage(for: workID)
        guard try readRecord(for: workID) == nil else {
            throw IOSDeviceSyncLocalLibraryError.invalidTransition
        }
        try writeRecord(IOSDeviceSyncLocalLibraryRecord(
            workID: workID,
            expectedDocumentID: package.documentID,
            state: .legacyPreserved,
            package: package,
            acknowledgedRemote: nil,
            pendingRemote: nil
        ))
    }

    func recordPackageMutation(
        workID: SyncWorkID,
        package: IOSDeviceSyncLocalPackageAttestation
    ) throws {
        try package.validate()
        try validateInstalledPackage(for: workID)
        guard var record = try readRecord(for: workID),
              record.expectedDocumentID == package.documentID,
              record.state != .reservedForPublish,
              record.state != .remoteOpenPending,
              record.state != .legacyPreserved else {
            throw IOSDeviceSyncLocalLibraryError.invalidTransition
        }
        record.package = package
        record.pendingRemote = nil
        if record.state == .needsReview || record.state == .accountQuarantined {
            record.acknowledgedRemote = nil
        } else if let acknowledged = record.acknowledgedRemote, package.matches(acknowledged) {
            record.state = .synced
        } else {
            record.state = .publishPending
            record.acknowledgedRemote = nil
        }
        try writeRecord(record)
    }

    private func readRecord(for workID: SyncWorkID) throws -> IOSDeviceSyncLocalLibraryRecord? {
        try validateRoots()
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
        try validateRoots()
        return envelope.record
    }

    private func writeRecord(_ record: IOSDeviceSyncLocalLibraryRecord) throws {
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
        try validateRoots()
        guard let status = try pathStatus(url), status.st_mode & S_IFMT == S_IFREG else {
            throw IOSDeviceSyncLocalLibraryError.invalidRegistry
        }
    }

    private func recordURL(for workID: SyncWorkID) -> URL {
        registryRootURL.appendingPathComponent(
            "\(workID.rawValue.uuidString).json",
            isDirectory: false
        )
    }

    private func canonicalWorkID(for url: URL) -> SyncWorkID? {
        guard url.deletingLastPathComponent().standardizedFileURL == registryRootURL,
              url.pathExtension == "json",
              let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
              url.lastPathComponent == "\(uuid.uuidString).json" else { return nil }
        return SyncWorkID(rawValue: uuid)
    }

    private func packageWorkIDs() throws -> Set<SyncWorkID> {
        let urls = try fileManager.contentsOfDirectory(
            at: workingCopyLocation.rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard urls.count <= Self.maximumRecords else {
            throw IOSDeviceSyncLocalLibraryError.invalidRegistry
        }
        var workIDs: Set<SyncWorkID> = []
        for url in urls {
            if let workID = try workingCopyLocation.workID(for: url) {
                workIDs.insert(workID)
            }
        }
        return workIDs
    }

    private func validateRoots() throws {
        var status = stat()
        guard lstat(registryRootURL.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              RootIdentity(status) == registryRootIdentity else {
            throw IOSDeviceSyncLocalLibraryError.unsafeRoot
        }
        do {
            try workingCopyLocation.validateFixedRoot()
        } catch {
            throw IOSDeviceSyncLocalLibraryError.unsafeRoot
        }
    }

    private func pathStatus(_ url: URL) throws -> stat? {
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
