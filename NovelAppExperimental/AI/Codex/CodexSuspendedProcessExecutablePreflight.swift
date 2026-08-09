import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex suspended-process inspection must only compile in FUMINIWAExperimental")
#endif

struct CodexSuspendedProcessExecutableLease {
    let descriptor: Int32
    let absolutePath: String
    let metadata: stat

    func close() {
        Darwin.close(descriptor)
    }
}

enum CodexSuspendedProcessExecutablePreflight {
    static func inspect(
        absolutePath: String
    ) throws -> CodexSuspendedProcessExecutableLease {
        try validatePathBytes(absolutePath)
        let initial = try pathMetadata(absolutePath)
        if fileType(initial) == mode_t(S_IFLNK) {
            throw CodexSuspendedProcessIdentityInspectionError.symbolicLink
        }
        try validateExecutable(initial)
        try requireCanonicalPath(absolutePath)

        let descriptor = absolutePath.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw CodexSuspendedProcessIdentityInspectionError.systemCallFailed(
                operation: "open(executable preflight)",
                code: errno
            )
        }
        do {
            let opened = try descriptorMetadata(descriptor)
            try validateExecutable(opened)
            try requireStable(initial, opened)
            try requireDescriptorPath(
                descriptor,
                matches: absolutePath
            )
            return CodexSuspendedProcessExecutableLease(
                descriptor: descriptor,
                absolutePath: absolutePath,
                metadata: opened
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func requireStable(
        _ lease: CodexSuspendedProcessExecutableLease
    ) throws {
        let descriptorState = try descriptorMetadata(lease.descriptor)
        try requireStable(lease.metadata, descriptorState)
        try requireDescriptorPath(
            lease.descriptor,
            matches: lease.absolutePath
        )
        let pathState = try pathMetadata(lease.absolutePath)
        try requireStable(descriptorState, pathState)
        try requireCanonicalPath(lease.absolutePath)
    }

    private static func validatePathBytes(_ path: String) throws {
        let bytes = Array(path.utf8)
        let isCanonicalInput = path.hasPrefix("/")
            && bytes == Array(path.precomposedStringWithCanonicalMapping.utf8)
            && !bytes.contains(0)
            && !bytes.contains(0x5C)
            && bytes.count <= CodexNodeExecutableInspectionLimits.maximumAbsolutePathBytes
            && bytes.allSatisfy { $0 >= 0x20 && $0 != 0x7F }
            && !containsUnicodeLineOrParagraphSeparator(bytes)
            && path.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
                    && !CharacterSet.illegalCharacters.contains($0)
                    && $0.properties.generalCategory != .format
            }
        guard isCanonicalInput else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidPath
        }
    }

    private static func requireCanonicalPath(_ path: String) throws {
        guard let pointer = path.withCString({ Darwin.realpath($0, nil) }) else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidPath
        }
        defer { free(pointer) }
        let canonical = String(validatingCString: pointer)
        let hasMatchingBytes = canonical.map {
            Array($0.utf8) == Array(path.utf8)
        } ?? false
        guard hasMatchingBytes else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidPath
        }
    }

    private static func descriptorMetadata(_ descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw CodexSuspendedProcessIdentityInspectionError.systemCallFailed(
                operation: "fstat(executable preflight)",
                code: errno
            )
        }
        return metadata
    }

    private static func pathMetadata(_ path: String) throws -> stat {
        var metadata = stat()
        guard path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidPath
        }
        return metadata
    }

    private static func validateExecutable(_ metadata: stat) throws {
        guard fileType(metadata) == mode_t(S_IFREG) else {
            throw CodexSuspendedProcessIdentityInspectionError.notRegularFile
        }
        guard metadata.st_nlink == 1 else {
            throw CodexSuspendedProcessIdentityInspectionError.hardLink
        }
        let ownerIsAllowed = metadata.st_uid == 0 || metadata.st_uid == Darwin.geteuid()
        guard ownerIsAllowed else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidOwner
        }
        let prohibited = mode_t(S_ISUID | S_ISGID | S_ISVTX | S_IWGRP | S_IWOTH)
        guard metadata.st_mode & prohibited == 0 else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidMode
        }
        guard metadata.st_mode & mode_t(S_IXUSR) != 0 else {
            throw CodexSuspendedProcessIdentityInspectionError.notExecutable
        }
        guard metadata.st_size > 0 else {
            throw CodexSuspendedProcessIdentityInspectionError.resourceLimit
        }
        guard let byteCount = UInt64(exactly: metadata.st_size) else {
            throw CodexSuspendedProcessIdentityInspectionError.resourceLimit
        }
        let isWithinResourceLimit =
            byteCount <= CodexNodeExecutableInspectionLimits.maximumExecutableBytes
        guard isWithinResourceLimit else {
            throw CodexSuspendedProcessIdentityInspectionError.resourceLimit
        }
    }

    private static func requireStable(_ left: stat, _ right: stat) throws {
        let isStable = left.st_dev == right.st_dev
            && left.st_ino == right.st_ino
            && left.st_mode == right.st_mode
            && left.st_nlink == right.st_nlink
            && left.st_uid == right.st_uid
            && left.st_gid == right.st_gid
            && left.st_size == right.st_size
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
            && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec
            && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
            && left.st_birthtimespec.tv_sec == right.st_birthtimespec.tv_sec
            && left.st_birthtimespec.tv_nsec == right.st_birthtimespec.tv_nsec
            && left.st_flags == right.st_flags
            && left.st_gen == right.st_gen
        guard isStable else {
            throw CodexSuspendedProcessIdentityInspectionError.processIdentityMismatch
        }
    }

    private static func requireDescriptorPath(
        _ descriptor: Int32,
        matches expectedPath: String
    ) throws {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let baseAddress = pointer.baseAddress else { return -1 }
            return Darwin.fcntl(
                descriptor,
                F_GETPATH,
                UnsafeMutableRawPointer(baseAddress)
            )
        }
        guard result == 0 else {
            throw CodexSuspendedProcessIdentityInspectionError.systemCallFailed(
                operation: "fcntl(F_GETPATH preflight)",
                code: errno
            )
        }
        let descriptorPath = buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.flatMap(String.init(validatingCString:))
        }
        let hasMatchingBytes = descriptorPath.map {
            Array($0.utf8) == Array(expectedPath.utf8)
        } ?? false
        guard hasMatchingBytes else {
            throw CodexSuspendedProcessIdentityInspectionError.processIdentityMismatch
        }
    }

    private static func fileType(_ metadata: stat) -> mode_t {
        metadata.st_mode & mode_t(S_IFMT)
    }

    private static func containsUnicodeLineOrParagraphSeparator(
        _ bytes: [UInt8]
    ) -> Bool {
        guard bytes.count >= 3 else { return false }
        return bytes.indices.dropLast(2).contains { index in
            bytes[index] == 0xE2
                && bytes[index + 1] == 0x80
                && (bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9)
        }
    }
}
