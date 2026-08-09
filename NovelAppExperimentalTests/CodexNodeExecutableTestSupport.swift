import Darwin
import Foundation
@testable import FUMINIWAExperimental
import Testing

func makeNodeInspectorTemporaryRoot() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .standardizedFileURL
        .resolvingSymlinksInPath()
    let root = base.appending(
        path: "FUMINIWA-CodexNodeInspectorTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false
    )
    guard chmod(root.path, 0o700) == 0 else {
        throw NodeInspectorTestError.systemCallFailed
    }
    return try URL(
        fileURLWithPath: nodeInspectorPhysicalPath(root.path),
        isDirectory: true
    )
}

func makeShortNodeInspectorTemporaryRoot() throws -> URL {
    var template = Array("/private/tmp/fn-node-XXXXXX".utf8CString)
    let created = template.withUnsafeMutableBufferPointer { buffer in
        buffer.baseAddress.flatMap(Darwin.mkdtemp)
    }
    guard created != nil else {
        throw NodeInspectorTestError.systemCallFailed
    }
    let path = template.withUnsafeBufferPointer { buffer in
        buffer.baseAddress.map(String.init(cString:))
    }
    guard let path, chmod(path, 0o700) == 0 else {
        throw NodeInspectorTestError.systemCallFailed
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

@discardableResult
func writeSyntheticNodeExecutable(
    root: URL,
    relativePath: String = "bin/node",
    contents: Data = syntheticThinMachO(architecture: .arm64),
    mode: mode_t = 0o700
) throws -> URL {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    let componentsAreCanonical = !components.isEmpty
        && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    guard componentsAreCanonical else {
        throw NodeInspectorTestError.invalidRelativePath
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
        guard chmod(parent.path, 0o700) == 0 else {
            throw NodeInspectorTestError.systemCallFailed
        }
    }

    let file = parent.appending(
        path: String(components.last!),
        directoryHint: .notDirectory
    )
    try contents.write(to: file)
    guard chmod(file.path, mode) == 0 else {
        throw NodeInspectorTestError.systemCallFailed
    }
    return file
}

func makeSparseSyntheticNodeExecutable(
    at url: URL,
    byteCount: UInt64,
    mode: mode_t = 0o700
) throws {
    let descriptor = url.path.withCString {
        Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
    }
    guard descriptor >= 0 else {
        throw NodeInspectorTestError.systemCallFailed
    }
    defer { Darwin.close(descriptor) }

    let header = syntheticThinMachO(architecture: .arm64)
    let written = header.withUnsafeBytes { bytes in
        Darwin.write(descriptor, bytes.baseAddress, bytes.count)
    }
    guard written == header.count else {
        throw NodeInspectorTestError.systemCallFailed
    }
    guard let size = off_t(exactly: byteCount) else {
        throw NodeInspectorTestError.systemCallFailed
    }
    guard Darwin.ftruncate(descriptor, size) == 0 else {
        throw NodeInspectorTestError.systemCallFailed
    }
}

func makeNodeInspectorFIFO(at url: URL, mode: mode_t = 0o700) throws {
    guard url.path.withCString({ Darwin.mkfifo($0, mode) }) == 0 else {
        throw NodeInspectorTestError.systemCallFailed
    }
}

func makeNodeInspectorUnixSocket(at url: URL) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw NodeInspectorTestError.systemCallFailed
    }

    var address = sockaddr_un()
    let pathBytes = Array(url.path.utf8CString)
    guard let pathOffset = MemoryLayout.offset(of: \sockaddr_un.sun_path) else {
        Darwin.close(descriptor)
        throw NodeInspectorTestError.systemCallFailed
    }
    let addressLength = pathOffset + pathBytes.count
    let pathFits = pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path)
    guard pathFits, let encodedLength = UInt8(exactly: addressLength) else {
        Darwin.close(descriptor)
        throw NodeInspectorTestError.invalidRelativePath
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
        throw NodeInspectorTestError.systemCallFailed
    }
    return descriptor
}

func capturedNodeInspectionError(
    _ operation: () throws -> Void
) -> CodexNodeExecutableInspectionError? {
    do {
        try operation()
        Issue.record("expected CodexNodeExecutableInspectionError")
        return nil
    } catch let error as CodexNodeExecutableInspectionError {
        return error
    } catch {
        Issue.record("unexpected error: \(error)")
        return nil
    }
}

func inspectSyntheticNodeExecutable(
    at url: URL,
    architecture: CodexRuntimeArchitecture = .arm64,
    testingHooks: CodexNodeExecutableInspectorTestingHooks = .none,
    codeSignature: CodexNodeCodeSignatureObservation = .syntheticUnsigned
) throws -> CodexNodeExecutableObservation {
    try CodexNodeExecutableInspector.inspect(
        absolutePath: url.path,
        requestedArchitecture: architecture,
        testingHooks: testingHooks,
        codeSignatureObserver: CodexNodeCodeSignatureObserving { codeSignature }
    )
}

extension CodexNodeCodeSignatureObservation {
    static let syntheticUnsigned = Self(
        validity: .unsigned,
        cdHash: nil,
        informationStatus: 0
    )
}

private func nodeInspectorPhysicalPath(_ path: String) throws -> String {
    guard let pointer = path.withCString({ Darwin.realpath($0, nil) }) else {
        throw NodeInspectorTestError.systemCallFailed
    }
    defer { free(pointer) }
    guard let physicalPath = String(validatingCString: pointer) else {
        throw NodeInspectorTestError.systemCallFailed
    }
    return physicalPath
}

enum NodeInspectorTestError: Error {
    case invalidRelativePath
    case systemCallFailed
}
