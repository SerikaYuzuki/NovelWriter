import Foundation
import NovelCore

/// 利用者との import / export 境界で、package 全体を安全に扱えない場合のエラー。
public enum NovelpkgPortableTransferError: Error, Equatable, Sendable {
    case invalidPackage
    case symbolicLink(relativePath: String)
    case unsupportedItem(relativePath: String)
    case nestingTooDeep
    case tooManyItems
    case fileTooLarge(relativePath: String)
    case packageTooLarge
    case documentMismatch
}

extension NovelpkgPortableTransferError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidPackage:
            "作品パッケージの形式を確認できません。"
        case let .symbolicLink(relativePath):
            "symbolic link は取り込めません: \(relativePath)"
        case let .unsupportedItem(relativePath):
            "対応していない項目が含まれています: \(relativePath)"
        case .nestingTooDeep:
            "作品パッケージの階層が深すぎます。"
        case .tooManyItems:
            "作品パッケージ内の項目数が上限を超えています。"
        case let .fileTooLarge(relativePath):
            "作品パッケージ内のファイルが大きすぎます: \(relativePath)"
        case .packageTooLarge:
            "作品パッケージ全体の容量が上限を超えています。"
        case .documentMismatch:
            "検証中に作品内容が変わりました。"
        }
    }
}

extension NovelpkgRepository: PortableDocumentPackageRepository {
    /// D-063 の受け渡し境界。通常の package load に加えて、付随dataと未知項目を
    /// 含む tree 全体が bounded regular file / directory だけであることを確認する。
    public func validatePortablePackage(at url: URL) async throws -> NovelDocument {
        try await Task.detached(priority: .utility) {
            try Self.validatePortablePackageSynchronously(at: url, requiresPackageExtension: true)
        }.value
    }

    /// source と sibling temporary package の双方を完全検証した後にだけ、利用者が
    /// 選んだ destination を atomic に置換する。検証失敗時は既存 destination を
    /// 変更しない。
    public func saveValidatedCopy(
        _ doc: NovelDocument,
        from sourceURL: URL,
        to destinationURL: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            try Self.performValidatedPortableCopy(
                doc,
                from: sourceURL,
                to: destinationURL
            )
        }.value
    }
}

extension NovelpkgRepository {
    struct PortablePackageLimits: Sendable {
        static let production = Self(
            maximumDepth: 16,
            maximumItemCount: 20000,
            maximumFileBytes: 512 * 1024 * 1024,
            maximumTotalBytes: 2 * 1024 * 1024 * 1024
        )

        let maximumDepth: Int
        let maximumItemCount: Int
        let maximumFileBytes: Int64
        let maximumTotalBytes: Int64
    }

    static func performValidatedPortableCopy(
        _ doc: NovelDocument,
        from sourceURL: URL,
        to destinationURL: URL,
        limits: PortablePackageLimits = .production
    ) throws {
        let fileManager = FileManager.default
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        try validateTransferEndpoints(source: source, destination: destination, fileManager: fileManager)
        let sourceDocument = try validatePortablePackageSynchronously(
            at: source,
            requiresPackageExtension: true,
            limits: limits
        )
        guard sourceDocument == doc else {
            throw NovelpkgPortableTransferError.documentMismatch
        }
        let parent = destination.deletingLastPathComponent()
        let workingURL = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).transfer",
            isDirectory: true
        )
        do {
            try writeValidatedPortableCopy(
                doc,
                source: source,
                workingURL: workingURL,
                limits: limits,
                fileManager: fileManager
            )
            try adoptValidatedPortableCopy(
                workingURL,
                destination: destination,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: workingURL)
            throw error
        }
    }

    static func validatePortablePackageSynchronously(
        at url: URL,
        requiresPackageExtension: Bool,
        limits: PortablePackageLimits = .production
    ) throws -> NovelDocument {
        let root = url.standardizedFileURL
        guard !requiresPackageExtension || root.pathExtension == "novelpkg" else {
            throw NovelpkgPortableTransferError.invalidPackage
        }
        try validatePortableTree(at: root, limits: limits)
        return try performLoad(from: root)
    }

    static func validatePortableTree(
        at root: URL,
        limits: PortablePackageLimits
    ) throws {
        let fileManager = FileManager.default
        let rootValues = try root.resourceValues(forKeys: [
            .isSymbolicLinkKey,
            .isDirectoryKey
        ])
        guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else {
            throw NovelpkgPortableTransferError.invalidPackage
        }

        var pending: [(url: URL, depth: Int)] = [(root, 0)]
        var itemCount = 0
        var totalBytes: Int64 = 0
        while let current = pending.popLast() {
            let children = try portableChildren(of: current, limits: limits, fileManager: fileManager)
            for child in children {
                itemCount += 1
                guard itemCount <= limits.maximumItemCount else {
                    throw NovelpkgPortableTransferError.tooManyItems
                }
                switch try classifyPortableItem(child, root: root, limits: limits) {
                case .directory:
                    let nextDepth = current.depth + 1
                    guard nextDepth <= limits.maximumDepth else {
                        throw NovelpkgPortableTransferError.nestingTooDeep
                    }
                    pending.append((child, nextDepth))
                case let .file(fileBytes):
                    let (newTotal, overflow) = totalBytes.addingReportingOverflow(fileBytes)
                    guard !overflow, newTotal <= limits.maximumTotalBytes else {
                        throw NovelpkgPortableTransferError.packageTooLarge
                    }
                    totalBytes = newTotal
                }
            }
        }
    }

    private enum PortableItem {
        case directory
        case file(Int64)
    }

    private static func validateTransferEndpoints(
        source: URL,
        destination: URL,
        fileManager: FileManager
    ) throws {
        guard source.pathExtension == "novelpkg",
              destination.pathExtension == "novelpkg",
              !pathsOverlap(source, destination) else {
            throw NovelpkgPortableTransferError.invalidPackage
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.fileExists(atPath: destination.path) else { return }
        let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw NovelpkgPortableTransferError.invalidPackage
        }
    }

    private static func writeValidatedPortableCopy(
        _ document: NovelDocument,
        source: URL,
        workingURL: URL,
        limits: PortablePackageLimits,
        fileManager: FileManager
    ) throws {
        try writePackageContents(
            of: document,
            into: workingURL,
            contentSourceURL: source,
            snapshotsSourceURL: source,
            fileManager: fileManager
        )
        let readBack = try validatePortablePackageSynchronously(
            at: workingURL,
            requiresPackageExtension: false,
            limits: limits
        )
        guard readBack == document else {
            throw NovelpkgPortableTransferError.documentMismatch
        }
    }

    private static func adoptValidatedPortableCopy(
        _ workingURL: URL,
        destination: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: workingURL)
        } else {
            try fileManager.moveItem(at: workingURL, to: destination)
        }
    }

    private static func portableChildren(
        of current: (url: URL, depth: Int),
        limits: PortablePackageLimits,
        fileManager: FileManager
    ) throws -> [URL] {
        guard current.depth <= limits.maximumDepth else {
            throw NovelpkgPortableTransferError.nestingTooDeep
        }
        return try fileManager.contentsOfDirectory(
            at: current.url,
            includingPropertiesForKeys: Array(portableResourceKeys),
            options: []
        )
    }

    private static func classifyPortableItem(
        _ item: URL,
        root: URL,
        limits: PortablePackageLimits
    ) throws -> PortableItem {
        let relativePath = portableRelativePath(of: item, root: root)
        let values = try item.resourceValues(forKeys: portableResourceKeys)
        if values.isSymbolicLink == true {
            throw NovelpkgPortableTransferError.symbolicLink(relativePath: relativePath)
        }
        if values.isDirectory == true {
            return .directory
        }
        guard values.isRegularFile == true else {
            throw NovelpkgPortableTransferError.unsupportedItem(relativePath: relativePath)
        }
        let fileBytes = Int64(values.fileSize ?? -1)
        let maximumBytes = maximumPortableFileBytes(relativePath: relativePath, limits: limits)
        guard fileBytes >= 0, fileBytes <= maximumBytes else {
            throw NovelpkgPortableTransferError.fileTooLarge(relativePath: relativePath)
        }
        return .file(fileBytes)
    }

    private static let portableResourceKeys: Set<URLResourceKey> = [
        .isSymbolicLinkKey,
        .isDirectoryKey,
        .isRegularFileKey,
        .fileSizeKey
    ]

    private static func maximumPortableFileBytes(
        relativePath: String,
        limits: PortablePackageLimits
    ) -> Int64 {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let fileName = components.last else { return limits.maximumFileBytes }
        if fileName == "manifest.json" {
            return min(limits.maximumFileBytes, 16 * 1024 * 1024)
        }
        if ["project.json", "characters.json", "plot.json", "flags.json", "world.json"].contains(fileName) {
            return min(limits.maximumFileBytes, 64 * 1024 * 1024)
        }
        let parentName = components.dropLast().last
        if ["episodes", "episode-notes", "world-notes"].contains(parentName) {
            return min(limits.maximumFileBytes, 1 * 1024 * 1024)
        }
        return limits.maximumFileBytes
    }

    private static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = canonicalTransferPath(lhs)
        let right = canonicalTransferPath(rhs)
        return left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    private static func canonicalTransferPath(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return parent.appendingPathComponent(url.lastPathComponent).path
    }

    private static func portableRelativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
