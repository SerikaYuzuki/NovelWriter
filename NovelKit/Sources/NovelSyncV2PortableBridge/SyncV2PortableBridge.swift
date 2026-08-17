import Foundation
import NovelCore
import NovelStorage
import NovelSyncV2

/// A validated, portable projection that a caller may pass to a v2 checkpoint.
///
/// This value deliberately has no URL, package, WorkID, or runtime-store
/// identity. Importing a package therefore cannot make the package itself the
/// local authority; the caller explicitly chooses the v2 WorkID and checkpoint
/// reason afterwards.
public struct SyncV2PortableImport: Sendable {
    public let document: NovelDocument
    public let attachments: [SyncAttachment]

    public init(document: NovelDocument, attachments: [SyncAttachment]) {
        self.document = document
        self.attachments = attachments
    }
}

/// Errors raised by the explicit v2 portable boundary.
public enum SyncV2PortableBridgeError: Error, Equatable, Sendable {
    case invalidPackage
    case symbolicLink(relativePath: String)
    case unsupportedAttachmentItem(relativePath: String)
    case invalidAttachmentName(String)
    case attachmentNameCollision(String)
    case attachmentMissing(String)
    case attachmentUnreadable(String)
    case attachmentByteCountMismatch(String)
    case documentChangedDuringTransfer
    case destinationExists
    case invalidDestination
    case exportReadBackMismatch(String)
}

extension SyncV2PortableBridgeError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidPackage:
            "作品パッケージを検証できません。"
        case let .symbolicLink(path):
            "symbolic link は取り込めません: \(path)"
        case let .unsupportedAttachmentItem(path):
            "添付資料は通常ファイルである必要があります: \(path)"
        case let .invalidAttachmentName(name):
            "添付資料名が portable 形式ではありません: \(name)"
        case let .attachmentNameCollision(name):
            "添付資料名が衝突しています: \(name)"
        case let .attachmentMissing(name):
            "添付資料が見つかりません: \(name)"
        case let .attachmentUnreadable(name):
            "添付資料を読み込めません: \(name)"
        case let .attachmentByteCountMismatch(name):
            "添付資料のサイズが変わりました: \(name)"
        case .documentChangedDuringTransfer:
            "作品パッケージの検証中に内容が変わりました。"
        case .destinationExists:
            "書き出し先は新しい .novelpkg である必要があります。"
        case .invalidDestination:
            "書き出し先を利用できません。"
        case let .exportReadBackMismatch(name):
            "書き出した資料を検証できません: \(name)"
        }
    }
}

/// The only bridge between the v2 SQLite projection and `.novelpkg`.
///
/// The bridge is intentionally an explicit service. It is not used by the v2
/// runtime, checkpoint worker, or autosave path. Package bytes are read only
/// during `importExplicitPackage` and written only during
/// `exportExplicitPackage`.
public struct SyncV2PortableBridge: Sendable {
    private let repository: any PortableDocumentPackageRepository & AttachmentManaging

    public init(
        repository: any PortableDocumentPackageRepository & AttachmentManaging = NovelpkgRepository()
    ) {
        self.repository = repository
    }

    /// Validates and reads a package without changing it or any v2 state.
    public func importExplicitPackage(from packageURL: URL) async throws -> SyncV2PortableImport {
        guard packageURL.pathExtension == "novelpkg" else {
            throw SyncV2PortableBridgeError.invalidPackage
        }

        let document: NovelDocument
        do {
            document = try await repository.validatePortablePackage(at: packageURL)
        } catch let error as NovelpkgPortableTransferError {
            throw map(error)
        }

        let payloads: [PortableAttachmentPayload]
        do {
            payloads = try await repository.readValidatedAttachments(in: packageURL)
        } catch let error as NovelpkgPortableTransferError {
            throw map(error)
        }
        let attachments = payloads.map { payload in
            SyncAttachment(
                attachmentId: Self.stableAttachmentID(for: payload.fileName),
                fileName: payload.fileName,
                bytes: payload.bytes
            )
        }

        // A package can be replaced by another process between the repository
        // validation and attachment reads. Revalidate the logical document so
        // callers never checkpoint a mixed package projection.
        do {
            let reread = try await repository.validatePortablePackage(at: packageURL)
            guard reread == document else {
                throw SyncV2PortableBridgeError.documentChangedDuringTransfer
            }
        } catch let error as NovelpkgPortableTransferError {
            throw map(error)
        }

        return SyncV2PortableImport(document: document, attachments: attachments)
    }

    /// Exports a committed v2 projection to a new `.novelpkg`.
    ///
    /// The destination must not exist. The document is first written to a
    /// private temporary package, every attachment is read back byte-for-byte,
    /// and only then is the validated package atomically adopted at the
    /// destination. A failure before adoption leaves the destination absent or
    /// untouched.
    public func exportExplicitPackage(
        document: NovelDocument,
        attachments: [SyncAttachment],
        to destinationURL: URL
    ) async throws {
        try validateDestination(destinationURL)
        try validateAttachmentValues(attachments)

        let fileManager = FileManager.default
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("FUMINIWA-SnapshotSyncV2-Export-\(UUID().uuidString)", isDirectory: true)
        let stagingURL = stagingRoot.appendingPathComponent("export.novelpkg", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        do {
            try await repository.save(document, to: stagingURL)
            for attachment in sortedAttachments(attachments) {
                let sourceURL = stagingRoot
                    .appendingPathComponent("sources", isDirectory: true)
                    .appendingPathComponent(attachment.fileName)
                try fileManager.createDirectory(
                    at: sourceURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                do {
                    try attachment.bytes.write(to: sourceURL, options: .atomic)
                } catch {
                    throw SyncV2PortableBridgeError.attachmentUnreadable(attachment.fileName)
                }

                let added = try await repository.addAttachment(from: sourceURL, to: stagingURL)
                guard added.fileName == attachment.fileName else {
                    throw SyncV2PortableBridgeError.attachmentNameCollision(attachment.fileName)
                }
            }

            let staged = try await importExplicitPackage(from: stagingURL)
            try verify(staged, document: document, attachments: attachments)

            // saveValidatedCopy performs a final tree validation and atomic
            // adoption. It is reached only after all source bytes are proven.
            try await repository.saveValidatedCopy(
                document,
                from: stagingURL,
                to: destinationURL
            )

            let exported = try await importExplicitPackage(from: destinationURL)
            try verify(exported, document: document, attachments: attachments)
        } catch let error as SyncV2PortableBridgeError {
            throw error
        } catch let error as NovelpkgPortableTransferError {
            throw map(error)
        } catch {
            throw SyncV2PortableBridgeError.invalidPackage
        }
    }
}

private extension SyncV2PortableBridge {
    /// Stable IDs are derived only from the portable filename. No package URL,
    /// random UUID, or runtime WorkID participates in the identity.
    static func stableAttachmentID(for fileName: String) -> UUID {
        let seed = Data("fuminiwa.snapshot-sync-v2.attachment-id\0".utf8)
            + Data(fileName.utf8)
        let hex = SHA256Digest.hex(seed)
        let groups = [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12))
        ]
        return UUID(uuidString: groups.joined(separator: "-"))!
    }

    static func portableNameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    func validateAttachmentName(_ name: String) throws {
        guard !name.isEmpty,
              !name.contains("\0"),
              !name.contains("/"),
              !name.contains("\\"),
              name != ".",
              name != "..",
              URL(fileURLWithPath: name).lastPathComponent == name else {
            throw SyncV2PortableBridgeError.invalidAttachmentName(name)
        }
    }

    func validateAttachmentValues(_ attachments: [SyncAttachment]) throws {
        var names: Set<String> = []
        for attachment in attachments {
            try validateAttachmentName(attachment.fileName)
            let key = Self.portableNameKey(attachment.fileName)
            guard names.insert(key).inserted else {
                throw SyncV2PortableBridgeError.attachmentNameCollision(attachment.fileName)
            }
        }
    }

    func sortedAttachments(_ attachments: [SyncAttachment]) -> [SyncAttachment] {
        attachments.sorted { lhs, rhs in
            let left = Self.portableNameKey(lhs.fileName)
            let right = Self.portableNameKey(rhs.fileName)
            if left != right {
                return left < right
            }
            return lhs.fileName.utf8.lexicographicallyPrecedes(rhs.fileName.utf8)
        }
    }

    func verify(
        _ actual: SyncV2PortableImport,
        document: NovelDocument,
        attachments expected: [SyncAttachment]
    ) throws {
        guard actual.document == document else {
            throw SyncV2PortableBridgeError.exportReadBackMismatch("document")
        }
        let expectedByName = Dictionary(uniqueKeysWithValues: expected.map { ($0.fileName, $0.bytes) })
        let actualByName = Dictionary(uniqueKeysWithValues: actual.attachments.map { ($0.fileName, $0.bytes) })
        guard expectedByName.count == actualByName.count else {
            throw SyncV2PortableBridgeError.exportReadBackMismatch("attachments")
        }
        for (name, bytes) in expectedByName {
            guard actualByName[name] == bytes else {
                throw SyncV2PortableBridgeError.exportReadBackMismatch(name)
            }
        }
    }

    func validateDestination(_ destinationURL: URL) throws {
        guard destinationURL.pathExtension == "novelpkg",
              !destinationURL.path.isEmpty else {
            throw SyncV2PortableBridgeError.invalidDestination
        }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw SyncV2PortableBridgeError.destinationExists
        }
        let parent = destinationURL.deletingLastPathComponent()
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true,
              values.isDirectory == true else {
            throw SyncV2PortableBridgeError.invalidDestination
        }
    }

    func map(_ error: NovelpkgPortableTransferError) -> SyncV2PortableBridgeError {
        switch error {
        case let .symbolicLink(relativePath):
            .symbolicLink(relativePath: relativePath)
        case let .unsupportedItem(relativePath):
            .unsupportedAttachmentItem(relativePath: relativePath)
        case let .invalidAttachmentName(name):
            .invalidAttachmentName(name)
        case let .attachmentNameCollision(name):
            .attachmentNameCollision(name)
        case let .attachmentUnreadable(name):
            .attachmentUnreadable(name)
        case let .attachmentByteCountMismatch(name):
            .attachmentByteCountMismatch(name)
        default:
            .invalidPackage
        }
    }
}
