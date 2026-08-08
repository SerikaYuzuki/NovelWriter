import CryptoKit
import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex deployment manifest verification must only compile in FUMINIWAExperimental")
#endif

struct CodexDeploymentManifestHashedFile {
    let size: UInt64
    let digest: Data
    let stableMetadata: stat
}

enum CodexDeploymentManifestFileHasher {
    private struct OpenedRegularFile {
        let descriptor: Int32
        let size: UInt64
        let metadata: stat
    }

    static func hashRegularFile(
        at path: String,
        relativePath: String,
        initial: stat,
        afterContentRead: ((String) -> Void)?
    ) throws -> CodexDeploymentManifestHashedFile {
        let opened = try openStableRegularFile(at: path, initial: initial)
        defer { Darwin.close(opened.descriptor) }
        let digest = try hashFileContents(
            descriptor: opened.descriptor,
            size: opened.size
        )

        afterContentRead?(relativePath)

        var afterRead = stat()
        guard Darwin.fstat(opened.descriptor, &afterRead) == 0 else {
            throw CodexDeploymentManifestError.treeChanged
        }
        try CodexDeploymentManifestFileIO.requireStable(opened.metadata, afterRead)
        let afterPathRead = try CodexDeploymentManifestFileIO.stableLstat(path)
        try CodexDeploymentManifestFileIO.requireStable(afterRead, afterPathRead)

        return CodexDeploymentManifestHashedFile(
            size: opened.size,
            digest: digest,
            stableMetadata: afterPathRead
        )
    }

    private static func openStableRegularFile(
        at path: String,
        initial: stat
    ) throws -> OpenedRegularFile {
        guard initial.st_size >= 0, let size = UInt64(exactly: initial.st_size) else {
            throw CodexDeploymentManifestError.treeChanged
        }
        guard size <= CodexDeploymentManifestLimits.maximumFileBytes else {
            throw CodexDeploymentManifestError.resourceLimit
        }

        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw CodexDeploymentManifestError.treeChanged
        }

        var beforeRead = stat()
        guard Darwin.fstat(descriptor, &beforeRead) == 0 else {
            Darwin.close(descriptor)
            throw CodexDeploymentManifestError.treeChanged
        }
        do {
            try CodexDeploymentManifestFileIO.validateSupportedEntry(beforeRead)
            guard CodexDeploymentManifestFileIO.fileType(beforeRead) == mode_t(S_IFREG) else {
                throw CodexDeploymentManifestError.treeChanged
            }
            try CodexDeploymentManifestFileIO.requireStable(initial, beforeRead)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return OpenedRegularFile(
            descriptor: descriptor,
            size: size,
            metadata: beforeRead
        )
    }

    private static func hashFileContents(
        descriptor: Int32,
        size: UInt64
    ) throws -> Data {
        var hasher = SHA256()
        var offset: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while offset < size {
            let requested = min(buffer.count, Int(size - offset))
            let bytesRead: Int = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.pread(
                    descriptor,
                    rawBuffer.baseAddress,
                    requested,
                    off_t(offset)
                )
            }
            if bytesRead < 0, errno == EINTR {
                continue
            }
            guard bytesRead > 0 else {
                throw CodexDeploymentManifestError.treeChanged
            }
            hasher.update(data: Data(buffer.prefix(bytesRead)))
            offset += UInt64(bytesRead)
        }
        return Data(hasher.finalize())
    }
}
