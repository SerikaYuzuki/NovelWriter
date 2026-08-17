import Darwin
import Foundation
import NovelSyncV2

enum IOSPrivateWorkingCopyLocationError: Error, Equatable {
    case unsafeRoot
    case invalidPackageName
    case destinationExists
}

/// Device Sync が扱える iOS app-private package の唯一の場所。
///
/// iOS の sandbox home は `/var` など OS 管理の symlink alias を含み得るため、
/// trusted base だけを一度 canonicalize する。その配下の app 管理 component は
/// symlink を許可せず、Works root の device/inode を process lifetime 中固定する。
final class IOSPrivateWorkingCopyLocation: @unchecked Sendable {
    struct PackageAttestation: Equatable, Sendable {
        let id: IOSPrivateDocumentID
        let url: URL
        fileprivate let identity: Identity
    }

    struct StagingAttestation: Equatable, Sendable {
        let url: URL
        fileprivate let identity: Identity
    }

    fileprivate struct Identity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    let rootURL: URL

    private let trustedBaseURL: URL
    private let relativeRootComponents: [String]
    private let rootIdentity: Identity
    private let fileManager: FileManager

    private init(
        rootURL: URL,
        trustedBaseURL: URL,
        relativeRootComponents: [String],
        rootIdentity: Identity,
        fileManager: FileManager
    ) {
        self.rootURL = rootURL
        self.trustedBaseURL = trustedBaseURL
        self.relativeRootComponents = relativeRootComponents
        self.rootIdentity = rootIdentity
        self.fileManager = fileManager
    }
}

extension IOSPrivateWorkingCopyLocation {
    static func prepareDefault(fileManager: FileManager = .default) throws -> IOSPrivateWorkingCopyLocation {
        // `FileManager.homeDirectoryForCurrentUser` は iOS では unavailable。
        // NSHomeDirectory は process sandbox の報告値だけを返し、後段でこの
        // trusted base を一度だけ canonicalize して app 管理 component を検査する。
        let reportedHome = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        ).standardizedFileURL
        guard let reportedApplicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.standardizedFileURL else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        let expectedApplicationSupport = reportedHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .standardizedFileURL
        guard reportedApplicationSupport.path == expectedApplicationSupport.path else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        return try prepare(
            requestedRootURL: reportedApplicationSupport
                .appendingPathComponent("FUMINIWA", isDirectory: true)
                .appendingPathComponent("Works", isDirectory: true),
            trustedSandboxBaseURL: reportedHome,
            fileManager: fileManager
        )
    }

    /// Test/Preview が明示する library root も、実行環境の private temporary root を
    /// trusted base として同じ検査を通す。production は `prepareDefault` を使う。
    static func prepareInjectedLibraryRoot(
        _ requestedRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> IOSPrivateWorkingCopyLocation {
        try prepare(
            requestedRootURL: requestedRootURL,
            trustedSandboxBaseURL: fileManager.temporaryDirectory,
            fileManager: fileManager
        )
    }

    static func prepare(
        requestedRootURL: URL,
        trustedSandboxBaseURL: URL,
        fileManager: FileManager = .default
    ) throws -> IOSPrivateWorkingCopyLocation {
        let requestedRoot = requestedRootURL.standardizedFileURL
        let reportedBase = trustedSandboxBaseURL.standardizedFileURL
        guard requestedRoot.isFileURL,
              reportedBase.isFileURL,
              requestedRoot.path != "/",
              reportedBase.path != "/" else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }

        let baseComponents = reportedBase.pathComponents
        let requestedComponents = requestedRoot.pathComponents
        guard requestedComponents.count > baseComponents.count,
              Array(requestedComponents.prefix(baseComponents.count)) == baseComponents else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        let relativeComponents = Array(requestedComponents.dropFirst(baseComponents.count))
        guard relativeComponents.allSatisfy(Self.isSafePathComponent) else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }

        // `/var` -> `/private/var` のような OS 管理 alias はここだけで解決する。
        let canonicalBase = reportedBase.resolvingSymlinksInPath().standardizedFileURL
        guard let baseStatus = try pathStatus(canonicalBase),
              baseStatus.st_mode & S_IFMT == S_IFDIR else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        let canonicalRoot = relativeComponents.reduce(canonicalBase) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }.standardizedFileURL

        try validateRelativeComponents(
            from: canonicalBase,
            components: relativeComponents,
            requireAllComponents: false
        )
        try fileManager.createDirectory(at: canonicalRoot, withIntermediateDirectories: true)
        try validateRelativeComponents(
            from: canonicalBase,
            components: relativeComponents,
            requireAllComponents: true
        )
        guard canonicalRoot.resolvingSymlinksInPath().standardizedFileURL.path == canonicalRoot.path,
              let rootStatus = try pathStatus(canonicalRoot),
              rootStatus.st_mode & S_IFMT == S_IFDIR else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }

        return IOSPrivateWorkingCopyLocation(
            rootURL: canonicalRoot,
            trustedBaseURL: canonicalBase,
            relativeRootComponents: relativeComponents,
            rootIdentity: identity(rootStatus),
            fileManager: fileManager
        )
    }

    static func isValidPrivatePackageName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), name.hasSuffix(".novelpkg") else { return false }
        return URL(fileURLWithPath: name).lastPathComponent == name
    }
}

extension IOSPrivateWorkingCopyLocation {
    func validateFixedRoot() throws {
        try Self.validateRelativeComponents(
            from: trustedBaseURL,
            components: relativeRootComponents,
            requireAllComponents: true
        )
        guard rootURL.resolvingSymlinksInPath().standardizedFileURL.path == rootURL.path,
              let status = try Self.pathStatus(rootURL),
              status.st_mode & S_IFMT == S_IFDIR,
              Self.identity(status) == rootIdentity else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
    }

    func destination(for id: IOSPrivateDocumentID) throws -> URL {
        try validateFixedRoot()
        let candidate = try directChildURL(forPackageName: id.packageName, allowsStaging: false)
        guard try Self.pathStatus(candidate) == nil else {
            throw IOSPrivateWorkingCopyLocationError.destinationExists
        }
        try validateFixedRoot()
        return candidate
    }

    /// Cloud libraryの作品はURLをmetadataへ保存せず、WorkIDから常に同じ
    /// app-private packageを導出する。既存packageがあってもURLを返す。
    func packageURL(for workID: WorkID) throws -> URL {
        try validateFixedRoot()
        return try directChildURL(
            forPackageName: "\(workID.rawValue.uuidString).novelpkg",
            allowsStaging: false
        )
    }

    func documentID(for workID: WorkID) -> IOSPrivateDocumentID {
        IOSPrivateDocumentID(packageName: "\(workID.rawValue.uuidString).novelpkg")
    }

    func workID(for packageURL: URL) throws -> WorkID? {
        try validateFixedRoot()
        let requested = packageURL.standardizedFileURL
        guard requested.deletingLastPathComponent() == rootURL,
              requested.pathExtension == "novelpkg",
              let uuid = UUID(uuidString: requested.deletingPathExtension().lastPathComponent),
              requested.lastPathComponent == "\(uuid.uuidString).novelpkg" else { return nil }
        return WorkID(uuid)
    }

    func stagingDestination() throws -> URL {
        try validateFixedRoot()
        let name = ".import-\(UUID().uuidString).novelpkg"
        let candidate = try directChildURL(forPackageName: name, allowsStaging: true)
        guard try Self.pathStatus(candidate) == nil else {
            throw IOSPrivateWorkingCopyLocationError.destinationExists
        }
        try validateFixedRoot()
        return candidate
    }

    func stagingPackageURL(for workID: WorkID) throws -> URL {
        try validateFixedRoot()
        return try directChildURL(
            forPackageName: ".\(workID.rawValue.uuidString).staging.novelpkg",
            allowsStaging: true
        )
    }

    func validateStagingPackage(at url: URL, for workID: WorkID) throws {
        let requested = url.standardizedFileURL
        let expected = rootURL.appendingPathComponent(
            ".\(workID.rawValue.uuidString).staging.novelpkg",
            isDirectory: true
        ).standardizedFileURL
        guard requested == expected else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        _ = try attestStagingPackage(at: requested)
    }

    func installStagingPackage(_ url: URL, for workID: WorkID) throws -> URL {
        try validateStagingPackage(at: url, for: workID)
        let staging = try attestStagingPackage(at: url)
        let finalURL = try packageURL(for: workID)
        guard try Self.pathStatus(finalURL) == nil else {
            throw IOSPrivateWorkingCopyLocationError.destinationExists
        }
        guard renamex_np(url.path, finalURL.path, UInt32(RENAME_EXCL)) == 0 else {
            throw errno == EEXIST
                ? IOSPrivateWorkingCopyLocationError.destinationExists
                : IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        let installed = try attestMovedPackage(at: finalURL, matching: staging)
        try revalidate(installed)
        return finalURL
    }

    /// D-072: this-device copy only. Does not delete CloudKit records.
    func removePackages(for workID: WorkID) throws {
        try validateFixedRoot()
        let staging = try stagingPackageURL(for: workID)
        if try Self.pathStatus(staging) != nil {
            try validateStagingPackage(at: staging, for: workID)
            try fileManager.removeItem(at: staging)
            try validateFixedRoot()
        }
        let final = try packageURL(for: workID)
        if try Self.pathStatus(final) != nil {
            try validateInstalledPackage(for: workID)
            try fileManager.removeItem(at: final)
            try validateFixedRoot()
        }
    }

    func validateInstalledPackage(for workID: WorkID) throws {
        let expected = try packageURL(for: workID)
        let attestation = try attestPackage(at: expected)
        guard attestation.id == documentID(for: workID) else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        try revalidate(attestation)
    }

    func attestPackage(for id: IOSPrivateDocumentID) throws -> PackageAttestation {
        let candidate = try directChildURL(forPackageName: id.packageName, allowsStaging: false)
        return try attestPackage(at: candidate)
    }

    func attestPackage(at packageURL: URL) throws -> PackageAttestation {
        try validateFixedRoot()
        let requested = packageURL.standardizedFileURL
        let id = IOSPrivateDocumentID(packageName: requested.lastPathComponent)
        let expected = try directChildURL(forPackageName: id.packageName, allowsStaging: false)
        guard requested.path == expected.path else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        let packageIdentity = try attestDirectory(at: requested)
        try validateFixedRoot()
        guard try attestDirectory(at: requested) == packageIdentity else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        return PackageAttestation(id: id, url: requested, identity: packageIdentity)
    }

    func attestStagingPackage(at packageURL: URL) throws -> StagingAttestation {
        try validateFixedRoot()
        let requested = packageURL.standardizedFileURL
        let expected = try directChildURL(
            forPackageName: requested.lastPathComponent,
            allowsStaging: true
        )
        guard requested.path == expected.path else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        let packageIdentity = try attestDirectory(at: requested)
        try validateFixedRoot()
        guard try attestDirectory(at: requested) == packageIdentity else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        return StagingAttestation(url: requested, identity: packageIdentity)
    }

    func attestMovedPackage(
        at packageURL: URL,
        matching staging: StagingAttestation
    ) throws -> PackageAttestation {
        let attestation = try attestPackage(at: packageURL)
        guard attestation.identity == staging.identity else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        return attestation
    }

    func revalidate(_ attestation: PackageAttestation) throws {
        let current = try attestPackage(for: attestation.id)
        guard current.url.path == attestation.url.path,
              current.identity == attestation.identity else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
    }

    func revalidate(_ attestation: StagingAttestation) throws {
        let current = try attestStagingPackage(at: attestation.url)
        guard current.identity == attestation.identity else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
    }

    func performWithAttestedPackage<Result: Sendable>(
        for id: IOSPrivateDocumentID,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let attestation = try attestPackage(for: id)
        do {
            let result = try await operation()
            try revalidate(attestation)
            return result
        } catch {
            do {
                try revalidate(attestation)
            } catch {
                throw IOSPrivateWorkingCopyLocationError.unsafeRoot
            }
            throw error
        }
    }

    func removeOwnedItemIfSafe(at itemURL: URL, allowsStaging: Bool) {
        guard (try? validateFixedRoot()) != nil,
              let expected = try? directChildURL(
                  forPackageName: itemURL.lastPathComponent,
                  allowsStaging: allowsStaging
              ),
              expected.path == itemURL.standardizedFileURL.path else { return }
        try? fileManager.removeItem(at: expected)
    }
}

private extension IOSPrivateWorkingCopyLocation {
    func directChildURL(forPackageName name: String, allowsStaging: Bool) throws -> URL {
        let validName = if allowsStaging {
            (name.hasPrefix(".import-") || name.hasSuffix(".staging.novelpkg"))
                && name.hasPrefix(".")
                && name.hasSuffix(".novelpkg")
                && URL(fileURLWithPath: name).lastPathComponent == name
        } else {
            Self.isValidPrivatePackageName(name)
        }
        guard validName else {
            throw IOSPrivateWorkingCopyLocationError.invalidPackageName
        }
        let candidate = rootURL.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == rootURL.path else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        return candidate
    }

    private func attestDirectory(at url: URL) throws -> Identity {
        guard let initial = try Self.pathStatus(url),
              initial.st_mode & S_IFMT == S_IFDIR,
              url.resolvingSymlinksInPath().standardizedFileURL.path == url.path else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        let initialIdentity = Self.identity(initial)
        guard let final = try Self.pathStatus(url),
              final.st_mode & S_IFMT == S_IFDIR,
              Self.identity(final) == initialIdentity else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        return initialIdentity
    }

    private static func validateRelativeComponents(
        from trustedBaseURL: URL,
        components: [String],
        requireAllComponents: Bool
    ) throws {
        var current = trustedBaseURL
        for component in components {
            current.appendPathComponent(component, isDirectory: true)
            guard let status = try pathStatus(current) else {
                if requireAllComponents {
                    throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                }
                return
            }
            guard status.st_mode & S_IFMT == S_IFDIR else {
                throw IOSPrivateWorkingCopyLocationError.unsafeRoot
            }
        }
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "/"
            && component != "."
            && component != ".."
            && URL(fileURLWithPath: component).lastPathComponent == component
    }

    private static func identity(_ status: stat) -> Identity {
        Identity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    private static func pathStatus(_ url: URL) throws -> stat? {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            return status
        }
        guard errno == ENOENT else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        return nil
    }
}
