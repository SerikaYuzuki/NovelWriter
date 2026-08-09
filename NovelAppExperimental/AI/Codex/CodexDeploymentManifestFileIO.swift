import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex deployment manifest verification must only compile in FUMINIWAExperimental")
#endif

enum CodexDeploymentManifestFileIO {
    static func requireCanonicalRoot(_ path: String) throws -> stat {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw CodexDeploymentManifestError.invalidRoot
        }

        var initial = stat()
        guard path.withCString({ Darwin.lstat($0, &initial) }) == 0 else {
            throw CodexDeploymentManifestError.invalidRoot
        }
        guard fileType(initial) == mode_t(S_IFDIR) else {
            throw CodexDeploymentManifestError.invalidRoot
        }

        guard let canonicalPointer = path.withCString({ Darwin.realpath($0, nil) }) else {
            throw CodexDeploymentManifestError.invalidRoot
        }
        defer { free(canonicalPointer) }
        guard let canonical = String(validatingCString: canonicalPointer), canonical == path else {
            throw CodexDeploymentManifestError.invalidRoot
        }
        try validateMode(initial)
        return initial
    }

    static func stableLstat(_ path: String) throws -> stat {
        var metadata = stat()
        guard path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
            throw CodexDeploymentManifestError.treeChanged
        }
        return metadata
    }

    static func validateSupportedEntry(_ metadata: stat) throws {
        let type = fileType(metadata)
        if type == mode_t(S_IFLNK) {
            throw CodexDeploymentManifestError.symbolicLink
        }
        guard type == mode_t(S_IFDIR) || type == mode_t(S_IFREG) else {
            throw CodexDeploymentManifestError.unsupportedEntry
        }
        if type == mode_t(S_IFREG), metadata.st_nlink != 1 {
            throw CodexDeploymentManifestError.hardLink
        }
        try validateMode(metadata)
    }

    static func validateMode(_ metadata: stat) throws {
        let prohibitedMode = mode_t(S_ISUID | S_ISGID | S_ISVTX | S_IWGRP | S_IWOTH)
        guard metadata.st_mode & prohibitedMode == 0 else {
            throw CodexDeploymentManifestError.invalidMode
        }
    }

    static func permissionMode(_ metadata: stat) -> UInt16 {
        UInt16(metadata.st_mode & 0o777)
    }

    static func fileType(_ metadata: stat) -> mode_t {
        metadata.st_mode & mode_t(S_IFMT)
    }

    static func sameFingerprint(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev
            && left.st_ino == right.st_ino
            && left.st_mode == right.st_mode
            && left.st_nlink == right.st_nlink
            && left.st_size == right.st_size
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
            && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
            && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }

    static func requireStable(_ initial: stat, _ final: stat) throws {
        guard sameFingerprint(initial, final) else {
            throw CodexDeploymentManifestError.treeChanged
        }
    }
}
