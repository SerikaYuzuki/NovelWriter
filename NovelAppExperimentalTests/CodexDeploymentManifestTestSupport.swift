import Darwin
import Foundation
@testable import FUMINIWAExperimental
import Testing

func makeManifestTemporaryRoot() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .standardizedFileURL
        .resolvingSymlinksInPath()
    let candidate = base.appending(
        path: "FUMINIWA-CodexDeploymentManifestTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: candidate,
        withIntermediateDirectories: false
    )
    guard chmod(candidate.path, 0o700) == 0 else {
        throw ManifestTestError.systemCallFailed
    }
    return try URL(fileURLWithPath: manifestPhysicalPath(candidate.path), isDirectory: true)
}

func makeShortManifestTemporaryRoot() throws -> URL {
    let candidate = URL(
        fileURLWithPath: "/private/tmp/fm-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: candidate,
        withIntermediateDirectories: false
    )
    guard chmod(candidate.path, 0o700) == 0 else {
        throw ManifestTestError.systemCallFailed
    }
    return candidate
}

@discardableResult
func writeManifestFile(
    root: URL,
    relativePath: String,
    contents: Data,
    mode: mode_t = 0o644
) throws -> URL {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    let hasCanonicalComponents = !components.isEmpty
        && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    guard hasCanonicalComponents else {
        throw ManifestTestError.invalidRelativePath
    }

    var parent = root
    for component in components.dropLast() {
        parent.append(path: String(component), directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: false
            )
        }
        guard chmod(parent.path, 0o755) == 0 else {
            throw ManifestTestError.systemCallFailed
        }
    }

    let file = parent.appending(path: String(components.last!), directoryHint: .notDirectory)
    try contents.write(to: file)
    guard chmod(file.path, mode) == 0 else {
        throw ManifestTestError.systemCallFailed
    }
    return file
}

@discardableResult
func writeManifestFile(
    root: URL,
    relativePath: String,
    contents: String,
    mode: mode_t = 0o644
) throws -> URL {
    try writeManifestFile(
        root: root,
        relativePath: relativePath,
        contents: Data(contents.utf8),
        mode: mode
    )
}

func makeSparseManifestFile(
    at url: URL,
    size: off_t,
    mode: mode_t = 0o600
) throws {
    let descriptor = url.path.withCString {
        Darwin.open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode)
    }
    guard descriptor >= 0 else {
        throw ManifestTestError.systemCallFailed
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.ftruncate(descriptor, size) == 0 else {
        throw ManifestTestError.systemCallFailed
    }
}

func makeUnixSocket(at url: URL) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw ManifestTestError.systemCallFailed
    }

    var address = sockaddr_un()
    let pathBytes = Array(url.path.utf8CString)
    guard let pathOffset = MemoryLayout.offset(of: \sockaddr_un.sun_path) else {
        Darwin.close(descriptor)
        throw ManifestTestError.systemCallFailed
    }
    let addressLength = pathOffset + pathBytes.count
    let pathFitsAddress = pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path)
    guard pathFitsAddress, let encodedLength = UInt8(exactly: addressLength) else {
        Darwin.close(descriptor)
        throw ManifestTestError.invalidRelativePath
    }
    address.sun_len = encodedLength
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        pathBytes.withUnsafeBytes { source in
            destination.copyBytes(from: source)
        }
    }

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(addressLength))
        }
    }
    guard result == 0 else {
        Darwin.close(descriptor)
        throw ManifestTestError.systemCallFailed
    }
    return descriptor
}

func capturedManifestError(
    _ operation: () throws -> Void
) -> CodexDeploymentManifestError? {
    do {
        try operation()
        Issue.record("expected CodexDeploymentManifestError")
        return nil
    } catch let error as CodexDeploymentManifestError {
        return error
    } catch {
        Issue.record("unexpected error: \(error)")
        return nil
    }
}

private func manifestPhysicalPath(_ path: String) throws -> String {
    guard let pointer = path.withCString({ Darwin.realpath($0, nil) }) else {
        throw ManifestTestError.systemCallFailed
    }
    defer { free(pointer) }
    guard let physicalPath = String(validatingCString: pointer) else {
        throw ManifestTestError.systemCallFailed
    }
    return physicalPath
}

enum ManifestTestError: Error {
    case invalidRelativePath
    case systemCallFailed
}
