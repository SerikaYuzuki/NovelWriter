import CryptoKit
import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex Node executable inspection must only compile in FUMINIWAExperimental")
#endif

enum CodexNodeExecutableFileIO {
    static func inspect(
        absolutePath: String,
        requestedArchitecture: CodexRuntimeArchitecture,
        testingHooks: CodexNodeExecutableInspectorTestingHooks,
        codeSignatureObserver: CodexNodeCodeSignatureObserving
    ) throws -> CodexNodeExecutableObservation {
        let initial = try initialMetadata(at: absolutePath)
        try requireCanonicalPath(absolutePath)
        testingHooks.afterInitialLstat?()

        let descriptor = absolutePath.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw CodexNodeExecutableInspectionError.fileChanged
        }
        defer { Darwin.close(descriptor) }

        let opened = try descriptorMetadata(descriptor)
        try validateExecutable(opened)
        try requireStable(initial, opened)
        try requireDescriptorPath(descriptor, matches: absolutePath)
        let byteCount = try checkedByteCount(opened)

        let digest = try hash(descriptor: descriptor, byteCount: byteCount)
        let machO = try CodexNodeMachOInspector.inspect(
            descriptor: descriptor,
            byteCount: byteCount,
            requestedArchitecture: requestedArchitecture
        )
        testingHooks.afterFileContentRead?()

        try requireStablePath(
            absolutePath,
            descriptor: descriptor,
            expected: opened
        )
        let signature = codeSignatureObserver.observe()
        testingHooks.afterCodeSignatureObservation?()
        try requireStablePath(
            absolutePath,
            descriptor: descriptor,
            expected: opened
        )

        return CodexNodeExecutableObservation(
            architecture: requestedArchitecture,
            machOContainer: machO.container,
            containedArchitectures: machO.architectures,
            byteCount: byteCount,
            sha256: digest.codexRuntimeLowercaseHex,
            ownerUserID: UInt32(opened.st_uid),
            permissionMode: UInt16(opened.st_mode & 0o777),
            codeSignature: signature
        )
    }

    private static func initialMetadata(at path: String) throws -> stat {
        let bytes = Array(path.utf8)
        let isBoundedAbsolutePath = path.hasPrefix("/")
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
        guard isBoundedAbsolutePath else {
            throw CodexNodeExecutableInspectionError.invalidPath
        }

        var metadata = stat()
        guard path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
            throw CodexNodeExecutableInspectionError.invalidPath
        }
        if fileType(metadata) == mode_t(S_IFLNK) {
            throw CodexNodeExecutableInspectionError.symbolicLink
        }
        try validateExecutable(metadata)
        return metadata
    }

    private static func requireCanonicalPath(_ path: String) throws {
        guard let pointer = path.withCString({ Darwin.realpath($0, nil) }) else {
            throw CodexNodeExecutableInspectionError.invalidPath
        }
        defer { free(pointer) }
        let canonical = String(validatingCString: pointer)
        let hasMatchingBytes = canonical.map {
            Array($0.utf8) == Array(path.utf8)
        } ?? false
        guard hasMatchingBytes else {
            throw CodexNodeExecutableInspectionError.invalidPath
        }
    }

    private static func descriptorMetadata(_ descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw CodexNodeExecutableInspectionError.fileChanged
        }
        return metadata
    }

    private static func pathMetadata(_ path: String) throws -> stat {
        var metadata = stat()
        guard path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
            throw CodexNodeExecutableInspectionError.fileChanged
        }
        return metadata
    }

    private static func validateExecutable(_ metadata: stat) throws {
        guard fileType(metadata) == mode_t(S_IFREG) else {
            throw CodexNodeExecutableInspectionError.notRegularFile
        }
        guard metadata.st_nlink == 1 else {
            throw CodexNodeExecutableInspectionError.hardLink
        }
        guard metadata.st_uid == Darwin.geteuid() else {
            throw CodexNodeExecutableInspectionError.invalidOwner
        }
        let prohibited = mode_t(S_ISUID | S_ISGID | S_ISVTX | S_IWGRP | S_IWOTH)
        guard metadata.st_mode & prohibited == 0 else {
            throw CodexNodeExecutableInspectionError.invalidMode
        }
        guard metadata.st_mode & mode_t(S_IXUSR) != 0 else {
            throw CodexNodeExecutableInspectionError.notExecutable
        }
        _ = try checkedByteCount(metadata)
    }

    private static func checkedByteCount(_ metadata: stat) throws -> UInt64 {
        guard metadata.st_size > 0, let byteCount = UInt64(exactly: metadata.st_size) else {
            throw CodexNodeExecutableInspectionError.resourceLimit
        }
        try CodexNodeExecutableInspectionLimits.validateExecutableByteCount(byteCount)
        return byteCount
    }

    private static func requireStablePath(
        _ path: String,
        descriptor: Int32,
        expected: stat
    ) throws {
        let descriptorState = try descriptorMetadata(descriptor)
        try requireStable(expected, descriptorState)
        try requireDescriptorPath(descriptor, matches: path)
        let pathState = try pathMetadata(path)
        try requireStable(descriptorState, pathState)
        try requireCanonicalPath(path)
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
            throw CodexNodeExecutableInspectionError.fileChanged
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
            throw CodexNodeExecutableInspectionError.fileChanged
        }
        let descriptorPath = buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.flatMap(String.init(validatingCString:))
        }
        let hasMatchingBytes = descriptorPath.map {
            Array($0.utf8) == Array(expectedPath.utf8)
        } ?? false
        guard hasMatchingBytes else {
            throw CodexNodeExecutableInspectionError.fileChanged
        }
    }

    private static func hash(descriptor: Int32, byteCount: UInt64) throws -> Data {
        var hasher = SHA256()
        var offset: UInt64 = 0
        var buffer = [UInt8](
            repeating: 0,
            count: CodexNodeExecutableInspectionLimits.hashBufferBytes
        )
        while offset < byteCount {
            let requested = min(buffer.count, Int(byteCount - offset))
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
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
            guard bytesRead >= 0 else {
                throw CodexNodeExecutableInspectionError.readFailed
            }
            guard bytesRead > 0 else {
                throw CodexNodeExecutableInspectionError.fileChanged
            }
            hasher.update(data: Data(buffer.prefix(bytesRead)))
            offset += UInt64(bytesRead)
        }
        return Data(hasher.finalize())
    }

    private static func fileType(_ metadata: stat) -> mode_t {
        metadata.st_mode & mode_t(S_IFMT)
    }

    private static func containsUnicodeLineOrParagraphSeparator(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 3 else { return false }
        return bytes.indices.dropLast(2).contains { index in
            bytes[index] == 0xE2
                && bytes[index + 1] == 0x80
                && (bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9)
        }
    }
}
