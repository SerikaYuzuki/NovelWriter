import Darwin
import Foundation
@testable import FUMINIWAExperimental
import Testing

@Test("canonical physical absolute pathだけを受理しaliasを拒否する")
func codexNodeInspectorRejectsNoncanonicalPathAliases() throws {
    let root = try makeNodeInspectorTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try writeSyntheticNodeExecutable(root: root)
    #expect(try inspectSyntheticNodeExecutable(at: executable).architecture == .arm64)

    let aliases = [
        executable.path.replacingOccurrences(of: "/bin/", with: "/bin/./"),
        executable.path.replacingOccurrences(of: "/bin/", with: "/bin/../bin/"),
        executable.path.replacingOccurrences(of: "/bin/", with: "//bin/"),
        String(executable.path.dropFirst())
    ]
    for alias in aliases {
        #expect(nodePathInspectionError(alias) == .invalidPath)
    }

    if executable.path.hasPrefix("/private/var/") {
        let varAlias = String(executable.path.dropFirst("/private".count))
        #expect(varAlias.hasPrefix("/var/"))
        #expect(nodePathInspectionError(varAlias) == .invalidPath)
    }
}

@Test("symlink selfとancestor aliasを拒否する")
func codexNodeInspectorRejectsSymbolicLinks() throws {
    let root = try makeNodeInspectorTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try writeSyntheticNodeExecutable(root: root)
    let directLink = root.appending(path: "node-link")
    #expect(symlink(executable.path, directLink.path) == 0)
    #expect(nodePathInspectionError(directLink.path) == .symbolicLink)

    let ancestorAlias = root.deletingLastPathComponent().appending(
        path: "fn-node-alias-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: ancestorAlias) }
    #expect(symlink(root.path, ancestorAlias.path) == 0)
    let aliasedExecutable = ancestorAlias.appending(path: "bin/node")
    #expect(nodePathInspectionError(aliasedExecutable.path) == .invalidPath)
}

@Test("hardlink・directory・FIFO・Unix socketを拒否する")
func codexNodeInspectorRejectsLinksAndSpecialFiles() throws {
    let root = try makeNodeInspectorTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try writeSyntheticNodeExecutable(root: root)
    let hardLink = root.appending(path: "node-hardlink")
    #expect(link(executable.path, hardLink.path) == 0)
    #expect(nodePathInspectionError(executable.path) == .hardLink)
    #expect(nodePathInspectionError(hardLink.path) == .hardLink)

    let directory = root.appending(path: "node-directory", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    #expect(nodePathInspectionError(directory.path) == .notRegularFile)

    let fifo = root.appending(path: "node-fifo")
    try makeNodeInspectorFIFO(at: fifo)
    #expect(nodePathInspectionError(fifo.path) == .notRegularFile)

    let shortRoot = try makeShortNodeInspectorTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: shortRoot) }
    let socket = shortRoot.appending(path: "s")
    let socketDescriptor = try makeNodeInspectorUnixSocket(at: socket)
    defer { Darwin.close(socketDescriptor) }
    #expect(nodePathInspectionError(socket.path) == .notRegularFile)
}

@Test("raw非NFC pathとUnicode separatorを拒否する")
func codexNodeInspectorRejectsNoncanonicalUnicodePaths() throws {
    let root = try makeNodeInspectorTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try writeSyntheticNodeExecutable(root: root)
    #expect(try inspectSyntheticNodeExecutable(at: executable).architecture == .arm64)

    let decomposed = executable.path.replacingOccurrences(of: "node", with: "e\u{0301}-node")
    #expect(nodePathInspectionError(decomposed) == .invalidPath)

    for separator in ["\u{2028}", "\u{2029}"] {
        let unsafe = executable.path.replacingOccurrences(of: "node", with: separator)
        #expect(nodePathInspectionError(unsafe) == .invalidPath)
    }
}

private func nodePathInspectionError(
    _ path: String
) -> CodexNodeExecutableInspectionError? {
    capturedNodeInspectionError {
        _ = try CodexNodeExecutableInspector.inspect(
            absolutePath: path,
            requestedArchitecture: .arm64,
            testingHooks: .none,
            codeSignatureObserver: CodexNodeCodeSignatureObserving {
                .syntheticUnsigned
            }
        )
    }
}
