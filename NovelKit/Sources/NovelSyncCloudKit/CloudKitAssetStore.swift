import CloudKit
import Foundation
import NovelSync

struct CloudKitStagedAsset: Sendable {
    let url: URL
    let asset: CKAsset
}

struct CloudKitAssetStore: Sendable {
    let rootURL: URL

    init(rootURL: URL, fileManager: FileManager = .default) throws {
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
        self.rootURL = standardized
    }

    func stage(content: String, fileManager: FileManager = .default) throws -> CloudKitStagedAsset {
        let data = Data(content.utf8)
        guard data.count <= EpisodeRevision.maximumContentUTF8Bytes else {
            throw EpisodeRevisionError.contentTooLarge(
                actualBytes: data.count,
                maximumBytes: EpisodeRevision.maximumContentUTF8Bytes
            )
        }
        let url = rootURL.appendingPathComponent("\(UUID().uuidString).utf8", isDirectory: false)
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
        guard expectedByteCount >= 0,
              expectedByteCount <= EpisodeRevision.maximumContentUTF8Bytes,
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
                  data.count <= EpisodeRevision.maximumContentUTF8Bytes else {
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
