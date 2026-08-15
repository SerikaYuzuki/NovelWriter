import Darwin
import Foundation
import NovelCore
import NovelLibrary
import NovelSync

typealias DeviceSyncLocalLibraryError = LibraryRegistryError
typealias DeviceSyncLocalLibraryState = LibraryRecordState
typealias DeviceSyncLocalPackageAttestation = LocalPackageAttestation
typealias DeviceSyncLocalLibraryRecord = LibraryRecord
typealias DeviceSyncLocalLibraryInventory = LibraryInventory
#if canImport(NovelSyncCloudKit)
/// CloudKit accountに依存しない、app-private working copyの耐久inventory。
/// URLは保存せず`workID -> SyncWorkingCopies-v2/<workID>.novelpkg`から導出する。
actor DeviceSyncLocalLibraryStore {
    private struct RecordEnvelope: Codable {
        static let currentVersion = 1

        let version: Int
        let record: DeviceSyncLocalLibraryRecord
    }

    private static let maximumRecordBytes = 2 * 1024 * 1024
    private static let maximumRecords = 20000

    private let registryRootURL: URL
    private let registryRootIdentity: FileDeviceSyncMergeRecoveryStore.RootIdentity
    private let workingCopyRoot: DeviceSyncPrivateWorkingCopyRoot
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(
        registryRootURL: URL,
        trustedAncestorURL: URL,
        workingCopyRoot: DeviceSyncPrivateWorkingCopyRoot,
        fileManager: FileManager = .default
    ) throws {
        let prepared = try FileDeviceSyncMergeRecoveryStore.prepareAnchoredRoot(
            registryRootURL,
            trustedAncestorURL: trustedAncestorURL,
            fileManager: fileManager
        )
        self.registryRootURL = prepared.url
        registryRootIdentity = prepared.identity
        self.workingCopyRoot = workingCopyRoot
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func inventory() throws -> DeviceSyncLocalLibraryInventory {
        try validateRoots()
        let urls = try fileManager.contentsOfDirectory(
            at: registryRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard urls.count <= Self.maximumRecords else {
            throw DeviceSyncLocalLibraryError.invalidRegistry
        }
        var records: [DeviceSyncLocalLibraryRecord] = []
        var unreadable: Set<SyncWorkID> = []
        for url in urls {
            guard let workID = canonicalWorkID(for: url) else { continue }
            do {
                let record = try readRecord(for: workID)
                guard let record else {
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
        return DeviceSyncLocalLibraryInventory(
            records: records,
            unreadableWorkIDs: unreadable,
            unregisteredPackageWorkIDs: unregistered
        )
    }

    func record(for workID: SyncWorkID) throws -> DeviceSyncLocalLibraryRecord? {
        try readRecord(for: workID)
    }

    func packageURL(for workID: SyncWorkID) throws -> URL {
        try validateRoots()
        return try workingCopyRoot.destination(for: workID)
    }

    func workID(for packageURL: URL) throws -> SyncWorkID? {
        try validateRoots()
        return try workingCopyRoot.workID(for: packageURL)
    }

    func stagingPackageURL(for workID: SyncWorkID) throws -> URL {
        try validateRoots()
        return try workingCopyRoot.stagingDestination(for: workID)
    }

    func validateStagingPackage(at url: URL, for workID: SyncWorkID) throws {
        try validateRoots()
        try workingCopyRoot.validateStagingPackage(at: url, for: workID)
    }

    func installStagingPackage(_ url: URL, for workID: SyncWorkID) throws -> URL {
        try validateRoots()
        let installed = try workingCopyRoot.installStagingPackage(url, for: workID)
        try validateRoots()
        return installed
    }

    func discardStagingPackage(_ url: URL, for workID: SyncWorkID) throws {
        try validateRoots()
        try workingCopyRoot.validateStagingPackage(at: url, for: workID)
        try fileManager.removeItem(at: url)
        try validateRoots()
    }

    func validateInstalledPackage(for workID: SyncWorkID) throws {
        let url = try packageURL(for: workID)
        try workingCopyRoot.validateCopiedPackage(at: url, for: workID)
    }

    func reserveForPublish(
        workID: SyncWorkID,
        expectedPackage: DeviceSyncLocalPackageAttestation
    ) throws {
        try expectedPackage.validate()
        guard try readRecord(for: workID) == nil else {
            throw DeviceSyncLocalLibraryError.duplicateWork
        }
        guard try pathStatus(packageURL(for: workID)) == nil else {
            throw DeviceSyncLocalLibraryError.duplicateWork
        }
        try writeRecord(
            DeviceSyncLocalLibraryRecord(
                workID: workID,
                expectedDocumentID: expectedPackage.documentID,
                state: .reservedForPublish,
                // package bytes are not installed yet. Persisting the expected
                // canonical attestation before staging prevents a killed writer
                // from later adopting an arbitrary same-document-ID package.
                package: expectedPackage,
                acknowledgedRemote: nil,
                pendingRemote: nil
            )
        )
    }

    /// A failed new/import may remove only its empty reservation. Any staging or
    /// final package keeps the record as recovery evidence and fails closed.
    /// Removes this device's registry record and hidden package. CloudKit
    /// records stay; a synced work may reappear as remote-only.
    func removeLocalWork(workID: SyncWorkID) throws {
        try validateRoots()
        let recordURL = recordURL(for: workID)
        let package = try packageURL(for: workID)
        let staging = try stagingPackageURL(for: workID)
        let hadRecord = try pathStatus(recordURL) != nil
        let hadPackage = try pathStatus(package) != nil
        let hadStaging = try pathStatus(staging) != nil
        guard hadRecord || hadPackage || hadStaging else {
            throw DeviceSyncLocalLibraryError.missingWork
        }
        try workingCopyRoot.removePackages(for: workID, fileManager: fileManager)
        if let status = try pathStatus(recordURL) {
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw DeviceSyncLocalLibraryError.invalidRegistry
            }
            try fileManager.removeItem(at: recordURL)
        }
        try validateRoots()
    }

    func abortPublishReservation(workID: SyncWorkID) throws {
        try validateRoots()
        guard let record = try readRecord(for: workID) else { return }
        guard record.state == .reservedForPublish,
              try pathStatus(packageURL(for: workID)) == nil,
              try pathStatus(stagingPackageURL(for: workID)) == nil else {
            throw DeviceSyncLocalLibraryError.invalidTransition
        }
        let url = recordURL(for: workID)
        guard let status = try pathStatus(url), status.st_mode & S_IFMT == S_IFREG else {
            throw DeviceSyncLocalLibraryError.invalidRegistry
        }
        try fileManager.removeItem(at: url)
        try validateRoots()
    }

    func beginRemoteOpen(_ remote: SyncWorkLibraryEntry) throws {
        try remote.validate()
        if let existing = try readRecord(for: remote.workID) {
            if existing.state == .remoteOpenPending, existing.pendingRemote == remote {
                return
            }
            throw DeviceSyncLocalLibraryError.invalidTransition
        } else {
            let finalURL = try packageURL(for: remote.workID)
            guard try pathStatus(finalURL) == nil else {
                throw DeviceSyncLocalLibraryError.invalidTransition
            }
            try writeRecord(
                DeviceSyncLocalLibraryRecord(
                    workID: remote.workID,
                    expectedDocumentID: remote.sourceDocumentID,
                    state: .remoteOpenPending,
                    package: nil,
                    acknowledgedRemote: nil,
                    pendingRemote: remote
                )
            )
        }
    }

    func confirmPublishPackage(
        workID: SyncWorkID,
        package: DeviceSyncLocalPackageAttestation
    ) throws {
        try package.validate()
        try validateInstalledPackage(for: workID)
        guard let existing = try readRecord(for: workID) else {
            throw DeviceSyncLocalLibraryError.missingWork
        }
        guard existing.state == .reservedForPublish,
              existing.expectedDocumentID == package.documentID,
              existing.package == package else {
            throw DeviceSyncLocalLibraryError.invalidTransition
        }
        try writeRecord(DeviceSyncLocalLibraryRecord(
            workID: workID,
            expectedDocumentID: existing.expectedDocumentID,
            state: .publishPending,
            package: package,
            acknowledgedRemote: nil,
            pendingRemote: nil
        ))
    }

    /// staging readback exactをfinal renameより先にregistryへ書く。
    func attestPublishStaging(
        workID: SyncWorkID,
        package: DeviceSyncLocalPackageAttestation
    ) throws {
        try package.validate()
        let staging = try stagingPackageURL(for: workID)
        try validateStagingPackage(at: staging, for: workID)
        guard var existing = try readRecord(for: workID),
              existing.state == .reservedForPublish,
              existing.expectedDocumentID == package.documentID,
              existing.package == nil || existing.package == package else {
            throw DeviceSyncLocalLibraryError.invalidTransition
        }
        existing.package = package
        try writeRecord(existing)
    }

    func confirmRemotePackage(
        workID: SyncWorkID,
        package: DeviceSyncLocalPackageAttestation,
        acknowledgedRemote: SyncWorkLibraryEntry
    ) throws {
        try package.validate()
        try acknowledgedRemote.validate()
        guard package.matches(acknowledgedRemote), acknowledgedRemote.workID == workID else {
            throw DeviceSyncLocalLibraryError.packageMismatch
        }
        try validateInstalledPackage(for: workID)
        guard let existing = try readRecord(for: workID) else {
            throw DeviceSyncLocalLibraryError.missingWork
        }
        guard existing.state == .remoteOpenPending,
              existing.pendingRemote == acknowledgedRemote else {
            throw DeviceSyncLocalLibraryError.invalidTransition
        }
        try writeRecord(DeviceSyncLocalLibraryRecord(
            workID: workID,
            expectedDocumentID: package.documentID,
            state: .synced,
            package: package,
            acknowledgedRemote: acknowledgedRemote,
            pendingRemote: nil
        ))
    }

    /// packageのatomic install/readbackをremote bindより先に耐久化する。
    /// この直後に終了しても、次回locallyBound＋exact headなら安全にsyncedへ昇格できる。
    func attestRemotePackage(
        workID: SyncWorkID,
        package: DeviceSyncLocalPackageAttestation,
        expectedRemote: SyncWorkLibraryEntry
    ) throws {
        try package.validate()
        try expectedRemote.validate()
        guard package.matches(expectedRemote), expectedRemote.workID == workID else {
            throw DeviceSyncLocalLibraryError.packageMismatch
        }
        try validateInstalledPackage(for: workID)
        guard let existing = try readRecord(for: workID),
              existing.state == .remoteOpenPending,
              existing.pendingRemote == expectedRemote else {
            throw DeviceSyncLocalLibraryError.invalidTransition
        }
        try writeRecord(DeviceSyncLocalLibraryRecord(
            workID: workID,
            expectedDocumentID: package.documentID,
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
            throw DeviceSyncLocalLibraryError.packageMismatch
        }
        record.state = .synced
        record.acknowledgedRemote = acknowledgedRemote
        record.pendingRemote = nil
        try writeRecord(record)
    }

    func markNeedsReview(workID: SyncWorkID) throws {
        guard var record = try readRecord(for: workID), record.package != nil else {
            throw DeviceSyncLocalLibraryError.missingWork
        }
        record.state = .needsReview
        record.pendingRemote = nil
        try writeRecord(record)
    }

    /// final packageがpending revisionと一致しない場合は絶対にoverwriteせず、
    /// 端末内copyをreview対象としてdurableに隔離する。
    func quarantineInstalledPackage(
        workID: SyncWorkID,
        package: DeviceSyncLocalPackageAttestation
    ) throws {
        try package.validate()
        try validateInstalledPackage(for: workID)
        guard let existing = try readRecord(for: workID),
              existing.expectedDocumentID == package.documentID else {
            throw DeviceSyncLocalLibraryError.packageMismatch
        }
        try writeRecord(DeviceSyncLocalLibraryRecord(
            workID: workID,
            expectedDocumentID: existing.expectedDocumentID,
            state: .needsReview,
            package: package,
            acknowledgedRemote: nil,
            pendingRemote: nil
        ))
    }

    /// すべてのatomic package save後、work journal confirmより先に呼ぶ。
    /// remote ackと同一snapshotの再保存だけはsyncedを維持し、変更があれば
    /// exact checkmarkを即座に取り下げる。
    func recordPackageMutation(
        workID: SyncWorkID,
        package: DeviceSyncLocalPackageAttestation
    ) throws {
        try package.validate()
        try validateInstalledPackage(for: workID)
        guard var record = try readRecord(for: workID),
              record.expectedDocumentID == package.documentID,
              record.state != .reservedForPublish,
              record.state != .remoteOpenPending else {
            throw DeviceSyncLocalLibraryError.invalidTransition
        }
        record.package = package
        record.pendingRemote = nil
        if record.state == .needsReview {
            record.acknowledgedRemote = nil
        } else if let acknowledged = record.acknowledgedRemote, package.matches(acknowledged) {
            record.state = .synced
        } else {
            record.state = .publishPending
            record.acknowledgedRemote = nil
        }
        try writeRecord(record)
    }

    private func readRecord(for workID: SyncWorkID) throws -> DeviceSyncLocalLibraryRecord? {
        try validateRoots()
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
        try validateRoots()
        return envelope.record
    }

    private func writeRecord(_ record: DeviceSyncLocalLibraryRecord) throws {
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
        try validateRoots()
        guard let status = try pathStatus(url), status.st_mode & S_IFMT == S_IFREG else {
            throw DeviceSyncLocalLibraryError.invalidRegistry
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
            at: workingCopyRoot.url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard urls.count <= Self.maximumRecords else {
            throw DeviceSyncLocalLibraryError.invalidRegistry
        }
        return Set(urls.compactMap { url in
            guard url.deletingLastPathComponent().standardizedFileURL == workingCopyRoot.url,
                  url.pathExtension == "novelpkg",
                  let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  url.lastPathComponent == "\(uuid.uuidString).novelpkg" else { return nil }
            return SyncWorkID(rawValue: uuid)
        })
    }

    private func validateRoots() throws {
        var status = stat()
        guard lstat(registryRootURL.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              FileDeviceSyncMergeRecoveryStore.RootIdentity(status) == registryRootIdentity else {
            throw DeviceSyncLocalLibraryError.unsafeRoot
        }
        do {
            try workingCopyRoot.validateFixedRoot()
        } catch {
            throw DeviceSyncLocalLibraryError.unsafeRoot
        }
    }

    private func pathStatus(_ url: URL) throws -> stat? {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            return status
        }
        guard errno == ENOENT else { throw DeviceSyncLocalLibraryError.invalidRegistry }
        return nil
    }
}
#endif
