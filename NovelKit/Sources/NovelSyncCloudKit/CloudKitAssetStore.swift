import CloudKit
import Foundation
import NovelSync

struct CloudKitStagedAsset: Sendable {
    let url: URL
    let asset: CKAsset
}

struct CloudKitAssetStore: Sendable {
    private static let processSessionID = UUID()
    private static let sessionPrefix = "session-"

    let rootURL: URL

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        sessionID: UUID = Self.processSessionID
    ) throws {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/"), rootURL.path != "/" else {
            throw CloudKitSyncAdapterError.unsafeAssetRoot
        }
        let standardized = rootURL.standardizedFileURL
        guard standardized.path != "/" else {
            throw CloudKitSyncAdapterError.unsafeAssetRoot
        }
        do {
            if fileManager.fileExists(atPath: standardized.path) {
                let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw CloudKitSyncAdapterError.unsafeAssetRoot
                }
            } else {
                try fileManager.createDirectory(at: standardized, withIntermediateDirectories: true)
            }
        } catch let error as CloudKitSyncAdapterError {
            throw error
        } catch {
            throw CloudKitSyncAdapterError.unsafeAssetRoot
        }
        let sessionDirectoryName = Self.sessionPrefix + sessionID.uuidString.lowercased()
        do {
            try Self.removeStaleStagingItems(
                from: standardized,
                keepingSessionDirectory: sessionDirectoryName,
                fileManager: fileManager
            )
            let sessionRoot = standardized.appendingPathComponent(sessionDirectoryName, isDirectory: true)
            if fileManager.fileExists(atPath: sessionRoot.path) {
                let values = try sessionRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw CloudKitSyncAdapterError.unsafeAssetRoot
                }
            } else {
                try fileManager.createDirectory(at: sessionRoot, withIntermediateDirectories: false)
            }
            self.rootURL = sessionRoot
        } catch let error as CloudKitSyncAdapterError {
            throw error
        } catch {
            throw CloudKitSyncAdapterError.unsafeAssetRoot
        }
    }

    private static func removeStaleStagingItems(
        from baseRoot: URL,
        keepingSessionDirectory: String,
        fileManager: FileManager
    ) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: baseRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries where entry.lastPathComponent != keepingSessionDirectory {
            let values = try entry.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isSymbolicLink != true else { continue }
            if values.isDirectory == true,
               isSessionDirectoryName(entry.lastPathComponent) {
                try fileManager.removeItem(at: entry)
            } else if values.isRegularFile == true,
                      isLegacyStagedAssetName(entry.lastPathComponent) {
                try fileManager.removeItem(at: entry)
            }
        }
    }

    private static func isSessionDirectoryName(_ name: String) -> Bool {
        guard name.hasPrefix(sessionPrefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(sessionPrefix.count))) != nil
    }

    private static func isLegacyStagedAssetName(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        guard ["json", "utf8"].contains(url.pathExtension.lowercased()) else { return false }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }

    func stage(content: String, fileManager: FileManager = .default) throws -> CloudKitStagedAsset {
        let data = Data(content.utf8)
        guard data.count <= EpisodeRevision.maximumContentUTF8Bytes else {
            throw EpisodeRevisionError.contentTooLarge(
                actualBytes: data.count,
                maximumBytes: EpisodeRevision.maximumContentUTF8Bytes
            )
        }
        return try stage(
            data: data,
            maximumByteCount: EpisodeRevision.maximumContentUTF8Bytes,
            fileExtension: "utf8",
            fileManager: fileManager
        )
    }

    /// CKRecordの1 MiB fieldへ作品本文を埋め込まず、呼び出し側が検証済みの
    /// canonical payloadをCKAssetとしてstageする共通境界。上限はdomain契約から
    /// 明示注入し、CloudKit固有の都合でpayloadを黙って切り詰めない。
    func stage(
        data: Data,
        maximumByteCount: Int,
        fileExtension: String,
        fileManager: FileManager = .default
    ) throws -> CloudKitStagedAsset {
        guard maximumByteCount >= 0,
              data.count <= maximumByteCount,
              !fileExtension.isEmpty,
              fileExtension.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
              }) else {
            throw CloudKitSyncAdapterError.invalidArguments
        }
        let url = rootURL.appendingPathComponent(
            "\(UUID().uuidString).\(fileExtension)",
            isDirectory: false
        )
        do {
            // UUIDで一意な一時asset。FoundationはatomicとwithoutOverwritingの同時指定を
            // fatal errorにするため、既存fileを上書きしない単独writeを使う。
            try data.write(to: url, options: .withoutOverwriting)
            guard let asset = CKAsset(fileURL: url) as CKAsset? else {
                throw CloudKitSyncAdapterError.invalidRemoteAsset
            }
            return CloudKitStagedAsset(url: url, asset: asset)
        } catch {
            try? fileManager.removeItem(at: url)
            if let adapterError = error as? CloudKitSyncAdapterError {
                throw adapterError
            }
            throw CloudKitSyncAdapterError.operationFailed
        }
    }

    func remove(_ stagedAssets: [CloudKitStagedAsset], fileManager: FileManager = .default) {
        for staged in stagedAssets {
            try? fileManager.removeItem(at: staged.url)
        }
    }

    func read(asset: CKAsset, expectedByteCount: Int, fileManager _: FileManager = .default) throws -> Data {
        try read(
            asset: asset,
            expectedByteCount: expectedByteCount,
            maximumByteCount: EpisodeRevision.maximumContentUTF8Bytes
        )
    }

    func read(
        asset: CKAsset,
        expectedByteCount: Int,
        maximumByteCount: Int,
        fileManager _: FileManager = .default
    ) throws -> Data {
        guard expectedByteCount >= 0,
              maximumByteCount >= 0,
              expectedByteCount <= maximumByteCount,
              let url = asset.fileURL,
              url.isFileURL else {
            throw CloudKitSyncAdapterError.invalidRemoteAsset
        }
        do {
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.fileSize == expectedByteCount else {
                throw CloudKitSyncAdapterError.invalidRemoteAsset
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
            guard data.count == expectedByteCount,
                  data.count <= maximumByteCount else {
                throw CloudKitSyncAdapterError.invalidRemoteAsset
            }
            return data
        } catch let error as CloudKitSyncAdapterError {
            throw error
        } catch {
            throw CloudKitSyncAdapterError.invalidRemoteAsset
        }
    }
}
