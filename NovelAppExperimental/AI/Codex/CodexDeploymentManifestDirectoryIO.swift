import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex deployment manifest verification must only compile in FUMINIWAExperimental")
#endif

enum CodexDeploymentManifestDirectoryIO {
    static func components(
        at path: String,
        initial: stat,
        parentRelativeBytes: Data,
        coveredEntryCount: inout Int
    ) throws -> [Data] {
        let directory = try openStableDirectory(at: path, initial: initial)
        defer { Darwin.closedir(directory) }

        var components: [Data] = []
        while let bytes = try nextComponent(from: directory) {
            if bytes == Data([0x2E]) || bytes == Data([0x2E, 0x2E]) {
                continue
            }
            _ = try CodexDeploymentManifestVerifier.decodeCanonicalComponent(bytes)
            try validateChildPathByteCount(
                parentRelativeBytes: parentRelativeBytes,
                componentBytes: bytes
            )
            try reserveCoveredEntry(
                parentRelativeBytes: parentRelativeBytes,
                componentBytes: bytes,
                coveredEntryCount: &coveredEntryCount
            )
            components.append(bytes)
        }
        components.sort { $0.lexicographicallyPrecedes($1) }
        return components
    }

    private static func openStableDirectory(
        at path: String,
        initial: stat
    ) throws -> UnsafeMutablePointer<DIR> {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let descriptor = path.withCString { Darwin.open($0, flags) }
        guard descriptor >= 0 else {
            throw CodexDeploymentManifestError.treeChanged
        }

        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0 else {
            Darwin.close(descriptor)
            throw CodexDeploymentManifestError.treeChanged
        }
        do {
            try CodexDeploymentManifestFileIO.validateSupportedEntry(opened)
            try CodexDeploymentManifestFileIO.requireStable(initial, opened)
        } catch {
            Darwin.close(descriptor)
            throw error
        }

        guard let directory = Darwin.fdopendir(descriptor) else {
            Darwin.close(descriptor)
            throw CodexDeploymentManifestError.treeChanged
        }
        return directory
    }

    private static func nextComponent(
        from directory: UnsafeMutablePointer<DIR>
    ) throws -> Data? {
        errno = 0
        guard let entry = Darwin.readdir(directory) else {
            guard errno == 0 else {
                throw CodexDeploymentManifestError.treeChanged
            }
            return nil
        }
        let length = Int(entry.pointee.d_namlen)
        var rawName = entry.pointee.d_name
        return withUnsafeBytes(of: &rawName) { rawBytes in
            Data(rawBytes.prefix(length))
        }
    }

    private static func validateChildPathByteCount(
        parentRelativeBytes: Data,
        componentBytes: Data
    ) throws {
        let separatorBytes = parentRelativeBytes.isEmpty ? 0 : 1
        let parentAndSeparator = parentRelativeBytes.count
            .addingReportingOverflow(separatorBytes)
        guard !parentAndSeparator.overflow else {
            throw CodexDeploymentManifestError.resourceLimit
        }
        let combined = parentAndSeparator.partialValue
            .addingReportingOverflow(componentBytes.count)
        let isWithinLimit = !combined.overflow
            && combined.partialValue <= CodexDeploymentManifestLimits.maximumRelativePathBytes
        guard isWithinLimit else {
            throw CodexDeploymentManifestError.resourceLimit
        }
    }

    private static func reserveCoveredEntry(
        parentRelativeBytes: Data,
        componentBytes: Data,
        coveredEntryCount: inout Int
    ) throws {
        let isRootSelfManifest = parentRelativeBytes.isEmpty
            && componentBytes == Data(CodexDeploymentManifestLimits.selfManifestPath.utf8)
        guard !isRootSelfManifest else { return }

        let nextCount = coveredEntryCount.addingReportingOverflow(1)
        let isWithinLimit = !nextCount.overflow
            && nextCount.partialValue <= CodexDeploymentManifestLimits.maximumEntryCount
        guard isWithinLimit else {
            throw CodexDeploymentManifestError.resourceLimit
        }
        coveredEntryCount = nextCount.partialValue
    }
}
