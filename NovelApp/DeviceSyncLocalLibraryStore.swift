import Darwin
import Foundation
import NovelCore
import NovelSync

enum DeviceSyncLocalLibraryError: Error, Equatable, Sendable {
    case unsafeRoot
    case invalidRegistry
    case duplicateWork
    case missingWork
    case invalidTransition
    case packageMismatch
}

enum DeviceSyncLocalLibraryState: String, Codable, Hashable, Sendable {
    /// work identityを先に確保し、package installが未完了の状態。
    case reservedForPublish
    /// packageはreadback済み。remote create/初回publishは未確認。
    case publishPending
    /// exact remote headを最後に確認した状態。表示時にはpackageを再readbackする。
    case synced
    /// exact remote headを取得する前に、再開可能なdownload intentを保存した状態。
    case remoteOpenPending
    /// packageは安全に読めるが、remoteとの差分を自動採用してはいけない状態。
    case needsReview
}

struct DeviceSyncLocalPackageAttestation: Codable, Hashable, Sendable {
    let documentID: UUID
    let structureDigest: SyncWorkStructureDigest
    let snapshotDigest: SyncContentDigest
    let snapshotByteCount: Int
    let titleProjection: String
    let titleDigest: SyncContentDigest
    let fullTitleUTF8ByteCount: Int
    let updatedAt: Date

    init(document: NovelDocument, updatedAt: Date) throws {
        let snapshot = try WorkSnapshot(document: document)
        let canonical = try WorkCanonicalJSON.encodeSnapshot(snapshot)
        documentID = document.id
        structureDigest = try SyncWorkStructureDigest(chapters: document.chapters)
        // Digest input is the already-validated canonical UTF-8 byte sequence.
        // swiftlint:disable:next optional_data_string_conversion
        snapshotDigest = SyncContentDigest(content: String(decoding: canonical, as: UTF8.self))
        snapshotByteCount = canonical.count
        titleProjection = SyncWorkLibraryEntry.displayTitleProjection(document.title)
        titleDigest = SyncContentDigest(content: document.title)
        fullTitleUTF8ByteCount = document.title.utf8.count
        self.updatedAt = updatedAt
        try validate()
    }

    func validate() throws {
        guard snapshotByteCount >= 0,
              snapshotByteCount <= WorkSnapshot.maximumCanonicalByteCount,
              titleProjection.utf8.count <= SyncWorkLibraryEntry.maximumDisplayTitleUTF8Bytes,
              fullTitleUTF8ByteCount >= titleProjection.utf8.count,
              fullTitleUTF8ByteCount <= WorkSnapshot.maximumStringUTF8Bytes,
              updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DeviceSyncLocalLibraryError.invalidRegistry
        }
    }

    func matches(_ remote: SyncWorkLibraryEntry) -> Bool {
        documentID == remote.sourceDocumentID
            && structureDigest == remote.structureDigest
            && snapshotDigest == remote.headSnapshotDigest
            && snapshotByteCount == remote.headSnapshotByteCount
            && titleDigest == remote.titleDigest
            && fullTitleUTF8ByteCount == remote.fullTitleUTF8ByteCount
    }
}

struct DeviceSyncLocalLibraryRecord: Codable, Hashable, Sendable, Identifiable {
    var id: SyncWorkID {
        workID
    }

    let workID: SyncWorkID
    let expectedDocumentID: UUID
    var state: DeviceSyncLocalLibraryState
    var package: DeviceSyncLocalPackageAttestation?
    /// `.synced`の意味をremote catalogの現在値へ勝手に拡張しないためのexact ack。
    var acknowledgedRemote: SyncWorkLibraryEntry?
    /// remote downloadを再開する際のexact head。nil-head descriptorは保存しない。
    var pendingRemote: SyncWorkLibraryEntry?

    func validate() throws {
        try package?.validate()
        try acknowledgedRemote?.validate()
        try pendingRemote?.validate()
        guard package?.documentID == nil || package?.documentID == expectedDocumentID else {
            throw DeviceSyncLocalLibraryError.invalidRegistry
        }
        try validateState()
    }

    private func validateState() throws {
        switch state {
        case .reservedForPublish:
            guard package != nil, acknowledgedRemote == nil, pendingRemote == nil else {
                throw DeviceSyncLocalLibraryError.invalidRegistry
            }
        case .publishPending:
            guard package != nil, acknowledgedRemote == nil, pendingRemote == nil else {
                throw DeviceSyncLocalLibraryError.invalidRegistry
            }
        case .synced:
            guard let package, let acknowledgedRemote,
                  pendingRemote == nil,
                  acknowledgedRemote.workID == workID,
                  package.matches(acknowledgedRemote) else {
                throw DeviceSyncLocalLibraryError.invalidRegistry
            }
        case .remoteOpenPending:
            guard acknowledgedRemote == nil,
                  let pendingRemote,
                  pendingRemote.workID == workID,
                  pendingRemote.sourceDocumentID == expectedDocumentID,
                  pendingRemote.headRevisionID != nil,
                  package == nil || package?.matches(pendingRemote) == true else {
                throw DeviceSyncLocalLibraryError.invalidRegistry
            }
        case .needsReview:
            guard package != nil, pendingRemote == nil else {
                throw DeviceSyncLocalLibraryError.invalidRegistry
            }
        }
    }
}

struct DeviceSyncLocalLibraryInventory: Sendable {
    let records: [DeviceSyncLocalLibraryRecord]
    /// 一つの壊れたrecordが他の作品を棚から消さない。canonical filenameから
    /// work identityだけを回収し、その行だけをunsafeとして扱う。
    let unreadableWorkIDs: Set<SyncWorkID>
    /// recordだけが失われたpackageを空棚として黙殺しない。自動でremote identityへ
    /// 再接続せず、作品ごとの復旧対象としてdisabled表示する。
    let unregisteredPackageWorkIDs: Set<SyncWorkID>
}

#if canImport(NovelSyncCloudKit) && !FUMINIWA_ENABLE_EXPERIMENTAL_AI
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
        guard remote.headRevisionID != nil else {
            throw DeviceSyncLocalLibraryError.invalidRegistry
        }
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
