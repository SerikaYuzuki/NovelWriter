import Darwin
import Foundation
import NovelCore
import NovelLibrary
import NovelSync

/// Cloud accountに依存しないapp-private working-copy inventory。
/// URLは保存せず、WorkIDから固定package名を毎回導出する。
actor IOSDeviceSyncLocalLibraryStore {
    private static let maximumRecords = 20000

    private let registry: IOSDeviceSyncLocalLibraryRegistry
    private let workingCopyLocation: IOSPrivateWorkingCopyLocation
    private let fileManager: FileManager

    init(
        registryRootURL: URL,
        trustedAncestorURL: URL,
        workingCopyLocation: IOSPrivateWorkingCopyLocation,
        fileManager: FileManager = .default
    ) throws {
        registry = try IOSDeviceSyncLocalLibraryRegistry(
            registryRootURL,
            trustedAncestorURL: trustedAncestorURL,
            fileManager: fileManager
        )
        self.workingCopyLocation = workingCopyLocation
        self.fileManager = fileManager
    }

    func inventory() throws -> IOSDeviceSyncLocalLibraryInventory {
        try validateRoots()
        let urls = try fileManager.contentsOfDirectory(
            at: registry.rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard urls.count <= Self.maximumRecords else {
            throw IOSDeviceSyncLocalLibraryError.invalidRegistry
        }
        var records: [IOSDeviceSyncLocalLibraryRecord] = []
        var unreadable: Set<SyncWorkID> = []
        for url in urls {
            guard let workID = registry.canonicalWorkID(for: url) else { continue }
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
        let unregistered = try registry.packageWorkIDs(
            using: workingCopyLocation,
            fileManager: fileManager
        ).subtracting(registered)
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
              try registry.pathStatus(packageURL(for: workID)) == nil else {
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
        let recordURL = registry.recordURL(for: workID)
        let package = try packageURL(for: workID)
        let staging = try stagingPackageURL(for: workID)
        let hadRecord = try registry.pathStatus(recordURL) != nil
        let hadPackage = try registry.pathStatus(package) != nil
        let hadStaging = try registry.pathStatus(staging) != nil
        guard hadRecord || hadPackage || hadStaging else {
            throw IOSDeviceSyncLocalLibraryError.missingWork
        }
        try workingCopyLocation.removePackages(for: workID)
        if let status = try registry.pathStatus(recordURL) {
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
              try registry.pathStatus(packageURL(for: workID)) == nil,
              try registry.pathStatus(staging) == nil else {
            throw IOSDeviceSyncLocalLibraryError.invalidTransition
        }
        let url = registry.recordURL(for: workID)
        guard let status = try registry.pathStatus(url), status.st_mode & S_IFMT == S_IFREG else {
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
        guard try registry.pathStatus(packageURL(for: remote.workID)) == nil else {
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
        let record = try registry.readRecord(for: workID)
        try validateRoots()
        return record
    }

    private func writeRecord(_ record: IOSDeviceSyncLocalLibraryRecord) throws {
        try registry.writeRecord(record)
        try validateRoots()
    }

    private func validateRoots() throws {
        try registry.validateRoot()
        do {
            try workingCopyLocation.validateFixedRoot()
        } catch {
            throw IOSDeviceSyncLocalLibraryError.unsafeRoot
        }
    }
}
