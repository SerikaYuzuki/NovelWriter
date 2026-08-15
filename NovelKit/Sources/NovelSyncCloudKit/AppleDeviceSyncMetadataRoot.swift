import Foundation

enum AppleDeviceSyncMetadataRoot {
    static func prepare(_ rootURL: URL, fileManager: FileManager) throws -> URL {
        let standardized = rootURL.standardizedFileURL
        guard rootURL.isFileURL,
              standardized.path.hasPrefix("/"),
              standardized.path != "/" else {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
        do {
            // final component自体がsymlinkなら、targetがdirectoryでもrootには採用しない。
            if (try? fileManager.destinationOfSymbolicLink(atPath: standardized.path)) != nil {
                throw AppleDeviceSyncServicesError.unsafeRoot
            }
            // `/var`等のOS標準aliasを含むancestorは一度canonical pathへ解決し、
            // 以後のmetadata/assets/journalも同じ解決済みrootへ固定する。
            let resolved = try resolveExistingAncestors(
                of: standardized,
                fileManager: fileManager
            )
            guard resolved.path != "/" else {
                throw AppleDeviceSyncServicesError.unsafeRoot
            }
            if fileManager.fileExists(atPath: resolved.path) {
                let values = try resolved.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw AppleDeviceSyncServicesError.unsafeRoot
                }
            } else {
                try fileManager.createDirectory(at: resolved, withIntermediateDirectories: true)
            }
            return resolved
        } catch let error as AppleDeviceSyncServicesError {
            throw error
        } catch {
            throw AppleDeviceSyncServicesError.unsafeRoot
        }
    }

    private static func resolveExistingAncestors(
        of url: URL,
        fileManager: FileManager
    ) throws -> URL {
        var existingAncestor = url
        var missingComponents: [String] = []
        while !fileManager.fileExists(atPath: existingAncestor.path) {
            guard existingAncestor.path != "/" else {
                throw AppleDeviceSyncServicesError.unsafeRoot
            }
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor = existingAncestor.deletingLastPathComponent()
        }
        var resolved = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents {
            resolved.appendPathComponent(component, isDirectory: true)
        }
        return resolved.standardizedFileURL
    }
}
